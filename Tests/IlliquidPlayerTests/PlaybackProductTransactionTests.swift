import AppKit
import Foundation
import IlliquidCore
import IlliquidNativePlayback
import IlliquidPlayback
import IlliquidPlaybackCore
import Testing
@testable import IlliquidPlayer

/// Real coordinator + real playback core + real JSON/UserDefaults stores. The
/// executor deliberately withholds native acknowledgements to expose ordering
/// windows; these are not claims of physical rendering or process-kill QA.
@MainActor
@Suite("Playback product transactions", .serialized)
struct PlaybackProductTransactionTests {
    @Test func loadingAndPendingSeekNeverReplaceTheLastSettledCheckpoint() async throws {
        let f = try ProductFixture()
        let a = try f.file("a.mkv"), b = try f.file("b.mkv")
        try f.sessions.save(.init(source: .localFile(a), position: 77, wasPaused: true))
        f.persistence.acceptMediaVersion(try f.version(b), for: b)
        f.persistence.setPlaybackPosition(31, for: b)
        f.player.open(url: b)
        try await eventually { f.runtime.loads.count == 1 }
        f.runtime.commitSource() // Native load committed, metadata not yet published.
        try await Task.sleep(for: .milliseconds(320))
        #expect(try f.sessions.load()?.source == .localFile(a))
        #expect(try f.sessions.load()?.position == 77)
        f.runtime.publishMetadata(version: try f.version(b))
        try await eventually { f.runtime.pendingSeeks.count == 1 }
        f.player.pause()
        try await Task.sleep(for: .milliseconds(320))
        #expect(f.persistence.playbackPosition(for: b) == 31)
        #expect(try f.sessions.load()?.source == .localFile(a))
        f.runtime.completeSeek()
        try await eventually { f.player.viewStore.phase == .paused }
        await f.player.shutdown()
        #expect(try f.sessions.load()?.source == .localFile(b))
        #expect(try f.sessions.load()?.position == 31)
    }

    @Test func audioThenSubtitlesThenResumeWaitForSeparateAcknowledgements() async throws {
        let f = try ProductFixture()
        let file = try f.file("tracks.mkv")
        f.persistence.acceptMediaVersion(try f.version(file), for: file)
        f.persistence.setPlaybackPosition(42, for: file)
        f.persistence.setMediaSettings(.init(audioTrack: .init(track: ProductRuntime.audio[1]),
            subtitleTrack: .init(track: ProductRuntime.subtitles[1]), subtitleDelay: 0.5), for: file)
        f.runtime.automaticallyAcknowledgesTracks = false
        f.player.open(url: file)
        try await eventually { f.runtime.loads.count == 1 }
        f.runtime.loadMetadata(version: try f.version(file), tracks: ProductRuntime.catalog)
        #expect(f.runtime.pendingTracks.count == 1)
        #expect(f.runtime.pendingSeeks.isEmpty)
        #expect(f.runtime.pendingTracks.first?.kind.isAudioSelection == true)
        f.runtime.completeTrack()
        try await eventually { f.runtime.pendingTracks.first?.kind.isSubtitleSelection == true }
        #expect(f.runtime.pendingSeeks.isEmpty)
        f.runtime.completeTrack()
        try await eventually { f.runtime.pendingSeeks.count == 1 }
        #expect(f.runtime.seekTargets.last == 42)
        f.runtime.completeSeek()
        try await eventually { f.player.viewStore.phase == .playing }
        #expect(f.player.viewStore.selectedAudioTrack?.id == 2)
        #expect(f.player.viewStore.selectedSubtitleTrack?.id == 4)
        #expect(f.player.viewStore.subtitleDelay == 0.5)
        await f.player.shutdown()
    }

    @Test func latestManualTrackChoicesSupersedeQueuedSavedChoices() async throws {
        let f = try ProductFixture()
        let file = try f.file("latest-track.mkv")
        f.persistence.setMediaSettings(.init(audioTrack: .init(track: ProductRuntime.audio[1]),
            subtitleTrack: .init(track: ProductRuntime.subtitles[1])), for: file)
        f.runtime.automaticallyAcknowledgesTracks = false
        f.player.open(url: file)
        try await eventually { f.runtime.loads.count == 1 }
        f.runtime.loadMetadata(version: try f.version(file), tracks: ProductRuntime.catalog)
        f.player.selectAudioTrack(ProductRuntime.audio[0])
        f.player.selectSubtitleTrack(nil)
        f.runtime.completeTrack() // Saved audio 2 finishes, then latest audio 1.
        try await eventually { !f.runtime.pendingTracks.isEmpty }
        f.runtime.completeTrack()
        try await eventually { f.runtime.pendingTracks.first?.kind.isSubtitleSelection == true }
        f.runtime.completeTrack()
        try await eventually { f.player.viewStore.phase == .playing }
        #expect(f.player.viewStore.selectedAudioTrack?.id == 1)
        #expect(f.player.viewStore.selectedSubtitleTrack == nil)
        #expect(f.persistence.mediaSettings(for: file)?.areSubtitlesVisible == false)
        await f.player.shutdown()
    }

