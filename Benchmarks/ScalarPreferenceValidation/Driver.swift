import Foundation
import IlliquidCore

/// Gate only the persistence callback, after the real writer has encoded its
/// snapshot. The store, locks, no-op checks and coalescing writer are unmodified.
private final class GatedDefaults: UserDefaults, @unchecked Sendable {
    private let counterLock = NSLock()
    private var armed = false
    private var preferenceWrites = 0
    let started = DispatchSemaphore(value: 0)
    let proceed = DispatchSemaphore(value: 0)

    func arm() {
        counterLock.lock()
        armed = true
        counterLock.unlock()
    }

    override func set(_ value: Any?, forKey key: String) {
        counterLock.lock()
        let blocked = armed && key.hasSuffix("playback-preferences.v1")
        if blocked { armed = false }
        counterLock.unlock()
        if blocked {
            started.signal()
            precondition(proceed.wait(timeout: .now() + 120) == .success)
        }
        super.set(value, forKey: key)
        if key.hasSuffix("playback-preferences.v1") {
            counterLock.lock()
            preferenceWrites += 1
            counterLock.unlock()
        }
    }

    var writes: Int {
        counterLock.lock()
        defer { counterLock.unlock() }
        return preferenceWrites
    }
}

@inline(never)
private func update(
    _ store: PlaybackPersistenceStore, field: String,
    first: Double, second: Double, iterations: Int
) {
    if field == "volume" {
        for index in 0..<iterations {
            store.setVolume(index & 1 == 0 ? first : second)
        }
    } else {
        for index in 0..<iterations {
            store.setPlaybackSpeed(index & 1 == 0 ? first : second)
        }
    }
}

@main
struct ScalarPreferenceBenchmark {
    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        precondition(arguments.count == 5, "field mode languages iterations writer")
        let field = arguments[0]
        let mode = arguments[1]
        let languageCount = Int(arguments[2])!
        let iterations = Int(arguments[3])!
        let blockedWriter = arguments[4] == "blocked"
        precondition(["volume", "speed"].contains(field))
        precondition(["unchanged", "changing", "clamped"].contains(mode))
        precondition([0, 4, 32].contains(languageCount))
        precondition(iterations > 0 && iterations % 2 == 0)
        precondition(["blocked", "normal"].contains(arguments[4]))

        let languages = [
            "en", "ja", "fr", "es", "de", "it", "pt", "ru",
            "zh", "ko", "ar", "hi", "nl", "sv", "no", "da",
            "fi", "pl", "cs", "sk", "uk", "tr", "el", "he",
            "th", "vi", "id", "ms", "ro", "hu", "bg", "ca",
        ]
        var preferences = PlaybackPreferences(
            volume: mode == "clamped" ? 100 : 50,
            isMuted: false,
            playbackSpeed: mode == "clamped" ? 4 : 1,
            isSidebarVisible: false,
            repeatMode: .all,
            isShuffleEnabled: true,
            hardwareDecodingPolicy: .off,
            preferredAudioOutputDeviceID: "benchmark-device",
            subtitleFallbackEncoding: .shiftJIS,
            trackSelection: .init(
                audioLanguages: Array(languages.prefix(languageCount)),
                subtitleLanguages: Array(languages.prefix(languageCount).reversed()),
                subtitles: .forcedOnly,
                prefersAccessibleTracks: true,
                avoidsCommentary: false
            ),
            remembersPlaybackHistory: false,
            restoresSessionPaused: false
        )
        precondition(preferences.trackSelection.audioLanguages.count == languageCount)
        precondition(preferences.trackSelection.subtitleLanguages.count == languageCount)

        let values: (Double, Double)
        switch (field, mode) {
        case ("volume", "changing"): values = (25, 75)
        case ("volume", "clamped"): values = (1000, 2000)
        case ("volume", _): values = (50, 50)
        case ("speed", "changing"): values = (0.75, 1.5)
        case ("speed", "clamped"): values = (8, 16)
        default: values = (1, 1)
        }
        if mode == "changing" {
            if field == "volume" { preferences.volume = values.1 }
            else { preferences.playbackSpeed = values.1 }
        }

        let suite = "IlliquidScalarBenchmark.\(UUID().uuidString)"
        let defaults = GatedDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PlaybackPersistenceStore(userDefaults: defaults, namespace: "Benchmark")
        store.savePreferences(preferences)
        store.flushSynchronously()
        let writesBefore = defaults.writes

        if blockedWriter {
            defaults.arm()
            store.setMuted(true)
            preferences.isMuted = true
            precondition(defaults.started.wait(timeout: .now() + 10) == .success)
        }

        // Warm the exact call path before timing. Even-sized changing batches
        // finish at the seeded value, so the measured batch has the same start.
        update(store, field: field, first: values.0, second: values.1, iterations: 64)
        if !blockedWriter { store.flushSynchronously() }
        let writesAfterWarmup = defaults.writes
        let start = DispatchTime.now().uptimeNanoseconds
        update(store, field: field, first: values.0, second: values.1, iterations: iterations)
        let elapsed = DispatchTime.now().uptimeNanoseconds - start

        if blockedWriter { defaults.proceed.signal() }
        store.flushSynchronously()
        let actual = store.loadPreferences()
        precondition(actual == preferences, "unrelated preferences or final scalar changed")
        let reloaded = PlaybackPersistenceStore(userDefaults: defaults, namespace: "Benchmark")
        precondition(reloaded.loadPreferences() == actual, "reload parity failed")

        let writes = defaults.writes - writesBefore
        if blockedWriter {
            precondition(writes == (mode == "changing" ? 2 : 1))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let result: [String: Any] = [
            "field": field, "mode": mode, "languages_per_list": languageCount,
            "writer": arguments[4], "iterations": iterations, "elapsed_ns": elapsed,
            "ns_per_update": Double(elapsed) / Double(iterations),
            "preference_writes_after_setup": writes,
            "preference_writes_after_warmup": defaults.writes - writesAfterWarmup,
            "preferences": try JSONSerialization.jsonObject(with: encoder.encode(actual)),
            "reload_matches": true,
        ]
        let json = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        print(String(decoding: json, as: UTF8.self))
    }
}
