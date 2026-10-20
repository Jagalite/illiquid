// Native macOS benchmark. Production sources are compiled without rewriting.
import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import ImageIO
import IlliquidCore
import UniformTypeIdentifiers

private struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

private func check(_ value: Bool, _ message: String) throws {
    if !value { throw CheckFailure(description: message) }
}

private struct Workload: Codable {
    let name: String
    let seedCount: Int
    let initialMiB: Int
    let seedLayout: String
    let insertionCount: Int
    let incomingBackground: Bool
    let prefill: Bool
    let targetMiB: Int?
    let expectedEvictions: Int
    let expectedBytePressure: Int
    let expectedCountPressure: Int
}

private struct ReceiptEntry: Codable, Equatable {
    let filename: String
    let bytes: Int
    let background: Bool
}

private struct JPEGReceipt: Codable {
    let jpegSHA256: String
    let bytes: Int
}

private struct ModelEntry {
    let receipt: ReceiptEntry
    // Fixed fixture mtimes are integer seconds. New writes are newer than all
    // fixture entries; their actual Date() values are deliberately not hashed.
    let age: Int
}

private struct Model {
    var entries: [String: ModelEntry]
    var bytes: Int
    var evictions: [String] = []
    var bytePressure = 0
    var countPressure = 0

    mutating func trim(limit: Int, incoming: Int, background: Bool) {
        let bytesExceeded = bytes + incoming > limit
        let countExceeded = entries.count >= 8192
        guard bytesExceeded || countExceeded else { return }
        bytePressure += bytesExceeded ? 1 : 0
        countPressure += countExceeded ? 1 : 0
        // Independent complete-sort oracle, frozen to the baseline ordering.
        // No candidate heap is used to determine expected output.
        let victims = entries.values.filter { !background || $0.receipt.background }.sorted {
            if $0.receipt.background != $1.receipt.background { return $0.receipt.background }
            if $0.age != $1.age { return $0.age < $1.age }
            return $0.receipt.filename < $1.receipt.filename
        }
        for victim in victims {
            guard bytes + incoming > limit || entries.count >= 8192 else { break }
            entries.removeValue(forKey: victim.receipt.filename)
            bytes -= victim.receipt.bytes
            evictions.append(victim.receipt.filename)
        }
    }

    mutating func insert(_ entry: ModelEntry, limit: Int) throws {
        trim(limit: limit, incoming: entry.receipt.bytes, background: entry.receipt.background)
        try check(bytes + entry.receipt.bytes <= limit && entries.count < 8192,
                  "oracle rejected an intended fixture insertion")
        try check(entries[entry.receipt.filename] == nil, "duplicate fixture key")
        entries[entry.receipt.filename] = entry
        bytes += entry.receipt.bytes
    }

    var receipt: [ReceiptEntry] {
        entries.values.map(\.receipt).sorted { $0.filename < $1.filename }
    }
}

private struct FullReceipt: Codable {
    let workload: Workload
    let initial: [ReceiptEntry]
    let expectedSurvivors: [ReceiptEntry]
    let evictedFilenames: [String]
    let insertedFilenames: [String]
    let expectedSHA256: String
}

private struct Measurement: Codable {
    let name: String
    let operation: String
    let operations: Int
    let wallNS: UInt64
    let cpuNS: UInt64
    let initialCount: Int
    let initialBytes: Int
    let finalCount: Int
    let finalBytes: Int
    let evictions: Int
    let insertions: Int
    let bytePressure: Int
    let countPressure: Int
    let expectedSHA256: String
    let actualSHA256: String
    let initialSHA256: String
    let oracleCheckedEveryFilenameAndSize: Bool
}

@main
private struct DiskEvictionHarness {
    static let payloadBytes = 4096
    static let fixtureEpoch = 1_000_000

    static func key(_ value: Int) -> NativeThumbnailCache.Key {
        .init(path: "/benchmark/disk-eviction/\(value).mkv", version: "fixture-v1",
              halfSecond: value, width: 64, height: 64)
    }

    static func entry(_ value: Int, bytes: Int, background: Bool, age: Int) -> ModelEntry {
        ModelEntry(receipt: ReceiptEntry(
            filename: "\(background ? "b" : "f")-\(key(value).digest).jpg",
            bytes: bytes, background: background), age: age)
    }

    static func json<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func image() throws -> CGImage {
        let pixels = Data(repeating: 128, count: 16 * 16 * 4)
        guard let provider = CGDataProvider(data: pixels as CFData),
              let result = CGImage(width: 16, height: 16, bitsPerComponent: 8,
                  bitsPerPixel: 32, bytesPerRow: 16 * 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                  provider: provider, decode: nil, shouldInterpolate: false,
                  intent: .defaultIntent) else {
            throw CheckFailure(description: "could not create real CGImage")
        }
        return result
    }

