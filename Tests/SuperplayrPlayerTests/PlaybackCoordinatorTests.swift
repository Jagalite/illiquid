import AppKit
import Foundation
import SuperplayrCore
import SuperplayrPlayback
import SuperplayrPlaybackCore
import Testing
@testable import SuperplayrPlayer

@MainActor
@Suite("Playback coordinator", .serialized)
struct PlaybackCoordinatorTests {
    @Test(arguments: [false, true])
    func chapterSelectionUsesIdentifiedSeekAndRestoresTransport(paused: Bool) async throws {
        let fixture = try CoordinatorFixture()
        let file = try fixture.createFile("chapter-transport.mkv")
        fixture.coordinator.open(url: file)
        try await waitForPreparation(fixture.coordinator)
        let load = try #require(fixture.runtime.loads.last)
        fixture.runtime.emit(.loaded, identity: load.identity)
        fixture.runtime.emit(.pauseChanged(false), identity: load.identity)
        if paused {
            fixture.coordinator.pause()
            fixture.runtime.emit(.pauseChanged(true), identity: load.identity)
        }

        let previousCount = fixture.runtime.executedEffects.count
        fixture.coordinator.selectChapter(Chapter(id: 1, title: "Next", startTime: 42))
        #expect(fixture.runtime.seeks.last == SeekRecord(value: 42, mode: .absoluteExact))
        let effect = try #require(fixture.runtime.executedEffects.dropFirst(previousCount).first {
            if case .seekPipeline = $0.kind { return true }
            return false
        })
        guard case .playback = effect.context.authority else {
            Issue.record("Chapter seek must carry playback authority")
            return
        }
        #expect(fixture.coordinator.viewStore.isPauseDesired == paused)
        fixture.runtime.emit(.seekCompleted, identity: load.identity)
        #expect(fixture.runtime.executedEffects.last?.kind == .applyRate(milliRate: paused ? 0 : 1_000))
        fixture.runtime.emit(.pauseChanged(paused), identity: load.identity)
        #expect(fixture.coordinator.viewStore.phase == (paused ? .paused : .playing))
        #expect(fixture.coordinator.viewStore.position == 42)
        await fixture.coordinator.shutdown()
    }

    @Test func chapterSelectionSupersedesPendingSkipsAndRejectsOldCompletion() async throws {
        let fixture = try CoordinatorFixture()
        let file = try fixture.createFile("chapter-supersession.mkv")
        fixture.coordinator.open(url: file)
        try await waitForPreparation(fixture.coordinator)
        let load = try #require(fixture.runtime.loads.last)
        fixture.runtime.emit(.loaded, identity: load.identity)
        fixture.runtime.emit(.pauseChanged(false), identity: load.identity)
        fixture.runtime.emit(.positionChanged(0), identity: load.identity)
        fixture.coordinator.seek(relative: 10)
        let oldSeek = try #require(fixture.runtime.executedEffects.last {
            if case .seekPipeline = $0.kind { return true }
            return false
        })
        fixture.coordinator.seek(relative: 10)
        fixture.coordinator.selectChapter(Chapter(id: 2, title: "Later", startTime: 120))
        #expect(fixture.runtime.seeks.last == SeekRecord(value: 120, mode: .absoluteExact))
        let seekCount = fixture.runtime.seeks.count
        let effectCount = fixture.runtime.executedEffects.count
        fixture.runtime.emitResult(context: oldSeek.context, kind: .succeeded)
        #expect(fixture.runtime.executedEffects.count == effectCount)
        #expect(fixture.coordinator.viewStore.position == 120)
        try await Task.sleep(for: .milliseconds(80))
        #expect(fixture.runtime.seeks.count == seekCount)
        fixture.runtime.emit(.seekCompleted, identity: load.identity)
        fixture.runtime.emit(.pauseChanged(false), identity: load.identity)
        #expect(fixture.coordinator.viewStore.phase == .playing)
        await fixture.coordinator.shutdown()
    }

    @Test func oversizedSeekAndSubtitleTimestampsAreRejectedWithoutIntegerTraps() throws {
        let fixture = try CoordinatorFixture()
        let driver = PlaybackRuntimeDriver(runtime: fixture.runtime)
        for seconds in [Double(Int64.max) / 1_000_000, Double.greatestFiniteMagnitude, .infinity, .nan] {
            #expect(!driver.seek(to: seconds, mode: .exact))
            #expect(!driver.setSubtitleDelay(seconds))
        }
        #expect(fixture.runtime.seeks.isEmpty)
    }

    @Test func rapidSkipReversalClampsAtBothBoundariesAndPreservesPause() async throws {
        let fixture = try CoordinatorFixture()
        let file = try fixture.createFile("skip-boundaries.mkv")
        fixture.coordinator.open(url: file)
        try await waitForPreparation(fixture.coordinator)
        let load = try #require(fixture.runtime.loads.last)
        fixture.runtime.emit(.loaded, identity: load.identity)
        fixture.runtime.emit(.durationChanged(300), identity: load.identity)
        fixture.runtime.emit(.positionChanged(295), identity: load.identity)
        for delta in [10.0, 10.0, -5.0] { fixture.coordinator.seek(relative: delta) }
        fixture.coordinator.pause()
        #expect(fixture.coordinator.state.position == 295)
        try await Task.sleep(for: .milliseconds(80))
        #expect(fixture.runtime.seeks.last?.value == 295)
        #expect(fixture.coordinator.state.isPauseDesired)
        fixture.coordinator.seek(to: 5)
        for delta in [-10.0, -10.0, 5.0] { fixture.coordinator.seek(relative: delta) }
        #expect(fixture.coordinator.state.position == 5)
        try await Task.sleep(for: .milliseconds(80))
        #expect(fixture.runtime.seeks.last?.value == 5)
        await fixture.coordinator.shutdown()
    }

    @Test func pendingSkipsDoNotStartAfterSleepOrShutdown() async throws {
        let fixture = try CoordinatorFixture()
        let file = try fixture.createFile("skip-lifecycle.mkv")
        fixture.coordinator.open(url: file)
        try await waitForPreparation(fixture.coordinator)
        let load = try #require(fixture.runtime.loads.last)
        fixture.runtime.emit(.loaded, identity: load.identity)
        fixture.runtime.emit(.positionChanged(0), identity: load.identity)
        fixture.coordinator.seek(relative: 10)
        fixture.coordinator.seek(relative: 10)
        #expect(fixture.runtime.seeks.count == 1)
        fixture.coordinator.systemWillSleep()
        #expect(fixture.runtime.seeks.last?.value == 20)
        let sleepingCount = fixture.runtime.seeks.count
        try await Task.sleep(for: .milliseconds(80))
        #expect(fixture.runtime.seeks.count == sleepingCount)
        fixture.coordinator.seek(relative: 10)
        fixture.coordinator.seek(relative: 10)
        let beforeShutdown = fixture.runtime.seeks.count
        await fixture.coordinator.shutdown()
        try await Task.sleep(for: .milliseconds(80))
        #expect(fixture.runtime.seeks.count == beforeShutdown)
        #expect(fixture.runtime.shutdownCount == 1)
    }

    @Test func rapidRelativeSkipsCoalesceNativeWorkAndExposeTheFinalExactTarget() async throws {
        let fixture = try CoordinatorFixture()
        let file = try fixture.createFile("rapid-skips.mkv")
        fixture.coordinator.open(url: file)
        try await waitForPreparation(fixture.coordinator)
        let load = try #require(fixture.runtime.loads.last)
        fixture.runtime.emit(.loaded, identity: load.identity)
        fixture.runtime.emit(.durationChanged(300), identity: load.identity)
        fixture.runtime.emit(.positionChanged(20), identity: load.identity)
        let before = fixture.runtime.seeks.count
        for _ in 0..<5 { fixture.coordinator.seek(relative: 10) }
        #expect(fixture.coordinator.state.position == 70)
        #expect(fixture.runtime.seeks.count == before + 1)
        let deadline = ContinuousClock.now + .seconds(1)
        while fixture.runtime.seeks.count < before + 2, ContinuousClock.now < deadline {
            await Task.yield()
        }
        #expect(fixture.runtime.seeks.count == before + 2)
        #expect(fixture.runtime.seeks.last == SeekRecord(value: 70, mode: .absoluteExact))
        await fixture.coordinator.shutdown()
    }

    @Test func absoluteSeekAndStopRetirePendingRelativeSkips() async throws {
        let fixture = try CoordinatorFixture()
        let file = try fixture.createFile("superseded-skips.mkv")
        fixture.coordinator.open(url: file)
        try await waitForPreparation(fixture.coordinator)
        let load = try #require(fixture.runtime.loads.last)
        fixture.runtime.emit(.loaded, identity: load.identity)
        fixture.runtime.emit(.positionChanged(0), identity: load.identity)
        fixture.coordinator.seek(relative: 10)
        fixture.coordinator.seek(relative: 10)
        #expect(fixture.runtime.seeks.count == 1)
        fixture.coordinator.seek(to: 100)
        #expect(fixture.runtime.seeks.last?.value == 100)
        let count = fixture.runtime.seeks.count
        try await Task.sleep(for: .milliseconds(80))
        #expect(fixture.runtime.seeks.count == count)
        fixture.coordinator.seek(relative: 10)
        fixture.coordinator.seek(relative: 10)
        fixture.coordinator.stop()
        let stoppedCount = fixture.runtime.seeks.count
        try await Task.sleep(for: .milliseconds(80))
        #expect(fixture.runtime.seeks.count == stoppedCount)
        await fixture.coordinator.shutdown()
    }

    @Test func uxVerificationClearThenQuitDoesNotRecreateClearedProgress() async throws {
        let fixture = try CoordinatorFixture()
        let file = try fixture.createFile("ux-clear-then-quit.mkv")
        fixture.coordinator.open(url: file)
        try await waitForPreparation(fixture.coordinator)
        let load = try #require(fixture.runtime.loads.last)
        fixture.runtime.emit(.loaded, identity: load.identity)
        fixture.runtime.emit(.durationChanged(300), identity: load.identity)
        fixture.runtime.emit(.positionChanged(42), identity: load.identity)
        fixture.coordinator.clearPlaybackProgress()
        #expect(fixture.persistence.playbackPosition(for: file) == nil)
        await fixture.coordinator.shutdown()
        let savedSession = try fixture.sessionStore.load()
        #expect(fixture.persistence.playbackPosition(for: file) == nil)
        #expect(savedSession == nil)
    }

    @Test func uxVerificationShutdownReportsFailedSaveWithoutSkippingNativeCleanup() async throws {
        let fixture = try CoordinatorFixture(sessionStore: FailedSessionStore())
        let file = try fixture.createFile("ux-shutdown-write-failure.mkv")
        fixture.coordinator.open(url: file)
        try await waitForPreparation(fixture.coordinator)
        let load = try #require(fixture.runtime.loads.last)
        fixture.runtime.emit(.loaded, identity: load.identity)
        await fixture.coordinator.shutdown()
        #expect(fixture.runtime.shutdownCount == 1)
        #expect(fixture.coordinator.state.shellError?.contains("Could not save") == true)
        #expect(fixture.coordinator.shutdownPersistenceError?.contains("Could not save") == true)
        await fixture.coordinator.shutdown()
        #expect(fixture.runtime.shutdownCount == 1)
        #expect(fixture.coordinator.shutdownPersistenceError != nil)
    }

    @Test func clearedProgressSurvivesPauseAndRepeatedPositionButRecordsFurtherPlayback() async throws {
        let fixture = try CoordinatorFixture()
        let file = try fixture.createFile("ux-clear-then-continue.mkv")
        fixture.coordinator.open(url: file)
        try await waitForPreparation(fixture.coordinator)
        let load = try #require(fixture.runtime.loads.last)
        fixture.runtime.emit(.loaded, identity: load.identity)
        fixture.runtime.emit(.durationChanged(300), identity: load.identity)
        fixture.runtime.emit(.positionChanged(42), identity: load.identity)
        fixture.coordinator.clearPlaybackProgress()
        fixture.runtime.emit(.positionChanged(42), identity: load.identity)
        fixture.runtime.emit(.pauseChanged(true), identity: load.identity)
        fixture.coordinator.systemWillSleep()
        #expect(fixture.persistence.playbackPosition(for: file) == nil)
        fixture.runtime.emit(.positionChanged(43), identity: load.identity)
        await fixture.coordinator.shutdown()
        #expect(fixture.persistence.playbackPosition(for: file) == 43)
        #expect(try fixture.sessionStore.load()?.position == 43)
        #expect(fixture.coordinator.shutdownPersistenceError == nil)
    }

    @Test func unverifiedContentCanAdvanceWithoutOverwritingEarlierHistory() async throws {
        let fixture = try CoordinatorFixture()
        let first = try fixture.createFile("unverified-01.mkv")
        let next = try fixture.createFile("unverified-02.mkv")
        fixture.persistence.setPlaybackProgress(position: 100, duration: 1_000, for: first)
        fixture.coordinator.open(urls: [first, next])
        try await waitForPreparation(fixture.coordinator)
        let initial = try #require(fixture.runtime.loads.last)
        fixture.runtime.emit(.loaded, identity: initial.identity)
        fixture.coordinator.stop()
        fixture.coordinator.sortPlaylist(by: .name, ascending: true)
        fixture.persistence.setPlaybackProgress(position: 100, duration: 1_000, for: first)
        fixture.coordinator.playItem(at: 0)
        let load = try #require(fixture.runtime.loads.last)
        fixture.runtime.observeVersionAtNextLoad(nil)
        fixture.runtime.emit(.loaded, identity: load.identity)
        fixture.runtime.emit(.prerollReady, identity: load.identity)
        fixture.runtime.emit(.pauseChanged(false), identity: load.identity)
        fixture.runtime.emit(.endOfFile, identity: load.identity)
        await waitForAdvance(fixture.runtime, after: load.identity.generation)
        #expect(fixture.runtime.loads.last?.identity.source == .localFile(next))
        #expect(fixture.persistence.playbackPosition(for: first) == 100)
        #expect(fixture.persistence.playbackProgress(for: first)?.isCompleted == false)
    }

    @Test func unchangedVersionKeepsResumeAndLocatedVersionKeepsSettings() async throws {
        let fixture = try CoordinatorFixture()
        let original = try fixture.createFile("original-location.mkv")
        let relocated = fixture.root.appendingPathComponent("new-location.mkv")
        let version = MediaContentVersion(fileIdentifier: 1, byteCount: 100,
                                          modificationSeconds: 1, modificationNanoseconds: 0,
                                          creationSeconds: 1, creationNanoseconds: 0)
        fixture.persistence.acceptMediaVersion(version, for: original)
        fixture.persistence.setPlaybackPosition(42, for: original)
        fixture.persistence.setMediaSettings(.init(subtitleDelay: 0.5), for: original)
        try fixture.sessionStore.save(.init(source: .localFile(original), position: 42, wasPaused: true))
        try FileManager.default.moveItem(at: original, to: relocated)
        #expect(fixture.coordinator.restoreLastSession())
        try await waitForPreparation(fixture.coordinator)
        fixture.coordinator.locateUnavailableSession(at: relocated)
        try await waitForPreparation(fixture.coordinator)
        fixture.runtime.observeVersionAtNextLoad(version)
        let load = try #require(fixture.runtime.loads.last)
        fixture.runtime.emit(.loaded, identity: load.identity)
        fixture.runtime.emit(.tracksChanged(.init(hasVideo: true, tracks: [], selectedAudioID: nil, selectedSubtitleID: nil)), identity: load.identity)
        #expect(fixture.runtime.seeks.last == SeekRecord(value: 42, mode: .absoluteExact))
        #expect(fixture.coordinator.state.isPauseDesired)
        #expect(fixture.persistence.mediaSettings(for: relocated)?.subtitleDelay == 0.5)
        #expect(fixture.persistence.playbackPosition(for: original) == 42)
        #expect(fixture.persistence.replacedMediaHistory(for: relocated).isEmpty)
    }

    @Test(arguments: [false, true])
    func changedOrUnverifiedContentDoesNotInheritResumeAndPerFileChoices(unverified: Bool) async throws {
        let fixture = try CoordinatorFixture()
        let file = try fixture.createFile("replaced.mkv")
        let old = MediaContentVersion(fileIdentifier: 1, byteCount: 100,
                                      modificationSeconds: 1, modificationNanoseconds: 0,
                                      creationSeconds: 1, creationNanoseconds: 0)
        let new = MediaContentVersion(fileIdentifier: 2, byteCount: 100,
                                      modificationSeconds: 2, modificationNanoseconds: 0,
                                      creationSeconds: 2, creationNanoseconds: 0)
        fixture.persistence.acceptMediaVersion(old, for: file)
        fixture.persistence.setPlaybackProgress(position: 100, duration: 1_000, for: file)
        fixture.persistence.setMediaSettings(.init(
            audioTrack: MediaTrackPreference(track: .init(id: 2, kind: .audio, title: "Old commentary")),
            areSubtitlesVisible: false, subtitleDelay: 2
        ), for: file)
        fixture.runtime.observeVersionAtNextLoad(unverified ? nil : new)
        fixture.coordinator.open(url: file)
        try await waitForPreparation(fixture.coordinator)
        let load = try #require(fixture.runtime.loads.last)
        fixture.runtime.emit(.mediaVersionObserved(new), identity: load.identity)
        #expect(fixture.persistence.playbackPosition(for: file) == 100)
        fixture.runtime.emit(.loaded, identity: load.identity)
        fixture.runtime.emit(.tracksChanged(.init(hasVideo: true, tracks: [
            .init(id: 1, kind: .audio, title: "Main"),
            .init(id: 2, kind: .audio, title: "Old commentary"),
            .init(id: 3, kind: .subtitle, languageCode: "en")
        ], selectedAudioID: 1, selectedSubtitleID: 3)), identity: load.identity)
        #expect(fixture.runtime.seeks.isEmpty)
        #expect(fixture.coordinator.state.subtitleDelay == 0)
        #expect(fixture.coordinator.state.selectedAudioTrack?.id != 2)
        #expect(fixture.coordinator.viewStore.recoveryIssue != nil)
        if unverified {
            fixture.coordinator.stop()
            #expect(fixture.persistence.playbackPosition(for: file) == 100)
            #expect(fixture.persistence.replacedMediaHistory(for: file).isEmpty)
        } else {
            #expect(fixture.persistence.playbackPosition(for: file) == nil)
            #expect(fixture.persistence.replacedMediaHistory(for: file).first?.position == 100)
        }
    }

    @Test func changedRestoreStartsAtZeroButKeepsPausedIntent() async throws {
        let fixture = try CoordinatorFixture()
        let file = try fixture.createFile("restored-replacement.mkv")
        let old = MediaContentVersion(fileIdentifier: 1, byteCount: 100,
                                      modificationSeconds: 1, modificationNanoseconds: 0,
                                      creationSeconds: 1, creationNanoseconds: 0)
        let new = MediaContentVersion(fileIdentifier: 2, byteCount: 100,
                                      modificationSeconds: 2, modificationNanoseconds: 0,
                                      creationSeconds: 2, creationNanoseconds: 0)
        fixture.persistence.acceptMediaVersion(old, for: file)
        fixture.persistence.setPlaybackPosition(100, for: file)
        try fixture.sessionStore.save(.init(source: .localFile(file), position: 100, wasPaused: true))
        fixture.runtime.observeVersionAtNextLoad(new)
        #expect(fixture.coordinator.restoreLastSession())
        try await waitForPreparation(fixture.coordinator)
        let load = try #require(fixture.runtime.loads.last)
        fixture.runtime.emit(.loaded, identity: load.identity)
        #expect(fixture.runtime.seeks.isEmpty)
        #expect(fixture.coordinator.state.isPauseDesired)
        #expect(fixture.persistence.replacedMediaHistory(for: file).first?.position == 100)
    }

    private final class BlockedRestoreStore: PlaybackSessionStoring, @unchecked Sendable {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var exited = false
        var didExit: Bool { lock.withLock { exited } }
        func load() throws -> PlaybackSessionRecord? {
            #expect(!Thread.isMainThread)
            entered.signal()
            _ = release.wait(timeout: .now() + 5)
            lock.withLock { exited = true }
            return nil
        }
        func save(_ session: PlaybackSessionRecord) throws {}
        func clear() throws {}
    }

    @Test func blockedRestoreDoesNotBlockFinderOpenOrShutdown() async throws {
        let store = BlockedRestoreStore()
        defer { store.release.signal() }
        let fixture = try CoordinatorFixture(sessionStore: store)
        #expect(fixture.coordinator.restoreLastSession())
        let entered = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: store.entered.wait(timeout: .now() + 3))
            }
        }
        #expect(entered == .success)
        let file = try fixture.createFile("finder-while-restore-blocked.mkv")
        fixture.coordinator.open(url: file)
        try await waitForPreparation(fixture.coordinator)
        #expect(fixture.runtime.loads.last?.identity.source == .localFile(file))
        await fixture.coordinator.shutdown()
        #expect(!store.didExit)
        #expect(fixture.runtime.loads.count == 1)
    }

    private struct FailedSessionStore: PlaybackSessionStoring {
        func load() throws -> PlaybackSessionRecord? { nil }
        func save(_ session: PlaybackSessionRecord) throws { throw CocoaError(.fileWriteNoPermission) }
        func clear() throws {}
    }

    private final class BlockedSaveStore: PlaybackSessionStoring, @unchecked Sendable {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var hasBlocked = false
        private var records: [PlaybackSessionRecord] = []
        var positions: [TimeInterval] { lock.withLock { records.map(\.position) } }
        func waitUntilEntered() -> Bool { entered.wait(timeout: .now() + 3) == .success }
        func load() throws -> PlaybackSessionRecord? { nil }
        func save(_ session: PlaybackSessionRecord) throws {
            #expect(!Thread.isMainThread)
            let mustBlock = lock.withLock {
                let first = !hasBlocked
                hasBlocked = true
                return first
            }
            if mustBlock {
                entered.signal()
                guard release.wait(timeout: .now() + 5) == .success else {
                    throw CocoaError(.fileWriteUnknown)
                }
            }
            lock.withLock { records.append(session) }
        }
        func clear() throws {}
    }

    @Test func shutdownJoinsBlockedSaveWithoutBlockingMainActorOrLosingLatestProgress() async throws {
        let store = BlockedSaveStore()
        defer { store.release.signal() }
        let fixture = try CoordinatorFixture(sessionStore: store)
        let file = try fixture.createFile("slow-final-save.mkv")
        fixture.coordinator.open(url: file)
        try await waitForPreparation(fixture.coordinator)
        let load = try #require(fixture.runtime.loads.last)
        fixture.runtime.emit(.loaded, identity: load.identity)
        fixture.runtime.emit(.durationChanged(300), identity: load.identity)
        fixture.runtime.emit(.positionChanged(42), identity: load.identity)
        let entered = await Task.detached {
            store.waitUntilEntered()
        }.value
        try #require(entered)
        fixture.runtime.emit(.positionChanged(43), identity: load.identity)
        var finished = false
        let shutdown = Task { await fixture.coordinator.shutdown(); finished = true }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while fixture.runtime.shutdownCount == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(fixture.runtime.shutdownCount == 1)
        #expect(!finished)
        #expect(store.positions.isEmpty)
        store.release.signal()
        await shutdown.value
        #expect(finished)
        #expect(store.positions.last == 43)
        #expect(fixture.coordinator.shutdownPersistenceError == nil)
    }

    @Test func failedCheckpointDoesNotAdvanceThePlaylist() async throws {
        let fixture = try CoordinatorFixture(sessionStore: FailedSessionStore())
        let first = try fixture.createFile("failure-01.mkv")
        let second = try fixture.createFile("failure-02.mkv")
        fixture.coordinator.open(urls: [first, second])
        try await waitForPreparation(fixture.coordinator)
        let load = try #require(fixture.runtime.loads.last)
        fixture.runtime.emit(.loaded, identity: load.identity)
        fixture.runtime.emit(.endOfFile, identity: load.identity)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while fixture.coordinator.state.shellError == nil, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(fixture.coordinator.state.shellError != nil)
        #expect(fixture.runtime.loads.count == 1)
        await fixture.coordinator.shutdown()
    }


    @Test func directOpenResolvesAliasesAndStopRejectsPendingPreparation() async throws {
        let fixture = try CoordinatorFixture()
        let first = try fixture.createFile("first.mkv")
        let second = try fixture.createFile("second.mkv")
        let alias = fixture.root.appendingPathComponent("alias.mkv")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: first)
        fixture.coordinator.open(url: alias)
        try await waitForPreparation(fixture.coordinator)
        #expect(fixture.runtime.loads.last?.identity.source == .localFile(first))
        let initialLoad = try #require(fixture.runtime.loads.last)
        fixture.runtime.emit(.loaded, identity: initialLoad.identity)
        #expect(fixture.coordinator.state.playlist.count == 1)
        try FileManager.default.removeItem(at: alias)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: second)
        fixture.coordinator.open(url: alias)
        try await waitForPreparation(fixture.coordinator)
        #expect(fixture.runtime.loads.last?.identity.source == .localFile(second))
        let loadCount = fixture.runtime.loads.count
        fixture.coordinator.open(url: first)
        fixture.coordinator.stop()
        try await waitForPreparation(fixture.coordinator)
        #expect(fixture.runtime.loads.count == loadCount)
        await fixture.coordinator.shutdown()
    }

    @Test func finderFolderClassificationSharesCancellationAndCanonicalPreparation() async throws {
        let fixture = try CoordinatorFixture()
        let folder = try fixture.createDirectory("folder")
        let video = try fixture.createFile("video.mkv", in: folder)
        var folders: [URL] = []
        fixture.coordinator.open(urls: [folder, video]) { folders = $0 }
        try await waitForPreparation(fixture.coordinator)
        #expect(folders == [folder])
        #expect(fixture.runtime.loads.last?.identity.source == .localFile(video))
        let load = try #require(fixture.runtime.loads.last)
        fixture.runtime.emit(.loaded, identity: load.identity)
        #expect(fixture.coordinator.state.playlist.count == 1)
        var calledAfterStop = false
        fixture.coordinator.open(urls: [folder]) { _ in calledAfterStop = true }
        fixture.coordinator.stop()
        try await waitForPreparation(fixture.coordinator)
        #expect(!calledAfterStop)
        await fixture.coordinator.shutdown()
    }


    @Test func finderRequestsRetainFolderOrderAndAppendDuringPreroll() async throws {
        let fixture = try CoordinatorFixture()
        let firstFolder = try fixture.createDirectory("first-folder")
        let secondFolder = try fixture.createDirectory("second-folder")
        let first = try fixture.createFile("first.mkv")
        let second = try fixture.createFile("second.mkv")
        var folders: [URL] = []
        fixture.coordinator.open(urls: [firstFolder, first]) { folders += $0 }
        fixture.coordinator.open(urls: [secondFolder, second], mode: .append) { folders += $0 }
        try await waitForPreparation(fixture.coordinator)
        #expect(folders == [firstFolder, secondFolder])
        let load = try #require(fixture.runtime.loads.last)
        fixture.runtime.emit(.loaded, identity: load.identity)
        #expect(Set(fixture.coordinator.state.playlist.map(\.url)) == [first, second])
        #expect(fixture.coordinator.state.currentURL == first)
        var lateCallbacks = 0
        fixture.coordinator.open(urls: [firstFolder]) { _ in lateCallbacks += 1 }
        fixture.coordinator.open(urls: [secondFolder]) { _ in lateCallbacks += 1 }
        fixture.coordinator.stop()
        try await waitForPreparation(fixture.coordinator)
        #expect(lateCallbacks == 0)
        await fixture.coordinator.shutdown()
    }

    private func waitForPreparation(_ coordinator: PlaybackCoordinator) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while coordinator.isPreparingSource, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(!coordinator.isPreparingSource)
    }

    private func waitForAdvance(_ runtime: CoordinatorFakeBackend, after generation: UInt64) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while (runtime.loads.last?.identity.generation ?? 0) <= generation, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect((runtime.loads.last?.identity.generation ?? 0) > generation)
    }

    @Test func preferredAudioOutputPersistsAndReappliesWhenAvailable() throws {
        let fixture = try CoordinatorFixture()
        let device = AudioOutputDevice(
            id: "usb-dac",
            name: "USB DAC",
            isDefault: false,
            isSelected: false
        )

        fixture.coordinator.selectAudioOutputDevice(device)

        #expect(fixture.coordinator.preferredAudioOutputDeviceID == "usb-dac")
        #expect(fixture.persistence.loadPreferences().preferredAudioOutputDeviceID == "usb-dac")
        #expect(fixture.runtime.audioOutputRequests == ["usb-dac"])

        fixture.runtime.emit(.audioDevicesChanged([device]), identity: nil)
        #expect(fixture.runtime.audioOutputRequests == ["usb-dac", "usb-dac"])

        fixture.runtime.emit(.audioDevicesChanged([
            AudioOutputDevice(
                id: "usb-dac",
                name: "USB DAC",
                isDefault: false,
                isSelected: true
            )
        ]), identity: nil)
        #expect(fixture.runtime.audioOutputRequests == ["usb-dac", "usb-dac"])

        fixture.coordinator.selectAudioOutputDevice(nil)
        #expect(fixture.coordinator.preferredAudioOutputDeviceID == nil)
        #expect(fixture.persistence.loadPreferences().preferredAudioOutputDeviceID == nil)
        #expect(fixture.runtime.audioOutputRequests.count == 3)
        #expect(fixture.runtime.audioOutputRequests[2] == nil)
    }

    @Test func audioOutputSelectionFailureIsPersistentWithoutFailingPlayback() async throws {
        let fixture = try CoordinatorFixture()
        let file = try fixture.createFile("audio-route.mkv")
        fixture.coordinator.open(url: file)
        try await waitForPreparation(fixture.coordinator)
        fixture.runtime.emit(.loaded, identity: fixture.runtime.loads.last!.identity)
        fixture.runtime.emit(.pauseChanged(false), identity: fixture.runtime.loads.last!.identity)
        let phase = fixture.coordinator.state.phase
        fixture.runtime.emit(.audioOutputSelectionFailed("Output unavailable"), identity: nil)
        #expect(fixture.coordinator.viewStore.recoveryIssue?.message == "Output unavailable")
        #expect(fixture.coordinator.state.phase == phase)
        #expect(fixture.coordinator.state.currentURL == file)
    }

    @Test func disablingVideoColorSamplingResetsPublishedColor() throws {
        let fixture = try CoordinatorFixture()
        let sample = VideoColorSample(
            columns: 1,
            rows: 1,
            colors: [SampledVideoColor(red: 0.2, green: 0.4, blue: 0.6)]
        )

        fixture.coordinator.setVideoColorSamplingEnabled(true)
        fixture.runtime.emit(.videoColorSampleChanged(sample), identity: nil)
        #expect(fixture.coordinator.videoColorStore.sample == sample)

        fixture.coordinator.setVideoColorSamplingEnabled(false)
        fixture.coordinator.setVideoColorSamplingEnabled(false)

        #expect(fixture.runtime.videoColorSamplingRequests == [true, false])
        #expect(fixture.coordinator.videoColorStore.sample == nil)
    }

    @Test func productionUsesPlanarWithIsolatedBenchmarkOverrides() {
        let planar = [
            "SUPERPLAYR_ENABLE_BENCHMARK_OVERRIDES": "1",
            "SUPERPLAYR_BENCHMARK_SOFTWARE_OUTPUT": "planar",
        ]
        #expect(PlaybackCoordinator.softwareVideoOutputPolicy(
            environment: planar,
            bundleIdentifier: "com.example.SuperplayrBenchmark"
        ) == .planarExperimental)
        #expect(PlaybackCoordinator.softwareVideoOutputPolicy(
            environment: planar,
            bundleIdentifier: "com.example.Superplayr"
        ) == .planarPreferred)
        #expect(PlaybackCoordinator.softwareVideoOutputPolicy(
            environment: ["SUPERPLAYR_BENCHMARK_SOFTWARE_OUTPUT": "planar"],
            bundleIdentifier: "com.example.SuperplayrBenchmark"
        ) == .planarPreferred)
        #expect(PlaybackCoordinator.softwareVideoOutputPolicy(
            environment: ["SUPERPLAYR_ENABLE_BENCHMARK_OVERRIDES": "1",
                          "SUPERPLAYR_BENCHMARK_SOFTWARE_OUTPUT": "bgra"],
            bundleIdentifier: "com.example.SuperplayrBenchmark"
        ) == .bgra)
        #expect(PlaybackCoordinator.benchmarkVideoFrameQueueCapacity(
            environment: planar.merging([
                "SUPERPLAYR_BENCHMARK_VIDEO_FRAME_QUEUE_CAPACITY": "8"
            ]) { _, new in new },
            bundleIdentifier: "com.example.SuperplayrBenchmark"
        ) == 8)
        #expect(PlaybackCoordinator.benchmarkVideoFrameQueueCapacity(
            environment: planar.merging([
                "SUPERPLAYR_BENCHMARK_VIDEO_FRAME_QUEUE_CAPACITY": "10"
            ]) { _, new in new },
            bundleIdentifier: "com.example.SuperplayrBenchmark"
        ) == 12)
        #expect(PlaybackCoordinator.benchmarkReservesVideoPipelineCapacity(
            environment: planar.merging([
                "SUPERPLAYR_BENCHMARK_RESERVE_VIDEO_PIPELINE_CAPACITY": "1"
            ]) { _, new in new },
            bundleIdentifier: "com.example.SuperplayrBenchmark"
        ))
        #expect(PlaybackCoordinator.benchmarkReservesVideoPipelineCapacity(
            environment: planar.merging([
                "SUPERPLAYR_BENCHMARK_RESERVE_VIDEO_PIPELINE_CAPACITY": "1"
            ]) { _, new in new },
            bundleIdentifier: "com.example.Superplayr"
        ))
        #expect(!PlaybackCoordinator.benchmarkReservesVideoPipelineCapacity(
            environment: planar.merging([
                "SUPERPLAYR_BENCHMARK_RESERVE_VIDEO_PIPELINE_CAPACITY": "0"
            ]) { _, new in new },
            bundleIdentifier: "com.example.SuperplayrBenchmark"
        ))
        #expect(PlaybackCoordinator.benchmarkReservesVideoPipelineCapacity(
            environment: [:],
            bundleIdentifier: "com.example.Superplayr"
        ))
        #expect(PlaybackCoordinator.benchmarkVideoPipelineCapacityOverride(
            environment: planar.merging([
                "SUPERPLAYR_BENCHMARK_VIDEO_PIPELINE_CAPACITY": "8"
            ]) { _, new in new },
            bundleIdentifier: "com.example.SuperplayrBenchmark"
        ) == 8)
        #expect(PlaybackCoordinator.benchmarkVideoPipelineCapacityOverride(
            environment: planar.merging([
                "SUPERPLAYR_BENCHMARK_VIDEO_PIPELINE_CAPACITY": "17"
            ]) { _, new in new },
            bundleIdentifier: "com.example.SuperplayrBenchmark"
        ) == nil)
        #expect(PlaybackCoordinator.benchmarkUsesFairDemuxDispatch(
            environment: planar.merging([
                "SUPERPLAYR_BENCHMARK_FAIR_DEMUX_DISPATCH": "1"
            ]) { _, new in new },
            bundleIdentifier: "com.example.SuperplayrBenchmark"
        ))
        #expect(!PlaybackCoordinator.benchmarkUsesFairDemuxDispatch(
            environment: planar.merging([
                "SUPERPLAYR_BENCHMARK_FAIR_DEMUX_DISPATCH": "1"
            ]) { _, new in new },
            bundleIdentifier: "com.example.Superplayr"
        ))
        #expect(PlaybackCoordinator.benchmarkVideoPipelineCapacityOverride(
            environment: planar.merging([
                "SUPERPLAYR_BENCHMARK_VIDEO_PIPELINE_CAPACITY": "8"
            ]) { _, new in new },
            bundleIdentifier: "com.example.Superplayr"
        ) == nil)
        #expect(PlaybackCoordinator.benchmarkSoftwarePlanarPoolCapacity(
            environment: planar.merging([
                "SUPERPLAYR_BENCHMARK_PLANAR_POOL_CAPACITY": "10"
            ]) { _, new in new },
            bundleIdentifier: "com.example.SuperplayrBenchmark"
        ) == 10)
        #expect(PlaybackCoordinator.benchmarkSoftwarePlanarPoolCapacity(
            environment: planar.merging([
                "SUPERPLAYR_BENCHMARK_PLANAR_POOL_CAPACITY": "6"
            ]) { _, new in new },
            bundleIdentifier: "com.example.SuperplayrBenchmark"
        ) == 16)
        #expect(PlaybackCoordinator.benchmarkSoftwarePlanarPoolCapacity(
            environment: planar.merging([
                "SUPERPLAYR_BENCHMARK_PLANAR_POOL_CAPACITY": "10"
            ]) { _, new in new },
            bundleIdentifier: "com.example.Superplayr"
        ) == 16)
        #expect(PlaybackCoordinator.benchmarkVideoFrameQueueCapacity(
            environment: planar.merging([
                "SUPERPLAYR_BENCHMARK_VIDEO_FRAME_QUEUE_CAPACITY": "8"
            ]) { _, new in new },
            bundleIdentifier: "com.example.Superplayr"
        ) == 12)
    }

    @Test func benchmarkControlRequiresExactBundleOverrideAndSession() throws {
        let fixture = try CoordinatorFixture()
        let environment = [
            "SUPERPLAYR_ENABLE_BENCHMARK_OVERRIDES": "1",
            "SUPERPLAYR_BENCHMARK_CONTROL_SESSION": "session-1",
        ]

        #expect(!fixture.coordinator.executeBenchmarkControl(
            session: "session-1",
            id: "pause-1",
            action: .pause,
            environment: environment,
            bundleIdentifier: "com.example.Superplayr"
        ))
        #expect(!fixture.coordinator.executeBenchmarkControl(
            session: "wrong-session",
            id: "pause-1",
            action: .pause,
            environment: environment,
            bundleIdentifier: "com.example.SuperplayrBenchmark"
        ))
        #expect(!fixture.coordinator.executeBenchmarkControl(
            session: "session-1",
            id: "invalid id",
            action: .pause,
            environment: environment,
            bundleIdentifier: "com.example.SuperplayrBenchmark"
        ))
    }

    @Test func benchmarkControlAcknowledgesTransportAndSeekCompletion() async throws {
        let fixture = try CoordinatorFixture()
        let file = try fixture.createFile("benchmark-control.mkv")
        let environment = [
            "SUPERPLAYR_ENABLE_BENCHMARK_OVERRIDES": "1",
            "SUPERPLAYR_BENCHMARK_CONTROL_SESSION": "session-1",
        ]
        var diagnostics: [String] = []
        fixture.coordinator.benchmarkDiagnosticHandler = { diagnostics.append($0) }

        fixture.coordinator.open(url: file)
        try await waitForPreparation(fixture.coordinator)
        let load = try #require(fixture.runtime.loads.last)
        fixture.runtime.emit(.loaded, identity: load.identity)
        fixture.runtime.emit(.prerollReady, identity: load.identity)
        fixture.runtime.emit(.pauseChanged(false), identity: load.identity)

        #expect(fixture.coordinator.executeBenchmarkControl(
            session: "session-1",
            id: "pause-1",
            action: .pause,
            environment: environment,
            bundleIdentifier: "com.example.SuperplayrBenchmark"
        ))
        fixture.runtime.emit(.pauseChanged(true), identity: load.identity)

        #expect(fixture.coordinator.executeBenchmarkControl(
            session: "session-1",
            id: "seek-1",
            action: .seekExact(42),
            environment: environment,
            bundleIdentifier: "com.example.SuperplayrBenchmark"
        ))
        fixture.runtime.emit(.seekCompleted, identity: load.identity)

        #expect(fixture.runtime.seeks.last == SeekRecord(value: 42, mode: .absoluteExact))
        #expect(diagnostics.contains {
            $0.contains("id=pause-1") && $0.contains("result=transport-confirmed")
        })
        #expect(diagnostics.contains {
            $0.contains("id=seek-1") && $0.contains("result=seek-pipeline-completed")
        })
    }

    @Test func benchmarkControlCapturesSynchronousTransportCompletion() async throws {
        let runtime = CoordinatorFakeBackend(synchronouslyCompletesRateChanges: true)
        let fixture = try CoordinatorFixture(runtime: runtime)
        let file = try fixture.createFile("benchmark-sync-control.mkv")
        let environment = [
            "SUPERPLAYR_ENABLE_BENCHMARK_OVERRIDES": "1",
            "SUPERPLAYR_BENCHMARK_CONTROL_SESSION": "session-1",
        ]
        var diagnostics: [String] = []
        fixture.coordinator.benchmarkDiagnosticHandler = { diagnostics.append($0) }

        fixture.coordinator.open(url: file)
        try await waitForPreparation(fixture.coordinator)
        let load = try #require(runtime.loads.last)
        runtime.emit(.loaded, identity: load.identity)
        runtime.emit(.prerollReady, identity: load.identity)

        #expect(fixture.coordinator.executeBenchmarkControl(
            session: "session-1",
            id: "pause-sync",
            action: .pause,
            environment: environment,
            bundleIdentifier: "com.example.SuperplayrBenchmark"
        ))
        #expect(diagnostics.contains {
            $0.contains("id=pause-sync") && $0.contains("result=transport-confirmed")
        })
    }

    @Test func loadedEventRestoresResumePositionThroughNativeRuntime() async throws {
        let fixture = try CoordinatorFixture()
        let file = try fixture.createFile("episode-01.mkv")
        fixture.persistence.setPlaybackPosition(42, for: file)

        fixture.coordinator.open(url: file)
        try await waitForPreparation(fixture.coordinator)
        let load = try #require(fixture.runtime.loads.last)
        fixture.runtime.emit(.loaded, identity: load.identity)
        fixture.runtime.emit(.seekCompleted, identity: load.identity)
        fixture.runtime.emit(.pauseChanged(false), identity: load.identity)

        #expect(fixture.runtime.seeks.last == SeekRecord(value: 42, mode: .absoluteExact))
        #expect(fixture.coordinator.state.phase == .playing)
        #expect(fixture.runtime.playCount >= 1)
    }

    @Test func durationPublishedDuringPrerollEnablesTimeline() async throws {
        let fixture = try CoordinatorFixture()
        let file = try fixture.createFile("episode-duration.mkv")

        fixture.coordinator.open(url: file)
        try await waitForPreparation(fixture.coordinator)
        let load = try #require(fixture.runtime.loads.last)
        fixture.runtime.emit(.loaded, identity: load.identity)
        #expect(fixture.coordinator.state.phase == .preparing)

        fixture.runtime.emit(.durationChanged(1_200), identity: load.identity)

        #expect(fixture.coordinator.state.duration == 1_200)
        #expect(fixture.coordinator.viewStore.duration == 1_200)
    }

    @Test func staleEventsAreRejectedAndEOFAdvancesPlaylist() async throws {
        let fixture = try CoordinatorFixture()
        let first = try fixture.createFile("episode-01.mkv")
        let second = try fixture.createFile("episode-02.mkv")

        fixture.coordinator.open(urls: [second, first])
        try await waitForPreparation(fixture.coordinator)
        let firstLoad = try #require(fixture.runtime.loads.last)
        let firstLoadedURL = firstLoad.identity.source.url
        fixture.runtime.emit(.loaded, identity: firstLoad.identity)
        fixture.runtime.emit(.positionChanged(25), identity: firstLoad.identity)
        fixture.runtime.emit(.endOfFile, identity: firstLoad.identity)
        await waitForAdvance(fixture.runtime, after: firstLoad.identity.generation)

        let secondLoad = try #require(fixture.runtime.loads.last)
        #expect(secondLoad.identity.source.url == fixture.coordinator.state.playlist[1].url)
        #expect(secondLoad.identity.generation > firstLoad.identity.generation)
        fixture.runtime.emit(.loaded, identity: secondLoad.identity)
        fixture.runtime.emit(.positionChanged(900), identity: firstLoad.identity)
        fixture.runtime.emit(.durationChanged(900), identity: firstLoad.identity)
        #expect(fixture.coordinator.state.position == 0)
        #expect(fixture.coordinator.state.duration == 0)
        #expect(fixture.coordinator.state.currentPlaylistIndex == 1)
        #expect(fixture.persistence.playbackProgress(for: firstLoadedURL)?.isCompleted == true)
        #expect(fixture.coordinator.state.recentDiagnosticMessages.contains {
            $0.contains("Discarded stale event")
        })
    }

    @Test func openingFolderUsesDisplayedOrderAndStartsFirstPlayableItem() async throws {
        let fixture = try CoordinatorFixture()
        let first = try fixture.createFile("episode-01.mkv")
        let second = try fixture.createFile("episode-02.mkv")

        fixture.coordinator.openFolder(url: first.deletingLastPathComponent())

        for _ in 0..<100 where fixture.runtime.loads.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        let load = try #require(fixture.runtime.loads.last)
        fixture.runtime.emit(.loaded, identity: load.identity)

        let displayedOrder = fixture.coordinator.state.playlist.map(\.url)
        #expect(Set(displayedOrder) == Set([first, second]))
        #expect(fixture.coordinator.state.currentPlaylistIndex == 0)
        #expect(fixture.runtime.loads.last?.identity.source.url == displayedOrder[0])
    }

    @Test func sourceBrowserSelectionPlaysTheExactFileWithinItsFolderScope() async throws {
        let fixture = try CoordinatorFixture()
        let folder = try fixture.createDirectory("Season 1")
        let first = try fixture.createFile("episode-01.mkv", in: folder)
        let second = try fixture.createFile("episode-02.mkv", in: folder)

        fixture.coordinator.openFileInContainingFolder(url: second)

        for _ in 0..<100 where fixture.runtime.loads.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        let load = try #require(fixture.runtime.loads.last)
        #expect(load.identity.source.url == second)
        fixture.runtime.emit(.loaded, identity: load.identity)

        #expect(fixture.coordinator.state.currentFolder == folder)
        #expect(fixture.coordinator.state.playlist.map(\.url) == [first, second])
        #expect(fixture.coordinator.state.currentPlaylistIndex == 1)
    }

    @Test func appendPreservesCurrentWhileReplaceStartsTheNewSelection() async throws {
        let fixture = try CoordinatorFixture()
        let first = try fixture.createFile("append-01.mkv")
        let second = try fixture.createFile("append-02.mkv")
        let third = try fixture.createFile("append-03.mkv")

        fixture.coordinator.open(urls: [first, second])
        try await waitForPreparation(fixture.coordinator)
        let initialLoad = try #require(fixture.runtime.loads.last)
        fixture.runtime.emit(.loaded, identity: initialLoad.identity)
        let currentURL = try #require(fixture.coordinator.state.currentURL)
        let loadCount = fixture.runtime.loads.count
        fixture.coordinator.open(urls: [third], mode: .append)
        try await waitForPreparation(fixture.coordinator)

        #expect(fixture.coordinator.state.playlist.count == 3)
        #expect(fixture.coordinator.state.currentURL == currentURL)
        #expect(fixture.runtime.loads.count == loadCount)

        fixture.coordinator.open(urls: [third], mode: .replace)
        try await waitForPreparation(fixture.coordinator)
        #expect(fixture.runtime.loads.count == loadCount + 1)
        #expect(fixture.coordinator.state.currentURL == currentURL)
        let replacement = try #require(fixture.runtime.loads.last)
        fixture.runtime.emit(.loaded, identity: replacement.identity)
        #expect(fixture.coordinator.state.playlist.map(\.url) == [third])
        #expect(fixture.coordinator.state.currentURL == third)
    }

    @Test
    func failedCandidateKeepsCommittedPlaylistSourceAndPersistenceAuthority() async throws {
        let fixture = try CoordinatorFixture()
        let committed = try fixture.createFile("committed.mkv")
        let malformed = try fixture.createFile("malformed.mkv")

        fixture.coordinator.open(url: committed)
        try await waitForPreparation(fixture.coordinator)
        var load = try #require(fixture.runtime.loads.last)
        fixture.runtime.emit(.loaded, identity: load.identity)
        fixture.runtime.emit(.pauseChanged(false), identity: load.identity)
        #expect(fixture.coordinator.state.currentURL == committed)
        #expect(fixture.persistence.lastOpenedMedia() == .file(committed))

        fixture.coordinator.open(url: malformed)
        try await waitForPreparation(fixture.coordinator)
        load = try #require(fixture.runtime.loads.last)
        let candidateOpen = try #require(fixture.runtime.executedEffects.last(where: {
            if case .openSource = $0.kind { return true }
            return false
        }))

        #expect(fixture.coordinator.state.currentURL == committed)
        #expect(fixture.coordinator.state.playlist.map(\.url) == [committed])
        #expect(fixture.coordinator.state.currentPlaylistIndex == 0)
        #expect(fixture.persistence.lastOpenedMedia() == .file(committed))

        fixture.runtime.emitResult(
            context: candidateOpen.context,
            kind: .failed
        )

        #expect(fixture.coordinator.state.currentURL == committed)
        #expect(fixture.coordinator.state.playlist.map(\.url) == [committed])
        #expect(fixture.coordinator.state.currentPlaylistIndex == 0)
        #expect(fixture.persistence.lastOpenedMedia() == .file(committed))
        #expect(fixture.coordinator.state.coreFailureCode == "faultInjectedFailure")
        #expect(load.identity.source.url == malformed)
    }

    @Test func failedAdvanceCanRetryOrSkipWithoutMovingCommittedIdentity() async throws {
        let fixture = try CoordinatorFixture()
        let files = try ["a.mkv", "b.mkv", "c.mkv"].map { try fixture.createFile($0) }
        fixture.coordinator.open(urls: files)
        try await waitForPreparation(fixture.coordinator)
        fixture.runtime.emit(.loaded, identity: fixture.runtime.loads.last!.identity)
        fixture.coordinator.sortPlaylist(by: .name, ascending: true)
        fixture.coordinator.playItem(at: 0)
        fixture.runtime.emit(.loaded, identity: fixture.runtime.loads.last!.identity)
        fixture.coordinator.playNext()
        func failLatest() throws {
            let effect = try #require(fixture.runtime.executedEffects.last {
                if case .openSource = $0.kind { return true }; return false
            })
            fixture.runtime.emitResult(context: effect.context, kind: .failed)
        }
        try failLatest()
        #expect(fixture.coordinator.state.currentURL == files[0])
        #expect(fixture.coordinator.state.recoveryIssue?.kind == .failedSource(canSkip: true))
        fixture.coordinator.retryRecovery()
        #expect(fixture.runtime.loads.last?.identity.source.url == files[1])
        try failLatest()
        fixture.coordinator.playNext()
        #expect(fixture.runtime.loads.last?.identity.source.url == files[2])
        #expect(fixture.coordinator.state.currentURL == files[0])
        try failLatest()
        #expect(fixture.coordinator.state.recoveryIssue?.kind == .failedSource(canSkip: false))
        let attempts = fixture.runtime.loads.count
        fixture.coordinator.skipFailedSource()
        #expect(fixture.runtime.loads.count == attempts)
        fixture.coordinator.sortPlaylist(by: .name, ascending: false)
        #expect(fixture.coordinator.state.recoveryIssue == nil)
        fixture.coordinator.retryRecovery()
        #expect(fixture.runtime.loads.count == attempts)
        fixture.coordinator.stop()
        #expect(fixture.coordinator.state.recoveryIssue == nil)
    }

    @Test func unavailableRestoreCanBeForgottenWithoutDeletingHistory() async throws {
        let fixture = try CoordinatorFixture()
        let missing = fixture.root.appendingPathComponent("missing.mkv")
        fixture.persistence.setPlaybackPosition(42, for: missing)
        fixture.persistence.setLastOpenedMedia(.file(missing))
        try fixture.sessionStore.save(PlaybackSessionRecord(source: .localFile(missing), position: 42, wasPaused: true))
        #expect(fixture.coordinator.restoreLastSession())
        try await waitForPreparation(fixture.coordinator)
        #expect(fixture.coordinator.state.recoveryIssue?.kind == .unavailableRestore(isFolder: false))
        #expect(fixture.coordinator.viewStore.recoveryIssue == fixture.coordinator.state.recoveryIssue)
        fixture.coordinator.forgetUnavailableSession()
        await fixture.coordinator.shutdown()
        #expect(try fixture.sessionStore.load() == nil)
        #expect(fixture.persistence.lastOpenedMedia() == nil)
        #expect(fixture.persistence.playbackPosition(for: missing) == 42)
    }

    @Test func subtitleEncodingPreferenceSurvivesOtherPreferenceChangesAndRelaunch() async throws {
        let fixture = try CoordinatorFixture()
        fixture.coordinator.setSubtitleFallbackEncoding(.shiftJIS)
        #expect(fixture.coordinator.viewStore.subtitleFallbackEncoding == .shiftJIS)
        fixture.persistence.setVolume(37)
        fixture.persistence.setPlaybackSpeed(1)
        await fixture.coordinator.shutdown()
        let restored = PlaybackCoordinator(persistence: fixture.persistence,
            sessionStore: fixture.sessionStore, runtime: CoordinatorFakeBackend())
        #expect(restored.state.subtitleFallbackEncoding == .shiftJIS)
        await restored.shutdown()
    }

    @Test func locatedRestoreCommitsOnlyAfterSuccessfulOpen() async throws {
        let fixture = try CoordinatorFixture()
        let missing = fixture.root.appendingPathComponent("old.mkv")
        let located = try fixture.createFile("found.mkv")
        let saved = PlaybackSessionRecord(source: .localFile(missing), position: 42, wasPaused: true)
        try fixture.sessionStore.save(saved)
        #expect(fixture.coordinator.restoreLastSession())
        try await waitForPreparation(fixture.coordinator)
        fixture.coordinator.locateUnavailableSession(at: located)
        try await waitForPreparation(fixture.coordinator)
        #expect(try fixture.sessionStore.load()?.source == saved.source)
        let load = try #require(fixture.runtime.loads.last)
        fixture.runtime.emit(.loaded, identity: load.identity)
        #expect(fixture.coordinator.state.currentURL == located)
        #expect(fixture.runtime.seeks.last?.value == 42)
        #expect(fixture.coordinator.state.recoveryIssue == nil)
        await fixture.coordinator.shutdown()
        #expect(try fixture.sessionStore.load()?.source == .localFile(located))
    }

    @Test
    func candidatePrerollAtomicallyCommitsPlaylistSourceAndPersistence() async throws {
        let fixture = try CoordinatorFixture()
        let committed = try fixture.createFile("committed.mkv")
        let candidate = try fixture.createFile("candidate.mkv")

        fixture.coordinator.open(url: committed)
        try await waitForPreparation(fixture.coordinator)
        var load = try #require(fixture.runtime.loads.last)
        fixture.runtime.emit(.loaded, identity: load.identity)

        fixture.coordinator.open(url: candidate)
        try await waitForPreparation(fixture.coordinator)
        load = try #require(fixture.runtime.loads.last)
        #expect(fixture.coordinator.state.currentURL == committed)
        #expect(fixture.persistence.lastOpenedMedia() == .file(committed))

        fixture.runtime.emit(.loaded, identity: load.identity)

        #expect(fixture.coordinator.state.currentURL == candidate)
        #expect(fixture.coordinator.state.playlist.map(\.url) == [candidate])
        #expect(fixture.coordinator.state.currentPlaylistIndex == 0)
        #expect(fixture.persistence.lastOpenedMedia() == .file(candidate))
    }

    @Test func mixedFolderAndFileDropExpandsAndDeduplicatesEverything() async throws {
        let fixture = try CoordinatorFixture()
        let direct = try fixture.createFile("direct.mkv")
        let folder = direct.deletingLastPathComponent().appendingPathComponent("drop-folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let nested = folder.appendingPathComponent("nested.mkv")
        try Data().write(to: nested)

        fixture.coordinator.open(urls: [direct, folder, direct])
        try await waitForPreparation(fixture.coordinator)
        for _ in 0..<100 where fixture.runtime.loads.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        let load = try #require(fixture.runtime.loads.last)
        fixture.runtime.emit(.loaded, identity: load.identity)

        #expect(Set(fixture.coordinator.state.playlist.map(\.url)) == Set([direct, nested]))
        #expect(fixture.coordinator.state.playlist.count == 2)
    }

    @Test func subtitleOnlyDropLoadsOneAndReportsTheNativeMultiTrackLimit() async throws {
        let fixture = try CoordinatorFixture()
        let media = try fixture.createFile("subtitles.mkv")
        let firstSubtitle = try fixture.createFile("subtitles.en.srt")
        let secondSubtitle = try fixture.createFile("subtitles.fr.srt")
        fixture.coordinator.open(url: media)
        try await waitForPreparation(fixture.coordinator)
        let load = try #require(fixture.runtime.loads.last)
        fixture.runtime.emit(.loaded, identity: load.identity)

        fixture.coordinator.open(urls: [firstSubtitle, secondSubtitle])
        try await waitForPreparation(fixture.coordinator)

        #expect(fixture.runtime.externalSubtitleLoads.count == 1)
        #expect(fixture.coordinator.state.lastError?.contains(
            "supports one external subtitle"
        ) == true)
    }

    @Test func sortingChangesPlaybackOrderWithoutChangingCurrentIdentity() async throws {
        let fixture = try CoordinatorFixture()
        let ten = try fixture.createFile("Episode 10.mkv")
        let two = try fixture.createFile("Episode 2.mkv")
        fixture.coordinator.open(urls: [ten, two])
        try await waitForPreparation(fixture.coordinator)
        let load = try #require(fixture.runtime.loads.last)
        fixture.runtime.emit(.loaded, identity: load.identity)
        let currentURL = try #require(fixture.coordinator.state.currentURL)

        fixture.coordinator.sortPlaylist(by: .name, ascending: true)

        #expect(fixture.coordinator.state.playlist.map(\.url) == [two, ten])
        #expect(fixture.coordinator.state.currentURL == currentURL)
        let currentIndex = try #require(fixture.coordinator.state.currentPlaylistIndex)
        if fixture.coordinator.state.playlist.indices.contains(currentIndex + 1) {
            fixture.coordinator.playNext()
            let next = try #require(fixture.runtime.loads.last)
            fixture.runtime.emit(.loaded, identity: next.identity)
            #expect(fixture.coordinator.state.currentURL
                == fixture.coordinator.state.playlist[currentIndex + 1].url)
        }
    }

    @Test func repeatAndShuffleRemainVisibleAndPreserveCurrentIdentity() async throws {
        let fixture = try CoordinatorFixture()
        let first = try fixture.createFile("repeat-01.mkv")
        let second = try fixture.createFile("repeat-02.mkv")
        fixture.coordinator.open(urls: [first, second])
        try await waitForPreparation(fixture.coordinator)
        let load = try #require(fixture.runtime.loads.last)
        fixture.runtime.emit(.loaded, identity: load.identity)
        let currentURL = try #require(fixture.coordinator.state.currentURL)
        let itemIDs = Set(fixture.coordinator.state.playlist.map(\.id))

        fixture.coordinator.setRepeatMode(.all)
        fixture.coordinator.setShuffleEnabled(true)

        #expect(fixture.coordinator.state.repeatMode == .all)
        #expect(fixture.coordinator.state.isShuffleEnabled)
        #expect(fixture.coordinator.state.currentURL == currentURL)
        #expect(Set(fixture.coordinator.state.playlist.map(\.id)) == itemIDs)
        #expect(fixture.persistence.loadPreferences().repeatMode == .all)
        #expect(fixture.persistence.loadPreferences().isShuffleEnabled)
    }

    @Test func repeatOneReloadsTheCompletedItemFromTheBeginning() async throws {
        let fixture = try CoordinatorFixture()
        let first = try fixture.createFile("repeat-one-01.mkv")
        let second = try fixture.createFile("repeat-one-02.mkv")
        fixture.coordinator.open(urls: [first, second])
        try await waitForPreparation(fixture.coordinator)
        fixture.coordinator.setRepeatMode(.one)
        let original = try #require(fixture.runtime.loads.last)

        fixture.runtime.emit(.loaded, identity: original.identity)
        fixture.runtime.emit(.pauseChanged(false), identity: original.identity)
        fixture.runtime.emit(.durationChanged(120), identity: original.identity)
        fixture.runtime.emit(.positionChanged(120), identity: original.identity)
        fixture.runtime.emit(.endOfFile, identity: original.identity)
        await waitForAdvance(fixture.runtime, after: original.identity.generation)

        let repeated = try #require(fixture.runtime.loads.last)
        #expect(repeated.identity.source.url == original.identity.source.url)
        #expect(repeated.identity.generation > original.identity.generation)
        fixture.runtime.emit(.loaded, identity: repeated.identity)
        #expect(fixture.coordinator.state.position == 0)
    }

    @Test func finalEOFKeepsSourceAndQueueAndPlaySeeksBackToStart() async throws {
        let fixture = try CoordinatorFixture()
        let video = try fixture.createFile("final-frame.mkv")
        fixture.coordinator.open(url: video)
        try await waitForPreparation(fixture.coordinator)
        let load = try #require(fixture.runtime.loads.last)
        fixture.runtime.emit(.loaded, identity: load.identity)
        fixture.runtime.emit(.pauseChanged(false), identity: load.identity)
        fixture.runtime.emit(.durationChanged(120), identity: load.identity)
        fixture.runtime.emit(.positionChanged(120), identity: load.identity)
        fixture.runtime.emit(.endOfFile, identity: load.identity)
        for _ in 0..<200 {
            if fixture.coordinator.state.isPauseDesired { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(fixture.coordinator.state.currentURL == video)
        #expect(fixture.coordinator.state.playlist.count == 1)
        #expect(fixture.coordinator.state.isPauseDesired)
        #expect(fixture.runtime.loads.count == 1)
        fixture.coordinator.play()
        #expect(fixture.runtime.seeks.last?.value == 0)
        #expect(fixture.runtime.loads.count == 1)
    }

    @Test(arguments: [true, false])
    func ordinaryRestoreHonorsPausedRestorePreference(paused: Bool) async throws {
        let fixture = try CoordinatorFixture()
        let video = try fixture.createFile("restore-policy.mkv")
        try fixture.sessionStore.save(.init(source: .localFile(video), position: 42, wasPaused: false))
        fixture.coordinator.setRestoresSessionPaused(paused)
        #expect(fixture.coordinator.restoreLastSession())
        try await waitForPreparation(fixture.coordinator)
        let load = try #require(fixture.runtime.loads.last)
        fixture.runtime.emit(.loaded, identity: load.identity)
        #expect(fixture.coordinator.state.isPauseDesired == paused)
        #expect(fixture.runtime.seeks.last?.value == 42)
    }

    @Test func historyOptOutBlocksSessionRestoreAndFinalCheckpoint() async throws {
        let fixture = try CoordinatorFixture()
        let video = try fixture.createFile("history-opt-out.mkv")
        try fixture.sessionStore.save(.init(source: .localFile(video), position: 42, wasPaused: false))
        fixture.coordinator.setRemembersPlaybackHistory(false)
        #expect(!fixture.coordinator.restoreLastSession())
        fixture.coordinator.open(url: video)
        try await waitForPreparation(fixture.coordinator)
        let load = try #require(fixture.runtime.loads.last)
        fixture.runtime.emit(.loaded, identity: load.identity)
        fixture.runtime.emit(.positionChanged(70), identity: load.identity)
        await fixture.coordinator.shutdown()
        #expect(try fixture.sessionStore.load()?.position == 42)
        #expect(fixture.persistence.playbackPosition(for: video) == nil)
    }

    @Test func repeatAllWrapsFromTheLastDisplayedItemToTheFirst() async throws {
        let fixture = try CoordinatorFixture()
        let first = try fixture.createFile("repeat-all-01.mkv")
        let second = try fixture.createFile("repeat-all-02.mkv")
        fixture.coordinator.open(urls: [first, second])
        try await waitForPreparation(fixture.coordinator)
        var load = try #require(fixture.runtime.loads.last)
        fixture.runtime.emit(.loaded, identity: load.identity)
        fixture.coordinator.playItem(at: 1)
        load = try #require(fixture.runtime.loads.last)
        fixture.runtime.emit(.loaded, identity: load.identity)
        fixture.coordinator.setRepeatMode(.all)
        let last = try #require(fixture.runtime.loads.last)

        fixture.runtime.emit(.loaded, identity: last.identity)
        fixture.runtime.emit(.endOfFile, identity: last.identity)
        await waitForAdvance(fixture.runtime, after: last.identity.generation)

        let wrapped = try #require(fixture.runtime.loads.last)
        #expect(wrapped.identity.source.url == fixture.coordinator.state.playlist[0].url)
        fixture.runtime.emit(.loaded, identity: wrapped.identity)
        #expect(fixture.coordinator.state.currentPlaylistIndex == 0)
    }

    @Test func restoresDirectPlaylistIndexPausedStateAndExactPosition() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("SuperplayrRestoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("restore-01.mkv")
        let second = root.appendingPathComponent("restore-02.mkv")
        try Data().write(to: first)
        try Data().write(to: second)
        let sessionStore = AtomicPlaybackSessionStore(
            fileURL: root.appendingPathComponent("session.json")
        )
        try sessionStore.save(PlaybackSessionRecord(
            source: .localFile(second),
            playlistItems: [
                FolderPlaylistItem(url: first),
                FolderPlaylistItem(url: second),
            ],
            playlistIndex: 1,
            position: 42,
            wasPaused: true
        ))
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        let runtime = CoordinatorFakeBackend()
        let coordinator = PlaybackCoordinator(
            persistence: PlaybackPersistenceStore(
                userDefaults: defaults,
                namespace: UUID().uuidString
            ),
            sessionStore: sessionStore,
            runtime: runtime
        )

        #expect(coordinator.restoreLastSession())
        try await waitForPreparation(coordinator)
        let load = try #require(runtime.loads.last)
        #expect(load.identity.source == .localFile(second))
        runtime.emit(.loaded, identity: load.identity)
        #expect(coordinator.state.currentPlaylistIndex == 1)
        #expect(coordinator.state.isPauseDesired)
        #expect(runtime.seeks.last == SeekRecord(value: 42, mode: .absoluteExact))
    }

    @Test func finderOpenSupersedesPausedRestoreForEveryRestoredField() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("SuperplayrFinderOpenRestore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let restoredFile = root.appendingPathComponent("restored-paused.mkv")
        let finderFile = root.appendingPathComponent("finder-opened.mkv")
        try Data().write(to: restoredFile)
        try Data().write(to: finderFile)
        let sessionStore = AtomicPlaybackSessionStore(
            fileURL: root.appendingPathComponent("session.json")
        )
        try sessionStore.save(PlaybackSessionRecord(
            source: .localFile(restoredFile),
            position: 42,
            wasPaused: true
        ))
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        let runtime = CoordinatorFakeBackend()
        let coordinator = PlaybackCoordinator(
            persistence: PlaybackPersistenceStore(
                userDefaults: defaults,
                namespace: UUID().uuidString
            ),
            sessionStore: sessionStore,
            runtime: runtime
        )

        #expect(coordinator.restoreLastSession())
        coordinator.open(url: finderFile)
        try await waitForPreparation(coordinator)
        let finderLoad = try #require(runtime.loads.last)
        #expect(finderLoad.identity.source == .localFile(finderFile))

        runtime.emit(.loaded, identity: finderLoad.identity)

        #expect(!coordinator.state.isPauseDesired)
        #expect(runtime.seeks.isEmpty)
        try await waitForPreparation(coordinator)
        #expect(runtime.loads.count == 1)
    }

    @Test(arguments: [false, true])
    func sameFileFinderOpenSupersedesRestoreAfterNativeLoadBegins(restoreCompleted: Bool) async throws {
        let fixture = try CoordinatorFixture()
        let file = try fixture.createFile("same-source-restore.mkv")
        try fixture.sessionStore.save(.init(source: .localFile(file), position: 42, wasPaused: true))
        #expect(fixture.coordinator.restoreLastSession())
        try await waitForPreparation(fixture.coordinator)
        let restoreLoad = try #require(fixture.runtime.loads.last)
        let restoreOpen = try #require(fixture.runtime.executedEffects.last { if case .openSource = $0.kind { true } else { false } })
        if restoreCompleted {
            fixture.runtime.emit(.loaded, identity: restoreLoad.identity)
            fixture.runtime.emit(.seekCompleted, identity: restoreLoad.identity)
        }
        let priorSeeks = fixture.runtime.seeks.count
        fixture.coordinator.open(url: file)
        try await waitForPreparation(fixture.coordinator)
        let finderLoad = try #require(fixture.runtime.loads.last)
        #expect(fixture.runtime.loads.count == (restoreCompleted ? 1 : 2))
        if !restoreCompleted {
            #expect(finderLoad.identity != restoreLoad.identity)
            // A late cancellation for the superseded load must not retire the new load.
            fixture.runtime.emitResult(context: restoreOpen.context, kind: .cancelled)
            fixture.runtime.emit(.loaded, identity: finderLoad.identity)
        }
        fixture.runtime.emit(.pauseChanged(false), identity: finderLoad.identity)
        fixture.runtime.emit(.positionChanged(3), identity: finderLoad.identity)
        #expect(!fixture.coordinator.state.isPauseDesired)
        #expect(fixture.coordinator.state.position == 3)
        #expect(fixture.runtime.seeks.count == priorSeeks)
        if !restoreCompleted {
            fixture.runtime.emit(.positionChanged(99), identity: restoreLoad.identity)
            #expect(fixture.coordinator.state.position == 3)
        }
        await fixture.coordinator.shutdown()
    }

    @Test(arguments: [false, true])
    func failedSameSourceReloadPreservesCommittedSessionIdentity(failPreroll: Bool) async throws {
        let fixture = try CoordinatorFixture()
        let file = try #require(URL(string: "https://example.invalid/reload-failure.mkv"))
        fixture.coordinator.openRemoteStream(url: file)
        try await waitForPreparation(fixture.coordinator)
        let original = try #require(fixture.runtime.loads.last)
        fixture.runtime.emit(.loaded, identity: original.identity)
        fixture.runtime.emit(.pauseChanged(false), identity: original.identity)
        fixture.coordinator.openRemoteStream(url: file)
        try await waitForPreparation(fixture.coordinator)
        let replacement = try #require(fixture.runtime.loads.last)
        #expect(fixture.runtime.loads.count == 2)
        #expect(replacement.identity != original.identity)
        let open = try #require(fixture.runtime.executedEffects.last { if case .openSource = $0.kind { true } else { false } })
        if failPreroll {
            fixture.runtime.emitResult(context: open.context, kind: .succeeded)
            let preroll = try #require(fixture.runtime.executedEffects.last { if case .awaitPreroll = $0.kind { true } else { false } })
            fixture.runtime.emitResult(context: preroll.context, kind: .failed)
        } else {
            fixture.runtime.emitResult(context: open.context, kind: .failed)
        }
        #expect(fixture.coordinator.state.recoveryIssue != nil)
        fixture.runtime.emit(.positionChanged(7), identity: original.identity)
        #expect(fixture.coordinator.state.position == 7)
        fixture.runtime.emit(.positionChanged(99), identity: replacement.identity)
        #expect(fixture.coordinator.state.position == 7)
        await fixture.coordinator.shutdown()
    }

    @Test func shuffleRestoresBaseOrderAcrossRelaunch() async throws {
        let fixture = try CoordinatorFixture()
        let files = try ["episode-1.mkv", "episode-2.mkv", "episode-3.mkv"].map {
            try fixture.createFile($0)
        }
        fixture.coordinator.open(urls: files)
        try await waitForPreparation(fixture.coordinator)
        let load = try #require(fixture.runtime.loads.last)
        fixture.runtime.emit(.loaded, identity: load.identity)
        fixture.coordinator.sortPlaylist(by: .name, ascending: true)
        let original = fixture.coordinator.state.playlist.map(\.id)
        let current = fixture.coordinator.state.currentURL
        fixture.coordinator.setShuffleEnabled(true)
        await fixture.coordinator.shutdown()

        let runtime = CoordinatorFakeBackend()
        let restored = PlaybackCoordinator(
            persistence: fixture.persistence, sessionStore: fixture.sessionStore, runtime: runtime
        )
        #expect(restored.restoreLastSession())
        try await waitForPreparation(restored)
        let resumed = try #require(runtime.loads.last)
        runtime.emit(.loaded, identity: resumed.identity)
        restored.setShuffleEnabled(false)
        #expect(restored.state.playlist.map(\.id) == original)
        #expect(restored.state.currentURL == current)
        restored.setShuffleEnabled(true)
        restored.sortPlaylist(by: .name, ascending: false)
        #expect(!restored.state.isShuffleEnabled)
        #expect(restored.state.playlist.map(\.id) == Array(original.reversed()))
        restored.setShuffleEnabled(true)
        let moved = restored.state.playlist.last!.id
        let target = restored.state.playlist.first!.id
        restored.movePlaylistItem(id: moved, before: target)
        #expect(!restored.state.isShuffleEnabled)
        #expect(restored.state.playlist.first?.id == moved)
        #expect(restored.state.currentURL == current)
        await restored.shutdown()
    }

    @Test func unshuffleRetainsAdditionsAndOmitsRemovedEntries() throws {
        let fixture = try CoordinatorFixture()
        let files = try ["first.mkv", "second.mkv", "third.mkv", "new.mkv"].map {
            FolderPlaylistItem(url: try fixture.createFile($0))
        }
        let result = PlaylistMutation.restoringOrder(
            [files[2], files[3], files[0]], ids: Array(files.prefix(3)).map(\.id)
        )
        #expect(result.map(\.id) == [files[0].id, files[2].id, files[3].id])
    }

    @Test(arguments: [false, true])
    func unavailableRestoreRetainsSessionAndCanRetry(folderSource: Bool) async throws {
        let fixture = try CoordinatorFixture()
        let folder = try fixture.createDirectory("mounted")
        let file = try fixture.createFile("episode.mkv", in: folder)
        let absent = folder.appendingPathComponent("offline-episode.mkv")
        let record = PlaybackSessionRecord(
            source: .localFile(file),
            collectionFolder: folderSource ? folder : nil,
            playlistItems: [FolderPlaylistItem(url: file), FolderPlaylistItem(url: absent)],
            playlistIndex: 0,
            position: 12,
            wasPaused: true
        )
        try fixture.sessionStore.save(record)
        let offline = folder.appendingPathExtension("offline")
        try FileManager.default.moveItem(at: folder, to: offline)

        #expect(fixture.coordinator.restoreLastSession())
        try await waitForPreparation(fixture.coordinator)
        #expect(try fixture.sessionStore.load() == record)
        #expect(fixture.runtime.loads.isEmpty)

        try FileManager.default.moveItem(at: offline, to: folder)
        #expect(fixture.coordinator.restoreLastSession())
        try await waitForPreparation(fixture.coordinator)
        await waitForAdvance(fixture.runtime, after: 0)
        let load = try #require(fixture.runtime.loads.last)
        fixture.runtime.emit(.loaded, identity: load.identity)
        if !folderSource {
            #expect(fixture.coordinator.state.playlist.map(\.url) == [file, absent])
        }
        await fixture.coordinator.shutdown()
    }

    @Test func rewatchCheckpointOverridesHistoricalCompletedBadge() async throws {
        let fixture = try CoordinatorFixture()
        let file = try fixture.createFile("rewatch.mkv")
        fixture.persistence.setPlaybackProgress(position: 1_000, duration: 1_000, for: file)
        fixture.persistence.setPlaybackProgress(position: 200, duration: 1_000, for: file)
        #expect(fixture.persistence.playbackProgress(for: file)?.isCompleted == true)
        try fixture.sessionStore.save(PlaybackSessionRecord(
            source: .localFile(file), position: 200, wasPaused: true
        ))

        #expect(fixture.coordinator.restoreLastSession())
        try await waitForPreparation(fixture.coordinator)
        let load = try #require(fixture.runtime.loads.last)
        fixture.runtime.emit(.loaded, identity: load.identity)
        #expect(fixture.runtime.seeks.last?.value == 200)
        #expect(fixture.persistence.playbackProgress(for: file)?.isCompleted == true)
    }

    @Test func completedSessionRestoresAtStartInsteadOfTheFinalSeconds() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("SuperplayrCompletedRestore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let media = root.appendingPathComponent("completed.mkv")
        try Data().write(to: media)
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        let persistence = PlaybackPersistenceStore(
            userDefaults: defaults,
            namespace: UUID().uuidString
        )
        persistence.setPlaybackProgress(position: 98, duration: 100, for: media)
        let sessionStore = AtomicPlaybackSessionStore(
            fileURL: root.appendingPathComponent("session.json")
        )
        try sessionStore.save(PlaybackSessionRecord(
            source: .localFile(media),
            position: 98,
            wasPaused: true
        ))
        let runtime = CoordinatorFakeBackend()
        let coordinator = PlaybackCoordinator(
            persistence: persistence,
            sessionStore: sessionStore,
            runtime: runtime
        )

        #expect(coordinator.restoreLastSession())
        try await waitForPreparation(coordinator)
        let load = try #require(runtime.loads.last)
        runtime.emit(.loaded, identity: load.identity)

        #expect(runtime.seeks.isEmpty)
        #expect(coordinator.state.isPauseDesired)
    }

    @Test func batchOpenOfStoppedCurrentFileCreatesANewPlaybackSession() async throws {
        let fixture = try CoordinatorFixture()
        let file = try fixture.createFile("reopen-after-close.mkv")
        fixture.coordinator.open(urls: [file])
        try await waitForPreparation(fixture.coordinator)
        let first = try #require(fixture.runtime.loads.last)
        fixture.runtime.emit(.loaded, identity: first.identity)
        fixture.runtime.emit(.durationChanged(300), identity: first.identity)
        fixture.runtime.emit(.positionChanged(43), identity: first.identity)
        fixture.coordinator.stop()
        fixture.coordinator.open(urls: [file])
        try await waitForPreparation(fixture.coordinator)
        #expect(fixture.runtime.loads.count == 2)
        #expect(fixture.runtime.loads.last?.identity != first.identity)
        #expect(fixture.persistence.playbackPosition(for: file) == 43)
        await fixture.coordinator.shutdown()
        #expect(try fixture.sessionStore.load()?.position == 43)
    }

    @Test func quittingAfterStopKeepsTheLastPlaybackCheckpoint() async throws {
        let fixture = try CoordinatorFixture()
        let file = try fixture.createFile("quit-after-close.mkv")
        fixture.coordinator.open(urls: [file])
        try await waitForPreparation(fixture.coordinator)
        let load = try #require(fixture.runtime.loads.last)
        fixture.runtime.emit(.loaded, identity: load.identity)
        fixture.runtime.emit(.durationChanged(300), identity: load.identity)
        fixture.runtime.emit(.positionChanged(43), identity: load.identity)
        fixture.coordinator.stop()
        await fixture.coordinator.shutdown()
        #expect(fixture.persistence.playbackPosition(for: file) == 43)
        #expect(try fixture.sessionStore.load()?.position == 43)
    }

    @Test func shutdownFlushesLatestProgressWithoutDependingOnDebouncedTask() async throws {
        let fixture = try CoordinatorFixture()
        let file = try fixture.createFile("final-progress.mkv")
        fixture.coordinator.open(url: file)
        try await waitForPreparation(fixture.coordinator)
        let load = try #require(fixture.runtime.loads.last)
        fixture.runtime.emit(.loaded, identity: load.identity)
        fixture.runtime.emit(.durationChanged(300), identity: load.identity)
        fixture.runtime.emit(.positionChanged(42), identity: load.identity)
        fixture.runtime.emit(.positionChanged(43), identity: load.identity)
        await fixture.coordinator.shutdown()
        #expect(fixture.persistence.playbackPosition(for: file) == 43)
        #expect(try fixture.sessionStore.load()?.position == 43)
        #expect(fixture.coordinator.shutdownPersistenceError == nil)
        #expect(fixture.runtime.shutdownCount == 1)
    }

    @Test func shutdownIsForwardedExactlyOnce() async throws {
        let fixture = try CoordinatorFixture()
        await fixture.coordinator.shutdown()
        await fixture.coordinator.shutdown()
        #expect(fixture.runtime.shutdownCount == 1)
        #expect(fixture.coordinator.state.phase == .shuttingDown)
    }

    @Test func repeatedAudioRouteChangesReprerollWithoutConsumingFailureRecovery() async throws {
        let fixture = try CoordinatorFixture()
        let file = try fixture.createFile("route-change.mkv")
        fixture.coordinator.open(url: file)
        try await waitForPreparation(fixture.coordinator)
        let load = try #require(fixture.runtime.loads.last)
        fixture.runtime.emit(.loaded, identity: load.identity)
        fixture.coordinator.pause()
        fixture.runtime.emit(.pauseChanged(true), identity: load.identity)
        for time in [12.0, 24.0, 36.0, 48.0] {
            fixture.runtime.emit(.audioOutputChanged(time), identity: load.identity)
            #expect(fixture.runtime.seeks.last == SeekRecord(value: time, mode: .absoluteExact))
            fixture.runtime.emit(.seekCompleted, identity: load.identity)
            fixture.runtime.emit(.prerollReady, identity: load.identity)
            fixture.runtime.emit(.pauseChanged(true), identity: load.identity)
            #expect(fixture.coordinator.state.isPauseDesired)
        }
        #expect(!fixture.runtime.executedEffects.contains {
            switch $0.kind {
            case .flushAudioPresentationForRecovery, .rebuildAudioPresentation, .disableAudioTrack: true
            default: false
            }
        })
    }

    @Test func audioRouteChangePreservesAnInFlightUserSeekTarget() async throws {
        let fixture = try CoordinatorFixture()
        let file = try fixture.createFile("route-during-seek.mkv")
        fixture.coordinator.open(url: file)
        try await waitForPreparation(fixture.coordinator)
        let load = try #require(fixture.runtime.loads.last)
        fixture.runtime.emit(.loaded, identity: load.identity)
        fixture.coordinator.seek(to: 180)
        fixture.runtime.emit(.audioOutputChanged(20), identity: load.identity)
        #expect(fixture.runtime.seeks.last?.value == 180)
        let count = fixture.runtime.seeks.count
        fixture.runtime.emit(.audioOutputChanged(50), identity: PlayerSessionIdentity(
            source: .localFile(file), generation: load.identity.generation + 10
        ))
        #expect(fixture.runtime.seeks.count == count)
    }

    @Test func lifecycleResumeDecisionComesFromDeterministicCore() async throws {
        let fixture = try CoordinatorFixture()
        let file = try fixture.createFile("episode-sleep.mkv")
        fixture.coordinator.open(url: file)
        try await waitForPreparation(fixture.coordinator)
        let load = try #require(fixture.runtime.loads.last)
        fixture.runtime.emit(.loaded, identity: load.identity)
        fixture.runtime.emit(.prerollReady, identity: load.identity)
        fixture.runtime.emit(.pauseChanged(false), identity: load.identity)
        fixture.runtime.emit(.positionChanged(12), identity: load.identity)

        fixture.coordinator.systemWillSleep()
        fixture.runtime.emit(.pauseChanged(true), identity: load.identity)
        #expect(fixture.coordinator.state.phase == .paused)

        let seeksBeforeRouteChange = fixture.runtime.seeks.count
        fixture.runtime.emit(.audioOutputChanged(13), identity: load.identity)
        #expect(fixture.runtime.seeks.count == seeksBeforeRouteChange)
        #expect(fixture.coordinator.state.phase == .paused)

        fixture.coordinator.systemDidWake()
        #expect(fixture.runtime.wakeRequests == [WakeRecord(position: 12, playing: true)])
        #expect(fixture.coordinator.state.phase == .playing)
    }

    @Test func pictureInPictureStateAndCommandsUseNativeRuntimeContract() async throws {
        let fixture = try CoordinatorFixture()
        let file = try fixture.createFile("episode-pip.mkv")

        fixture.coordinator.open(url: file)
        try await waitForPreparation(fixture.coordinator)
        let load = try #require(fixture.runtime.loads.last)
        fixture.runtime.emit(.loaded, identity: load.identity)
        fixture.runtime.emit(.prerollReady, identity: load.identity)
        fixture.runtime.emit(.pauseChanged(false), identity: load.identity)
        fixture.runtime.emit(
            .pictureInPictureChanged(.init(isPossible: true, isActive: false)),
            identity: nil
        )
        fixture.coordinator.setPictureInPictureActive(true)
        #expect(fixture.runtime.pictureInPictureRequests == [true])

        fixture.runtime.emit(
            .pictureInPictureChanged(.init(isPossible: true, isActive: true)),
            identity: load.identity
        )
        #expect(fixture.coordinator.state.pictureInPicture.isActive)

        fixture.runtime.emit(.transportRequested(playing: false), identity: load.identity)
        fixture.runtime.emit(.pauseChanged(true), identity: load.identity)
        #expect(fixture.coordinator.state.phase == .paused)
    }

    @Test func capabilitiesGateUnavailableNativeFeatures() async throws {
        let runtime = CoordinatorFakeBackend(capabilities: [.localFiles])
        let fixture = try CoordinatorFixture(runtime: runtime)
        let file = try fixture.createFile("no-pip.mkv")
        fixture.coordinator.open(url: file)
        try await waitForPreparation(fixture.coordinator)
        fixture.coordinator.setPictureInPictureActive(true)
        #expect(runtime.pictureInPictureRequests.isEmpty)
        #expect(fixture.coordinator.state.lastError?.contains("Picture in Picture") == true)
    }

    @Test func capabilityModelIsTheSharedOperationSourceOfTruth() {
        let capabilities: PlaybackCapabilities = [
            .localFiles,
            .relativeSeeking,
            .subtitleDelay,
            .pictureInPicture,
        ]
        let model = PlayerCapabilityModel(capabilities: capabilities)

        #expect(model.supports(.openLocalFiles))
        #expect(model.supports(.seekRelative))
        #expect(model.supports(.changeSubtitleDelay))
        #expect(model.supports(.pictureInPicture))
        #expect(!model.supports(.openRemoteStream))
        #expect(!model.supports(.changePlaybackSpeed))
        #expect(!model.supports(.stepFrame))
        #expect(!model.supports(.saveScreenshot))
    }

    @Test func unsupportedPersistedPlaybackSpeedIsSanitizedBeforePublication() throws {
        let runtime = CoordinatorFakeBackend(capabilities: [.localFiles])
        let suiteName = "SuperplayrTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let persistence = PlaybackPersistenceStore(
            userDefaults: defaults,
            namespace: "CapabilitySanitization"
        )
        persistence.setPlaybackSpeed(2)
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("SuperplayrCapabilityTests-\(UUID().uuidString)")
        let sessionStore = AtomicPlaybackSessionStore(
            fileURL: root.appendingPathComponent("session.json")
        )

        let coordinator = PlaybackCoordinator(
            persistence: persistence,
            sessionStore: sessionStore,
            runtime: runtime
        )

        #expect(coordinator.state.playbackSpeed == 1)
        #expect(coordinator.viewStore.playbackSpeed == 1)
        #expect(persistence.loadPreferences().playbackSpeed == 1)
    }

    @Test func productionDriverPreservesEffectIdentityAcrossHostileResults() throws {
        let runtime = CoordinatorFakeBackend()
        let driver = PlaybackRuntimeDriver(runtime: runtime)
        var transitions: [PlaybackTransition] = []
        driver.onTransition = { transitions.append($0) }
        let url = URL(fileURLWithPath: "/tmp/effect-seam.mkv")
        let media = try #require(MediaLoadRequest(source: .localFile(url), origin: .userSelected))
        let request = PlaybackRuntimeLoadRequest(
            media: media,
            identity: PlayerSessionIdentity(source: .localFile(url), generation: 1)
        )

        #expect(driver.load(request))
        let open = try #require(runtime.executedEffects.first)
        #expect(driver.currentSnapshot.phase == .opening)

        let mismatched = PlaybackEffectContext(
            authority: open.context.authority,
            operationID: PlaybackOperationID(rawValue: open.context.operationID.rawValue + 1),
            effectID: open.context.effectID
        )
        runtime.emitResult(context: mismatched, kind: .succeeded)
        guard case .stale = transitions.last?.disposition else {
            Issue.record("mismatched effect context was not rejected as stale")
            return
        }
        #expect(driver.currentSnapshot.phase == .opening)

        runtime.emitResult(context: open.context, kind: .cancelled)
        #expect(driver.currentSnapshot.phase == .failed)
        runtime.emitResult(context: open.context, kind: .cancelled)
        #expect(transitions.last?.disposition == .duplicate(effectID: open.context.effectID))

        let failedRuntime = CoordinatorFakeBackend()
        let failedDriver = PlaybackRuntimeDriver(runtime: failedRuntime)
        #expect(failedDriver.load(request))
        let failedOpen = try #require(failedRuntime.executedEffects.first)
        failedRuntime.emitResult(context: failedOpen.context, kind: .failed)
        #expect(failedDriver.currentSnapshot.phase == .failed)
    }

    @Test
    func invariantFailureStillPhysicallyShutsDownRuntime() async {
        let runtime = CoordinatorFakeBackend()
        let model = PlaybackModelRuntime(
            state: PlaybackCoreState(lifecycle: .invariantFailed),
            recordsReplaySteps: false
        )
        let driver = PlaybackRuntimeDriver(runtime: runtime, model: model)

        await driver.shutdown()

        #expect(runtime.shutdownCount == 1)
    }

    @Test func coreTrackAndSubtitleCommandsPublishOnlyAcknowledgedValues() async throws {
        let fixture = try CoordinatorFixture()
        let file = try fixture.createFile("tracks.mkv")
        fixture.coordinator.open(url: file)
        try await waitForPreparation(fixture.coordinator)
        let load = try #require(fixture.runtime.loads.last)
        fixture.runtime.emit(.loaded, identity: load.identity)
        fixture.runtime.emit(.tracksChanged(.init(
            hasVideo: true,
            tracks: [
                MediaTrack(id: 1, kind: .audio, title: "Main", isDefault: true),
                MediaTrack(id: 2, kind: .audio, title: "Commentary"),
                MediaTrack(id: 3, kind: .subtitle, title: "English"),
            ],
            selectedAudioID: 1,
            selectedSubtitleID: nil
        )), identity: load.identity)
        fixture.runtime.emit(.prerollReady, identity: load.identity)
        fixture.runtime.emit(.pauseChanged(false), identity: load.identity)

        fixture.coordinator.selectAudioTrack(fixture.coordinator.state.audioTracks[1])
        #expect(fixture.coordinator.state.selectedAudioTrack?.id == 2)
        fixture.runtime.emit(.pauseChanged(false), identity: load.identity)

        fixture.coordinator.selectSubtitleTrack(fixture.coordinator.state.subtitleTracks[0])
        #expect(fixture.coordinator.state.selectedSubtitleTrack?.id == 3)
        fixture.coordinator.setSubtitleDelay(0.25)
        #expect(fixture.coordinator.state.subtitleDelay == 0.25)
    }

    @Test func externalLanguageRestoreWaitsForTheInstalledSidecarCatalog() async throws {
        let fixture = try CoordinatorFixture()
        let video = try fixture.createFile("external-languages.mkv")
        let french = MediaTrack(id: Int64.max - 1, kind: .subtitle, title: "French", languageCode: "fr",
                               codec: "dvd_subtitle", isExternal: true, externalFilename: "captions.idx")
        fixture.persistence.setMediaSettings(.init(subtitleTrack: MediaTrackPreference(track: french)), for: video)
        fixture.coordinator.open(url: video)
        try await waitForPreparation(fixture.coordinator)
        let load = try #require(fixture.runtime.loads.last)
        fixture.runtime.emit(.loaded, identity: load.identity)
        fixture.runtime.emit(.tracksChanged(.init(hasVideo: true,
            tracks: [.init(id: 3, kind: .subtitle, title: "English", languageCode: "en")],
            selectedAudioID: nil, selectedSubtitleID: nil)), identity: load.identity)
        #expect(fixture.coordinator.state.selectedSubtitleTrack?.id != 3)
        fixture.runtime.emit(.tracksChanged(.init(hasVideo: true,
            tracks: [.init(id: Int64.max, kind: .subtitle, title: "English", languageCode: "en",
                           codec: "dvd_subtitle", isExternal: true, externalFilename: "captions.idx"), french],
            selectedAudioID: nil, selectedSubtitleID: Int64.max)), identity: load.identity)
        #expect(fixture.coordinator.state.selectedSubtitleTrack?.id == french.id)
    }

    @Test func perFileTrackSubtitleVisibilityAndDelayRestoreByMetadata() async throws {
        let fixture = try CoordinatorFixture()
        let first = try fixture.createFile("settings-01.mkv")
        let second = try fixture.createFile("settings-02.mkv")
        fixture.coordinator.open(url: first)
        try await waitForPreparation(fixture.coordinator)
        var load = try #require(fixture.runtime.loads.last)
        fixture.runtime.emit(.loaded, identity: load.identity)
        let tracks = PlayerTrackSnapshot(
            hasVideo: true,
            tracks: [
                MediaTrack(id: 1, kind: .audio, title: "Main", languageCode: "en"),
                MediaTrack(id: 2, kind: .audio, title: "Commentary", languageCode: "en"),
                MediaTrack(id: 3, kind: .subtitle, title: "English", languageCode: "en"),
            ],
            selectedAudioID: 1,
            selectedSubtitleID: nil
        )
        fixture.runtime.emit(.tracksChanged(tracks), identity: load.identity)
        fixture.coordinator.selectAudioTrack(fixture.coordinator.state.audioTracks[1])
        fixture.coordinator.selectSubtitleTrack(fixture.coordinator.state.subtitleTracks[0])
        fixture.coordinator.setSubtitleDelay(0.3)

        fixture.coordinator.open(url: second)
        try await waitForPreparation(fixture.coordinator)
        fixture.coordinator.open(url: first)
        try await waitForPreparation(fixture.coordinator)
        load = try #require(fixture.runtime.loads.last)
        fixture.runtime.emit(.loaded, identity: load.identity)
        fixture.runtime.emit(.tracksChanged(.init(
            hasVideo: true,
            tracks: [
                MediaTrack(id: 11, kind: .audio, title: "Main", languageCode: "en"),
                MediaTrack(id: 12, kind: .audio, title: "Commentary", languageCode: "en"),
                MediaTrack(id: 13, kind: .subtitle, title: "English", languageCode: "en"),
            ],
            selectedAudioID: 11,
            selectedSubtitleID: nil
        )), identity: load.identity)

        #expect(fixture.coordinator.state.selectedAudioTrack?.id == 12)
        #expect(fixture.coordinator.state.selectedSubtitleTrack?.id == 13)
        #expect(abs(fixture.coordinator.state.subtitleDelay - 0.3) < 0.001)
        #expect(fixture.persistence.mediaSettings(for: first)?.audioTrack?.title
            == "Commentary")

        fixture.coordinator.selectSubtitleTrack(nil)
        #expect(fixture.persistence.mediaSettings(for: first)?.areSubtitlesVisible == false)
    }
}

