import Foundation
import SuperplayrCore
import SuperplayrPlayback

/// Framework-independent validation for toolchains that ship without XCTest
/// or Swift Testing. A failure is returned as a stable, human-readable label.
public enum ArchitectureValidation {
    @MainActor
    public static func run() -> [String] {
        var failures: [String] = []
        func check(_ condition: @autoclosure () -> Bool, _ label: String) {
            if !condition() { failures.append(label) }
        }

        let state = PlaybackState()
        check(state.phase == .idle && state.isPaused && !state.isLoading, "idle lifecycle")
        state.applyAuthorityProjection(.init(
            phase: .loading, position: 0, duration: 0, isBuffering: false,
            selectedAudioID: nil, selectedSubtitleID: nil,
            subtitleDelay: 0, failureCode: nil
        ))
        check(state.phase == .loading && state.isLoading, "loading lifecycle")
        state.applyAuthorityProjection(.init(
            phase: .playing, position: 12, duration: 1_200, isBuffering: false,
            selectedAudioID: nil, selectedSubtitleID: nil,
            subtitleDelay: 0, failureCode: nil
        ))
        check(
            state.position == 12 && state.duration == 1_200,
            "core timing projection"
        )
        state.applyAuthorityProjection(.init(
            phase: .buffering, position: 12, duration: 1_200, isBuffering: true,
            selectedAudioID: nil, selectedSubtitleID: nil,
            subtitleDelay: 0, failureCode: nil
        ))
        check(state.phase == .buffering && state.isLoading, "buffering lifecycle")
        state.applyAuthorityProjection(.init(
            phase: .paused, position: 12, duration: 1_200, isBuffering: false,
            selectedAudioID: nil, selectedSubtitleID: nil,
            subtitleDelay: 0, failureCode: nil
        ))
        check(state.phase == .paused && state.isPaused && !state.isLoading, "paused lifecycle")

        let local = URL(fileURLWithPath: "/Media/movie.mkv")
        let remote = URL(string: "https://example.com/movie.m3u8")!
        check(MediaSource(url: local) == .localFile(local), "local source validation")
        check(MediaSource(url: remote) == .remoteStream(remote), "HTTPS source validation")
        check(MediaSource(url: URL(string: "ftp://example.com/movie")!) == nil, "scheme rejection")
        check(
            MediaLoadRequest(source: .remoteStream(remote), origin: .restoredSession) == nil,
            "remote restore authorization rejection"
        )
        check(
            MediaLoadRequest(source: .remoteStream(remote), origin: .userSelected)?.source
                == .remoteStream(remote),
            "explicit remote authorization"
        )

        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }
        let store = AtomicPlaybackSessionStore(
            fileURL: tempDirectory.appendingPathComponent("session.json")
        )
        let record = PlaybackSessionRecord(
            source: .localFile(local),
            collectionFolder: local.deletingLastPathComponent(),
            playlistIndex: 2,
            position: 41.25,
            wasPaused: true,
            updatedAt: Date(timeIntervalSince1970: 123)
        )
        do {
            try store.save(record)
            let loadedRecord = try store.load()
            check(loadedRecord == record, "atomic session round trip")
            try store.clear()
            let clearedRecord = try store.load()
            check(clearedRecord == nil, "atomic session clear")
        } catch {
            failures.append("atomic session store: \(error.localizedDescription)")
        }

        for index in 0..<150 { state.recordDiagnostic("message-\(index)") }
        check(state.recentDiagnosticMessages.count == 100, "bounded diagnostics count")
        check(state.recentDiagnosticMessages.first == "message-50", "bounded diagnostics order")
        check(Chapter(id: 0, title: nil, startTime: -.infinity).startTime == 0, "chapter sanitization")
        check(BufferStatus(cacheDuration: 0, cachePercent: 900).cachePercent == 100, "cache sanitization")

        let firstIdentity = PlayerSessionIdentity(source: .localFile(local), generation: 1)
        let secondIdentity = PlayerSessionIdentity(source: .localFile(local), generation: 2)
        var eventGate = PlaybackRuntimeEventGate(activeIdentity: firstIdentity)
        check(
            eventGate.accepts(PlaybackRuntimeEvent(
                identity: firstIdentity,
                payload: .positionChanged(1)
            )),
            "active runtime event accepted"
        )
        eventGate.activate(secondIdentity)
        check(
            !eventGate.accepts(PlaybackRuntimeEvent(
                identity: firstIdentity,
                payload: .positionChanged(2)
            )),
            "stale backend generation rejected"
        )
        check(
            PlaybackCapabilities([.localFiles, .exactSeeking]).contains(.exactSeeking),
            "runtime capability gating"
        )

        state.setVideoFilter(.sharpen, enabled: true)
        state.setVideoFilter(.deband, enabled: true)
        state.setVideoFilter(.sharpen, enabled: true)
        check(state.activeVideoFilters == [.deband, .sharpen], "ordered unique video filters")
        state.setVideoFilter(.deband, enabled: false)
        check(state.activeVideoFilters == [.sharpen], "video filter removal")

