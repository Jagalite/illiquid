import AVFoundation
import CoreMedia
import Foundation
import SuperplayrCore

struct VideoPresentationRecoveryResult: @unchecked Sendable {
    let fence: PresentationFence
    let oldDisplayLayer: AVSampleBufferDisplayLayer
    let newDisplayLayer: AVSampleBufferDisplayLayer
    let rebuiltGraph: Bool
}

struct PresentationFence: RawRepresentable, Equatable, Hashable, Comparable, Sendable {
    let rawValue: UInt64

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

enum PresentationFlushComponent: String, Hashable, Sendable {
    case audio
    case video
}

enum PresentationFlushAcknowledgmentDisposition: Equatable, Sendable {
    case accepted
    case duplicate
    case stale
    case droppedAfterTermination
}

struct PresentationFlushSnapshot: Equatable, Sendable {
    let fence: PresentationFence
    let acknowledged: Set<PresentationFlushComponent>
}

struct RendererPresentationMetricsSnapshot: Equatable, Sendable {
    let fence: PresentationFence
    let videoSubmissionAttempts: Int
    let videoEnqueueReturnedWithoutImmediateFailure: Int
    let audioSubmissionAttempts: Int
    let audioEnqueueReturnedWithoutImmediateFailure: Int
    let firstVideoRendererClockEvidenceSeconds: Double?
    let firstAudioRendererClockEvidenceSeconds: Double?
    let rendererMediaTimeSeconds: Double
    let rendererRate: Float
    let rendererClockEpochBaselineSeconds: Double
    let rendererClockMaximumSeconds: Double
    let firstRendererClockAdvanceSeconds: Double?
    let flushRequested: Bool
    let flushCompleted: Bool
    let rendererDrainEvidence: Bool

    // AVSampleBufferVideoRenderer does not expose equivalent per-frame
    // presented/late/dropped completion evidence. Nil means unmeasured, not 0.
    let firstVisibleFrameSeconds: Double? = nil
    let lateVideoFrames: Int? = nil
    let droppedVideoFrames: Int? = nil
}

struct RendererClockAdvanceLedger: Equatable, Sendable {
    private(set) var baselineSeconds: Double
    private(set) var maximumSeconds: Double
    private(set) var firstAdvanceUptimeSeconds: Double?

    init(baselineSeconds: Double) {
        let baseline = baselineSeconds.isFinite ? baselineSeconds : 0
        self.baselineSeconds = baseline
        maximumSeconds = baseline
    }

    mutating func observe(mediaTimeSeconds: Double, uptimeSeconds: Double) {
        guard mediaTimeSeconds.isFinite, uptimeSeconds.isFinite else { return }
        maximumSeconds = max(maximumSeconds, mediaTimeSeconds)
        if firstAdvanceUptimeSeconds == nil,
           mediaTimeSeconds > baselineSeconds + 0.001
        {
            firstAdvanceUptimeSeconds = uptimeSeconds
        }
    }
}

enum RendererMembershipAction: Equatable, Sendable {
    case none
    case add
    case remove(PresentationFence)
}

struct RendererMembershipSnapshot: Equatable, Sendable {
    let attached: Bool
    let desired: Bool
    let pendingRemoval: PresentationFence?
}

/// Serial state machine for AVSampleBufferRenderSynchronizer membership.
/// Removal is asynchronous. A newer request to re-add while removal is in
/// flight is remembered and fulfilled only after the matching callback, so a
/// renderer is never concurrently removed and added under different files.
struct RendererMembershipLedger: Sendable {
    private(set) var attached: Bool
    private(set) var desired: Bool
    private(set) var pendingRemoval: PresentationFence?

    init(attached: Bool) {
        self.attached = attached
        desired = attached
    }

    mutating func request(_ desired: Bool, fence: PresentationFence) -> RendererMembershipAction {
        self.desired = desired
        guard pendingRemoval == nil else { return .none }
        if desired, !attached {
            attached = true
            return .add
        }
        if !desired, attached {
            pendingRemoval = fence
            return .remove(fence)
        }
        return .none
    }

    mutating func observeRemoval(fence: PresentationFence) -> RendererMembershipAction {
        guard pendingRemoval == fence else { return .none }
        pendingRemoval = nil
        attached = false
        if desired {
            attached = true
            return .add
        }
        return .none
    }

