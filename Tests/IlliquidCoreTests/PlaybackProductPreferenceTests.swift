import Foundation
import Testing
@testable import IlliquidCore

@Suite("Playback product preference isolation")
struct PlaybackProductPreferenceTests {
    enum Mutation: String, CaseIterable, Sendable {
        case volume, muted, speed, sidebar, repeatMode, shuffle, hardware, output, tracks, encoding

        func apply(to store: PlaybackPersistenceStore, expected: inout PlaybackPreferences) {
            switch self {
            case .volume:
                store.setVolume(27); expected.volume = 27
            case .muted:
                store.setMuted(false); expected.isMuted = false
            case .speed:
                store.setPlaybackSpeed(1.75); expected.playbackSpeed = 1.75
            case .sidebar:
                store.setSidebarVisible(true); expected.isSidebarVisible = true
            case .repeatMode:
                store.setRepeatMode(.one); expected.repeatMode = .one
            case .shuffle:
                store.setShuffleEnabled(false); expected.isShuffleEnabled = false
            case .hardware:
                store.setHardwareDecodingPolicy(.off); expected.hardwareDecodingPolicy = .off
            case .output:
                store.setPreferredAudioOutputDeviceID("second-output"); expected.preferredAudioOutputDeviceID = "second-output"
            case .tracks:
                let value = TrackSelectionPreferences(audioLanguages: ["jpn"], subtitleLanguages: ["eng"], subtitles: .off)
                store.setTrackSelectionPreferences(value); expected.trackSelection = value
            case .encoding:
                store.setSubtitleFallbackEncoding(.shiftJIS); expected.subtitleFallbackEncoding = .shiftJIS
            }
        }
    }

    @Test(arguments: Mutation.allCases)
    func everySetterPreservesUnrelatedFieldsThroughRealStoreReload(_ mutation: Mutation) throws {
        for history in [false, true] {
            for paused in [false, true] {
                let domain = "IlliquidPreferenceIsolation-\(UUID().uuidString)"
                let defaults = try #require(UserDefaults(suiteName: domain))
                let store = PlaybackPersistenceStore(userDefaults: defaults, namespace: "Test")
                defer {
                    store.flushSynchronously()
                    defaults.removePersistentDomain(forName: domain)
                }
                var expected = PlaybackPreferences(volume: 63, isMuted: true,
                    playbackSpeed: 1.25, isSidebarVisible: false, repeatMode: .all,
                    isShuffleEnabled: true, hardwareDecodingPolicy: .compatibility,
                    preferredAudioOutputDeviceID: "first-output", subtitleFallbackEncoding: .windows1251,
                    trackSelection: .init(audioLanguages: ["fra"], subtitleLanguages: ["deu"],
                        subtitles: .forcedOnly, prefersAccessibleTracks: true, avoidsCommentary: false),
                    remembersPlaybackHistory: history, restoresSessionPaused: paused)
                store.savePreferences(expected)
                mutation.apply(to: store, expected: &expected)
                #expect(store.loadPreferences() == expected)
                store.flushSynchronously()
                let reloaded = PlaybackPersistenceStore(userDefaults: defaults, namespace: "Test")
                #expect(reloaded.loadPreferences() == expected)
                let file = URL(fileURLWithPath: "/tmp/preference-isolation.mkv")
                reloaded.setPlaybackPosition(24, for: file)
                #expect(reloaded.playbackPosition(for: file) == (history ? 24 : nil))
                reloaded.flushSynchronously()
            }
        }
    }

    @Test func scalarValidationDoesNotReenableHistory() throws {
        let domain = "IlliquidPreferenceValidation-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        let store = PlaybackPersistenceStore(userDefaults: defaults, namespace: "Test")
        defer { store.flushSynchronously(); defaults.removePersistentDomain(forName: domain) }
        var preferences = PlaybackPreferences.standard
        preferences.remembersPlaybackHistory = false
        preferences.restoresSessionPaused = false
        store.savePreferences(preferences)
        for value in [Double.nan, .infinity, -.infinity, -10, 1_000] {
            store.setVolume(value)
            store.setPlaybackSpeed(value)
            let saved = store.loadPreferences()
            #expect(!saved.remembersPlaybackHistory)
            #expect(!saved.restoresSessionPaused)
            #expect(saved.volume.isFinite && (0...100).contains(saved.volume))
            #expect(saved.playbackSpeed.isFinite && (0.25...4).contains(saved.playbackSpeed))
        }
    }
}
