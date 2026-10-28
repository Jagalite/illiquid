// Native component experiment: complete production IlliquidCore, without rewrites.
import Darwin
import Foundation
import IlliquidCore

private let namespace = "IlliquidHistoryJSONBenchmark"
private let historyKey = "\(namespace).playback-state.v1"

private struct Failure: Error, CustomStringConvertible {
    let description: String
}
private func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw Failure(description: message) }
}

private final class MeasuredDefaults: UserDefaults, @unchecked Sendable {
    // Configured before the store can reach this object from its writer queue.
    var usesMemorySink = false
    private let auditLock = NSLock()
    private var values: [String: Data] = [:]
    private var writeCount = 0
    private var payloadBytes = 0

    override func set(_ value: Any?, forKey key: String) {
        if usesMemorySink {
            auditLock.lock()
            values[key] = value as? Data
            auditLock.unlock()
        } else {
            super.set(value, forKey: key)
        }
        if key == historyKey {
            auditLock.lock()
            writeCount += 1
            payloadBytes += (value as? Data)?.count ?? 0
            auditLock.unlock()
        }
    }

    override func data(forKey key: String) -> Data? {
        if !usesMemorySink { return super.data(forKey: key) }
        auditLock.lock()
        defer { auditLock.unlock() }
        return values[key]
    }

    func resetCounters() {
        auditLock.lock()
        writeCount = 0
        payloadBytes = 0
        auditLock.unlock()
    }

    func counters() -> (writes: Int, bytes: Int) {
        auditLock.lock()
        defer { auditLock.unlock() }
        return (writeCount, payloadBytes)
    }
}

// These types describe seed input, not a substitute implementation of the store.
private struct ArchivedFixture: Encodable {
    let version: MediaContentVersion
    let position: Double?
    let duration: Double
    let isCompleted: Bool
    let mediaSettings: MediaPlaybackSettings?
}
private struct Seed: Encodable {
    var playbackPositions: [String: Double] = [:]
    var playbackDurations: [String: Double] = [:]
    var completedFiles: [String] = []
    var lastWatchedFiles: [String: String] = [:]
    var lastOpenedMedia: PlaybackRestoreTarget?
    var mediaSettings: [String: MediaPlaybackSettings] = [:]
    var mediaVersions: [String: MediaContentVersion] = [:]
    var replacedHistory: [String: [ArchivedFixture]] = [:]
    var preferences = PlaybackPreferences.standard
}
private struct Workload {
    let name: String
    let count: Int
    let rich: Bool
    let deep: Bool
    let unicode: Bool

    init(_ name: String) throws {
        self.name = name
        switch name {
        case "empty": count = 0; rich = false; deep = false; unicode = false
        case "small-100": count = 100; rich = false; deep = false; unicode = false
        case "progress-1000": count = 1_000; rich = false; deep = false; unicode = false
        case "rich-1000": count = 1_000; rich = true; deep = false; unicode = false
        case "deep-1000": count = 1_000; rich = false; deep = true; unicode = false
        case "unicode-1000": count = 1_000; rich = true; deep = false; unicode = true
        case "rich-10000": count = 10_000; rich = true; deep = false; unicode = false
        default: throw Failure(description: "Unknown workload \(name)")
        }
    }

    func path(_ index: Int) -> String {
        let root = deep
            ? "/Volumes/Media/Archive/Collection/Region/Language/Genre/Decade/Year/TV"
            : "/Volumes/Media/TV"
        let series = unicode ? "日本語 🌙 \"Series\" %2F" : "Series"
        return "\(root)/\(series)-\(index / 24)/Season 01/Episode \(index).mkv"
    }

    func makeSeed() -> Seed {
        var seed = Seed()
        for index in 0..<count {
            let key = path(index)
            seed.playbackDurations[key] = 3_600
            if rich && index % 5 == 4 {
                seed.completedFiles.append(key)
            } else {
                seed.playbackPositions[key] = Double(index % 900) + 0.25
            }
            if rich {
                seed.mediaVersions[key] = version(UInt64(index + 1))
                if index % 4 == 0 {
                    seed.mediaSettings[key] = MediaPlaybackSettings(
                        subtitleTrack: MediaTrackPreference(track: MediaTrack(
                            id: 2, kind: .subtitle,
                            title: unicode ? "日本語 / \"CC\" \\ commentary" : "English / CC",
                            languageCode: "en", codec: "ass",
                            isExternal: true, externalFilename: "Episode \(index).en.srt"
                        )),
                        subtitleDelay: 0.5
                    )
                }
                if index % 24 == 0 {
                    let folder = URL(fileURLWithPath: key).deletingLastPathComponent().path
                    seed.lastWatchedFiles[folder] = key
                }
                if index % 20 == 0 {
                    seed.replacedHistory[key] = [
                        ArchivedFixture(
                            version: version(UInt64(index + 20_001)),
                            position: 240.5, duration: 3_600,
                            isCompleted: false, mediaSettings: seed.mediaSettings[key]
                        ),
                        ArchivedFixture(
                            version: version(UInt64(index + 40_001)),
                            position: nil, duration: 3_600,
                            isCompleted: true, mediaSettings: nil
                        ),
                    ]
                }
            }
        }
        if rich { seed.lastOpenedMedia = .file(URL(fileURLWithPath: path(0))) }
        return seed
    }
}

