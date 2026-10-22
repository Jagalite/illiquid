import Foundation
import IlliquidCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Fixture construction, decoding, and JSON comparison are outside the timer.
@main
enum SessionCheckpointBenchmark {
    static func main() throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 7,
              let count = Int(arguments[2]), count >= 0,
              let iterations = Int(arguments[4]), iterations > 0 else {
            fatalError("usage: benchmark <save|encode> <count> <plain|rich> <iterations> <baseline|candidate> <output-dir>")
        }
        let mode = arguments[1]
        let rich = arguments[3] == "rich"
        let baseline = arguments[5] == "baseline"
        let directory = URL(fileURLWithPath: arguments[6], isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Start with an absent nested directory; the production store creates it.
        let store = AtomicPlaybackSessionStore(fileURL: directory.appendingPathComponent("state/session.json"))
        var record = makeRecord(count: count, rich: rich)

        func encode(_ value: PlaybackSessionRecord) throws -> Data {
            let encoder = JSONEncoder()
            if baseline { encoder.outputFormatting = [.sortedKeys] }
            return try encoder.encode(value)
        }

        // Establish the steady overwrite workload and warm Foundation in both modes.
        for _ in 0..<3 {
            if mode == "save" { try store.save(record) }
            else { _ = try encode(record) }
        }
        var finalData = Data()
        var bytesEncoded = 0
        let cpuStart = clock()
        let wallStart = DispatchTime.now().uptimeNanoseconds
        for index in 0..<iterations {
            record.position = 42.5 + Double(index % 360)
            if mode == "save" {
                try store.save(record)
            } else {
                finalData = try encode(record)
                bytesEncoded &+= finalData.count
            }
        }
        let wallNanoseconds = DispatchTime.now().uptimeNanoseconds - wallStart
        let cpuSeconds = Double(clock() - cpuStart) / Double(CLOCKS_PER_SEC)

        if mode == "save" { finalData = try Data(contentsOf: store.fileURL) }
        let decoded = try JSONDecoder().decode(PlaybackSessionRecord.self, from: finalData)
        precondition(decoded == record, "complete decoded record changed")
        precondition(decoded.playlistItems.map(\.url) == record.playlistItems.map(\.url))
        precondition(decoded.playlistItems.map(\.externalSubtitleURLs) == record.playlistItems.map(\.externalSubtitleURLs))
        precondition(decoded.unshuffledPlaylistIDs == record.unshuffledPlaylistIDs)
        if mode == "save" {
            let loaded = try store.load()
            precondition(loaded == record, "production load changed the record")
            try store.clear()
        }
        // Python compares these complete documents between separately built variants.
        try finalData.write(to: directory.appendingPathComponent("payload.json"))
        let receipt: [String: Any] = [
            "mode": mode, "count": count, "rich": rich,
            "iterations": iterations, "variant": arguments[5],
            "wall_ns_per_save": Double(wallNanoseconds) / Double(iterations),
            "cpu_ns_per_save": cpuSeconds * 1_000_000_000 / Double(iterations),
            "payload_bytes": finalData.count, "encoded_bytes_checksum": bytesEncoded,
            "roundtrip_passed": true,
        ]
        let output = try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys])
        print(String(decoding: output, as: UTF8.self))
    }

    private static func makeRecord(count: Int, rich: Bool) -> PlaybackSessionRecord {
        let folder = URL(fileURLWithPath: rich
            ? "/Volumes/Media/映画 Café 雨/Season \"One\" % #/Long folder name with spaces"
            : "/Volumes/Media/Series", isDirectory: true)
        var items: [FolderPlaylistItem] = []
        for index in 0..<count {
            let stem = rich ? "Episode \(index) — 雨 e\u{301} quote\" slash\\ percent%" : "Episode \(index)"
            items.append(FolderPlaylistItem(
                url: folder.appendingPathComponent(stem + ".mkv"),
                externalSubtitleURLs: rich ? [
                    folder.appendingPathComponent(stem + ".日本語.srt"),
                    folder.appendingPathComponent(stem + ".en.srt"),
                ] : [],
                dateAdded: rich && index % 3 != 0
                    ? Date(timeIntervalSince1970: 1_700_000_000 + Double(index)) : nil
            ))
        }
        let originalIDs = rich ? items.map(\.id) : nil
        if rich { items.reverse() }
        return PlaybackSessionRecord(
            source: items.first.map { .localFile($0.url) }
                ?? .remoteStream(URL(string: "https://example.invalid/live.m3u8?name=rain%20snow")!),
            collectionFolder: count > 0 ? folder : nil,
            playlistItems: items,
            playlistIndex: count > 0 ? 0 : nil,
            position: 42.5,
            wasPaused: rich,
            unshuffledPlaylistIDs: originalIDs,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_123.25)
        )
    }
}
