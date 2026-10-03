import AppKit
import CoreMedia
import Foundation
import SuperplayrCore
import SuperplayrPlaybackCore
import SuperplayrPlayback

public enum NativePlaybackRuntimeError: LocalizedError {
    case localFilesOnly
    case backendShutDown
    case surfaceUnavailable

    public var errorDescription: String? {
        switch self {
        case .localFilesOnly: "Native Apple playback currently supports local files only."
        case .backendShutDown: "The native playback backend has already shut down."
        case .surfaceUnavailable: "The native sample-buffer surface could not be created."
        }
    }
}

/// The product selects bounded planar output with BGRA fallback. Explicit BGRA
/// remains available to compatibility callers and qualification harnesses.
public enum NativeSoftwareVideoOutputPolicy: String, Sendable {
    case bgra
    case planarPreferred
    case planarExperimental
}

public struct NativePlaybackLifecycleTransition: Codable, Equatable, Sendable {
    public let stage: String
    public let uptimeSeconds: Double
}

/// Read-only, generation-scoped evidence for lifecycle qualification. Renderer
/// submission and renderer-clock advancement remain separate facts.
public struct NativePlaybackDiagnosticSnapshot: Codable, Equatable, Sendable {
    public let sessionID: UInt64
    public let sourcePath: String?
    public let lifecycleStage: String
    public let lifecycleStageUptimeSeconds: Double
    public let hasInstalledMediaSession: Bool
    public let lifecycleTransitions: [NativePlaybackLifecycleTransition]
    public let mediaGeneration: Int
    public let presentationFence: UInt64
    public let rendererMediaTimeSeconds: Double
    public let rendererRate: Float
    public let rendererClockEpochBaselineSeconds: Double
    public let rendererClockMaximumSeconds: Double
    public let firstRendererClockAdvanceSeconds: Double?
    public let videoPTS: Double
    public let audioPTS: Double
    public let audioOutputChannels: Int?
    public let audioOutputSampleRate: Int?
    public let audioDownmixOccurred: Bool?
    public let usesDeinterlacingFilter: Bool
    public let deinterlacingFailure: String?
    public let videoSubmissionAttempts: Int
    public let videoEnqueueReturnedWithoutImmediateFailure: Int
    public let flushCompleted: Bool
    public let rendererReady: Bool
    public let isPrerolled: Bool
    public let rendererFailure: String?
    public let failureDomain: String?
    public let failureStage: String?
    public let failureCode: String?
    public let failureNativeCode: Int64?
    public let ffmpegPixelFormat: String
    public let pixelBufferFormat: String
    public let softwarePoolAllocatedBuffers: Int
    public let softwarePoolThresholdWaits: Int
    public let softwarePoolTimeouts: Int
    public let softwareBGRAFallbackFrames: Int
    public let discardedStaleFrames: Int
    public let rendererStarvations: Int
    public let peakVideoFrameQueueDepth: Int
    public let videoPipelineCapacity: Int
    public let videoPipelineCapacityInUse: Int
    public let peakVideoPipelineCapacityInUse: Int
    public let videoPipelineCapacityWaiters: Int
    public let demuxDeferredPacketDepth: Int
    public let peakDemuxDeferredPacketDepth: Int
    public let demuxDeferredPacketCount: Int
    public let demuxCapacityWaits: Int
    public let demuxCapacityWaitSeconds: Double
    public let framesSubmitted: Int

    public var rendererClockAdvanced: Bool {
        firstRendererClockAdvanceSeconds != nil
    }
}

private struct NativeReplacementLifecycleSnapshot: Sendable {
    var sessionID: UInt64 = 0
    var sourcePath: String?
    var stage = "idle"
    var stageUptimeSeconds = 0.0
    var transitions: [NativePlaybackLifecycleTransition] = []
}

private final class NativeReplacementLifecycleLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var value = NativeReplacementLifecycleSnapshot()

    func begin(sessionID: UInt64, sourcePath: String) {
        lock.withLock {
            let now = ProcessInfo.processInfo.systemUptime
            value = NativeReplacementLifecycleSnapshot(
                sessionID: sessionID,
                sourcePath: sourcePath,
                stage: "replacement-began",
                stageUptimeSeconds: now,
                transitions: [NativePlaybackLifecycleTransition(
                    stage: "replacement-began",
                    uptimeSeconds: now
                )]
            )
        }
    }

    func record(sessionID: UInt64, stage: String) {
        lock.withLock {
            guard value.sessionID == sessionID else { return }
            let now = ProcessInfo.processInfo.systemUptime
            value.stage = stage
            value.stageUptimeSeconds = now
            value.transitions.append(NativePlaybackLifecycleTransition(
                stage: stage,
                uptimeSeconds: now
            ))
        }
    }

    var snapshot: NativeReplacementLifecycleSnapshot {
        lock.withLock { value }
    }
}

private struct PendingPreviewSeek {
    let target: TimeInterval
    let effectID: PlaybackEffectID?
}

private struct DeferredReplacementRequest {
    let request: PlaybackRuntimeLoadRequest
    let seekTo: TimeInterval?
    let emitLoaded: Bool
    let preserveOldUntilPrepared: Bool
    let audioDelay: TimeInterval?
}

private struct PendingCommittedReplacement {
    let candidateSessionID: PlaybackSessionID
    let candidate: MediaSession
    let candidateMetadata: RuntimeSessionMetadata
    let oldSession: MediaSession
    let oldMetadata: RuntimeSessionMetadata?
    let oldSubtitleSource: NativeSubtitleSource
    let oldAudioIndex: Int32?
    let oldPreparedExternalSubtitle: PreparedExternalSubtitle?
    let oldIdentity: PlayerSessionIdentity?
    let oldURL: URL?
    let rollbackPosition: TimeInterval
}

enum RuntimeObservationSource: String, CaseIterable, Sendable {
    case presentationClock
    case videoEnqueue
    case audioEnqueue
    case subtitlePacket
    case preroll
    case decoderDrain
    case rendererFailure
}

enum RuntimeObservationUrgency: Sendable {
    case routine
    case urgent
}

struct RuntimeObservationRequest: Sendable {
    let source: RuntimeObservationSource
    let urgency: RuntimeObservationUrgency
}

struct RuntimeObservationMetricsSnapshot: Equatable, Sendable {
    var requestsBySource: [RuntimeObservationSource: Int] = [:]
    var scheduledDeliveries = 0
    var coalescedRequests = 0
    var deliveredObservations = 0
    var followUpDeliveries = 0
    var maximumDelayNanoseconds: UInt64 = 0
    var maximumUrgentDelayNanoseconds: UInt64 = 0

    var totalRequests: Int { requestsBySource.values.reduce(0, +) }
}

struct RuntimeObservationMetricsLedger: Sendable {
    private(set) var snapshot = RuntimeObservationMetricsSnapshot()
    private var oldestPendingNanoseconds: UInt64?
    private var oldestUrgentPendingNanoseconds: UInt64?

    mutating func recordRequest(
        _ request: RuntimeObservationRequest,
        at nanoseconds: UInt64,
        scheduled: Bool
    ) {
        snapshot.requestsBySource[request.source, default: 0] += 1
        if scheduled {
            snapshot.scheduledDeliveries += 1
        } else {
            snapshot.coalescedRequests += 1
        }
        oldestPendingNanoseconds = min(oldestPendingNanoseconds ?? nanoseconds, nanoseconds)
        if request.urgency == .urgent {
            oldestUrgentPendingNanoseconds = min(
                oldestUrgentPendingNanoseconds ?? nanoseconds,
                nanoseconds
            )
        }
    }

    mutating func recordDelivery(at nanoseconds: UInt64, isFollowUp: Bool) {
        snapshot.deliveredObservations += 1
        if isFollowUp { snapshot.followUpDeliveries += 1 }
        if let oldestPendingNanoseconds {
            snapshot.maximumDelayNanoseconds = max(
                snapshot.maximumDelayNanoseconds,
                nanoseconds &- oldestPendingNanoseconds
            )
        }
        if let oldestUrgentPendingNanoseconds {
            snapshot.maximumUrgentDelayNanoseconds = max(
                snapshot.maximumUrgentDelayNanoseconds,
                nanoseconds &- oldestUrgentPendingNanoseconds
            )
        }
        oldestPendingNanoseconds = nil
        oldestUrgentPendingNanoseconds = nil
    }
}

/// Collapses overlapping decoder/audio observation requests into one main-actor
/// delivery plus, at most, one follow-up when work arrived during that delivery.
/// Counters make the coalescing rate and urgent-edge delay observable without
/// changing the delivery policy.
final class RuntimeObservationCoalescer: @unchecked Sendable {
    private let lock = NSLock()
    private var isScheduled = false
    private var needsFollowUp = false
    private var metrics = RuntimeObservationMetricsLedger()

    func request(
        _ request: RuntimeObservationRequest,
        operation: @escaping @MainActor @Sendable () -> Void
    ) {
        let requestedAt = DispatchTime.now().uptimeNanoseconds
        let shouldSchedule = lock.withLock {
            if isScheduled {
                needsFollowUp = true
                metrics.recordRequest(request, at: requestedAt, scheduled: false)
                return false
            }
            isScheduled = true
            metrics.recordRequest(request, at: requestedAt, scheduled: true)
            return true
        }
        guard shouldSchedule else { return }

        Task { @MainActor [weak self] in
            guard let self else { return }
            var isFollowUp = false
            while true {
                lock.withLock {
                    metrics.recordDelivery(
                        at: DispatchTime.now().uptimeNanoseconds,
                        isFollowUp: isFollowUp
                    )
                }
                operation()
                let shouldRepeat = lock.withLock {
                    if needsFollowUp {
                        needsFollowUp = false
                        return true
                    }
                    isScheduled = false
                    return false
                }
                guard shouldRepeat else { return }
                isFollowUp = true
                await Task.yield()
            }
        }
    }

    func snapshot() -> RuntimeObservationMetricsSnapshot {
        lock.withLock { metrics.snapshot }
    }
}

/// Production adapter around the qualified native playback implementation.
///
/// FFmpeg, VideoToolbox, sample-buffer renderers, and libass remain private to
/// this module. Product code communicates only through `PlaybackRuntime`.
@MainActor
public final class NativePlaybackRuntime: PlaybackRuntime {
    public let capabilities: PlaybackCapabilities
    private var trackSelectionPreferences = TrackSelectionPreferences()
    public func setTrackSelectionPreferences(_ preferences: TrackSelectionPreferences) {
        trackSelectionPreferences = preferences.sanitized()
    }

    private var subtitleFallbackEncoding: SubtitleFallbackEncoding = .unicodeOnly
    private var audioDeviceMonitor: NativeAudioDeviceMonitor?
    private var audioDeviceCatalog = NativeAudioDeviceCatalog()
    private var availableAudioDevices: [AudioOutputDevice] { audioDeviceCatalog.devices }
    private var lastPublishedAudioDevices: [AudioOutputDevice]?

    public func setSubtitleFallbackEncoding(_ encoding: SubtitleFallbackEncoding) {
        subtitleFallbackEncoding = encoding
    }

    public var eventHandler: (@MainActor @Sendable (PlaybackRuntimeEvent) -> Void)? {
        didSet {
            if eventHandler != nil, audioDeviceMonitor == nil, !isShutdown {
                audioDeviceMonitor = NativeAudioDeviceMonitor { [weak self] devices in
                    Task { @MainActor [weak self] in self?.updateAudioDevices(devices) }
                }
            }
        }
    }

    let presentation: NativePresentationCoordinator
    private let subtitleMemoryBudget: SubtitleMemoryBudget
    private(set) var subtitles: SubtitlePipeline
    private var pictureInPictureSubtitles: SubtitlePipeline?
    private var pictureInPictureSubtitleCompositor: PiPSubtitleCompositor?
    private var pictureInPictureInitializationFailure: String?
    private let runtimeMetadata = PlaybackRuntimeMetadataDirectory()
    private let replacementLifecycle = NativeReplacementLifecycleLedger()

    private var surfaceHost: NativePlaybackSurfaceHost?
    private var session: MediaSession?
    private var pendingLoad: PlaybackRuntimeLoadRequest?
    private var operations = NativeOperationLedger()
    private var operationDeadlineTasks: [PlaybackEffectID: Task<Void, Never>] = [:]
    private var operationWorkTasks: [PlaybackEffectID: Task<Void, Never>] = [:]
    private var legacyExternalSubtitleTask: Task<Void, Never>?
    private var replacementTasks: [PlaybackSessionID: Task<Void, Never>] = [:]
    private var replacementCandidates: [PlaybackSessionID: MediaSession] = [:]
    private var replacementCandidateMetadata:
        [PlaybackSessionID: RuntimeSessionMetadata] = [:]
    private var replacementConstructionCancellations:
        [PlaybackSessionID: FFmpegInputCancellationSignal] = [:]
    private var replacementSeekTargets: [PlaybackSessionID: TimeInterval?] = [:]
    private var retirementTasks: [UUID: Task<Bool, Never>] = [:]
    private var deferredReplacementRequest: DeferredReplacementRequest?
    private var deferredReplacementTask: Task<Void, Never>?
    private var deferredReplacementAdmissionCount = 0
    private var cancelledReplacementSessionIDs: Set<PlaybackSessionID> = []
    private var latestReplacementSessionID: PlaybackSessionID?
    private var pendingCommittedReplacement: PendingCommittedReplacement?
    private var pendingMetadataPublicationSessionID: PlaybackSessionID?
    private var activeIdentity: PlayerSessionIdentity?
    private var currentURL: URL?
    private var selectedAudioIndex: Int32?
    private var subtitleSource: NativeSubtitleSource = .automaticEmbedded
    private var preparedExternalSubtitle: PreparedExternalSubtitle?
    private var externalSubtitleRequestRevision: UInt64 = 0
    private var desiredPlaying = false
    private let frameStepReader = NativeFrameStepReader()
    private var playbackSpeed: Float = 1
    private var videoAdjustments = VideoAdjustmentState.standard
    private var preferHardware = true
    private let softwareVideoOutputPolicy: NativeSoftwareVideoOutputPolicy
    private let seekPrerollFrameSkippingEnabled: Bool
    private let softwareSeekAccelerationEnabled: Bool
    private let videoFrameQueueCapacity: Int
    private let reservesVideoPipelineCapacity: Bool
    private let videoPipelineCapacityOverride: Int?
    private let usesFairDemuxDispatch: Bool
    private let softwarePlanarOutputMaximumBufferCount: Int
    private var volume = 100.0
    private var isMuted = false
    private var currentTime = 0.0
    private var pendingPreviewSeek: PendingPreviewSeek?
    private var previewSeekInFlight = false
    private var activeSessionID = PlaybackSessionID(rawValue: 0)
    private var activeRuntimeSession: RuntimeSessionMetadata?
    private var applicationGraphLease: ResourceLeaseID?
    private var surfaceLease: ResourceLeaseID?
    private var surfaceBorrow: ResourceBorrowID?
    private var pictureInPictureLease: ResourceLeaseID?
    private var pictureInPictureBorrow: ResourceBorrowID?
    private var lastSnapshot: MediaSessionSnapshot?
    private var didEmitFirstFrameSubmitted = false
    private var didEmitPreroll = false
    private var didEmitEndOfFile = false
    private var isShutdown = false
    private var shutdownTask: Task<Bool, Never>?
    private var shutdownResult: Bool?
    private var shutdownEffectTask: Task<Void, Never>?
    private var lastMetricsEmission = Date.distantPast
    private var lastPositionEmission = Date.distantPast
    private var lastBufferingEmission = Date.distantPast
    private var lastBufferingState: Bool?
    private var lastEmittedVideoStatus: VideoOutputStatus?
    private var lastEmittedVideoAspectRatio: Double?
    private var lastEmittedDecoderStatus: PlayerDecoderStatus?
    private var lastObservationMetrics = RuntimeObservationMetricsSnapshot()
    private let presentationObservations = RuntimeObservationCoalescer()
    private var lastSubtitlePacketRequestCount = 0
    private var subtitleCompositedPiPRequested = false
    private var subtitleCompositedPiPPresentationActive = false
    private var restartVideoOnlyPiPAfterCompositionFailure = false
    private var pictureInPictureDisplayLayerHost: PiPSubtitleDisplayLayerHost?
    private var pictureInPictureRestoreRequestHandler:
        PictureInPictureRestoreRequestHandler?
    private lazy var pictureInPictureController: NativePictureInPictureController? = {
        guard capabilities.contains(.pictureInPicture) else { return nil }
        return NativePictureInPictureController(
            displayLayer: presentation.video.displayLayer,
            onSetPlaying: { [weak self] playing in
                self?.emit(.transportRequested(playing: playing))
            },
            onSkip: { [weak self] interval in
                self?.emit(.relativeSeekRequested(interval))
            },
            onRestoreUserInterface: { [weak self] completion in
                guard let self else {
                    completion(false)
                    return
                }
                if let pictureInPictureRestoreRequestHandler {
                    pictureInPictureRestoreRequestHandler(completion)
                    return
                }
                guard let window = surfaceHost?.view.window else {
                    completion(false)
                    return
                }
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                completion(
                    window.isVisible
                        && surfaceHost?.view.window === window
                )
            },
            onViewportSizeChanged: { [weak self] viewportSize in
                guard let self else { return }
                if subtitleCompositedPiPRequested,
                   let pictureInPictureSubtitleCompositor
                {
                    if let size = pictureInPictureSubtitleCompositor.setViewportSize(
                        viewportSize
                    ) {
                        pictureInPictureDisplayLayerHost?.setSize(size)
                    }
                } else {
                    surfaceHost?.pictureInPictureViewportSize = viewportSize
                }
            },
            onStateChanged: { [weak self] state in
                guard let self else { return }
                setSubtitleCompositedPiPPresentationActive(
                    state.isActive && subtitleCompositedPiPRequested
                )
                emit(.pictureInPictureChanged(state), identity: nil)
            },
            onSessionEnded: { [weak self] in
                guard let self else { return }
                let restartVideoOnly =
                    restartVideoOnlyPiPAfterCompositionFailure && !isShutdown
                restartVideoOnlyPiPAfterCompositionFailure = false
                endSubtitleCompositedPiPSession(rebindController: !isShutdown)
                if restartVideoOnly {
                    pictureInPictureController?.startWhenPossible()
                }
            },
            onDiagnostic: { [weak self] message in
                self?.emit(.diagnostic(message), identity: nil)
            }
        )
    }()

