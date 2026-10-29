import Foundation
import Testing
@testable import IlliquidCore

private let scalarPreferenceNamespace = "ScalarPreferenceTests"
private let scalarPreferenceKey = "\(scalarPreferenceNamespace).playback-preferences.v1"
private let scalarHistoryKey = "\(scalarPreferenceNamespace).playback-state.v1"

private struct PersistedPreferenceScalars: Decodable {
    let volume: Double
    let playbackSpeed: Double
}

private final class ScalarPreferenceDefaults: UserDefaults {
    private let counterLock = NSLock()
    private var writes: [String: Int] = [:]

    override func set(_ value: Any?, forKey key: String) {
        super.set(value, forKey: key)
        counterLock.lock()
        writes[key, default: 0] += 1
        counterLock.unlock()
    }

    func writeCount(for key: String) -> Int {
        counterLock.lock()
        defer { counterLock.unlock() }
        return writes[key, default: 0]
    }
}

@Suite("Scalar preference mutation invariants")
struct ScalarPreferenceMutationTests {
    @Test func volumeBoundariesPreserveAllOtherPreferences() throws {
        try withDefaults { defaults in
            let store = makeStore(defaults)
            defer { store.flushSynchronously() }
            var expected = distinctivePreferences()
            store.savePreferences(expected)
            let cases: [(input: Double, expected: Double)] = [
                (-.greatestFiniteMagnitude, 0), (-1, 0), (-.leastNonzeroMagnitude, 0),
                (-0.0, 0), (0, 0), (.leastNonzeroMagnitude, .leastNonzeroMagnitude),
                (42.25, 42.25), (100.0.nextDown, 100.0.nextDown), (100, 100),
                (100.0.nextUp, 100), (.greatestFiniteMagnitude, 100),
                (.nan, 100), (.infinity, 100), (-.infinity, 100),
            ]
            for item in cases {
                store.setVolume(item.input)
                expected.volume = item.expected
                #expect(store.loadPreferences() == expected, "Volume input: \(item.input)")
                try expectPersisted(expected, from: store, defaults: defaults)
            }
            #expect(defaults.data(forKey: scalarHistoryKey) == nil)
        }
    }

    @Test func speedBoundariesPreserveAllOtherPreferences() throws {
        try withDefaults { defaults in
            let store = makeStore(defaults)
            defer { store.flushSynchronously() }
            var expected = distinctivePreferences()
            store.savePreferences(expected)
            let cases: [(input: Double, expected: Double)] = [
                (-.greatestFiniteMagnitude, 1), (-1, 1), (-.leastNonzeroMagnitude, 1),
                (-0.0, 1), (0, 1), (.leastNonzeroMagnitude, 0.25),
                (0.25.nextDown, 0.25), (0.25, 0.25), (0.25.nextUp, 0.25.nextUp),
                (1.75, 1.75), (4.0.nextDown, 4.0.nextDown), (4, 4),
                (4.0.nextUp, 4), (.greatestFiniteMagnitude, 4),
                (.nan, 1), (.infinity, 1), (-.infinity, 1),
            ]
            for item in cases {
                store.setPlaybackSpeed(item.input)
                expected.playbackSpeed = item.expected
                #expect(store.loadPreferences() == expected, "Speed input: \(item.input)")
                try expectPersisted(expected, from: store, defaults: defaults)
            }
            #expect(defaults.data(forKey: scalarHistoryKey) == nil)
        }
    }

