import AVFoundation
import CoreMedia
import Foundation
import OSLog
import SuperplayrCore
import SuperplayrPlaybackCore

struct MediaSessionSnapshot: Equatable, Sendable {
    var videoPacketDepth = 0
    var audioPacketDepth = 0
    var subtitlePacketDepth = 0
    var videoFrameDepth = 0
    var audioFrameDepth = 0
    var videoPacketProducerWaits = 0
    var videoPacketProducerWaitSeconds = 0.0
    var audioPacketProducerWaits = 0
    var audioPacketProducerWaitSeconds = 0.0
    var subtitlePacketProducerWaits = 0
    var subtitlePacketProducerWaitSeconds = 0.0
    var demuxDeferredPacketDepth = 0
    var peakDemuxDeferredPacketDepth = 0
    var demuxDeferredVideoPackets = 0
    var demuxDeferredAudioPackets = 0
    var demuxDeferredSubtitlePackets = 0
    var demuxDeferredPacketCount = 0
    var demuxCapacityWaits = 0
    var demuxCapacityWaitSeconds = 0.0
    // End timestamps of the latest samples accepted by each renderer. These
    // are enqueue horizons, not observations of visible or audible output.
    var videoPTS = 0.0
    var audioPTS = 0.0
    var audioOutputChannels: Int?
    var audioOutputSampleRate: Int?
    var audioDownmixOccurred: Bool?
    var firstEnqueuedVideoPTS: Double?
    var firstEnqueuedAudioPTS: Double?
    var bufferedVideoDuration = 0.0
    var bufferedAudioDuration = 0.0
    var discardedStalePackets = 0
    var discardedStaleFrames = 0
    // Number of video enqueue calls that returned without an immediate
    // renderer failure. This is submission evidence, not presentation.
    var framesSubmitted = 0
    var videoSubmissionAttempts = 0
    var videoEnqueueReturnedWithoutImmediateFailure = 0
    var audioSubmissionAttempts = 0
    var audioEnqueueReturnedWithoutImmediateFailure = 0
    var firstVideoRendererClockEvidenceSeconds: Double?
    var firstAudioRendererClockEvidenceSeconds: Double?
    var rendererMediaTimeSeconds = 0.0
    var rendererRate: Float = 0
    var rendererClockEpochBaselineSeconds = 0.0
    var rendererClockMaximumSeconds = 0.0
    var firstRendererClockAdvanceSeconds: Double?
    var presentationFence: UInt64 = 0
    var firstVisibleFrameSeconds: Double?
    var rendererLateFrames: Int?
    var rendererDroppedFrames: Int?
    var flushRequested = false
    var flushCompleted = false
    var rendererDrainEvidence = false
    var rendererStarvations = 0
    var rendererBackpressureEvents = 0
    var rendererBackpressureSeconds = 0.0
    var peakVideoFrameQueueDepth = 0
    var videoPipelineCapacity = 0
    var videoPipelineCapacityInUse = 0
    var peakVideoPipelineCapacityInUse = 0
    var videoPipelineCapacityWaiters = 0
    var temporaryDecodedVideoFrames = 0
    var peakTemporaryDecodedVideoFrames = 0
    /// Distinct buffer identities observed during the current pool lifetime;
    /// not the number of buffers currently allocated or retained.
    var softwarePoolAllocatedBuffers = 0
    var softwarePoolReusedCheckouts = 0
    var softwarePoolBytesPerBuffer = 0
    var softwarePoolMaximumBuffers = 0
    var softwarePoolInUseUpperBound = 0
    var softwarePoolFreeLowerBound = 0
    var softwarePoolThresholdWaits = 0
    var softwarePoolTimeouts = 0
    var softwarePoolCancellations = 0
    var softwareBGRAFallbackFrames = 0
    var softwareDecodeErrorsDropped = 0
    var softwareCorruptFramesDropped = 0
    var softwareOldGenerationRetainedUpperBound: Int?
    var softwareOwnershipApplicationFrames = 0
    var softwareOwnershipPeakApplicationFrames = 0
    var softwareOwnershipDecodedFrames = 0
    var softwareOwnershipFramesWaitingForQueue = 0
    var softwareOwnershipQueuedFrames = 0
    var softwareOwnershipPresentingFrames = 0
    var softwareOwnershipSubmittedApplicationFrames = 0
    var softwareOwnershipRendererSampleAttachments = 0
    var softwareOwnershipPeakRendererSampleAttachments = 0
    var softwareOwnershipKnownOutstandingBuffers = 0
    var softwareOwnershipPeakKnownOutstandingBuffers = 0
    var softwareOwnershipOldGenerationKnownBuffers = 0
    var softwareOwnershipReuseWhileKnownOwned = 0
    var softwareOwnershipPoolThresholdWaits = 0
    var softwareOwnershipPoolTimeouts = 0
    var softwareOwnershipLastTimeout: PlanarPoolTimeoutOwnershipSnapshot?
    var softwareOwnershipLastFlush: PlanarFlushOwnershipSnapshot?
    var seekCount = 0
    var seekTimings: SeekPerformanceTimings?
    var discardedSeekPrerollFrames = 0
    var seekPrerollNonReferencePackets = 0
    var softwareSeekAccelerationCount = 0
    var hardwareSeekRestorationCount = 0
    var hardwareFallbackCount = 0
    var generation = 0
    var rendererReady = false
    var isPrerolled = false
    var rendererFailure: String?
    var ffmpegPixelFormat = "Unknown"
    var usesDeinterlacingFilter = false
    var deinterlacingFailure: String?
    var pixelBufferFormat = "Unknown"
    var hardwareDecoder = "Not initialized"
    var lastRecoveryMessage: String?
    var lastRecoveryFailure: PlaybackFailure?
    var isHardwareDecoded = false
    var isCopiedHardwarePath = false
    var isNearZeroCopy = false
    var colorPrimaries: Int32?
    var transferCharacteristic: Int32?
    var matrixCoefficients: Int32?
    var isFullRange = false
    var hasMasteringDisplayMetadata = false
    var hasContentLightMetadata = false
    var subtitleEventCount = 0
    var decoderDrainComplete = false
    var ended = false
    var isBuffering = false

    mutating func beginDifferentialSeekObservation() {
        firstEnqueuedVideoPTS = nil
        firstEnqueuedAudioPTS = nil
    }

    @discardableResult
    mutating func recordEnqueuedVideo(startPTS: Double, endPTS: Double, generation candidate: Int) -> Bool {
        guard candidate == generation else { return false }
        if firstEnqueuedVideoPTS == nil { firstEnqueuedVideoPTS = startPTS }
        videoPTS = endPTS
        return true
    }

    @discardableResult
    mutating func recordEnqueuedAudio(startPTS: Double, endPTS: Double, generation candidate: Int) -> Bool {
        guard candidate == generation else { return false }
        if firstEnqueuedAudioPTS == nil { firstEnqueuedAudioPTS = startPTS }
        audioPTS = endPTS
        return true
    }
}

private enum DemuxWork {
    case seek(SeekRequest)
    case read(generation: Int)
}

private enum DemuxPacketDestination: Hashable, Sendable {
    case video
    case audio
    case subtitle
}

private struct NativeVideoFormatSignature: Equatable {
    let width: Int
    let height: Int
    let pixelFormat: OSType
    let colorPrimaries: Int32?
    let transfer: Int32?
    let matrix: Int32?
    let fullRange: Bool
    let codedSize: CGSize
    let displaySize: CGSize
    let pixelAspectRatio: CGSize
    let rotationDegrees: Double
    let chromaLocation: Int32?
    let cleanAperture: CGRect?
    let masteringDisplayMetadata: Data?
    let contentLightMetadata: Data?
}

struct NativeVideoGeometry: Equatable, Sendable {
    let displaySize: CGSize
    let rotationDegrees: Double
}

enum MediaSessionEndPolicy {
    static func shouldFinish(
        decoderDrainComplete: Bool,
        rendererDrainEvidence: Bool,
        successfulVideoSubmissions: Int,
        successfulAudioSubmissions: Int
    ) -> Bool {
        guard decoderDrainComplete else { return false }
        let hasSubmittedMedia = successfulVideoSubmissions > 0
            || successfulAudioSubmissions > 0
        return rendererDrainEvidence || !hasSubmittedMedia
    }

    static func isSupplyStarved(
        presentationRate: Float,
        beforeEnd: Bool,
        decoderDrainComplete: Bool,
        videoStarved: Bool,
        audioStarved: Bool
    ) -> Bool {
        presentationRate > 0
            && beforeEnd
            && !decoderDrainComplete
            && (videoStarved || audioStarved)
    }

    static func isStreamStarved(
        isSelected: Bool,
        packetDepth: Int,
        frameDepth: Int,
        rendererBufferedDuration: Double
    ) -> Bool {
        isSelected
            && packetDepth == 0
            && frameDepth == 0
            && rendererBufferedDuration <= 0
    }
}

enum SoftwareVideoRecoveryDisposition: Equatable {
    case packetReplay(packetCount: Int)
    case seek(generation: Int)
}

final class MediaSession: @unchecked Sendable {
    let contentVersion: MediaContentVersion?
    let mediaInfo: FFmpegMediaInfo
    let presentation: NativePresentationCoordinator
    let subtitles: SubtitlePipeline
    private let pictureInPictureSubtitles: SubtitlePipeline?
    private(set) var registeredAttachmentNames: [String] = []

    var activeAudioStream: FFmpegStreamInfo? { selectedAudio }
    var activeSubtitleStream: FFmpegStreamInfo? { selectedSubtitle }
    var activeSubtitleSource: NativeSubtitleSource { subtitleSource }
    var pictureInPictureSubtitlePipeline: SubtitlePipeline? {
        pictureInPictureSubtitles
    }
    var seekInProgress: Bool { seeks.isActive }
    var currentGeneration: Int { generation.current }
    var currentVideoGeometry: NativeVideoGeometry? {
        stateLock.withLock { videoGeometry }
    }

    private let input: FFmpegInputExecutor
    private let subtitleInput: FFmpegInputExecutor?
    private let delayedAudioInput: FFmpegInputExecutor?
    let audioDelay: TimeInterval
    private let audioSeekLock = NSLock()
    private var pendingAudioSeek: SeekRequest?
    private let audioEndWait = MediaReadAheadGate()
    private let videoDecoder: VideoDecoder?
    private let audioDecoder: AudioDecoder?
    private let subtitleDecoder: SubtitleDecoder?
    private let selectedVideo: FFmpegStreamInfo?
    private let selectedAudio: FFmpegStreamInfo?
    private let selectedSubtitle: FFmpegStreamInfo?
    private let subtitleSource: NativeSubtitleSource
    private let subtitleTimelineOrigin: TimeInterval
    private let onSeekCompleted: (@Sendable (_ generation: Int, _ wasPreview: Bool) -> Void)?
    private let onSeekFailed: (@Sendable (_ generation: Int, PlaybackFailure) -> Void)?
    private let onObservationRequested: (@Sendable (RuntimeObservationRequest) -> Void)?
    private let onFailureObserved: (@Sendable (PlaybackFailure) -> Void)?
    private let onSubtitleDiagnostic: (@Sendable (String) -> Void)?
    private let onSynchronizationObserved: (@Sendable (SynchronizationCoreEvent) -> Void)?
    private let generation = PlaybackGeneration()
    private let seeks = SeekTransactionReducer()
    private let seekTransitionLock = NSLock()
    private let subtitleSeekLock = NSLock()
    private let subtitleReadAhead = MediaReadAheadGate()
    private let demuxEndWait = MediaReadAheadGate()
    private let formatTransitionLock = NSLock()
    private let formatReconfiguration = NativeFormatReconfigurationBarrier()
    private let recovery: NativeRecoveryController
    private let synchronization: NativeSynchronizationController
    private let videoDemand = RendererDemandGate()
    private let audioDemand = RendererDemandGate()
    private let videoDemandQueue = DispatchQueue(
        label: "com.superplayr.native.video-demand",
        qos: .userInteractive
    )
    private let audioDemandQueue = DispatchQueue(
        label: "com.superplayr.native.audio-demand",
        qos: .userInteractive
    )