    @Test(arguments: [false, true])
    func sparsePreferencesDoNotLeakBetweenFilesOrReenableHistory(history: Bool) async throws {
        let f = try ProductFixture()
        let a = try f.file("preferences-a.mkv"), b = try f.file("preferences-b.mkv")
        f.player.setRemembersPlaybackHistory(history)
        f.player.setDefaultPlaybackSpeed(1.25)
        try await f.open(a, tracks: ProductRuntime.catalog)
        f.player.setPlaybackSpeed(1.75)
        f.player.setAudioDelay(-0.35)
        #expect(f.player.defaultPlaybackSpeed == 1.25)
        #expect(f.player.mediaSettingsForCurrentFile.overriddenFields == [.playbackSpeed, .audioDelay])
        #expect(f.player.remembersPlaybackHistory == history)
        #expect((f.persistence.mediaSettings(for: a) != nil) == history)
        try await f.open(b, tracks: ProductRuntime.catalog)
        #expect(f.player.viewStore.playbackSpeed == 1.25)
        #expect(f.player.viewStore.audioDelay == 0)
        #expect(f.player.mediaSettingsForCurrentFile.isEmpty)
        try await f.open(a, tracks: ProductRuntime.catalog)
        #expect(f.player.viewStore.playbackSpeed == (history ? 1.75 : 1.25))
        #expect(f.player.viewStore.audioDelay == (history ? -0.35 : 0))
        f.player.resetCurrentMediaSettings()
        #expect(f.player.defaultPlaybackSpeed == 1.25)
        #expect(f.player.viewStore.playbackSpeed == 1.25)
        #expect(f.player.viewStore.audioDelay == 0)
        #expect(f.player.mediaSettingsForCurrentFile.isEmpty)
        #expect(f.player.remembersPlaybackHistory == history)
        await f.player.shutdown()
    }

    @Test func remoteTrackAndDelayCommandsRemainSessionLocal() async throws {
        let f = try ProductFixture()
        let remote = try #require(URL(string: "https://example.invalid/video.mkv"))
        f.player.openRemoteStream(url: remote)
        try await eventually { f.runtime.loads.count == 1 }
        f.runtime.loadMetadata(version: nil, tracks: ProductRuntime.catalog)
        f.player.selectAudioTrack(ProductRuntime.audio[1])
        f.player.selectSubtitleTrack(nil)
        f.player.setSubtitleDelay(0.5)
        f.player.setPlaybackSpeed(1.75)
        #expect(f.player.viewStore.selectedAudioTrack?.id == 2)
        #expect(f.player.viewStore.selectedSubtitleTrack == nil)
        #expect(f.player.viewStore.subtitleDelay == 0.5)
        #expect(f.player.viewStore.playbackSpeed == 1.75)
        #expect(f.player.defaultPlaybackSpeed == 1)
        #expect(f.persistence.mediaSettings(for: remote) == nil)
        await f.player.shutdown()
    }

    @Test func changedFileArchivesOldHistoryBeforeAnyNewCheckpoint() async throws {
        let f = try ProductFixture()
        let file = try f.file("changed.mkv")
        let previous = try f.version(file)
        f.persistence.acceptMediaVersion(previous, for: file)
        f.persistence.setPlaybackPosition(42, for: file)
        f.persistence.setMediaSettings(.init(playbackSpeed: 2, audioDelay: 0.4), for: file)
        try Data("replacement has different bytes".utf8).write(to: file)
        try await f.open(file)
        #expect(f.runtime.seekTargets.isEmpty)
        #expect(f.player.viewStore.playbackSpeed == 1)
        #expect(f.persistence.replacedMediaHistory(for: file).last?.position == 42)
        #expect(f.persistence.replacedMediaHistory(for: file).last?.version == previous)
        await f.player.shutdown()
    }