    @Test func equivalentScalarInputsDoNotWriteAnotherSnapshot() throws {
        try withDefaults { defaults in
            let store = makeStore(defaults)
            defer { store.flushSynchronously() }
            let cases: [(volume: Double, speed: Double, volumes: [Double], speeds: [Double])] = [
                (100, 1, [100, 101, .greatestFiniteMagnitude, .nan, .infinity, -.infinity],
                 [1, 0, -1, .nan, .infinity, -.infinity]),
                (0, 0.25, [0, -0.0, -1, -.greatestFiniteMagnitude],
                 [0.25, 0.25.nextDown, .leastNonzeroMagnitude]),
                (42.25, 4, [42.25], [4, 4.0.nextUp, .greatestFiniteMagnitude]),
            ]
            for item in cases {
                var expected = distinctivePreferences()
                expected.volume = item.volume
                expected.playbackSpeed = item.speed
                store.savePreferences(expected)
                store.flushSynchronously()
                let writes = defaults.writeCount(for: scalarPreferenceKey)
                let bytes = defaults.data(forKey: scalarPreferenceKey)
                for volume in item.volumes { store.setVolume(volume) }
                for speed in item.speeds { store.setPlaybackSpeed(speed) }
                store.flushSynchronously()
                #expect(store.loadPreferences() == expected)
                #expect(defaults.writeCount(for: scalarPreferenceKey) == writes)
                #expect(defaults.data(forKey: scalarPreferenceKey) == bytes)
            }
            #expect(defaults.writeCount(for: scalarHistoryKey) == 0)
        }
    }

    @Test func publicPreferenceMutationsAreSanitizedOnSaveAndDoNotAliasStoredState() throws {
        try withDefaults { defaults in
            let store = makeStore(defaults)
            defer { store.flushSynchronously() }
            var submitted = distinctivePreferences()
            submitted.volume = .nan
            submitted.playbackSpeed = .infinity
            submitted.preferredAudioOutputDeviceID = " \t auto \n"
            submitted.trackSelection.audioLanguages = [" ENG ", "en", "", "jpn", "ja"]
            submitted.trackSelection.subtitleLanguages = [" FRA ", "fr", "", "deu", "de"]
            store.savePreferences(submitted)

            var expected = distinctivePreferences()
            expected.volume = 100
            expected.playbackSpeed = 1
            expected.preferredAudioOutputDeviceID = nil
            expected.trackSelection.audioLanguages = ["en", "ja"]
            expected.trackSelection.subtitleLanguages = ["fr", "de"]
            #expect(store.loadPreferences() == expected)

            // Both the original argument and a getter result are independent
            // values, including their copy-on-write language arrays.
            submitted.trackSelection.audioLanguages.append("es")
            submitted.volume = -50
            var returned = store.loadPreferences()
            returned.volume = .infinity
            returned.playbackSpeed = -20
            returned.trackSelection.subtitleLanguages.removeAll()
            returned.preferredAudioOutputDeviceID = "unsubmitted device"
            #expect(store.loadPreferences() == expected)

            store.setVolume(32.5)
            store.setPlaybackSpeed(1.25)
            expected.volume = 32.5
            expected.playbackSpeed = 1.25
            try expectPersisted(expected, from: store, defaults: defaults)
        }
    }

    @Test func individualPreferenceSettersEstablishTheInvariantBeforeScalarChanges() throws {
        try withDefaults { defaults in
            let store = makeStore(defaults)
            defer { store.flushSynchronously() }
            var expected = distinctivePreferences()
            store.savePreferences(expected)
            var tracks = TrackSelectionPreferences(subtitles: .always,
                prefersAccessibleTracks: false, avoidsCommentary: true)
            tracks.audioLanguages = [" ENG ", "en", "", "jpn"]
                + Array(repeating: "", count: 28) + ["fr"]
            tracks.subtitleLanguages = [" DEU ", "de", " FRA ", ""]
            store.setTrackSelectionPreferences(tracks)
            store.setPreferredAudioOutputDeviceID(" \t USB-🔊 \n")
            store.setMuted(false)
            store.setSidebarVisible(true)
            store.setRepeatMode(.all)
            store.setShuffleEnabled(false)
            store.setHardwareDecodingPolicy(.compatibility)
            store.setSubtitleFallbackEncoding(.windows1251)

            expected.trackSelection = TrackSelectionPreferences(audioLanguages: ["en", "ja"],
                subtitleLanguages: ["de", "fr"], subtitles: .always,
                prefersAccessibleTracks: false, avoidsCommentary: true)
            expected.preferredAudioOutputDeviceID = "USB-🔊"
            expected.isMuted = false
            expected.isSidebarVisible = true
            expected.repeatMode = .all
            expected.isShuffleEnabled = false
            expected.hardwareDecodingPolicy = .compatibility
            expected.subtitleFallbackEncoding = .windows1251
            #expect(store.loadPreferences() == expected)

            tracks.audioLanguages = ["es"]
            store.setVolume(-5)
            store.setPlaybackSpeed(99)
            expected.volume = 0
            expected.playbackSpeed = 4
            try expectPersisted(expected, from: store, defaults: defaults)
        }
    }

