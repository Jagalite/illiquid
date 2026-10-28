import CryptoKit
import Foundation
import IlliquidCore
@testable import IlliquidPlayer

/// Measures the complete production checkpoint, including existing playlist
/// deduplication. Input preparation and JSON fingerprinting are outside timing.
@main
struct CheckpointProbe {
    static func main() throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 4,
              let count = Int(arguments[2]), (0...100_000).contains(count),
              let iterations = Int(arguments[3]), (1...100_000).contains(iterations)
        else {
            throw ProbeError("Usage: CheckpointProbe SCENARIO COUNT ITERATIONS")
        }
        let scenario = arguments[1]
        let supported = [
            "no-folder-last", "no-folder-miss", "no-folder-first",
            "folder-first", "folder-last", "folder-miss",
            "remote-source", "unsupported-source", "all-invalid-items",
        ]
        guard supported.contains(scenario) else {
            throw ProbeError("Unknown scenario: \(scenario)")
        }
        let folder = URL(fileURLWithPath: "/Media/Checkpoint/Café/Season 01",
                         isDirectory: true)
        let items = (0..<count).map { index in
            let url = scenario == "all-invalid-items"
                ? URL(string: "file://archive.invalid/Media/Checkpoint/Episode-\(index).mkv")!
                : folder.appendingPathComponent("Episode \(index).mkv")
            return FolderPlaylistItem(
                url: url,
                externalSubtitleURLs: [
                    URL(fileURLWithPath: "/Subtitles/Checkpoint/Episode \(index).srt"),
                ],
                dateAdded: Date(timeIntervalSince1970: Double(index))
            )
        }
        let missing = folder.appendingPathComponent("Missing episode.mkv")
        let source: MediaSource
        let index: Int?
        switch scenario {
        case "folder-first", "no-folder-first":
            source = .localFile(items.first?.url ?? missing)
            index = items.indices.first
        case "folder-last", "no-folder-last":
            source = .localFile(items.last?.url ?? missing)
            index = items.indices.last
        case "remote-source":
            source = .remoteStream(URL(string: "https://media.invalid/checkpoint/live.m3u8")!)
            index = nil
        case "unsupported-source":
            source = .localFile(URL(string: "file://archive.invalid/Media/Checkpoint/Missing.mkv")!)
            index = nil
        default:
            source = .localFile(missing)
            index = nil
        }
        let checkpoint = PlaybackCheckpoint(
            source: source,
            folder: scenario.hasPrefix("no-folder-") ? nil : folder,
            playlist: items,
            index: index,
            position: 123.25,
            wasPaused: false,
            unshuffledPlaylistIDs: nil
        )

        // Drain temporary Objective-C objects between records. No array of
        // output records is retained by the timed workload.
        for _ in 0..<3 {
            _ = autoreleasepool { consume(checkpoint.record()) }
        }
        var checksum: UInt64 = 0
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<iterations {
            checksum &+= autoreleasepool { consume(checkpoint.record()) }
        }
        let elapsed = DispatchTime.now().uptimeNanoseconds - start

        var record = checkpoint.record()
        let expectedFolder = count > 0 && ["folder-first", "folder-last"].contains(scenario)
            ? folder : nil
        guard record.collectionFolder == expectedFolder,
              record.source == source,
              record.playlistItems == items,
              record.playlistIndex == index,
              record.position == 123.25,
              record.wasPaused == false,
              record.unshuffledPlaylistIDs == nil,
              record.schemaVersion == PlaybackSessionRecord.currentSchemaVersion
        else {
            throw ProbeError("Unexpected complete checkpoint result: \(scenario)/\(count)")
        }
        guard checksum == consume(record) &* UInt64(iterations) else {
            throw ProbeError("Timed result consumption differs from the checked result")
        }
        // updatedAt is intentionally fresh on each record. Equalize only this
        // field before fingerprinting every encoded field, including metadata.
        record.updatedAt = Date(timeIntervalSince1970: 0)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(record)
        guard try JSONDecoder().decode(PlaybackSessionRecord.self, from: bytes) == record else {
            throw ProbeError("Checkpoint JSON round trip failed")
        }
        let fingerprint = SHA256.hash(data: bytes)
            .map { String(format: "%02x", $0) }.joined()
        let output = Observation(
            scenario: scenario,
            count: count,
            iterations: iterations,
            elapsed_ns: elapsed,
            checksum: String(checksum),
            fingerprint: fingerprint
        )
        print(String(decoding: try encoder.encode(output), as: UTF8.self))
    }

    @inline(never)
    private static func consume(_ record: PlaybackSessionRecord) -> UInt64 {
        UInt64(record.playlistItems.count)
            &+ UInt64((record.playlistIndex ?? -1) + 1)
            &+ UInt64(record.schemaVersion)
            &+ UInt64(record.position * 100)
            &+ (record.collectionFolder == nil ? 0 : 1)
            &+ (record.wasPaused ? 1 : 0)
    }

    private struct Observation: Encodable {
        let scenario: String
        let count: Int
        let iterations: Int
        let elapsed_ns: UInt64
        let checksum: String
        let fingerprint: String
    }

    private struct ProbeError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
