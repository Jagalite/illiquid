import Foundation
import IlliquidCore
@testable import IlliquidPlayer
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

private func cpuNanoseconds() -> UInt64 {
    var value = timespec()
    precondition(clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &value) == 0)
    return UInt64(value.tv_sec) * 1_000_000_000 + UInt64(value.tv_nsec)
}

private func fixture(scenario: String, count: Int) -> PlaybackCheckpoint {
    let folder = URL(fileURLWithPath: "/Volumes/Media/Series/Checkpoint Research", isDirectory: true)
    var items: [FolderPlaylistItem] = []
    items.reserveCapacity(count)
    for index in 0..<count {
        let name = index % 7 == 0 ? "Café 日本語 Episode \(index).mkv" : "Episode \(index).mkv"
        items.append(FolderPlaylistItem(
            url: folder.appendingPathComponent("Season \(index / 24 + 1)/" + name),
            externalSubtitleURLs: index % 5 == 0
                ? [folder.appendingPathComponent("Subtitles/Episode \(index).en.srt")] : [],
            dateAdded: Date(timeIntervalSince1970: Double(1_700_000_000 + index))
        ))
    }
    let location = scenario.split(separator: "-").last!
    let selection: Int?
    switch location {
    case "first": selection = items.indices.first
    case "middle": selection = items.isEmpty ? nil : items.count / 2
    case "last": selection = items.indices.last
    default: selection = nil
    }
    let source: MediaSource
    if scenario == "remote" {
        source = .remoteStream(URL(string: "https://media.example/live.m3u8")!)
    } else {
        source = .localFile(selection.map { items[$0].url }
            ?? folder.appendingPathComponent("Missing episode.mkv"))
    }
    return PlaybackCheckpoint(
        source: source,
        folder: scenario.hasPrefix("loose-") ? nil : folder,
        playlist: items,
        index: selection,
        position: 123.5,
        wasPaused: true,
        unshuffledPlaylistIDs: nil
    )
}

private func canonicalBytes(_ input: PlaybackSessionRecord) throws -> Data {
    var record = input
    record.updatedAt = Date(timeIntervalSince1970: 1_234)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(record)
    let decoded = try JSONDecoder().decode(PlaybackSessionRecord.self, from: data)
    precondition(decoded == record, "Record did not round-trip")
    let reencoded = try encoder.encode(decoded)
    precondition(reencoded == data, "Encoded representation changed on round-trip")
    return data
}

private func expectedFolder(scenario: String, count: Int) -> Bool {
    count > 0 && scenario.hasPrefix("folder-") && !scenario.hasSuffix("-missing")
}

// The measured implementation is in a separate optimized production module.
// Consume only inexpensive fields here; no URL normalization, JSON or I/O.
@inline(never)
private func measuredRecord(_ checkpoint: PlaybackCheckpoint) -> PlaybackSessionRecord {
    checkpoint.record()
}

private struct Measurement: Encodable {
    let scenario: String
    let count: Int
    let iterations: Int
    let wallNanoseconds: UInt64
    let cpuNanoseconds: UInt64
    let checksum: Int
    let resultCount: Int
    let retainsFolder: Bool
    let timestampInBounds: Bool
}

@main
private enum Driver {
    static func main() throws {
        let args = CommandLine.arguments
        precondition(args.count >= 5, "Usage: driver verify|measure scenario count output|iterations [last-output]")
        let mode = args[1], scenario = args[2]
        let validScenarios: Set<String> = [
            "folder-first", "folder-middle", "folder-last", "folder-missing",
            "loose-first", "loose-middle", "loose-last", "loose-missing", "remote",
        ]
        precondition(validScenarios.contains(scenario))
        let count = Int(args[3])!
        precondition((0...10_000).contains(count))
        let checkpoint = fixture(scenario: scenario, count: count)
        if mode == "verify" {
            let before = Date()
            let record = measuredRecord(checkpoint)
            let after = Date()
            precondition(record.updatedAt >= before && record.updatedAt <= after)
            precondition((record.collectionFolder != nil) == expectedFolder(scenario: scenario, count: count))
            precondition(record.playlistItems.count == count)
            precondition(record.source == checkpoint.source && record.playlistIndex == checkpoint.index)
            precondition(record.position == checkpoint.position && record.wasPaused == checkpoint.wasPaused)
            try canonicalBytes(record).write(to: URL(fileURLWithPath: args[4]))
            print("{\"verified\":true}")
            return
        }
        precondition(mode == "measure")
        let iterations = Int(args[4])!
        precondition(iterations > 0)
        // Warm allocation and Foundation paths without fixture work in timing.
        for _ in 0..<3 { _ = measuredRecord(checkpoint) }
        var last = measuredRecord(checkpoint)
        var checksum = 0
        let before = Date()
        let cpuStart = cpuNanoseconds()
        let wallStart = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<iterations {
            last = measuredRecord(checkpoint)
            checksum &+= last.playlistItems.count + (last.collectionFolder == nil ? 0 : 1)
                + (last.playlistIndex ?? -1) + Int(last.position)
        }
        let wall = DispatchTime.now().uptimeNanoseconds - wallStart
        let cpu = cpuNanoseconds() - cpuStart
        let after = Date()
        let fresh = last.updatedAt >= before && last.updatedAt <= after
        precondition(fresh)
        precondition((last.collectionFolder != nil) == expectedFolder(scenario: scenario, count: count))
        precondition(last.playlistItems.count == count)
        if args.count > 5 {
            // Compare the complete final timed result outside the clock too.
            try canonicalBytes(last).write(to: URL(fileURLWithPath: args[5]))
        }
        let result = Measurement(scenario: scenario, count: count, iterations: iterations,
            wallNanoseconds: wall, cpuNanoseconds: cpu, checksum: checksum,
            resultCount: last.playlistItems.count, retainsFolder: last.collectionFolder != nil,
            timestampInBounds: fresh)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        print(String(decoding: try encoder.encode(result), as: UTF8.self))
    }
}