    @Test func interruptedSeekRecoversTheLastAcceptedClockNotTheOptimisticTarget() async throws {
        let f = try ProductFixture()
        let file = try f.file("interrupted.mkv")
        try await f.open(file)
        f.runtime.emit(.positionChanged(87))
        f.player.seek(to: 250)
        #expect(f.player.viewStore.position == 250)
        f.runtime.emit(.typedFailure(.init(domain: .input, stage: .callback,
            stableCode: "injectedDisconnectedDrive", recoverability: .fatal)))
        #expect(f.player.viewStore.recoveryIssue?.kind == .interruptedSource)
        f.player.retryRecovery()
        try await eventually { f.runtime.loads.count == 2 }
        f.runtime.loadMetadata(version: try f.version(file))
        try await eventually { f.runtime.seekTargets.last == 87 }
        f.runtime.completeSeek()
        await f.player.shutdown()
        #expect(try f.sessions.load()?.position == 87)
    }

    @Test func failedQueuedFileLocatePreservesItsOwnPositionAndRejectsStalePanels() async throws {
        let f = try ProductFixture()
        let a = try f.file("playing.mkv"), b = try f.file("missing.mkv")
        f.persistence.acceptMediaVersion(try f.version(b), for: b)
        f.persistence.setPlaybackPosition(41, for: b)
        try await f.open(a)
        f.runtime.emit(.positionChanged(70))
        f.player.open(url: b)
        try await eventually { f.runtime.loads.count == 2 }
        f.runtime.failOpen()
        let issue = try #require(f.player.viewStore.recoveryIssue)
        let moved = f.root.appendingPathComponent("located.mkv")
        try FileManager.default.moveItem(at: b, to: moved)
        f.player.locateUnavailableSession(at: moved, expectedIssueID: UUID())
        #expect(f.runtime.loads.count == 2)
        f.player.locateUnavailableSession(at: moved, expectedIssueID: issue.id)
        try await eventually { f.runtime.loads.count == 3 }
        f.runtime.loadMetadata(version: try f.version(moved))
        try await eventually { f.runtime.seekTargets.last == 41 }
        f.runtime.completeSeek()
        let count = f.runtime.loads.count
        f.player.locateUnavailableSession(at: a, expectedIssueID: issue.id)
        #expect(f.runtime.loads.count == count)
        await f.player.shutdown()
        #expect(try f.sessions.load()?.source == .localFile(moved))
        #expect(try f.sessions.load()?.position == 41)
    }

    @Test(arguments: [0.0, 0.25, 120.0], [false, true])
    func automationWaitsForExactSeekAndHonorsExplicitZeroAndTransport(position: Double, paused: Bool) async throws {
        let f = try ProductFixture()
        let file = try f.file("automation.mkv"), previous = try f.file("previous.mkv")
        try f.sessions.save(.init(source: .localFile(previous), position: 77, wasPaused: true))
        f.persistence.acceptMediaVersion(try f.version(file), for: file)
        f.persistence.setPlaybackPosition(55, for: file)
        var completed = false
        let action = Task { @MainActor in
            defer { completed = true }
            return try await f.player.openMedia(at: file, position: position, paused: paused)
        }
        try await eventually { f.runtime.loads.count == 1 }
        f.runtime.loadMetadata(version: try f.version(file))
        try await eventually { !f.runtime.pendingSeeks.isEmpty }
        #expect(f.runtime.seekTargets.last == position)
        #expect(!completed)
        #expect(throws: PlaybackAutomationError.noPlayback) { try f.player.currentPlaybackReference() }
        #expect(try f.sessions.load()?.source == .localFile(previous))
        f.runtime.completeSeek()
        let reference = try await action.value
        #expect(reference.url == file)
        #expect(reference.position == position)
        #expect(f.player.viewStore.isPauseDesired == paused)
        await f.player.shutdown()
        #expect(try f.sessions.load()?.position == position)
    }

    @Test func cancelledAutomationPreservesPreviousCheckpoint() async throws {
        let f = try ProductFixture()
        let file = try f.file("cancelled.mkv"), previous = try f.file("previous.mkv")
        try f.sessions.save(.init(source: .localFile(previous), position: 77, wasPaused: true))
        let action = Task { @MainActor in try await f.player.openMedia(at: file, position: 12, paused: true) }
        try await eventually { f.runtime.loads.count == 1 }
        f.runtime.loadMetadata(version: try f.version(file))
        try await eventually { !f.runtime.pendingSeeks.isEmpty }
        action.cancel()
        await #expect(throws: CancellationError.self) { try await action.value }
        await f.player.shutdown()
        #expect(try f.sessions.load()?.source == .localFile(previous))
        #expect(try f.sessions.load()?.position == 77)
    }