        let folder = URL(fileURLWithPath: "/tmp/Shows", isDirectory: true)
        let episodeOne = folder.appendingPathComponent("Episode 1.mkv")
        let episodeTwo = folder.appendingPathComponent("Episode 2.mkv")
        let episodeTen = folder.appendingPathComponent("Episode 10.mkv")
        check(
            NaturalFilenameOrdering.sort([episodeTen, episodeTwo, episodeOne])
                .map(\.lastPathComponent)
                == ["Episode 1.mkv", "Episode 2.mkv", "Episode 10.mkv"],
            "natural filename ordering"
        )

        let playlist = FolderPlaylist(
            folderURL: folder,
            items: [FolderPlaylistItem(url: episodeTwo), FolderPlaylistItem(url: episodeOne)]
        )
        check(playlist.initialIndex(restoring: episodeTwo) == 1, "playlist restore index")
        check(playlist.nextIndex(after: 0) == 1, "playlist next boundary")
        check(playlist.nextIndex(after: 1) == nil, "playlist end boundary")
        check(playlist.previousIndex(before: 1) == 0, "playlist previous boundary")
        check(playlist.previousIndex(before: 0) == nil, "playlist start boundary")

        let exactSubtitle = folder.appendingPathComponent("Episode 1.en.srt")
        let wrongSubtitle = folder.appendingPathComponent("Episode 10.en.srt")
        check(
            ExternalSubtitleMatcher.matchingSubtitles(
                for: episodeOne,
                among: [wrongSubtitle, exactSubtitle]
            ) == [exactSubtitle],
            "external subtitle episode boundary"
        )
        let genericSubtitle = folder.appendingPathComponent("Show.srt")
        let showOne = folder.appendingPathComponent("Show Episode 1.mkv")
        let showTwo = folder.appendingPathComponent("Show Episode 2.mkv")
        let associations = ExternalSubtitleMatcher.associate(
            subtitleURLs: [genericSubtitle],
            with: [showOne, showTwo]
        )
        check(associations[showOne] == [] && associations[showTwo] == [], "ambiguous subtitle rejection")

        let tracks = MediaTrackParser.parse([
            MediaTrackDescriptor(
                id: 1,
                type: "audio",
                title: " Director Commentary ",
                language: "eng",
                codec: "aac",
                isDefault: true
            ),
            MediaTrackDescriptor(id: 2, type: "sub", title: "English Signs"),
            MediaTrackDescriptor(id: nil, type: "audio"),
        ])
        check(tracks.count == 2, "malformed track rejection")
        check(
            tracks.first?.kind == .audio
                && tracks.first?.title == "Director Commentary"
                && tracks.first?.isDefault == true,
            "media track parsing"
        )

        check(MediaFileSupport.isSupportedMediaFile(URL(fileURLWithPath: "/tmp/Movie.MKV")), "media extension case")
        check(MediaFileSupport.isSupportedSubtitleFile(URL(fileURLWithPath: "/tmp/Movie.Ass")), "subtitle extension case")
        check(MediaFileSupport.isSupportedSubtitleFile(URL(fileURLWithPath: "/tmp/Movie.ssa")), "SSA subtitle intake")
        check(MediaFileSupport.isSupportedSubtitleFile(URL(fileURLWithPath: "/tmp/Movie.vtt")), "WebVTT subtitle intake")
        check(!MediaFileSupport.isSupportedSubtitleFile(URL(fileURLWithPath: "/tmp/Movie.sup")), "bitmap subtitle extension rejection")
        check(!MediaFileSupport.isSupportedMediaFile(remote), "remote file extension rejection")
        check(
            NormalizedFileURL.representsSameFile(
                URL(fileURLWithPath: "/tmp/Shows/Season/../Episode.mkv"),
                URL(fileURLWithPath: "/tmp/Shows/Episode.mkv")
            ),
            "normalized file identity"
        )

        let fitted = AspectFitWindowSizing.fittedWindowSize(
            currentWindowSize: CGSize(width: 1_200, height: 760),
            currentVideoViewportSize: CGSize(width: 930, height: 760),
            minimumWindowSize: CGSize(width: 720, height: 440),
            videoAspectRatio: 16.0 / 9.0
        )
        check(abs((fitted?.width ?? 0) - 1_200) < 0.01, "aspect fit preserves overhead")
        check(abs((fitted?.height ?? 0) - 523.125) < 0.01, "aspect fit height")