    private let videoPackets = BoundedQueue<PacketQueueItem>(
        capacity: 96,
        byteCapacity: 32 * 1_024 * 1_024,
        durationCapacityMicroseconds: 4_000_000,
        cost: \.boundedQueueCost
    )
    private let audioPackets = BoundedQueue<PacketQueueItem>(
        capacity: 192,
        byteCapacity: 8 * 1_024 * 1_024,
        durationCapacityMicroseconds: 4_000_000,
        cost: \.boundedQueueCost
    )
    private let subtitlePackets = BoundedQueue<PacketQueueItem>(
        capacity: 64,
        byteCapacity: 4 * 1_024 * 1_024,
        durationCapacityMicroseconds: 30_000_000,
        cost: \.boundedQueueCost
    )
    private let videoFrames: BoundedQueue<VideoFrameQueueItem>
    private let audioFrames = BoundedQueue<AudioFrameQueueItem>(capacity: 48)
    private let videoPipelineCapacityGate: VideoFrameCapacityGate?
    private let usesFairDemuxDispatch: Bool
    private let videoRecoveryPackets = VideoRecoveryPacketBuffer()

    private let workerGroup = DispatchGroup()
    private let stateLock = NSLock()
    private var running = false
    private var desiredRate: Float = 1
    private var presentationWorkersStarted = false
    private var presentationWorkersSuspended = false
    private var preparingForCommit = false
    private var hasDecodedVideoFrame = false
    private var hasDecodedAudioFrame = false
    private var videoSeekFloor: (generation: Int, seconds: Double)?
    private var audioSeekFloor: (generation: Int, seconds: Double)?
    private var previewGeneration: Int?
    private var pendingSubtitleSeek: SeekRequest?
    private var startedGeneration: Int?
    private var endedVideoGeneration: Int?
    private var endedAudioGeneration: Int?
    private var wasSupplyStarved = false
    private var decoderDrainComplete = false
    private var consecutiveHardwareDecodeFailures = 0
    private var didPauseAtEnd = false
    private var videoEndOfStreamDemand = EndOfStreamDemandLifecycle()
    private var audioEndOfStreamDemand = EndOfStreamDemandLifecycle()
    private var metrics = MediaSessionSnapshot()
    private var presentationFence: PresentationFence
    private var videoFormatSignature: NativeVideoFormatSignature?
    private var videoFormatRevision: UInt64 = 0
    private var audioFormatRevision: UInt64?
    private var pendingVideoRecoveryReplay: [FFmpegPacket] = []
    private var videoGeometry: NativeVideoGeometry?
    private var audioDisabled = false
    private var subtitleDisabled = false

    init(
        url: URL,
        presentation: NativePresentationCoordinator,
        subtitles: SubtitlePipeline,
        pictureInPictureSubtitles: SubtitlePipeline? = nil,
        trackSelectionPreferences: TrackSelectionPreferences = .init(),
        bitmapForcedOnlyOverride: Bool? = nil,
        selectedAudioIndex: Int32? = nil,
        audioDelay: TimeInterval = 0,
        selectedSubtitleIndex: Int32? = nil,
        subtitleSource: NativeSubtitleSource? = nil,
        preferHardware: Bool = true,
        seekPrerollFrameSkippingEnabled: Bool = true,
        softwareSeekAccelerationEnabled: Bool = true,
        softwareVideoOutputMode: SoftwareVideoOutputMode = .bgra,
        videoFrameQueueCapacity: Int = 12,
        reservesVideoPipelineCapacity: Bool = true,
        videoPipelineCapacityOverride: Int? = nil,
        usesFairDemuxDispatch: Bool = false,
        softwarePlanarOutputMaximumBufferCount: Int =
            SoftwareBGRAOutputPool.qualifiedMaximumBufferCount,
        constructionCancellation: FFmpegInputCancellationSignal? = nil,
        sessionID: PlaybackSessionID = PlaybackSessionID(rawValue: 0),
        onLifecycleTrace: (@Sendable (String) -> Void)? = nil,
        onSeekCompleted: (@Sendable (_ generation: Int, _ wasPreview: Bool) -> Void)? = nil,
        onSeekFailed: (@Sendable (_ generation: Int, PlaybackFailure) -> Void)? = nil,
        onFailureObserved: (@Sendable (PlaybackFailure) -> Void)? = nil,
        onSubtitleDiagnostic: (@Sendable (String) -> Void)? = nil,
        onSynchronizationObserved: (@Sendable (SynchronizationCoreEvent) -> Void)? = nil,
        onObservationRequested: (@Sendable (RuntimeObservationRequest) -> Void)? = nil
    ) throws {
        let boundedVideoFrameCapacity = max(1, videoFrameQueueCapacity)
        videoFrames = BoundedQueue<VideoFrameQueueItem>(
            capacity: boundedVideoFrameCapacity
        )
        // Controlled flush/recheckout probes found as many as five pool
        // buffers temporarily unavailable after every known application and
        // CMSampleBuffer owner had released. Active playback separately
        // observed up to four live renderer-sample attachments. Reserve both
        // measured classes; the remaining permits include the decoder's
        // pre-allocation reservation and application-owned frames.
        let measuredRendererRetentionAllowance = 5 + 4
        let softwarePoolCapacity = min(
            SoftwareBGRAOutputPool.qualifiedMaximumBufferCount,
            max(1, softwarePlanarOutputMaximumBufferCount)
        )
        let reservablePipelineCapacity = max(
            1,
            softwarePoolCapacity - measuredRendererRetentionAllowance
        )
        let selectedPipelineCapacity = videoPipelineCapacityOverride.map {
            min(max(1, $0), boundedVideoFrameCapacity, softwarePoolCapacity)
        } ?? min(boundedVideoFrameCapacity, reservablePipelineCapacity)
        videoPipelineCapacityGate = reservesVideoPipelineCapacity
            ? VideoFrameCapacityGate(capacity: selectedPipelineCapacity)
            : nil
        self.usesFairDemuxDispatch = usesFairDemuxDispatch
        try constructionCancellation?.checkCancellation()
        onLifecycleTrace?("input-opening")
        let versionBeforeOpen = NativeFileContentVersion.read(url)
        try constructionCancellation?.checkCancellation()
        let openedInput = try FFmpegInputExecutor(
            url: url,
            cancellationSignal: constructionCancellation
        )
        try constructionCancellation?.checkCancellation()
        onLifecycleTrace?("input-opened")
        contentVersion = NativeFileContentVersion.verified(
            before: versionBeforeOpen, after: NativeFileContentVersion.read(url)
        )
        try constructionCancellation?.checkCancellation()
        let openedMediaInfo = openedInput.mediaInfo
        let videoStream = openedMediaInfo.videoStreams.first {
            $0.index == openedMediaInfo.selectedVideoIndex
        }
        let audioIndex = selectedAudioIndex ?? openedMediaInfo.preferredTrackIndex(
            .audio, preferences: trackSelectionPreferences
        )
        let audioStream = openedMediaInfo.audioStreams.first { $0.index == audioIndex }
        self.audioDelay = audioStream == nil ? 0 : AudioDelayTimeline.bounded(audioDelay)
        delayedAudioInput = self.audioDelay == 0 ? nil : try FFmpegInputExecutor(
            url: url, cancellationSignal: constructionCancellation)
        let requestedSubtitleSource = subtitleSource
            ?? selectedSubtitleIndex.map(NativeSubtitleSource.embedded)
            ?? .automaticEmbedded
        let resolvedSubtitleSource: NativeSubtitleSource
        if requestedSubtitleSource == .automaticEmbedded {
            resolvedSubtitleSource = openedMediaInfo.preferredTrackIndex(
                .subtitle, preferences: trackSelectionPreferences, audioLanguage: audioStream?.language
            ).map(NativeSubtitleSource.embedded) ?? .off
        } else {
            resolvedSubtitleSource = requestedSubtitleSource
        }
        let subtitleStream: FFmpegStreamInfo?
        let openedSubtitleInput: FFmpegInputExecutor?
        if case let .externalBitmap(subtitleURL, index) = resolvedSubtitleSource {
            let external = try FFmpegInputExecutor(url: subtitleURL, cancellationSignal: constructionCancellation)
            guard let stream = external.mediaInfo.subtitleStreams.first(where: { $0.index == index && $0.subtitleCapability == .bitmap }) else {
                throw PresentationError("The selected external bitmap subtitle track is unavailable.")
            }
            openedSubtitleInput = external
            subtitleStream = stream
            subtitleTimelineOrigin = 0
        } else {
            subtitleStream = resolvedSubtitleSource.resolve(in: openedMediaInfo)
            openedSubtitleInput = subtitleStream == nil ? nil : try FFmpegInputExecutor(url: url, cancellationSignal: constructionCancellation)
            subtitleTimelineOrigin = openedMediaInfo.startTime
        }
        try constructionCancellation?.checkCancellation()

        let openedVideoDecoder: VideoDecoder?
        if let videoStream,
           let parameters = try openedInput.copyCodecParameters(streamIndex: videoStream.index)
        {
            openedVideoDecoder = try parameters.withUnsafePointer {
                try VideoDecoder(
                    parameters: $0,
                    stream: videoStream,
                    preferHardware: preferHardware,
                    timelineOriginSeconds: openedMediaInfo.startTime,
                    softwareOutputMode: softwareVideoOutputMode,
                    softwarePlanarOutputMaximumBufferCount:
                        softwarePlanarOutputMaximumBufferCount,
                    seekPrerollFrameSkippingEnabled: seekPrerollFrameSkippingEnabled,
                    softwareSeekAccelerationEnabled: softwareSeekAccelerationEnabled
                )
            }
        } else {
            openedVideoDecoder = nil
        }
        try constructionCancellation?.checkCancellation()
        onLifecycleTrace?("video-decoder-opened")
        let openedAudioDecoder: AudioDecoder?
        if let audioStream,
           let parameters = try openedInput.copyCodecParameters(streamIndex: audioStream.index)
        {
            openedAudioDecoder = try parameters.withUnsafePointer {
                try AudioDecoder(
                    parameters: $0,
                    stream: audioStream,
                    timelineOriginSeconds: openedMediaInfo.startTime,
                    outputCapacity: presentation.audioOutputCapacity
                )
            }
        } else {
            openedAudioDecoder = nil
        }
        try constructionCancellation?.checkCancellation()
        onLifecycleTrace?("audio-decoder-opened")
        let openedSubtitleDecoder: SubtitleDecoder?
        if let subtitleStream,
           let parameters = try openedSubtitleInput?.copyCodecParameters(
            streamIndex: subtitleStream.index
           )
        {
            openedSubtitleDecoder = try parameters.withUnsafePointer {
                try SubtitleDecoder(parameters: $0, stream: subtitleStream, memoryBudget: subtitles.sharedMemoryBudget,
                                    fallbackCanvasSize: videoStream?.codedSize)
            }
        } else {
            openedSubtitleDecoder = nil
        }
        try constructionCancellation?.checkCancellation()
        onLifecycleTrace?("subtitle-decoder-opened")

        input = openedInput
        subtitleInput = openedSubtitleInput
        mediaInfo = openedMediaInfo
        self.presentation = presentation
        presentationFence = presentation.currentFence
        self.subtitles = subtitles
        self.pictureInPictureSubtitles = pictureInPictureSubtitles
        selectedVideo = videoStream
        selectedAudio = audioStream
        selectedSubtitle = subtitleStream
        self.subtitleSource = resolvedSubtitleSource
        videoDecoder = openedVideoDecoder
        audioDecoder = openedAudioDecoder
        subtitleDecoder = openedSubtitleDecoder
        self.onSeekCompleted = onSeekCompleted
        self.onSeekFailed = onSeekFailed
        self.onObservationRequested = onObservationRequested
        self.onFailureObserved = onFailureObserved
        self.onSubtitleDiagnostic = onSubtitleDiagnostic
        self.onSynchronizationObserved = onSynchronizationObserved
        recovery = NativeRecoveryController()
        synchronization = NativeSynchronizationController(
            hasVideo: videoStream != nil,
            hasAudio: audioStream != nil
        )

        let videoSize = selectedVideo?.displaySize ?? CGSize(width: 1_920, height: 1_080)
        registeredAttachmentNames = try subtitles.configure(
            codecPrivate: subtitleStream.flatMap {
                openedSubtitleInput?.codecPrivateData(streamIndex: $0.index)
            },
            codecName: subtitleStream?.codecName,
            attachments: mediaInfo.attachments,
            frameSize: videoSize,
            storageSize: videoSize
        )
        try constructionCancellation?.checkCancellation()
        if let pictureInPictureSubtitles {
            _ = try pictureInPictureSubtitles.configure(
                codecPrivate: subtitleStream.flatMap {
                    openedSubtitleInput?.codecPrivateData(streamIndex: $0.index)
                },
                codecName: subtitleStream?.codecName,
                attachments: mediaInfo.attachments,
                frameSize: videoSize,
                storageSize: videoSize
            )
        }
        try constructionCancellation?.checkCancellation()
        onLifecycleTrace?("subtitle-pipeline-configured")
        let forcesBitmapEventsOnly = bitmapForcedOnlyOverride ?? (
            requestedSubtitleSource == .automaticEmbedded && trackSelectionPreferences.subtitles == .forcedOnly
                && subtitleStream?.subtitleCapability == .bitmap
                && subtitleStream?.selectionCandidate?.track.isForced != true
        )
        subtitles.forcesBitmapEventsOnly = forcesBitmapEventsOnly
        pictureInPictureSubtitles?.forcesBitmapEventsOnly = forcesBitmapEventsOnly
        stateLock.withLock {
            metrics.generation = generation.current
            metrics.hardwareDecoder = openedVideoDecoder?.hardwareStatusDescription
                ?? "Software decoder"
        }
    }

