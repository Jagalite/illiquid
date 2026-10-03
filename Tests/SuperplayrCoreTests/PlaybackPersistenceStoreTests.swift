import Foundation
import Testing
@testable import SuperplayrCore

@Suite("Playback persistence")
struct PlaybackPersistenceStoreTests {
    @Test("Defaults and validated preference updates")
    func defaultPreferencesAndValidatedUpdates() {
        withStore { store, _ in
            #expect(store.loadPreferences() == PlaybackPreferences.standard)

            store.setVolume(42)
            store.setMuted(true)
            store.setPlaybackSpeed(1.5)
            store.setSidebarVisible(false)
            store.setRepeatMode(.all)
            store.setShuffleEnabled(true)
            store.setPreferredAudioOutputDeviceID("usb-dac")

            #expect(
                store.loadPreferences() == PlaybackPreferences(
                    volume: 42,
                    isMuted: true,
                    playbackSpeed: 1.5,
                    isSidebarVisible: false,
                    repeatMode: .all,
                    isShuffleEnabled: true,
                    preferredAudioOutputDeviceID: "usb-dac"
                )
            )

            store.setVolume(500)
            store.setPlaybackSpeed(-4)
            #expect(store.loadPreferences().volume == 100)
            #expect(store.loadPreferences().playbackSpeed == 1)
            #expect(store.loadPreferences().repeatMode == .all)
            #expect(store.loadPreferences().isShuffleEnabled)
            #expect(store.loadPreferences().preferredAudioOutputDeviceID == "usb-dac")

            store.setPreferredAudioOutputDeviceID("auto")
            #expect(store.loadPreferences().preferredAudioOutputDeviceID == nil)
        }
    }

    @Test("Positions use normalized identities and persist across instances")
    func positionUsesNormalizedFileIdentityAndPersistsAcrossInstances() {
        withStore { store, defaults in
            let directURL = URL(fileURLWithPath: "/tmp/Shows/Episode.mkv")
            let equivalentURL = URL(fileURLWithPath: "/tmp/Shows/Season/../Episode.mkv")
            #expect(store.setPlaybackPosition(125.25, for: equivalentURL))
            #expect(store.playbackPosition(for: directURL) == 125.25)

            store.flushSynchronously()
            let reloaded = PlaybackPersistenceStore(
                userDefaults: defaults,
                namespace: "Tests"
            )
            #expect(reloaded.playbackPosition(for: directURL) == 125.25)
        }
    }

    @Test("Platinum continues using the legacy Superplayr defaults namespace")
    func platinumRetainsLegacyDefaultsNamespace() {
        let suiteName = "PlatinumPersistenceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let fileURL = URL(fileURLWithPath: "/tmp/Shows/Legacy Episode.mkv")
        let legacyStore = PlaybackPersistenceStore(userDefaults: defaults)
        #expect(legacyStore.setPlaybackPosition(73.5, for: fileURL))
        legacyStore.flushSynchronously()
        #expect(defaults.data(forKey: "Superplayr.playback-state.v1") != nil)

        let platinumStore = PlaybackPersistenceStore(userDefaults: defaults)
        #expect(platinumStore.playbackPosition(for: fileURL) == 73.5)
    }

    @Test("Rejects invalid positions and remote URLs")
    func rejectsInvalidPositionsAndRemoteURLs() throws {
        try withStore { store, _ in
            let fileURL = URL(fileURLWithPath: "/tmp/Movie.mkv")
            #expect(!store.setPlaybackPosition(-1, for: fileURL))
            #expect(!store.setPlaybackPosition(.infinity, for: fileURL))
            let remoteURL = try #require(URL(string: "https://example.com/movie.mp4"))
            #expect(!store.setPlaybackPosition(10, for: remoteURL))
            #expect(store.playbackPosition(for: fileURL) == nil)
        }
    }

    @Test("Last watched file can be restored and cleared")
    func lastWatchedFileCanBeRestoredAndCleared() throws {
        try withStore { store, _ in
            let folderURL = URL(fileURLWithPath: "/tmp/Shows", isDirectory: true)
            let fileURL = folderURL.appendingPathComponent("Episode 2.mkv")

            store.setLastWatchedFile(fileURL, for: folderURL)
            let restoredFile = try #require(store.lastWatchedFile(for: folderURL))
            #expect(NormalizedFileURL.representsSameFile(restoredFile, fileURL))

            store.setLastWatchedFile(nil, for: folderURL)
            #expect(store.lastWatchedFile(for: folderURL) == nil)
        }
    }

    @Test("Last opened file or folder persists across store instances")
    func lastOpenedMediaPersistsAcrossStoreInstances() throws {
        try withStore { store, defaults in
            let folderURL = URL(fileURLWithPath: "/tmp/Shows/Season/..", isDirectory: true)
            #expect(store.setLastOpenedMedia(.folder(folderURL)))

            store.flushSynchronously()
            var reloaded = PlaybackPersistenceStore(
                userDefaults: defaults,
                namespace: "Tests"
            )
            let restoredFolder = try #require(reloaded.lastOpenedMedia())
            guard case let .folder(restoredFolderURL) = restoredFolder else {
                Issue.record("Expected a folder restore target")
                return
            }
            #expect(restoredFolderURL.path == "/tmp/Shows")

            let fileURL = URL(fileURLWithPath: "/tmp/Shows/Episode 2.mkv")
            #expect(reloaded.setLastOpenedMedia(.file(fileURL)))
            reloaded.flushSynchronously()
            reloaded = PlaybackPersistenceStore(
                userDefaults: defaults,
                namespace: "Tests"
            )
            let restoredFile = try #require(reloaded.lastOpenedMedia())
            guard case let .file(restoredFileURL) = restoredFile else {
                Issue.record("Expected a file restore target")
                return
            }
            #expect(NormalizedFileURL.representsSameFile(restoredFileURL, fileURL))
        }
    }

    @Test("Last opened media rejects remote URLs")
    func lastOpenedMediaRejectsRemoteURLs() throws {
        try withStore { store, _ in
            let remoteURL = try #require(URL(string: "https://example.com/movie.mp4"))
            #expect(!store.setLastOpenedMedia(.file(remoteURL)))
            #expect(store.lastOpenedMedia() == nil)
        }
    }

    @Test("Existing version one state decodes without a restore target")
    func legacyStateWithoutRestoreTargetStillDecodes() throws {
        try withStore { _, defaults in
            let legacyState: [String: Any] = [
                "playbackPositions": ["/tmp/Movie.mkv": 18.5],
                "lastWatchedFiles": [:],
                "preferences": [
                    "volume": 46.0,
                    "isMuted": true,
                    "playbackSpeed": 1.25,
                    "isSidebarVisible": false,
                ],
            ]
            defaults.set(
                try JSONSerialization.data(withJSONObject: legacyState),
                forKey: "Tests.playback-state.v1"
            )

            let reloaded = PlaybackPersistenceStore(
                userDefaults: defaults,
                namespace: "Tests"
            )
            #expect(reloaded.playbackPosition(for: URL(fileURLWithPath: "/tmp/Movie.mkv")) == 18.5)
            #expect(reloaded.loadPreferences().volume == 46)
            #expect(reloaded.lastOpenedMedia() == nil)
        }
    }

    @Test("Clearing history preserves preferences")
    func clearHistoryPreservesPreferences() {
        withStore { store, _ in
            let folderURL = URL(fileURLWithPath: "/tmp/Shows", isDirectory: true)
            let fileURL = folderURL.appendingPathComponent("Episode.mkv")
            store.setVolume(35)
            store.setPlaybackPosition(20, for: fileURL)
            store.setLastWatchedFile(fileURL, for: folderURL)
            store.setLastOpenedMedia(.folder(folderURL))

            store.clearPlaybackHistory()

            #expect(store.playbackPosition(for: fileURL) == nil)
            #expect(store.lastWatchedFile(for: folderURL) == nil)
            #expect(store.lastOpenedMedia() == nil)
            #expect(store.loadPreferences().volume == 35)
        }
    }

    @Test("Playback progress and remembered media choices can be cleared independently")
    func clearPlaybackDataScopesIndependently() {
        withStore { store, _ in
            let folderURL = URL(fileURLWithPath: "/tmp/Shows", isDirectory: true)
            let fileURL = folderURL.appendingPathComponent("Episode.mkv")
            let mediaSettings = MediaPlaybackSettings(
                areSubtitlesVisible: false,
                subtitleDelay: 0.4
            )
            store.setPlaybackPosition(20, for: fileURL)
            store.setLastWatchedFile(fileURL, for: folderURL)
            store.setLastOpenedMedia(.folder(folderURL))
            store.setMediaSettings(mediaSettings, for: fileURL)

            store.clearPlaybackProgress()

            #expect(store.playbackPosition(for: fileURL) == nil)
            #expect(store.lastWatchedFile(for: folderURL) == nil)
            #expect(store.lastOpenedMedia() == nil)
            #expect(store.mediaSettings(for: fileURL) == mediaSettings)

            store.setPlaybackPosition(30, for: fileURL)
            store.clearRememberedMediaSettings()

            #expect(store.playbackPosition(for: fileURL) == 30)
            #expect(store.mediaSettings(for: fileURL) == nil)
        }
    }

    @Test("Per-file track and subtitle settings use stable metadata")
    func perFileTrackAndSubtitleSettingsUseStableMetadata() {
        withStore { store, defaults in
            let file = URL(fileURLWithPath: "/tmp/Show/Episode.mkv")
            let settings = MediaPlaybackSettings(
                audioTrack: MediaTrackPreference(track: MediaTrack(
                    id: 91,
                    kind: .audio,
                    title: "Commentary",
                    languageCode: "en",
                    codec: "aac"
                )),
                subtitleTrack: MediaTrackPreference(track: MediaTrack(
                    id: 44,
                    kind: .subtitle,
                    title: "English",
                    languageCode: "en",
                    codec: "ass"
                )),
                areSubtitlesVisible: true,
                subtitleDelay: 0.4
            )
            store.setMediaSettings(settings, for: file)
            store.flushSynchronously()
            let reloaded = PlaybackPersistenceStore(
                userDefaults: defaults,
                namespace: "Tests"
            )
            let restored = reloaded.mediaSettings(for: file)

            #expect(restored == settings)
            let renumbered = MediaTrack(
                id: 2,
                kind: .audio,
                title: "Commentary",
                languageCode: "en",
                codec: "aac"
            )
            #expect(restored?.audioTrack?.bestMatch(in: [renumbered]) == renumbered)
        }
    }

    private func withStore(
        _ body: (PlaybackPersistenceStore, UserDefaults) throws -> Void
    ) rethrows {
        let suiteName = "SuperplayrTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = PlaybackPersistenceStore(userDefaults: defaults, namespace: "Tests")
        defer { store.flushSynchronously() }
        try body(store, defaults)
    }
}
