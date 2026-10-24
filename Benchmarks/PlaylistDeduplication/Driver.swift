import Dispatch
import Foundation
import IlliquidCore

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@_silgen_name("illiquid_live_allocated_bytes")
private func liveAllocatedBytes() -> UInt64

@inline(__always)
private func releasingTemporaryObjects<T>(_ body: () throws -> T) rethrows -> T {
    #if canImport(Darwin)
    return try autoreleasepool(invoking: body)
    #else
    return try body()
    #endif
}

private enum Scope: String {
    case deduplicate, session
}

private enum Pattern: String {
    case unique, sparse, early, late, fourfold, all
}

private struct BenchmarkError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private struct Fixture {
    let input: [FolderPlaylistItem]
    let expected: [FolderPlaylistItem]
    let source: MediaSource
    let folder: URL
    let index: Int?
    let updatedAt = Date(timeIntervalSince1970: 1_234)
    let position: TimeInterval = 42.25
    let wasPaused = true

    init(pattern: Pattern, count: Int) {
        let distinctCount = count / 4 + (count % 4 == 0 ? 0 : 1)
        var preparedInput: [FolderPlaylistItem] = []
        preparedInput.reserveCapacity(pattern == .sparse ? max(50_000, count) : count)
        for occurrence in 0..<count {
            let identity: Int
            switch pattern {
            case .unique, .sparse: identity = occurrence
            case .early: identity = occurrence < 2 ? 0 : occurrence - 1
            case .late: identity = occurrence == count - 1 ? 0 : occurrence
            case .fourfold: identity = occurrence % distinctCount
            case .all: identity = 0
            }
            preparedInput.append(FolderPlaylistItem(
                url: URL(fileURLWithPath: "/Media/Episode \(identity).mkv"),
                externalSubtitleURLs: [
                    URL(fileURLWithPath: "/Subtitles/\(identity)-\(occurrence).srt"),
                    URL(fileURLWithPath: "/Subtitles/\(identity)-\(occurrence).ass"),
                ],
                dateAdded: Date(timeIntervalSince1970: Double(occurrence))
            ))
        }

        // The oracle follows known integer fixture identities, without calling
        // either production deduplication or normalized string-ID helpers.
        let firstOccurrences: [Int]
        switch pattern {
        case .unique, .sparse: firstOccurrences = Array(0..<count)
        case .early:
            firstOccurrences = count > 1 ? [0] + Array(2..<count) : Array(0..<count)
        case .late:
            firstOccurrences = Array(0..<(count > 1 ? count - 1 : count))
        case .fourfold: firstOccurrences = Array(0..<distinctCount)
        case .all: firstOccurrences = count == 0 ? [] : [0]
        }
        input = preparedInput
        expected = firstOccurrences.map { preparedInput[$0] }
        source = .localFile(preparedInput.first?.url ?? URL(fileURLWithPath: "/Media/empty.mkv"))
        folder = URL(fileURLWithPath: "/Media", isDirectory: true)
        index = preparedInput.isEmpty ? nil : 0
    }
}

private enum Produced {
    case playlist([FolderPlaylistItem])
    case session(PlaybackSessionRecord)

    var items: [FolderPlaylistItem] {
        switch self {
        case let .playlist(items): items
        case let .session(record): record.playlistItems
        }
    }
}

// The driver is compiled separately from the actual production module. Neither
// this wrapper nor the non-inlinable production entry points can be folded into
// a precomputed answer for an unchanged fixture.
@inline(never)
private func produce(_ scope: Scope, _ fixture: Fixture) -> Produced {
    // Return the owned value after draining Objective-C temporaries on Darwin.
    // Both measured variants pay the same pool overhead in the timed loop.
    releasingTemporaryObjects {
        switch scope {
        case .deduplicate:
            return .playlist(PlaylistMutation.deduplicated(fixture.input))
        case .session:
            return .session(PlaybackSessionRecord(
                source: fixture.source,
                collectionFolder: fixture.folder,
                playlistItems: fixture.input,
                playlistIndex: fixture.index,
                position: fixture.position,
                wasPaused: fixture.wasPaused,
                unshuffledPlaylistIDs: nil,
                updatedAt: fixture.updatedAt
            ))
        }
    }
}