    public init(
        softwareVideoOutputPolicy: NativeSoftwareVideoOutputPolicy = .bgra,
        videoFrameQueueCapacity: Int = 12,
        reservesVideoPipelineCapacity: Bool = true,
        videoPipelineCapacityOverride: Int? = nil,
        usesFairDemuxDispatch: Bool = false,
        softwarePlanarOutputMaximumBufferCount: Int = 16,
        seekPrerollFrameSkippingEnabled: Bool = true,
        softwareSeekAccelerationEnabled: Bool = true
    ) throws {
        var capabilities: PlaybackCapabilities = [
            .localFiles,
            .playbackSpeed,
            .videoGeometry,
            .frameStepping,
            .screenshots,
            .relativeSeeking,
            .exactSeeking,
            .previewSeeking,
            .audioTracks,
            .audioDeviceSelection,
            .audioDelay,
            .subtitleTracks,
            .externalSubtitles,
            .subtitleDelay,
            .chapters,
            .hardwareDecodingPolicy,
            .nativeSampleBufferSurface,
        ]
        if NativePictureInPictureController.isSupported {
            capabilities.insert(.pictureInPicture)
        }
        self.capabilities = capabilities
        self.softwareVideoOutputPolicy = softwareVideoOutputPolicy
        self.seekPrerollFrameSkippingEnabled = seekPrerollFrameSkippingEnabled
        self.softwareSeekAccelerationEnabled = softwareSeekAccelerationEnabled
        self.videoFrameQueueCapacity = max(1, videoFrameQueueCapacity)
        self.reservesVideoPipelineCapacity = reservesVideoPipelineCapacity
        self.videoPipelineCapacityOverride = videoPipelineCapacityOverride
        self.usesFairDemuxDispatch = usesFairDemuxDispatch
        self.softwarePlanarOutputMaximumBufferCount = max(
            1,
            softwarePlanarOutputMaximumBufferCount
        )
        let presentation = try NativePresentationCoordinator()
        let subtitleMemoryBudget = SubtitleMemoryBudget()
        self.subtitleMemoryBudget = subtitleMemoryBudget
        let subtitles = try SubtitlePipeline(
            overlay: SubtitleOverlayView(),
            deduplicatesPackets: true,
            memoryBudget: self.subtitleMemoryBudget,
            memoryOwner: .mainLibass
        )
        self.presentation = presentation
        self.subtitles = subtitles
        pictureInPictureSubtitles = nil
        pictureInPictureSubtitleCompositor = nil
        pictureInPictureInitializationFailure = capabilities.contains(.pictureInPicture)
            ? nil
            : "Picture in Picture is unavailable on this system."
        presentation.setAudioOutputChangeHandler { [weak self] fence, time in
            Task { @MainActor [weak self] in
                self?.audioDeviceMonitor?.refresh()
                guard let self, self.session != nil, self.activeIdentity != nil,
                      self.presentation.currentFence == fence, time.isNumeric else { return }
                self.emit(.audioOutputChanged(max(0, time.seconds)))
            }
        }
        presentation.setVideoColorSampleHandler { [weak self] sample in
            Task { @MainActor [weak self] in
                self?.emit(.videoColorSampleChanged(sample))
            }
        }
        subtitles.overlay.onPresentationInvalidated = { [weak self] in
            self?.subtitles.invalidatePresentationRequest()
            self?.renderSubtitlesAtPresentationTime()
        }
        let presentationObservations = self.presentationObservations
        presentation.setPresentationTimeHandler { [weak self] _ in
            presentationObservations.request(.init(source: .presentationClock, urgency: .routine)) { [weak self] in
                guard let self, !self.isShutdown else { return }
                self.renderSubtitlesAtPresentationTime()
                if self.desiredPlaying,
                   self.lastSnapshot?.decoderDrainComplete == true,
                   self.lastSnapshot?.ended == false
                {
                    self.consumeRuntimeObservation()
                }
            }
        }
        let graphContext = runtimeMetadata.makeApplicationContext()
        applicationGraphLease = runtimeMetadata.leases.acquire(
            provenance: RuntimeResourceProvenance(
                kind: .applicationPresentationGraph,
                authority: graphContext.authority,
                creatorContext: graphContext,
                storageExecutor: .presentation
            )
        )
    }

    private var subtitlePipelines: [SubtitlePipeline] {
        if let pictureInPictureSubtitles {
            [subtitles, pictureInPictureSubtitles]
        } else {
            [subtitles]
        }
    }

    private var subtitlesEnabled: Bool {
        if case .off = subtitleSource { return false }
        return true
    }

    private var selectedSubtitleIndex: Int32? {
        switch subtitleSource {
        case let .embedded(streamIndex):
            streamIndex
        case .automaticEmbedded:
            session?.activeSubtitleStream?.index
        case .off, .external, .externalBitmap:
            nil
        }
    }

    private var externalSubtitleTrack: MediaTrack? {
        preparedExternalSubtitle?.track
    }

    private var externalSubtitleData: Data? {
        preparedExternalSubtitle?.data
    }

    private func setSubtitlePipelinesEnabled(_ enabled: Bool) {
        for pipeline in subtitlePipelines {
            pipeline.isEnabled = enabled
        }
        refreshPresentationObservationCadence()
        renderSubtitlesAtPresentationTime()
    }

    private func makeCandidateSubtitlePipelines(
        source: NativeSubtitleSource
    ) throws -> (
        main: SubtitlePipeline,
        pictureInPicture: SubtitlePipeline?
    ) {
        let enabled = source != .off
        let main = try SubtitlePipeline(
            overlay: subtitles.overlay,
            deduplicatesPackets: true,
            memoryBudget: self.subtitleMemoryBudget,
            memoryOwner: .mainLibass
        )
        main.setPresentationAuthorityEnabled(false)
        main.isEnabled = enabled
        main.delay = subtitles.delay

        let pictureInPicture: SubtitlePipeline?
        if pictureInPictureSubtitleCompositor != nil {
            let candidate = try SubtitlePipeline(
                overlay: SubtitleOverlayView(headless: true),
                presentsOverlay: false,
                deduplicatesPackets: true,
                memoryBudget: self.subtitleMemoryBudget,
                memoryOwner: .pictureInPictureLibass
            )
            candidate.setPresentationAuthorityEnabled(false)
            candidate.isEnabled = enabled
            candidate.delay = subtitles.delay
            pictureInPicture = candidate
        } else {
            pictureInPicture = nil
        }
        return (main, pictureInPicture)
    }

    @discardableResult
    private func preparePictureInPictureSubtitleInfrastructureIfNeeded() -> Bool {
        guard capabilities.contains(.pictureInPicture) else { return false }
        if pictureInPictureSubtitleCompositor != nil { return true }
        guard pictureInPictureInitializationFailure == nil else { return false }

        do {
            let compositor = try PiPSubtitleCompositor(
                memoryBudget: subtitleMemoryBudget
            )
            compositor.setVideoAdjustments(videoAdjustments)
            pictureInPictureSubtitleCompositor = compositor
            presentation.setPictureInPictureFrameSink(
                { [weak compositor] frame in
                    compositor?.receive(frame)
                },
                onInvalidation: { [weak compositor] in
                    compositor?.invalidatePendingFrames()
                }
            )
            compositor.setViewportSize(nil)
            emit(.diagnostic(
                "[native-pip-subtitles] Ready for eligible SDR BGRA/NV12 media; normal presentation remains on the original display layer."
            ), identity: nil)
            return true
        } catch {
            pictureInPictureInitializationFailure = error.localizedDescription
            emit(.diagnostic(
                "[native-pip-subtitles] Video-only fallback after initialization failure: "
                    + error.localizedDescription
            ), identity: nil)
            return false
        }
    }

    var hasPreparedPictureInPictureSubtitleInfrastructureForTesting: Bool {
        pictureInPictureSubtitleCompositor != nil
    }

    private func setSubtitlePipelineDelay(_ delay: Double) {
        for pipeline in subtitlePipelines {
            pipeline.delay = delay
        }
        renderSubtitlesAtPresentationTime()
    }

    private func clearSubtitlePipelines() {
        for pipeline in subtitlePipelines {
            pipeline.clear()
        }
    }

    private func setSubtitleDiagnosticMediaIdentity(_ identity: String?) {
        subtitles.setDiagnosticMediaIdentity(identity)
        pictureInPictureSubtitles?.setDiagnosticMediaIdentity(
            identity.map { "\($0) [PiP]" }
        )
    }

    private func installExternalSubtitleData(_ data: Data) throws {
        for pipeline in subtitlePipelines {
            try pipeline.installExternal(data: data)
        }
    }

    private func terminateSubtitlePipelines() {
        for pipeline in subtitlePipelines {
            pipeline.terminate()
        }
    }

    private func refreshPictureInPictureSubtitleFrame() {
        guard subtitleCompositedPiPRequested else { return }
        pictureInPictureSubtitleCompositor?.refreshLatestFrame()
    }

    private func setSubtitleCompositedPiPPresentationActive(_ active: Bool) {
        guard subtitleCompositedPiPPresentationActive != active else { return }
        subtitleCompositedPiPPresentationActive = active
        // The main renderer remains the session's demand source. Hiding its
        // view must not bypass sample submission and admit an entire decoded
        // stream while the shared clock is paused. It also retains the correct
        // timestamped frame for restoration, rather than the latest prefetch.
        if !active { session?.renderSubtitles() }
        surfaceHost?.setMainPresentationSuppressed(active)
    }

    public func makeSurfaceHost() throws -> any PlaybackSurfaceHost {
        guard !isShutdown else { throw NativePlaybackRuntimeError.backendShutDown }
        if let surfaceHost { return surfaceHost }
        let host = NativePlaybackSurfaceHost(backend: self)
        surfaceHost = host
        if surfaceLease == nil {
            let context = runtimeMetadata.makeApplicationContext()
            let lease = runtimeMetadata.leases.acquire(provenance: RuntimeResourceProvenance(
                kind: .surface,
                authority: context.authority,
                creatorContext: context,
                storageExecutor: .platform
            ))
            surfaceLease = lease
            surfaceBorrow = runtimeMetadata.leases.borrow(lease)
        }
        _ = pictureInPictureController
        if let pictureInPictureInitializationFailure {
            emit(.diagnostic(
                "[native-pip-subtitles] Video-only fallback after initialization failure: "
                    + pictureInPictureInitializationFailure
            ), identity: nil)
        }
        if capabilities.contains(.pictureInPicture), pictureInPictureLease == nil {
            let context = runtimeMetadata.makeApplicationContext()
            let lease = runtimeMetadata.leases.acquire(provenance: RuntimeResourceProvenance(
                kind: .pictureInPicture,
                authority: context.authority,
                creatorContext: context,
                storageExecutor: .platform
            ))
            pictureInPictureLease = lease
            pictureInPictureBorrow = runtimeMetadata.leases.borrow(lease)
        }
        pictureInPictureController?.publishCurrentState()
        if let pendingLoad {
            self.pendingLoad = nil
            beginReplaceSession(for: pendingLoad, seekTo: nil, emitLoaded: true)
        }
        return host
    }

    public func execute(_ request: PlaybackRuntimeEffectRequest) {
        let effect = request.effect
        switch effect.kind {
        case let .openSource(source):
            guard let load = request.load else {
                finish(effect, succeeded: false, code: "missingAuthorizedLoad")
                return
            }
            let transaction = beginOperation(
                effect,
                kind: .open,
                requestedState: .openSource(source),
                supersessionCode: "openSuperseded"
            )
            do {
                try self.load(load)
            } catch {
                finishOperation(
                    effectID: transaction.effectID,
                    succeeded: false,
                    code: "nativeOpenRejected"
                )
            }

        case .probeSource:
            finish(effect, succeeded: false, code: "legacyProbeEffectUnsupported")

        case .configureSession:
            finish(effect, succeeded: false, code: "legacyConfigureEffectUnsupported")

        case .awaitPreroll:
            if session?.snapshot().isPrerolled == true {
                finish(effect)
            } else {
                _ = beginOperation(
                    effect,
                    kind: .preroll,
                    requestedState: .awaitPreroll,
                    nativeSessionID: activeSessionID,
                    supersessionCode: "prerollSuperseded"
                )
            }

        case let .applyRate(milliRate):
            guard let session else {
                finish(effect, succeeded: false, code: "rateRequiresSession")
                return
            }
            let playing = milliRate != 0
            desiredPlaying = playing
            if playing { playbackSpeed = Float(milliRate) / 1_000 }
            let accepted = session.requestTransport(playing: playing, speed: Float(milliRate) / 1_000)
            if accepted {
                pictureInPictureController?.updatePlayback(
                    duration: session.mediaInfo.duration,
                    isPaused: !playing
                )
                emit(.pauseChanged(!playing))
            }
            finish(effect, succeeded: accepted, code: "presentationRateRejected")

        case let .seekPipeline(target, mode), let .seek(target, mode):
            guard let seconds = seconds(target), session != nil else {
                finish(effect, succeeded: false, code: "seekRequiresValidSession")
                return
            }
            let transaction = beginOperation(
                effect,
                kind: .seek,
                requestedState: .seek(target: target, mode: mode),
                nativeSessionID: activeSessionID,
                supersessionCode: "seekSuperseded"
            )
            seek(
                to: seconds,
                mode: runtimeSeekMode(mode),
                effectID: transaction.effectID
            )

        case let .applyAudioSelection(intent, _):
            let id: Int64? = switch intent {
            case .off: nil
            case .automatic: nil
            case .stream(let track): track.mediaTrackID
            }
            if case .off = intent {
                finish(effect, succeeded: session?.disableAudioTrackAfterFailure() == true,
                       code: "audioDisableFailed")
                return
            }
            if let id {
                guard let index = streamIndex(id),
                      session?.mediaInfo.audioStreams.contains(where: { $0.index == index }) == true
                else {
                    finish(effect, succeeded: false, code: "invalidAudioTrackID")
                    return
                }
            }
            if id.flatMap(streamIndex) == selectedAudioIndex {
                finish(effect)
            } else {
                _ = beginOperation(
                    effect,
                    kind: .trackReplacement,
                    requestedState: .audioTrack(id),
                    supersessionCode: "trackSelectionSuperseded"
                )
                selectAudioTrack(id)
            }

        case let .applySubtitleSelection(intent, _):
            switch intent {
            case .off:
                if subtitleSource == .off {
                    finish(effect)
                } else {
                    _ = beginOperation(
                        effect,
                        kind: .trackReplacement,
                        requestedState: .subtitle(intent),
                        supersessionCode: "trackSelectionSuperseded"
                    )
                    selectSubtitleTrack(nil)
                }
            case .automatic:
                if subtitleSource == .automaticEmbedded {
                    finish(effect)
                } else {
                    _ = beginOperation(
                        effect,
                        kind: .trackReplacement,
                        requestedState: .subtitle(intent),
                        supersessionCode: "trackSelectionSuperseded"
                    )
                    if let url = currentURL {
                        subtitleSource = .automaticEmbedded
                        replaceSessionForTrackChange(url: url)
                    } else {
                        finishOperation(
                            kind: .trackReplacement,
                            nativeSessionID: activeSessionID,
                            succeeded: false,
                            code: "subtitleSelectionRequiresActiveMedia"
                        )
                    }
                }
            case .embedded(let track):
                // Installed sidecar tracks share the existing track-ID command.
                // Resource installation itself remains the external-source effect.
                if let requested = preparedExternalSubtitle?.source(for: track.mediaTrackID) {
                    if subtitleSource == requested { finish(effect) }
                    else {
                        _ = beginOperation(effect, kind: .trackReplacement, requestedState: .subtitle(intent),
                                           supersessionCode: "trackSelectionSuperseded")
                        selectSubtitleTrack(track.mediaTrackID)
                    }
                    return
                }
                guard let index = streamIndex(track.mediaTrackID),
                      session?.mediaInfo.subtitleStreams.contains(where: {
                          $0.index == index && $0.subtitleCapability?.isPlayable == true
                      }) == true
                else {
                    finish(effect, succeeded: false, code: "invalidOrUnsupportedSubtitleTrackID")
                    return
                }
                if selectedSubtitleIndex == index {
                    // Automatic selection may already have resolved to this
                    // exact stream. Canonicalize the persisted choice without
                    // rebuilding the entire playback session.
                    subtitleSource = .embedded(streamIndex: index)
                    setBitmapSubtitleFilter(false)
                    finish(effect)
                } else {
                    _ = beginOperation(
                        effect,
                        kind: .trackReplacement,
                        requestedState: .subtitle(intent),
                        supersessionCode: "trackSelectionSuperseded"
                    )
                    selectSubtitleTrack(track.mediaTrackID)
                }
            case .external:
                guard let url = request.externalResourceURL else {
                    finish(effect, succeeded: false, code: "missingExternalSubtitleURL")
                    return
                }
                let transaction = beginOperation(
                    effect,
                    kind: .externalSubtitle,
                    requestedState: .externalSubtitle(url),
                    nativeSessionID: activeSessionID,
                    supersessionCode: "externalSubtitleSuperseded"
                )
                installExternalSubtitle(url, effectID: transaction.effectID)
            }

        case let .applySubtitleDelay(microseconds):
            setSubtitlePipelineDelay(
                min(max(Double(microseconds) / 1_000_000, -10), 10)
            )
            refreshPictureInPictureSubtitleFrame()
            emit(.subtitleDelayChanged(subtitles.delay))
            finish(effect)

        case .cancelSession:
            let transaction = beginOperation(
                effect,
                kind: .sessionCancellation,
                requestedState: .cancelSession,
                nativeSessionID: activeSessionID,
                supersessionCode: "sessionCancellationSuperseded"
            )
            cancelSession(effectID: transaction.effectID)

        case .clearSubtitleOverlay, .invalidateSubtitleSource:
            clearSubtitlePipelines()
            finish(effect)

        case .installPresentationFence(let removeDisplayedImage):
            let transaction = beginOperation(
                effect,
                kind: .presentationFlush,
                requestedState: .presentationFlush,
                nativeSessionID: activeSessionID,
                supersessionCode: "presentationFlushSuperseded"
            )
            let time = presentation.currentTime
            let fence = presentation.installFenceAndRequestFlush(
                at: time.isNumeric ? time : .zero,
                removeDisplayedImage: removeDisplayedImage
            )
            finishWhenPresentationFlushCompletes(
                effectID: transaction.effectID,
                fence: fence
            )

        case .resumeVideoDecoderAfterTransientFailure,
             .recreateVideoDecoderInSoftware,
             .flushPresentationForRecovery,
             .rebuildPresentationGraph,
             .flushAudioPresentationForRecovery,
             .rebuildAudioPresentation,
             .disableAudioTrack,
             .disableSubtitleTrack,
             .correctAudioVideoDrift,
             .reconfigureMediaFormat:
            executeRecoveryOrSynchronization(effect)

        case let .resumeAfterWake(position, milliRate):
            guard let seconds = seconds(position), session != nil else {
                finish(effect, succeeded: false, code: "wakeRequiresValidSession")
                return
            }
            let transaction = beginOperation(
                effect,
                kind: .wake,
                requestedState: .wake(position: position, milliRate: milliRate),
                nativeSessionID: activeSessionID,
                supersessionCode: "wakeSuperseded"
            )
            let generation = resumeAfterWake(
                position: seconds,
                playing: milliRate != 0
            )
            if let generation {
                correlateOperation(
                    effectID: transaction.effectID,
                    nativeSessionID: activeSessionID,
                    nativeGeneration: generation
                )
            } else {
                finishOperation(
                    effectID: transaction.effectID,
                    succeeded: false,
                    code: "wakeRequiresValidSession"
                )
            }

        case .finalizeShutdown:
            let transaction = beginOperation(
                effect,
                kind: .shutdown,
                requestedState: .shutdown,
                supersessionCode: "shutdownSuperseded"
            )
            shutdownEffectTask?.cancel()
            shutdownEffectTask = Task { [weak self] in
                guard let self else { return }
                let clean = await self.shutdownAndReport()
                guard !Task.isCancelled else { return }
                self.shutdownEffectTask = nil
                self.finishOperation(
                    effectID: transaction.effectID,
                    succeeded: clean,
                    code: "nativeShutdownIncomplete"
                )
            }

        case .cancelInputRead, .flushDecoder, .releaseLease,
             .persistCheckpoint, .advancePlaylist, .mirrorDiagnostic:
            // These are either superseded compatibility effects or belong to
            // a player-shell executor. Production validation rejects routing
            // them here.
            finish(effect, succeeded: false, code: "effectRoutedToWrongExecutor")
        }
    }

