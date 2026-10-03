import Foundation
import Testing
@testable import SuperplayrCore

@Suite("Playback history scale", .serialized)
struct PlaybackHistoryScalingTests {
    @Test(arguments: [10_000, 100_000], [false, true])
    func largeHistoryPreservesUntouchedEntriesThroughMutationAndFlush(count: Int, versioned: Bool) async throws {
        let suite = "PlatinumHistoryScaling-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let positions = Dictionary(uniqueKeysWithValues: (0..<count).map {
            ("/tmp/history/episode-\($0).mkv", Double($0 + 1))
        })
        let durations = positions.mapValues { $0 + 200 }
        let completed = positions.keys.sorted().enumerated().compactMap { $0.offset.isMultiple(of: 4) ? $0.element : nil }
        let settings = Dictionary(uniqueKeysWithValues: positions.keys.sorted().prefix(count / 2).map {
            ($0, ["areSubtitlesVisible": true, "subtitleDelay": 0] as [String: Any])
        })
        var state: [String: Any] = [
            "playbackPositions": positions, "playbackDurations": durations,
            "completedFiles": completed, "mediaSettings": settings,
        ]
        if versioned {
            func version(_ identifier: Int) -> [String: Int] {
                ["fileIdentifier": identifier, "byteCount": 2_000_000,
                 "modificationSeconds": 100, "modificationNanoseconds": 0,
                 "creationSeconds": 50, "creationNanoseconds": 0]
            }
            state["mediaVersions"] = Dictionary(uniqueKeysWithValues: (0..<count).map {
                ("/tmp/history/episode-\($0).mkv", version($0 + 1))
            })
            state["replacedHistory"] = Dictionary(uniqueKeysWithValues: (0..<(count / 100)).map {
                ("/tmp/history/episode-\($0).mkv", [["version": version(count + $0 + 1),
                                                 "position": 42, "duration": 1_000,
                                                 "isCompleted": false] as [String: Any]])
            })
        }
        defaults.set(try JSONSerialization.data(withJSONObject: state), forKey: "Scale.playback-state.v1")
        let clock = ContinuousClock()
        let start = clock.now
        let store = PlaybackPersistenceStore(userDefaults: defaults, namespace: "Scale")
        let loaded = clock.now
        let changed = URL(fileURLWithPath: "/tmp/history/episode-0.mkv")
        var mutations: [Duration] = []
        for index in 0..<20 {
            let before = clock.now
            store.setPlaybackPosition(Double(index + 2), for: changed)
            mutations.append(before.duration(to: clock.now))
        }
        let flushStart = clock.now
        try await store.flush().get()
        let flushed = clock.now
        let restored = PlaybackPersistenceStore(userDefaults: defaults, namespace: "Scale")
        #expect(restored.playbackPosition(for: changed) == 21)
        #expect(restored.playbackPosition(for: URL(fileURLWithPath: "/tmp/history/episode-\(count - 1).mkv")) == Double(count))
        if versioned {
            #expect(restored.mediaVersion(for: URL(fileURLWithPath: "/tmp/history/episode-\(count - 1).mkv"))?.fileIdentifier == UInt64(count))
            #expect(restored.replacedMediaHistory(for: changed).first?.position == 42)
        }
        let bytes = defaults.data(forKey: "Scale.playback-state.v1")?.count ?? 0
        print("HISTORY_SCALE count=\(count) versioned=\(versioned) snapshot_load=\(start.duration(to: loaded)) mutation_p95=\(mutations.sorted()[18]) encode_and_flush=\(flushStart.duration(to: flushed)) bytes=\(bytes)")
    }
}
