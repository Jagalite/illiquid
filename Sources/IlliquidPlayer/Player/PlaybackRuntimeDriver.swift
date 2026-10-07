import Foundation
import OSLog
import IlliquidCore
import IlliquidPlayback
import IlliquidPlaybackCore

/// The sole serialized command/result path between the product coordinator and
/// the native mechanism adapter. Effect identity and command acceptance are
/// allocated by the deterministic core; the runtime only executes effects.
@MainActor
final class PlaybackRuntimeDriver {
    let runtime: any PlaybackRuntime
    var onRuntimeEvent: (@MainActor (PlaybackRuntimeEvent) -> Void)?
    var onTransition: (@MainActor (PlaybackTransition) -> Void)?
    var onPersistCheckpoint: (@MainActor () async -> Bool)?
    var onAdvancePlaylist: (@MainActor () -> Void)?

    // Replay documents are a diagnostic/test facility. Recording every live
    // event performs two canonical encodes and retains an ever-growing step
    // history, so keep it out of the production playback path.
    private var model: PlaybackModelRuntime
    private var pendingLoad: PlaybackRuntimeLoadRequest?
    private var sessionBeforePendingLoad: PlaybackSessionID?
    private var pendingExternalSubtitleURLs: [MediaSourceIdentity: URL] = [:]
    private var eventGate = PlaybackRuntimeEventGate()
    private var shutdownWaiters: [CheckedContinuation<Void, Never>] = []
    private var shutdownEffectFinished = false
    private var checkpointTasks: [PlaybackEffectID: Task<Void, Never>] = [:]
    private var pendingRelativeSeek: PlaybackEffect?
    private var relativeSeekDispatchTask: Task<Void, Never>?
    private var lastRelativeSeekDispatch: ContinuousClock.Instant?
    private var pendingRelativeSeekReceivedAt: ContinuousClock.Instant?
    private static let relativeSeekDispatchInterval: Duration = .milliseconds(40)

    var currentSnapshot: PlaybackUISnapshot { PlaybackUISnapshot(state: model.core.state) }

    init(
        runtime: any PlaybackRuntime,
        model: PlaybackModelRuntime = PlaybackModelRuntime(recordsReplaySteps: false)
    ) {
        self.runtime = runtime
        self.model = model
        runtime.eventHandler = { [weak self] event in self?.receive(event) }
    }

    @discardableResult
    func load(_ request: PlaybackRuntimeLoadRequest) -> Bool {
        pendingLoad = request
        sessionBeforePendingLoad = model.core.state.activeSession?.id
        return send(.load(
            source: sourceIdentity(request.media.source),
            autoplay: true
        ))
    }

    @discardableResult
    func setPlaybackSpeed(_ speed: Double) -> Bool {
        guard speed.isFinite, (0.25...4).contains(speed) else { return false }
        return send(.setPlaybackSpeed(milliRate: Int32((speed * 1_000).rounded())))
    }

    @discardableResult
    func setLoop(start: TimeInterval?, end: TimeInterval?) -> Bool {
        send(.setLoop(start: start.map(timestamp), end: end.map(timestamp)))
    }

    @discardableResult func play() -> Bool { send(.play) }
    @discardableResult func pause() -> Bool { send(.pause) }
    @discardableResult func stop() -> Bool { send(.stop) }

    @discardableResult
    func systemWillSleep() -> Bool {
        // Drain accepted user intent before suspending, so a dispatch timer
        // cannot initiate fresh native work after the sleep transition.
        if let pending = pendingRelativeSeek, isCurrentSeek(pending) {
            cancelPendingRelativeSeek()
            runtime.execute(PlaybackRuntimeEffectRequest(effect: pending))
        }
        return sendEvent(.lifecycle(.systemWillSleep))
    }

    @discardableResult
    func systemDidWake() -> Bool { sendEvent(.lifecycle(.systemDidWake)) }

    @discardableResult
    func seek(to seconds: TimeInterval, mode: IlliquidPlaybackCore.SeekMode) -> Bool {
        send(.seek(target: timestamp(seconds), mode: mode))
    }