    deinit { stop() }

    func start(rate: Float = 1) {
        guard startDecodeWorkers(rate: rate, preparingForCommit: false) else {
            return
        }
        startPresentationWorkers()
    }

    /// Starts bounded demux/decode work without acquiring the shared
    /// presentation graph. The current session can continue presenting until
    /// this candidate has produced the required first decoded samples.
    @discardableResult
    func prepareForCommit() -> Bool {
        startDecodeWorkers(rate: 0, preparingForCommit: true)
    }

    var isPreparedForCommit: Bool {
        let state = stateLock.withLock {
            (
                running,
                preparingForCommit,
                hasDecodedVideoFrame,
                hasDecodedAudioFrame,
                metrics.rendererFailure,
                audioDisabled
            )
        }
        guard state.0, state.1, state.4 == nil else { return false }
        return (selectedVideo == nil || state.2)
            && (selectedAudio == nil || state.5 || state.3)
            && (selectedVideo != nil || (selectedAudio != nil && !state.5))
    }

    @discardableResult
    func commitPrepared(rate: Float) -> Bool {
        let accepted = stateLock.withLock { () -> Bool in
            guard running,
                  preparingForCommit,
                  !presentationWorkersStarted,
                  metrics.rendererFailure == nil,
                  (selectedVideo == nil || hasDecodedVideoFrame),
                  (selectedAudio == nil || audioDisabled || hasDecodedAudioFrame)
            else { return false }
            preparingForCommit = false
            desiredRate = rate
            return true
        }
        guard accepted else { return false }
        startPresentationWorkers()
        return true
    }

    /// Quiesces this session at the physical commit boundary while leaving its
    /// bounded decode queues intact for deterministic rollback.
    func suspendPresentationForReplacement() {
        let shouldSuspend = stateLock.withLock { () -> Bool in
            guard running,
                  presentationWorkersStarted,
                  !presentationWorkersSuspended
            else { return false }
            presentationWorkersSuspended = true
            desiredRate = 0
            return true
        }
        guard shouldSuspend else { return }
        _ = presentation.pause(fence: stateLock.withLock { presentationFence })
        presentation.video.stopRequestingMediaData()
        presentation.audio.stopRequestingMediaData()
        videoDemand.revoke()
        audioDemand.revoke()
    }

    @discardableResult
    func resumePresentationAfterReplacementRollback(
        fence: PresentationFence,
        playing: Bool
    ) -> Bool {
        let shouldResume = stateLock.withLock { () -> Bool in
            guard running, presentationWorkersStarted else { return false }
            presentationWorkersSuspended = false
            presentationFence = fence
            desiredRate = playing ? 1 : 0
            return true
        }
        guard shouldResume else { return false }
        armRendererDemand()
        return presentation.setRate(playing ? 1 : 0, fence: fence)
    }

    private func startDecodeWorkers(
        rate: Float,
        preparingForCommit: Bool
    ) -> Bool {
        let shouldStart = stateLock.withLock { () -> Bool in
            guard !running else { return false }
            running = true
            desiredRate = rate
            self.preparingForCommit = preparingForCommit
            return true
        }
        guard shouldStart else { return false }
        synchronization.beginGeneration(generation.current)
        launch("demux", body: demuxLoop)
        if videoDecoder != nil {
            launch("video-decode", body: videoDecodeLoop)
        }
        if audioDecoder != nil {
            launch("audio-decode", body: audioDecodeLoop)
        }
        if selectedSubtitle != nil {
            launch("subtitle-demux", body: subtitleDemuxLoop)
        }
        return true
    }

    private func startPresentationWorkers() {
        let shouldStart = stateLock.withLock { () -> Bool in
            guard running, !presentationWorkersStarted else { return false }
            presentationWorkersStarted = true
            presentationWorkersSuspended = false
            return true
        }
        guard shouldStart else { return }
        armRendererDemand()
        if videoDecoder != nil {
            launch("video-present", body: videoPresentationLoop)
        }
        if audioDecoder != nil {
            launch("audio-present", body: audioPresentationLoop)
        }
    }

    @discardableResult
    func requestTransport(playing: Bool, speed: Float = 1) -> Bool {
        let state = stateLock.withLock { () -> (Float, PresentationFence) in
            desiredRate = playing ? speed : 0
            return (desiredRate, presentationFence)
        }
        return presentation.setRate(state.0, fence: state.1)
    }

    func adoptPresentationFence(_ fence: PresentationFence) {
        stateLock.withLock { presentationFence = fence }
    }

    @MainActor
    func setSubtitlePresentationAuthorityEnabled(_ enabled: Bool) {
        subtitles.setPresentationAuthorityEnabled(enabled)
        pictureInPictureSubtitles?.setPresentationAuthorityEnabled(enabled)
    }

    @discardableResult
    func seek(
        to seconds: Double,
        exact: Bool,
        resumeRate: Float,
        isPreview: Bool = false
    ) -> Int {
        let nonnegativeTarget = max(seconds, 0)
        let targetSeconds = switch mediaInfo.durationStatus {
        case .valid(let duration): min(nonnegativeTarget, max(duration, 0))
        case .unknown, .invalid: nonnegativeTarget
        }
        let target = CMTime(seconds: targetSeconds, preferredTimescale: 60_000)
        var shouldResumeVideoDemand = false
        var shouldResumeAudioDemand = false
        var dispatchedGeneration = generation.current
        seekTransitionLock.withLock {
            let newGeneration = generation.advance()
            dispatchedGeneration = newGeneration
            stateLock.withLock {
                desiredRate = resumeRate
                // Preview seeks deliberately accept the preceding keyframe.
                // The final exact seek decodes forward and rejects output
                // before the requested presentation boundary.
                videoSeekFloor = selectedVideo == nil || isPreview
                    ? nil
                    : (newGeneration, targetSeconds)
                audioSeekFloor = selectedAudio == nil || audioDisabled || isPreview
                    ? nil
                    : (newGeneration, targetSeconds)
                previewGeneration = isPreview ? newGeneration : nil
                startedGeneration = nil
                endedVideoGeneration = nil
                endedAudioGeneration = nil
                metrics.generation = newGeneration
                metrics.seekCount += 1
                metrics.seekTimings = SeekPerformanceTimings(
                    generation: newGeneration,
                    requestedUptime: ProcessInfo.processInfo.systemUptime
                )
                metrics.discardedSeekPrerollFrames = 0
                metrics.seekPrerollNonReferencePackets = 0
                metrics.softwareSeekAccelerationCount = 0
                metrics.hardwareSeekRestorationCount = 0
                metrics.ended = false
                metrics.beginDifferentialSeekObservation()
                decoderDrainComplete = false
                didPauseAtEnd = false
                shouldResumeVideoDemand = videoEndOfStreamDemand.resumeIfNeeded()
                shouldResumeAudioDemand = audioEndOfStreamDemand.resumeIfNeeded()
            }
            synchronization.beginGeneration(
                newGeneration,
                videoOnly: isPreview
            )
            let seekRequest = SeekRequest(
                target: target,
                exact: exact,
                generation: newGeneration,
                resumeRate: resumeRate,
                isPreview: isPreview
            )
            seeks.submit(seekRequest)
            let decoder = videoDecoder
            decoder?.recordPlanarFlushRequested(activeGeneration: newGeneration)
            let recordVideoFlushCompletion = decoder?.planarVideoFlushCompletionRecorder(
                activeGeneration: newGeneration
            )
            videoPackets.removeAll()
            audioPackets.removeAll()
            subtitlePackets.removeAll()
            videoFrames.removeAll()
            audioFrames.removeAll()
            videoRecoveryPackets.reset(generation: newGeneration)
            stateLock.withLock { pendingVideoRecoveryReplay.removeAll() }
            seeks.acknowledge(.packetAndFrameQueues, generation: newGeneration)
            subtitleSeekLock.withLock {
                // Cancel the prior input call before publishing the new seek;
                // otherwise the subtitle worker can start the new lookup and
                // have that lookup accidentally cancelled by this transition.
                _ = subtitleInput?.cancelActiveOperation()
                subtitles.clear(generation: newGeneration)
                pictureInPictureSubtitles?.clear(generation: newGeneration)
                pendingSubtitleSeek = seekRequest
            }
            audioSeekLock.withLock {
                _ = delayedAudioInput?.cancelActiveOperation()
                pendingAudioSeek = seekRequest
            }
            audioEndWait.reset(generation: newGeneration, position: target.seconds)
            seeks.acknowledge(.subtitleVisibleClear, generation: newGeneration)
            seeks.acknowledge(.subtitleSourceInvalidation, generation: newGeneration)
            // A renderer flush invalidates all queued samples, so retaining the
            // already-presented image cannot leak an old-generation frame back
            // into playback. Keep that image visible until the first accepted
            // frame from the new generation replaces it; removing it here makes
            // exact and arrow-key seeks visibly flash the layer's black backing.
            let fence = presentation.installFenceAndRequestFlush(
                at: target,
                removeDisplayedImage: false,
                videoFlushCompletion: { _ in recordVideoFlushCompletion?() }
            )
            stateLock.withLock { presentationFence = fence }
            seeks.acknowledge(.presentationFence, generation: newGeneration)
            let cancellation = input.cancelActiveOperation()
            if cancellation == .interruptRequested || cancellation == .targetNotActive {
                seeks.acknowledge(.inputReadCancellation, generation: newGeneration)
            }
            subtitleReadAhead.reset(generation: newGeneration, position: target.seconds)
            demuxEndWait.reset(generation: newGeneration, position: target.seconds)
        }
        if shouldResumeVideoDemand { armVideoRendererDemand() }
        if shouldResumeAudioDemand { armAudioRendererDemand() }
        return dispatchedGeneration
    }

    @discardableResult
    func cancelActiveInputOperation() -> FFmpegInputCancellationDisposition {
        input.cancelActiveOperation()
    }

    func stop(releasesPresentation: Bool = true) {
        let stopState = stateLock.withLock { () -> (Bool, Bool) in
            let value = running
            running = false
            return (value, presentationWorkersStarted)
        }
        formatReconfiguration.cancelAll()
        subtitleReadAhead.close()
        audioEndWait.close()
        demuxEndWait.close()
        guard stopState.0 else { return }
        let newGeneration = generation.advance()
        let decoder = videoDecoder
        decoder?.recordPlanarFlushRequested(activeGeneration: newGeneration)
        let recordVideoFlushCompletion = decoder?.planarVideoFlushCompletionRecorder(
            activeGeneration: newGeneration
        )
        _ = input.cancelActiveOperation()
        _ = delayedAudioInput?.cancelActiveOperation()
        _ = subtitleInput?.cancelActiveOperation()
        videoPackets.close()
        audioPackets.close()
        subtitlePackets.close()
        videoFrames.close()
        audioFrames.close()
        videoRecoveryPackets.reset()
        stateLock.withLock { pendingVideoRecoveryReplay.removeAll() }
        videoPipelineCapacityGate?.close()
        videoDemand.close()
        audioDemand.close()
        if releasesPresentation, stopState.1 {
            presentation.video.stopRequestingMediaData()
            presentation.audio.stopRequestingMediaData()
        }
        subtitles.clear()
        pictureInPictureSubtitles?.clear()
        if releasesPresentation {
            let fence = presentation.stop { _ in recordVideoFlushCompletion?() }
            stateLock.withLock { presentationFence = fence }
        } else {
            recordVideoFlushCompletion?()
        }
    }