    public func load(_ request: PlaybackRuntimeLoadRequest) throws {
        guard !isShutdown else { throw NativePlaybackRuntimeError.backendShutDown }
        guard !request.media.source.isRemote else { throw NativePlaybackRuntimeError.localFilesOnly }

        let preservesCommittedSession = session != nil
        if !preservesCommittedSession {
            activeIdentity = request.identity
            currentURL = request.media.source.url
            selectedAudioIndex = nil
            subtitleSource = .automaticEmbedded
            preparedExternalSubtitle = nil
            setSubtitlePipelinesEnabled(true)
            desiredPlaying = false
            pictureInPictureController?.updatePlayback(duration: 0, isPaused: true)
        }
        pendingPreviewSeek = nil
        previewSeekInFlight = false
        didEmitFirstFrameSubmitted = false
        didEmitPreroll = false
        didEmitEndOfFile = false
        lastSnapshot = nil
        lastPositionEmission = .distantPast
        lastBufferingEmission = .distantPast
        lastBufferingState = nil
        lastEmittedVideoStatus = nil
        lastEmittedVideoAspectRatio = nil
        lastEmittedDecoderStatus = nil
        emit(.started, identity: request.identity)

        guard surfaceHost != nil else {
            pendingLoad = request
            return
        }
        beginReplaceSession(
            for: request,
            seekTo: nil,
            emitLoaded: true,
            preserveOldUntilPrepared: preservesCommittedSession
        )
    }

    public func play() {
        desiredPlaying = true
        session?.requestTransport(playing: true, speed: playbackSpeed)
        pictureInPictureController?.updatePlayback(
            duration: session?.mediaInfo.duration ?? 0,
            isPaused: false
        )
        emit(.pauseChanged(false))
    }

    public func pause() {
        desiredPlaying = false
        session?.requestTransport(playing: false)
        pictureInPictureController?.updatePlayback(
            duration: session?.mediaInfo.duration ?? 0,
            isPaused: true
        )
        emit(.pauseChanged(true))
    }

    public func stop() {
        pendingLoad = nil
        desiredPlaying = false
        stopPictureInPictureForLifecycleChange()
        pictureInPictureController?.updatePlayback(duration: 0, isPaused: true)
        pendingPreviewSeek = nil
        previewSeekInFlight = false
        let identity = activeIdentity
        stopCurrentSession()
        currentTime = 0
        emit(.positionChanged(0), identity: identity)
        emit(.stopped, identity: identity)
        activeIdentity = nil
    }

    public func seek(to value: TimeInterval, mode: SuperplayrPlayback.SeekMode) {
        seek(to: value, mode: mode, effectID: nil)
    }

    private func seek(
        to value: TimeInterval,
        mode: SuperplayrPlayback.SeekMode,
        effectID: PlaybackEffectID?
    ) {
        guard let session else { return }
        let target: TimeInterval
        switch mode {
        case .relative:
            target = currentTime + value
        case .absoluteExact:
            target = value
        case .absolutePreview:
            target = value
        }
        let nonnegativeTarget = max(target, 0)
        let bounded = switch session.mediaInfo.durationStatus {
        case .valid(let duration): min(nonnegativeTarget, max(duration, 0))
        case .unknown, .invalid: nonnegativeTarget
        }
        didEmitEndOfFile = false
        if mode == .absolutePreview {
            // Like mpv's queued keyframe seeks, keep only the newest target
            // while a preview frame is being produced. A full pipeline flush
            // for every mouse event prevents the renderer from ever catching
            // up during a fast drag.
            pendingPreviewSeek = PendingPreviewSeek(
                target: bounded,
                effectID: effectID
            )
            dispatchPendingPreviewSeekIfReady(session: session)
        } else {
            pendingPreviewSeek = nil
            previewSeekInFlight = false
            let nativeGeneration = session.seek(
                to: bounded,
                exact: true,
                resumeRate: 0
            )
            if let effectID {
                correlateOperation(
                    effectID: effectID,
                    nativeSessionID: activeSessionID,
                    nativeGeneration: nativeGeneration
                )
            }
        }
        if let replacementSessionID = latestReplacementSessionID,
           replacementSessionID != activeSessionID,
           replacementTasks[replacementSessionID] != nil
                || replacementCandidates[replacementSessionID] != nil
        {
            replacementSeekTargets[replacementSessionID] = bounded
        }
        currentTime = bounded
        emit(.positionChanged(bounded))
    }

    public func setVolume(_ value: Double) {
        volume = min(max(value, 0), 100)
        presentation.setVolume(Float(volume / 100), muted: isMuted)
        emit(.volumeChanged(volume))
    }

    public func setMuted(_ value: Bool) {
        isMuted = value
        presentation.setVolume(Float(volume / 100), muted: value)
        emit(.muteChanged(value))
    }

    public func setPlaybackSpeed(_ value: Double) {
        guard value.isFinite, (0.25...4).contains(value) else { return }
        playbackSpeed = Float(value)
        // The deterministic core applies the transport rate. This preference
        // also survives native replacement/rollback and direct wake recovery.
        emit(.speedChanged(value))
    }

    public func selectAudioTrack(_ id: Int64?) {
        guard let url = currentURL else { return }
        let index = id.flatMap(streamIndex)
        guard id == nil || index.flatMap({ candidate in
            session?.mediaInfo.audioStreams.first(where: { $0.index == candidate })
        }) != nil else {
            emit(.diagnostic("[native-track] Rejected invalid audio track ID"), identity: nil)
            return
        }
        guard index != selectedAudioIndex else { return }
        selectedAudioIndex = index
        replaceSessionForTrackChange(url: url)
    }

    public func selectSubtitleTrack(_ id: Int64?) {
        guard let url = currentURL else { return }
        if id == nil {
            guard subtitleSource != .off else { return }
            subtitleSource = .off
            replaceSessionForTrackChange(url: url)
            return
        }
        if let id, let requested = preparedExternalSubtitle?.source(for: id) {
            guard subtitleSource != requested else { return }
            subtitleSource = requested
            replaceSessionForTrackChange(url: url)
            return
        }
        let index = id.flatMap(streamIndex)
        guard let index,
              session?.mediaInfo.subtitleStreams.contains(where: {
                  $0.index == index && $0.subtitleCapability?.isPlayable == true
              }) == true
        else {
            emit(.diagnostic(
                "[native-subtitle] Rejected invalid or unsupported subtitle track ID"
            ), identity: nil)
            return
        }
        let requested = NativeSubtitleSource.embedded(streamIndex: index)
        guard selectedSubtitleIndex != index else {
            subtitleSource = requested
            setBitmapSubtitleFilter(false)
            return
        }
        subtitleSource = requested
        replaceSessionForTrackChange(url: url)
    }

    public func selectAudioOutputDevice(_ id: String?) {
        guard !isShutdown else { return }
        let requested = id == "auto" ? nil : id
        let selected = availableAudioDevices.contains { $0.id == requested } ? requested : nil
        do { try presentation.setAudioOutputDevice(selected) }
        catch { emit(.audioOutputSelectionFailed("Could not select audio output: \(error.localizedDescription)"), identity: nil) }
        updateAudioOutputCapacity(requestRecovery: false)
        publishAudioDevices()
    }

    private func updateAudioDevices(_ catalog: NativeAudioDeviceCatalog) {
        guard !isShutdown, catalog.isValid else { return }
        if catalog.lostPrivateOutput(comparedTo: audioDeviceCatalog, selectedID: presentation.audioOutputDeviceID), session != nil {
            emit(.transportRequested(playing: false))
            emit(.diagnostic("[audio] Headphones disconnected; playback paused."), identity: nil)
        }
        audioDeviceCatalog = catalog
        let devices = catalog.devices
        if let selected = presentation.audioOutputDeviceID,
           !devices.contains(where: { $0.id == selected }) {
            do {
                try presentation.setAudioOutputDevice(nil)
                emit(.diagnostic("[audio] Selected output disconnected; using System Default."), identity: nil)
            } catch {
                emit(.audioOutputSelectionFailed("Could not restore default audio output: \(error.localizedDescription)"), identity: nil)
            }
        }
        updateAudioOutputCapacity(requestRecovery: true)
        publishAudioDevices()
    }

    private func updateAudioOutputCapacity(requestRecovery: Bool) {
        let channels = audioDeviceCatalog.capacity(selectedID: presentation.audioOutputDeviceID)
        let changed = presentation.audioOutputCapacity.update(channels: channels)
        guard changed, requestRecovery, session != nil else { return }
        let time = presentation.currentTime
        guard time.isNumeric else { return }
        // Reuse the core-owned route transaction so queued PCM from the old
        // layout is discarded and decoded again with the new capability.
        emit(.audioOutputChanged(max(0, time.seconds)))
    }

    private func publishAudioDevices() {
        let devices = NativeAudioDeviceMonitor.selectionSnapshot(
            availableAudioDevices, selectedID: presentation.audioOutputDeviceID
        )
        guard devices != lastPublishedAudioDevices else { return }
        lastPublishedAudioDevices = devices
        emit(.audioDevicesChanged(devices), identity: nil)
    }
    public func loadExternalSubtitle(_ url: URL, select: Bool) {
        guard select else {
            emit(.diagnostic(
                "[native-subtitle] Loading an unselected additional sidecar is unsupported; the selected track was preserved."
            ), identity: nil)
            return
        }
        guard externalSubtitleRequestRevision < UInt64.max else {
            emit(.failed("External subtitle request identity exhausted"))
            return
        }
        externalSubtitleRequestRevision += 1
        let revision = externalSubtitleRequestRevision
        let sessionID = activeSessionID
        legacyExternalSubtitleTask?.cancel()
        let encoding = subtitleFallbackEncoding
        legacyExternalSubtitleTask = Task { [weak self] in
            let result = await SourcePreparationExecutor.shared.result { checkCancellation in
                try checkCancellation()
                return try PreparedExternalSubtitle.prepare(url: url, encoding: encoding)
            }
            guard let self,
                  !Task.isCancelled,
                  !self.isShutdown,
                  revision == self.externalSubtitleRequestRevision,
                  sessionID == self.activeSessionID
            else { return }
            do {
                let prepared = try result.get()
                self.preparedExternalSubtitle = prepared
                self.subtitleSource = prepared.source
                if let mediaURL = self.currentURL {
                    self.replaceSessionForTrackChange(url: mediaURL)
                }
                self.emit(.diagnostic("[native-subtitle] Loaded \(url.lastPathComponent)."), identity: nil)
            } catch {
                self.emit(.diagnostic("[native-subtitle] \(error.localizedDescription)"), identity: nil)
            }
            self.legacyExternalSubtitleTask = nil
        }
    }

    private func installExternalSubtitle(
        _ url: URL,
        effectID: PlaybackEffectID
    ) {
        guard externalSubtitleRequestRevision < UInt64.max else {
            finishOperation(
                effectID: effectID,
                succeeded: false,
                code: "externalSubtitleIdentityExhausted"
            )
            return
        }
        externalSubtitleRequestRevision += 1
        let revision = externalSubtitleRequestRevision
        let sessionID = activeSessionID
        let encoding = subtitleFallbackEncoding
        operationWorkTasks[effectID] = Task { [weak self] in
            let result = await SourcePreparationExecutor.shared.result { checkCancellation in
                try checkCancellation()
                return try PreparedExternalSubtitle.prepare(url: url, encoding: encoding)
            }
            guard let self else { return }
            guard !self.isShutdown,
                  revision == self.externalSubtitleRequestRevision,
                  sessionID == self.activeSessionID
            else {
                self.finishOperation(
                    effectID: effectID,
                    succeeded: false,
                    code: "externalSubtitleCancelled"
                )
                return
            }
            do {
                let prepared = try result.get()
                self.preparedExternalSubtitle = prepared
                self.subtitleSource = prepared.source
                guard let mediaURL = self.currentURL else {
                    self.finishOperation(
                        effectID: effectID,
                        succeeded: false,
                        code: "externalSubtitleRequiresActiveMedia"
                    )
                    return
                }
                self.replaceSessionForTrackChange(url: mediaURL)
            } catch {
                self.finishOperation(
                    effectID: effectID,
                    succeeded: false,
                    code: "externalSubtitleInstallFailed"
                )
            }
        }
    }

    public func setAudioDelay(_ value: TimeInterval) {
        guard let session, session.activeAudioStream != nil,
              let identity = activeIdentity, let url = currentURL,
              let request = MediaLoadRequest(source: .localFile(url), origin: .userSelected) else { return }
        let delay = AudioDelayTimeline.bounded(value)
        guard delay != session.audioDelay || !replacementTasks.isEmpty
            || deferredReplacementRequest != nil || pendingCommittedReplacement != nil else { return }
        beginReplaceSession(for: PlaybackRuntimeLoadRequest(media: request, identity: identity),
                            seekTo: currentTime, emitLoaded: false, preserveOldUntilPrepared: true,
                            audioDelay: delay)
    }
    public func setSubtitleDelay(_ value: TimeInterval) {
        setSubtitlePipelineDelay(min(max(value, -10), 10))
        refreshPictureInPictureSubtitleFrame()
        emit(.subtitleDelayChanged(subtitles.delay))
    }

    public func setHardwareDecodingPolicy(_ policy: HardwareDecodingPolicy) {
        preferHardware = policy != .off
        if policy == .compatibility {
            emit(.diagnostic(
                "[native-decoder] Compatibility currently uses the normal VideoToolbox path with software fallback."
            ), identity: nil)
        }
    }

    public func setVideoScaleMode(_ mode: VideoScaleMode) {
        videoAdjustments.scaleMode = mode
        updateVideoPresentationGeometry()
    }

    public func setVideoAspect(_ aspect: String?) {
        guard aspect == nil || VideoPresentationGeometry.ratio(aspect) != nil else { return }
        videoAdjustments.aspectRatio = aspect
        updateVideoPresentationGeometry()
    }

    private func updateVideoPresentationGeometry() {
        surfaceHost?.videoAdjustments = videoAdjustments
        pictureInPictureSubtitleCompositor?.setVideoAdjustments(videoAdjustments)
        session?.videoAdjustments = videoAdjustments
        session?.renderSubtitles()
    }

    public func setVideoColorSamplingEnabled(_ enabled: Bool) {
        presentation.setVideoColorSamplingEnabled(enabled)
    }
    public func setVideoCrop(_ crop: String?) {
        guard crop == nil || VideoPresentationGeometry.ratio(crop) != nil else { return }
        videoAdjustments.crop = crop
        updateVideoPresentationGeometry()
    }
    public func setVideoRotation(_ rotation: Int) { unsupported("video rotation override") }
    public func setDeinterlace(_ enabled: Bool) { unsupported("manual deinterlacing override") }
    public func setVideoEqualizer(_ adjustments: VideoAdjustmentState) {
        unsupported("video equalizer")
    }

    public func setPictureInPictureActive(_ active: Bool) {
        guard capabilities.contains(.pictureInPicture) else {
            unsupported("Picture in Picture")
            return
        }
        let hasSubtitleSource: Bool = switch subtitleSource {
        case .off:
            false
        case .automaticEmbedded:
            session?.activeSubtitleStream != nil
        case .embedded, .external, .externalBitmap:
            true
        }
        if active,
           (hasSubtitleSource || videoAdjustments.aspectRatio != nil || videoAdjustments.crop != nil),
           let pictureInPictureSubtitleCompositor
        {
            startSubtitleCompositedPiP(compositor: pictureInPictureSubtitleCompositor)
            return
        }
        if !active, subtitleCompositedPiPRequested {
            pictureInPictureController?.setActive(false)
            if pictureInPictureController?.state.isActive != true {
                endSubtitleCompositedPiPSession()
            }
            return
        }
        if active, hasSubtitleSource {
            emit(.diagnostic(
                "[native-pip] Subtitles remain in the main AppKit overlay and are not composited into the system Picture in Picture window."
            ), identity: nil)
        }
        pictureInPictureController?.setActive(active)
    }

    public func setPictureInPictureRestoreRequestHandler(
        _ handler: PictureInPictureRestoreRequestHandler?
    ) {
        pictureInPictureRestoreRequestHandler = handler
    }

    private func startSubtitleCompositedPiP(
        compositor: PiPSubtitleCompositor
    ) {
        guard !subtitleCompositedPiPRequested else { return }
        guard let eligibility = compositor.latestEligibility else {
            emit(.diagnostic(
                "[native-pip-subtitles] No decoded frame is available; using video-only PiP."
            ), identity: nil)
            pictureInPictureController?.setActive(true)
            return
        }
        guard case .supported = eligibility else {
            if case let .videoOnly(reason) = eligibility {
                emit(.diagnostic(
                    "[native-pip-subtitles] \(reason.diagnosticDescription) Using video-only PiP."
                ), identity: nil)
            }
            pictureInPictureController?.setActive(true)
            return
        }
        guard let surfaceHost else {
            emit(.diagnostic(
                "[native-pip-subtitles] Could not resolve the live player view; using video-only PiP."
            ), identity: nil)
            pictureInPictureController?.setActive(true)
            return
        }
        let initialSize = compositor.setViewportSize(nil)
            ?? compositor.setViewportSize(surfaceHost.videoViewportSize)
        guard let displayLayerHost = PiPSubtitleDisplayLayerHost(
            displayLayer: compositor.displayLayer,
            parentView: surfaceHost.view
        )
        else {
            emit(.diagnostic(
                "[native-pip-subtitles] Could not host the composed display layer; using video-only PiP."
            ), identity: nil)
            pictureInPictureController?.setActive(true)
            return
        }
        pictureInPictureDisplayLayerHost = displayLayerHost
        if let initialSize {
            displayLayerHost.setSize(initialSize)
        }
        guard presentation.attachPictureInPictureRenderer(compositor.renderer) else {
            displayLayerHost.tearDown()
            pictureInPictureDisplayLayerHost = nil
            emit(.diagnostic(
                "[native-pip-subtitles] Could not attach the composed renderer; using video-only PiP."
            ), identity: nil)
            pictureInPictureController?.setActive(true)
            return
        }

        subtitleCompositedPiPRequested = true
        emit(.diagnostic(
            "[native-pip-subtitles] Starting PiP with a separate SDR Metal-composited sample stream."
        ), identity: nil)
        compositor.start(
            onFirstSample: { [weak self, weak compositor] result in
                Task { @MainActor [weak self, weak compositor] in
                    guard let self,
                          let compositor,
                          self.subtitleCompositedPiPRequested
                    else {
                        return
                    }
                    switch result {
                    case .success:
                        self.pictureInPictureController?.rebind(
                            displayLayer: compositor.displayLayer
                        )
                        self.pictureInPictureController?.startWhenPossible()
                    case let .failure(error):
                        self.emit(.diagnostic(
                            "[native-pip-subtitles] Composition failed before PiP start; using video-only PiP: \(error.localizedDescription)"
                        ), identity: nil)
                        self.endSubtitleCompositedPiPSession()
                        self.pictureInPictureController?.setActive(true)
                    }
                }
            },
            onFailure: { [weak self] error in
                Task { @MainActor [weak self] in
                    guard let self, subtitleCompositedPiPRequested else {
                        return
                    }
                    emit(.diagnostic(
                        "[native-pip-subtitles] Composition stopped; switching to video-only PiP: \(error.localizedDescription)"
                    ), identity: nil)
                    restartVideoOnlyPiPAfterCompositionFailure = true
                    pictureInPictureController?.setActive(false)
                    if pictureInPictureController?.state.isActive != true {
                        endSubtitleCompositedPiPSession()
                        restartVideoOnlyPiPAfterCompositionFailure = false
                        pictureInPictureController?.setActive(true)
                    }
                }
            }
        )
    }

    private func endSubtitleCompositedPiPSession(rebindController: Bool = true) {
        guard subtitleCompositedPiPRequested,
              let pictureInPictureSubtitleCompositor
        else {
            return
        }
        setSubtitleCompositedPiPPresentationActive(false)
        subtitleCompositedPiPRequested = false
        pictureInPictureSubtitleCompositor.stop()
        if let pictureInPictureSubtitles {
            let mainCounters = subtitles.counters()
            let pipCounters = pictureInPictureSubtitles.counters()
            emit(.diagnostic(
                "[native-pip-subtitles] independent-libass "
                    + "main-events=\(subtitles.eventCount) "
                    + "main-libass-frames=\(mainCounters.libassFrames) "
                    + "main-overlay-commits=\(mainCounters.overlayCommits) "
                    + "pip-events=\(pictureInPictureSubtitles.eventCount) "
                    + "pip-libass-frames=\(pipCounters.libassFrames)"
            ), identity: nil)
        }
        presentation.detachPictureInPictureRenderer(
            pictureInPictureSubtitleCompositor.renderer
        )
        surfaceHost?.pictureInPictureViewportSize = nil
        if rebindController {
            pictureInPictureController?.rebind(
                displayLayer: presentation.video.displayLayer
            )
        }
        pictureInPictureDisplayLayerHost?.tearDown()
        pictureInPictureDisplayLayerHost = nil
    }