    @Test func supersededAutomationDoesNotStopTheNewManualSource() async throws {
        let f = try ProductFixture()
        let a = try f.file("automation-old.mkv"), b = try f.file("manual-new.mkv")
        let action = Task { @MainActor in try await f.player.openMedia(at: a, position: 12, paused: true) }
        try await eventually { f.runtime.loads.count == 1 }
        let stale = f.runtime.loads[0].identity
        try await f.open(b)
        await #expect(throws: PlaybackAutomationError.superseded) { try await action.value }
        f.runtime.emit(.loaded, identity: stale)
        f.runtime.emit(.positionChanged(99), identity: stale)
        #expect(f.player.viewStore.currentURL == b)
        #expect(f.player.viewStore.phase == .playing)
        #expect(f.player.viewStore.position != 99)
        await f.player.shutdown()
    }

    @Test func orderedEnqueueIsAllOrNothingAndDoesNotRestartPlayback() async throws {
        let f = try ProductFixture()
        let current = try f.file("current.mkv"), b = try f.file("b.mkv"), a = try f.file("a.mkv")
        try await f.open(current)
        f.runtime.emit(.positionChanged(19))
        let added = try await f.player.enqueueOrderedMedia([b, a, b])
        #expect(added == [b, a])
        #expect(f.player.viewStore.playlist.map(\.url) == [current, b, a])
        #expect(f.runtime.loads.count == 1)
        #expect(f.player.viewStore.position == 19)
        let missing = f.root.appendingPathComponent("unavailable.mkv")
        await #expect(throws: PlaybackAutomationError.invalidFile) {
            try await f.player.enqueueOrderedMedia([a, missing])
        }
        #expect(f.player.viewStore.playlist.map(\.url) == [current, b, a])
        #expect(f.runtime.loads.count == 1)
        await f.player.shutdown()
    }

    @Test func changedPlaybackReferenceFailsBeforeReplacingCurrentMedia() async throws {
        let f = try ProductFixture()
        let current = try f.file("current.mkv"), referenced = try f.file("referenced.mkv")
        let reference = try PlaybackReference(url: referenced, position: 12, contentVersion: f.version(referenced))
        try Data("changed".utf8).write(to: referenced)
        try await f.open(current)
        await #expect(throws: PlaybackAutomationError.changedFile) { try await f.player.openPlaybackReference(reference) }
        #expect(f.runtime.loads.count == 1)
        #expect(f.player.viewStore.currentURL == current)
        await f.player.shutdown()
    }

    @Test func timedOutSeekNeverReturnsAnOptimisticReference() async throws {
        let f = try ProductFixture(automationTimeout: 0.1)
        let file = try f.file("timeout.mkv"), previous = try f.file("previous.mkv")
        try f.sessions.save(.init(source: .localFile(previous), position: 77, wasPaused: true))
        let action = Task { @MainActor in try await f.player.openMedia(at: file, position: 90) }
        try await eventually { f.runtime.loads.count == 1 }
        f.runtime.loadMetadata(version: try f.version(file))
        await #expect(throws: PlaybackAutomationError.timedOut) { try await action.value }
        await f.player.shutdown()
        #expect(try f.sessions.load()?.source == .localFile(previous))
        #expect(try f.sessions.load()?.position == 77)
    }

    @Test func captionJumpRejectsAnIndexFromAnEarlierSource() async throws {
        let f = try ProductFixture()
        let a = try f.file("caption-a.mkv"), b = try f.file("caption-b.mkv")
        try await f.open(a, tracks: ProductRuntime.catalog)
        let request = try #require(f.player.captionSourceRequest)
        let cue = try #require(CaptionCue(id: 0, start: 7, end: 9, text: "Hello"))
        let index = CaptionIndex(cues: [cue])
        f.player.setSubtitleDelay(0.5)
        #expect(f.player.jumpToCaption(0, in: index, source: request))
        #expect(f.runtime.seekTargets.last == 6.5)
        f.runtime.completeSeek()
        try await f.open(b, tracks: ProductRuntime.catalog)
        let count = f.runtime.seekTargets.count
        #expect(!f.player.jumpToCaption(0, in: index, source: request))
        #expect(f.runtime.seekTargets.count == count)
        await f.player.shutdown()
    }

    @Test func cancellingAQueuedActionDoesNotReleaseItsSuccessorEarly() async throws {
        let queue = PlaybackAutomationQueue()
        let gate = ProductGate()
        var order: [Int] = []
        let first = Task { @MainActor in
            try await queue.perform { order.append(1); await gate.wait(); order.append(2) }
        }
        try await eventually { order == [1] }
        let cancelled = Task { @MainActor in try await queue.perform { order.append(99) } }
        await Task.yield()
        let third = Task { @MainActor in try await queue.perform { order.append(3) } }
        cancelled.cancel()
        try await Task.sleep(for: .milliseconds(20))
        #expect(order == [1])
        gate.release()
        try await first.value
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        try await third.value
        #expect(order == [1, 2, 3])
    }
}