    @Test(arguments: [false, true])
    func decodedPreferencesAreSanitizedBeforeScalarChanges(dedicatedKey: Bool) throws {
        try withDefaults { defaults in
            let raw: [String: Any] = [
                "volume": -55, "playbackSpeed": 99, "isMuted": true,
                "isSidebarVisible": false, "repeatMode": "one", "isShuffleEnabled": true,
                "hardwareDecodingPolicy": "off", "preferredAudioOutputDeviceID": " \t auto \n",
                "subtitleFallbackEncoding": "shiftJIS", "remembersPlaybackHistory": false,
                "restoresSessionPaused": false,
                "trackSelection": [
                    "audioLanguages": [" ENG ", "en", "", "jpn"],
                    "subtitleLanguages": [" FRA ", "fr", "", "deu"],
                    "subtitles": "forcedOnly", "prefersAccessibleTracks": true,
                    "avoidsCommentary": false,
                ] as [String: Any],
            ]
            let file = URL(fileURLWithPath: "/tmp/scalar-preference-history.mkv")
            let legacy: [String: Any] = [
                "playbackPositions": [file.path: 23.0],
                // A dedicated payload must override these different legacy
                // preferences; without it, the legacy payload is validated.
                "preferences": dedicatedKey ? ["volume": 61, "isMuted": false] : raw,
            ]
            let history = try JSONSerialization.data(withJSONObject: legacy)
            defaults.set(history, forKey: scalarHistoryKey)
            if dedicatedKey {
                defaults.set(try JSONSerialization.data(withJSONObject: raw), forKey: scalarPreferenceKey)
            }
            let store = makeStore(defaults)
            defer { store.flushSynchronously() }
            var expected = distinctivePreferences()
            expected.volume = 0
            expected.playbackSpeed = 4
            expected.preferredAudioOutputDeviceID = nil
            expected.trackSelection.audioLanguages = ["en", "ja"]
            expected.trackSelection.subtitleLanguages = ["fr", "de"]
            #expect(!store.hasUnreadableHistory)
            #expect(store.loadPreferences() == expected)
            #expect(store.playbackPosition(for: file) == 23)

            store.setVolume(54.5)
            store.setPlaybackSpeed(0.5)
            expected.volume = 54.5
            expected.playbackSpeed = 0.5
            try expectPersisted(expected, from: store, defaults: defaults)
            #expect(defaults.data(forKey: scalarHistoryKey) == history)
            #expect(store.playbackPosition(for: file) == 23)
        }
    }