    private func stopPictureInPictureForLifecycleChange() {
        pictureInPictureController?.setActive(false)
        if subtitleCompositedPiPRequested,
           pictureInPictureController?.state.isActive != true
        {
            endSubtitleCompositedPiPSession()
        }
    }

    public func pausedReadbackDiagnostic() -> NativePausedReadbackDiagnostic {
        let buffer = presentation.video.renderer.displayedPixelBuffer()
        let frame = buffer.flatMap { presentation.video.identity(for: $0) }
        return NativePausedReadbackDiagnostic(
            hasPixelBuffer: buffer != nil,
            currentGeneration: session?.currentGeneration,
            displayedGeneration: frame?.generation,
            displayedPTS: frame?.time,
            rendererRate: presentation.rate,
            seekInProgress: session?.seekInProgress ?? false,
            isCurrent: session != nil && presentation.rate == 0
                && session?.seekInProgress == false
                && frame?.generation == session?.currentGeneration
        )
    }

    public func frameStepTarget(direction: Int) async throws -> TimeInterval? {
        guard let session, let url = currentURL, presentation.rate == 0 else {
            throw PresentationError("Pause the video before stepping.")
        }
        let identity = activeSessionID
        let deadline = ContinuousClock().now.advanced(by: .seconds(8))
        var displayed: SampleBufferVideoPresenter.FrameIdentity?
        while ContinuousClock().now < deadline {
            try Task.checkCancellation()
            guard activeSessionID == identity, presentation.rate == 0 else { throw CancellationError() }
            if !session.seekInProgress,
               let buffer = presentation.video.renderer.displayedPixelBuffer(),
               let candidate = presentation.video.identity(for: buffer),
               candidate.generation == session.currentGeneration {
                displayed = candidate
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard let displayed else { throw PresentationError("The displayed frame is not available yet.") }
        if let target = presentation.video.adjacentTime(to: displayed, direction: direction) { return target }
        let generation = session.currentGeneration
        let target = try await frameStepReader.target(url: url, position: displayed.time, direction: direction)
        guard activeSessionID == identity, self.session?.currentGeneration == generation,
              presentation.rate == 0 else { throw CancellationError() }
        return target
    }

    public func execute(_ command: SuperplayrCore.PlaybackCommand) async throws {
        guard case let .screenshot(url, includeSubtitles) = command else {
            throw UnsupportedPlaybackCapabilityError(String(describing: command))
        }
        guard url.isFileURL, let session, !session.seekInProgress,
              let surfaceHost, presentation.rate == 0,
              let buffer = presentation.video.renderer.displayedPixelBuffer(),
              let frameIdentity = presentation.video.identity(for: buffer),
              frameIdentity.generation == session.currentGeneration,
              let geometry = session.currentVideoGeometry else {
            throw PresentationError("Wait for the video frame to appear before capturing it.")
        }
        let identity = activeSessionID
        let viewSize = surfaceHost.videoViewportSize
        let scale = min(surfaceHost.view.window?.backingScaleFactor ?? 1,
            8192 / max(viewSize.width, viewSize.height, 1),
            sqrt(33_554_432 / max(viewSize.width * viewSize.height, 1)))
        let size = CGSize(width: floor(viewSize.width * scale), height: floor(viewSize.height * scale))
        let viewport = VideoPresentationGeometry(sourceSize: geometry.displaySize,
            bounds: CGRect(origin: .zero, size: size), adjustments: videoAdjustments).imageRect
        let regions = includeSubtitles ? subtitles.renderedRegions(
            at: CMTime(seconds: frameIdentity.time, preferredTimescale: 60_000),
            viewport: viewport, videoSize: geometry.displaySize) : []
        let capture = NativeScreenshot(buffer: buffer, displaySize: geometry.displaySize,
            rotation: geometry.rotationDegrees, mirrored: surfaceHost.isHorizontallyMirrored,
            size: size, adjustments: videoAdjustments, regions: regions)
        let data = try await Task.detached(priority: .userInitiated) { try capture.png() }.value
        guard identity == activeSessionID, session.currentGeneration == frameIdentity.generation else { throw CancellationError() }
        try await Task.detached(priority: .utility) { try data.write(to: url, options: .atomic) }.value
    }

    @discardableResult
    public func resumeAfterWake(position: TimeInterval, playing: Bool) -> Int? {
        guard let session else { return nil }
        currentTime = max(position, 0)
        let nativeGeneration = session.seek(
            to: currentTime,
            exact: true,
            resumeRate: playing ? playbackSpeed : 0
        )
        desiredPlaying = playing
        return nativeGeneration
    }

    public func shutdown() async {
        _ = await shutdownAndReport()
    }

    private func shutdownAndReport() async -> Bool {
        if let shutdownResult { return shutdownResult }
        if let shutdownTask { return await shutdownTask.value }
        isShutdown = true
        audioDeviceMonitor?.stop()
        audioDeviceMonitor = nil
        let task = Task { @MainActor [weak self] in
            guard let self else { return false }
            return await self.performPhysicalShutdown()
        }
        shutdownTask = task
        let result = await task.value
        shutdownTask = nil
        shutdownResult = result
        return result
    }

    private func performPhysicalShutdown() async -> Bool {
        pendingLoad = nil
        desiredPlaying = false
        pictureInPictureRestoreRequestHandler = nil

        let terminatingExternalSubtitleTask = legacyExternalSubtitleTask
        terminatingExternalSubtitleTask?.cancel()
        legacyExternalSubtitleTask = nil
        deferredReplacementTask?.cancel()
        deferredReplacementTask = nil
        deferredReplacementRequest = nil
        cancelAllReplacementTasks()

        let shutdownTransaction = operations.active(.shutdown)
        let removedOperations = operations.removeAll()
        if let shutdownTransaction {
            _ = operations.begin(
                shutdownTransaction,
                supersessionCode: "shutdownSuperseded"
            )
        }
        for transaction in removedOperations where transaction.kind != .shutdown {
            cancel(transaction.effect, code: "physicalShutdownStarted")
        }

        let shutdownEffectID = shutdownTransaction?.effectID
        let terminatingOperationDeadlines = operationDeadlineTasks.compactMap {
            effectID, task in effectID == shutdownEffectID ? nil : task
        }
        operationDeadlineTasks = operationDeadlineTasks.filter {
            effectID, _ in effectID == shutdownEffectID
        }
        for task in terminatingOperationDeadlines {
            task.cancel()
        }
        let terminatingOperationWork = Array(operationWorkTasks.values)
        operationWorkTasks.removeAll()
        for task in terminatingOperationWork {
            task.cancel()
        }

        let terminatingReplacements = Array(replacementTasks.values)
        for task in terminatingReplacements {
            await task.value
        }
        replacementTasks.removeAll()
        await terminatingExternalSubtitleTask?.value
        for task in terminatingOperationWork {
            await task.value
        }

        if subtitleCompositedPiPRequested {
            await pictureInPictureController?.stopAndWaitIfActive()
        }
        endSubtitleCompositedPiPSession(rebindController: false)
        pictureInPictureController?.shutdown()
        pendingPreviewSeek = nil
        previewSeekInFlight = false

        var terminatingSessions:
            [(session: MediaSession, metadata: RuntimeSessionMetadata?, releasesPresentation: Bool)]
            = []
        var terminatingSessionIdentities: Set<ObjectIdentifier> = []
        func appendTerminatingSession(
            _ terminatingSession: MediaSession?,
            metadata: RuntimeSessionMetadata?,
            releasesPresentation: Bool
        ) {
            guard let terminatingSession else { return }
            let identity = ObjectIdentifier(terminatingSession)
            guard terminatingSessionIdentities.insert(identity).inserted else { return }
            terminatingSessions.append((
                session: terminatingSession,
                metadata: metadata,
                releasesPresentation: releasesPresentation
            ))
        }

        appendTerminatingSession(
            session,
            metadata: activeRuntimeSession,
            releasesPresentation: true
        )
        if let pendingCommittedReplacement {
            appendTerminatingSession(
                pendingCommittedReplacement.candidate,
                metadata: pendingCommittedReplacement.candidateMetadata,
                releasesPresentation: true
            )
            appendTerminatingSession(
                pendingCommittedReplacement.oldSession,
                metadata: pendingCommittedReplacement.oldMetadata,
                releasesPresentation: false
            )
        }
        for (sessionID, candidate) in replacementCandidates {
            appendTerminatingSession(
                candidate,
                metadata: replacementCandidateMetadata[sessionID],
                releasesPresentation: false
            )
        }

        session = nil
        activeRuntimeSession = nil
        pendingCommittedReplacement = nil
        replacementCandidates.removeAll()
        replacementCandidateMetadata.removeAll()
        replacementConstructionCancellations.removeAll()
        replacementSeekTargets.removeAll()
        latestReplacementSessionID = nil
        cancelledReplacementSessionIDs.removeAll()

        for item in terminatingSessions {
            item.session.setSubtitlePresentationAuthorityEnabled(false)
            releaseLogically(item.metadata)
            item.session.stop(
                releasesPresentation: item.releasesPresentation
            )
        }

        var clean = true
        let terminationResults = await withTaskGroup(
            of: (Int, Bool).self,
            returning: [(Int, Bool)].self
        ) { group in
            for (index, item) in terminatingSessions.enumerated() {
                group.addTask {
                    (index, item.session.waitForShutdown())
                }
            }
            var results: [(Int, Bool)] = []
            for await result in group {
                results.append(result)
            }
            return results
        }
        for (index, didTerminate) in terminationResults {
            clean = clean && didTerminate
            if !didTerminate {
                emit(.diagnostic("[native-shutdown] Worker shutdown timed out."), identity: nil)
            } else if let metadata = terminatingSessions[index].metadata {
                _ = runtimeMetadata.leases.observePhysicalRelease(
                    metadata.workerLease
                )
            }
        }

        let terminatingRetirements = Array(retirementTasks.values)
        for task in terminatingRetirements {
            clean = await task.value && clean
        }
        retirementTasks.removeAll()

        clearSubtitlePipelines()
        surfaceHost?.shutdown()
        surfaceHost = nil
        releaseApplicationGraphBorrowsAndLeases()
        runtimeMetadata.callbackTombstone.install()
        terminateSubtitlePipelines()
        presentation.terminate()
        activeIdentity = nil
        emit(.shutdownCompleted, identity: nil)
        return clean
    }

    func updateDisplay(_ capabilities: NativeDisplayCapabilities) {
        emit(.displayChanged(DisplayOutputStatus(
            name: capabilities.name,
            maximumFramesPerSecond: surfaceHost?.view.window?.screen?.maximumFramesPerSecond,
            maximumPotentialEDR: capabilities.potentialEDRHeadroom,
            isEDREnabled: capabilities.currentEDRHeadroom > 1,
            colorSpaceName: surfaceHost?.view.window?.screen?.colorSpace?.localizedName
        )))
    }

    func refreshPictureInPictureState() {
        pictureInPictureController?.publishCurrentState()
    }

    private func beginReplaceSession(
        for request: PlaybackRuntimeLoadRequest,
        seekTo: TimeInterval?,
        emitLoaded: Bool,
        preserveOldUntilPrepared: Bool = false,
        audioDelay: TimeInterval? = nil
    ) {
        if pendingMetadataPublicationSessionID != nil {
            cancelOperation(kind: .preroll, code: "prerollSupersededByOpen")
            pendingMetadataPublicationSessionID = nil
        }
        let requestedAudioIndex = selectedAudioIndex
        let requestedSubtitleSource = subtitleSource
        let requestedExternalSubtitle = preparedExternalSubtitle
        cancelAllReplacementTasks()
        if let pendingCommittedReplacement {
            failCommittedReplacementBeforePreroll(
                sessionID: pendingCommittedReplacement.candidateSessionID,
                code: "nativeCandidateSupersededBeforePreroll"
            )
            if !emitLoaded {
                selectedAudioIndex = requestedAudioIndex
                subtitleSource = requestedSubtitleSource
                preparedExternalSubtitle = requestedExternalSubtitle
            }
        }
        preparePictureInPictureSubtitleInfrastructureIfNeeded()
        guard canAdmitCandidateSubtitlePipelines else {
            deferReplacement(DeferredReplacementRequest(
                request: request,
                seekTo: seekTo,
                emitLoaded: emitLoaded,
                preserveOldUntilPrepared: preserveOldUntilPrepared,
                audioDelay: audioDelay
            ))
            return
        }
        deferredReplacementRequest = nil
        let oldSession = session
        let oldRuntimeSession = activeRuntimeSession
        if !preserveOldUntilPrepared {
            releaseLogically(oldRuntimeSession)
            oldSession?.stop()
            session = nil
            activeRuntimeSession = nil
            presentation.flush(at: .zero)
        }
        let replacementMetadata = runtimeMetadata.beginSession()
        let replacementSessionID: PlaybackSessionID
        if case .playback(let sessionID, _, _) = replacementMetadata.authority {
            replacementSessionID = sessionID
        } else {
            preconditionFailure("runtime session must carry playback authority")
        }
        latestReplacementSessionID = replacementSessionID
        replacementSeekTargets[replacementSessionID] = seekTo
        if !preserveOldUntilPrepared {
            activeSessionID = replacementSessionID
            activeRuntimeSession = replacementMetadata
        }
        for kind in [
            NativeOperationKind.open,
            .trackReplacement,
            .externalSubtitle,
        ] {
            if let transaction = operations.active(kind) {
                correlateOperation(
                    effectID: transaction.effectID,
                    nativeSessionID: replacementSessionID
                )
            }
        }
        replacementLifecycle.begin(
            sessionID: replacementSessionID.rawValue,
            sourcePath: request.media.source.url.path
        )
        pendingPreviewSeek = nil
        previewSeekInFlight = false
        let candidateSubtitleSource: NativeSubtitleSource =
            emitLoaded ? .automaticEmbedded : subtitleSource
        let candidatePipelines: (
            main: SubtitlePipeline,
            pictureInPicture: SubtitlePipeline?
        )
        do {
            candidatePipelines = try makeCandidateSubtitlePipelines(
                source: candidateSubtitleSource
            )
        } catch {
            finishOperation(
                kind: .open,
                nativeSessionID: replacementSessionID,
                succeeded: false,
                code: "subtitlePipelinePreparationFailed"
            )
            finishOperation(
                kind: .trackReplacement,
                nativeSessionID: replacementSessionID,
                succeeded: false,
                code: "subtitlePipelinePreparationFailed"
            )
            finishOperation(
                kind: .externalSubtitle,
                nativeSessionID: replacementSessionID,
                succeeded: false,
                code: "subtitlePipelinePreparationFailed"
            )
            releaseLogically(replacementMetadata)
            _ = runtimeMetadata.leases.observePhysicalRelease(
                replacementMetadata.workerLease
            )
            if !preserveOldUntilPrepared {
                activeRuntimeSession = nil
            }
            emit(.typedFailure(PlaybackFailure(
                domain: .presentation,
                stage: .configure,
                stableCode: "subtitlePipelinePreparationFailed",
                recoverability: .retryable
            )))
            return
        }
        let trackSelectionPreferences = trackSelectionPreferences
        let explicitlySelectsSubtitle: Bool
        if case .subtitle? = operations.active(.trackReplacement)?.requestedState {
            explicitlySelectsSubtitle = true
        } else { explicitlySelectsSubtitle = false }
        let bitmapForcedOnlyOverride = !emitLoaded && !explicitlySelectsSubtitle
            && candidateSubtitleSource == oldSession?.activeSubtitleSource
            ? oldSession?.subtitles.forcesBitmapEventsOnly : nil
        let selectedAudioIndex = emitLoaded ? nil : selectedAudioIndex
        let audioDelay = emitLoaded ? 0 : audioDelay ?? oldSession?.audioDelay ?? 0
        let subtitleSource = candidateSubtitleSource
        let externalSubtitleData = emitLoaded ? nil : externalSubtitleData
        let externalSubtitlePreparation: PreparedExternalSubtitle?
        if !emitLoaded, case .externalBitmap = subtitleSource {
            externalSubtitlePreparation = preparedExternalSubtitle
        } else { externalSubtitlePreparation = nil }
        let preferHardware = preferHardware
        let softwareVideoOutputPolicy = softwareVideoOutputPolicy
        let seekPrerollFrameSkippingEnabled = seekPrerollFrameSkippingEnabled
        let softwareSeekAccelerationEnabled = softwareSeekAccelerationEnabled
        let videoFrameQueueCapacity = videoFrameQueueCapacity
        let reservesVideoPipelineCapacity = reservesVideoPipelineCapacity
        let videoPipelineCapacityOverride = videoPipelineCapacityOverride
        let usesFairDemuxDispatch = usesFairDemuxDispatch
        let softwarePlanarOutputMaximumBufferCount =
            softwarePlanarOutputMaximumBufferCount
        let presentation = presentation
        let subtitles = candidatePipelines.main
        let pictureInPictureSubtitles = candidatePipelines.pictureInPicture
        let observationCoalescer = RuntimeObservationCoalescer()
        let replacementLifecycle = replacementLifecycle
        let constructionCancellation = FFmpegInputCancellationSignal()
        replacementConstructionCancellations[replacementSessionID] =
            constructionCancellation

        let replacementTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result {
                    replacementLifecycle.record(
                        sessionID: replacementSessionID.rawValue,
                        stage: "media-session-initializing"
                    )
                    let softwareVideoOutputMode: SoftwareVideoOutputMode = switch softwareVideoOutputPolicy {
                    case .bgra:
                        .bgra
                    case .planarPreferred, .planarExperimental:
                        .planarPreferred(
                            rendererAttributes: presentation.video
                                .recommendedPixelBufferAttributes
                        )
                    }
                    try externalSubtitlePreparation?.verifyVersions()
                    let candidate = try MediaSession(
                        url: request.media.source.url,
                        presentation: presentation,
                        subtitles: subtitles,
                        pictureInPictureSubtitles: pictureInPictureSubtitles,
                        trackSelectionPreferences: trackSelectionPreferences,
                        bitmapForcedOnlyOverride: bitmapForcedOnlyOverride,
                        selectedAudioIndex: selectedAudioIndex,
                        audioDelay: audioDelay,
                        subtitleSource: subtitleSource,
                        preferHardware: preferHardware,
                        seekPrerollFrameSkippingEnabled: seekPrerollFrameSkippingEnabled,
                        softwareSeekAccelerationEnabled: softwareSeekAccelerationEnabled,
                        softwareVideoOutputMode: softwareVideoOutputMode,
                        videoFrameQueueCapacity: videoFrameQueueCapacity,
                        reservesVideoPipelineCapacity:
                            reservesVideoPipelineCapacity,
                        videoPipelineCapacityOverride:
                            videoPipelineCapacityOverride,
                        usesFairDemuxDispatch: usesFairDemuxDispatch,
                        softwarePlanarOutputMaximumBufferCount:
                            softwarePlanarOutputMaximumBufferCount,
                        constructionCancellation: constructionCancellation,
                        sessionID: replacementSessionID,
                        onLifecycleTrace: { stage in
                            replacementLifecycle.record(
                                sessionID: replacementSessionID.rawValue,
                                stage: stage
                            )
                        },
                        onSeekCompleted: { [weak self] generation, wasPreview in
                            Task { @MainActor [weak self] in
                                self?.seekDidComplete(
                                    generation: generation,
                                    wasPreview: wasPreview,
                                    sessionID: replacementSessionID
                                )
                            }
                        },
                        onSeekFailed: { [weak self] generation, failure in
                            Task { @MainActor [weak self] in
                                self?.seekDidFail(
                                    generation: generation,
                                    failure: failure,
                                    sessionID: replacementSessionID
                                )
                            }
                        },
                        onFailureObserved: { [weak self] failure in
                            Task { @MainActor [weak self] in
                                guard let self, self.activeSessionID == replacementSessionID else {
                                    return
                                }
                                self.emit(.typedFailure(failure))
                            }
                        },
                        onSubtitleDiagnostic: { [weak self] message in
                            Task { @MainActor [weak self] in
                                guard let self, self.activeSessionID == replacementSessionID else { return }
                                self.emit(.diagnostic(message))
                            }
                        },
                        onSynchronizationObserved: { [weak self] event in
                            Task { @MainActor [weak self] in
                                guard let self, self.activeSessionID == replacementSessionID else {
                                    return
                                }
                                self.emit(.synchronization(event))
                            }
                        },
                        onObservationRequested: { [weak self] request in
                            observationCoalescer.request(request) { [weak self] in
                                guard let self,
                                      self.activeSessionID == replacementSessionID
                                else { return }
                                self.lastObservationMetrics = observationCoalescer.snapshot()
                                self.consumeRuntimeObservation()
                            }
                        }
                    )
                    try externalSubtitlePreparation?.verifyVersions()
                    if case .external = subtitleSource {
                        guard let externalSubtitleData else {
                            throw PresentationError(
                                "Selected external subtitle has no prepared data"
                            )
                        }
                        try subtitles.installExternal(data: externalSubtitleData)
                        try pictureInPictureSubtitles?.installExternal(
                            data: externalSubtitleData
                        )
                    }
                    return candidate
                }
            }.value
            guard let self else {
                if case .success(let replacement) = result {
                    replacement.stop(releasesPresentation: false)
                }
                return
            }
            self.replacementTasks.removeValue(forKey: replacementSessionID)
            self.replacementConstructionCancellations.removeValue(
                forKey: replacementSessionID
            )
            if Task.isCancelled {
                self.cancelledReplacementSessionIDs.insert(replacementSessionID)
            }
            finishReplacingSession(
                result,
                request: request,
                seekTo: seekTo,
                emitLoaded: emitLoaded,
                metadata: replacementMetadata,
                sessionID: replacementSessionID,
                oldSession: oldSession,
                oldMetadata: oldRuntimeSession,
                preservedOldSession: preserveOldUntilPrepared
            )
        }
        replacementTasks[replacementSessionID] = replacementTask
    }

