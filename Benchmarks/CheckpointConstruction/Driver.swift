import Dispatch
import Foundation
import IlliquidCore
@testable import IlliquidPlayer

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

private struct BenchmarkError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

@inline(__always)
private func releasingTemporaryObjects<T>(_ body: () throws -> T) rethrows -> T {
    #if canImport(Darwin)
    return try autoreleasepool(invoking: body)
    #else
    return try body()
    #endif
}

private let scenarios: Set<String> = [
    "no-folder-last", "folder-last", "no-folder-first", "folder-first",
    "folder-missing", "no-folder-missing", "folder-middle", "folder-unicode",
    "no-folder-unicode", "folder-unsupported-source", "folder-remote",
    "folder-invalid-items", "folder-mixed-items", "folder-duplicates",
]

private struct Fixture {
    let checkpoint: PlaybackCheckpoint
    let expected: PlaybackSessionRecord

    init(scenario: String, count: Int) throws {
        let unicode = scenario.hasSuffix("unicode")
        let duplicates = scenario == "folder-duplicates"
        let distinctCount = duplicates ? (count + 3) / 4 : count
        let rootPath = unicode ? "/Media/Caf\u{00E9}/Season" : "/Media/Library"
        let folder = scenario.hasPrefix("no-folder-") ? nil
            : URL(fileURLWithPath: rootPath, isDirectory: true)
        var items: [FolderPlaylistItem] = []
        items.reserveCapacity(count)
        for occurrence in 0..<count {
            let identity = duplicates ? occurrence % distinctCount : occurrence
            let local = URL(fileURLWithPath: "\(rootPath)/Episode \(identity).mkv")
            var url = local
            if unicode {
                url = URL(string: "file://LOCALHOST/Media/Cafe%CC%81/Season/../Season/Episode%20\(identity).mkv?restore=1#chapter")!
            } else if scenario == "folder-invalid-items"
                || (scenario == "folder-unsupported-source" && occurrence == count - 1)
                || (scenario == "folder-mixed-items" && occurrence != count - 1 && occurrence % 3 == 0) {
                url = URL(string: "file://archive.invalid/Media/Library/Episode%20\(identity).mkv")!
            } else if (scenario == "folder-remote" && occurrence == count - 1)
                || (scenario == "folder-mixed-items" && occurrence != count - 1 && occurrence % 3 == 1) {
                url = URL(string: "https://example.invalid/Media/Library/Episode%20\(identity).mkv")!
            }
            let subtitles = [URL(fileURLWithPath: "/Subtitles/\(occurrence)-2.srt"),
                             URL(fileURLWithPath: "/Subtitles/\(occurrence)-1.ass")]
            let date = Date(timeIntervalSince1970: 1_700_000_000 + Double(occurrence))
            if unicode {
                // Codable can preserve aliases that the normal initializer
                // canonicalizes. Keep the exact stored URL and metadata here.
                let bytes = try JSONSerialization.data(withJSONObject: [
                    "url": url.absoluteString,
                    "externalSubtitleURLs": subtitles.map(\.absoluteString),
                    "dateAdded": date.timeIntervalSinceReferenceDate,
                ])
                items.append(try JSONDecoder().decode(FolderPlaylistItem.self, from: bytes))
            } else {
                items.append(FolderPlaylistItem(url: url,
                    externalSubtitleURLs: subtitles, dateAdded: date))
            }
        }

        // The expected membership and first occurrences come from fixture
        // identities, without calling either production URL-comparison helper.
        let selected = count == 0 ? nil : scenario.hasSuffix("first") ? 0
            : scenario.hasSuffix("middle") ? count / 2 : count - 1
        let selectedIdentity = selected.map { duplicates ? $0 % distinctCount : $0 }
        var source: MediaSource = .localFile(URL(fileURLWithPath:
            "\(rootPath)/Episode \(selectedIdentity ?? -1).mkv"))
        var belongs = count > 0
        if scenario.hasSuffix("missing") {
            source = .localFile(URL(fileURLWithPath: "\(rootPath)/Missing.mkv"))
            belongs = false
        } else if scenario == "folder-unsupported-source" {
            source = .localFile(URL(string:
                "file://archive.invalid/Media/Library/Episode%20\(selectedIdentity ?? -1).mkv")!)
            belongs = false
        } else if scenario == "folder-remote" {
            source = .remoteStream(URL(string:
                "https://example.invalid/Media/Library/Episode%20\(selectedIdentity ?? -1).mkv")!)
            belongs = false
        } else if scenario == "folder-invalid-items" {
            belongs = false
        }
        let savedIndex = scenario.hasSuffix("missing") ? nil : selected
        let order: [String]? = count == 0 ? nil : [
            "\(rootPath)/Episode \(selectedIdentity!).mkv",
            "\(rootPath)/Episode 0.mkv", "removed-before-checkpoint",
        ]
        checkpoint = PlaybackCheckpoint(source: source, folder: folder, playlist: items,
            index: savedIndex, position: 42.25, wasPaused: !source.isRemote,
            unshuffledPlaylistIDs: order)
        // Initialize with no items, then assign the independently known output
        // so the expected playlist does not reuse production deduplication.
        var record = PlaybackSessionRecord(source: source,
            collectionFolder: belongs ? folder : nil, playlistItems: [],
            playlistIndex: savedIndex, position: 42.25, wasPaused: !source.isRemote,
            unshuffledPlaylistIDs: order, updatedAt: Self.fixedDate)
        record.playlistItems = duplicates ? Array(items.prefix(distinctCount)) : items
        expected = record
    }

