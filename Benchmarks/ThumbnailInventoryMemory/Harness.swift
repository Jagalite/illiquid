// Native macOS component benchmark; production cache sources are unmodified.
import CThumbnailReadMetrics
import CoreGraphics
import CryptoKit
import Dispatch
import Foundation
import ImageIO
import IlliquidCore
import UniformTypeIdentifiers

private let payloadBytes = 4096
private let imageWidth = 32
private let imageHeight = 18

private struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

private func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw CheckFailure(description: message) }
}

private func key(_ index: Int) -> NativeThumbnailCache.Key {
    .init(path: "/benchmark/thumbnail-inventory/\(index).mkv",
          version: "fixture-v1", halfSecond: index,
          width: imageWidth, height: imageHeight)
}

private func hash(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func printJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    print(String(decoding: try encoder.encode(value), as: UTF8.self))
}

private func fixtureJPEG() throws -> Data {
    var pixels = [UInt8](repeating: 255, count: imageWidth * imageHeight * 4)
    for y in 0..<imageHeight {
        for x in 0..<imageWidth {
            let offset = (y * imageWidth + x) * 4
            pixels[offset] = UInt8((x * 7 + y * 3) % 256)
            pixels[offset + 1] = UInt8((x * 3 + y * 11) % 256)
            pixels[offset + 2] = UInt8((x * 17 + y * 5) % 256)
        }
    }
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
          let provider = CGDataProvider(data: Data(pixels) as CFData),
          let image = CGImage(width: imageWidth, height: imageHeight,
              bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: imageWidth * 4,
              space: colorSpace,
              bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
              provider: provider, decode: nil, shouldInterpolate: false,
              intent: .defaultIntent) else {
        throw CheckFailure(description: "Could not create patterned fixture image")
    }
    let encoded = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
        encoded, UTType.jpeg.identifier as CFString, 1, nil) else {
        throw CheckFailure(description: "Could not create JPEG destination")
    }
    CGImageDestinationAddImage(destination, image,
        [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
    try require(CGImageDestinationFinalize(destination), "JPEG encoding failed")
    var data = encoded as Data
    try require(data.count <= payloadBytes, "JPEG exceeds fixed fixture size")
    data.append(Data(repeating: 0, count: payloadBytes - data.count))
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        throw CheckFailure(description: "Padded fixture is not a decodable JPEG")
    }
    try require(decoded.width == imageWidth && decoded.height == imageHeight,
                "Padded JPEG dimensions changed")
    return data
}

private struct SeedReceipt: Encodable, Sendable {
    let count: Int
    let bytes: Int
    let jpeg_sha256: String
}

private func seed(_ directory: URL, count: Int) throws -> SeedReceipt {
    let manager = FileManager.default
    try require(!manager.fileExists(atPath: directory.path),
                "Seed directory must be new")
    try manager.createDirectory(at: directory, withIntermediateDirectories: true)
    let jpeg = try fixtureJPEG()
    for index in 0..<count {
        try autoreleasepool {
            let tier = index.isMultiple(of: 2) ? "b" : "f"
            let url = directory.appendingPathComponent("\(tier)-\(key(index).digest).jpg")
            try jpeg.write(to: url, options: .atomic)
            try manager.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: 1_000_000 + Double(index))],
                ofItemAtPath: url.path)
        }
    }
    return SeedReceipt(count: count, bytes: count * payloadBytes, jpeg_sha256: hash(jpeg))
}

// Draw into a specified sRGB RGBA layout to compare decoded content rather than
// provider layout, pointer identity, or just image dimensions. Outside timing.
private func pixelHash(_ image: CGImage) throws -> String {
    var pixels = [UInt8](repeating: 0, count: imageWidth * imageHeight * 4)
    let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: bytes.baseAddress,
                  width: imageWidth, height: imageHeight,
                  bitsPerComponent: 8, bytesPerRow: imageWidth * 4,
                  space: colorSpace,
                  bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                      | CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.draw(image, in: CGRect(
            x: 0, y: 0, width: CGFloat(imageWidth), height: CGFloat(imageHeight)
        ))
        return true
    }
    try require(rendered, "Could not rasterize decoded image")
    return hash(Data(pixels))
}

private struct Measurement: Encodable, Sendable {
    let count: Int
    let inventory_bytes: Int
    let inventory_wall_ns: UInt64
    let inventory_cpu_ns: UInt64
    let heap_metric: String
    let heap_before_bytes: UInt64
    let heap_after_bytes: UInt64
    let heap_delta_bytes: Int64
    let resident_metric: String
    let resident_before_bytes: UInt64
    let resident_after_bytes: UInt64
    let resident_delta_bytes: Int64
    let read_iterations: Int
    let read_wall_ns: UInt64
    let read_cpu_ns: UInt64
    let read_checksum: UInt64
    let pixel_sha256: [String]
}

private extension NativeThumbnailDiskCache {
    // Every pool is entered and drained synchronously on this actor's executor.
    // In particular, no await or returned CGImage can carry enumerator/read
    // autoreleases across the memory snapshot or timed-loop iteration boundary.
    @inline(never)
    func consumedImage(for key: Key, expectHit: Bool) -> UInt64 {
        autoreleasepool {
            let result = image(for: key, background: true)
            precondition((result != nil) == expectHit, "Unexpected cache hit/miss")
            guard let result else { return 1 }
            precondition(result.width == imageWidth && result.height == imageHeight)
            return UInt64(result.width) &* 1_000_003
                &+ UInt64(result.height) &* 97 &+ UInt64(result.bitsPerPixel)
        }
    }