    func waitForShutdown(timeout: DispatchTime = .now() + 3) -> Bool {
        workerGroup.wait(timeout: timeout) == .success
    }

    func snapshot() -> MediaSessionSnapshot {
        let activeGeneration = generation.current
        let videoPacketContention = videoPackets.contentionSnapshot
        let audioPacketContention = audioPackets.contentionSnapshot
        let subtitlePacketContention = subtitlePackets.contentionSnapshot
        let planarOwnership = videoDecoder?.planarOwnershipSnapshot(
            activeGeneration: activeGeneration
        )
        let result = stateLock.withLock {
            () -> (MediaSessionSnapshot, PresentationFence, Bool, Double, Bool) in
            metrics.videoPacketDepth = videoPackets.count
            metrics.audioPacketDepth = audioPackets.count
            metrics.subtitlePacketDepth = subtitlePackets.count
            metrics.videoFrameDepth = videoFrames.count
            metrics.audioFrameDepth = audioFrames.count
            metrics.videoPacketProducerWaits = videoPacketContention.producerWaits
            metrics.videoPacketProducerWaitSeconds =
                videoPacketContention.producerWaitSeconds
            metrics.audioPacketProducerWaits = audioPacketContention.producerWaits
            metrics.audioPacketProducerWaitSeconds =
                audioPacketContention.producerWaitSeconds
            metrics.subtitlePacketProducerWaits = subtitlePacketContention.producerWaits
            metrics.subtitlePacketProducerWaitSeconds =
                subtitlePacketContention.producerWaitSeconds
            metrics.rendererReady = presentation.video.isReady
                && (selectedAudio == nil || audioDisabled || presentation.audio.isReady)
            metrics.isPrerolled = startedGeneration == generation.current
            if let presentationFailure = presentation.video.failureDescription {
                metrics.rendererFailure = presentationFailure
            }
            metrics.subtitleEventCount = subtitles.eventCount
            let sync = presentation.currentTime.seconds
            if sync.isFinite {
                metrics.bufferedVideoDuration = max(0, metrics.videoPTS - sync)
                metrics.bufferedAudioDuration = max(0, metrics.audioPTS - sync)
            }
            let beforeEnd = !metrics.ended && sync < max(mediaInfo.duration - 0.1, 0)
            let videoStarved = MediaSessionEndPolicy.isStreamStarved(
                isSelected: selectedVideo != nil && endedVideoGeneration != generation.current,
                packetDepth: metrics.videoPacketDepth,
                frameDepth: metrics.videoFrameDepth,
                rendererBufferedDuration: metrics.bufferedVideoDuration
            )
            let audioStarved = MediaSessionEndPolicy.isStreamStarved(
                isSelected: selectedAudio != nil && !audioDisabled && endedAudioGeneration != generation.current,
                packetDepth: metrics.audioPacketDepth,
                frameDepth: metrics.audioFrameDepth,
                rendererBufferedDuration: metrics.bufferedAudioDuration
            )
            let supplyStarved = MediaSessionEndPolicy.isSupplyStarved(
                presentationRate: presentation.rate,
                beforeEnd: beforeEnd,
                decoderDrainComplete: decoderDrainComplete,
                videoStarved: videoStarved,
                audioStarved: audioStarved
            )
            if supplyStarved, !wasSupplyStarved {
                metrics.rendererStarvations += 1
            }
            wasSupplyStarved = supplyStarved
            metrics.decoderDrainComplete = decoderDrainComplete
            let cache = minPositiveDuration(
                metrics.bufferedVideoDuration,
                metrics.bufferedAudioDuration
            )
            return (
                metrics,
                presentationFence,
                supplyStarved,
                cache,
                decoderDrainComplete
            )
        }
        synchronization.observeSupply(starved: result.2, cacheSeconds: result.3)
        var snapshot = result.0
        if let pipelineCapacity = videoPipelineCapacityGate?.snapshot {
            snapshot.videoPipelineCapacity = pipelineCapacity.capacity
            snapshot.videoPipelineCapacityInUse = pipelineCapacity.inUse
            snapshot.peakVideoPipelineCapacityInUse = pipelineCapacity.peakInUse
            snapshot.videoPipelineCapacityWaiters =
                pipelineCapacity.waitingAcquisitions
        }
        let renderer = presentation.rendererPresentationMetrics(demuxEOF: result.4)
        let completion = stateLock.withLock { () -> (ended: Bool, shouldPause: Bool) in
            guard presentationFence == result.1,
                  decoderDrainComplete == result.4
            else {
                return (result.0.ended, false)
            }
            if !metrics.ended,
               MediaSessionEndPolicy.shouldFinish(
                   decoderDrainComplete: decoderDrainComplete,
                   rendererDrainEvidence: renderer.rendererDrainEvidence,
                   successfulVideoSubmissions:
                       renderer.videoEnqueueReturnedWithoutImmediateFailure,
                   successfulAudioSubmissions:
                       renderer.audioEnqueueReturnedWithoutImmediateFailure
               )
            {
                metrics.ended = true
            }
            let shouldPause = metrics.ended && !didPauseAtEnd
            if shouldPause { didPauseAtEnd = true }
            return (metrics.ended, shouldPause)
        }
        snapshot.ended = completion.ended
        if completion.shouldPause { _ = presentation.pause(fence: result.1) }
        snapshot.videoSubmissionAttempts = renderer.videoSubmissionAttempts
        snapshot.videoEnqueueReturnedWithoutImmediateFailure =
            renderer.videoEnqueueReturnedWithoutImmediateFailure
        snapshot.audioSubmissionAttempts = renderer.audioSubmissionAttempts
        snapshot.audioEnqueueReturnedWithoutImmediateFailure =
            renderer.audioEnqueueReturnedWithoutImmediateFailure
        snapshot.firstVideoRendererClockEvidenceSeconds =
            renderer.firstVideoRendererClockEvidenceSeconds
        snapshot.firstAudioRendererClockEvidenceSeconds =
            renderer.firstAudioRendererClockEvidenceSeconds
        snapshot.rendererMediaTimeSeconds = renderer.rendererMediaTimeSeconds
        snapshot.rendererRate = renderer.rendererRate
        snapshot.rendererClockEpochBaselineSeconds = renderer.rendererClockEpochBaselineSeconds
        snapshot.rendererClockMaximumSeconds = renderer.rendererClockMaximumSeconds
        snapshot.firstRendererClockAdvanceSeconds = renderer.firstRendererClockAdvanceSeconds
        if renderer.fence == result.1, renderer.firstRendererClockAdvanceSeconds != nil,
           snapshot.seekTimings?.milliseconds[.prerollCompleted] != nil,
           snapshot.seekTimings?.milliseconds[.rendererClockAdvanced] == nil {
            recordSeekStage(.rendererClockAdvanced, generation: snapshot.generation)
            snapshot.seekTimings = stateLock.withLock {
                metrics.seekTimings?.generation == snapshot.generation ? metrics.seekTimings : snapshot.seekTimings
            }
        }
        snapshot.presentationFence = renderer.fence.rawValue
        snapshot.firstVisibleFrameSeconds = renderer.firstVisibleFrameSeconds
        snapshot.rendererLateFrames = renderer.lateVideoFrames
        snapshot.rendererDroppedFrames = renderer.droppedVideoFrames
        snapshot.flushRequested = renderer.flushRequested
        snapshot.flushCompleted = renderer.flushCompleted
        snapshot.rendererDrainEvidence = renderer.rendererDrainEvidence
        if let planarOwnership {
            snapshot.softwareOwnershipApplicationFrames =
                planarOwnership.applicationFrames
            snapshot.softwareOwnershipPeakApplicationFrames =
                planarOwnership.peakApplicationFrames
            snapshot.softwareOwnershipDecodedFrames = planarOwnership.decodedFrames
            snapshot.softwareOwnershipFramesWaitingForQueue =
                planarOwnership.framesWaitingForQueue
            snapshot.softwareOwnershipQueuedFrames = planarOwnership.queuedFrames
            snapshot.softwareOwnershipPresentingFrames =
                planarOwnership.presentingFrames
            snapshot.softwareOwnershipSubmittedApplicationFrames =
                planarOwnership.submittedApplicationFrames
            snapshot.softwareOwnershipRendererSampleAttachments =
                planarOwnership.rendererSampleAttachments
            snapshot.softwareOwnershipPeakRendererSampleAttachments =
                planarOwnership.peakRendererSampleAttachments
            snapshot.softwareOwnershipKnownOutstandingBuffers =
                planarOwnership.knownOutstandingBuffers
            snapshot.softwareOwnershipPeakKnownOutstandingBuffers =
                planarOwnership.peakKnownOutstandingBuffers
            snapshot.softwareOwnershipOldGenerationKnownBuffers =
                planarOwnership.oldGenerationKnownOutstandingBuffers
            snapshot.softwareOwnershipReuseWhileKnownOwned =
                planarOwnership.reuseWhileKnownOwned
            snapshot.softwareOwnershipPoolThresholdWaits =
                planarOwnership.poolThresholdWaits
            snapshot.softwareOwnershipPoolTimeouts = planarOwnership.poolTimeouts
            snapshot.softwareOwnershipLastTimeout = planarOwnership.lastTimeout
            snapshot.softwareOwnershipLastFlush = planarOwnership.lastFlush
        }
        snapshot.isBuffering = synchronization.isBuffering
        stateLock.withLock { metrics.isBuffering = snapshot.isBuffering }
        return snapshot
    }

    func updateSubtitleReadAhead(position: TimeInterval) {
        subtitleReadAhead.update(position: position)
    }

    @MainActor var videoAdjustments = VideoAdjustmentState.standard

    @MainActor
    func renderSubtitles() {
        guard let videoSize = selectedVideo?.displaySize else { return }
        let bounds = subtitles.overlay.bounds
        let viewport = VideoPresentationGeometry(sourceSize: videoSize, bounds: bounds, adjustments: videoAdjustments).imageRect
        subtitles.render(
            at: presentation.currentTime,
            viewport: viewport,
            videoSize: videoSize
        )
    }

    private func launch(_ label: String, body: @escaping @Sendable () -> Void) {
        workerGroup.enter()
        DispatchQueue(label: "com.superplayr.native.\(label)").async { [self] in
            body()
            workerGroup.leave()
        }
    }

    private var isRunning: Bool { stateLock.withLock { running } }

    private func demuxLoop() {
        if usesFairDemuxDispatch {
            fairDemuxLoop()
            return
        }
        blockingDemuxLoop()
    }

