import Foundation
import IlliquidCore
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

private let cases: [(Int, Bool)] = [
    (0, false), (1, false), (25, false), (25, true),
    (250, false), (250, true), (2_500, false), (2_500, true),
]

private func fixture(count: Int, rich: Bool) -> PlaybackSessionRecord {
    let folder = URL(fileURLWithPath: "/Synthetic/Illiquid checkpoint/日本語/Épisodes", isDirectory: true)
    let items = (0..<count).map { index in
        let url = folder.appendingPathComponent("Episode \(index) — café %25.mkv")
        return FolderPlaylistItem(
            url: url,
            externalSubtitleURLs: rich ? [
                url.deletingPathExtension().appendingPathExtension("日本語.ass"),
                url.deletingPathExtension().appendingPathExtension("en.srt"),
            ] : [],
            dateAdded: rich ? Date(timeIntervalSinceReferenceDate: 700_000_000 + Double(index)) : nil
        )
    }
    let playlist = rich ? Array(items.reversed()) : items
    return PlaybackSessionRecord(
        source: playlist.isEmpty
            ? .remoteStream(URL(string: "https://example.invalid/live.m3u8?name=synthetic%20fixture")!)
            : .localFile(playlist[count / 2].url),
        collectionFolder: playlist.isEmpty ? nil : folder,
        playlistItems: playlist,
        playlistIndex: playlist.isEmpty ? nil : count / 2,
        position: 42.125,
        wasPaused: rich,
        unshuffledPlaylistIDs: rich ? items.map(\.id) : nil,
        updatedAt: Date(timeIntervalSinceReferenceDate: 800_000_000)
    )
}

private func cpuTime() -> UInt64 {
    var value = timespec()
    precondition(clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &value) == 0)
    return UInt64(value.tv_sec) * 1_000_000_000 + UInt64(value.tv_nsec)
}

private func emit(_ value: [String: Any]) throws {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))
}

@main
private struct Harness {
    static func main() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let command = args.first else { preconditionFailure("Expected verify or bench") }
        if command == "verify" {
            precondition(args.count == 2)
            let directory = URL(fileURLWithPath: args[1], isDirectory: true)
            for (count, rich) in cases {
                let record = fixture(count: count, rich: rich)
                let file = directory.appendingPathComponent("\(count)-\(rich ? "rich" : "plain").json")
                let store = AtomicPlaybackSessionStore(fileURL: file)
                try store.save(record)
                let loaded = try store.load()
                precondition(loaded == record, "Production store round trip changed state")
                let saved = try Data(contentsOf: file)
                let encoded = try encodeSession(record)
                let savedJSON = try JSONSerialization.jsonObject(with: saved) as! NSDictionary
                let encodedJSON = try JSONSerialization.jsonObject(with: encoded) as! NSDictionary
                precondition(savedJSON == encodedJSON, "Extracted encoding probe differs from actual save")
                let decoded = try JSONDecoder().decode(PlaybackSessionRecord.self, from: encoded)
                precondition(decoded == record)
            }
            try emit(["cases": cases.count, "round_trips": cases.count * 2, "encoding_parity": true])
            return
        }
        precondition(command == "bench" && args.count == 6)
        let mode = args[1]
        let count = Int(args[2])!
        let rich = args[3] == "rich"
        let iterations = Int(args[4])!
        precondition(["save", "encode"].contains(mode) && cases.contains { $0.0 == count && $0.1 == rich })
        precondition((1...100_000).contains(iterations))
        let file = URL(fileURLWithPath: args[5]).appendingPathComponent("session.json")
        let store = AtomicPlaybackSessionStore(fileURL: file)
        var record = fixture(count: count, rich: rich)
        var data = Data()
        for _ in 0..<3 {
            if mode == "save" { try store.save(record) }
            else { data = try encodeSession(record) }
        }
        var checksum = 0
        let cpuStart = cpuTime()
        let start = DispatchTime.now().uptimeNanoseconds
        for index in 0..<iterations {
            record.position = Double(index) + 0.125
            record.updatedAt = Date(timeIntervalSinceReferenceDate: 800_000_000 + Double(index))
            if mode == "save" { try store.save(record) }
            else {
                data = try encodeSession(record)
                checksum &+= data.count
            }
        }
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        let cpu = cpuTime() - cpuStart
        // Decode and inspect complete values only after both clocks stop.
        if mode == "save" { data = try Data(contentsOf: file) }
        let decoded = try JSONDecoder().decode(PlaybackSessionRecord.self, from: data)
        precondition(decoded == record, "Timed output changed state")
        try emit([
            "mode": mode, "items": count, "rich": rich, "iterations": iterations,
            "elapsed_ns": elapsed, "cpu_ns": cpu, "encoded_bytes": data.count,
            "checksum": checksum, "final_position": decoded.position,
            "round_trip": true,
        ])
    }
}