    var snapshot: RendererMembershipSnapshot {
        RendererMembershipSnapshot(
            attached: attached,
            desired: desired,
            pendingRemoval: pendingRemoval
        )
    }
}

/// Tracks asynchronous renderer acknowledgments independently from the commit
/// sequencer so a synchronous or hostile duplicate callback can never deadlock
/// the presentation queue.
final class PresentationFlushAcknowledgmentLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var currentFence = PresentationFence(rawValue: 0)
    private var acknowledgments: [PresentationFence: Set<PresentationFlushComponent>] = [:]
    private var terminated = false

    func install(_ fence: PresentationFence) {
        lock.withLock {
            currentFence = fence
            acknowledgments[fence] = []
            acknowledgments = acknowledgments.filter { $0.key >= fence }
        }
    }

    func observe(
        fence: PresentationFence,
        component: PresentationFlushComponent
    ) -> PresentationFlushAcknowledgmentDisposition {
        lock.withLock {
            guard !terminated else { return .droppedAfterTermination }
            guard fence == currentFence else { return .stale }
            var observed = acknowledgments[fence, default: []]
            guard observed.insert(component).inserted else { return .duplicate }
            acknowledgments[fence] = observed
            return .accepted
        }
    }

    func terminate() {
        lock.withLock { terminated = true }
    }

    func snapshot() -> PresentationFlushSnapshot {
        lock.withLock {
            PresentationFlushSnapshot(
                fence: currentFence,
                acknowledged: acknowledgments[currentFence, default: []]
            )
        }
    }
}

final class NativePresentationCoordinator: @unchecked Sendable {
    let synchronizer = AVSampleBufferRenderSynchronizer()
    private(set) var video = SampleBufferVideoPresenter()
    private(set) var audio: SampleBufferAudioPresenter

    private let commitQueue = DispatchQueue(
        label: "com.superplayr.native.presentation-executor",
        qos: .userInteractive
    )
    private let flushAcknowledgments = PresentationFlushAcknowledgmentLedger()
    private var installedFence = PresentationFence(rawValue: 0)
    private var rendererObservation = DifferentialRendererObservationJournal(epoch: 0)
    private var videoSubmissionAttempts = 0
    private var videoEnqueueReturnedWithoutImmediateFailure = 0
    private var audioSubmissionAttempts = 0
    private var audioEnqueueReturnedWithoutImmediateFailure = 0
    private var rendererClockAdvance = RendererClockAdvanceLedger(baselineSeconds: 0)
    private var terminated = false
    private var videoMembership = RendererMembershipLedger(attached: true)
    private var audioMembership = RendererMembershipLedger(attached: true)
    private var pictureInPictureFrameSink: (
        @Sendable (NativeDecodedVideoFrame) -> Void
    )?
    private var pictureInPictureFrameInvalidationSink: (@Sendable () -> Void)?
    private var pictureInPictureRenderer: AVSampleBufferVideoRenderer?
    private var pictureInPictureRemovalInFlight = false
    private let videoColorSampler = VideoFrameColorSampler()
    private var isVideoColorSamplingEnabled = false
    private var videoColorSampleHandler: (
        @Sendable (VideoColorSample) -> Void
    )?
    private var presentationTimeObserver: Any?
    private var presentationTimeObservationInterval = CMTime(value: 1, timescale: 30)
    private var presentationTimeObservationRevision: UInt64 = 0
    private var presentationTimeHandler: (@Sendable (CMTime) -> Void)?
    private var audioOutputObservers: [NSObjectProtocol] = []
    let audioOutputCapacity = NativeAudioOutputCapacity()
    private var audioOutputChangeHandler: (@Sendable (PresentationFence, CMTime) -> Void)?

    init() throws {
        audio = try SampleBufferAudioPresenter(
            sampleRate: AudioDecoder.outputSampleRate,
            channelCount: AudioDecoder.outputChannelCount
        )
        synchronizer.addRenderer(video.renderer)
        synchronizer.addRenderer(audio.renderer)
        synchronizer.delaysRateChangeUntilHasSufficientMediaData = true
        observeAudioOutputChanges()
    }

    var currentTime: CMTime { commitQueue.sync { synchronizer.currentTime() } }
    var rate: Float { commitQueue.sync { synchronizer.rate } }
    var currentFence: PresentationFence { commitQueue.sync { installedFence } }
    var audioOutputDeviceID: String? { commitQueue.sync { audio.renderer.audioOutputDeviceUniqueID } }