    static func prepareJPEG(at url: URL) throws {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CheckFailure(description: "could not create JPEG destination")
        }
        CGImageDestinationAddImage(destination, try image(),
            [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        try check(CGImageDestinationFinalize(destination), "JPEG encoding failed")
        let payload = try padded(data as Data, to: payloadBytes)
        try verifyJPEG(payload)
        try payload.write(to: url)
        print(String(decoding: try json(JPEGReceipt(jpegSHA256: hash(payload), bytes: payload.count)), as: UTF8.self))
    }

    static func padded(_ jpeg: Data, to size: Int) throws -> Data {
        try check(jpeg.count <= size, "JPEG is larger than fixture's declared file size")
        var result = jpeg
        result.append(Data(repeating: 0, count: size - result.count))
        return result
    }

    static func verifyJPEG(_ data: Data) throws {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw CheckFailure(description: "fixture is not a decodable JPEG")
        }
        try check(decoded.width == 16 && decoded.height == 16, "unexpected JPEG dimensions")
    }

    static func physicalReceipt(_ directory: URL) throws -> [ReceiptEntry] {
        try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
            .map { url in
                let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
                let name = url.lastPathComponent
                try check(values.isRegularFile == true && values.isSymbolicLink != true,
                          "unexpected nonregular file: \(name)")
                try check(name.hasSuffix(".jpg") && (name.hasPrefix("b-") || name.hasPrefix("f-")),
                          "unexpected physical filename: \(name)")
                guard let bytes = values.fileSize else {
                    throw CheckFailure(description: "missing file size for \(name)")
                }
                return ReceiptEntry(filename: name, bytes: bytes, background: name.hasPrefix("b-"))
            }.sorted { $0.filename < $1.filename }
    }

