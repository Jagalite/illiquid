import Foundation
import Darwin
import IlliquidCore
@testable import IlliquidPlayer

private enum Failure: Error {
    case invalid(String)
}

private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw Failure.invalid(message) }
}

@inline(never)
private func construct(_ checkpoint: PlaybackCheckpoint) -> PlaybackSessionRecord {
    checkpoint.record()
}

private func originalRecord(_ checkpoint: PlaybackCheckpoint) -> PlaybackSessionRecord {
    let belongsToFolder = checkpoint.source.url.isFileURL && checkpoint.playlist.contains {
        NormalizedFileURL.representsSameFile($0.url, checkpoint.source.url)
    }
    return PlaybackSessionRecord(
        source: checkpoint.source,
        collectionFolder: belongsToFolder ? checkpoint.folder : nil,
        playlistItems: checkpoint.playlist,
        playlistIndex: checkpoint.index,
        position: checkpoint.position,
        wasPaused: checkpoint.wasPaused,
        unshuffledPlaylistIDs: checkpoint.unshuffledPlaylistIDs,
        updatedAt: fixedDate
    )
}

private func normalized(_ record: PlaybackSessionRecord) -> PlaybackSessionRecord {
    var copy = record
    // Date() still executes in the timed production method. Normalize only
    // its nondeterministic value for complete-record comparisons.
    copy.updatedAt = fixedDate
    return copy
}

private func encoded(_ value: PlaybackSessionRecord) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
}

private func fingerprint(_ bytes: Data) -> String {
    var value: UInt64 = 14_695_981_039_346_656_037
    for byte in bytes { value = (value ^ UInt64(byte)) &* 1_099_511_628_211 }
    return String(value, radix: 16)
}

private func receipt(_ checkpoint: PlaybackCheckpoint) throws -> (record: PlaybackSessionRecord, bytes: Data) {
    let actual = normalized(construct(checkpoint))
    let expected = originalRecord(checkpoint)
    try require(actual == expected, "complete checkpoint record differs from original behavior")
    let actualBytes = try encoded(actual)
    let expectedBytes = try encoded(expected)
    try require(actualBytes == expectedBytes, "normalized encoded checkpoint differs")
    return (actual, actualBytes)
}

private func checksumPart(_ result: PlaybackSessionRecord) -> UInt64 {
    UInt64(result.playlistItems.count) &* 31
        &+ (result.collectionFolder == nil ? 3 : 7)
        &+ UInt64(bitPattern: Int64(result.playlistIndex ?? -1))
        &+ (result.wasPaused ? 17 : 19)
        &+ UInt64(result.position)
}

private func cpuNanoseconds() -> UInt64 {
    var time = timespec()
    precondition(clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &time) == 0)
    return UInt64(time.tv_sec) * 1_000_000_000 + UInt64(time.tv_nsec)
}

private func makeCheckpoint(count: Int, pattern: String) throws -> PlaybackCheckpoint {
    try require(count >= 0, "count must be nonnegative")
    let folder = URL(fileURLWithPath: "/Volumes/Media/IlliquidCheckpointStudy", isDirectory: true)
    var items: [FolderPlaylistItem] = []
    items.reserveCapacity(count)
    for i in 0..<count {
        let url = folder.appendingPathComponent("Episode-\(i)-A-longish-media-title.mkv")
        let subtitles = i % 4 == 0 ? [url.deletingPathExtension().appendingPathExtension("en.srt")] : []
        items.append(FolderPlaylistItem(url: url, externalSubtitleURLs: subtitles,
            dateAdded: fixedDate.addingTimeInterval(Double(i))))
    }
    if count == 0 {
        try require(pattern == "empty", "only the empty control has no items")
        return PlaybackCheckpoint(source: .localFile(folder.appendingPathComponent("Missing.mkv")),
            folder: folder, playlist: [], index: nil, position: 123.25,
            wasPaused: true, unshuffledPlaylistIDs: nil)
    }
    var selected = count - 1
    if pattern == "first" || pattern == "stale-first" { selected = 0 }
    if pattern == "middle" { selected = count / 2 }
    var source: MediaSource = .localFile(items[selected].url)
    var index: Int? = selected
    var collectionFolder: URL? = folder
    switch pattern {
    case "first", "middle", "last": break
    case "no-folder": collectionFolder = nil
    case "nil-index": index = nil
    case "stale-index": index = 0
    case "stale-first": index = count - 1
    case "out-of-range-index": index = count
    case "missing": source = .localFile(folder.appendingPathComponent("Missing.mkv"))
    case "remote": source = .remoteStream(URL(string: "https://example.invalid/media.mkv")!)
    default: throw Failure.invalid("unknown pattern \(pattern)")
    }
    return PlaybackCheckpoint(source: source, folder: collectionFolder, playlist: items,
        index: index, position: 123.25, wasPaused: true,
        unshuffledPlaylistIDs: [items.last!.id, items.first!.id])
}

private func decodedItem(_ url: URL) throws -> FolderPlaylistItem {
    let data = try JSONSerialization.data(withJSONObject: [
        "url": url.absoluteString, "externalSubtitleURLs": [String]()
    ] as [String: Any])
    return try JSONDecoder().decode(FolderPlaylistItem.self, from: data)
}