private struct Fingerprint {
    private(set) var value: UInt64 = 14_695_981_039_346_656_037

    mutating func append(_ number: UInt64) {
        for shift in stride(from: 0, to: 64, by: 8) {
            appendByte(UInt8(truncatingIfNeeded: number >> shift))
        }
    }

    mutating func append(_ string: String) {
        append(UInt64(string.utf8.count))
        for byte in string.utf8 { appendByte(byte) }
    }

    mutating func appendByte(_ byte: UInt8) {
        value = (value ^ UInt64(byte)) &* 1_099_511_628_211
    }

    mutating func append(_ items: [FolderPlaylistItem]) {
        append(UInt64(items.count))
        for item in items {
            append(item.id)
            append(item.url.absoluteString)
            append(UInt64(item.externalSubtitleURLs.count))
            for subtitle in item.externalSubtitleURLs { append(subtitle.absoluteString) }
            appendByte(item.dateAdded == nil ? 0 : 1)
            if let date = item.dateAdded { append(date.timeIntervalSince1970.bitPattern) }
        }
    }

    var hex: String { String(value, radix: 16) }
}

private func validate(_ result: Produced, against fixture: Fixture) throws -> String {
    let items = result.items
    guard items == fixture.expected else {
        throw BenchmarkError("Complete playlist output differs from the first-occurrence oracle")
    }
    var fingerprint = Fingerprint()
    fingerprint.append(items)
    var expectedFingerprint = Fingerprint()
    expectedFingerprint.append(fixture.expected)
    guard fingerprint.value == expectedFingerprint.value else {
        throw BenchmarkError("Exact playlist representations or metadata differ from the oracle")
    }
    if case let .session(record) = result {
        guard record.schemaVersion == PlaybackSessionRecord.currentSchemaVersion,
              record.source == fixture.source,
              record.collectionFolder == fixture.folder,
              record.playlistIndex == fixture.index,
              record.unshuffledPlaylistIDs == nil,
              record.position == fixture.position,
              record.wasPaused == fixture.wasPaused,
              record.updatedAt == fixture.updatedAt else {
            throw BenchmarkError("Session metadata changed during record construction")
        }
        fingerprint.append(UInt64(record.schemaVersion))
        fingerprint.append(record.source.url.absoluteString)
        fingerprint.appendByte(record.source.isRemote ? 1 : 0)
        fingerprint.append(record.collectionFolder?.absoluteString ?? "")
        fingerprint.append(UInt64(record.playlistIndex.map { $0 + 1 } ?? 0))
        fingerprint.append(record.position.bitPattern)
        fingerprint.appendByte(record.wasPaused ? 1 : 0)
        fingerprint.append(record.updatedAt.timeIntervalSince1970.bitPattern)
    }
    return fingerprint.hex
}

private func checksumComponent(_ items: [FolderPlaylistItem]) -> UInt64 {
    let first = items.first?.dateAdded?.timeIntervalSince1970.bitPattern ?? 0
    let last = items.last?.dateAdded?.timeIntervalSince1970.bitPattern ?? 0
    return (UInt64(items.count) &* 0x9E37_79B9_7F4A_7C15) ^ first ^ (last &* 31)
}

@inline(never)
private func warmAndValidate(_ scope: Scope, _ fixture: Fixture) throws {
    try releasingTemporaryObjects {
        let warm = produce(scope, fixture)
        _ = try validate(warm, against: fixture)
        // Initialize the probe before its measured use. This helper releases
        // the warm result and validation temporaries before measurement starts.
        _ = liveAllocatedBytes()
        withExtendedLifetime(warm) {}
    }
}

private struct RetainedOutputMeasurement {
    let outputCount: Int
    let elementStride: Int
    let inputCapacity: Int
    let outputCapacity: Int
    let sharesInputStorage: Bool
    let additionalElementCapacityBytes: Int
    let allocatedBefore: UInt64
    let allocatedAfter: UInt64
    let fingerprint: String
}