@MainActor
private final class ProductGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
}

@MainActor
private func eventually(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !condition() {
        guard ContinuousClock.now < deadline else { throw ProductTimeout() }
        try await Task.sleep(for: .milliseconds(2))
    }
}
private struct ProductTimeout: Error {}

@MainActor
private final class ProductFixture {
    let root: URL
    let persistence: PlaybackPersistenceStore
    let sessions: AtomicPlaybackSessionStore
    let runtime = ProductRuntime()
    let player: PlaybackCoordinator
    private let defaults: UserDefaults
    private let domain = "IlliquidProductTest-\(UUID().uuidString)"

    init(automationTimeout: TimeInterval = 2) throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defaults = try #require(UserDefaults(suiteName: domain))
        persistence = PlaybackPersistenceStore(userDefaults: defaults, namespace: "Product")
        sessions = AtomicPlaybackSessionStore(fileURL: root.appendingPathComponent("session.json"))
        player = PlaybackCoordinator(persistence: persistence, sessionStore: sessions, runtime: runtime,
            thumbnailCacheDirectory: root.appendingPathComponent("thumbnails"), automationTimeout: automationTimeout)
    }

    deinit { try? FileManager.default.removeItem(at: root); UserDefaults.standard.removePersistentDomain(forName: domain) }

    func file(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data("fixture for coordinator testing, not encoded media".utf8).write(to: url)
        return url
    }
    func version(_ url: URL) throws -> MediaContentVersion {
        try #require(NativeMediaInspection.contentVersion(of: url))
    }
    func open(_ url: URL, tracks: [MediaTrack] = []) async throws {
        let count = runtime.loads.count
        player.open(url: url)
        try await eventually { self.runtime.loads.count == count + 1 }
        runtime.loadMetadata(version: try version(url), tracks: tracks)
        if !runtime.pendingSeeks.isEmpty { runtime.completeSeek() }
        try await eventually { self.player.viewStore.phase == .playing }
    }
}

/// A controllable executor, not a second playback policy. Every completion
/// echoes the unchanged effect context through the real driver/core.
@MainActor
private final class ProductRuntime: PlaybackRuntime {
    static let audio = [MediaTrack(id: 1, kind: .audio, languageCode: "en", isDefault: true),
                        MediaTrack(id: 2, kind: .audio, languageCode: "ja")]
    static let subtitles = [MediaTrack(id: 3, kind: .subtitle, languageCode: "en", isDefault: true),
                            MediaTrack(id: 4, kind: .subtitle, languageCode: "ja")]
    static var catalog: [MediaTrack] { audio + subtitles }
    let capabilities: PlaybackCapabilities = [.localFiles, .remoteStreams, .relativeSeeking, .exactSeeking, .previewSeeking,
        .playbackSpeed, .audioTracks, .subtitleTracks, .externalSubtitles, .audioDelay, .subtitleDelay, .pictureInPicture]
    var eventHandler: (@MainActor @Sendable (PlaybackRuntimeEvent) -> Void)?
    var loads: [PlaybackRuntimeLoadRequest] = []
    var pendingOpen: PlaybackEffect?
    var pendingPreroll: PlaybackEffect?
    var pendingSeeks: [PlaybackEffect] = []
    var pendingTracks: [PlaybackEffect] = []
    var seekTargets: [Double] = []
    var automaticallyAcknowledgesTracks = true

    func execute(_ request: PlaybackRuntimeEffectRequest) {
        let effect = request.effect
        switch effect.kind {
        case .openSource:
            guard let load = request.load else { finish(effect, succeeded: false); return }
            loads.append(load)
            pendingOpen = effect
            pendingSeeks.removeAll()
            pendingTracks.removeAll()
        case .awaitPreroll: pendingPreroll = effect
        case let .seekPipeline(target, _), let .seek(target, _):
            guard case let .valid(time) = target else { finish(effect, succeeded: false); return }
            seekTargets.append(Double(time.value) / Double(time.timescale))
            pendingSeeks.append(effect)
        case .applyAudioSelection, .applySubtitleSelection:
            if automaticallyAcknowledgesTracks { finish(effect) }
            else { pendingTracks.append(effect) }
        case let .applyRate(rate):
            emit(.pauseChanged(rate == 0))
            finish(effect)
        default: finish(effect)
        }
    }