private func verifyCases() throws -> [Data] {
    var cases: [PlaybackCheckpoint] = []
    for count in [1, 16, 256] {
        for pattern in ["first", "middle", "last", "no-folder", "nil-index", "stale-index",
                        "stale-first", "out-of-range-index", "missing", "remote"] {
            cases.append(try makeCheckpoint(count: count, pattern: pattern))
        }
    }
    cases.append(try makeCheckpoint(count: 0, pattern: "empty"))
    let directory = URL(fileURLWithPath: "/Media/Caf\u{00e9}", isDirectory: true)
    let first = FolderPlaylistItem(url: directory.appendingPathComponent("First.mkv"),
        externalSubtitleURLs: [directory.appendingPathComponent("First.en.srt")], dateAdded: fixedDate)
    let match = FolderPlaylistItem(url: directory.appendingPathComponent("Episode.mkv"),
        externalSubtitleURLs: [directory.appendingPathComponent("Episode.fr.srt")],
        dateAdded: fixedDate.addingTimeInterval(1))
    let duplicate = FolderPlaylistItem(url: match.url,
        externalSubtitleURLs: [directory.appendingPathComponent("Episode.de.srt")],
        dateAdded: fixedDate.addingTimeInterval(2))
    let remoteItem = FolderPlaylistItem(url: URL(string: "https://example.invalid/remote.mkv")!)
    let unsupportedItem = FolderPlaylistItem(url: URL(string: "file://remote.invalid/Media/Episode.mkv")!)
    let alias = try decodedItem(URL(string: "file://localhost/Media/Cafe%CC%81/Season/../Episode.mkv")!)
    let patterns: [[FolderPlaylistItem]] = [[], [match], [first, match], [first, match, duplicate],
        [remoteItem, match, unsupportedItem], [unsupportedItem], [first, alias]]
    let sources: [MediaSource] = [
        .localFile(match.url),
        .localFile(URL(fileURLWithPath: "/Media/Cafe\u{0301}/./Episode.mkv")),
        .localFile(URL(string: "file://localhost/Media/Caf%C3%A9/Episode.mkv")!),
        .localFile(URL(fileURLWithPath: "/Media/Missing.mkv")),
        .localFile(URL(string: "file://remote.invalid/Media/Episode.mkv")!),
        .localFile(URL(string: "file://user@localhost/Media/Episode.mkv")!),
        .localFile(URL(string: "file://localhost:123/Media/Episode.mkv")!),
        .localFile(URL(string: "https://example.invalid/remote.mkv")!),
        .remoteStream(URL(string: "https://example.invalid/remote.mkv")!),
        .remoteStream(match.url),
    ]
    for items in patterns {
        for source in sources {
            for index in [nil, Int.min, -1, 0, 1, 2, items.count, Int.max] as [Int?] {
                for folder in [directory, nil] as [URL?] {
                    cases.append(PlaybackCheckpoint(source: source, folder: folder, playlist: items,
                        index: index, position: 45.5, wasPaused: false,
                        unshuffledPlaylistIDs: [match.id, first.id]))
                }
            }
        }
    }
    for position in [-12.0, Double.nan, Double.infinity, -Double.infinity] {
        cases.append(PlaybackCheckpoint(source: .localFile(match.url), folder: directory,
            playlist: [match], index: 0, position: position, wasPaused: true,
            unshuffledPlaylistIDs: nil))
    }
    return try cases.map { try receipt($0).bytes }
}

@main
private struct Main {
    static func main() throws {
        let args = CommandLine.arguments
        if args.count == 2 && args[1] == "--verify" {
            let records = try verifyCases()
            let result: [String: Any] = [
                "cases": records.count, "passed": true,
                // The runner compares complete bytes, not only fingerprints.
                "records": records.map { $0.base64EncodedString() }
            ]
            print(String(decoding: try JSONSerialization.data(withJSONObject: result,
                options: [.sortedKeys]), as: UTF8.self))
            return
        }
        guard args.count == 4, let count = Int(args[1]), let iterations = Int(args[3]), iterations > 0 else {
            throw Failure.invalid("usage: driver COUNT PATTERN ITERATIONS or --verify")
        }
        let pattern = args[2]
        let checkpoint = try makeCheckpoint(count: count, pattern: pattern)
        let before = try receipt(checkpoint)
        let expectedPart = checksumPart(before.record)
        var warmup: UInt64 = 0
        for _ in 0..<4 { warmup &+= checksumPart(construct(checkpoint)) }
        try require(warmup == expectedPart &* 4, "warmup checksum mismatch")
        var checksum: UInt64 = 0
        let wallStart = DispatchTime.now().uptimeNanoseconds
        let cpuStart = cpuNanoseconds()
        for _ in 0..<iterations {
            checksum &+= checksumPart(construct(checkpoint))
        }
        let cpuElapsed = cpuNanoseconds() - cpuStart
        let wallElapsed = DispatchTime.now().uptimeNanoseconds - wallStart
        try require(checksum == expectedPart &* UInt64(iterations), "timed checksum mismatch")
        let after = try receipt(checkpoint)
        try require(before.record == after.record && before.bytes == after.bytes, "record changed during timing")
        let result: [String: Any] = [
            "count": count, "pattern": pattern, "iterations": iterations,
            "cpu_ns": cpuElapsed, "wall_ns": wallElapsed, "checksum": String(checksum),
            "fingerprint": fingerprint(after.bytes), "output_count": after.record.playlistItems.count,
            "has_collection_folder": after.record.collectionFolder != nil
        ]
        print(String(decoding: try JSONSerialization.data(withJSONObject: result,
            options: [.sortedKeys]), as: UTF8.self))
    }
}