    private func finishReplacingSession(
        _ result: Result<MediaSession, Error>,
        request: PlaybackRuntimeLoadRequest,
        seekTo: TimeInterval?,
        emitLoaded: Bool,
        metadata: RuntimeSessionMetadata,
        sessionID: PlaybackSessionID,
        oldSession: MediaSession?,
        oldMetadata: RuntimeSessionMetadata?,
        preservedOldSession: Bool
    ) {
        replacementLifecycle.record(
            sessionID: sessionID.rawValue,
            stage: "finish-replacement-entered"
        )
        let replacementWasCancelled =
            cancelledReplacementSessionIDs.remove(sessionID) != nil
        guard !isShutdown,
              !replacementWasCancelled,
              latestReplacementSessionID == sessionID,
              preservedOldSession
                || (
                    sessionID == activeSessionID
                        && activeRuntimeSession?.workerLease == metadata.workerLease
                )
        else {
            replacementSeekTargets.removeValue(forKey: sessionID)
            if case .success(let staleSession) = result {
                staleSession.stop(releasesPresentation: false)
                releaseLogically(metadata)
                retireSession(staleSession, metadata: metadata)
            } else {
                releaseLogically(metadata)
                _ = runtimeMetadata.leases.observePhysicalRelease(metadata.workerLease)
            }
            if !preservedOldSession {
                retireSession(oldSession, metadata: oldMetadata)
            }
            return
        }
        let replacement: MediaSession
        switch result {
        case .success(let opened):
            replacement = opened
            replacementCandidates[sessionID] = opened
            replacementCandidateMetadata[sessionID] = metadata
            replacementLifecycle.record(
                sessionID: sessionID.rawValue,
                stage: "media-session-prepared"
            )
        case .failure(let error):
            replacementLifecycle.record(
                sessionID: sessionID.rawValue,
                stage: "media-session-preparation-failed"
            )
            finishOperation(
                kind: .open,
                nativeSessionID: sessionID,
                succeeded: false,
                code: "nativeSessionPreparationFailed"
            )
            finishOperation(
                kind: .trackReplacement,
                nativeSessionID: sessionID,
                succeeded: false,
                code: "nativeTrackReplacementFailed"
            )
            finishOperation(
                kind: .externalSubtitle,
                nativeSessionID: sessionID,
                succeeded: false,
                code: "nativeTrackReplacementFailed"
            )
            releaseLogically(metadata)
            _ = runtimeMetadata.leases.observePhysicalRelease(metadata.workerLease)
            if preservedOldSession, let oldSession {
                session = oldSession
                activeRuntimeSession = oldMetadata
                if case .playback(let oldSessionID, _, _) = oldMetadata?.authority {
                    activeSessionID = oldSessionID
                }
                selectedAudioIndex = oldSession.activeAudioStream?.index
                subtitleSource = oldSession.activeSubtitleSource
                emit(.diagnostic(
                    "[native-track] Replacement preparation failed; kept the previous track: \(error.localizedDescription)"
                ), identity: nil)
                emitTracks()
            } else {
                activeRuntimeSession = nil
                retireSession(oldSession, metadata: oldMetadata)
                emit(.failed(error.localizedDescription))
            }
            return
        }
        if preservedOldSession {
            if !emitLoaded, let previous = oldSession?.contentVersion,
               let candidate = replacement.contentVersion, previous != candidate {
                failPreparedReplacement(replacement, metadata: metadata, sessionID: sessionID,
                                        oldSession: oldSession, oldMetadata: oldMetadata,
                                        code: "sourceContentChangedDuringTrackReplacement")
                return
            }
            guard replacement.prepareForCommit() else {
                failPreparedReplacement(
                    replacement,
                    metadata: metadata,
                    sessionID: sessionID,
                    oldSession: oldSession,
                    oldMetadata: oldMetadata,
                    code: "nativeCandidatePreparationRejected"
                )
                return
            }
            replacementLifecycle.record(
                sessionID: sessionID.rawValue,
                stage: "candidate-decode-preroll-started"
            )
            replacementTasks[sessionID] = Task { [weak self] in
                guard let self else { return }
                let clock = ContinuousClock()
                let deadline = clock.now.advanced(by: .seconds(7))
                while !Task.isCancelled, clock.now < deadline {
                    if replacement.isPreparedForCommit {
                        self.replacementTasks.removeValue(forKey: sessionID)
                        self.commitReplacement(
                            replacement,
                            request: request,
                            seekTo: seekTo,
                            emitLoaded: emitLoaded,
                            metadata: metadata,
                            sessionID: sessionID,
                            oldSession: oldSession,
                            oldMetadata: oldMetadata,
                            oldWasPreserved: true
                        )
                        return
                    }
                    if replacement.snapshot().rendererFailure != nil {
                        break
                    }
                    try? await Task.sleep(for: .milliseconds(10))
                }
                if Task.isCancelled {
                    self.replacementTasks.removeValue(forKey: sessionID)
                    self.failPreparedReplacement(
                        replacement,
                        metadata: metadata,
                        sessionID: sessionID,
                        oldSession: oldSession,
                        oldMetadata: oldMetadata,
                        code: "nativeCandidatePreparationCancelled"
                    )
                    return
                }
                self.replacementTasks.removeValue(forKey: sessionID)
                self.failPreparedReplacement(
                    replacement,
                    metadata: metadata,
                    sessionID: sessionID,
                    oldSession: oldSession,
                    oldMetadata: oldMetadata,
                    code: "nativeCandidatePrerollFailed"
                )
            }
            return
        }
        commitReplacement(
            replacement,
            request: request,
            seekTo: seekTo,
            emitLoaded: emitLoaded,
            metadata: metadata,
            sessionID: sessionID,
            oldSession: oldSession,
            oldMetadata: oldMetadata,
            oldWasPreserved: false
        )
    }

    private func commitReplacement(
        _ replacement: MediaSession,
        request: PlaybackRuntimeLoadRequest,
        seekTo: TimeInterval?,
        emitLoaded: Bool,
        metadata: RuntimeSessionMetadata,
        sessionID: PlaybackSessionID,
        oldSession: MediaSession?,
        oldMetadata: RuntimeSessionMetadata?,
        oldWasPreserved: Bool
    ) {
        guard !isShutdown,
              latestReplacementSessionID == sessionID,
              cancelledReplacementSessionIDs.remove(sessionID) == nil
        else {
            replacementCandidates.removeValue(forKey: sessionID)
            replacementCandidateMetadata.removeValue(forKey: sessionID)
            replacementSeekTargets.removeValue(forKey: sessionID)
            replacement.stop(releasesPresentation: false)
            releaseLogically(metadata)
            retireSession(replacement, metadata: metadata)
            return
        }
        let rollbackExternalSubtitle = preparedExternalSubtitle
        let rollbackIdentity = activeIdentity
        let rollbackURL = currentURL
        let committedSeekTarget =
            replacementSeekTargets.removeValue(forKey: sessionID) ?? seekTo
        if oldWasPreserved {
            oldSession?.suspendPresentationForReplacement()
            oldSession?.setSubtitlePresentationAuthorityEnabled(false)
        }
        replacementCandidates.removeValue(forKey: sessionID)
        replacementCandidateMetadata.removeValue(forKey: sessionID)
        replacement.setSubtitlePresentationAuthorityEnabled(true)
        subtitles = replacement.subtitles
        pictureInPictureSubtitles =
            replacement.pictureInPictureSubtitlePipeline
        pictureInPictureSubtitleCompositor?.setSubtitlePipeline(
            replacement.pictureInPictureSubtitlePipeline
        )
        subtitleSource = replacement.activeSubtitleSource
        if emitLoaded {
            activeIdentity = request.identity
            preparedExternalSubtitle = nil
        }
        activeSessionID = sessionID
        activeRuntimeSession = metadata
        session = replacement
        replacementLifecycle.record(
            sessionID: sessionID.rawValue,
            stage: "old-session-retirement-dispatched"
        )
        replacementLifecycle.record(
            sessionID: sessionID.rawValue,
            stage: "presentation-membership-configuring"
        )
        let membershipFence = presentation.configureMembership(
            hasVideo: !replacement.mediaInfo.videoStreams.isEmpty,
            hasAudio: !replacement.mediaInfo.audioStreams.isEmpty
        )
        replacement.adoptPresentationFence(membershipFence)
        replacementLifecycle.record(
            sessionID: sessionID.rawValue,
            stage: "presentation-fence-adopted"
        )
        currentURL = request.media.source.url
        setSubtitleDiagnosticMediaIdentity(currentURL?.lastPathComponent)
        selectedAudioIndex = replacement.activeAudioStream?.index
        surfaceHost?.rotationDegrees = replacement.mediaInfo.videoStreams.first {
            $0.index == replacement.mediaInfo.selectedVideoIndex
        }?.rotationDegrees ?? 0
        surfaceHost?.isHorizontallyMirrored = replacement.mediaInfo.videoStreams.first {
            $0.index == replacement.mediaInfo.selectedVideoIndex
        }?.isMirrored ?? false
        surfaceHost?.sourceDisplaySize = replacement.mediaInfo.videoStreams.first {
            $0.index == replacement.mediaInfo.selectedVideoIndex
        }?.displaySize ?? .zero
        replacement.videoAdjustments = videoAdjustments
        surfaceHost?.videoAdjustments = videoAdjustments
        currentTime = committedSeekTarget ?? 0
        didEmitFirstFrameSubmitted = false
        lastObservationMetrics = RuntimeObservationMetricsSnapshot()
        lastSubtitlePacketRequestCount = 0
        didEmitPreroll = false
        didEmitEndOfFile = false
        lastSnapshot = nil
        lastEmittedVideoStatus = nil
        lastEmittedVideoAspectRatio = nil
        lastEmittedDecoderStatus = nil

        replacementLifecycle.record(
            sessionID: sessionID.rawValue,
            stage: "media-session-starting"
        )
        let started: Bool
        if oldWasPreserved {
            started = replacement.commitPrepared(rate: 0)
        } else {
            replacement.start(rate: 0)
            started = true
        }
        guard started else {
            failCommittedReplacementBeforePreroll(
                sessionID: sessionID,
                code: "nativeCandidateCommitRejected"
            )
            return
        }
        finishOperation(kind: .open, nativeSessionID: sessionID)
        if oldWasPreserved, let oldSession {
            pendingCommittedReplacement = PendingCommittedReplacement(
                candidateSessionID: sessionID,
                candidate: replacement,
                candidateMetadata: metadata,
                oldSession: oldSession,
                oldMetadata: oldMetadata,
                oldSubtitleSource: oldSession.activeSubtitleSource,
                oldAudioIndex: oldSession.activeAudioStream?.index,
                oldPreparedExternalSubtitle: rollbackExternalSubtitle,
                oldIdentity: rollbackIdentity,
                oldURL: rollbackURL,
                rollbackPosition: committedSeekTarget ?? currentTime
            )
        } else {
            retireSession(oldSession, metadata: oldMetadata)
            if latestReplacementSessionID == sessionID {
                latestReplacementSessionID = nil
            }
        }
        replacementLifecycle.record(
            sessionID: sessionID.rawValue,
            stage: "media-session-started"
        )
        if let committedSeekTarget, committedSeekTarget > 0 {
            replacement.seek(
                to: committedSeekTarget,
                exact: true,
                resumeRate: desiredPlaying ? playbackSpeed : 0
            )
        }
        presentation.setVolume(Float(volume / 100), muted: isMuted)
        pictureInPictureController?.updatePlayback(
            duration: replacement.mediaInfo.duration,
            isPaused: !desiredPlaying
        )
        if emitLoaded {
            pendingMetadataPublicationSessionID = sessionID
        } else {
            emitTracks()
        }
    }

    private func failPreparedReplacement(
        _ replacement: MediaSession,
        metadata: RuntimeSessionMetadata,
        sessionID: PlaybackSessionID,
        oldSession: MediaSession?,
        oldMetadata: RuntimeSessionMetadata?,
        code: String
    ) {
        replacementCandidates.removeValue(forKey: sessionID)
        replacementCandidateMetadata.removeValue(forKey: sessionID)
        replacementSeekTargets.removeValue(forKey: sessionID)
        if pendingMetadataPublicationSessionID == sessionID {
            pendingMetadataPublicationSessionID = nil
        }
        replacement.setSubtitlePresentationAuthorityEnabled(false)
        replacement.stop(releasesPresentation: false)
        releaseLogically(metadata)
        retireSession(replacement, metadata: metadata)
        guard !isShutdown, latestReplacementSessionID == sessionID else {
            if latestReplacementSessionID == sessionID {
                latestReplacementSessionID = nil
            }
            return
        }
        if latestReplacementSessionID == sessionID {
            latestReplacementSessionID = nil
        }
        if let oldSession {
            session = oldSession
            activeRuntimeSession = oldMetadata
            if case .playback(let oldSessionID, _, _) = oldMetadata?.authority {
                activeSessionID = oldSessionID
            }
            selectedAudioIndex = oldSession.activeAudioStream?.index
            subtitleSource = oldSession.activeSubtitleSource
        }
        finishOperation(
            kind: .open,
            nativeSessionID: sessionID,
            succeeded: false,
            code: code
        )
        finishOperation(
            kind: .trackReplacement,
            nativeSessionID: sessionID,
            succeeded: false,
            code: code
        )
        finishOperation(
            kind: .externalSubtitle,
            nativeSessionID: sessionID,
            succeeded: false,
            code: code
        )
        emit(.diagnostic(
            "[native-track] Candidate preparation failed; the committed session remained active."
        ), identity: nil)
        emitTracks()
    }

    private func finalizeCommittedReplacementIfNeeded(
        candidateSessionID: PlaybackSessionID
    ) {
        guard let pending = pendingCommittedReplacement,
              pending.candidateSessionID == candidateSessionID
        else { return }
        pendingCommittedReplacement = nil
        if latestReplacementSessionID == candidateSessionID {
            latestReplacementSessionID = nil
        }
        releaseLogically(pending.oldMetadata)
        pending.oldSession.stop(releasesPresentation: false)
        retireSession(pending.oldSession, metadata: pending.oldMetadata)
        _ = pending.candidate.requestTransport(playing: desiredPlaying, speed: playbackSpeed)
        pictureInPictureController?.updatePlayback(
            duration: pending.candidate.mediaInfo.duration,
            isPaused: !desiredPlaying
        )
        replacementLifecycle.record(
            sessionID: candidateSessionID.rawValue,
            stage: "candidate-preroll-committed-old-session-retired"
        )
    }

    private func failCommittedReplacementBeforePreroll(
        sessionID: PlaybackSessionID,
        code: String
    ) {
        guard let pending = pendingCommittedReplacement,
              pending.candidateSessionID == sessionID
        else {
            finishOperation(
                kind: .trackReplacement,
                nativeSessionID: sessionID,
                succeeded: false,
                code: code
            )
            finishOperation(
                kind: .externalSubtitle,
                nativeSessionID: sessionID,
                succeeded: false,
                code: code
            )
            return
        }
        pendingCommittedReplacement = nil
        if pendingMetadataPublicationSessionID == sessionID {
            pendingMetadataPublicationSessionID = nil
        }
        pending.candidate.setSubtitlePresentationAuthorityEnabled(false)
        pending.candidate.stop(releasesPresentation: true)
        releaseLogically(pending.candidateMetadata)
        retireSession(
            pending.candidate,
            metadata: pending.candidateMetadata
        )

        subtitleSource = pending.oldSubtitleSource
        selectedAudioIndex = pending.oldAudioIndex
        preparedExternalSubtitle = pending.oldPreparedExternalSubtitle
        activeIdentity = pending.oldIdentity
        currentURL = pending.oldURL
        subtitles = pending.oldSession.subtitles
        pictureInPictureSubtitles =
            pending.oldSession.pictureInPictureSubtitlePipeline
        pending.oldSession.setSubtitlePresentationAuthorityEnabled(true)
        pictureInPictureSubtitleCompositor?.setSubtitlePipeline(
            pending.oldSession.pictureInPictureSubtitlePipeline
        )
        session = pending.oldSession
        activeRuntimeSession = pending.oldMetadata
        if case .playback(let oldSessionID, _, _) = pending.oldMetadata?.authority {
            activeSessionID = oldSessionID
        }
        let rollbackFence = presentation.configureMembership(
            hasVideo: !pending.oldSession.mediaInfo.videoStreams.isEmpty,
            hasAudio: !pending.oldSession.mediaInfo.audioStreams.isEmpty
        )
        _ = pending.oldSession.resumePresentationAfterReplacementRollback(
            fence: rollbackFence,
            playing: false
        )
        _ = pending.oldSession.seek(
            to: pending.rollbackPosition,
            exact: true,
            resumeRate: desiredPlaying ? playbackSpeed : 0
        )
        _ = pending.oldSession.requestTransport(playing: desiredPlaying, speed: playbackSpeed)
        didEmitPreroll = true
        lastSnapshot = nil
        latestReplacementSessionID = nil
        finishOperation(
            kind: .preroll,
            nativeSessionID: sessionID,
            succeeded: false,
            code: code
        )
        finishOperation(
            kind: .trackReplacement,
            nativeSessionID: sessionID,
            succeeded: false,
            code: code
        )
        finishOperation(
            kind: .externalSubtitle,
            nativeSessionID: sessionID,
            succeeded: false,
            code: code
        )
        emit(.diagnostic(
            "[native-track] Candidate failed before preroll; restored the previous session."
        ), identity: nil)
        emitTracks()
    }