    /// Benchmark-only prototype that preserves FIFO ordering within each
    /// stream while allowing audio or subtitles to advance around a full video
    /// packet queue. The staging budget is deliberately much smaller than the
    /// packet queues: at most eight packets, 4 MiB, or 250 ms plus one accepted
    /// oversize packet. No packet is dropped.
    private func fairDemuxLoop() {
        let router = BoundedInterleavingRouter<DemuxPacketDestination, PacketQueueItem>(
            destinations: [
                .video: videoPackets,
                .audio: audioPackets,
                .subtitle: subtitlePackets,
            ],
            maximumPendingItems: 8,
            maximumPendingBytes: 4 * 1_024 * 1_024,
            maximumPendingDurationMicroseconds: 250_000,
            cost: \.boundedQueueCost
        )
        var atEndOfFile = false
        while isRunning {
            let work = seekTransitionLock.withLock { () -> DemuxWork in
                if let seek = seeks.takePending() { return .seek(seek) }
                return .read(generation: generation.current)
            }
            if case let .seek(seek) = work {
                router.removeAll()
                recordDemuxRouter(router)
                do {
                    recordSeekStage(.demuxStarted, generation: seek.generation)
                    try input.seek(
                        to: seek.target.seconds + mediaInfo.startTime,
                        exact: seek.exact
                    )
                    recordSeekStage(.demuxCompleted, generation: seek.generation)
                    seeks.markPrerolling(seek)
                    atEndOfFile = false
                } catch {
                    onSeekFailed?(seek.generation, PlaybackFailure(
                        domain: .demux,
                        stage: .seek,
                        stableCode: "nativeSeekFailed",
                        nativeCode: (error as? FFmpegError).map { Int64($0.code) },
                        recoverability: .fatal
                    ))
                    return
                }
                continue
            }

            let capacityRevisions = router.capacityRevisions
            guard router.drain() != .closed else { return }
            recordDemuxRouter(router)
            if atEndOfFile {
                if router.isEmpty {
                    if case let .read(activeGeneration) = work {
                        demuxEndWait.wait(until: nil, generation: activeGeneration)
                    }
                } else {
                    router.waitForCapacityChange(
                        after: capacityRevisions,
                        timeout: 0.1
                    )
                    recordDemuxRouter(router)
                }
                continue
            }
            guard router.canAcceptAnotherElement else {
                router.waitForCapacityChange(
                    after: capacityRevisions,
                    timeout: 0.1
                )
                recordDemuxRouter(router)
                continue
            }

            do {
                guard case let .read(activeGeneration) = work else { continue }
                guard let packet = try input.readPacket(generation: activeGeneration) else {
                    guard generation.accepts(activeGeneration) else {
                        incrementStalePacket()
                        continue
                    }
                    if videoDecoder != nil,
                       router.route(
                        .endOfStream(generation: activeGeneration),
                        to: .video,
                        allowingBudgetOverflow: true
                       ) == .closed { return }
                    if audioDecoder != nil, delayedAudioInput == nil,
                       !stateLock.withLock({ audioDisabled }),
                       router.route(
                        .endOfStream(generation: activeGeneration),
                        to: .audio,
                        allowingBudgetOverflow: true
                       ) == .closed { return }
                    atEndOfFile = true
                    recordDemuxRouter(router)
                    continue
                }
                guard generation.accepts(packet.generation) else {
                    incrementStalePacket()
                    continue
                }
                let audioIsDisabled = stateLock.withLock { audioDisabled }
                let destination: DemuxPacketDestination? = switch packet.streamIndex {
                case selectedVideo?.index: .video
                case selectedAudio?.index where !audioIsDisabled && delayedAudioInput == nil: .audio
                case selectedSubtitle?.index: nil
                default: nil
                }
                guard let destination else { continue }
                switch router.route(.packet(packet), to: destination) {
                case .pushed:
                    recordDemuxRouter(router)
                case .closed:
                    return
                case .wouldBlock:
                    // The loop checks the staging budget before every read, so
                    // this can only indicate an internal accounting error.
                    failRenderer("Fair demux staging exceeded its bounded budget.")
                    return
                }
            } catch let error as FFmpegError where error.isInterrupted && isRunning {
                continue
            } catch {
                reportDemuxFailure(error)
                return
            }
        }
    }

    private func recordDemuxRouter(
        _ router: BoundedInterleavingRouter<DemuxPacketDestination, PacketQueueItem>
    ) {
        let snapshot = router.snapshot
        stateLock.withLock {
            metrics.demuxDeferredPacketDepth = snapshot.pendingItems
            metrics.peakDemuxDeferredPacketDepth = snapshot.peakPendingItems
            metrics.demuxDeferredVideoPackets = router.pendingCount(for: .video)
            metrics.demuxDeferredAudioPackets = router.pendingCount(for: .audio)
            metrics.demuxDeferredSubtitlePackets = router.pendingCount(for: .subtitle)
            metrics.demuxDeferredPacketCount = snapshot.deferredItems
            metrics.demuxCapacityWaits = snapshot.capacityWaits
            metrics.demuxCapacityWaitSeconds = snapshot.capacityWaitSeconds
        }
    }

    private func blockingDemuxLoop() {
        var atEndOfFile = false
        while isRunning {
            let work = seekTransitionLock.withLock { () -> DemuxWork in
                if let seek = seeks.takePending() { return .seek(seek) }
                return .read(generation: generation.current)
            }
            if case let .seek(seek) = work {
                do {
                    recordSeekStage(.demuxStarted, generation: seek.generation)
                    try input.seek(
                        to: seek.target.seconds + mediaInfo.startTime,
                        exact: seek.exact
                    )
                    recordSeekStage(.demuxCompleted, generation: seek.generation)
                    seeks.markPrerolling(seek)
                    atEndOfFile = false
                } catch {
                    onSeekFailed?(seek.generation, PlaybackFailure(
                        domain: .demux,
                        stage: .seek,
                        stableCode: "nativeSeekFailed",
                        nativeCode: (error as? FFmpegError).map { Int64($0.code) },
                        recoverability: .fatal
                    ))
                    return
                }
                continue
            }
            if atEndOfFile {
                if case let .read(activeGeneration) = work {
                    demuxEndWait.wait(until: nil, generation: activeGeneration)
                }
                continue
            }
            do {
                guard case let .read(activeGeneration) = work else { continue }
                guard let packet = try input.readPacket(generation: activeGeneration) else {
                    guard generation.accepts(activeGeneration) else {
                        incrementStalePacket()
                        continue
                    }
                    if videoDecoder != nil { _ = videoPackets.push(.endOfStream(generation: activeGeneration)) }
                    if audioDecoder != nil, delayedAudioInput == nil,
                       !stateLock.withLock({ audioDisabled })
                    {
                        _ = audioPackets.push(.endOfStream(generation: activeGeneration))
                    }
                    atEndOfFile = true
                    continue
                }
                guard generation.accepts(packet.generation) else {
                    incrementStalePacket()
                    continue
                }
                let audioIsDisabled = stateLock.withLock { audioDisabled }
                switch packet.streamIndex {
                case selectedVideo?.index: _ = videoPackets.push(.packet(packet))
                case selectedAudio?.index where !audioIsDisabled && delayedAudioInput == nil:
                    _ = audioPackets.push(.packet(packet))
                case selectedSubtitle?.index: break
                default: break
                }
            } catch let error as FFmpegError where error.isInterrupted && isRunning {
                continue
            } catch {
                reportDemuxFailure(error)
                return
            }
        }
    }

    private func decodeVideoPacket(
        _ packet: FFmpegPacket,
        decoder: VideoDecoder
    ) throws {
        videoRecoveryPackets.record(packet)
        decoder.seekOutputFloor = stateLock.withLock {
            videoSeekFloor.flatMap { $0.generation == packet.generation ? $0 : nil }
        }
        let reserveSoftwareOutput: (() -> VideoFrameCapacityPermit?)?
        if let gate = videoPipelineCapacityGate {
            reserveSoftwareOutput = {
                gate.acquire {
                    self.isRunning && self.generation.accepts(packet.generation)
                }
            }
        } else {
            reserveSoftwareOutput = nil
        }
        try decoder.decode(
            packet,
            while: {
                self.isRunning && self.generation.accepts(packet.generation)
            },
            reserveSoftwareOutput: reserveSoftwareOutput
        ) { decodedFrame in
            let frame = decodedFrame
            self.stateLock.withLock {
                if decoder.hardwareWasConfigured {
                    self.consecutiveHardwareDecodeFailures = 0
                }
                self.metrics.temporaryDecodedVideoFrames = 1
                self.metrics.peakTemporaryDecodedVideoFrames = max(
                    self.metrics.peakTemporaryDecodedVideoFrames,
                    1
                )
            }
            defer {
                self.stateLock.withLock {
                    self.metrics.temporaryDecodedVideoFrames = 0
                }
            }
            guard self.accepts(frame) else { return }
            guard self.pushVideoFrame(frame) else { return }
            self.recordVideoDecodeDiagnostics(decoder)
        }
    }

    private func reportVideoDecodeFailure(_ error: Error, decoder: VideoDecoder) {
        let hardwareWasConfigured = decoder.hardwareWasConfigured
        let failureContext = stateLock.withLock {
            let isHardwareDecodeFailure = hardwareWasConfigured
                && !(error is SoftwarePixelBufferPoolError)
            if isHardwareDecodeFailure {
                consecutiveHardwareDecodeFailures += 1
            } else {
                consecutiveHardwareDecodeFailures = 0
            }
            return (
                observedHardwareOutput:
                    metrics.framesSubmitted > 0 && metrics.isHardwareDecoded,
                consecutiveCount: max(1, consecutiveHardwareDecodeFailures)
            )
        }
        let failure = recovery.videoFailure(
            error: error,
            stream: selectedVideo ?? decoder.streamInfo,
            hardwareWasConfigured: hardwareWasConfigured,
            hardwareOutputWasObserved: failureContext.observedHardwareOutput,
            consecutiveCount: failureContext.consecutiveCount
        )
        stateLock.withLock { metrics.lastRecoveryFailure = failure }
        onFailureObserved?(failure)
    }

    private func takePendingVideoRecoveryReplay() -> [FFmpegPacket] {
        stateLock.withLock {
            let replay = pendingVideoRecoveryReplay
            pendingVideoRecoveryReplay.removeAll(keepingCapacity: false)
            return replay
        }
    }

    private func videoDecodeLoop() {
        guard let videoDecoder else { return }
        var decoderGeneration = generation.current

        do {
            for packet in takePendingVideoRecoveryReplay() {
                guard generation.accepts(packet.generation) else {
                    incrementStalePacket()
                    continue
                }
                try decodeVideoPacket(packet, decoder: videoDecoder)
            }
        } catch SoftwarePixelBufferPoolError.cancelled {
            // A concurrent seek invalidated replay; continue with its new queue.
        } catch {
            reportVideoDecodeFailure(error, decoder: videoDecoder)
            return
        }

        while isRunning {
            switch videoPackets.pop() {
            case .closed: return
            case let .value(item):
                do {
                    switch item {
                    case let .packet(packet):
                        guard generation.accepts(packet.generation) else {
                            incrementStalePacket(); continue
                        }
                        if decoderGeneration != packet.generation {
                            videoDecoder.flush()
                            videoRecoveryPackets.reset(generation: packet.generation)
                            decoderGeneration = packet.generation
                        }
                        try decodeVideoPacket(packet, decoder: videoDecoder)
                    case let .endOfStream(active):
                        guard generation.accepts(active) else {
                            incrementStalePacket(); continue
                        }
                        if decoderGeneration != active {
                            videoDecoder.flush(); decoderGeneration = active
                        }
                        videoDecoder.seekOutputFloor = stateLock.withLock {
                            videoSeekFloor.flatMap { $0.generation == active ? $0 : nil }
                        }
                        let reserveSoftwareOutput: (() -> VideoFrameCapacityPermit?)?
                        if let gate = videoPipelineCapacityGate {
                            reserveSoftwareOutput = {
                                gate.acquire {
                                    self.isRunning && self.generation.accepts(active)
                                }
                            }
                        } else {
                            reserveSoftwareOutput = nil
                        }
                        try videoDecoder.drain(
                            generation: active,
                            while: {
                                self.isRunning && self.generation.accepts(active)
                            },
                            reserveSoftwareOutput: reserveSoftwareOutput
                        ) { decodedFrame in
                            let frame = decodedFrame
                            self.stateLock.withLock {
                                if videoDecoder.hardwareWasConfigured {
                                    self.consecutiveHardwareDecodeFailures = 0
                                }
                                self.metrics.temporaryDecodedVideoFrames = 1
                                self.metrics.peakTemporaryDecodedVideoFrames = max(
                                    self.metrics.peakTemporaryDecodedVideoFrames,
                                    1
                                )
                            }
                            defer {
                                self.stateLock.withLock {
                                    self.metrics.temporaryDecodedVideoFrames = 0
                                }
                            }
                            guard self.accepts(frame) else { return }
                            guard self.pushVideoFrame(frame) else { return }
                            self.recordVideoDecodeDiagnostics(videoDecoder)
                        }
                        _ = videoFrames.push(.endOfStream(generation: active))
                    case let .flush(active):
                        videoDecoder.flush()
                        videoRecoveryPackets.reset(generation: active)
                        decoderGeneration = active
                    }
                } catch SoftwarePixelBufferPoolError.cancelled {
                    continue
                } catch {
                    reportVideoDecodeFailure(error, decoder: videoDecoder)
                    return
                }
            }
        }
    }