    func setAudioOutputDevice(_ id: String?) throws {
        try commitQueue.sync {
            guard !terminated, audio.renderer.audioOutputDeviceUniqueID != id else { return }
            let position = synchronizer.currentTime()
            try audio.setOutputDevice(id)
            // Device assignment can change the synchronizer's clock. Refill
            // through the same core transaction used by platform route events.
            audioOutputChangeHandler?(installedFence, position)
        }
    }

    func setAudioOutputChangeHandler(
        _ handler: (@Sendable (PresentationFence, CMTime) -> Void)?
    ) {
        commitQueue.sync { audioOutputChangeHandler = handler }
    }

    /// Called on the commit queue, or during construction before publication.
    private func observeAudioOutputChanges() {
        let center = NotificationCenter.default
        for observer in audioOutputObservers { center.removeObserver(observer) }
        audioOutputObservers.removeAll()
        let owner = audio
        for name in [
            NSNotification.Name.AVSampleBufferAudioRendererWasFlushedAutomatically,
            NSNotification.Name.AVSampleBufferAudioRendererOutputConfigurationDidChange,
        ] {
            audioOutputObservers.append(center.addObserver(
                forName: name, object: owner.renderer, queue: nil
            ) { [weak self, weak owner] _ in
                guard let self, let owner else { return }
                self.commitQueue.async { [weak self, weak owner] in
                    guard let self, let owner, !self.terminated,
                          self.audio === owner else { return }
                    self.audioOutputChangeHandler?(self.installedFence, self.synchronizer.currentTime())
                }
            })
        }
    }

    deinit {
        for observer in audioOutputObservers { NotificationCenter.default.removeObserver(observer) }
        if let presentationTimeObserver { synchronizer.removeTimeObserver(presentationTimeObserver) }
    }

    func setVideoColorSampleHandler(
        _ handler: (@Sendable (VideoColorSample) -> Void)?
    ) {
        commitQueue.sync {
            videoColorSampleHandler = handler
        }
    }

    func setPresentationTimeHandler(
        _ handler: (@Sendable (CMTime) -> Void)?
    ) {
        commitQueue.sync {
            guard !terminated else { return }
            presentationTimeHandler = handler
            replacePresentationTimeObserver()
        }
    }

    func setPresentationTimeObservationInterval(_ interval: CMTime) {
        guard interval.isNumeric, interval.seconds > 0 else { return }
        commitQueue.sync {
            guard !terminated, interval != presentationTimeObservationInterval else { return }
            presentationTimeObservationInterval = interval
            replacePresentationTimeObserver()
        }
    }

    /// Media-time callbacks stop repeating while paused, but still report jumps
    /// and start/stop. The revision rejects callbacks already queued by a retired
    /// observer. All add/remove/delivery operations use the presentation queue.
    private func replacePresentationTimeObserver() {
        presentationTimeObservationRevision &+= 1
        if let presentationTimeObserver { synchronizer.removeTimeObserver(presentationTimeObserver) }
        presentationTimeObserver = nil
        guard presentationTimeHandler != nil else { return }
        let revision = presentationTimeObservationRevision
        presentationTimeObserver = synchronizer.addPeriodicTimeObserver(
            forInterval: presentationTimeObservationInterval, queue: commitQueue
        ) { [weak self] time in
            guard let self, !self.terminated,
                  self.presentationTimeObservationRevision == revision else { return }
            self.presentationTimeHandler?(time)
        }
    }

    func setVideoColorSamplingEnabled(_ enabled: Bool) {
        commitQueue.sync {
            guard !terminated, isVideoColorSamplingEnabled != enabled else {
                return
            }
            isVideoColorSamplingEnabled = enabled
            videoColorSampler.reset()
        }
    }

    @discardableResult
    func setRate(
        _ rate: Float,
        at time: CMTime = .invalid,
        fence: PresentationFence? = nil
    ) -> Bool {
        commitQueue.sync {
            guard !terminated, fence.map({ $0 == installedFence }) ?? true else { return false }
            synchronizer.setRate(rate, time: time)
            return true
        }
    }