    private func replaceSessionForTrackChange(url: URL) {
        guard let identity = activeIdentity,
              let request = MediaLoadRequest(source: .localFile(url), origin: .userSelected)
        else { return }
        beginReplaceSession(
            for: PlaybackRuntimeLoadRequest(media: request, identity: identity),
            seekTo: currentTime,
            emitLoaded: false,
            preserveOldUntilPrepared: true
        )
    }

    private var canAdmitCandidateSubtitlePipelines: Bool {
        var requests: [(owner: SubtitleMemoryOwner, bytes: Int)] = [
            (.mainLibass, 32 * 1_024 * 1_024),
        ]
        if pictureInPictureSubtitleCompositor != nil {
            requests.append((.pictureInPictureLibass, 16 * 1_024 * 1_024))
        }
        return subtitleMemoryBudget.canAcquire(requests)
    }

    private func deferReplacement(_ request: DeferredReplacementRequest) {
        deferredReplacementAdmissionCount += 1
        deferredReplacementRequest = request
        guard deferredReplacementTask == nil else { return }

        deferredReplacementTask = Task { @MainActor [weak self] in
            let clock = ContinuousClock()
            // Track replacement operations have a 10-second deadline. Resolve
            // admission first so the caller receives the more specific failure
            // and the currently playing session remains authoritative.
            let deadline = clock.now.advanced(by: .seconds(9))
            while !Task.isCancelled, clock.now < deadline {
                guard let self, !self.isShutdown else { return }
                if self.canAdmitCandidateSubtitlePipelines,
                   let deferred = self.deferredReplacementRequest
                {
                    self.deferredReplacementRequest = nil
                    self.deferredReplacementTask = nil
                    self.beginReplaceSession(
                        for: deferred.request,
                        seekTo: deferred.seekTo,
                        emitLoaded: deferred.emitLoaded,
                        preserveOldUntilPrepared: deferred.preserveOldUntilPrepared,
                        audioDelay: deferred.audioDelay
                    )
                    return
                }
                try? await Task.sleep(for: .milliseconds(10))
            }

            guard let self, !Task.isCancelled, !self.isShutdown else { return }
            self.deferredReplacementRequest = nil
            self.deferredReplacementTask = nil
            for kind in [
                NativeOperationKind.open,
                .trackReplacement,
                .externalSubtitle,
            ] {
                if let transaction = self.operations.active(kind) {
                    self.finishOperation(
                        effectID: transaction.effectID,
                        succeeded: false,
                        code: "subtitlePipelineAdmissionTimedOut"
                    )
                }
            }
            self.emit(.typedFailure(PlaybackFailure(
                domain: .presentation,
                stage: .configure,
                stableCode: "subtitlePipelineAdmissionTimedOut",
                recoverability: .retryable
            )))
        }
    }

    private func retireSession(
        _ oldSession: MediaSession?,
        metadata: RuntimeSessionMetadata?
    ) {
        guard let oldSession else { return }
        releaseLogically(metadata)
        let ledger = runtimeMetadata.leases
        let retirementID = UUID()
        let task = Task { @MainActor [weak self] in
            let clean = await Task.detached(priority: .utility) {
                oldSession.waitForShutdown()
            }.value
            if clean, let metadata {
                _ = ledger.observePhysicalRelease(metadata.workerLease)
            }
            self?.retirementTasks.removeValue(forKey: retirementID)
            return clean
        }
        retirementTasks[retirementID] = task
    }

    private func stopCurrentSession() {
        abandonReplacementStateForStop()
        let oldSession = session
        let oldRuntimeSession = activeRuntimeSession
        session = nil
        activeRuntimeSession = nil
        releaseLogically(oldRuntimeSession)
        pendingPreviewSeek = nil
        previewSeekInFlight = false
        oldSession?.stop()
        clearSubtitlePipelines()
        presentation.stop()
        if let oldSession {
            retireSession(oldSession, metadata: oldRuntimeSession)
        }
    }

    private func abandonReplacementStateForStop() {
        latestReplacementSessionID = nil
        replacementSeekTargets.removeAll()
        deferredReplacementTask?.cancel()
        deferredReplacementTask = nil
        deferredReplacementRequest = nil
        cancelAllReplacementTasks()
        guard let pendingCommittedReplacement else { return }
        self.pendingCommittedReplacement = nil
        pendingCommittedReplacement.oldSession
            .setSubtitlePresentationAuthorityEnabled(false)
        releaseLogically(pendingCommittedReplacement.oldMetadata)
        pendingCommittedReplacement.oldSession.stop(
            releasesPresentation: false
        )
        retireSession(
            pendingCommittedReplacement.oldSession,
            metadata: pendingCommittedReplacement.oldMetadata
        )
    }

    private func consumeRuntimeObservation() {
        guard let session else { return }
        defer { refreshPresentationObservationCadence() }
        if previewSeekInFlight, !session.seekInProgress {
            previewSeekInFlight = false
        }
        dispatchPendingPreviewSeekIfReady(session: session)
        let synchronizerTime = presentation.currentTime.seconds
        if synchronizerTime.isFinite {
            currentTime = max(0, synchronizerTime)
            session.updateSubtitleReadAhead(position: currentTime)
            if Date().timeIntervalSince(lastPositionEmission) >= 0.25 {
                lastPositionEmission = Date()
                emit(.positionChanged(currentTime))
            }
        }
        let subtitlePacketRequestCount = lastObservationMetrics.requestsBySource[
            .subtitlePacket,
            default: 0
        ]
        if NativeSubtitleRenderPolicy.hasNewSubtitlePacket(
            current: subtitlePacketRequestCount,
            previous: lastSubtitlePacketRequestCount
        ) {
            renderSubtitlesAtPresentationTime()
        }
        lastSubtitlePacketRequestCount = subtitlePacketRequestCount
        let snapshot = session.snapshot()
        guard snapshot != lastSnapshot else { return }
        let previous = lastSnapshot
        lastSnapshot = snapshot
        if let failure = snapshot.deinterlacingFailure, failure != previous?.deinterlacingFailure {
            emit(.diagnostic("[native-deinterlace] Automatic filtering fell back to source fields: \(failure)"), identity: nil)
        }

        let buffered = minPositive(snapshot.bufferedVideoDuration, snapshot.bufferedAudioDuration)
        let isPreviewing = previewSeekInFlight || pendingPreviewSeek != nil
        let buffering = desiredPlaying && !isPreviewing && snapshot.isBuffering
        if buffering != lastBufferingState
            || Date().timeIntervalSince(lastBufferingEmission) >= 0.5
        {
            lastBufferingState = buffering
            lastBufferingEmission = Date()
            emit(.bufferingChanged(BufferStatus(
                isBuffering: buffering,
                cacheDuration: buffered
            )))
        }
        emitVideoStatus(media: session.mediaInfo, snapshot: snapshot)
        let decoderStatus = PlayerDecoderStatus(
            name: snapshot.hardwareDecoder,
            isHardwareDecoded: snapshot.isHardwareDecoded,
            didFallbackToSoftware: snapshot.hardwareFallbackCount > 0
        )
        if decoderStatus != lastEmittedDecoderStatus {
            lastEmittedDecoderStatus = decoderStatus
            emit(.decoderChanged(decoderStatus))
        }

        if !didEmitFirstFrameSubmitted, snapshot.framesSubmitted > 0 {
            didEmitFirstFrameSubmitted = true
            emit(.firstFrameSubmitted)
        }
        if !didEmitPreroll, snapshot.isPrerolled {
            didEmitPreroll = true
            emit(.prerollReady)
            finalizeCommittedReplacementIfNeeded(
                candidateSessionID: activeSessionID
            )
            finishOperation(kind: .preroll, nativeSessionID: activeSessionID)
            publishCommittedMediaMetadataIfNeeded(sessionID: activeSessionID)
            finishOperation(
                kind: .trackReplacement,
                nativeSessionID: activeSessionID
            )
            finishOperation(
                kind: .externalSubtitle,
                nativeSessionID: activeSessionID
            )
            // A paused source/track replacement may keep the exact same clock
            // time. It still needs an initial frame without a periodic tick.
            renderSubtitlesAtPresentationTime()
        }
        if let failure = snapshot.rendererFailure,
           failure != previous?.rendererFailure
        {
            if pendingCommittedReplacement?.candidateSessionID == activeSessionID {
                failCommittedReplacementBeforePreroll(
                    sessionID: activeSessionID,
                    code: "nativeCandidatePresentationFailed"
                )
                return
            }
            emit(.failed(failure))
        }
        if snapshot.ended, !didEmitEndOfFile {
            didEmitEndOfFile = true
            desiredPlaying = false
            pictureInPictureController?.updatePlayback(
                duration: session.mediaInfo.duration,
                isPaused: true
            )
            stopPictureInPictureForLifecycleChange()
            emit(.endOfFile)
        }
        if let recovery = snapshot.lastRecoveryMessage,
           recovery != previous?.lastRecoveryMessage
        {
            emit(.diagnostic("[native-recovery] \(recovery)"), identity: nil)
        }
        if Date().timeIntervalSince(lastMetricsEmission) >= 1 {
            lastMetricsEmission = Date()
            for payload in nativePeriodicMetricsPayloads(
                snapshot: snapshot,
                observation: lastObservationMetrics
            ) {
                emit(payload, identity: nil)
            }
            let clockMetrics = presentationObservations.snapshot()
            emit(.diagnostic(
                "[native-presentation-observation] requests=\(clockMetrics.totalRequests) "
                    + "deliveries=\(clockMetrics.deliveredObservations) "
                    + "coalesced=\(clockMetrics.coalescedRequests) "
                    + "max-ui-delay-ms=\(Double(clockMetrics.maximumDelayNanoseconds) / 1_000_000)"
            ), identity: nil)
        }
    }

    private func renderSubtitlesAtPresentationTime() {
        guard let session,
              NativeSubtitleRenderPolicy.shouldRender(
                  isEnabled: subtitlesEnabled,
                  hasEmbeddedSubtitle: session.activeSubtitleStream != nil,
                  hasExternalSubtitle: externalSubtitleTrack != nil
              )
        else { return }
        session.renderSubtitles()
    }

    private func setBitmapSubtitleFilter(_ forcedOnly: Bool) {
        for pipeline in subtitlePipelines { pipeline.forcesBitmapEventsOnly = forcedOnly }
        renderSubtitlesAtPresentationTime()
        refreshPictureInPictureSubtitleFrame()
    }

    private func refreshPresentationObservationCadence() {
        let hasSubtitles = NativeSubtitleRenderPolicy.shouldRender(
            isEnabled: subtitlesEnabled,
            hasEmbeddedSubtitle: session?.activeSubtitleStream != nil,
            hasExternalSubtitle: externalSubtitleTrack != nil
        )
        let sourceFrameRate = session?.mediaInfo.videoStreams.first {
            $0.index == session?.mediaInfo.selectedVideoIndex
        }?.averageFrameRate
        let frameRate = sourceFrameRate.map { $0 * (lastSnapshot?.usesDeinterlacingFilter == true ? 2 : 1) }
        presentation.setPresentationTimeObservationInterval(
            NativeSubtitleRenderPolicy.observationInterval(hasSubtitles: hasSubtitles, frameRate: frameRate)
        )
    }

    private func dispatchPendingPreviewSeekIfReady(session: MediaSession) {
        guard !previewSeekInFlight, let pending = pendingPreviewSeek else { return }
        pendingPreviewSeek = nil
        if let effectID = pending.effectID,
           operations.transaction(effectID: effectID) == nil
        {
            return
        }
        previewSeekInFlight = true
        let nativeGeneration = session.seek(
            to: pending.target,
            exact: false,
            resumeRate: 0,
            isPreview: true
        )
        if let effectID = pending.effectID {
            correlateOperation(
                effectID: effectID,
                nativeSessionID: activeSessionID,
                nativeGeneration: nativeGeneration
            )
        }
    }

    private func seekDidComplete(
        generation: Int,
        wasPreview: Bool,
        sessionID: PlaybackSessionID
    ) {
        let transaction = takeOperation(
            nativeSessionID: sessionID,
            nativeGeneration: generation
        )
        guard sessionID == activeSessionID,
              let session,
              session.currentGeneration == generation
        else { return }
        emit(.seekCompleted)
        if let transaction {
            if transaction.kind == .wake,
               case let .wake(_, milliRate) = transaction.requestedState
            {
                let playing = milliRate != 0
                let accepted = session.requestTransport(playing: playing, speed: Float(milliRate) / 1_000)
                if accepted {
                    desiredPlaying = playing
                    pictureInPictureController?.updatePlayback(
                        duration: session.mediaInfo.duration,
                        isPaused: !playing
                    )
                    emit(.pauseChanged(!playing))
                    finish(transaction.effect)
                } else {
                    finish(
                        transaction.effect,
                        succeeded: false,
                        code: "wakeRateRestoreRejected"
                    )
                }
            } else {
                finish(transaction.effect)
            }
        }
        guard wasPreview, previewSeekInFlight else { return }
        previewSeekInFlight = false
        dispatchPendingPreviewSeekIfReady(session: session)
    }

    private func seekDidFail(
        generation: Int,
        failure: PlaybackFailure,
        sessionID: PlaybackSessionID
    ) {
        let transaction = takeOperation(
            nativeSessionID: sessionID,
            nativeGeneration: generation
        )
        guard sessionID == activeSessionID,
              session?.currentGeneration == generation
        else { return }
        if let transaction {
            finish(transaction.effect, failure: failure)
        }
        if previewSeekInFlight {
            previewSeekInFlight = false
            if let session {
                dispatchPendingPreviewSeekIfReady(session: session)
            }
        }
    }

    var sessionSnapshotForDiagnostics: MediaSessionSnapshot? { session?.snapshot() }
    public var diagnosticSnapshot: NativePlaybackDiagnosticSnapshot? {
        let lifecycle = replacementLifecycle.snapshot
        let snapshot = session?.snapshot()
        guard lifecycle.sessionID > 0 || snapshot != nil else { return nil }
        let failure = snapshot?.lastRecoveryFailure
        return NativePlaybackDiagnosticSnapshot(
            sessionID: lifecycle.sessionID,
            sourcePath: lifecycle.sourcePath ?? currentURL?.path,
            lifecycleStage: lifecycle.stage,
            lifecycleStageUptimeSeconds: lifecycle.stageUptimeSeconds,
            hasInstalledMediaSession: snapshot != nil,
            lifecycleTransitions: lifecycle.transitions,
            mediaGeneration: snapshot?.generation ?? 0,
            presentationFence: snapshot?.presentationFence ?? presentation.currentFence.rawValue,
            rendererMediaTimeSeconds: snapshot?.rendererMediaTimeSeconds
                ?? presentation.currentTime.seconds,
            rendererRate: snapshot?.rendererRate ?? presentation.rate,
            rendererClockEpochBaselineSeconds: snapshot?.rendererClockEpochBaselineSeconds ?? 0,
            rendererClockMaximumSeconds: snapshot?.rendererClockMaximumSeconds ?? 0,
            firstRendererClockAdvanceSeconds: snapshot?.firstRendererClockAdvanceSeconds,
            videoPTS: snapshot?.videoPTS ?? 0,
            audioPTS: snapshot?.audioPTS ?? 0,
            audioOutputChannels: snapshot?.audioOutputChannels,
            audioOutputSampleRate: snapshot?.audioOutputSampleRate,
            audioDownmixOccurred: snapshot?.audioDownmixOccurred,
            usesDeinterlacingFilter: snapshot?.usesDeinterlacingFilter ?? false,
            deinterlacingFailure: snapshot?.deinterlacingFailure,
            videoSubmissionAttempts: snapshot?.videoSubmissionAttempts ?? 0,
            videoEnqueueReturnedWithoutImmediateFailure:
                snapshot?.videoEnqueueReturnedWithoutImmediateFailure ?? 0,
            flushCompleted: snapshot?.flushCompleted ?? false,
            rendererReady: snapshot?.rendererReady ?? presentation.video.isReady,
            isPrerolled: snapshot?.isPrerolled ?? false,
            rendererFailure: snapshot?.rendererFailure,
            failureDomain: failure?.domain.rawValue,
            failureStage: failure?.stage.rawValue,
            failureCode: failure?.stableCode,
            failureNativeCode: failure?.nativeCode,
            ffmpegPixelFormat: snapshot?.ffmpegPixelFormat ?? "Unknown",
            pixelBufferFormat: snapshot?.pixelBufferFormat ?? "Unknown",
            softwarePoolAllocatedBuffers: snapshot?.softwarePoolAllocatedBuffers ?? 0,
            softwarePoolThresholdWaits: snapshot?.softwarePoolThresholdWaits ?? 0,
            softwarePoolTimeouts: snapshot?.softwarePoolTimeouts ?? 0,
            softwareBGRAFallbackFrames: snapshot?.softwareBGRAFallbackFrames ?? 0,
            discardedStaleFrames: snapshot?.discardedStaleFrames ?? 0,
            rendererStarvations: snapshot?.rendererStarvations ?? 0,
            peakVideoFrameQueueDepth: snapshot?.peakVideoFrameQueueDepth ?? 0,
            videoPipelineCapacity: snapshot?.videoPipelineCapacity ?? 0,
            videoPipelineCapacityInUse: snapshot?.videoPipelineCapacityInUse ?? 0,
            peakVideoPipelineCapacityInUse:
                snapshot?.peakVideoPipelineCapacityInUse ?? 0,
            videoPipelineCapacityWaiters: snapshot?.videoPipelineCapacityWaiters ?? 0,
            demuxDeferredPacketDepth: snapshot?.demuxDeferredPacketDepth ?? 0,
            peakDemuxDeferredPacketDepth:
                snapshot?.peakDemuxDeferredPacketDepth ?? 0,
            demuxDeferredPacketCount: snapshot?.demuxDeferredPacketCount ?? 0,
            demuxCapacityWaits: snapshot?.demuxCapacityWaits ?? 0,
            demuxCapacityWaitSeconds: snapshot?.demuxCapacityWaitSeconds ?? 0,
            framesSubmitted: snapshot?.framesSubmitted ?? 0
        )
    }
    var observationMetricsForDiagnostics: RuntimeObservationMetricsSnapshot {
        lastObservationMetrics
    }

    var runtimeLeaseSnapshotsForTesting: [RuntimeLeaseSnapshot] {
        runtimeMetadata.leases.snapshots()
    }

    var subtitleMemoryBudgetSnapshotForTesting: SubtitleMemoryBudgetSnapshot {
        subtitleMemoryBudget.snapshot
    }

    var deferredReplacementAdmissionCountForTesting: Int {
        deferredReplacementAdmissionCount
    }

    private func releaseLogically(_ metadata: RuntimeSessionMetadata?) {
        guard let metadata else { return }
        runtimeMetadata.leases.supersede(authority: metadata.authority)
        runtimeMetadata.leases.requestRelease(metadata.workerLease)
    }

    private func releaseApplicationGraphBorrowsAndLeases() {
        if let lease = pictureInPictureLease, let borrow = pictureInPictureBorrow {
            runtimeMetadata.leases.returnBorrow(borrow, from: lease)
        }
        if let lease = surfaceLease, let borrow = surfaceBorrow {
            runtimeMetadata.leases.returnBorrow(borrow, from: lease)
        }
        for lease in [pictureInPictureLease, surfaceLease, applicationGraphLease].compactMap({ $0 }) {
            runtimeMetadata.leases.requestRelease(lease)
            _ = runtimeMetadata.leases.observePhysicalRelease(lease)
        }
        pictureInPictureBorrow = nil
        pictureInPictureLease = nil
        surfaceBorrow = nil
        surfaceLease = nil
        applicationGraphLease = nil
    }

