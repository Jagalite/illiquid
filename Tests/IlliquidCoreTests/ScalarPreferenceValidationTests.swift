import Foundation
import Testing
@testable import IlliquidCore

@Suite("Scalar preference validation")
struct ScalarPreferenceValidationTests {
    private struct LegacyHistory: Encodable {
        let preferences: PlaybackPreferences
    }

    @Test(
        "Volume and speed preserve preferences sanitized at every ingress",
        arguments: ["legacyHistory", "separatePreferences", "savePreferences"]
    )
    func scalarUpdatesPreserveSanitizedPreferences(ingress: String) throws {
        let suiteName = "IlliquidScalarPreferenceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let namespace = "ScalarTests"
        let historyKey = "\(namespace).playback-state.v1"
        let preferencesKey = "\(namespace).playback-preferences.v1"
        let raw = Self.rawPreferences()
        let encoder = JSONEncoder()

        if ingress == "legacyHistory" {
            defaults.set(
                try encoder.encode(LegacyHistory(preferences: raw)),
                forKey: historyKey
            )
        } else if ingress == "separatePreferences" {
            // The separate preference key must override conflicting legacy values.
            defaults.set(
                try encoder.encode(LegacyHistory(preferences: .standard)),
                forKey: historyKey
            )
            defaults.set(try encoder.encode(raw), forKey: preferencesKey)
        }

        let store = PlaybackPersistenceStore(
            userDefaults: defaults, namespace: namespace
        )
        defer { store.flushSynchronously() }
        if ingress == "savePreferences" {
            store.savePreferences(raw)
        }

        var expected = PlaybackPreferences(
            volume: 0, isMuted: true, playbackSpeed: 4, isSidebarVisible: false,
            repeatMode: .all, isShuffleEnabled: true, hardwareDecodingPolicy: .off,
            preferredAudioOutputDeviceID: "usb-dac",
            subtitleFallbackEncoding: .shiftJIS,
            trackSelection: TrackSelectionPreferences(
                audioLanguages: ["en", "ja"], subtitleLanguages: ["fr", "es"],
                subtitles: .forcedOnly, prefersAccessibleTracks: true,
                avoidsCommentary: false
            ),
            remembersPlaybackHistory: false, restoresSessionPaused: false
        )
        #expect(!store.hasUnreadableHistory)
        #expect(store.loadPreferences() == expected)

        let cases: [(input: Double, volume: Double, speed: Double)] = [
            (.nan, 100, 1),
            (.infinity, 100, 1),
            (-.infinity, 100, 1),
            (-Double.greatestFiniteMagnitude, 0, 1),
            (-Double.leastNonzeroMagnitude, 0, 1),
            (0, 0, 1),
            (Double.leastNonzeroMagnitude, Double.leastNonzeroMagnitude, 0.25),
            (0.1, 0.1, 0.25),
            (0.25, 0.25, 0.25),
            (1.5, 1.5, 1.5),
            (4, 4, 4),
            (100, 100, 4),
            (Double.greatestFiniteMagnitude, 100, 4),
        ]
        for value in cases {
            store.setVolume(value.input)
            expected.volume = value.volume
            #expect(store.loadPreferences() == expected)
            store.setPlaybackSpeed(value.input)
            expected.playbackSpeed = value.speed
            #expect(store.loadPreferences() == expected)
        }

        // Signed-zero behavior must agree with the established public initializer.
        let zeroReference = PlaybackPreferences(
            volume: -0.0, isMuted: false, playbackSpeed: -0.0, isSidebarVisible: true
        )
        store.setVolume(-0.0)
        store.setPlaybackSpeed(-0.0)
        expected.volume = zeroReference.volume
        expected.playbackSpeed = zeroReference.playbackSpeed
        #expect(store.loadPreferences() == expected)
        #expect(store.loadPreferences().volume.bitPattern == zeroReference.volume.bitPattern)

        store.setVolume(42)
        store.setPlaybackSpeed(1.5)
        expected.volume = 42
        expected.playbackSpeed = 1.5
        store.flushSynchronously()
        let reloaded = PlaybackPersistenceStore(
            userDefaults: defaults, namespace: namespace
        )
        #expect(reloaded.loadPreferences() == expected)
    }

    private static func rawPreferences() -> PlaybackPreferences {
        var value = PlaybackPreferences.standard
        value.volume = -25
        value.playbackSpeed = 9
        value.isMuted = true
        value.isSidebarVisible = false
        value.repeatMode = .all
        value.isShuffleEnabled = true
        value.hardwareDecodingPolicy = .off
        value.preferredAudioOutputDeviceID = "  usb-dac \n"
        value.subtitleFallbackEncoding = .shiftJIS
        value.remembersPlaybackHistory = false
        value.restoresSessionPaused = false
        value.trackSelection.audioLanguages = [" EN ", "en", "JA", " "]
        value.trackSelection.subtitleLanguages = [" FR ", "fr", "ES", ""]
        value.trackSelection.subtitles = .forcedOnly
        value.trackSelection.prefersAccessibleTracks = true
        value.trackSelection.avoidsCommentary = false
        return value
    }
}