    @discardableResult
    func pause(fence: PresentationFence? = nil) -> Bool {
        commitQueue.sync {
            guard !terminated, fence.map({ $0 == installedFence }) ?? true else { return false }
            synchronizer.rate = 0
            return true
        }
    }

    /// Installs the identity fence before requesting either renderer flush.
    /// This is a control-priority path and never waits for renderer readiness
    /// or for the asynchronous video completion callback.
    @discardableResult
    func installFenceAndRequestFlush(
        at time: CMTime,
        removeDisplayedImage: Bool = true,
        videoFlushCompletion: (@Sendable (PresentationFence) -> Void)? = nil
    ) -> PresentationFence {
        commitQueue.sync {
            guard !terminated else { return installedFence }
            precondition(installedFence.rawValue < UInt64.max, "presentation fence exhausted")
            installedFence = PresentationFence(rawValue: installedFence.rawValue + 1)
            let fence = installedFence
            beginRendererObservationEpoch(fence, baselineTime: time)
            flushAcknowledgments.install(fence)
            synchronizer.rate = 0
            videoColorSampler.reset()
            audio.flush()
            _ = flushAcknowledgments.observe(fence: fence, component: .audio)
            video.flush(removeDisplayedImage: removeDisplayedImage) {
                [flushAcknowledgments] in
                _ = flushAcknowledgments.observe(fence: fence, component: .video)
                videoFlushCompletion?(fence)
            }
            pictureInPictureFrameInvalidationSink?()
            pictureInPictureRenderer?.flush(
                removingDisplayedImage: removeDisplayedImage
            )
            synchronizer.setRate(0, time: time)
            return fence
        }
    }

    @discardableResult
    func flush(at time: CMTime, removeDisplayedImage: Bool = true) -> PresentationFence {
        installFenceAndRequestFlush(
            at: time,
            removeDisplayedImage: removeDisplayedImage
        )
    }

    @discardableResult
    func stop(
        videoFlushCompletion: (@Sendable (PresentationFence) -> Void)? = nil
    ) -> PresentationFence {
        installFenceAndRequestFlush(
            at: .zero,
            videoFlushCompletion: videoFlushCompletion
        )
    }

    func enqueueVideo(
        _ frame: NativeDecodedVideoFrame,
        fence: PresentationFence,
        displayImmediately: Bool = false
    ) throws -> Bool {
        let result: (
            accepted: Bool,
            sink: (@Sendable (NativeDecodedVideoFrame) -> Void)?
        ) = try commitQueue.sync {
            guard !terminated, fence == installedFence else {
                return (false, nil)
            }
            let sink = pictureInPictureFrameSink
            try enqueueMainVideo(
                frame,
                displayImmediately: displayImmediately,
                fence: fence
            )
            return (true, sink)
        }
        guard result.accepted else { return false }
        result.sink?(frame)
        return true
    }

    private func enqueueMainVideo(
        _ frame: NativeDecodedVideoFrame,
        displayImmediately: Bool,
        fence: PresentationFence
    ) throws {
        videoSubmissionAttempts += 1
        try video.enqueue(frame, displayImmediately: displayImmediately)
        videoEnqueueReturnedWithoutImmediateFailure += 1
        if isVideoColorSamplingEnabled,
           let videoColorSampleHandler,
           let sample = videoColorSampler.sampleIfNeeded(frame.pixelBuffer)
        {
            videoColorSampleHandler(sample)
        }
        if let interval = DifferentialMediaInterval(
            start: frame.presentationTime.seconds,
            end: frame.presentationTime.seconds + frame.duration.seconds
        ) {
            rendererObservation.recordEnqueued(
                kind: .video,
                interval: interval,
                epoch: Int(fence.rawValue)
            )
        }
    }

    func setPictureInPictureFrameSink(
        _ sink: (@Sendable (NativeDecodedVideoFrame) -> Void)?,
        onInvalidation: (@Sendable () -> Void)? = nil
    ) {
        commitQueue.sync {
            pictureInPictureFrameSink = sink
            pictureInPictureFrameInvalidationSink = onInvalidation
        }
    }

    func attachPictureInPictureRenderer(
        _ renderer: AVSampleBufferVideoRenderer
    ) -> Bool {
        commitQueue.sync {
            guard !terminated,
                  pictureInPictureRenderer == nil,
                  !pictureInPictureRemovalInFlight
            else {
                return false
            }
            synchronizer.addRenderer(renderer)
            pictureInPictureRenderer = renderer
            return true
        }
    }