    @Test(arguments: [false, true])
    func malformedPreferencesRetainSafeFallbacksAndDoNotRewriteHistory(corruptHistory: Bool) throws {
        try withDefaults { defaults in
            var expected = corruptHistory ? PlaybackPreferences.standard : distinctivePreferences()
            let history: Data
            if corruptHistory {
                history = Data(#"{"preferences":{"volume":"loud"}}"#.utf8)
            } else {
                let encoded = try JSONEncoder().encode(expected)
                let object = try JSONSerialization.jsonObject(with: encoded)
                history = try JSONSerialization.data(withJSONObject: ["preferences": object])
            }
            defaults.set(history, forKey: scalarHistoryKey)
            defaults.set(Data("not valid JSON".utf8), forKey: scalarPreferenceKey)
            let store = makeStore(defaults)
            defer { store.flushSynchronously() }
            #expect(store.hasUnreadableHistory == corruptHistory)
            #expect(store.loadPreferences() == expected)
            store.setVolume(22)
            store.setPlaybackSpeed(.nan)
            expected.volume = 22
            expected.playbackSpeed = 1
            try expectPersisted(expected, from: store, defaults: defaults)
            #expect(defaults.data(forKey: scalarHistoryKey) == history)
            #expect(store.hasUnreadableHistory == corruptHistory)
        }
    }

    @Test func concurrentChangesToDifferentPreferenceFieldsSurviveFlush() throws {
        try withDefaults { defaults in
            let store = makeStore(defaults)
            defer { store.flushSynchronously() }
            var expected = distinctivePreferences()
            store.savePreferences(expected)
            let tracks = TrackSelectionPreferences(audioLanguages: ["es", "ja"],
                subtitleLanguages: ["de"], subtitles: .always,
                prefersAccessibleTracks: true, avoidsCommentary: true)
            DispatchQueue.concurrentPerform(iterations: 4) { worker in
                for _ in 0..<32 {
                    switch worker {
                    case 0: store.setVolume(77)
                    case 1: store.setPlaybackSpeed(1.75)
                    case 2: store.setTrackSelectionPreferences(tracks)
                    default: store.setPreferredAudioOutputDeviceID(" USB-DAC ")
                    }
                }
            }
            expected.volume = 77
            expected.playbackSpeed = 1.75
            expected.trackSelection = tracks
            expected.preferredAudioOutputDeviceID = "USB-DAC"
            try expectPersisted(expected, from: store, defaults: defaults)
            #expect(defaults.data(forKey: scalarHistoryKey) == nil)
        }
    }

    private func distinctivePreferences() -> PlaybackPreferences {
        PlaybackPreferences(volume: 27.5, isMuted: true, playbackSpeed: 1.5,
            isSidebarVisible: false, repeatMode: .one, isShuffleEnabled: true,
            hardwareDecodingPolicy: .off, preferredAudioOutputDeviceID: "USB-🎧",
            subtitleFallbackEncoding: .shiftJIS,
            trackSelection: TrackSelectionPreferences(audioLanguages: ["ja", "fr"],
                subtitleLanguages: ["en", "de"], subtitles: .forcedOnly,
                prefersAccessibleTracks: true, avoidsCommentary: false),
            remembersPlaybackHistory: false, restoresSessionPaused: false)
    }

    private func makeStore(_ defaults: UserDefaults) -> PlaybackPersistenceStore {
        PlaybackPersistenceStore(userDefaults: defaults, namespace: scalarPreferenceNamespace)
    }

    private func withDefaults(_ body: (ScalarPreferenceDefaults) throws -> Void) throws {
        let suite = "IlliquidScalarPreferenceTests.\(UUID().uuidString)"
        let defaults = try #require(ScalarPreferenceDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    private func expectPersisted(_ expected: PlaybackPreferences,
                                 from store: PlaybackPersistenceStore,
                                 defaults: UserDefaults) throws {
        #expect(store.loadPreferences() == expected)
        store.flushSynchronously()
        let data = try #require(defaults.data(forKey: scalarPreferenceKey))
        // Decode raw scalars without PlaybackPreferences' sanitizing initializer.
        // JSONSerialization's NSNumber decimal bridge can round adjacent Double
        // values; direct Double decoding keeps these boundary assertions exact.
        let scalars = try JSONDecoder().decode(PersistedPreferenceScalars.self, from: data)
        #expect(scalars.volume == expected.volume)
        #expect(scalars.playbackSpeed == expected.playbackSpeed)
        #expect(try JSONDecoder().decode(PlaybackPreferences.self, from: data) == expected)
        #expect(makeStore(defaults).loadPreferences() == expected)
    }
}