private func version(_ identifier: UInt64) -> MediaContentVersion {
    .init(
        fileIdentifier: identifier, byteCount: 1_048_576,
        modificationSeconds: 1_700_000_000, modificationNanoseconds: 123,
        creationSeconds: 1_600_000_000, creationNanoseconds: 456
    )
}

private func canonical(_ data: Data) throws -> Data {
    guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let completed = object["completedFiles"] as? [String]
    else { throw Failure(description: "Missing complete history object") }
    // This is the only unordered array in the persisted schema.
    object["completedFiles"] = completed.sorted()
    return try JSONSerialization.data(
        withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]
    )
}

private func cpuNanoseconds() throws -> UInt64 {
    var value = timespec()
    try require(clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &value) == 0, "CPU clock failed")
    return UInt64(value.tv_sec) * 1_000_000_000 + UInt64(value.tv_nsec)
}

@main
private struct Main {
    static func main() throws {
        let args = CommandLine.arguments
        try require(args.count == 5, "usage: benchmark WORKLOAD SINK ITERATIONS OUTPUT_JSON")
        let workload = try Workload(args[1])
        let sink = args[2]
        try require(["memory", "defaults"].contains(sink), "Unknown sink")
        guard let iterations = Int(args[3]), iterations > 0, iterations % 2 == 0 else {
            throw Failure(description: "Iterations must be positive and even")
        }
        try require(!NonDecodePerformance.isEnabled, "Disable performance instrumentation")
        let suite = "IlliquidHistoryJSONResearch.\(UUID().uuidString)"
        guard let defaults = MeasuredDefaults(suiteName: suite) else {
            throw Failure(description: "Cannot create isolated defaults suite")
        }
        defaults.usesMemorySink = sink == "memory"
        defer { defaults.removePersistentDomain(forName: suite) }
        var seed = workload.makeSeed()
        defaults.set(try JSONEncoder().encode(seed), forKey: historyKey)
        let store = PlaybackPersistenceStore(userDefaults: defaults, namespace: namespace)
        defer { store.flushSynchronously() }
        try require(!store.hasUnreadableHistory, "Seed failed to decode")
        let target = URL(fileURLWithPath: workload.path(0))
        if workload.count > 0 {
            try require(store.playbackPosition(for: target) == 0.25, "Seed position missing")
            try require(store.playbackProgress(for: target)?.duration == 3_600, "Seed duration missing")
            if workload.rich {
                try require(store.mediaVersion(for: target) == version(1), "Seed version missing")
                try require(store.replacedMediaHistory(for: target).count == 2, "Seed archives missing")
            }
        }

        func update(_ index: Int) {
            if workload.count == 0 {
                store.clearPlaybackHistory()
            } else {
                // Every operation changes the value; both are below completion.
                precondition(store.setPlaybackPosition(120.25 + Double(index % 2), for: target))
            }
            store.flushSynchronously()
        }
        for index in 0..<4 { update(index) }
        // Let warmup's scheduled 100 ms drains finish before observation begins.
        Thread.sleep(forTimeInterval: 0.15)
        defaults.resetCounters()

        let cpuStart = try cpuNanoseconds()
        let wallStart = DispatchTime.now().uptimeNanoseconds
        for index in 0..<iterations { update(index) }
        let wallNanoseconds = DispatchTime.now().uptimeNanoseconds - wallStart
        let cpuElapsed = try cpuNanoseconds() - cpuStart

        let counts = defaults.counters()
        try require(counts.writes == iterations, "A timed operation did not write exactly once")
        guard let data = defaults.data(forKey: historyKey) else {
            throw Failure(description: "No final history")
        }
        if workload.count > 0 { seed.playbackPositions[workload.path(0)] = 121.25 }
        let expected = try canonical(JSONEncoder().encode(seed))
        try require(try canonical(data) == expected, "Complete persisted history differs from fixture")
        try require(counts.bytes == data.count * iterations, "Payload size changed within batch")
        let restored = PlaybackPersistenceStore(userDefaults: defaults, namespace: namespace)
        try require(!restored.hasUnreadableHistory, "Final history failed to reload")
        if workload.count > 0 {
            try require(restored.playbackPosition(for: target) == 121.25, "Final position missing")
        }
        try data.write(to: URL(fileURLWithPath: args[4]), options: [.atomic])
        let row: [String: Any] = [
            "workload": workload.name, "sink": sink, "seed_records": workload.count,
            "iterations": iterations, "writes": counts.writes,
            "wall_ns": wallNanoseconds, "cpu_ns": cpuElapsed,
            "payload_bytes": data.count, "total_payload_bytes": counts.bytes,
            "slash_count": data.filter { $0 == 47 }.count,
            "instrumentation_enabled": NonDecodePerformance.isEnabled,
            "fixture_verified": true,
        ]
        print(String(decoding: try JSONSerialization.data(
            withJSONObject: row, options: [.sortedKeys]
        ), as: UTF8.self))
    }
}