private struct SeekRecord: Equatable {
    let value: TimeInterval
    let mode: SuperplayrPlayback.SeekMode
}

private struct WakeRecord: Equatable {
    let position: TimeInterval
    let playing: Bool
}

@MainActor
private final class CoordinatorFixture {
    let persistence: PlaybackPersistenceStore
    let coordinator: PlaybackCoordinator
    let runtime: CoordinatorFakeBackend
    let sessionStore: any PlaybackSessionStoring
    let root: URL

    init(runtime: CoordinatorFakeBackend = CoordinatorFakeBackend(),
         sessionStore: (any PlaybackSessionStoring)? = nil) throws {
        self.runtime = runtime
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("SuperplayrCoordinatorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        persistence = PlaybackPersistenceStore(userDefaults: defaults, namespace: UUID().uuidString)
        self.sessionStore = sessionStore ?? AtomicPlaybackSessionStore(fileURL: root.appendingPathComponent("session.json"))
        coordinator = PlaybackCoordinator(
            persistence: persistence,
            sessionStore: self.sessionStore,
            runtime: runtime
        )
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func createDirectory(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func createFile(_ name: String, in directory: URL? = nil) throws -> URL {
        let url = (directory ?? root).appendingPathComponent(name)
        try Data().write(to: url)
        return url
    }
}

@MainActor
private final class CoordinatorFakeBackend: PlaybackRuntime {
    let capabilities: PlaybackCapabilities
    var eventHandler: (@MainActor @Sendable (PlaybackRuntimeEvent) -> Void)?
    var loads: [PlaybackRuntimeLoadRequest] = []
    var seeks: [SeekRecord] = []
    var pictureInPictureRequests: [Bool] = []
    var videoColorSamplingRequests: [Bool] = []
    var shutdownCount = 0
    var playCount = 0
    var wakeRequests: [WakeRecord] = []
    var externalSubtitleLoads: [URL] = []
    var audioOutputRequests: [String?] = []
    var executedEffects: [PlaybackEffect] = []
    private var pendingOpen: PlaybackEffect?
    private var pendingPreroll: PlaybackEffect?
    private var pendingRate: PlaybackEffect?
    private var pendingSeek: PlaybackEffect?
    private let synchronouslyCompletesRateChanges: Bool

    init(capabilities: PlaybackCapabilities = [
        .localFiles, .remoteStreams, .relativeSeeking, .exactSeeking, .previewSeeking,
        .playbackSpeed, .audioTracks, .subtitleTracks, .externalSubtitles, .audioDelay,
        .subtitleDelay, .frameStepping, .screenshots, .chapters, .audioDeviceSelection,
        .videoAdjustments, .videoFilters, .hardwareDecodingPolicy, .pictureInPicture,
    ], synchronouslyCompletesRateChanges: Bool = false) {
        self.capabilities = capabilities
        self.synchronouslyCompletesRateChanges = synchronouslyCompletesRateChanges
    }

    private var nextContentVersionObservation: MediaContentVersion??
    func observeVersionAtNextLoad(_ version: MediaContentVersion?) {
        nextContentVersionObservation = .some(version)
    }

    func emit(_ payload: PlaybackRuntimeEventPayload, identity: PlayerSessionIdentity?) {
        if case .loaded = payload {
            if let open = pendingOpen {
                pendingOpen = nil
                finish(open)
            }
            if let preroll = pendingPreroll {
                pendingPreroll = nil
                finish(preroll)
            }
            if let observation = nextContentVersionObservation {
                nextContentVersionObservation = nil
                eventHandler?(PlaybackRuntimeEvent(identity: identity, payload: .mediaVersionObserved(observation)))
            }
            eventHandler?(PlaybackRuntimeEvent(identity: identity, payload: payload))
            return
        }
        let effect: PlaybackEffect? = switch payload {
        case .loaded: nil
        case .prerollReady: pendingPreroll
        case .pauseChanged: pendingRate
        case .seekCompleted: pendingSeek
        default: nil
        }
        eventHandler?(PlaybackRuntimeEvent(identity: identity, payload: payload))
        if let effect {
            if pendingOpen?.context == effect.context { pendingOpen = nil }
            if pendingPreroll?.context == effect.context { pendingPreroll = nil }
            if pendingRate?.context == effect.context { pendingRate = nil }
            if pendingSeek?.context == effect.context { pendingSeek = nil }
            finish(effect)
        }
    }

    func makeSurfaceHost() throws -> any PlaybackSurfaceHost { CoordinatorFakeSurface() }
    func execute(_ request: PlaybackRuntimeEffectRequest) {
        let effect = request.effect
        executedEffects.append(effect)
        switch effect.kind {
        case .openSource:
            if let load = request.load { loads.append(load); pendingOpen = effect }
            else { finish(effect, succeeded: false) }
        case .probeSource, .configureSession:
            finish(effect)
        case .awaitPreroll:
            pendingPreroll = effect
        case let .applyRate(rate):
            if rate != 0 { playCount += 1 }
            if synchronouslyCompletesRateChanges {
                eventHandler?(PlaybackRuntimeEvent(
                    identity: loads.last?.identity,
                    payload: .pauseChanged(rate == 0)
                ))
                finish(effect)
            } else {
                pendingRate = effect
            }
        case let .seekPipeline(target, mode), let .seek(target, mode):
            guard case let .valid(time) = target else {
                finish(effect, succeeded: false)
                return
            }
            seeks.append(.init(
                value: Double(time.value) / Double(time.timescale),
                mode: mode == .relative ? .relative
                    : (mode == .exact ? .absoluteExact : .absolutePreview)
            ))
            pendingSeek = effect
        case .cancelSession:
            finish(effect)
        case .finalizeShutdown:
            shutdownCount += 1
            finish(effect)
        case let .resumeAfterWake(position, rate):
            if case let .valid(time) = position {
                wakeRequests.append(.init(
                    position: Double(time.value) / Double(time.timescale),
                    playing: rate != 0
                ))
                finish(effect)
            } else {
                finish(effect, succeeded: false)
            }
        case .applySubtitleSelection(.external(_), _):
            if let url = request.externalResourceURL {
                externalSubtitleLoads.append(url)
            }
            finish(effect)
        case .persistCheckpoint, .advancePlaylist, .mirrorDiagnostic,
             .cancelInputRead, .flushDecoder, .installPresentationFence,
             .clearSubtitleOverlay, .invalidateSubtitleSource, .releaseLease,
             .applyAudioSelection, .applySubtitleSelection, .applySubtitleDelay,
             .resumeVideoDecoderAfterTransientFailure,
             .recreateVideoDecoderInSoftware, .flushPresentationForRecovery,
             .rebuildPresentationGraph, .disableAudioTrack,
             .disableSubtitleTrack, .flushAudioPresentationForRecovery,
             .rebuildAudioPresentation, .correctAudioVideoDrift,
             .reconfigureMediaFormat:
            finish(effect)
        }
    }
    func load(_ request: PlaybackRuntimeLoadRequest) throws { loads.append(request) }
    func play() { playCount += 1 }
    func pause() {}
    func stop() {}
    func seek(to value: TimeInterval, mode: SuperplayrPlayback.SeekMode) {
        seeks.append(.init(value: value, mode: mode))
    }
    func setVolume(_ value: Double) {}
    func setMuted(_ value: Bool) {}
    func setPlaybackSpeed(_ value: Double) {}
    func selectAudioTrack(_ id: Int64?) {}
    func selectSubtitleTrack(_ id: Int64?) {}
    func selectAudioOutputDevice(_ id: String?) { audioOutputRequests.append(id) }
    func loadExternalSubtitle(_ url: URL, select: Bool) {}
    func setAudioDelay(_ value: TimeInterval) {}
    func setSubtitleDelay(_ value: TimeInterval) {}
    func setHardwareDecodingPolicy(_ policy: HardwareDecodingPolicy) {}
    func setVideoAspect(_ aspect: String?) {}
    func setVideoCrop(_ crop: String?) {}
    func setVideoRotation(_ rotation: Int) {}
    func setDeinterlace(_ enabled: Bool) {}
    func setVideoEqualizer(_ adjustments: VideoAdjustmentState) {}
    func setPictureInPictureActive(_ active: Bool) { pictureInPictureRequests.append(active) }
    func setVideoColorSamplingEnabled(_ enabled: Bool) {
        videoColorSamplingRequests.append(enabled)
    }
    func execute(_ command: SuperplayrCore.PlaybackCommand) async throws {}
    func resumeAfterWake(position: TimeInterval, playing: Bool) {
        wakeRequests.append(.init(position: position, playing: playing))
    }
    func shutdown() async { shutdownCount += 1 }

    private func finish(_ effect: PlaybackEffect, succeeded: Bool = true) {
        eventHandler?(PlaybackRuntimeEvent(
            identity: nil,
            payload: .effectResult(PlaybackEffectResult(
                context: effect.context,
                token: EffectResultToken(kind: succeeded ? .succeeded : .failed)
            ))
        ))
    }

    func emitResult(context: PlaybackEffectContext, kind: EffectResultKind) {
        eventHandler?(PlaybackRuntimeEvent(
            identity: nil,
            payload: .effectResult(PlaybackEffectResult(
                context: context,
                token: EffectResultToken(kind: kind),
                failure: kind == .succeeded ? nil : PlaybackFailure(
                    domain: .input,
                    stage: .callback,
                    stableCode: kind == .cancelled ? "faultInjectedCancellation" : "faultInjectedFailure",
                    recoverability: kind == .cancelled ? .cancelled : .fatal
                )
            ))
        ))
    }
}

@MainActor
private final class CoordinatorFakeSurface: PlaybackSurfaceHost {
    let view = NSView()
    var videoViewportSize: CGSize { view.bounds.size }
    var onOpenURLs: (([URL], PlaylistOpenMode) -> Void)?
    var onUserActivity: (() -> Void)?
    var onInteraction: ((PlaybackSurfaceInteraction) -> Void)?
    var contextMenuProvider: (() -> NSMenu?)?
    func updateDisplay(screen: NSScreen?) {}
    func setPlaybackPhase(_ phase: PlaybackPhase) {}
    func shutdown() {}
}