    private func audioDecodeLoop() {
        if delayedAudioInput != nil {
            delayedAudioDecodeLoop()
            return
        }
        guard let audioDecoder else { return }
        var decoderGeneration = generation.current
        while isRunning && !stateLock.withLock({ audioDisabled }) {
            switch audioPackets.pop() {
            case .closed: return
            case let .value(item):
                do {
                    switch item {
                    case let .packet(packet):
                        guard generation.accepts(packet.generation) else {
                            incrementStalePacket(); continue
                        }
                        if decoderGeneration != packet.generation {
                            audioDecoder.flush(); decoderGeneration = packet.generation
                        }
                        for frame in try audioDecoder.decode(packet)
                            where generation.accepts(frame.generation)
                        {
                            if audioFrames.push(.frame(frame)) {
                                stateLock.withLock { hasDecodedAudioFrame = true }
                            }
                        }
                    case let .endOfStream(active):
                        guard generation.accepts(active) else {
                            incrementStalePacket(); continue
                        }
                        if decoderGeneration != active {
                            audioDecoder.flush(); decoderGeneration = active
                        }
                        for frame in try audioDecoder.drain(generation: active)
                            where generation.accepts(frame.generation)
                        {
                            if audioFrames.push(.frame(frame)) {
                                stateLock.withLock { hasDecodedAudioFrame = true }
                            }
                        }
                        _ = audioFrames.push(.endOfStream(generation: active))
                    case let .flush(active):
                        audioDecoder.flush(); decoderGeneration = active
                    }
                } catch {
                    reportAudioFailure(error, stage: .receiveFrame)
                    return
                }
            }
        }
    }

    /// Runs on the existing audio decode worker. Independent reads prevent
    /// either sign of a large offset from blocking behind video packet admission.
    private func delayedAudioDecodeLoop() {
        guard let delayedAudioInput, let audioDecoder, let selectedAudio else { return }
        var active = generation.current
        var timeline = AudioDelayTimeline(delay: audioDelay)
        var atEOF = false
        var needsInitialSeek = true
        func emit(_ frame: NativeDecodedAudioFrame) -> Bool {
            guard isRunning, generation.accepts(frame.generation),
                  !stateLock.withLock({ audioDisabled }), audioFrames.push(.frame(frame)) else { return false }
            stateLock.withLock {
                if generation.accepts(frame.generation) { hasDecodedAudioFrame = true }
            }
            return true
        }
        while isRunning && !stateLock.withLock({ audioDisabled }) {
            let seek = audioSeekLock.withLock { () -> SeekRequest? in
                defer { pendingAudioSeek = nil }
                return pendingAudioSeek
            }
            if needsInitialSeek || seek != nil {
                needsInitialSeek = false
                let target = seek?.target.seconds ?? 0
                active = seek?.generation ?? generation.current
                timeline = AudioDelayTimeline(delay: audioDelay, target: target)
                atEOF = false
                audioDecoder.flush()
                var sourceTarget = max(0, target - audioDelay)
                if case let .valid(duration) = mediaInfo.durationStatus {
                    // Seek within a short stream even when the requested audio
                    // advance exceeds its duration, then drain into silence.
                    sourceTarget = min(sourceTarget, max(0, duration - 1))
                }
                do {
                    try delayedAudioInput.seek(to: sourceTarget + mediaInfo.startTime, exact: true)
                } catch let error as FFmpegError where error.isInterrupted && isRunning {
                    continue
                } catch {
                    reportAudioFailure(error, stage: .seek)
                    return
                }
                continue
            }
            if atEOF {
                audioEndWait.wait(until: nil, generation: active)
                continue
            }
            do {
                if let packet = try delayedAudioInput.readPacket(generation: active) {
                    guard generation.accepts(active), packet.streamIndex == selectedAudio.index else { continue }
                    for frame in try audioDecoder.decode(packet) {
                        guard timeline.consume(frame, emit: emit) else { break }
                    }
                } else {
                    guard generation.accepts(active) else { continue }
                    for frame in try audioDecoder.drain(generation: active) {
                        guard timeline.consume(frame, emit: emit) else { break }
                    }
                    let channels = presentation.audioOutputCapacity.outputChannels(forSourceChannels: selectedAudio.channelCount ?? 2)
                    let fallback = NativeDecodedAudioFrame(interleavedFloatPCM: Data(), presentationTime: .zero,
                        duration: .zero, generation: active, sampleRate: 48_000, channelCount: channels,
                        sampleCount: 0, sourceSampleRate: selectedAudio.sampleRate ?? 48_000,
                        sourceChannelCount: selectedAudio.channelCount ?? 2,
                        sourceChannelLayout: selectedAudio.channelLayout ?? "unknown",
                        downmixOccurred: (selectedAudio.channelCount ?? 2) > channels, conversionOccurred: true)
                    let end: Double? = if case let .valid(duration) = mediaInfo.durationStatus { duration } else { nil }
                    if timeline.finish(duration: end, fallback: fallback, emit: emit), generation.accepts(active) {
                        _ = audioFrames.push(.endOfStream(generation: active))
                    }
                    atEOF = true
                }
            } catch let error as FFmpegError where error.isInterrupted && isRunning {
                continue
            } catch {
                reportAudioFailure(error, stage: .receiveFrame)
                return
            }
        }
    }

    /// Reads the selected subtitle stream through an independent input so
    /// video/audio packet backpressure can never stall subtitle delivery.
    private func subtitleDemuxLoop() {
        guard let selectedSubtitle, let subtitleInput, let subtitleDecoder else {
            return
        }
        var activeGeneration = generation.current
        var atEndOfFile = false

        while isRunning && !stateLock.withLock({ subtitleDisabled }) {
            if let seek = subtitleSeekLock.withLock({ () -> SeekRequest? in
                defer { pendingSubtitleSeek = nil }
                return pendingSubtitleSeek
            }) {
                let absoluteTarget = seek.target.seconds + subtitleTimelineOrigin
                activeGeneration = seek.generation
                atEndOfFile = false
                do {
                    try subtitleDecoder.flush()
                    let activePackets = try subtitleInput.activeSubtitlePackets(
                        streamIndex: selectedSubtitle.index,
                        at: absoluteTarget,
                        generation: seek.generation
                    )
                    for packet in activePackets where generation.accepts(packet.generation) {
                        try processSubtitlePacket(packet, decoder: subtitleDecoder)
                    }
                } catch let error as FFmpegError where error.isInterrupted && isRunning {
                    continue
                } catch let error as FFmpegError where error.isInvalidData && isRunning {
                    // A damaged subtitle access unit must not kill the independent
                    // subtitle worker. The following seek repositions the input at
                    // the requested generation and later valid cues remain usable.
                } catch {
                    observeSubtitleInputFailure(error)
                    return
                }
                do {
                    try subtitleInput.seek(to: absoluteTarget, exact: seek.exact)
                } catch let error as FFmpegError where error.isInterrupted && isRunning {
                    continue
                } catch {
                    observeSubtitleInputFailure(error)
                    return
                }
                continue
            }

            if atEndOfFile {
                subtitleReadAhead.wait(until: nil, generation: activeGeneration)
                continue
            }

            do {
                guard let packet = try subtitleInput.readPacket(
                    generation: activeGeneration
                ) else {
                    atEndOfFile = true
                    continue
                }
                guard generation.accepts(packet.generation) else {
                    incrementStalePacket()
                    continue
                }
                if let timestamp = packet.decodeSeconds ?? packet.presentationSeconds,
                   timestamp.isFinite,
                   !subtitleReadAhead.wait(
                       until: timestamp - subtitleTimelineOrigin, generation: activeGeneration
                   ) {
                    continue
                }
                guard packet.streamIndex == selectedSubtitle.index else { continue }
                let pruneBefore = subtitleReadAhead.currentPosition - 30
                subtitles.pruneEmbeddedEvents(before: pruneBefore)
                pictureInPictureSubtitles?.pruneEmbeddedEvents(before: pruneBefore)
                try processSubtitlePacket(packet, decoder: subtitleDecoder)
            } catch let error as FFmpegError where error.isInterrupted && isRunning {
                continue
            } catch let error as FFmpegError where error.isInvalidData && isRunning {
                // FFmpeg leaves text-subtitle decoders usable after a malformed
                // packet. Drop only that cue and keep reading future packets.
                continue
            } catch {
                observeSubtitleInputFailure(error)
                return
            }
        }
    }

    private func processSubtitlePacket(
        _ packet: FFmpegPacket,
        decoder: SubtitleDecoder
    ) throws {
        let events = try decoder.decode(packet)
        for event in events {
            guard generation.accepts(event.generation) else { continue }
            guard subtitles.process(event: event, timelineOriginSeconds: subtitleTimelineOrigin) else {
                throw PresentationError("Bitmap subtitle timeline exceeds its bounded memory limit")
            }
            let pipAccepted = pictureInPictureSubtitles?.process(
                event: event,
                timelineOriginSeconds: subtitleTimelineOrigin
            ) ?? true
            if !pipAccepted { pictureInPictureSubtitles?.clear(generation: event.generation) }
        }
        guard !events.isEmpty else { return }
        onObservationRequested?(RuntimeObservationRequest(
            source: .subtitlePacket,
            urgency: .routine
        ))
    }

    private func observeSubtitleInputFailure(_ error: Error) {
        let failure = PlaybackFailure(
            domain: .subtitle,
            stage: .read,
            stableCode: "nativeSubtitleReadFailed",
            nativeCode: (error as? FFmpegError).map { Int64($0.code) },
            recoverability: .fallbackAvailable,
            streamID: selectedSubtitle.map {
                PlaybackStreamID(kind: .subtitle, demuxIndex: $0.index)
            }
        )
        stateLock.withLock { metrics.lastRecoveryFailure = failure }
        onSubtitleDiagnostic?("[native-subtitle] \(failure.stableCode): \(String(reflecting: error))")
        onFailureObserved?(failure)
    }

    private func videoPresentationLoop() {
        while isRunning {
            switch videoFrames.pop() {
            case .closed: return
            case let .value(item):
                switch item {
                case let .frame(frame):
                    frame.planarOwnershipToken?.transition(to: .presenting)
                    guard accepts(frame) else { continue }
                    if frame.beginsTimelineDiscontinuity {
                        let failure = PlaybackFailure(
                            domain: .presentation,
                            stage: .flush,
                            stableCode: "videoTimelineDiscontinuity",
                            recoverability: .retryable,
                            streamID: selectedVideo.map {
                                PlaybackStreamID(kind: .video, demuxIndex: $0.index)
                            }
                        )
                        stateLock.withLock { metrics.lastRecoveryFailure = failure }
                        onFailureObserved?(failure)
                        return
                    }
                    guard adoptVideoFormatIfNeeded(frame) else { return }
                    let backpressureStart = ProcessInfo.processInfo.systemUptime
                    guard videoDemand.consume(while: { self.isRunning }) else { return }
                    let backpressureDuration = ProcessInfo.processInfo.systemUptime
                        - backpressureStart
                    if backpressureDuration >= 0.001 {
                        stateLock.withLock {
                            metrics.rendererBackpressureEvents += 1
                            metrics.rendererBackpressureSeconds += backpressureDuration
                        }
                    }
                    guard isRunning, accepts(frame) else { continue }
                    do {
                        guard let fence = stateLock.withLock({
                            metrics.generation == frame.generation ? presentationFence : nil
                        }) else { incrementStaleFrame(); continue }
                        guard try presentation.enqueueVideo(
                            frame,
                            fence: fence,
                            // Preview remains a paused, timestamped transaction
                            // on the synchronizer. DisplayImmediately is not
                            // qualified under AVSampleBufferRenderSynchronizer.
                            displayImmediately: false
                        ) else {
                            incrementStaleFrame()
                            continue
                        }
                        stateLock.withLock {
                            // A seek can reset metrics after enqueue returns but
                            // before this lock is acquired. Never journal the old
                            // frame as the new generation's first output.
                            guard metrics.recordEnqueuedVideo(
                                startPTS: frame.presentationTime.seconds,
                                endPTS: frame.presentationTime.seconds + frame.duration.seconds,
                                generation: frame.generation
                            ) else { return }
                            metrics.framesSubmitted += 1
                            if metrics.seekTimings?.milliseconds[.videoEnqueued] == nil {
                                metrics.seekTimings?.record(.videoEnqueued, generation: frame.generation,
                                                           at: ProcessInfo.processInfo.systemUptime)
                            }
                            metrics.ffmpegPixelFormat = frame.ffmpegPixelFormat
                            metrics.usesDeinterlacingFilter = frame.usesDeinterlacingFilter
                            metrics.deinterlacingFailure = frame.deinterlacingFailure
                            metrics.pixelBufferFormat = Self.pixelFormatName(frame.pixelBuffer)
                            metrics.isHardwareDecoded = frame.isHardwareDecoded
                            metrics.isCopiedHardwarePath = frame.isCopiedHardwarePath
                            metrics.isNearZeroCopy = frame.isNearZeroCopy
                            metrics.colorPrimaries = frame.colorPrimaries
                            metrics.transferCharacteristic = frame.transferCharacteristic
                            metrics.matrixCoefficients = frame.matrixCoefficients
                            metrics.isFullRange = frame.isFullRange
                            metrics.hasMasteringDisplayMetadata = frame.hasMasteringDisplayMetadata
                            metrics.hasContentLightMetadata = frame.hasContentLightMetadata
                        }
                        onObservationRequested?(RuntimeObservationRequest(
                            source: .videoEnqueue,
                            urgency: .routine
                        ))
                        startIfPrerolled(.video, generation: frame.generation)
                    } catch {
                        let failure = recovery.presentationFailure(error: error)
                        stateLock.withLock { metrics.lastRecoveryFailure = failure }
                        onFailureObserved?(failure)
                        return
                    }
                case let .endOfStream(active): markEnded(kind: .video, generation: active)
                case .flush: break
                }
            }
        }
    }

