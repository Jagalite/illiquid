import Foundation
import Testing
@testable import IlliquidCore

@Suite("History JSON encoding")
struct HistoryJSONEncodingTests {
    private let namespace = "HistoryJSONEncoding"
    private var historyKey: String { "\(namespace).playback-state.v1" }

    @Test(arguments: [false, true])
    func readsAndRewritesBothLegacySlashForms(slashEscaped: Bool) async throws {
        let suite = "IlliquidHistoryJSON-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        // Older history documents can omit the fields added in later releases.
        let seed: String
        if slashEscaped {
            seed = #"""
                {
                  "playbackPositions": {"\/synthetic\/history\/show\/episode.mkv": 42.5},
                  "playbackDurations": {"\/synthetic\/history\/show\/episode.mkv": 1000},
                  "lastWatchedFiles": {"\/synthetic\/history\/show": "\/synthetic\/history\/show\/episode.mkv"},
                  "lastOpenedMedia": {"kind": "folder", "path": "\/synthetic\/history\/show"}
                }
                """#
        } else {
            seed = #"""
                {
                  "playbackPositions": {"/synthetic/history/show/episode.mkv": 42.5},
                  "playbackDurations": {"/synthetic/history/show/episode.mkv": 1000},
                  "lastWatchedFiles": {"/synthetic/history/show": "/synthetic/history/show/episode.mkv"},
                  "lastOpenedMedia": {"kind": "folder", "path": "/synthetic/history/show"}
                }
                """#
        }
        defaults.set(Data(seed.utf8), forKey: historyKey)

        let file = URL(fileURLWithPath: "/synthetic/history/show/episode.mkv")
        let folder = URL(fileURLWithPath: "/synthetic/history/show", isDirectory: true)
        let store = PlaybackPersistenceStore(userDefaults: defaults, namespace: namespace)
        defer { store.flushSynchronously() }
        #expect(!store.hasUnreadableHistory)
        #expect(store.playbackPosition(for: file) == 42.5)
        #expect(store.playbackProgress(for: file)?.duration == 1000)
        #expect(store.lastWatchedFile(for: folder) == file)
        #expect(store.lastOpenedMedia() == PlaybackRestoreTarget.folder(folder))

        #expect(store.setPlaybackPosition(57.25, for: file))
        try await store.flush().get()

        let restored = PlaybackPersistenceStore(userDefaults: defaults, namespace: namespace)
        #expect(!restored.hasUnreadableHistory)
        #expect(restored.playbackPosition(for: file) == 57.25)
        #expect(restored.playbackProgress(for: file)?.duration == 1000)
        #expect(restored.lastWatchedFile(for: folder) == file)
        #expect(restored.lastOpenedMedia() == PlaybackRestoreTarget.folder(folder))
        #expect(restored.loadPreferences() == .standard)
    }

    @Test
    func roundTripsCompleteHistoryWithDifficultPathsAndMetadata() async throws {
        let suite = "IlliquidHistoryJSON-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PlaybackPersistenceStore(userDefaults: defaults, namespace: namespace)
        defer { store.flushSynchronously() }

        // Lexical identities only: no media files or directories are created.
        // A component's trailing backslash is immediately before a separator.
        let folder = try #require(NormalizedFileURL.normalize(URL(
            fileURLWithPath:
                "/synthetic/history/quote \"folder\"/backslash\\/日本語 🌙/literal %2F/line\nbreak\tsegment",
            isDirectory: true
        )))
        let file = try #require(NormalizedFileURL.normalize(folder.appendingPathComponent(
            "episode \"quoted\" \\ 100%25 日本語.mkv"
        )))
        let completedFile = folder.appendingPathComponent("completed.mkv")
        #expect(file.path.contains("\\/"))

        let title = "quoted \"title\" / backslash \\/\nline\t日本語 🌙 %2F \u{2028}\u{2029} tail"
        let externalFilename = "subtitles\\/\nEnglish \"CC\" %2F 日本語.srt"
        let originalSettings = MediaPlaybackSettings(
            audioTrack: MediaTrackPreference(track: MediaTrack(
                id: 9, kind: .audio, title: title, languageCode: "ja", codec: "aac"
            )),
            subtitleTrack: MediaTrackPreference(track: MediaTrack(
                id: 17, kind: .subtitle, title: title, languageCode: "en",
                codec: "ass", isExternal: true, externalFilename: externalFilename
            )),
            areSubtitlesVisible: false,
            subtitleDelay: 2.5
        )
        let completedSettings = MediaPlaybackSettings(
            areSubtitlesVisible: true, subtitleDelay: -1.25
        )
        var currentSettings = originalSettings
        currentSettings.areSubtitlesVisible = true
        currentSettings.subtitleDelay = -0.75
        var preferences = store.loadPreferences()
        preferences.volume = 37
        preferences.isMuted = true
        store.savePreferences(preferences)

        #expect(store.acceptMediaVersion(version(1), for: file) == .firstObservation)
        #expect(store.setPlaybackProgress(position: 42.5, duration: 1000, for: file))
        store.setMediaSettings(originalSettings, for: file)

        // Preserve an unfinished version and then a completed version in order.
        #expect(store.acceptMediaVersion(version(2), for: file) == .changed)
        #expect(store.setPlaybackProgress(position: 950, duration: 1000, for: file))
        store.setMediaSettings(completedSettings, for: file)
        #expect(store.acceptMediaVersion(version(3), for: file) == .changed)
        #expect(store.setPlaybackProgress(position: 74.25, duration: 1200, for: file))
        store.setMediaSettings(currentSettings, for: file)
        #expect(store.acceptMediaVersion(version(4), for: completedFile) == .firstObservation)
        #expect(store.setPlaybackProgress(position: 950, duration: 1000, for: completedFile))
        store.setLastWatchedFile(file, for: folder)
        #expect(store.setLastOpenedMedia(.file(file)))
        try await store.flush().get()

        let restored = PlaybackPersistenceStore(userDefaults: defaults, namespace: namespace)
        #expect(!restored.hasUnreadableHistory)
        #expect(restored.playbackPosition(for: file) == 74.25)
        #expect(restored.playbackProgress(for: file) == MediaPlaybackProgress(
            position: 74.25, duration: 1200, isCompleted: false
        ))
        #expect(restored.playbackPosition(for: completedFile) == nil)
        #expect(restored.playbackProgress(for: completedFile) == MediaPlaybackProgress(
            position: 1000, duration: 1000, isCompleted: true
        ))
        #expect(restored.lastWatchedFile(for: folder) == file)
        #expect(restored.lastOpenedMedia() == PlaybackRestoreTarget.file(file))
        #expect(restored.mediaSettings(for: file) == currentSettings)
        #expect(restored.mediaVersion(for: file) == version(3))
        #expect(restored.mediaVersion(for: completedFile) == version(4))
        #expect(restored.loadPreferences() == preferences)

        let archives = restored.replacedMediaHistory(for: file)
        #expect(archives.count == 2)
        let first = try #require(archives.first)
        let second = try #require(archives.dropFirst().first)
        #expect(first.version == version(1))
        #expect(first.position == 42.5)
        #expect(first.duration == 1000)
        #expect(!first.isCompleted)
        #expect(first.mediaSettings == originalSettings)
        #expect(second.version == version(2))
        #expect(second.position == nil)
        #expect(second.duration == 1000)
        #expect(second.isCompleted)
        #expect(second.mediaSettings == completedSettings)
    }

    @Test
    func newHistoryDoesNotAddOptionalSlashEscapes() async throws {
        let suite = "IlliquidHistoryJSON-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PlaybackPersistenceStore(userDefaults: defaults, namespace: namespace)
        defer { store.flushSynchronously() }

        // No literal backslashes: substring matching would otherwise be ambiguous.
        let file = URL(fileURLWithPath: "/synthetic/history/series/season/episode.mkv")
        let folder = file.deletingLastPathComponent()
        #expect(store.setPlaybackProgress(position: 21.5, duration: 1000, for: file))
        store.setLastWatchedFile(file, for: folder)
        #expect(store.setLastOpenedMedia(.file(file)))
        try await store.flush().get()

        let data = try #require(defaults.data(forKey: historyKey))
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("\"\(file.path)\""))
        #expect(!json.contains(#"\/"#))
        let restored = PlaybackPersistenceStore(userDefaults: defaults, namespace: namespace)
        #expect(!restored.hasUnreadableHistory)
        #expect(restored.playbackPosition(for: file) == 21.5)
        #expect(restored.lastWatchedFile(for: folder) == file)
        #expect(restored.lastOpenedMedia() == PlaybackRestoreTarget.file(file))
    }

    private func version(_ identifier: UInt64) -> MediaContentVersion {
        MediaContentVersion(
            fileIdentifier: identifier,
            byteCount: 1_048_576,
            modificationSeconds: 1_700_000_000,
            modificationNanoseconds: 123_456_789,
            creationSeconds: 1_600_000_000,
            creationNanoseconds: 987_654_321
        )
    }
}