@inline(never)
private func measureRetainedOutput(_ scope: Scope, _ fixture: Fixture) throws -> RetainedOutputMeasurement {
    try withExtendedLifetime(fixture) {
        let allocatedBefore = liveAllocatedBytes()
        let retained = produce(scope, fixture)
        // Exactly one result is retained here, alongside the pre-existing
        // source/expected fixture. The production pool has already drained.
        let allocatedAfter = withExtendedLifetime(retained) { liveAllocatedBytes() }

        return try withExtendedLifetime(retained) {
            try releasingTemporaryObjects {
                let fingerprint = try validate(retained, against: fixture)
                let items = retained.items
                let sharesInputStorage = fixture.input.withUnsafeBufferPointer { input in
                    items.withUnsafeBufferPointer { output in
                        input.baseAddress == output.baseAddress
                    }
                }
                let stride = MemoryLayout<FolderPlaylistItem>.stride
                let (capacityBytes, overflow) = items.capacity.multipliedReportingOverflow(by: stride)
                guard !overflow else { throw BenchmarkError("Element capacity byte count overflow") }
                return RetainedOutputMeasurement(
                    outputCount: items.count, elementStride: stride,
                    inputCapacity: fixture.input.capacity, outputCapacity: items.capacity,
                    sharesInputStorage: sharesInputStorage,
                    additionalElementCapacityBytes: sharesInputStorage ? 0 : capacityBytes,
                    allocatedBefore: allocatedBefore, allocatedAfter: allocatedAfter,
                    fingerprint: fingerprint
                )
            }
        }
    }
    // No output array or record escapes this helper. The measured result is
    // released before the separate create/discard timing loop begins.
}

private struct Measurement: Encodable {
    let scope: String
    let pattern: String
    let count: Int
    let iterations: Int
    let output_count: Int
    let element_stride: Int
    let input_capacity: Int
    let output_capacity: Int
    let shares_input_storage: Bool
    let additional_element_capacity_bytes: Int
    let allocated_before_bytes: UInt64
    let allocated_after_bytes: UInt64
    let elapsed_ns: UInt64
    let checksum: UInt64
    let output_fingerprint: String
}

private func run(scope: Scope, pattern: Pattern, count: Int, iterations: Int) throws -> Measurement {
    let fixture = releasingTemporaryObjects { Fixture(pattern: pattern, count: count) }
    try warmAndValidate(scope, fixture)

    return try withExtendedLifetime(fixture) {
        let memory = try measureRetainedOutput(scope, fixture)
        var checksum: UInt64 = 0
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<(iterations - 1) {
            let result = produce(scope, fixture)
            checksum &+= checksumComponent(result.items)
        }
        let lastResult = produce(scope, fixture)
        checksum &+= checksumComponent(lastResult.items)
        let elapsed = DispatchTime.now().uptimeNanoseconds - start

        let finalFingerprint = try releasingTemporaryObjects {
            try validate(lastResult, against: fixture)
        }
        guard checksum == checksumComponent(fixture.expected) &* UInt64(iterations),
              finalFingerprint == memory.fingerprint else {
            throw BenchmarkError("Timed output does not match the independent oracle")
        }
        return Measurement(
            scope: scope.rawValue, pattern: pattern.rawValue, count: count, iterations: iterations,
            output_count: memory.outputCount, element_stride: memory.elementStride,
            input_capacity: memory.inputCapacity, output_capacity: memory.outputCapacity,
            shares_input_storage: memory.sharesInputStorage,
            additional_element_capacity_bytes: memory.additionalElementCapacityBytes,
            allocated_before_bytes: memory.allocatedBefore, allocated_after_bytes: memory.allocatedAfter,
            elapsed_ns: elapsed, checksum: checksum, output_fingerprint: memory.fingerprint
        )
    }
}

@main
private struct Driver {
    static func main() {
        do {
            let args = CommandLine.arguments
            guard args.count == 5, let scope = Scope(rawValue: args[1]),
                  let pattern = Pattern(rawValue: args[2]), let count = Int(args[3]), count >= 0,
                  let iterations = Int(args[4]), iterations > 0 else {
                throw BenchmarkError("Usage: Driver <deduplicate|session> <unique|sparse|early|late|fourfold|all> <count >= 0> <iterations > 0>")
            }
            let measurement = try run(scope: scope, pattern: pattern, count: count, iterations: iterations)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(measurement)
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([10]))
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(1)
        }
    }
}