    @inline(never)
    func measurement(count: Int) throws -> Measurement {
        let heapMetric = String(cString: thumbnail_heap_metric())
        let residentMetric = String(cString: thumbnail_resident_metric())
        try require(heapMetric != "unsupported" && residentMetric != "unsupported",
                    "Native live-memory metrics are unavailable")
        autoreleasepool {
            _ = FileManager.default
            _ = thumbnail_heap_bytes()
            _ = thumbnail_resident_bytes()
            _ = thumbnail_cpu_nanoseconds()
            _ = DispatchTime.now().uptimeNanoseconds
        }
        let heapBefore = thumbnail_heap_bytes()
        let residentBefore = thumbnail_resident_bytes()
        let inventoryCPUStart = thumbnail_cpu_nanoseconds()
        let inventoryWallStart = DispatchTime.now().uptimeNanoseconds
        // This is the first inventory. No image read or preflight ran beforehand.
        let inventoryBytes = autoreleasepool { bytes() }
        let inventoryWall = DispatchTime.now().uptimeNanoseconds - inventoryWallStart
        let inventoryCPUEnd = thumbnail_cpu_nanoseconds()
        // Keep the actor and its complete inventory alive after the pool drains.
        let heapAfter = withExtendedLifetime(self) { thumbnail_heap_bytes() }
        let residentAfter = withExtendedLifetime(self) { thumbnail_resident_bytes() }
        try require(inventoryBytes == count * payloadBytes,
                    "Inventory was incomplete or unexpectedly evicted fixture entries")
        try require(heapBefore > 0 && heapAfter > 0 && residentBefore > 0 && residentAfter > 0,
                    "Native live-memory sampler failed")
        try require(inventoryCPUStart > 0 && inventoryCPUEnd >= inventoryCPUStart,
                    "Inventory CPU sampler failed")

        // Memory samples are complete. Warm only the subsequent read benchmark.
        let indices = count == 0 ? [0] : [0, count / 2, count - 1]
        let keys = indices.map { key($0) }
        let expectHit = count > 0
        for _ in 0..<8 {
            for lookup in keys { _ = consumedImage(for: lookup, expectHit: expectHit) }
        }
        var pixelHashes: [String] = []
        if expectHit {
            for lookup in keys {
                let digest = try autoreleasepool {
                    guard let decoded = image(for: lookup, background: true) else {
                        throw CheckFailure(description: "Pixel preflight unexpectedly missed")
                    }
                    return try pixelHash(decoded)
                }
                pixelHashes.append(digest)
            }
            try require(Set(pixelHashes).count == 1,
                        "Identical fixture files decoded to different pixels")
        }
        let iterations = 512
        var checksum: UInt64 = 0
        let readCPUStart = thumbnail_cpu_nanoseconds()
        let readWallStart = DispatchTime.now().uptimeNanoseconds
        for index in 0..<iterations {
            checksum &+= consumedImage(for: keys[index % keys.count], expectHit: expectHit)
        }
        let readWall = DispatchTime.now().uptimeNanoseconds - readWallStart
        let readCPUEnd = thumbnail_cpu_nanoseconds()
        try require(readCPUStart > 0 && readCPUEnd >= readCPUStart,
                    "Read CPU sampler failed")
        try require(bytes() == inventoryBytes, "Background reads changed inventory accounting")
        return Measurement(count: count, inventory_bytes: inventoryBytes,
            inventory_wall_ns: inventoryWall,
            inventory_cpu_ns: inventoryCPUEnd - inventoryCPUStart,
            heap_metric: heapMetric, heap_before_bytes: heapBefore,
            heap_after_bytes: heapAfter,
            heap_delta_bytes: Int64(heapAfter) - Int64(heapBefore),
            resident_metric: residentMetric, resident_before_bytes: residentBefore,
            resident_after_bytes: residentAfter,
            resident_delta_bytes: Int64(residentAfter) - Int64(residentBefore),
            read_iterations: iterations, read_wall_ns: readWall,
            read_cpu_ns: readCPUEnd - readCPUStart,
            read_checksum: checksum, pixel_sha256: pixelHashes)
    }
}

@main
private struct InventoryHarness {
    static func main() async throws {
        let arguments = CommandLine.arguments
        try require(arguments.count == 4, "Usage: seed|measure DIRECTORY COUNT")
        guard let count = Int(arguments[3]), (0...8191).contains(count) else {
            throw CheckFailure(description: "COUNT must be between 0 and 8191")
        }
        let directory = URL(fileURLWithPath: arguments[2], isDirectory: true)
        switch arguments[1] {
        case "seed":
            try printJSON(autoreleasepool { try seed(directory, count: count) })
        case "measure":
            let cache = NativeThumbnailDiskCache(directory: directory)
            var preferences = ThumbnailPreferences()
            preferences.diskMiB = 1024
            await cache.configure(preferences)
            let result = try await cache.measurement(count: count)
            try printJSON(result)
        default:
            throw CheckFailure(description: "Unknown mode")
        }
    }
}