    func commitSource() {
        if let effect = pendingOpen { pendingOpen = nil; finish(effect) }
        if let effect = pendingPreroll { pendingPreroll = nil; finish(effect) }
    }
    func publishMetadata(version: MediaContentVersion?, tracks: [MediaTrack] = []) {
        emit(.mediaVersionObserved(version))
        emit(.tracksChanged(.init(hasVideo: true, tracks: tracks,
            selectedAudioID: tracks.first(where: { $0.kind == .audio })?.id,
            selectedSubtitleID: tracks.first(where: { $0.kind == .subtitle })?.id)))
        emit(.audioDelayChanged(0))
        emit(.loaded)
        emit(.durationChanged(300))
    }
    func loadMetadata(version: MediaContentVersion?, tracks: [MediaTrack] = []) {
        commitSource()
        publishMetadata(version: version, tracks: tracks)
    }
    func completeSeek() {
        guard !pendingSeeks.isEmpty else { return }
        let effect = pendingSeeks.removeLast()
        pendingSeeks.removeAll()
        emit(.seekCompleted)
        finish(effect)
    }
    func completeTrack() {
        guard !pendingTracks.isEmpty else { return }
        finish(pendingTracks.removeFirst())
    }
    func failOpen() {
        guard let effect = pendingOpen else { return }
        pendingOpen = nil
        finish(effect, succeeded: false)
    }
    func emit(_ payload: PlaybackRuntimeEventPayload, identity: PlayerSessionIdentity? = nil) {
        eventHandler?(.init(identity: identity ?? loads.last?.identity, payload: payload))
    }
    private func finish(_ effect: PlaybackEffect, succeeded: Bool = true) {
        eventHandler?(.init(identity: nil, payload: .effectResult(.init(context: effect.context,
            token: .init(kind: succeeded ? .succeeded : .failed),
            failure: succeeded ? nil : .init(domain: .input, stage: .callback,
                stableCode: "injectedProductFailure", recoverability: .fatal)))))
    }
    func makeSurfaceHost() throws -> any PlaybackSurfaceHost { throw UnsupportedPlaybackCapabilityError("test has no surface") }
    func setVolume(_ value: Double) {}
    func setMuted(_ value: Bool) {}
    func setPlaybackSpeed(_ value: Double) { emit(.speedChanged(value)) }
    func selectAudioOutputDevice(_ id: String?) {}
    func setAudioDelay(_ value: TimeInterval) { emit(.audioDelayChanged(value)) }
    func setHardwareDecodingPolicy(_ policy: HardwareDecodingPolicy) {}
    func setVideoAspect(_ aspect: String?) {}
    func setVideoCrop(_ crop: String?) {}
    func setVideoRotation(_ rotation: Int) {}
    func setDeinterlace(_ enabled: Bool) {}
    func setVideoEqualizer(_ adjustments: VideoAdjustmentState) {}
    func setPictureInPictureActive(_ active: Bool) {}
    func execute(_ command: IlliquidCore.PlaybackCommand) async throws {}
    func shutdown() async {}
}

private extension PlaybackEffectKind {
    var isAudioSelection: Bool { if case .applyAudioSelection = self { true } else { false } }
    var isSubtitleSelection: Bool { if case .applySubtitleSelection = self { true } else { false } }
}