    func detachPictureInPictureRenderer(
        _ renderer: AVSampleBufferVideoRenderer
    ) {
        let rendererIdentity = ObjectIdentifier(renderer)
        commitQueue.async { [weak self] in
            guard let self,
                  let attachedRenderer = self.pictureInPictureRenderer,
                  ObjectIdentifier(attachedRenderer) == rendererIdentity,
                  !self.pictureInPictureRemovalInFlight
            else {
                return
            }
            self.pictureInPictureRemovalInFlight = true
            self.pictureInPictureRenderer = nil
            self.synchronizer.removeRenderer(attachedRenderer, at: .zero) { [weak self] _ in
                self?.commitQueue.async { [weak self] in
                    self?.pictureInPictureRemovalInFlight = false
                }
            }
        }
    }

    func enqueueAudio(
        _ frame: NativeDecodedAudioFrame,
        fence: PresentationFence
    ) throws -> Bool {
        try commitQueue.sync {
            guard !terminated, fence == installedFence else { return false }
            audioSubmissionAttempts += 1
            try audio.enqueue(frame)
            audioEnqueueReturnedWithoutImmediateFailure += 1
            if let interval = DifferentialMediaInterval(
                start: frame.presentationTime.seconds,
                end: frame.presentationTime.seconds + frame.duration.seconds
            ) {
                rendererObservation.recordEnqueued(
                    kind: .audio,
                    interval: interval,
                    epoch: Int(fence.rawValue)
                )
            }
            return true
        }
    }

    @discardableResult
    func configureMembership(hasVideo: Bool, hasAudio: Bool) -> PresentationFence {
        commitQueue.sync {
            guard !terminated else { return installedFence }
            precondition(installedFence.rawValue < UInt64.max, "presentation fence exhausted")
            installedFence = PresentationFence(rawValue: installedFence.rawValue + 1)
            let fence = installedFence
            beginRendererObservationEpoch(fence, baselineTime: .zero)
            flushAcknowledgments.install(fence)
            synchronizer.rate = 0
            audio.flush()
            video.flush(removeDisplayedImage: true) { [flushAcknowledgments] in
                _ = flushAcknowledgments.observe(fence: fence, component: .video)
            }
            pictureInPictureFrameInvalidationSink?()
            pictureInPictureRenderer?.flush(removingDisplayedImage: true)
            _ = flushAcknowledgments.observe(fence: fence, component: .audio)
            applyVideoMembership(videoMembership.request(hasVideo, fence: fence))
            applyAudioMembership(audioMembership.request(hasAudio, fence: fence))
            synchronizer.setRate(0, time: .zero)
            return fence
        }
    }

    private func applyVideoMembership(_ action: RendererMembershipAction) {
        switch action {
        case .none:
            break
        case .add:
            synchronizer.addRenderer(video.renderer)
        case .remove(let fence):
            synchronizer.removeRenderer(video.renderer, at: .zero) { [weak self] _ in
                self?.commitQueue.async { [weak self] in
                    guard let self, !self.terminated else { return }
                    self.applyVideoMembership(self.videoMembership.observeRemoval(fence: fence))
                }
            }
        }
    }

    private func applyAudioMembership(_ action: RendererMembershipAction) {
        switch action {
        case .none:
            break
        case .add:
            synchronizer.addRenderer(audio.renderer)
        case .remove(let fence):
            synchronizer.removeRenderer(audio.renderer, at: .zero) { [weak self] _ in
                self?.commitQueue.async { [weak self] in
                    guard let self, !self.terminated else { return }
                    self.applyAudioMembership(self.audioMembership.observeRemoval(fence: fence))
                }
            }
        }
    }

    func disableAudio() {
        commitQueue.sync {
            guard !terminated else { return }
            audio.stopRequestingMediaData()
            audio.flush()
            applyAudioMembership(audioMembership.request(false, fence: installedFence))
        }
    }

    func setVolume(_ volume: Float, muted: Bool) {
        commitQueue.sync {
            guard !terminated else { return }
            audio.volume = min(max(volume, 0), 1)
            audio.isMuted = muted
        }
    }