        let suiteName = "SuperplayrValidation.\(UUID().uuidString)"
        if let defaults = UserDefaults(suiteName: suiteName) {
            defer { defaults.removePersistentDomain(forName: suiteName) }
            defaults.removePersistentDomain(forName: suiteName)
            let persistence = PlaybackPersistenceStore(userDefaults: defaults, namespace: "Check")
            persistence.setVolume(42)
            persistence.setMuted(true)
            persistence.setPlaybackSpeed(1.5)
            check(persistence.loadPreferences().volume == 42, "preference persistence")
            check(persistence.setPlaybackPosition(125.25, for: episodeOne), "position accepted")
            check(
                persistence.playbackPosition(
                    for: folder.appendingPathComponent("Season/../Episode 1.mkv")
                ) == 125.25,
                "normalized position persistence"
            )
            check(!persistence.setPlaybackPosition(-1, for: episodeOne), "invalid position rejection")
            check(!persistence.setPlaybackPosition(10, for: remote), "remote position rejection")
            check(
                persistence.setPlaybackProgress(position: 90, duration: 100, for: episodeOne),
                "playback progress accepted"
            )
            check(
                persistence.playbackProgress(for: episodeOne)?.isCompleted == false,
                "ninety percent remains in progress"
            )
            check(
                persistence.setPlaybackProgress(position: 90.1, duration: 100, for: episodeOne),
                "completed progress accepted"
            )
            check(
                persistence.playbackProgress(for: episodeOne)?.isCompleted == true,
                "greater than ninety percent completes"
            )
            check(
                persistence.playbackPosition(for: episodeOne) == nil,
                "completed playback does not resume near the end"
            )
            persistence.setLastWatchedFile(episodeTwo, for: folder)
            persistence.setLastOpenedMedia(.folder(folder))
            persistence.clearPlaybackHistory()
            check(persistence.lastWatchedFile(for: folder) == nil, "history clear watched file")
            check(persistence.lastOpenedMedia() == nil, "history clear restore target")
            check(persistence.playbackProgress(for: episodeOne) == nil, "history clear progress")
            check(persistence.loadPreferences().volume == 42, "history clear preserves preferences")
        } else {
            failures.append("isolated user defaults")
        }

        do {
            try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
            let nestedDirectory = tempDirectory.appendingPathComponent("nested", isDirectory: true)
            try FileManager.default.createDirectory(at: nestedDirectory, withIntermediateDirectories: true)
            for name in ["Episode 10.mkv", "Episode 2.MP4", "Episode 1.avi", "notes.txt", ".hidden.mp4"] {
                FileManager.default.createFile(
                    atPath: tempDirectory.appendingPathComponent(name).path,
                    contents: Data()
                )
            }
            FileManager.default.createFile(
                atPath: nestedDirectory.appendingPathComponent("Episode 3.mkv").path,
                contents: Data()
            )
            let discovered = try FolderPlaylistDiscovery.discover(in: tempDirectory)
            check(
                discovered.items.map { $0.url.lastPathComponent }
                    == ["Episode 1.avi", "Episode 2.MP4", "Episode 10.mkv"],
                "shallow folder discovery"
            )
        } catch {
            failures.append("folder discovery: \(error.localizedDescription)")
        }

        runStaticAuthorityChecks(&failures)

        return failures
    }

    private static func runStaticAuthorityChecks(_ failures: inout [String]) {
        let repository = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        )
        func contents(_ relativePath: String) -> String {
            do {
                return try String(
                    contentsOf: repository.appendingPathComponent(relativePath),
                    encoding: .utf8
                )
            } catch {
                failures.append("architecture source unavailable: \(relativePath)")
                return ""
            }
        }

        let controller = contents("Sources/SuperplayrPlayer/Player/PlaybackController.swift")
        let forbiddenControllerBypasses = [
            "backend?.play(", "backend?.pause(", "backend?.stop(", "backend?.seek(",
            "backend?.selectAudioTrack(", "backend?.selectSubtitleTrack(",
            "backend?.loadExternalSubtitle(", "backend?.setSubtitleDelay(",
            "state.markLoaded(", "state.markBuffering(", "state.setPaused(",
            "state.updatePosition(", "state.updateDuration(",
        ]
        for bypass in forbiddenControllerBypasses where controller.contains(bypass) {
            failures.append("core authority bypass: \(bypass)")
        }

        let runtimeContract = contents("Sources/SuperplayrPlayback/PlaybackRuntime.swift")
        for forbidden in [
            "func play()", "func pause()", "func stop()", "func seek(to",
            "func selectAudioTrack", "func selectSubtitleTrack", "func setSubtitleDelay",
        ] where runtimeContract.contains(forbidden) {
            failures.append("runtime exposes core-owned direct command: \(forbidden)")
        }

        let nativeSynchronization = contents(
            "Sources/SuperplayrNativePlayback/Runtime/NativeSynchronizationController.swift"
        )
        if nativeSynchronization.contains("SynchronizationMachineState()") {
            failures.append("native synchronization duplicates core policy")
        }
        let nativeRecovery = contents(
            "Sources/SuperplayrNativePlayback/Runtime/NativeRecoveryController.swift"
        )
        if nativeRecovery.contains("RecoveryMachineState()") {
            failures.append("native recovery duplicates core policy")
        }
    }
}
