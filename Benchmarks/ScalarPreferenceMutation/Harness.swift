import Foundation
import IlliquidCore

/// Observe real UserDefaults callbacks without changing the production writer.
/// The blocked case gates one callback after JSON encoding, so both variants
/// replace pending snapshots under the same scheduling conditions.
private final class ObservedDefaults: UserDefaults {
    private let auditLock = NSLock()
    private var recording = false
    private var blocksNext = false
    private var callbacks = 0
    let started = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)

    func arm(block: Bool) {
        auditLock.lock()
        recording = true
        blocksNext = block
        callbacks = 0
        auditLock.unlock()
    }

    override func set(_ value: Any?, forKey key: String) {
        auditLock.lock()
        let observed = recording && key == "Illiquid.playback-preferences.v1"
        let blocked = observed && blocksNext
        if observed { callbacks += 1 }
        if blocked { blocksNext = false }
        auditLock.unlock()
        if blocked {
            started.signal()
            precondition(release.wait(timeout: .now() + 30) == .success, "write gate timed out")
        }
        super.set(value, forKey: key)
    }

    var writeCount: Int {
        auditLock.lock()
        defer { auditLock.unlock() }
        return callbacks
    }
}

@main
struct ScalarPreferenceBenchmark {
    static func main() throws {
        let args = CommandLine.arguments
        precondition(args.count == 5, "Expected FIELD MODE LANGUAGE_COUNT UPDATES")
        let field = args[1], mode = args[2]
        let languageCount = Int(args[3])!, updates = Int(args[4])!
        precondition(["volume", "speed"].contains(field))
        precondition(["noop", "blocked", "burst", "flushed"].contains(mode))
        precondition([0, 1, 3, 32].contains(languageCount) && updates > 0)

        let languages = [
            "en", "ja", "fr", "de", "es", "it", "pt", "ru",
            "zh", "ko", "ar", "hi", "nl", "sv", "no", "da",
            "fi", "pl", "cs", "sk", "hu", "ro", "bg", "uk",
            "el", "tr", "he", "th", "vi", "id", "ms", "fa",
        ]
        var expected = PlaybackPreferences(
            volume: 42, isMuted: true, playbackSpeed: 1.25, isSidebarVisible: false,
            repeatMode: .all, isShuffleEnabled: true, hardwareDecodingPolicy: .compatibility,
            preferredAudioOutputDeviceID: languageCount == 0 ? nil : "usb-dac",
            subtitleFallbackEncoding: .shiftJIS,
            trackSelection: .init(
                audioLanguages: Array(languages.prefix(languageCount)),
                subtitleLanguages: Array(languages.suffix(languageCount)),
                subtitles: .always, prefersAccessibleTracks: true, avoidsCommentary: false
            ),
            remembersPlaybackHistory: false, restoresSessionPaused: false
        )
        precondition(expected.trackSelection.audioLanguages.count == languageCount)
        precondition(expected.trackSelection.subtitleLanguages.count == languageCount)
        let suite = "com.example.IlliquidScalarPreferenceBenchmark.\(UUID().uuidString)"
        let defaults = ObservedDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferenceKey = "Illiquid.playback-preferences.v1"
        let historyKey = "Illiquid.playback-state.v1"
        let history = Data(#"{"playbackPositions":{"/synthetic/untouched.mkv":123.5},"lastWatchedFiles":{}}"#.utf8)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        defaults.set(try encoder.encode(expected), forKey: preferenceKey)
        defaults.set(history, forKey: historyKey)
        let store = PlaybackPersistenceStore(userDefaults: defaults)
        precondition(store.loadPreferences() == expected && !store.hasUnreadableHistory)

        // Warm each setter without scheduling a delayed callback. Seeding used
        // direct encoded values, not a previous savePreferences submission.
        for _ in 0..<16 {
            store.setVolume(expected.volume)
            store.setPlaybackSpeed(expected.playbackSpeed)
        }
        defaults.arm(block: mode == "blocked")
        if mode == "blocked" {
            expected.isMuted = false
            store.setMuted(false)
            precondition(defaults.started.wait(timeout: .now() + 10) == .success,
                         "initial preferences callback did not start")
        }
        let values = (0..<updates).map { index -> Double in
            if mode == "noop" { return field == "volume" ? expected.volume : expected.playbackSpeed }
            if field == "volume" { return index.isMultiple(of: 2) ? 25 : 75 }
            return index.isMultiple(of: 2) ? 0.75 : 1.75
        }
        let beforeWrites = defaults.writeCount
        let operationStart = DispatchTime.now().uptimeNanoseconds
        var callerNS: UInt64 = 0
        if mode == "flushed" {
            // The end-to-end control intentionally flushes every change. Its
            // caller subtotal uses individual timers; the main modes use one
            // aggregate timer, avoiding timer overhead per fast setter.
            for value in values {
                let start = DispatchTime.now().uptimeNanoseconds
                if field == "volume" { store.setVolume(value) }
                else { store.setPlaybackSpeed(value) }
                callerNS += DispatchTime.now().uptimeNanoseconds - start
                store.flushSynchronously()
            }
        } else {
            let start = DispatchTime.now().uptimeNanoseconds
            if field == "volume" {
                for value in values { store.setVolume(value) }
            } else {
                for value in values { store.setPlaybackSpeed(value) }
            }
            callerNS = DispatchTime.now().uptimeNanoseconds - start
        }
        // UserDefaults observation starts after encoding. A short burst must
        // also finish well before the writer's unchanged 100 ms delay, so even
        // an encoding callback that has not reached set() cannot overlap it.
        if mode == "burst" {
            precondition(DispatchTime.now().uptimeNanoseconds - operationStart < 50_000_000,
                         "burst approached the scheduled writer deadline")
        }
        let writesDuringTiming = defaults.writeCount - beforeWrites
        let flushStart = DispatchTime.now().uptimeNanoseconds
        if mode == "blocked" { defaults.release.signal() }
        store.flushSynchronously()
        let end = DispatchTime.now().uptimeNanoseconds

        if field == "volume" { expected.volume = values.last! }
        else { expected.playbackSpeed = values.last! }
        let actual = store.loadPreferences()
        let persisted = try JSONDecoder().decode(PlaybackPreferences.self,
                                                 from: defaults.data(forKey: preferenceKey)!)
        let reloaded = PlaybackPersistenceStore(userDefaults: defaults).loadPreferences()
        precondition(actual == expected && persisted == expected && reloaded == expected,
                     "complete preferences did not survive mutation and reload")
        let unchangedHistory = defaults.data(forKey: historyKey) == history
            && store.playbackPosition(for: URL(fileURLWithPath: "/synthetic/untouched.mkv")) == 123.5
        precondition(unchangedHistory, "scalar update changed stored history")
        let expectedWrites = mode == "noop" ? 0 : mode == "blocked" ? 2 : mode == "burst" ? 1 : updates
        precondition(defaults.writeCount == expectedWrites, "unexpected coalescing/write count")
        precondition(writesDuringTiming == (mode == "flushed" ? updates : 0),
                     "background callback contaminated caller timing")

        let receipt: [String: Any] = [
            "field": field, "mode": mode, "language_count": languageCount, "updates": updates,
            "actual_audio_languages": actual.trackSelection.audioLanguages,
            "actual_subtitle_languages": actual.trackSelection.subtitleLanguages,
            "caller_ns": callerNS, "flush_ns": end - flushStart,
            "total_through_flush_ns": end - operationStart,
            "writes": defaults.writeCount, "writes_during_timing": writesDuringTiming,
            "final_preferences": String(decoding: try encoder.encode(actual), as: UTF8.self),
            "persisted_preferences": String(decoding: try encoder.encode(persisted), as: UTF8.self),
            "unchanged_history": unchangedHistory,
        ]
        print(String(decoding: try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys]),
                     as: UTF8.self))
    }
}