    private func cancelAllReplacementTasks() {
        for (sessionID, task) in replacementTasks {
            cancelledReplacementSessionIDs.insert(sessionID)
            replacementConstructionCancellations[sessionID]?
                .requestCancellation()
            task.cancel()
        }
        for cancellation in replacementConstructionCancellations.values {
            cancellation.requestCancellation()
        }
    }

    private func cancelSession(effectID: PlaybackEffectID) {
        let cancelledIdentity = activeIdentity
        pendingLoad = nil
        pendingMetadataPublicationSessionID = nil
        let cancellations: [(NativeOperationKind, String)] = [
            (.open, "openCancelled"),
            (.preroll, "prerollCancelled"),
            (.seek, "seekCancelled"),
            (.trackReplacement, "trackSelectionCancelled"),
            (.externalSubtitle, "externalSubtitleCancelled"),
            (.recovery, "recoveryCancelled"),
            (.wake, "wakeCancelled"),
            (.presentationFlush, "presentationFlushCancelled"),
        ]
        for (kind, code) in cancellations {
            cancelOperation(kind: kind, code: code)
        }
        legacyExternalSubtitleTask?.cancel()
        legacyExternalSubtitleTask = nil
        abandonReplacementStateForStop()
        if externalSubtitleRequestRevision < UInt64.max { externalSubtitleRequestRevision += 1 }
        desiredPlaying = false
        stopPictureInPictureForLifecycleChange()
        pictureInPictureController?.updatePlayback(duration: 0, isPaused: true)
        pendingPreviewSeek = nil
        previewSeekInFlight = false

        let oldSession = session
        let oldMetadata = activeRuntimeSession
        session = nil
        activeRuntimeSession = nil
        releaseLogically(oldMetadata)
        oldSession?.stop()
        clearSubtitlePipelines()
        presentation.stop()
        currentTime = 0

        guard let oldSession else {
            if activeIdentity == cancelledIdentity { activeIdentity = nil }
            emit(.stopped, identity: cancelledIdentity)
            finishOperation(effectID: effectID)
            return
        }
        let ledger = runtimeMetadata.leases
        operationWorkTasks[effectID] = Task { [weak self] in
            let clean = await Task.detached { oldSession.waitForShutdown() }.value
            guard let self, !Task.isCancelled else { return }
            if clean, let oldMetadata {
                _ = ledger.observePhysicalRelease(oldMetadata.workerLease)
            }
            if self.activeIdentity == cancelledIdentity { self.activeIdentity = nil }
            self.emit(.stopped, identity: cancelledIdentity)
            self.finishOperation(
                effectID: effectID,
                succeeded: clean,
                code: "sessionCancellationTimedOut"
            )
        }
    }

    private func executeRecoveryOrSynchronization(_ effect: PlaybackEffect) {
        switch effect.kind {
        case .resumeVideoDecoderAfterTransientFailure:
            let transaction = beginOperation(
                effect,
                kind: .recovery,
                requestedState: .recovery("videoDecoderRetry"),
                nativeSessionID: activeSessionID,
                supersessionCode: "recoverySuperseded"
            )
            guard session?.resumeVideoDecodingAfterTransientFailure() == true else {
                finishOperation(
                    effectID: transaction.effectID,
                    succeeded: false,
                    code: "videoDecoderRetryFailed"
                )
                return
            }
            finishOperation(effectID: transaction.effectID)

        case .recreateVideoDecoderInSoftware:
            let transaction = beginOperation(
                effect,
                kind: .recovery,
                requestedState: .recovery("softwareVideoDecoder"),
                nativeSessionID: activeSessionID,
                supersessionCode: "recoverySuperseded"
            )
            guard let session,
                  let disposition = session.recoverVideoDecoderInSoftware()
            else {
                finishOperation(
                    effectID: transaction.effectID,
                    succeeded: false,
                    code: "softwareDecoderRecoveryFailed"
                )
                return
            }
            switch disposition {
            case .packetReplay:
                finishOperation(effectID: transaction.effectID)
            case let .seek(nativeGeneration):
                correlateOperation(
                    effectID: transaction.effectID,
                    nativeSessionID: activeSessionID,
                    nativeGeneration: nativeGeneration
                )
            }
        case .flushPresentationForRecovery:
            let transaction = beginOperation(
                effect,
                kind: .recovery,
                requestedState: .recovery("flushVideoPresentation"),
                nativeSessionID: activeSessionID,
                supersessionCode: "recoverySuperseded"
            )
            let result = presentation.recoverVideoPresentation(rebuildGraph: false)
            session?.adoptPresentationFence(result.fence)
            session?.resumeVideoPresentationAfterRecovery()
            finishWhenPresentationFlushCompletes(
                effectID: transaction.effectID,
                fence: result.fence
            )
        case .rebuildPresentationGraph:
            let transaction = beginOperation(
                effect,
                kind: .recovery,
                requestedState: .recovery("rebuildPresentationGraph"),
                nativeSessionID: activeSessionID,
                supersessionCode: "recoverySuperseded"
            )
            let result = presentation.recoverVideoPresentation(rebuildGraph: true)
            session?.adoptPresentationFence(result.fence)
            surfaceHost?.rebindVideoLayer(result.newDisplayLayer)
            if !subtitleCompositedPiPRequested {
                pictureInPictureController?.rebind(displayLayer: result.newDisplayLayer)
            }
            session?.resumeVideoPresentationAfterRecovery()
            finishWhenPresentationFlushCompletes(
                effectID: transaction.effectID,
                fence: result.fence
            )
        case .flushAudioPresentationForRecovery:
            let transaction = beginOperation(
                effect,
                kind: .recovery,
                requestedState: .recovery("flushAudioPresentation"),
                nativeSessionID: activeSessionID,
                supersessionCode: "recoverySuperseded"
            )
            do {
                let fence = try presentation.recoverAudioPresentation(rebuildGraph: false)
                session?.adoptPresentationFence(fence)
                session?.resumeAudioPresentationAfterRecovery()
                finishWhenPresentationFlushCompletes(
                    effectID: transaction.effectID,
                    fence: fence
                )
            } catch {
                finishOperation(
                    effectID: transaction.effectID,
                    succeeded: false,
                    code: "audioPresentationFlushFailed"
                )
            }
        case .rebuildAudioPresentation:
            let transaction = beginOperation(
                effect,
                kind: .recovery,
                requestedState: .recovery("rebuildAudioPresentation"),
                nativeSessionID: activeSessionID,
                supersessionCode: "recoverySuperseded"
            )
            do {
                let fence = try presentation.recoverAudioPresentation(rebuildGraph: true)
                session?.adoptPresentationFence(fence)
                session?.resumeAudioPresentationAfterRecovery()
                finishWhenPresentationFlushCompletes(
                    effectID: transaction.effectID,
                    fence: fence
                )
            } catch {
                finishOperation(
                    effectID: transaction.effectID,
                    succeeded: false,
                    code: "audioPresentationRebuildFailed"
                )
            }
        case .disableAudioTrack:
            let transaction = beginOperation(
                effect,
                kind: .recovery,
                requestedState: .recovery("disableAudioTrack"),
                nativeSessionID: activeSessionID,
                supersessionCode: "recoverySuperseded"
            )
            let disabled = session?.disableAudioTrackAfterFailure() == true
            if disabled { selectedAudioIndex = nil }
            finishOperation(
                effectID: transaction.effectID,
                succeeded: disabled,
                code: "audioDisableFailed"
            )
        case .disableSubtitleTrack:
            let transaction = beginOperation(
                effect,
                kind: .recovery,
                requestedState: .recovery("disableSubtitleTrack"),
                nativeSessionID: activeSessionID,
                supersessionCode: "recoverySuperseded"
            )
            let disabled = session?.disableSubtitleTrackAfterFailure() == true
            if disabled { subtitleSource = .off }
            finishOperation(
                effectID: transaction.effectID,
                succeeded: disabled,
                code: "subtitleDisableFailed"
            )
        case let .reconfigureMediaFormat(stream, revision):
            guard let formatSession = session else {
                finish(effect, succeeded: false, code: "formatSessionUnavailable")
                return
            }
            let transaction = beginOperation(
                effect,
                kind: .recovery,
                requestedState: .mediaFormat(
                    stream: stream,
                    revision: revision
                ),
                nativeSessionID: activeSessionID,
                supersessionCode: "recoverySuperseded"
            )
            let fence = presentation.installFenceAndRequestFlush(
                at: presentation.currentTime,
                removeDisplayedImage: false
            )
            formatSession.adoptPresentationFence(fence)
            finishWhenPresentationFlushCompletes(
                effectID: transaction.effectID,
                fence: fence
            ) {
                formatSession.completeFormatReconfiguration(
                    stream,
                    revision: revision
                )
                if stream == .video,
                   let geometry = formatSession.currentVideoGeometry
                {
                    self.surfaceHost?.rotationDegrees = geometry.rotationDegrees
                    self.surfaceHost?.sourceDisplaySize = geometry.displaySize
                }
            }
        case let .correctAudioVideoDrift(microseconds):
            let current = presentation.currentTime
            let corrected = CMTimeAdd(
                current.isNumeric ? current : .zero,
                CMTime(value: microseconds, timescale: 1_000_000)
            )
            let accepted = presentation.setRate(
                desiredPlaying ? playbackSpeed : 0,
                at: corrected,
                fence: presentation.currentFence
            )
            finish(effect, succeeded: accepted, code: "driftCorrectionRejected")
        default:
            finish(effect, succeeded: false, code: "invalidDirectiveRouting")
        }
    }

    @discardableResult
    private func beginOperation(
        _ effect: PlaybackEffect,
        kind: NativeOperationKind,
        requestedState: NativeOperationRequestedState,
        nativeSessionID: PlaybackSessionID? = nil,
        supersessionCode: String
    ) -> NativeOperationTransaction {
        let transaction = NativeOperationTransaction(
            effect: effect,
            kind: kind,
            requestedState: requestedState,
            deadline: ContinuousClock().now.advanced(
                by: NativeOperationDeadlinePolicy.timeout(for: kind)
            )
        )
        if let superseded = operations.begin(
            transaction,
            supersessionCode: supersessionCode
        ) {
            cancelOperationDeadline(effectID: superseded.effectID)
            cancel(superseded.effect, code: supersessionCode)
        }
        if let nativeSessionID {
            correlateOperation(
                effectID: transaction.effectID,
                nativeSessionID: nativeSessionID
            )
        }
        scheduleOperationDeadline(transaction)
        return transaction
    }

    private func correlateOperation(
        effectID: PlaybackEffectID,
        nativeSessionID: PlaybackSessionID,
        nativeGeneration: Int? = nil
    ) {
        _ = operations.correlate(
            effectID: effectID,
            nativeSessionID: nativeSessionID,
            nativeGeneration: nativeGeneration
        )
    }

    private func finishOperation(
        effectID: PlaybackEffectID,
        succeeded: Bool = true,
        code: String? = nil
    ) {
        guard let transaction = operations.take(effectID: effectID) else { return }
        cancelOperationDeadline(effectID: effectID)
        cancelOperationWork(effectID: effectID)
        finish(transaction.effect, succeeded: succeeded, code: code)
    }

    private func finishOperation(
        kind: NativeOperationKind,
        nativeSessionID: PlaybackSessionID,
        succeeded: Bool = true,
        code: String? = nil
    ) {
        guard let transaction = operations.take(
            kind: kind,
            nativeSessionID: nativeSessionID
        ) else { return }
        cancelOperationDeadline(effectID: transaction.effectID)
        cancelOperationWork(effectID: transaction.effectID)
        finish(transaction.effect, succeeded: succeeded, code: code)
    }

    private func takeOperation(
        nativeSessionID: PlaybackSessionID,
        nativeGeneration: Int
    ) -> NativeOperationTransaction? {
        guard let transaction = operations.take(
            nativeSessionID: nativeSessionID,
            nativeGeneration: nativeGeneration
        ) else { return nil }
        cancelOperationDeadline(effectID: transaction.effectID)
        return transaction
    }

    private func cancelOperation(kind: NativeOperationKind, code: String) {
        guard let transaction = operations.cancel(kind: kind, code: code) else { return }
        cancelOperationDeadline(effectID: transaction.effectID)
        cancelOperationWork(effectID: transaction.effectID)
        cancel(transaction.effect, code: code)
    }

    private func scheduleOperationDeadline(
        _ transaction: NativeOperationTransaction
    ) {
        cancelOperationDeadline(effectID: transaction.effectID)
        operationDeadlineTasks[transaction.effectID] = Task { [weak self] in
            do {
                try await ContinuousClock().sleep(
                    until: transaction.deadline
                )
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.operationDeadlineReached(effectID: transaction.effectID)
        }
    }

    private func cancelOperationDeadline(effectID: PlaybackEffectID) {
        operationDeadlineTasks.removeValue(forKey: effectID)?.cancel()
    }

    private func cancelOperationWork(effectID: PlaybackEffectID) {
        operationWorkTasks.removeValue(forKey: effectID)?.cancel()
    }

    private func operationDeadlineReached(effectID: PlaybackEffectID) {
        guard let transaction = operations.cancel(
            effectID: effectID,
            code: "nativeOperationTimedOut"
        ) else { return }
        cancelOperationDeadline(effectID: effectID)
        cancelOperationWork(effectID: effectID)
        switch transaction.kind {
        case .seek, .recovery, .wake:
            _ = session?.cancelActiveInputOperation()
        case .open:
            pendingLoad = nil
            if let nativeSessionID = transaction.nativeSessionID {
                cancelledReplacementSessionIDs.insert(nativeSessionID)
                replacementConstructionCancellations[nativeSessionID]?
                    .requestCancellation()
                replacementTasks[nativeSessionID]?.cancel()
            }
            if transaction.nativeSessionID == activeSessionID {
                stopCurrentSession()
            }
        case .preroll:
            if transaction.nativeSessionID == activeSessionID {
                stopCurrentSession()
            }
        case .trackReplacement, .externalSubtitle:
            if let nativeSessionID = transaction.nativeSessionID {
                if pendingCommittedReplacement?.candidateSessionID
                    == nativeSessionID
                {
                    failCommittedReplacementBeforePreroll(
                        sessionID: nativeSessionID,
                        code: "nativeOperationTimedOut"
                    )
                } else {
                    cancelledReplacementSessionIDs.insert(nativeSessionID)
                    replacementConstructionCancellations[nativeSessionID]?
                        .requestCancellation()
                    replacementTasks[nativeSessionID]?.cancel()
                }
            }
        case .presentationFlush, .sessionCancellation, .shutdown:
            break
        }
        finish(
            transaction.effect,
            failure: PlaybackFailure(
                domain: failureDomain(for: transaction.effect.executor),
                stage: timeoutStage(for: transaction.kind),
                stableCode: "nativeOperationTimedOut",
                recoverability: transaction.kind == .shutdown ? .fatal : .retryable
            )
        )
    }

    private func timeoutStage(
        for kind: NativeOperationKind
    ) -> PlaybackFailure.Stage {
        switch kind {
        case .open: .open
        case .seek, .wake: .seek
        case .preroll, .trackReplacement, .externalSubtitle, .recovery,
             .presentationFlush: .configure
        case .sessionCancellation: .close
        case .shutdown: .shutdown
        }
    }

    private func finishWhenPresentationFlushCompletes(
        effectID: PlaybackEffectID,
        fence: PresentationFence,
        onSuccess: (@MainActor () -> Void)? = nil
    ) {
        operationWorkTasks[effectID]?.cancel()
        operationWorkTasks[effectID] = Task { [weak self] in
            guard let self else { return }
            for _ in 0..<300 {
                if self.presentation.flushCompleted(fence) {
                    onSuccess?()
                    self.finishOperation(effectID: effectID)
                    return
                }
                try? await Task.sleep(for: .milliseconds(10))
            }
            self.finishOperation(
                effectID: effectID,
                succeeded: false,
                code: "presentationFlushTimedOut"
            )
        }
    }

    private func finish(
        _ effect: PlaybackEffect,
        succeeded: Bool = true,
        code: String? = nil
    ) {
        let token = EffectResultToken(kind: succeeded ? .succeeded : .failed)
        let failure = code.map { stableCode in
            PlaybackFailure(
                domain: failureDomain(for: effect.executor),
                stage: .callback,
                stableCode: stableCode,
                recoverability: .fatal
            )
        }
        emit(.effectResult(PlaybackEffectResult(
            context: effect.context,
            token: token,
            failure: failure
        )), identity: nil)
    }

    private func finish(_ effect: PlaybackEffect, failure: PlaybackFailure) {
        emit(.effectResult(PlaybackEffectResult(
            context: effect.context,
            token: EffectResultToken(kind: .failed),
            failure: failure
        )), identity: nil)
    }

    private func cancel(_ effect: PlaybackEffect, code: String) {
        emit(.effectResult(PlaybackEffectResult(
            context: effect.context,
            token: EffectResultToken(kind: .cancelled),
            failure: PlaybackFailure(
                domain: failureDomain(for: effect.executor),
                stage: .callback,
                stableCode: code,
                recoverability: .cancelled
            )
        )), identity: nil)
    }

    private func failureDomain(for executor: ExecutorKind) -> PlaybackFailure.Domain {
        switch executor {
        case .input: .input
        case .videoDecode: .videoDecode
        case .audioDecode: .audioDecode
        case .presentation: .presentation
        case .subtitle: .subtitle
        case .persistence: .persistence
        case .platform, .mainActorControl: .platform
        case .resource: .resource
        case .diagnostics: .invariant
        }
    }

    private func seconds(_ timestamp: MediaTimestamp) -> TimeInterval? {
        guard case let .valid(time) = timestamp, time.timescale > 0 else { return nil }
        return Double(time.value) / Double(time.timescale)
    }

    private func timestamp(_ seconds: TimeInterval) -> MediaTimestamp {
        guard seconds.isFinite else { return .invalid(.nonFiniteSource) }
        let value = seconds * 1_000_000
        guard value >= Double(Int64.min), value <= Double(Int64.max),
              let time = ValidMediaTime(value: Int64(value.rounded()), timescale: 1_000_000)
        else { return .invalid(.overflow) }
        return .valid(time)
    }

    private func runtimeSeekMode(
        _ mode: SuperplayrPlaybackCore.SeekMode
    ) -> SuperplayrPlayback.SeekMode {
        switch mode {
        case .relative: .relative
        case .preview, .keyframe: .absolutePreview
        case .exact: .absoluteExact
        }
    }

    private func emitTracks() {
        guard let info = session?.mediaInfo else { return }
        emit(.audioDelayChanged(session?.audioDelay ?? 0))
        var tracks = info.audioStreams.map { mediaTrack($0, kind: .audio) }
        tracks.append(contentsOf: info.subtitleStreams
            .filter { $0.subtitleCapability?.isPlayable == true }
            .map { mediaTrack($0, kind: .subtitle) })
        tracks.append(contentsOf: preparedExternalSubtitle?.tracks ?? [])
        let selectedSubtitleID: Int64? = switch subtitleSource {
        case .off:
            Optional<Int64>.none
        case .automaticEmbedded:
            session?.activeSubtitleStream.map { trackID($0.index) }
        case let .embedded(streamIndex):
            trackID(streamIndex)
        case .external:
            Self.externalSubtitleTrackID
        case let .externalBitmap(_, index):
            PreparedExternalSubtitle.trackID(index)
        }
        emit(.tracksChanged(PlayerTrackSnapshot(
            hasVideo: !info.videoStreams.isEmpty,
            tracks: tracks,
            selectedAudioID: selectedAudioIndex.map(trackID),
            selectedSubtitleID: selectedSubtitleID
        )))
    }

    private func publishCommittedMediaMetadataIfNeeded(
        sessionID: PlaybackSessionID
    ) {
        guard pendingMetadataPublicationSessionID == sessionID,
              let session,
              activeSessionID == sessionID
        else { return }
        pendingMetadataPublicationSessionID = nil

        // The preroll effect is completed first. Its synchronous core result
        // atomically commits shell identity and switches event gates before
        // any candidate metadata becomes observable. Version applicability
        // must precede tracks and loaded, which restore per-file choices/time.
        emit(.mediaVersionObserved(session.contentVersion))
        emitTracks()
        emit(.loaded)
        emit(.durationChanged(session.mediaInfo.duration))
        emitVideoStatus(media: session.mediaInfo, snapshot: nil)
        emit(.chaptersChanged(
            session.mediaInfo.chapters.enumerated().map { offset, chapter in
                Chapter(id: Int64(offset), title: chapter.title, startTime: chapter.start)
            },
            currentID: nil
        ))
        for stream in session.mediaInfo.subtitleStreams
            where stream.subtitleCapability?.isPlayable != true
        {
            emit(.diagnostic(
                "[native-capability] Subtitle codec \(stream.codecName) is unsupported; the track was not advertised as playable."
            ), identity: nil)
        }
        if let stream = session.mediaInfo.videoStreams.first(where: {
            $0.index == session.mediaInfo.selectedVideoIndex
        }), stream.interlaceMode.requiresDeinterlacing {
            emit(.diagnostic(
                "[native-capability] \(stream.interlaceMode.rawValue) video detected; automatic BWDIF reconstructs flagged fields with source fallback for unsupported inputs."
            ), identity: nil)
        }
        emit(.pauseChanged(!desiredPlaying))
    }

    private func emitVideoStatus(media: FFmpegMediaInfo, snapshot: MediaSessionSnapshot?) {
        guard let stream = media.videoStreams.first(where: { $0.index == media.selectedVideoIndex }) else {
            emitVideoStatusIfChanged(.empty, aspectRatio: nil)
            return
        }
        let displaySize = stream.displaySize
        let transfer = snapshot?.transferCharacteristic.map(String.init)
        let primaries = snapshot?.colorPrimaries.map(String.init)
        let isHDR = snapshot?.transferCharacteristic == 16
            || snapshot?.transferCharacteristic == 18
            || snapshot?.colorPrimaries == 9
        let status = VideoOutputStatus(
            pixelWidth: stream.codedSize.map { Int($0.width) },
            pixelHeight: stream.codedSize.map { Int($0.height) },
            codec: stream.codecName,
            pixelFormat: snapshot?.ffmpegPixelFormat,
            colorPrimaries: primaries,
            transferFunction: transfer,
            isHDR: isHDR,
            decoder: snapshot?.hardwareDecoder,
            isHardwareDecoded: snapshot?.isHardwareDecoded ?? false
        )
        let aspectRatio = displaySize.flatMap { size in
            size.height > 0 ? Double(size.width / size.height) : nil
        }
        emitVideoStatusIfChanged(status, aspectRatio: aspectRatio)
    }

    private func emitVideoStatusIfChanged(
        _ status: VideoOutputStatus,
        aspectRatio: Double?
    ) {
        guard status != lastEmittedVideoStatus
                || aspectRatio != lastEmittedVideoAspectRatio
        else { return }
        lastEmittedVideoStatus = status
        lastEmittedVideoAspectRatio = aspectRatio
        emit(.videoChanged(status, aspectRatio: aspectRatio))
    }

    private func mediaTrack(_ stream: FFmpegStreamInfo, kind: MediaTrackKind) -> MediaTrack {
        MediaTrack(
            id: trackID(stream.index),
            kind: kind,
            title: stream.title,
            languageCode: stream.language,
            codec: stream.codecName,
            isDefault: stream.disposition & 1 != 0,
            isForced: stream.disposition & 64 != 0
        )
    }

    private func unsupported(_ operation: String) {
        emit(.diagnostic(
            "[native-capability] \(UnsupportedPlaybackCapabilityError(operation).localizedDescription)"
        ), identity: nil)
    }

    private func emit(
        _ payload: PlaybackRuntimeEventPayload,
        identity: PlayerSessionIdentity? = nil
    ) {
        let mayCrossShutdownTombstone: Bool
        switch payload {
        case .effectResult, .shutdownCompleted:
            mayCrossShutdownTombstone = true
        default:
            mayCrossShutdownTombstone = false
        }
        if !mayCrossShutdownTombstone {
            guard runtimeMetadata.callbackTombstone.disposition(
                for: runtimeMetadata.applicationEpoch,
                carriesResourceCustody: false
            ) == .forward else { return }
        }
        let resolved: PlayerSessionIdentity?
        switch payload {
        case .effectResult, .diagnostic, .pictureInPictureChanged, .shutdownCompleted,
             .audioDevicesChanged, .audioOutputSelectionFailed:
            resolved = identity
        default: resolved = identity ?? activeIdentity
        }
        eventHandler?(PlaybackRuntimeEvent(identity: resolved, payload: payload))
    }

    private func trackID(_ index: Int32) -> Int64 {
        NativeTrackIDMapping.trackID(for: index)
    }
    private func streamIndex(_ id: Int64) -> Int32? {
        NativeTrackIDMapping.streamIndex(for: id)
    }

    private func minPositive(_ lhs: Double, _ rhs: Double) -> Double {
        let values = [lhs, rhs].filter { $0 > 0 && $0.isFinite }
        return values.min() ?? 0
    }

    private static let externalSubtitleTrackID = Int64.max
}

enum NativeSubtitleRenderPolicy {
    /// Requested media-time cadence, not a guarantee of display-frame delivery.
    /// EOF still needs clock observation with subtitles off, at a lower rate.
    static func observationInterval(hasSubtitles: Bool, frameRate: Double?) -> CMTime {
        guard hasSubtitles else { return CMTime(value: 1, timescale: 4) }
        let rate = frameRate.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 30
        return CMTime(seconds: 1 / min(max(rate, 24), 120), preferredTimescale: 120_000)
    }

