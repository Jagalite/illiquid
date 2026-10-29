import Foundation
import IlliquidCore
@testable import IlliquidPlayer

private struct Workload: Sendable {
    let name: String
    let count: Int
    let target: String
    let hint: String
    var hasFolder = true
    var unicode = false
    var invalidItems = false
    var duplicates = false
}

private let workloads: [Workload] = [
    .init(name: "empty", count: 0, target: "missing", hint: "none"),
    .init(name: "singleton-hit", count: 1, target: "first", hint: "first"),
    .init(name: "first-32", count: 32, target: "first", hint: "first"),
    .init(name: "middle-32", count: 32, target: "middle", hint: "middle"),
    .init(name: "last-32", count: 32, target: "last", hint: "last"),
    .init(name: "first-1000", count: 1000, target: "first", hint: "first"),
    .init(name: "middle-1000", count: 1000, target: "middle", hint: "middle"),
    .init(name: "last-1000", count: 1000, target: "last", hint: "last"),
    .init(name: "last-10000", count: 10000, target: "last", hint: "last"),
    .init(name: "nil-hint-1000", count: 1000, target: "last", hint: "none"),
    .init(name: "stale-first-hint-1000", count: 1000, target: "last", hint: "first"),
    .init(name: "stale-last-hint-first-hit-32", count: 32, target: "first", hint: "last"),
    .init(name: "negative-hint-1000", count: 1000, target: "last", hint: "negative"),
    .init(name: "oversized-hint-1000", count: 1000, target: "last", hint: "oversized"),
    .init(name: "missing-32", count: 32, target: "missing", hint: "first"),
    .init(name: "missing-1000", count: 1000, target: "missing", hint: "last"),
    .init(name: "no-folder-1000", count: 1000, target: "last", hint: "last", hasFolder: false),
    .init(name: "no-folder-10000", count: 10000, target: "last", hint: "last", hasFolder: false),
    .init(name: "unicode-last-1000", count: 1000, target: "last", hint: "last", unicode: true),
    .init(name: "duplicates-1000", count: 1000, target: "last", hint: "last", duplicates: true),
    .init(name: "remote-source-1000", count: 1000, target: "remote", hint: "first"),
    .init(name: "unsupported-file-source-1000", count: 1000, target: "unsupported", hint: "first"),
    .init(name: "unsupported-items-1000", count: 1000, target: "missing", hint: "none", invalidItems: true),
]

private struct Fixture {
    let checkpoint: PlaybackCheckpoint
    let expectedFolder: URL?
    let expectedCount: Int
}

private func fixture(for workload: Workload) -> Fixture {
    let folder = URL(fileURLWithPath: "/CheckpointBenchmark", isDirectory: true)
    func url(_ index: Int) -> URL {
        if workload.invalidItems {
            return URL(string: "https://example.invalid/episode-\(index).mkv")!
        }
        let name = workload.unicode
            ? "Séries/日本語/Long descriptive épisode \(index) — café.mkv"
            : "episode-\(index).mkv"
        return folder.appendingPathComponent(name, isDirectory: false)
    }
    var items = (0..<workload.count).map {
        FolderPlaylistItem(
            url: url($0),
            externalSubtitleURLs: [folder.appendingPathComponent("subtitle-\($0).srt")],
            dateAdded: Date(timeIntervalSince1970: Double($0))
        )
    }
    if workload.duplicates {
        for index in stride(from: 0, to: workload.count, by: 4) {
            items.append(FolderPlaylistItem(
                url: url(index),
                externalSubtitleURLs: [folder.appendingPathComponent("conflicting.srt")],
                dateAdded: .distantFuture
            ))
        }
    }

    let source: MediaSource
    let sourceIsPresent: Bool
    switch workload.target {
    case "first":
        source = .localFile(url(0))
        sourceIsPresent = workload.count > 0 && !workload.invalidItems
    case "middle":
        source = .localFile(url(workload.count / 2))
        sourceIsPresent = workload.count > 0 && !workload.invalidItems
    case "last":
        source = .localFile(url(workload.count - 1))
        sourceIsPresent = workload.count > 0 && !workload.invalidItems
    case "remote":
        source = .remoteStream(URL(string: "https://example.invalid/live.m3u8")!)
        sourceIsPresent = false
    case "unsupported":
        source = .localFile(URL(string: "file://remote.invalid/CheckpointBenchmark/episode-0.mkv")!)
        sourceIsPresent = false
    default:
        source = .localFile(folder.appendingPathComponent("missing.mkv"))
        sourceIsPresent = false
    }

    let index: Int?
    switch workload.hint {
    case "first": index = 0
    case "middle": index = workload.count / 2
    case "last": index = workload.count - 1
    case "negative": index = Int.min
    case "oversized": index = Int.max
    default: index = nil
    }
    return Fixture(
        checkpoint: PlaybackCheckpoint(
            source: source, folder: workload.hasFolder ? folder : nil,
            playlist: items, index: index, position: 42.5, wasPaused: true,
            unshuffledPlaylistIDs: workload.count > 0 ? [items[0].id] : nil
        ),
        expectedFolder: workload.hasFolder && sourceIsPresent ? folder : nil,
        expectedCount: workload.count
    )
}