    private func audioPresentationLoop() {
        while isRunning && !stateLock.withLock({ audioDisabled }) {
            switch audioFrames.pop() {
            case .closed: return
            case let .value(item):
                switch item {
                case let .frame(frame):
                    guard let acceptedFrame = acceptedAudioFrame(frame) else { continue }
                    guard adoptAudioFormatIfNeeded(acceptedFrame) else { return }
                    guard audioDemand.consume(while: { self.isRunning }) else { return }
                    guard isRunning, generation.accepts(acceptedFrame.generation) else {
                        incrementStaleFrame()
                        continue
                    }
                    do {
                        guard let fence = stateLock.withLock({
                            metrics.generation == acceptedFrame.generation ? presentationFence : nil
                        }) else { incrementStaleFrame(); continue }
                        guard try presentation.enqueueAudio(acceptedFrame, fence: fence) else {
                            incrementStaleFrame()
                            continue
                        }
                        stateLock.withLock {
                            guard metrics.recordEnqueuedAudio(
                                startPTS: acceptedFrame.presentationTime.seconds,
                                endPTS: acceptedFrame.presentationTime.seconds
                                    + acceptedFrame.duration.seconds,
                                generation: acceptedFrame.generation
                            ) else { return }
                            metrics.audioOutputChannels = acceptedFrame.channelCount
                            if metrics.seekTimings?.milliseconds[.audioEnqueued] == nil {
                                metrics.seekTimings?.record(.audioEnqueued, generation: acceptedFrame.generation,
                                                           at: ProcessInfo.processInfo.systemUptime)
                            }
                            metrics.audioOutputSampleRate = acceptedFrame.sampleRate
                            metrics.audioDownmixOccurred = acceptedFrame.downmixOccurred
                        }
                        onObservationRequested?(RuntimeObservationRequest(
                            source: .audioEnqueue,
                            urgency: .routine
                        ))
                        startIfPrerolled(.audio, generation: acceptedFrame.generation)
                    } catch {
                        reportAudioFailure(error, stage: .enqueue)
                        return
                    }
                case let .endOfStream(active): markEnded(kind: .audio, generation: active)
                case .flush: break
                }
            }
        }
    }

    private func accepts(_ frame: NativeDecodedVideoFrame) -> Bool {
        guard generation.accepts(frame.generation) else {
            incrementStaleFrame(); return false
        }
        return acceptsVideo(pts: frame.presentationTime.seconds, generation: frame.generation)
    }

    private func pushVideoFrame(_ frame: NativeDecodedVideoFrame) -> Bool {
        frame.planarOwnershipToken?.transition(to: .waitingForQueue)
        guard videoFrames.push(.frame(frame)) else { return false }
        stateLock.withLock { hasDecodedVideoFrame = true }
        frame.planarOwnershipToken?.transition(to: .queued)
        return true
    }

    private func adoptVideoFormatIfNeeded(_ frame: NativeDecodedVideoFrame) -> Bool {
        let signature = NativeVideoFormatSignature(
            width: CVPixelBufferGetWidth(frame.pixelBuffer),
            height: CVPixelBufferGetHeight(frame.pixelBuffer),
            pixelFormat: CVPixelBufferGetPixelFormatType(frame.pixelBuffer),
            colorPrimaries: frame.colorPrimaries,
            transfer: frame.transferCharacteristic,
            matrix: frame.matrixCoefficients,
            fullRange: frame.isFullRange,
            codedSize: frame.codedSize,
            displaySize: frame.displaySize,
            pixelAspectRatio: frame.pixelAspectRatio,
            rotationDegrees: frame.rotationDegrees,
            chromaLocation: frame.chromaLocation,
            cleanAperture: frame.cleanAperture,
            masteringDisplayMetadata: frame.masteringDisplayMetadata,
            contentLightMetadata: frame.contentLightMetadata
        )
        let failure: PlaybackFailure? = formatTransitionLock.withLock {
            let previous = stateLock.withLock { videoFormatSignature }
            guard let previous else {
                stateLock.withLock {
                    videoFormatSignature = signature
                    videoGeometry = NativeVideoGeometry(
                        displaySize: frame.displaySize,
                        rotationDegrees: frame.rotationDegrees
                    )
                }
                return nil
            }
            guard previous != signature else { return nil }
            guard videoFormatRevision < UInt64.max else {
                return PlaybackFailure(
                    domain: .presentation,
                    stage: .configure,
                    stableCode: "videoFormatRevisionExhausted",
                    recoverability: .fatal
                )
            }
            videoFormatRevision += 1
            let revision = MediaFormatRevisionID(rawValue: videoFormatRevision)
            let ticket = formatReconfiguration.begin(
                .video,
                revision: revision
            )
            onSynchronizationObserved?(.formatChanged(stream: .video, revision: revision))
            guard ticket.wait(timeout: .now() + 3) == .success else {
                return PlaybackFailure(
                    domain: .presentation,
                    stage: .configure,
                    stableCode: "videoFormatReconfigurationTimedOut",
                    recoverability: .retryable
                )
            }
            stateLock.withLock {
                videoFormatSignature = signature
                videoGeometry = NativeVideoGeometry(
                    displaySize: frame.displaySize,
                    rotationDegrees: frame.rotationDegrees
                )
            }
            return nil
        }
        guard let failure else { return true }
        recordFormatAdoptionFailure(failure)
        return false
    }

    private func adoptAudioFormatIfNeeded(_ frame: NativeDecodedAudioFrame) -> Bool {
        let failure: PlaybackFailure? = formatTransitionLock.withLock {
            let previous = stateLock.withLock { audioFormatRevision }
            guard let previous else {
                stateLock.withLock {
                    audioFormatRevision = frame.formatRevision
                }
                return nil
            }
            guard previous != frame.formatRevision else { return nil }
            let revision = MediaFormatRevisionID(rawValue: frame.formatRevision)
            let ticket = formatReconfiguration.begin(
                .audio,
                revision: revision
            )
            onSynchronizationObserved?(.formatChanged(stream: .audio, revision: revision))
            guard ticket.wait(timeout: .now() + 3) == .success else {
                return PlaybackFailure(
                    domain: .presentation,
                    stage: .configure,
                    stableCode: "audioFormatReconfigurationTimedOut",
                    recoverability: .retryable
                )
            }
            stateLock.withLock {
                audioFormatRevision = frame.formatRevision
            }
            return nil
        }
        guard let failure else { return true }
        recordFormatAdoptionFailure(failure)
        return false
    }

    func completeFormatReconfiguration(
        _ stream: SynchronizedStream,
        revision: MediaFormatRevisionID
    ) {
        formatReconfiguration.complete(stream, revision: revision)
    }

    private func acceptedAudioFrame(
        _ frame: NativeDecodedAudioFrame
    ) -> NativeDecodedAudioFrame? {
        guard generation.accepts(frame.generation) else {
            incrementStaleFrame(); return nil
        }
        let floor = stateLock.withLock { () -> Double? in
            guard let floor = audioSeekFloor, floor.generation == frame.generation else {
                return nil
            }
            let frameEnd = frame.presentationTime.seconds + frame.duration.seconds
            guard frameEnd > floor.seconds else { return -.infinity }
            audioSeekFloor = nil
            return floor.seconds
        }
        guard floor != -.infinity else {
            incrementStaleFrame()
            return nil
        }
        guard let floor else { return frame }
        return frame.trimmingSamples(before: floor)
    }

    private func acceptsVideo(pts: Double, generation candidate: Int) -> Bool {
        let accepted = stateLock.withLock { () -> Bool in
            if let floor = videoSeekFloor, floor.generation == candidate {
                if pts + 0.001 < floor.seconds { return false }
                videoSeekFloor = nil
            }
            if metrics.seekTimings?.milliseconds[.targetVideoDecoded] == nil {
                metrics.seekTimings?.record(.targetVideoDecoded, generation: candidate,
                                           at: ProcessInfo.processInfo.systemUptime)
            }
            return true
        }
        if !accepted { incrementStaleFrame() }
        return accepted
    }

    private func startIfPrerolled(
        _ stream: NativeSynchronizationStream,
        generation candidate: Int
    ) {
        let isVideoOnlyPreview = stateLock.withLock {
            () -> Bool in
            guard startedGeneration != candidate else { return false }
            let videoOnlyPreview = previewGeneration == candidate && selectedVideo != nil
            return videoOnlyPreview
        }
        guard synchronization.observePreroll(stream, generation: candidate) else { return }
        stateLock.withLock {
            startedGeneration = candidate
            if isVideoOnlyPreview { previewGeneration = nil }
        }
        if seeks.finish(generation: candidate) {
            recordSeekStage(.prerollCompleted, generation: candidate)
            onSeekCompleted?(candidate, isVideoOnlyPreview)
        }
        onObservationRequested?(RuntimeObservationRequest(
            source: .preroll,
            urgency: .urgent
        ))
    }

    private func minPositiveDuration(_ lhs: Double, _ rhs: Double) -> Double {
        let values = [lhs, rhs].filter { $0 > 0 && $0.isFinite }
        return values.min() ?? 0
    }

    private func recordSeekStage(_ stage: SeekPerformanceTimings.Stage, generation: Int) {
        let completed = stateLock.withLock { () -> SeekPerformanceTimings? in
            guard metrics.seekTimings?.generation == generation else { return nil }
            metrics.seekTimings?.record(stage, generation: generation,
                                       at: ProcessInfo.processInfo.systemUptime)
            return stage == .prerollCompleted ? metrics.seekTimings : nil
        }
        if let completed {
            Logger(subsystem: "com.superplayr.seek", category: "pipeline")
                .info("generation=\(generation) \(completed.summary, privacy: .public)")
        }
    }