    @discardableResult
    func selectAudioTrack(_ id: Int64?) -> Bool {
        let intent: AudioSelectionIntent = id.map {
            .stream(PlaybackTrackID(kind: .audio, mediaTrackID: $0))
        } ?? .automatic
        return send(.selectAudio(intent))
    }

    @discardableResult
    func selectSubtitleTrack(_ id: Int64?) -> Bool {
        let intent: SubtitleSelectionIntent = id.map {
            .embedded(PlaybackTrackID(kind: .subtitle, mediaTrackID: $0))
        } ?? .off
        return send(.selectSubtitle(intent))
    }

    @discardableResult
    func selectExternalSubtitle(_ url: URL) -> Bool {
        let source = MediaSourceIdentity(rawValue: "subtitle:\(url.absoluteURL.standardized.path)")
        pendingExternalSubtitleURLs[source] = url
        if send(.selectSubtitle(.external(source))) { return true }
        pendingExternalSubtitleURLs.removeValue(forKey: source)
        return false
    }

    @discardableResult
    func setSubtitleDelay(_ seconds: TimeInterval) -> Bool {
        guard seconds.isFinite else { return false }
        let scaled = seconds * 1_000_000
        guard let microseconds = Int64(exactly: scaled.rounded()) else { return false }
        return send(.setSubtitleDelay(microseconds: microseconds))
    }

    func shutdown() async {
        guard send(.shutdown) else {
            await runtime.shutdown()
            shutdownEffectFinished = true
            resumeShutdownWaitersIfFinished()
            return
        }
        if model.core.state.lifecycle == .terminated || shutdownEffectFinished { return }
        await withCheckedContinuation { continuation in
            shutdownWaiters.append(continuation)
        }
    }

    func receive(_ event: PlaybackRuntimeEvent) {
        guard acceptsForCore(event) else {
            onRuntimeEvent?(event)
            return
        }
        switch event.payload {
        case let .effectResult(result):
            let completedKind = model.pendingEffects.first(where: {
                $0.context.effectID == result.context.effectID
            })?.kind
            process(model.send(.effectResult(result)))
            settlePendingLoad(after: completedKind, result: result)
            if case .finalizeShutdown = completedKind { shutdownEffectFinished = true }
            resumeShutdownWaitersIfFinished()
        case .started, .loaded, .prerollReady, .seekCompleted, .pauseChanged:
            break
        case let .positionChanged(seconds):
            process(model.send(.acceptedClockSample(timestamp(seconds))))
        case let .audioOutputChanged(seconds):
            process(model.send(.audioOutputChanged(timestamp(seconds))))
        case let .durationChanged(seconds):
            process(model.send(.durationObserved(timestamp(seconds))))
        case .endOfFile:
            // Native emits EOF only after decoder drain and the presentation
            // horizon are complete, so this is one real aggregate drain fact.
            process(model.send(.demuxEndOfFile(requiredDrain: [])))
        case let .typedFailure(failure):
            process(model.send(.failureObserved(failure)))
        case let .failed(message):
            let failure = playbackFailure(code: stableCode(message))
            process(model.send(.failureObserved(failure)))
        case .shutdownCompleted:
            break
        case let .transportRequested(playing):
            _ = playing ? play() : pause()
        case let .relativeSeekRequested(interval):
            _ = seek(to: interval, mode: .relative)
        case .diagnostic:
            process(model.send(.diagnosticObserved(code: "native.runtime")))
        case let .bufferingChanged(status):
            let cache = UInt64(max(status.cacheDuration, 0) * 1_000_000)
            process(model.send(.synchronization(.supplyObserved(
                starved: status.isBuffering,
                cacheMicroseconds: cache
            ))))
        case let .synchronization(event):
            process(model.send(.synchronization(event)))
        case let .tracksChanged(snapshot):
            process(model.send(.catalogObserved(catalog(snapshot))))
        case .firstFrameSubmitted, .mediaVersionObserved,
             .decoderChanged, .videoChanged, .videoColorSampleChanged, .displayChanged,
             .volumeChanged, .muteChanged, .speedChanged, .audioDevicesChanged, .audioOutputSelectionFailed,
             .chaptersChanged, .audioDelayChanged, .subtitleDelayChanged,
             .videoAdjustmentsChanged, .pictureInPictureChanged, .stopped:
            break
        }
        onRuntimeEvent?(event)
    }