/// Exercises the product coordinator against the actual FFmpeg/Apple runtime.
/// The hosted window provides renderer-buffer evidence, not physical scanout.
@MainActor
@Suite("Playback product native integration", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["ILLIQUID_PRODUCT_FIXTURES"] != nil))
struct PlaybackProductNativeTests {
    @Test(.timeLimit(.minutes(1)))
    func nativeOpenReferenceRapidScrubAndWakeRetainTheLatestPausedFrame() async throws {
        try await withNativePlayer { player, runtime, root in
            let file = root.appendingPathComponent("first.mp4")
            let reference = try await player.openMedia(at: file, position: 2, paused: true)
            #expect(reference.url == file)
            #expect(abs(reference.position - 2) < 0.04)
            let started = ContinuousClock.now
            for position in [6.0, 0.3, 5.0, 1.7, 6.7, 0.8, 3.2] {
                player.previewSeek(to: position)
            }
            player.seek(to: 4.5)
            try await nativeEventually {
                let shown = runtime.pausedReadbackDiagnostic()
                // Renderer publication can precede the core's seek acknowledgement.
                // Require both observations before asking for a settled reference.
                return shown.isCurrent && shown.displayedPTS.map { abs($0 - 4.5) < 0.04 } == true
                    && (try? player.currentPlaybackReference()).map { abs($0.position - 4.5) < 0.04 } == true
            }
            let shown = runtime.pausedReadbackDiagnostic()
            #expect(player.viewStore.isPauseDesired)
            #expect(shown.rendererRate == 0)
            #expect(abs(try player.currentPlaybackReference().position - 4.5) < 0.04)
            print("[product-native] rapid-scrub displayed-pts=\(shown.displayedPTS ?? -1) duration=\(started.duration(to: .now))")
            // Drive the real lifecycle commands without sleeping the CI machine.
            player.systemWillSleep()
            player.systemDidWake()
            try await nativeEventually {
                let shown = runtime.pausedReadbackDiagnostic()
                return shown.isCurrent && shown.displayedPTS.map { abs($0 - 4.5) < 0.04 } == true
                    && (try? player.currentPlaybackReference()).map { abs($0.position - 4.5) < 0.04 } == true
            }
            #expect(player.viewStore.isPauseDesired)
            #expect(abs(try player.currentPlaybackReference().position - 4.5) < 0.04)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func nativeFileOverridesCaptionsAndExternalSnapshotSurviveReopening() async throws {
        try await withNativePlayer { player, runtime, root in
            let input = root.appendingPathComponent("first.mp4")
            let file = root.appendingPathComponent("tracks.mkv")
            let subtitle = root.appendingPathComponent("captions.srt")
            // Distinct actual stream slots exercise restoration through the
            // native decoder adapter; identical source samples are not a claim
            // of listening-based language qualification.
            let fixture = Process()
            fixture.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            fixture.arguments = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
                "-i", input.path, "-i", subtitle.path,
                "-map", "0:v:0", "-map", "0:a:0", "-map", "0:a:0", "-map", "1:s:0", "-map", "1:s:0",
                "-c", "copy", "-c:s", "srt", "-metadata:s:a:0", "language=eng",
                "-metadata:s:a:1", "language=jpn", "-metadata:s:s:0", "language=eng",
                "-metadata:s:s:1", "language=jpn", file.path]
            try fixture.run()
            fixture.waitUntilExit()
            try #require(fixture.terminationStatus == 0)
            _ = try await player.openMedia(at: file, position: 1, paused: true)
            let audio = try #require(player.viewStore.audioTracks.last)
            let captions = try #require(player.viewStore.subtitleTracks.last)
            player.selectAudioTrack(audio)
            player.selectSubtitleTrack(captions)
            player.setSubtitleDelay(0.5)
            try await nativeEventually {
                player.viewStore.selectedAudioTrack?.id == audio.id
                    && player.viewStore.selectedSubtitleTrack?.id == captions.id
                    && player.viewStore.subtitleDelay == 0.5 && !runtime.hasPendingMediaReplacement
                    && (try? player.currentPlaybackReference()) != nil
            }
            let source = try #require(player.captionSourceRequest)
            let index = try await player.readCaptions(for: source)
            #expect(index.search("世界").count == 1)
            #expect(player.jumpToCaption(0, in: index, source: source))
            try await nativeEventually { (try? player.currentPlaybackReference()) != nil }
            #expect(abs(player.viewStore.position - 0.5) < 0.04)
            player.setPlaybackSpeed(1.5)
            player.setAudioDelay(0.2)
            try await nativeEventually {
                abs(player.viewStore.audioDelay - 0.2) < 0.0001 && !runtime.hasPendingMediaReplacement
            }
            _ = try await player.openMedia(at: root.appendingPathComponent("other.mp4"), position: 0, paused: true)
            #expect(player.viewStore.playbackSpeed == 1)
            #expect(player.viewStore.audioDelay == 0)
            _ = try await player.openMedia(at: file, position: 1, paused: true)
            #expect(player.viewStore.selectedAudioTrack?.id == audio.id)
            #expect(player.viewStore.selectedSubtitleTrack?.id == captions.id)
            #expect(player.viewStore.playbackSpeed == 1.5)
            #expect(abs(player.viewStore.audioDelay - 0.2) < 0.0001)
            #expect(player.viewStore.subtitleDelay == 0.5)
            player.loadExternalSubtitle(subtitle)
            try await nativeEventually {
                player.captionSourceRequest?.subtitleTrack.isExternal == true && !runtime.hasPendingMediaReplacement
            }
            let externalSource = try #require(player.captionSourceRequest)
            let before = try await player.readCaptions(for: externalSource)
            try "1\n00:00:01,000 --> 00:00:03,000\nChanged on disk.\n".write(to: subtitle, atomically: true, encoding: .utf8)
            let after = try await player.readCaptions(for: externalSource)
            #expect(before == after) // Search indexes the bytes being played.
            player.selectSubtitleTrack(nil)
            try await nativeEventually { player.viewStore.selectedSubtitleTrack == nil && !runtime.hasPendingMediaReplacement }
            player.loadExternalSubtitle(subtitle)
            try await nativeEventually {
                player.captionSourceRequest?.subtitleTrack.isExternal == true && !runtime.hasPendingMediaReplacement
            }
            let reloadedSource = try #require(player.captionSourceRequest)
            let reloadedIndex = try await player.readCaptions(for: reloadedSource)
            #expect(reloadedIndex.search("Changed on disk").count == 1)
            #expect(reloadedSource != externalSource)
            #expect(!player.jumpToCaption(0, in: before, source: externalSource))
            #expect(!player.replayPreviousCaption(in: before, source: externalSource, sentence: false))
            await #expect(throws: PlaybackAutomationError.superseded) { try await player.readCaptions(for: externalSource) }
            #expect(player.jumpToCaption(0, in: reloadedIndex, source: reloadedSource))
            try await nativeEventually { (try? player.currentPlaybackReference()) != nil }
            // An ordinary seek keeps the index usable.
            #expect(player.captionSourceRequest == reloadedSource)
            player.selectSubtitleTrack(nil)
            try await nativeEventually { player.viewStore.selectedSubtitleTrack == nil && !runtime.hasPendingMediaReplacement }
            #expect(!player.jumpToCaption(0, in: before, source: externalSource))
            _ = try await player.openMedia(at: root.appendingPathComponent("other.mp4"), position: 0, paused: true)
            _ = try await player.openMedia(at: file, position: 1, paused: true)
            #expect(player.viewStore.selectedSubtitleTrack == nil)
            player.resetCurrentMediaSettings()
            try await nativeEventually {
                player.viewStore.audioDelay == 0 && !runtime.hasPendingMediaReplacement
                    && (try? player.currentPlaybackReference()) != nil
            }
            #expect(player.viewStore.playbackSpeed == 1)
            #expect(player.viewStore.subtitleDelay == 0)
            #expect(player.mediaSettingsForCurrentFile.isEmpty)
        }
    }