    func recoverVideoPresentation(rebuildGraph: Bool) -> VideoPresentationRecoveryResult {
        if !rebuildGraph {
            let layer = commitQueue.sync { video.displayLayer }
            let fence = installFenceAndRequestFlush(at: currentTime)
            return VideoPresentationRecoveryResult(
                fence: fence,
                oldDisplayLayer: layer,
                newDisplayLayer: layer,
                rebuiltGraph: false
            )
        }
        return commitQueue.sync {
            let old = video
            precondition(installedFence.rawValue < UInt64.max, "presentation fence exhausted")
            installedFence = PresentationFence(rawValue: installedFence.rawValue + 1)
            let fence = installedFence
            beginRendererObservationEpoch(fence, baselineTime: .zero)
            flushAcknowledgments.install(fence)
            synchronizer.rate = 0
            audio.flush()
            _ = flushAcknowledgments.observe(fence: fence, component: .audio)
            old.flush(removeDisplayedImage: true) { [flushAcknowledgments] in
                _ = flushAcknowledgments.observe(fence: fence, component: .video)
            }
            pictureInPictureFrameInvalidationSink?()
            pictureInPictureRenderer?.flush(removingDisplayedImage: true)
            synchronizer.removeRenderer(old.renderer, at: .zero) { _ in }

            let replacement = SampleBufferVideoPresenter()
            let wantsVideo = videoMembership.snapshot.desired
            if wantsVideo { synchronizer.addRenderer(replacement.renderer) }
            videoMembership = RendererMembershipLedger(attached: wantsVideo)
            video = replacement
            synchronizer.setRate(0, time: .zero)
            return VideoPresentationRecoveryResult(
                fence: fence,
                oldDisplayLayer: old.displayLayer,
                newDisplayLayer: replacement.displayLayer,
                rebuiltGraph: true
            )
        }
    }

    func recoverAudioPresentation(rebuildGraph: Bool) throws -> PresentationFence {
        guard rebuildGraph else {
            return installFenceAndRequestFlush(
                at: currentTime,
                removeDisplayedImage: false
            )
        }
        let replacement = try SampleBufferAudioPresenter(
            sampleRate: AudioDecoder.outputSampleRate,
            channelCount: AudioDecoder.outputChannelCount
        )
        return try commitQueue.sync {
            let old = audio
            let baseline = synchronizer.currentTime()
            replacement.volume = old.volume
            replacement.isMuted = old.isMuted
            try replacement.setOutputDevice(old.renderer.audioOutputDeviceUniqueID)
            precondition(installedFence.rawValue < UInt64.max, "presentation fence exhausted")
            installedFence = PresentationFence(rawValue: installedFence.rawValue + 1)
            let fence = installedFence
            beginRendererObservationEpoch(fence, baselineTime: baseline)
            flushAcknowledgments.install(fence)
            synchronizer.rate = 0
            old.stopRequestingMediaData()
            old.flush()
            _ = flushAcknowledgments.observe(fence: fence, component: .audio)
            video.flush(removeDisplayedImage: false) { [flushAcknowledgments] in
                _ = flushAcknowledgments.observe(fence: fence, component: .video)
            }
            synchronizer.removeRenderer(old.renderer, at: .zero) { _ in }
            let wantsAudio = audioMembership.snapshot.desired
            if wantsAudio { synchronizer.addRenderer(replacement.renderer) }
            audioMembership = RendererMembershipLedger(attached: wantsAudio)
            audio = replacement
            observeAudioOutputChanges()
            synchronizer.setRate(0, time: baseline.isNumeric ? baseline : .zero)
            return fence
        }
    }

    func terminate() {
        commitQueue.sync {
            guard !terminated else { return }
            terminated = true
            for observer in audioOutputObservers { NotificationCenter.default.removeObserver(observer) }
            audioOutputObservers.removeAll()
            audioOutputChangeHandler = nil
            presentationTimeHandler = nil
            presentationTimeObservationRevision &+= 1
            if let presentationTimeObserver { synchronizer.removeTimeObserver(presentationTimeObserver) }
            presentationTimeObserver = nil
            synchronizer.rate = 0
            audio.flush()
            video.flush(removeDisplayedImage: true)
            if let pictureInPictureRenderer {
                synchronizer.removeRenderer(pictureInPictureRenderer, at: .zero)
                self.pictureInPictureRenderer = nil
            }
            pictureInPictureFrameSink = nil
            pictureInPictureFrameInvalidationSink = nil
        }
        flushAcknowledgments.terminate()
    }

