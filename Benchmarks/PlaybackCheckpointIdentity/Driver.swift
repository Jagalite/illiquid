import Foundation
import Dispatch
#if os(Linux)
import Glibc
#else
import Darwin
#endif
import IlliquidCore
@testable import IlliquidPlayer

// The production implementation is compiled in a separate module without
// cross-module optimization. This observer cannot eliminate its work.
@inline(never)
private func construct(_ checkpoint: PlaybackCheckpoint) -> PlaybackSessionRecord {
    checkpoint.record()
}

private func canonicalBytes(_ record: PlaybackSessionRecord) throws -> Data {
    var record = record
    // Construction intentionally reads Date(). Normalize only that volatile
    // field; every other persisted field participates in byte-for-byte parity.
    record.updatedAt = Date(timeIntervalSince1970: 1_700_000_000)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(record)
}

private func fingerprint(_ bytes: Data) -> String {
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in bytes { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
    return String(hash, radix: 16)
}

private struct Fixture {
    let checkpoint: PlaybackCheckpoint
    let expected: PlaybackSessionRecord

    init(count: Int, scenario: String) {
        let folder = URL(fileURLWithPath: "/Media/Season", isDirectory: true)
        var items = (0..<count).map { index in
            FolderPlaylistItem(
                url: folder.appendingPathComponent("Feature-\(index)-Café.mkv"),
                externalSubtitleURLs: [folder.appendingPathComponent("Feature-\(index).en.srt")],
                dateAdded: Date(timeIntervalSince1970: Double(index))
            )
        }
        var seed: UInt64 = 0x86_54_25_31
        if items.count > 1 {
            for index in stride(from: items.count - 1, through: 1, by: -1) {
                seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                items.swapAt(index, Int((seed >> 32) % UInt64(index + 1)))
            }
        }
        let index: Int?
        switch scenario {
        case "first-hit": index = items.isEmpty ? nil : 0
        case "middle-hit": index = items.isEmpty ? nil : items.count / 2
        case "late-hit", "nil-folder": index = items.isEmpty ? nil : items.count - 1
        case "missing", "remote": index = nil
        default: preconditionFailure("Unknown fixture")
        }
        let source: MediaSource = scenario == "remote"
            ? .remoteStream(URL(string: "https://example.invalid/stream.mp4?track=1")!)
            : .localFile(index.map { items[$0].url } ?? folder.appendingPathComponent("absent.mkv"))
        let unshuffled = items.isEmpty ? nil : items.reversed().map(\.id)
        checkpoint = PlaybackCheckpoint(
            source: source, folder: scenario == "nil-folder" ? nil : folder,
            playlist: items, index: index, position: 123.75, wasPaused: true,
            unshuffledPlaylistIDs: unshuffled
        )
        // Membership is known from fixture construction; do not reproduce the
        // production normalized-URL predicate in the expected result.
        expected = PlaybackSessionRecord(
            source: source, collectionFolder: scenario != "nil-folder" && index != nil ? folder : nil,
            playlistItems: items, playlistIndex: index, position: 123.75,
            wasPaused: true, unshuffledPlaylistIDs: unshuffled
        )
    }
}

private struct AllocationMeter {
    typealias Action = @convention(c) () -> Void
    typealias Count = @convention(c) () -> UInt64
    let begin: Action?
    let end: Action?
    let requests: Count?
    let bytes: Count?

    init() {
        #if os(Linux)
        begin = dlsym(nil, "meter_begin").map { unsafeBitCast($0, to: Action.self) }
        end = dlsym(nil, "meter_end").map { unsafeBitCast($0, to: Action.self) }
        requests = dlsym(nil, "meter_requests").map { unsafeBitCast($0, to: Count.self) }
        bytes = dlsym(nil, "meter_bytes").map { unsafeBitCast($0, to: Count.self) }
        #else
        begin = nil; end = nil; requests = nil; bytes = nil
        #endif
    }
}

@main
private enum Driver {
    static func main() throws {
        guard CommandLine.arguments.count == 5,
              let count = Int(CommandLine.arguments[1]), count >= 0,
              let iterations = Int(CommandLine.arguments[3]), iterations > 0
        else { fatalError("Usage: driver COUNT SCENARIO ITERATIONS timing|allocations") }
        let scenario = CommandLine.arguments[2]
        let mode = CommandLine.arguments[4]
        precondition(mode == "timing" || mode == "allocations")
        let meter = AllocationMeter()
        if mode == "allocations" {
            precondition(meter.begin != nil && meter.end != nil && meter.requests != nil && meter.bytes != nil,
                         "Allocation mode requires the Linux/glibc interposer")
        } else {
            precondition(meter.begin == nil, "Timing must not run under the allocation interposer")
        }
        let fixture = Fixture(count: count, scenario: scenario)
        let expectedBytes = try canonicalBytes(fixture.expected)
        let warm = construct(fixture.checkpoint)
        let warmBytes = try canonicalBytes(warm)
        precondition(warmBytes == expectedBytes, "Warmup record differs from fixture")

        var checksum: UInt64 = 0
        let start = DispatchTime.now().uptimeNanoseconds
        if mode == "allocations" { meter.begin?() }
        for index in 0..<iterations {
            let record = construct(fixture.checkpoint)
            // Identical constant-size observation overhead is included. Complete
            // record verification and serialization remain outside measurement.
            checksum &+= UInt64(record.playlistItems.count)
            checksum &+= record.collectionFolder == nil ? 17 : 31
            if !record.playlistItems.isEmpty {
                checksum &+= UInt64(record.playlistItems[index % record.playlistItems.count].url.absoluteString.utf8.count)
            }
        }
        if mode == "allocations" { meter.end?() }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
        let requests = meter.requests?()
        let bytes = meter.bytes?()

        let final = construct(fixture.checkpoint)
        let finalBytes = try canonicalBytes(final)
        precondition(finalBytes == expectedBytes, "Final record differs from fixture")
        var result: [String: Any] = [
            "count": count, "scenario": scenario, "iterations": iterations, "mode": mode,
            "seconds": elapsed, "checksum": checksum,
            "canonical_record_fnv1a64": fingerprint(expectedBytes),
            "canonical_record_bytes": expectedBytes.count, "complete_record_parity": true,
        ]
        if mode == "allocations", let requests, let bytes {
            result["allocation_requests"] = requests
            result["allocation_requested_bytes"] = bytes
        }
        print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
    }
}