    private func withNativePlayer(_ body: @MainActor (PlaybackCoordinator, NativePlaybackRuntime, URL) async throws -> Void) async throws {
        let fixtures = try #require(ProcessInfo.processInfo.environment["ILLIQUID_PRODUCT_FIXTURES"])
        let directory = URL(fileURLWithPath: fixtures)
        let domain = "IlliquidNativeProduct-\(UUID().uuidString)"
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(domain)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain); try? FileManager.default.removeItem(at: root) }
        for name in ["first.mp4", "other.mp4"] {
            try FileManager.default.copyItem(at: directory.appendingPathComponent("h264-aac.mp4"), to: root.appendingPathComponent(name))
        }
        try FileManager.default.copyItem(at: directory.appendingPathComponent("captions.srt"), to: root.appendingPathComponent("captions.srt"))
        let persistence = PlaybackPersistenceStore(userDefaults: defaults, namespace: "NativeProduct")
        var preferences = PlaybackPreferences.standard
        preferences.volume = 0
        preferences.isMuted = true
        persistence.savePreferences(preferences)
        let runtime = try NativePlaybackRuntime()
        let player = PlaybackCoordinator(persistence: persistence,
            sessionStore: AtomicPlaybackSessionStore(fileURL: root.appendingPathComponent("session.json")),
            runtime: runtime, thumbnailCacheDirectory: root.appendingPathComponent("thumbnails"), automationTimeout: 15)
        _ = NSApplication.shared
        let host = try player.makeVideoSurfaceHost()
        let window = NSWindow(contentRect: CGRect(x: 80, y: 80, width: 480, height: 300),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host.view
        host.view.frame = CGRect(x: 0, y: 0, width: 480, height: 300)
        host.view.layoutSubtreeIfNeeded()
        window.orderFrontRegardless()
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        do { try await body(player, runtime, root) }
        catch { await player.shutdown(); throw error }
        await player.shutdown()
        #expect(player.shutdownPersistenceError == nil)
    }

    private func nativeEventually(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw ProductTimeout() }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