    static let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
}

private func checksumComponent(_ record: PlaybackSessionRecord) -> UInt64 {
    let first = record.playlistItems.first?.dateAdded?.timeIntervalSince1970.bitPattern ?? 0
    let last = record.playlistItems.last?.dateAdded?.timeIntervalSince1970.bitPattern ?? 0
    return (UInt64(record.playlistItems.count) &* 0x9E37_79B9_7F4A_7C15)
        ^ first ^ (last &* 31) ^ record.position.bitPattern
        ^ UInt64(record.playlistIndex.map { $0 + 1 } ?? 0)
        ^ (record.collectionFolder == nil ? 0 : 0x100)
        ^ (record.wasPaused ? 0x200 : 0)
        ^ (record.source.isRemote ? 0x400 : 0)
        ^ UInt64(record.unshuffledPlaylistIDs?.count ?? 0)
}

// Separate compilation keeps the production call opaque to this driver. The
// result is consumed and released before returning; no output survives timing.
@inline(never)
private func constructAndRelease(_ checkpoint: PlaybackCheckpoint) -> UInt64 {
    releasingTemporaryObjects {
        let record = checkpoint.record()
        return checksumComponent(record)
    }
}

private func encoded(_ record: PlaybackSessionRecord) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(record)
}

private func validate(_ fixture: Fixture, expectedBytes: Data) throws -> String {
    try releasingTemporaryObjects {
        let earliest = Date()
        var record = fixture.checkpoint.record()
        let latest = Date()
        guard record.updatedAt >= earliest, record.updatedAt <= latest else {
            throw BenchmarkError("Checkpoint timestamp is outside its construction interval")
        }
        // Fix only the volatile timestamp, outside all timed operations.
        record.updatedAt = Fixture.fixedDate
        let bytes = try encoded(record)
        guard record == fixture.expected, bytes == expectedBytes else {
            throw BenchmarkError("Complete checkpoint output differs from the fixture oracle")
        }
        let hash = bytes.reduce(UInt64(14_695_981_039_346_656_037)) {
            ($0 ^ UInt64($1)) &* 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}

private func cpuNanoseconds() -> UInt64 {
    var value = timespec()
    precondition(clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &value) == 0)
    return UInt64(value.tv_sec) * 1_000_000_000 + UInt64(value.tv_nsec)
}

private struct Measurement: Encodable {
    let scenario: String
    let count: Int
    let iterations: Int
    let elapsed_ns: UInt64
    let cpu_ns: UInt64
    let checksum: UInt64
    let output_fingerprint: String
    let output_count: Int
    let validation_count: Int
}

@main
private struct Driver {
    static func main() {
        do {
            let args = CommandLine.arguments
            guard args.count == 4, scenarios.contains(args[1]),
                  let count = Int(args[2]), count >= 0,
                  let iterations = Int(args[3]), iterations > 0 else {
                throw BenchmarkError("Usage: Driver <scenario> <count >= 0> <iterations > 0>")
            }
            let fixture = try releasingTemporaryObjects { try Fixture(scenario: args[1], count: count) }
            let expectedBytes = try encoded(fixture.expected)
            let fingerprint = try validate(fixture, expectedBytes: expectedBytes)
            for _ in 0..<2 { _ = constructAndRelease(fixture.checkpoint) }
            var checksum: UInt64 = 0
            let cpuStart = cpuNanoseconds()
            let wallStart = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<iterations { checksum &+= constructAndRelease(fixture.checkpoint) }
            let elapsed = DispatchTime.now().uptimeNanoseconds - wallStart
            let cpuElapsed = cpuNanoseconds() - cpuStart
            let finalFingerprint = try validate(fixture, expectedBytes: expectedBytes)
            guard checksum == checksumComponent(fixture.expected) &* UInt64(iterations),
                  finalFingerprint == fingerprint else {
                throw BenchmarkError("Timed checkpoint outputs failed their checksum")
            }
            let result = Measurement(scenario: args[1], count: count, iterations: iterations,
                elapsed_ns: elapsed, cpu_ns: cpuElapsed, checksum: checksum,
                output_fingerprint: fingerprint, output_count: fixture.expected.playlistItems.count,
                validation_count: 2)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            FileHandle.standardOutput.write(try encoder.encode(result))
            FileHandle.standardOutput.write(Data([10]))
            withExtendedLifetime(fixture) {}
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(1)
        }
    }
}