    private func acceptsForCore(_ event: PlaybackRuntimeEvent) -> Bool {
        eventGate.accepts(event)
    }

    private func settlePendingLoad(
        after completedKind: PlaybackEffectKind?,
        result: PlaybackEffectResult
    ) {
        guard let pendingLoad else { return }
        let pendingSource = sourceIdentity(pendingLoad.media.source)
        if model.core.state.activeSession?.source == pendingSource,
           model.core.state.activeSession?.id != sessionBeforePendingLoad,
           model.core.state.pendingSession == nil
        {
            eventGate.activate(pendingLoad.identity)
            self.pendingLoad = nil
            return
        }
        guard result.token.kind != .succeeded else { return }
        switch completedKind {
        case .openSource, .awaitPreroll:
            self.pendingLoad = nil
        default:
            break
        }
    }

    private(set) var commandRevision: UInt64 = 0

    @discardableResult
    private func send(_ command: IlliquidPlaybackCore.PlaybackCommand) -> Bool {
        commandRevision &+= 1
        return sendEvent(.command(command))
    }

    @discardableResult
    private func sendEvent(_ event: PlaybackEvent) -> Bool {
        let transition = model.send(event)
        process(transition)
        if case .accepted = transition.disposition { return true }
        return false
    }

    private func process(_ transition: PlaybackTransition) {
        if let pending = pendingRelativeSeek, !isCurrentSeek(pending) {
            cancelPendingRelativeSeek()
        }
        onTransition?(transition)
        for effect in transition.effects { execute(effect) }
    }

    private func execute(_ effect: PlaybackEffect) {
        switch effect.kind {
        case .seekPipeline:
            if model.core.state.activeSession?.seek?.mode == .relative {
                dispatchRelativeSeek(effect)
            } else {
                // A timeline release, recovery, or other absolute seek wins
                // immediately over a pending burst of relative skips.
                cancelPendingRelativeSeek()
                runtime.execute(PlaybackRuntimeEffectRequest(effect: effect))
            }
        case .openSource:
            guard let request = pendingLoad else {
                complete(effect.context.effectID, succeeded: false, code: "missingLoadRequest")
                return
            }
            runtime.execute(PlaybackRuntimeEffectRequest(effect: effect, load: request))
        case .applySubtitleSelection(.external(let source), _):
            let url = pendingExternalSubtitleURLs.removeValue(forKey: source)
            runtime.execute(PlaybackRuntimeEffectRequest(
                effect: effect,
                externalResourceURL: url
            ))
        case .persistCheckpoint:
            let id = effect.context.effectID
            checkpointTasks[id] = Task { [weak self] in
                guard let self else { return }
                let succeeded = await onPersistCheckpoint?() == true
                checkpointTasks.removeValue(forKey: id)
                complete(id, succeeded: succeeded, code: "checkpointPersistenceFailed")
            }
        case .advancePlaylist:
            onAdvancePlaylist?()
            complete(effect.context.effectID)
        case .mirrorDiagnostic:
            // Explicit synchronous allowlist: bounded local diagnostic mirror.
            complete(effect.context.effectID)
        case .probeSource, .configureSession, .awaitPreroll, .applyRate,
             .seek, .cancelSession, .cancelInputRead, .flushDecoder,
             .applyAudioSelection, .applySubtitleSelection, .applySubtitleDelay,
             .installPresentationFence, .clearSubtitleOverlay,
             .invalidateSubtitleSource, .releaseLease, .finalizeShutdown,
             .resumeVideoDecoderAfterTransientFailure,
             .recreateVideoDecoderInSoftware, .flushPresentationForRecovery,
             .rebuildPresentationGraph, .disableAudioTrack,
             .disableSubtitleTrack, .flushAudioPresentationForRecovery,
             .rebuildAudioPresentation, .correctAudioVideoDrift,
             .reconfigureMediaFormat, .resumeAfterWake:
            runtime.execute(PlaybackRuntimeEffectRequest(effect: effect))
        }
    }

    private func isCurrentSeek(_ effect: PlaybackEffect) -> Bool {
        effect.context.authority == model.core.state.activeSession?.authority &&
            model.core.state.outstandingEffects[effect.context.effectID] != nil
    }