    func membershipSnapshotForTesting() -> (
        video: RendererMembershipSnapshot,
        audio: RendererMembershipSnapshot
    ) {
        commitQueue.sync { (videoMembership.snapshot, audioMembership.snapshot) }
    }

    func flushSnapshotForTesting() -> PresentationFlushSnapshot {
        flushAcknowledgments.snapshot()
    }

    func flushCompleted(_ fence: PresentationFence) -> Bool {
        let snapshot = flushAcknowledgments.snapshot()
        return snapshot.fence == fence
            && snapshot.acknowledged.isSuperset(of: [.audio, .video])
    }

    func differentialRendererObservation(demuxEOF: Bool) -> DifferentialRendererObservationJournal {
        commitQueue.sync {
            let epoch = Int(installedFence.rawValue)
            if demuxEOF { rendererObservation.markDemuxEOF(epoch: epoch) }
            rendererObservation.observeRendererClock(
                mediaTime: synchronizer.currentTime().seconds,
                monotonicSeconds: ProcessInfo.processInfo.systemUptime,
                epoch: epoch
            )
            return rendererObservation
        }
    }

    func rendererPresentationMetrics(
        demuxEOF: Bool
    ) -> RendererPresentationMetricsSnapshot {
        commitQueue.sync {
            let epoch = Int(installedFence.rawValue)
            let rendererTime = synchronizer.currentTime().seconds
            rendererClockAdvance.observe(
                mediaTimeSeconds: rendererTime,
                uptimeSeconds: ProcessInfo.processInfo.systemUptime
            )
            if demuxEOF { rendererObservation.markDemuxEOF(epoch: epoch) }
            rendererObservation.observeRendererClock(
                mediaTime: rendererTime,
                monotonicSeconds: ProcessInfo.processInfo.systemUptime,
                epoch: epoch
            )
            let flush = flushAcknowledgments.snapshot()
            return RendererPresentationMetricsSnapshot(
                fence: installedFence,
                videoSubmissionAttempts: videoSubmissionAttempts,
                videoEnqueueReturnedWithoutImmediateFailure:
                    videoEnqueueReturnedWithoutImmediateFailure,
                audioSubmissionAttempts: audioSubmissionAttempts,
                audioEnqueueReturnedWithoutImmediateFailure:
                    audioEnqueueReturnedWithoutImmediateFailure,
                firstVideoRendererClockEvidenceSeconds: Self.readinessTime(
                    rendererObservation.readiness(for: .video)
                ),
                firstAudioRendererClockEvidenceSeconds: Self.readinessTime(
                    rendererObservation.readiness(for: .audio)
                ),
                rendererMediaTimeSeconds: rendererTime,
                rendererRate: synchronizer.rate,
                rendererClockEpochBaselineSeconds: rendererClockAdvance.baselineSeconds,
                rendererClockMaximumSeconds: rendererClockAdvance.maximumSeconds,
                firstRendererClockAdvanceSeconds: rendererClockAdvance
                    .firstAdvanceUptimeSeconds,
                flushRequested: installedFence.rawValue > 0,
                flushCompleted: flush.fence == installedFence
                    && flush.acknowledged.isSuperset(of: [.audio, .video]),
                rendererDrainEvidence: rendererObservation.isRendererDrained
            )
        }
    }

    private func beginRendererObservationEpoch(
        _ fence: PresentationFence,
        baselineTime: CMTime
    ) {
        rendererObservation = DifferentialRendererObservationJournal(epoch: Int(fence.rawValue))
        videoSubmissionAttempts = 0
        videoEnqueueReturnedWithoutImmediateFailure = 0
        audioSubmissionAttempts = 0
        audioEnqueueReturnedWithoutImmediateFailure = 0
        rendererClockAdvance = RendererClockAdvanceLedger(
            baselineSeconds: baselineTime.seconds
        )
    }

    private static func readinessTime(_ readiness: DifferentialReadiness) -> Double? {
        guard case let .measured(monotonicSeconds, _) = readiness else { return nil }
        return monotonicSeconds
    }

    @discardableResult
    func observeFlushAcknowledgmentForTesting(
        fence: PresentationFence,
        component: PresentationFlushComponent
    ) -> PresentationFlushAcknowledgmentDisposition {
        flushAcknowledgments.observe(fence: fence, component: component)
    }
}