private struct Observation: Encodable {
    let workload: String
    let iterations: Int
    let elapsedNanoseconds: UInt64
    let checksum: UInt64
    let resultFingerprint: String
    let inputCount: Int
    let outputCount: Int
    let hasCollectionFolder: Bool
}

// Keep every returned record observable without adding URL normalization or
// JSON encoding to the measured interval.
@inline(never)
private func contribution(_ record: PlaybackSessionRecord) -> UInt64 {
    UInt64(record.playlistItems.count)
        &+ UInt64(truncatingIfNeeded: record.playlistIndex ?? -1)
        &+ UInt64(record.position)
        &+ (record.collectionFolder == nil ? 0 : 1)
        &+ (record.wasPaused ? 1 : 0)
        &+ UInt64(record.unshuffledPlaylistIDs?.count ?? 0)
}

private func measure(_ workload: Workload, iterations: Int) throws -> Observation {
    let input = fixture(for: workload)
    var warmup = input.checkpoint.record()
    precondition(warmup.collectionFolder == input.expectedFolder)
    precondition(warmup.playlistItems.count == input.expectedCount)
    precondition(warmup.source == input.checkpoint.source)
    precondition(warmup.playlistIndex == input.checkpoint.index)
    precondition(warmup.position == 42.5 && warmup.wasPaused)
    precondition(warmup.unshuffledPlaylistIDs == input.checkpoint.unshuffledPlaylistIDs)
    let expectedContribution = contribution(warmup)
    // Date() is part of production construction. Only the untimed comparison
    // record gets a fixed timestamp so baseline/candidate digests can agree.
    warmup.updatedAt = Date(timeIntervalSince1970: 0)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    // Portable deterministic fingerprint of the complete untimed record.
    // Independent XCTest assertions compare complete records and JSON round trips.
    let digestValue = try encoder.encode(warmup).reduce(UInt64(14695981039346656037)) {
        ($0 ^ UInt64($1)) &* 1099511628211
    }
    let digest = String(digestValue, radix: 16)

    var checksum: UInt64 = 0
    let start = DispatchTime.now().uptimeNanoseconds
    for _ in 0..<iterations {
        let record = input.checkpoint.record()
        checksum &+= contribution(record)
    }
    let elapsed = DispatchTime.now().uptimeNanoseconds - start
    precondition(checksum == expectedContribution &* UInt64(iterations))
    return Observation(
        workload: workload.name, iterations: iterations,
        elapsedNanoseconds: elapsed, checksum: checksum, resultFingerprint: digest,
        inputCount: input.checkpoint.playlist.count,
        outputCount: input.expectedCount,
        hasCollectionFolder: input.expectedFolder != nil
    )
}

@main
private enum CheckpointBenchmark {
    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if arguments == ["--list"] {
            print(String(decoding: try encoder.encode(workloads.map(\.name)), as: UTF8.self))
            return
        }
        guard arguments.count == 2,
              let workload = workloads.first(where: { $0.name == arguments[0] }),
              let iterations = Int(arguments[1]), iterations > 0 else {
            fatalError("Usage: CheckpointBenchmark --list | WORKLOAD ITERATIONS")
        }
        let result = try measure(workload, iterations: iterations)
        print(String(decoding: try encoder.encode(result), as: UTF8.self))
    }
}
