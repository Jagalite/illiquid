import Dispatch
import Foundation
import IlliquidCore
@testable import IlliquidPlayer
#if os(Linux)
import Glibc
#else
import Darwin
#endif

private func cpuNanoseconds() -> UInt64 {
    var value = timespec()
    precondition(clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &value) == 0)
    return UInt64(value.tv_sec) * 1_000_000_000 + UInt64(value.tv_nsec)
}

private func fixture(count: Int, kind: String) -> PlaybackCheckpoint {
    let folder = URL(fileURLWithPath: "/Illiquid Benchmark/Series", isDirectory: true)
    let items = (0..<count).map { index in
        FolderPlaylistItem(
            url: folder.appendingPathComponent("Episode \(index).mkv"),
            externalSubtitleURLs: index % 16 == 0
                ? [folder.appendingPathComponent("Episode \(index).en.srt")] : [],
            dateAdded: Date(timeIntervalSince1970: Double(index))
        )
    }
    let selected: Int?
    switch kind {
    case "first": selected = count > 0 ? 0 : nil
    case "middle": selected = count > 0 ? count / 2 : nil
    case "last": selected = count > 0 ? count - 1 : nil
    case "missing", "remote", "invalid": selected = nil
    default: preconditionFailure("Unknown workload")
    }
    let source: MediaSource
    if kind == "remote" {
        source = .remoteStream(URL(string: "https://example.invalid/video.mkv")!)
    } else if kind == "invalid" {
        source = .localFile(URL(string: "file://server/Illiquid%20Benchmark/Series/Episode%200.mkv")!)
    } else {
        source = .localFile(selected.map { items[$0].url }
            ?? folder.appendingPathComponent("Missing.mkv"))
    }
    return PlaybackCheckpoint(
        source: source, folder: folder, playlist: items, index: selected,
        position: 42.25, wasPaused: true,
        unshuffledPlaylistIDs: count == 0 ? nil : [items[0].id]
    )
}

private func canonical(_ record: PlaybackSessionRecord) throws -> String {
    var normalized = record
    // Date() is intentionally part of the timed production operation. Only
    // verification removes its nondeterministic value.
    normalized.updatedAt = Date(timeIntervalSince1970: 1_700_000_000)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return String(decoding: try encoder.encode(normalized), as: UTF8.self)
}

private func fingerprint(_ text: String) -> String {
    var value: UInt64 = 14_695_981_039_346_656_037
    for byte in text.utf8 { value = (value ^ UInt64(byte)) &* 1_099_511_628_211 }
    return String(value)
}

@inline(never)
private func consume(_ record: PlaybackSessionRecord) -> UInt64 {
    UInt64(record.playlistItems.count) &+ record.position.bitPattern
        &+ (record.collectionFolder == nil ? 0 : 1) &+ (record.wasPaused ? 2 : 0)
}

@main
private enum Main {
    static func main() throws {
        let arguments = CommandLine.arguments
        precondition(arguments.count >= 4, "verify|measure COUNT KIND [ITERATIONS]")
        let mode = arguments[1]
        let count = Int(arguments[2])!
        let kind = arguments[3]
        precondition(count >= 0)
        let input = fixture(count: count, kind: kind)
        let warmup = input.record()
        let expectedFolder = count > 0 && ["first", "middle", "last"].contains(kind)
            ? input.folder : nil
        var expected = PlaybackSessionRecord(
            source: input.source, collectionFolder: expectedFolder,
            playlistItems: input.playlist, playlistIndex: input.index,
            position: input.position, wasPaused: input.wasPaused,
            unshuffledPlaylistIDs: input.unshuffledPlaylistIDs
        )
        expected.updatedAt = warmup.updatedAt
        precondition(warmup == expected, "Independent full-record expectation failed")
        let fullRecord = try canonical(warmup)
        var output: [String: Any] = [
            "count": count, "kind": kind,
            "output_fingerprint": fingerprint(fullRecord),
            "warmup_checksum": String(consume(warmup)),
            "output_count": warmup.playlistItems.count,
            "belongs_to_folder": warmup.collectionFolder != nil,
        ]
        if mode == "verify" {
            output["record"] = fullRecord
        } else {
            precondition(mode == "measure" && arguments.count == 5)
            let iterations = Int(arguments[4])!
            precondition(iterations > 0)
            var checksum: UInt64 = 0
            let cpuStart = cpuNanoseconds()
            let start = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<iterations {
                checksum &+= consume(input.record())
            }
            let elapsed = DispatchTime.now().uptimeNanoseconds - start
            let cpu = cpuNanoseconds() - cpuStart
            precondition(checksum == consume(warmup) &* UInt64(iterations))
            output["iterations"] = iterations
            output["elapsed_ns"] = elapsed
            output["cpu_ns"] = cpu
            output["checksum"] = String(checksum)
        }
        let data = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
