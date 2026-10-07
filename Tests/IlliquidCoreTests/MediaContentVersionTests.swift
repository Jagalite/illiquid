import Foundation
import Testing
@testable import IlliquidCore

@Suite("Versioned playback history")
struct MediaContentVersionTests {
    private func version(_ identifier: UInt64) -> MediaContentVersion {
        .init(fileIdentifier: identifier, byteCount: 1_024,
              modificationSeconds: 100, modificationNanoseconds: 0,
              creationSeconds: 50, creationNanoseconds: 0)
    }

    @Test func replacementArchivesOldProgressAndSettingsWithoutApplyingThemToNewContent() throws {
        let name = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = PlaybackPersistenceStore(userDefaults: defaults, namespace: name)
        let file = URL(fileURLWithPath: "/tmp/movie.mkv")
        store.setPlaybackProgress(position: 100, duration: 1_000, for: file)
        store.setMediaSettings(.init(areSubtitlesVisible: false, subtitleDelay: 2), for: file)
        #expect(store.acceptMediaVersion(version(1), for: file) == .firstObservation)
        #expect(store.playbackPosition(for: file) == 100) // Legacy migration preserves history.
        #expect(store.acceptMediaVersion(version(1), for: file) == .unchanged)
        #expect(store.acceptMediaVersion(version(2), for: file) == .changed)
        #expect(store.playbackProgress(for: file) == nil)
        #expect(store.mediaSettings(for: file) == nil)
        store.flushSynchronously()
        let restored = PlaybackPersistenceStore(userDefaults: defaults, namespace: name)
        let archive = try #require(restored.replacedMediaHistory(for: file).first)
        #expect(archive.position == 100)
        #expect(archive.mediaSettings?.subtitleDelay == 2)
        #expect(restored.mediaVersion(for: file) == version(2))
        restored.clearPlaybackProgress()
        #expect(restored.replacedMediaHistory(for: file).first?.position == nil)
        #expect(restored.replacedMediaHistory(for: file).first?.mediaSettings != nil)
        restored.clearRememberedMediaSettings()
        #expect(restored.replacedMediaHistory(for: file).first?.mediaSettings == nil)
        restored.clearPlaybackHistory()
        #expect(restored.mediaVersion(for: file) == nil)
        #expect(restored.replacedMediaHistory(for: file).isEmpty)
    }

    @Test func explicitLocateCopiesOnlyMatchingVersionsAndKeepsOriginalHistory() throws {
        let name = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = PlaybackPersistenceStore(userDefaults: defaults, namespace: name)
        let old = URL(fileURLWithPath: "/tmp/original.mkv")
        let new = URL(fileURLWithPath: "/tmp/renamed.mkv")
        store.acceptMediaVersion(version(1), for: old)
        store.setPlaybackPosition(42, for: old)
        store.setMediaSettings(.init(subtitleDelay: 0.5), for: old)
        #expect(!store.copyHistoryForLocatedMedia(from: old, to: new, version: version(2)))
        #expect(store.playbackPosition(for: new) == nil)
        #expect(store.copyHistoryForLocatedMedia(from: old, to: new, version: version(1)))
        #expect(store.playbackPosition(for: new) == 42)
        #expect(store.playbackPosition(for: old) == 42)
        #expect(store.mediaSettings(for: new)?.subtitleDelay == 0.5)
    }
}
