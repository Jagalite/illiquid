import Foundation
import Testing
@testable import SuperplayrCore

@Suite("History opt-out and recovery")
struct HistoryPolicyTests {
    @Test func optOutPreservesExistingHistoryButDoesNotRecordNewProgress() throws {
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PlaybackPersistenceStore(userDefaults: defaults, namespace: "UX")
        let old = URL(fileURLWithPath: "/tmp/old.mkv")
        let new = URL(fileURLWithPath: "/tmp/private.mkv")
        store.setPlaybackPosition(10, for: old)
        var preferences = store.loadPreferences()
        preferences.remembersPlaybackHistory = false
        store.savePreferences(preferences)
        store.setPlaybackPosition(20, for: old)
        store.setPlaybackProgress(position: 50, duration: 100, for: new)
        store.setLastOpenedMedia(.file(new))
        store.setLastWatchedFile(new, for: new.deletingLastPathComponent())
        store.setMediaSettings(.init(subtitleDelay: 1), for: new)
        store.markPlaybackCompleted(for: new)
        store.flushSynchronously()
        let reloaded = PlaybackPersistenceStore(userDefaults: defaults, namespace: "UX")
        #expect(!reloaded.loadPreferences().remembersPlaybackHistory)
        #expect(reloaded.playbackPosition(for: old) == 10)
        #expect(reloaded.playbackProgress(for: new) == nil)
        #expect(reloaded.lastOpenedMedia() == nil)
        #expect(reloaded.lastWatchedFile(for: new.deletingLastPathComponent()) == nil)
        #expect(reloaded.mediaSettings(for: new) == nil)
        reloaded.clearPlaybackHistory()
        #expect(reloaded.playbackPosition(for: old) == nil)
    }

    @Test func malformedHistoryIsNotOverwrittenByOrdinaryPlayback() throws {
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let corrupt = Data("not valid json".utf8)
        defaults.set(corrupt, forKey: "UX.playback-state.v1")
        let store = PlaybackPersistenceStore(userDefaults: defaults, namespace: "UX")
        #expect(store.hasUnreadableHistory)
        store.setPlaybackPosition(10, for: URL(fileURLWithPath: "/tmp/new.mkv"))
        store.setVolume(50)
        store.flushSynchronously()
        #expect(defaults.data(forKey: "UX.playback-state.v1") == corrupt)
        store.clearPlaybackProgress()
        store.clearRememberedMediaSettings()
        store.flushSynchronously()
        #expect(store.hasUnreadableHistory)
        #expect(defaults.data(forKey: "UX.playback-state.v1") == corrupt)
        store.clearPlaybackHistory()
        store.flushSynchronously()
        #expect(!store.hasUnreadableHistory)
        #expect(defaults.data(forKey: "UX.playback-state.v1") != corrupt)
    }

    @Test func oldPreferencesMigrateToRememberingHistoryAndPausedRestore() throws {
        let preferences = try JSONDecoder().decode(PlaybackPreferences.self, from: Data("{}".utf8))
        #expect(preferences.remembersPlaybackHistory)
        #expect(preferences.restoresSessionPaused)
    }
}