    private func markEnded(kind: NativeStreamKind, generation candidate: Int) {
        let shouldSuspendDemand = seekTransitionLock.withLock { () -> Bool in
            guard generation.accepts(candidate) else { return false }
            return stateLock.withLock {
                if kind == .video { endedVideoGeneration = candidate }
                if kind == .audio { endedAudioGeneration = candidate }
                let videoEnded = selectedVideo == nil || endedVideoGeneration == candidate
                let audioEnded = selectedAudio == nil || audioDisabled
                    || endedAudioGeneration == candidate
                decoderDrainComplete = videoEnded && audioEnded
                switch kind {
                case .video: return videoEndOfStreamDemand.suspendIfNeeded()
                case .audio: return audioEndOfStreamDemand.suspendIfNeeded()
                default: return false
                }
            }
        }
        if shouldSuspendDemand { suspendRendererDemand(kind) }
        onObservationRequested?(RuntimeObservationRequest(
            source: .decoderDrain,
            urgency: .urgent
        ))
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.1) {
            [onObservationRequested] in
            onObservationRequested?(RuntimeObservationRequest(
                source: .decoderDrain,
                urgency: .urgent
            ))
        }
    }

    private func armRendererDemand() {
        if selectedVideo != nil { armVideoRendererDemand() }
        if selectedAudio != nil, !stateLock.withLock({ audioDisabled }) {
            armAudioRendererDemand()
        }
    }

    private func armVideoRendererDemand() {
        guard stateLock.withLock({ !videoEndOfStreamDemand.isSuspended }) else { return }
        let videoEpoch = videoDemand.beginEpoch()
        presentation.video.requestMediaDataWhenReady(on: videoDemandQueue) {
            [videoDemand] in
            videoDemand.offer(epoch: videoEpoch)
        }
    }

    private func armAudioRendererDemand() {
        guard stateLock.withLock({ !audioEndOfStreamDemand.isSuspended }) else { return }
        let audioEpoch = audioDemand.beginEpoch()
        presentation.audio.requestMediaDataWhenReady(on: audioDemandQueue) {
            [audioDemand] in
            audioDemand.offer(epoch: audioEpoch)
        }
    }

    private func suspendRendererDemand(_ kind: NativeStreamKind) {
        switch kind {
        case .video:
            presentation.video.stopRequestingMediaData()
            videoDemand.revoke()
        case .audio:
            presentation.audio.stopRequestingMediaData()
            audioDemand.revoke()
        default: break
        }
    }

    private func incrementStalePacket() {
        stateLock.withLock { metrics.discardedStalePackets += 1 }
    }

    private func incrementStaleFrame() {
        stateLock.withLock { metrics.discardedStaleFrames += 1 }
    }

    private func recordVideoDecodeDiagnostics(_ decoder: VideoDecoder) {
        let queueDepth = videoFrames.count
        let currentPlanar = decoder.currentPlanarOutputDiagnostics
        let cumulativePlanar = decoder.planarOutputDiagnostics
        stateLock.withLock {
            metrics.peakVideoFrameQueueDepth = max(
                metrics.peakVideoFrameQueueDepth,
                queueDepth
            )
            metrics.softwarePoolAllocatedBuffers = currentPlanar?.uniqueBuffers ?? 0
            metrics.softwarePoolReusedCheckouts = currentPlanar?.reusedCheckouts ?? 0
            metrics.softwarePoolBytesPerBuffer = currentPlanar?.bytesPerBuffer ?? 0
            metrics.softwarePoolMaximumBuffers = currentPlanar?.maximumBufferCount ?? 0
            metrics.softwarePoolInUseUpperBound = currentPlanar?.inUseUpperBound ?? 0
            metrics.softwarePoolFreeLowerBound = currentPlanar?.freeLowerBound ?? 0
            metrics.softwareDecodeErrorsDropped = decoder.droppedSoftwareDecodeErrors
            metrics.softwareCorruptFramesDropped = decoder.droppedCorruptSoftwareFrames
            metrics.discardedSeekPrerollFrames = decoder.discardedSeekPrerollFrames
            metrics.seekPrerollNonReferencePackets = decoder.seekPrerollNonReferencePackets
            metrics.softwareSeekAccelerationCount = decoder.softwareSeekAccelerationCount
            metrics.hardwareSeekRestorationCount = decoder.hardwareSeekRestorationCount
            guard let cumulativePlanar else { return }
            metrics.softwarePoolThresholdWaits = cumulativePlanar.thresholdWaits
            metrics.softwarePoolTimeouts = cumulativePlanar.timeouts
            metrics.softwarePoolCancellations = cumulativePlanar.cancellations
            metrics.softwareBGRAFallbackFrames = cumulativePlanar.bgraFallbacks
            metrics.softwareOldGenerationRetainedUpperBound =
                decoder.oldGenerationPlanarBuffersRetainedUpperBound
        }
    }

    func recoverVideoDecoderInSoftware() -> SoftwareVideoRecoveryDisposition? {
        guard let decoder = videoDecoder else { return nil }
        do {
            let wasHardware = decoder.hardwareWasConfigured
            let recreated = wasHardware
                ? try decoder.switchToSoftware()
                : try decoder.restartSoftwareDecoder()
            guard recreated else { return nil }

            let rawTime = presentation.currentTime.seconds
            let activeGeneration = generation.current
            let recoveryState = stateLock.withLock {
                (
                    rate: desiredRate,
                    submittedVideoHorizon: metrics.videoPTS
                )
            }
            let presentationTime = rawTime.isFinite ? max(rawTime, 0) : 0
            let target = max(presentationTime, recoveryState.submittedVideoHorizon)
            let replay = videoRecoveryPackets.takeReplayPackets(
                generation: activeGeneration
            )
            let usesPacketReplay = replay.first?.isKeyframe == true
            let recoveryKind = wasHardware
                ? "software video decoding"
                : "a restarted software video decoder"
            let message = usesPacketReplay
                ? "Continued with \(recoveryKind) by replaying "
                    + "\(replay.count) packets at "
                    + String(format: "%.3f s", target)
                : "Restarted with \(recoveryKind) at "
                    + String(format: "%.3f s", target)
            stateLock.withLock {
                consecutiveHardwareDecodeFailures = 0
                metrics.hardwareDecoder = wasHardware
                    ? "Software fallback after VideoToolbox failure"
                    : "Software decoder restarted after sustained corruption"
                if wasHardware { metrics.hardwareFallbackCount += 1 }
                metrics.lastRecoveryMessage = message
                metrics.isHardwareDecoded = false
                metrics.isCopiedHardwarePath = false
                metrics.isNearZeroCopy = false
            }

            if usesPacketReplay {
                // Keep already-submitted hardware frames and audio moving. Drop
                // only application-queued video, replay the compressed GOP into
                // the new decoder, and reject duplicate output through the last
                // submitted video horizon. The first software frame then joins
                // the existing timeline without a full demux/presentation seek.
                videoFrames.removeAll()
                stateLock.withLock {
                    videoSeekFloor = (activeGeneration, target)
                    pendingVideoRecoveryReplay = replay
                }
                launch("video-decode-recovery-replay", body: videoDecodeLoop)
                return .packetReplay(packetCount: replay.count)
            }

            let recoveryGeneration = seek(
                to: target,
                exact: true,
                resumeRate: recoveryState.rate
            )
            launch("video-decode-recovery", body: videoDecodeLoop)
            return .seek(generation: recoveryGeneration)
        } catch {
            return nil
        }
    }

    func resumeVideoDecodingAfterTransientFailure() -> Bool {
        guard isRunning, videoDecoder?.hardwareWasConfigured == true else {
            return false
        }
        launch("video-decode-retry", body: videoDecodeLoop)
        return true
    }

    func resumeVideoPresentationAfterRecovery() {
        guard isRunning else { return }
        armVideoRendererDemand()
        launch("video-present-recovery", body: videoPresentationLoop)
    }

    func resumeAudioPresentationAfterRecovery() {
        guard isRunning, !stateLock.withLock({ audioDisabled }) else { return }
        armAudioRendererDemand()
        launch("audio-present-recovery", body: audioPresentationLoop)
    }

    func disableAudioTrackAfterFailure() -> Bool {
        let activeGeneration = generation.current
        let changed = stateLock.withLock { () -> Bool in
            guard running, selectedAudio != nil, !audioDisabled else { return false }
            audioDisabled = true
            hasDecodedAudioFrame = false
            endedAudioGeneration = activeGeneration
            return true
        }
        guard changed else { return false }
        _ = delayedAudioInput?.cancelActiveOperation()
        audioEndWait.close()
        audioPackets.removeAll()
        audioFrames.removeAll()
        presentation.audio.stopRequestingMediaData()
        audioDemand.revoke()
        presentation.disableAudio()
        synchronization.disable(.audio)
        startIfPrerolled(.audio, generation: activeGeneration)
        onObservationRequested?(RuntimeObservationRequest(
            source: .decoderDrain,
            urgency: .urgent
        ))
        return true
    }

    func disableSubtitleTrackAfterFailure() -> Bool {
        let changed = stateLock.withLock { () -> Bool in
            guard running, selectedSubtitle != nil, !subtitleDisabled else { return false }
            subtitleDisabled = true
            return true
        }
        guard changed else { return false }
        subtitleReadAhead.close()
        subtitleSeekLock.withLock { pendingSubtitleSeek = nil }
        _ = subtitleInput?.cancelActiveOperation()
        subtitles.clear()
        pictureInPictureSubtitles?.clear()
        onObservationRequested?(RuntimeObservationRequest(
            source: .subtitlePacket,
            urgency: .urgent
        ))
        return true
    }

    private func reportDemuxFailure(_ error: Error) {
        let failure = PlaybackFailure(
            domain: .demux,
            stage: .read,
            stableCode: "nativeDemuxReadFailed",
            nativeCode: (error as? FFmpegError).map { Int64($0.code) },
            recoverability: .fatal
        )
        stateLock.withLock {
            metrics.rendererFailure = error.localizedDescription
            metrics.lastRecoveryFailure = failure
        }
        onFailureObserved?(failure)
        onObservationRequested?(RuntimeObservationRequest(
            source: .rendererFailure,
            urgency: .urgent
        ))
    }

    private func reportAudioFailure(_ error: Error, stage: PlaybackFailure.Stage) {
        guard let selectedAudio else { return }
        let failure = PlaybackFailure(
            domain: .audioDecode,
            stage: stage,
            stableCode: stage == .enqueue
                ? "nativeAudioPresentationFailed"
                : "nativeAudioDecodeFailed",
            nativeCode: (error as? FFmpegError).map { Int64($0.code) },
            recoverability: .fallbackAvailable,
            streamID: PlaybackStreamID(kind: .audio, demuxIndex: selectedAudio.index),
            codecName: selectedAudio.codecName
        )
        stateLock.withLock { metrics.lastRecoveryFailure = failure }
        onFailureObserved?(failure)
    }

    private func failRenderer(_ message: String) {
        stateLock.withLock { metrics.rendererFailure = message }
        onObservationRequested?(RuntimeObservationRequest(
            source: .rendererFailure,
            urgency: .urgent
        ))
    }

    private func recordFormatAdoptionFailure(_ failure: PlaybackFailure) {
        stateLock.withLock {
            metrics.rendererFailure = failure.stableCode
            metrics.lastRecoveryFailure = failure
        }
        onFailureObserved?(failure)
        onObservationRequested?(RuntimeObservationRequest(
            source: .rendererFailure,
            urgency: .urgent
        ))
    }

    private static func pixelFormatName(_ buffer: CVPixelBuffer) -> String {
        let value = CVPixelBufferGetPixelFormatType(buffer)
        let bytes: [UInt8] = [
            UInt8((value >> 24) & 0xff), UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff), UInt8(value & 0xff),
        ]
        let printable = bytes.allSatisfy { $0 >= 32 && $0 < 127 }
        return printable ? String(bytes: bytes, encoding: .ascii) ?? "\(value)" : "\(value)"
    }
}

final class NativeFormatReconfigurationBarrier: @unchecked Sendable {
    private struct Pending {
        let revision: MediaFormatRevisionID
        let semaphore: DispatchSemaphore
    }

    private let lock = NSLock()
    private var pending: [SynchronizedStream: Pending] = [:]

    func begin(
        _ stream: SynchronizedStream,
        revision: MediaFormatRevisionID
    ) -> DispatchSemaphore {
        lock.withLock {
            let semaphore = DispatchSemaphore(value: 0)
            pending[stream] = Pending(
                revision: revision,
                semaphore: semaphore
            )
            return semaphore
        }
    }

    func complete(
        _ stream: SynchronizedStream,
        revision: MediaFormatRevisionID
    ) {
        let semaphore = lock.withLock { () -> DispatchSemaphore? in
            guard pending[stream]?.revision == revision else { return nil }
            return pending.removeValue(forKey: stream)?.semaphore
        }
        semaphore?.signal()
    }

    func cancelAll() {
        let semaphores = lock.withLock {
            let values = pending.values.map(\.semaphore)
            pending.removeAll()
            return values
        }
        for semaphore in semaphores {
            semaphore.signal()
        }
    }
}

private extension NSLock {
    func withLock<Result>(_ body: () -> Result) -> Result {
        lock()
        defer { unlock() }
        return body()
    }
}