    private func cancelPendingRelativeSeek() {
        relativeSeekDispatchTask?.cancel()
        relativeSeekDispatchTask = nil
        pendingRelativeSeek = nil
        pendingRelativeSeekReceivedAt = nil
    }

    private func dispatchRelativeSeek(_ effect: PlaybackEffect) {
        let now = ContinuousClock.now
        let deadline = lastRelativeSeekDispatch.map { $0 + Self.relativeSeekDispatchInterval }
        guard let deadline, now < deadline else {
            cancelPendingRelativeSeek()
            lastRelativeSeekDispatch = now
            runtime.execute(PlaybackRuntimeEffectRequest(effect: effect))
            return
        }
        pendingRelativeSeek = effect
        pendingRelativeSeekReceivedAt = now
        guard relativeSeekDispatchTask == nil else { return }
        relativeSeekDispatchTask = Task { [weak self] in
            do { try await ContinuousClock().sleep(until: deadline) }
            catch { return }
            guard let self, !Task.isCancelled else { return }
            relativeSeekDispatchTask = nil
            guard let pending = pendingRelativeSeek else { return }
            let receivedAt = pendingRelativeSeekReceivedAt
            pendingRelativeSeek = nil
            pendingRelativeSeekReceivedAt = nil
            guard isCurrentSeek(pending) else { return }
            lastRelativeSeekDispatch = .now
            if let receivedAt {
                let delay = receivedAt.duration(to: .now).components
                let ms = Double(delay.seconds) * 1_000 + Double(delay.attoseconds) / 1e15
                Logger(subsystem: "com.illiquid.seek", category: "dispatch")
                    .info("coalesced-skip-dispatch-delay-ms=\(ms)")
            }
            runtime.execute(PlaybackRuntimeEffectRequest(effect: pending))
        }
    }

    private func complete(
        _ effectID: PlaybackEffectID,
        succeeded: Bool = true,
        code: String? = nil
    ) {
        let token = EffectResultToken(kind: succeeded ? .succeeded : .failed)
        let failure = code.map(playbackFailure(code:))
        if let transition = model.complete(effectID: effectID, token: token, failure: failure) {
            process(transition)
        }
    }

    private func resumeShutdownWaitersIfFinished() {
        guard model.core.state.lifecycle == .terminated || shutdownEffectFinished else { return }
        let waiters = shutdownWaiters
        shutdownWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func playbackFailure(code: String) -> PlaybackFailure {
        PlaybackFailure(
            domain: .resource,
            stage: .callback,
            stableCode: code,
            recoverability: .fatal
        )
    }

    private func sourceIdentity(_ source: IlliquidCore.MediaSource) -> MediaSourceIdentity {
        switch source {
        case let .localFile(url): .init(rawValue: "local:\(url.absoluteURL.standardized.path)")
        case let .remoteStream(url): .init(rawValue: "remote:\(url.absoluteString)")
        }
    }

    private func timestamp(_ seconds: TimeInterval) -> MediaTimestamp {
        guard seconds.isFinite else { return .invalid(.nonFiniteSource) }
        let value = seconds * 1_000_000
        guard let integral = Int64(exactly: value.rounded()),
              let time = ValidMediaTime(value: integral, timescale: 1_000_000)
        else { return .invalid(.overflow) }
        return .valid(time)
    }

    private func stableCode(_ message: String) -> String {
        _ = message
        return "nativeRuntimeFailure"
    }

    private func catalog(_ snapshot: PlayerTrackSnapshot) -> PlaybackCatalog {
        PlaybackCatalog(
            hasVideo: snapshot.hasVideo,
            audio: snapshot.tracks.filter { $0.kind == .audio }.map {
                PlaybackTrackCandidate(
                    id: PlaybackTrackID(kind: .audio, mediaTrackID: $0.id),
                    isDefault: $0.isDefault,
                    isForced: $0.isForced
                )
            },
            subtitles: snapshot.tracks.filter { $0.kind == .subtitle }.map {
                PlaybackTrackCandidate(
                    id: PlaybackTrackID(kind: .subtitle, mediaTrackID: $0.id),
                    isDefault: $0.isDefault,
                    isForced: $0.isForced
                )
            }
        )
    }
}