    static func processCPUTime() throws -> UInt64 {
        var value = timespec()
        try check(clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &value) == 0,
                  "clock_gettime(CLOCK_PROCESS_CPUTIME_ID) failed")
        return UInt64(value.tv_sec) * 1_000_000_000 + UInt64(value.tv_nsec)
    }

    static func run(_ workload: Workload, jpeg: Data, directory: URL,
                    receiptURL: URL?) async throws {
        try check(workload.seedCount > 0 && workload.seedCount < 8192,
                  "seed inventory must warm without a count-cap trim")
        try check(workload.insertionCount >= 0 && workload.initialMiB > 0,
                  "invalid workload configuration")
        try check(jpeg.count == payloadBytes, "insertion payload must be exactly 4096 bytes")
        try verifyJPEG(jpeg)
        try check(Date().timeIntervalSince1970 > Double(fixtureEpoch + workload.seedCount),
                  "fixture dates must precede inserted dates")
        let manager = FileManager.default
        try check(!manager.fileExists(atPath: directory.path), "fixture directory must be new")
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: directory) }

        let limit = workload.initialMiB * 1024 * 1024
        var model = Model(entries: [:], bytes: 0)
        var payloads: [Int: Data] = [:]
        for index in 0..<workload.seedCount {
            let size: Int
            if workload.seedLayout == "exact-byte-cap" {
                size = limit / workload.seedCount + (index < limit % workload.seedCount ? 1 : 0)
            } else {
                try check(workload.seedLayout == "fixed-payload", "unknown seed layout")
                size = payloadBytes
            }
            let item = entry(index, bytes: size, background: index % 3 != 0,
                             age: fixtureEpoch + index / 8)
            if payloads[size] == nil { payloads[size] = try padded(jpeg, to: size) }
            let url = directory.appendingPathComponent(item.receipt.filename)
            try payloads[size]!.write(to: url)
            try manager.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(item.age))],
                                      ofItemAtPath: url.path)
            model.entries[item.receipt.filename] = item
            model.bytes += size
        }
        if workload.seedLayout == "exact-byte-cap" {
            try check(model.bytes == limit, "byte-cap fixture is not exactly full")
        }
        let realImage = try image()
        let cache = NativeThumbnailDiskCache(directory: directory, encode: { _ in jpeg })
        var settings = ThumbnailPreferences()
        settings.diskMiB = workload.initialMiB
        await cache.configure(settings)
        let inventoriedBytes = await cache.bytes()
        try check(inventoriedBytes == model.bytes, "inventory unexpectedly trimmed fixture")
        // Warm existing-key insert/digest dispatch without promotion or mutation.
        await cache.insert(realImage, for: key(1), background: true, epoch: 0)
        if workload.prefill {
            try check(workload.seedCount == 8191 && workload.seedLayout == "fixed-payload",
                      "count control must prefill from 8191 to 8192")
            let item = entry(1_000_000, bytes: payloadBytes,
                             background: workload.incomingBackground, age: 10_000_000)
            await cache.insert(realImage, for: key(1_000_000),
                               background: workload.incomingBackground, epoch: 0)
            try model.insert(item, limit: limit)
        }
        let initial = model.receipt
        try check(try physicalReceipt(directory) == initial, "initial fixture identity or size mismatch")
        try check(await cache.bytes() == model.bytes, "initial accounted bytes mismatch")
        try check(model.evictions.isEmpty, "warmup must not evict")
        let initialBytes = model.bytes
        let incomingKeys = (0..<workload.insertionCount).map { key(2_000_000 + $0) }
        var insertedNames: [String] = []
        for index in 0..<workload.insertionCount {
            let item = entry(2_000_000 + index, bytes: payloadBytes,
                             background: workload.incomingBackground, age: 10_000_001 + index)
            try model.insert(item, limit: limit)
            insertedNames.append(item.receipt.filename)
        }
        if let target = workload.targetMiB {
            try check(workload.insertionCount == 0, "configure workload cannot also insert")
            model.trim(limit: target * 1024 * 1024, incoming: 0, background: false)
            settings.diskMiB = target
        }
        try check(model.evictions.count == workload.expectedEvictions,
                  "fixture does not exercise the declared number of evictions")
        try check(model.bytePressure == workload.expectedBytePressure && model.countPressure == workload.expectedCountPressure,
                  "fixture exercises the wrong budget trigger")

        let cpuStart = try processCPUTime()
        let wallStart = DispatchTime.now().uptimeNanoseconds
        if workload.targetMiB != nil {
            await cache.configure(settings)
        } else {
            for item in incomingKeys {
                await cache.insert(realImage, for: item, background: workload.incomingBackground, epoch: 0)
            }
        }
        let wallNS = DispatchTime.now().uptimeNanoseconds - wallStart
        let cpuNS = try processCPUTime() - cpuStart

        let actual = try physicalReceipt(directory)
        let expected = model.receipt
        try check(actual == expected, "final survivor filenames, byte sizes, or tiers differ from independent oracle")
        let actualNames = Set(actual.map(\.filename))
        let initialNames = Set(initial.map(\.filename))
        try check(initialNames.subtracting(actualNames).count == workload.expectedEvictions,
                  "actual eviction count differs from the declared workload")
        try check(Set(insertedNames).isSubset(of: actualNames), "a timed insertion was rejected or lost")
        try check(actualNames.subtracting(initialNames) == Set(insertedNames), "unexpected inserted filenames")
        let finalBytes = await cache.bytes()
        try check(finalBytes == model.bytes && finalBytes == actual.reduce(0) { $0 + $1.bytes },
                  "actor and physical byte accounting differ")
        let expectedHash = hash(try json(expected))
        let actualHash = hash(try json(actual))
        if let receiptURL {
            let full = FullReceipt(workload: workload, initial: initial, expectedSurvivors: expected,
                evictedFilenames: model.evictions, insertedFilenames: insertedNames, expectedSHA256: expectedHash)
            try json(full).write(to: receiptURL)
        }
        let measurement = Measurement(name: workload.name,
            operation: workload.targetMiB == nil ? "insert" : "configure",
            operations: workload.targetMiB == nil ? workload.insertionCount : 1,
            wallNS: wallNS, cpuNS: cpuNS, initialCount: initial.count, initialBytes: initialBytes,
            finalCount: actual.count, finalBytes: finalBytes,
            evictions: model.evictions.count, insertions: insertedNames.count,
            bytePressure: model.bytePressure, countPressure: model.countPressure,
            expectedSHA256: expectedHash, actualSHA256: actualHash,
            initialSHA256: hash(try json(initial)), oracleCheckedEveryFilenameAndSize: true)
        print(String(decoding: try json(measurement), as: UTF8.self))
    }

    static func main() async throws {
        let arguments = CommandLine.arguments
        if arguments.count == 3 && arguments[1] == "prepare" {
            try prepareJPEG(at: URL(fileURLWithPath: arguments[2]))
            return
        }
        try check(arguments.count == 5,
                  "usage: harness CASE.json FIXED.jpg FIXTURE_DIRECTORY RECEIPT.json-or-dash")
        let workload = try JSONDecoder().decode(Workload.self,
            from: Data(contentsOf: URL(fileURLWithPath: arguments[1])))
        let jpeg = try Data(contentsOf: URL(fileURLWithPath: arguments[2]))
        let receipt = arguments[4] == "-" ? nil : URL(fileURLWithPath: arguments[4])
        try await run(workload, jpeg: jpeg, directory: URL(fileURLWithPath: arguments[3]), receiptURL: receipt)
    }
}