    static func shouldRender(
        isEnabled: Bool,
        hasEmbeddedSubtitle: Bool,
        hasExternalSubtitle: Bool
    ) -> Bool {
        isEnabled && (hasEmbeddedSubtitle || hasExternalSubtitle)
    }

    /// Packet arrival invalidates a paused frame immediately. While playback
    /// advances, the synchronizer's periodic time observer owns cue timing.
    static func hasNewSubtitlePacket(current: Int, previous: Int) -> Bool {
        current > previous
    }
}

/// Periodic diagnostics deliberately expose enqueue horizons without feeding
/// them back into synchronization. Differing renderer queue depths routinely
/// put the audio enqueue horizon hundreds of milliseconds ahead of video; that
/// is not presentation drift and must never retime the shared synchronizer.
func nativePeriodicMetricsPayloads(
    snapshot: MediaSessionSnapshot,
    observation: RuntimeObservationMetricsSnapshot = RuntimeObservationMetricsSnapshot()
) -> [PlaybackRuntimeEventPayload] {
    let videoClock = snapshot.firstVideoRendererClockEvidenceSeconds == nil
        ? "unmeasured" : "observed"
    let audioClock = snapshot.firstAudioRendererClockEvidenceSeconds == nil
        ? "unmeasured" : "observed"
    let flush = !snapshot.flushRequested
        ? "not-requested" : (snapshot.flushCompleted ? "completed" : "pending")
    let drain = snapshot.rendererDrainEvidence ? "observed" : "unmeasured"
    let sourceCounts = RuntimeObservationSource.allCases.map {
        "\($0.rawValue)=\(observation.requestsBySource[$0, default: 0])"
    }.joined(separator: ",")
    let maximumDelayMilliseconds = Double(observation.maximumDelayNanoseconds) / 1_000_000
    let maximumUrgentDelayMilliseconds =
        Double(observation.maximumUrgentDelayNanoseconds) / 1_000_000
    let oldGenerationRetained = snapshot.softwareOldGenerationRetainedUpperBound
        .map(String.init) ?? "unmeasured"
    let timeout = snapshot.softwareOwnershipLastTimeout
    let timeoutKnownOwned = timeout.map { String($0.knownOutstandingBuffers) }
        ?? "unmeasured"
    let timeoutApplicationFrames = timeout.map { String($0.applicationFrames) }
        ?? "unmeasured"
    let timeoutQueuedFrames = timeout.map { String($0.queuedFrames) }
        ?? "unmeasured"
    let timeoutRendererSamples = timeout.map { String($0.rendererSampleAttachments) }
        ?? "unmeasured"
    let timeoutOldestSampleMilliseconds = timeout.map {
        String(format: "%.3f", $0.oldestRendererSampleMilliseconds)
    } ?? "unmeasured"
    let ownershipFlush = snapshot.softwareOwnershipLastFlush
    let flushGeneration = ownershipFlush.map { String($0.activeGeneration) }
        ?? "unmeasured"
    let flushOldKnownAtRequest = ownershipFlush.map {
        String($0.oldGenerationKnownBuffersAtRequest)
    } ?? "unmeasured"
    let flushOldSamplesAtRequest = ownershipFlush.map {
        String($0.oldGenerationRendererSamplesAtRequest)
    } ?? "unmeasured"
    let flushOldKnownAtCompletion = ownershipFlush?
        .oldGenerationKnownBuffersAtVideoCompletion.map(String.init)
        ?? "unmeasured"
    let flushOldSamplesAtCompletion = ownershipFlush?
        .oldGenerationRendererSamplesAtVideoCompletion.map(String.init)
        ?? "unmeasured"
    let flushCompletionMilliseconds = ownershipFlush?
        .videoFlushCompletionMilliseconds.map { String(format: "%.3f", $0) }
        ?? "unmeasured"
    let flushOldKnownZeroMilliseconds = ownershipFlush?
        .oldGenerationKnownBuffersReachedZeroMilliseconds.map {
            String(format: "%.3f", $0)
        } ?? "unmeasured"
    let recoveryFailure = snapshot.lastRecoveryFailure
    let recoveryNativeCode = recoveryFailure?.nativeCode.map(String.init) ?? "none"
    return [
        .diagnostic(
            "[native-metrics] gen=\(snapshot.generation) "
                + "venqueue=\(snapshot.videoPTS) aenqueue=\(snapshot.audioPTS) "
                + "audio-pcm=\(snapshot.audioOutputChannels ?? 0)ch@\(snapshot.audioOutputSampleRate ?? 0)Hz "
                + "audio-downmix=\(snapshot.audioDownmixOccurred.map(String.init) ?? "unknown") "
                + "deinterlace=\(snapshot.usesDeinterlacingFilter ? "bwdif" : "source") "
                + "vq=\(snapshot.videoPacketDepth)/\(snapshot.videoFrameDepth) "
                + "aq=\(snapshot.audioPacketDepth)/\(snapshot.audioFrameDepth) "
                + "packet-producer-waits="
                + "v:\(snapshot.videoPacketProducerWaits),"
                + "a:\(snapshot.audioPacketProducerWaits),"
                + "s:\(snapshot.subtitlePacketProducerWaits) "
                + "packet-producer-wait-seconds="
                + "v:\(String(format: "%.6f", snapshot.videoPacketProducerWaitSeconds)),"
                + "a:\(String(format: "%.6f", snapshot.audioPacketProducerWaitSeconds)),"
                + "s:\(String(format: "%.6f", snapshot.subtitlePacketProducerWaitSeconds)) "
                + "demux-deferred="
                + "\(snapshot.demuxDeferredPacketDepth)/"
                + "\(snapshot.peakDemuxDeferredPacketDepth) "
                + "demux-deferred-by-stream="
                + "v:\(snapshot.demuxDeferredVideoPackets),"
                + "a:\(snapshot.demuxDeferredAudioPackets),"
                + "s:\(snapshot.demuxDeferredSubtitlePackets) "
                + "demux-deferred-total=\(snapshot.demuxDeferredPacketCount) "
                + "demux-capacity-waits=\(snapshot.demuxCapacityWaits) "
                + "demux-capacity-wait-seconds="
                + "\(String(format: "%.6f", snapshot.demuxCapacityWaitSeconds)) "
                + "stale=\(snapshot.discardedStalePackets)/\(snapshot.discardedStaleFrames) "
                + "software-pool-distinct-seen="
                + "\(snapshot.softwarePoolAllocatedBuffers) "
                + "software-pool-reuses=\(snapshot.softwarePoolReusedCheckouts) "
                + "software-pool-bytes=\(snapshot.softwarePoolBytesPerBuffer) "
                + "software-pool-cap=\(snapshot.softwarePoolMaximumBuffers) "
                + "software-active-upper=\(snapshot.softwarePoolInUseUpperBound) "
                + "software-free-lower=\(snapshot.softwarePoolFreeLowerBound) "
                + "software-waits=\(snapshot.softwarePoolThresholdWaits) "
                + "software-timeouts=\(snapshot.softwarePoolTimeouts) "
                + "software-cancellations=\(snapshot.softwarePoolCancellations) "
                + "software-bgra-fallbacks=\(snapshot.softwareBGRAFallbackFrames) "
                + "software-decode-errors-dropped="
                + "\(snapshot.softwareDecodeErrorsDropped) "
                + "software-corrupt-frames-dropped="
                + "\(snapshot.softwareCorruptFramesDropped) "
                + "ffmpeg-format=\(snapshot.ffmpegPixelFormat) "
                + "pixel-buffer=\(snapshot.pixelBufferFormat) "
                + "software-temporary=\(snapshot.temporaryDecodedVideoFrames) "
                + "software-temporary-peak=\(snapshot.peakTemporaryDecodedVideoFrames) "
                + "software-queue-peak=\(snapshot.peakVideoFrameQueueDepth) "
                + "software-pipeline-capacity="
                + "\(snapshot.videoPipelineCapacity) "
                + "software-pipeline-in-use="
                + "\(snapshot.videoPipelineCapacityInUse) "
                + "software-pipeline-in-use-peak="
                + "\(snapshot.peakVideoPipelineCapacityInUse) "
                + "software-pipeline-waiters="
                + "\(snapshot.videoPipelineCapacityWaiters) "
                + "software-samples-submitted=\(snapshot.framesSubmitted) "
                + "software-starvations=\(snapshot.rendererStarvations) "
                + "software-backpressure-events=\(snapshot.rendererBackpressureEvents) "
                + "software-backpressure-seconds="
                + "\(String(format: "%.6f", snapshot.rendererBackpressureSeconds)) "
                + "software-old-generation-retained-upper="
                + "\(oldGenerationRetained) "
                + "software-known-owned="
                + "\(snapshot.softwareOwnershipKnownOutstandingBuffers) "
                + "software-known-owned-peak="
                + "\(snapshot.softwareOwnershipPeakKnownOutstandingBuffers) "
                + "software-app-owned=\(snapshot.softwareOwnershipApplicationFrames) "
                + "software-app-owned-peak="
                + "\(snapshot.softwareOwnershipPeakApplicationFrames) "
                + "software-decoded-owned=\(snapshot.softwareOwnershipDecodedFrames) "
                + "software-queue-wait-owned="
                + "\(snapshot.softwareOwnershipFramesWaitingForQueue) "
                + "software-queued-owned=\(snapshot.softwareOwnershipQueuedFrames) "
                + "software-presenting-owned="
                + "\(snapshot.softwareOwnershipPresentingFrames) "
                + "software-submitted-app-owned="
                + "\(snapshot.softwareOwnershipSubmittedApplicationFrames) "
                + "software-renderer-sample-owned="
                + "\(snapshot.softwareOwnershipRendererSampleAttachments) "
                + "software-renderer-sample-owned-peak="
                + "\(snapshot.softwareOwnershipPeakRendererSampleAttachments) "
                + "software-old-generation-known-owned="
                + "\(snapshot.softwareOwnershipOldGenerationKnownBuffers) "
                + "software-reuse-while-known-owned="
                + "\(snapshot.softwareOwnershipReuseWhileKnownOwned) "
                + "software-ownership-pool-waits="
                + "\(snapshot.softwareOwnershipPoolThresholdWaits) "
                + "software-ownership-pool-timeouts="
                + "\(snapshot.softwareOwnershipPoolTimeouts) "
                + "software-timeout-known-owned=\(timeoutKnownOwned) "
                + "software-timeout-app-owned=\(timeoutApplicationFrames) "
                + "software-timeout-queued-owned=\(timeoutQueuedFrames) "
                + "software-timeout-renderer-sample-owned="
                + "\(timeoutRendererSamples) "
                + "software-timeout-oldest-sample-ms="
                + "\(timeoutOldestSampleMilliseconds) "
                + "software-flush-generation=\(flushGeneration) "
                + "software-flush-old-known-request=\(flushOldKnownAtRequest) "
                + "software-flush-old-samples-request=\(flushOldSamplesAtRequest) "
                + "software-flush-old-known-video-completion="
                + "\(flushOldKnownAtCompletion) "
                + "software-flush-old-samples-video-completion="
                + "\(flushOldSamplesAtCompletion) "
                + "software-flush-video-completion-ms="
                + "\(flushCompletionMilliseconds) "
                + "software-flush-old-known-zero-ms="
                + "\(flushOldKnownZeroMilliseconds) "
                + "recovery-domain="
                + "\(recoveryFailure?.domain.rawValue ?? "none") "
                + "recovery-stage="
                + "\(recoveryFailure?.stage.rawValue ?? "none") "
                + "recovery-code="
                + "\(recoveryFailure?.stableCode ?? "none") "
                + "recovery-native-code=\(recoveryNativeCode) "
                + "recovery-disposition="
                + "\(recoveryFailure?.recoverability.rawValue ?? "none") "
                + "recovery-hardware-configured="
                + "\(recoveryFailure?.hardwareWasConfigured == true ? "yes" : "no") "
                + "recovery-hardware-output="
                + "\(recoveryFailure?.hardwareOutputWasObserved == true ? "yes" : "no")"
        ),
        .diagnostic(
            "[native-presentation] "
                + "video-submit=\(snapshot.videoSubmissionAttempts) "
                + "video-enqueue-returned=\(snapshot.videoEnqueueReturnedWithoutImmediateFailure) "
                + "audio-submit=\(snapshot.audioSubmissionAttempts) "
                + "audio-enqueue-returned=\(snapshot.audioEnqueueReturnedWithoutImmediateFailure) "
                + "renderer-accepted=unmeasured "
                + "renderer-clock=video:\(videoClock),audio:\(audioClock) "
                + "renderer-time=\(String(format: "%.6f", snapshot.rendererMediaTimeSeconds)) "
                + "renderer-rate=\(snapshot.rendererRate) "
                + "renderer-clock-baseline="
                + "\(String(format: "%.6f", snapshot.rendererClockEpochBaselineSeconds)) "
                + "renderer-clock-maximum="
                + "\(String(format: "%.6f", snapshot.rendererClockMaximumSeconds)) "
                + "renderer-clock-advanced="
                + "\(snapshot.firstRendererClockAdvanceSeconds == nil ? "no" : "yes") "
                + "first-visible=unmeasured late=unmeasured dropped=unmeasured "
                + "flush=\(flush) drain=\(drain)"
        ),
        .diagnostic(
            "[native-observation] requests=\(observation.totalRequests) "
                + "scheduled=\(observation.scheduledDeliveries) "
                + "coalesced=\(observation.coalescedRequests) "
                + "delivered=\(observation.deliveredObservations) "
                + "followups=\(observation.followUpDeliveries) "
                + "max-delay-ms=\(String(format: "%.3f", maximumDelayMilliseconds)) "
                + "max-urgent-delay-ms=\(String(format: "%.3f", maximumUrgentDelayMilliseconds)) "
                + "sources=\(sourceCounts)"
        ),
    ]
}
