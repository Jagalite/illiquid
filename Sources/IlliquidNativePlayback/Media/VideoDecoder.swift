import CFFmpeg
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

struct NativeDecodedVideoFrame: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let planarOwnershipToken: PlanarFrameOwnershipToken?
    var pipelineCapacityPermit: VideoFrameCapacityPermit? = nil
    let presentationTime: CMTime
    let duration: CMTime
    let generation: Int
    let codedSize: CGSize
    let displaySize: CGSize
    let pixelAspectRatio: CGSize
    let rotationDegrees: Double
    let isHorizontallyMirrored: Bool
    let colorPrimaries: Int32?
    let transferCharacteristic: Int32?
    let matrixCoefficients: Int32?
    let isFullRange: Bool
    let hasMasteringDisplayMetadata: Bool
    let hasContentLightMetadata: Bool
    let sourceComponentDepth: Int
    let ffmpegPixelFormat: String
    let isHardwareDecoded: Bool
    let isCopiedHardwarePath: Bool
    let isNearZeroCopy: Bool
    let chromaLocation: Int32?
    let cleanAperture: CGRect?
    let masteringDisplayMetadata: Data?
    let contentLightMetadata: Data?
    let beginsTimelineDiscontinuity: Bool
    let usesDeinterlacingFilter: Bool
    let deinterlacingFailure: String?

    init(
        pixelBuffer: CVPixelBuffer,
        planarOwnershipToken: PlanarFrameOwnershipToken?,
        pipelineCapacityPermit: VideoFrameCapacityPermit? = nil,
        presentationTime: CMTime,
        duration: CMTime,
        generation: Int,
        codedSize: CGSize,
        displaySize: CGSize,
        pixelAspectRatio: CGSize,
        rotationDegrees: Double,
        colorPrimaries: Int32?,
        transferCharacteristic: Int32?,
        matrixCoefficients: Int32?,
        isFullRange: Bool,
        hasMasteringDisplayMetadata: Bool,
        hasContentLightMetadata: Bool,
        sourceComponentDepth: Int,
        ffmpegPixelFormat: String,
        isHardwareDecoded: Bool,
        isCopiedHardwarePath: Bool,
        isNearZeroCopy: Bool,
        chromaLocation: Int32? = nil,
        cleanAperture: CGRect? = nil,
        masteringDisplayMetadata: Data? = nil,
        contentLightMetadata: Data? = nil,
        beginsTimelineDiscontinuity: Bool = false,
        isHorizontallyMirrored: Bool = false,
        usesDeinterlacingFilter: Bool = false,
        deinterlacingFailure: String? = nil
    ) {
        self.pixelBuffer = pixelBuffer
        self.planarOwnershipToken = planarOwnershipToken
        self.pipelineCapacityPermit = pipelineCapacityPermit
        self.presentationTime = presentationTime
        self.duration = duration
        self.generation = generation
        self.codedSize = codedSize
        self.displaySize = displaySize
        self.pixelAspectRatio = pixelAspectRatio
        self.rotationDegrees = rotationDegrees
        self.isHorizontallyMirrored = isHorizontallyMirrored
        self.colorPrimaries = colorPrimaries
        self.transferCharacteristic = transferCharacteristic
        self.matrixCoefficients = matrixCoefficients
        self.isFullRange = isFullRange
        self.hasMasteringDisplayMetadata = hasMasteringDisplayMetadata
        self.hasContentLightMetadata = hasContentLightMetadata
        self.sourceComponentDepth = sourceComponentDepth
        self.ffmpegPixelFormat = ffmpegPixelFormat
        self.isHardwareDecoded = isHardwareDecoded
        self.isCopiedHardwarePath = isCopiedHardwarePath
        self.isNearZeroCopy = isNearZeroCopy
        self.chromaLocation = chromaLocation
        self.cleanAperture = cleanAperture
        self.masteringDisplayMetadata = masteringDisplayMetadata
        self.contentLightMetadata = contentLightMetadata
        self.beginsTimelineDiscontinuity = beginsTimelineDiscontinuity
        self.usesDeinterlacingFilter = usesDeinterlacingFilter
        self.deinterlacingFailure = deinterlacingFailure
    }
}

enum VideoFrameQueueItem: @unchecked Sendable {
    case frame(NativeDecodedVideoFrame)
    case flush(generation: Int, target: CMTime, resumeRate: Float)
    case endOfStream(generation: Int)
}

enum SoftwarePixelBufferPoolError: Error, Equatable {
    case creation(CVReturn)
    case exhausted
    case cancelled
    case allocation(CVReturn)
}

struct SoftwareVideoDecoderNoProgressError: Error, Equatable, Sendable {
    let consecutiveErrors: Int
}

struct SoftwareVideoDecodeProgressBudget: Equatable, Sendable {
    static let maximumConsecutiveErrors = 32
    private(set) var consecutiveErrors = 0

    mutating func recordError() -> Bool {
        consecutiveErrors += 1
        return consecutiveErrors >= Self.maximumConsecutiveErrors
    }

    mutating func recordFrame() {
        consecutiveErrors = 0
    }
}

enum VideoTimestampDecision: Equatable, Sendable {
    case accept(CMTime, beginsDiscontinuity: Bool)
    case drop
}

struct VideoTimestampValidator: Equatable, Sendable {
    static let maximumContinuousJumpSeconds = 5.0
    static let maximumBackwardJitterSeconds = 0.050

    private(set) var lastAcceptedTime: CMTime?
    private var expectedNextTime: CMTime?

    mutating func reset() {
        lastAcceptedTime = nil
        expectedNextTime = nil
    }

    mutating func validate(_ proposed: CMTime, duration: CMTime) -> VideoTimestampDecision {
        let safeDuration = duration.isNumeric && duration.seconds > 0
            ? duration
            : CMTime(value: 1, timescale: 30)
        let accepted: CMTime
        if proposed.isNumeric, proposed.seconds.isFinite {
            accepted = proposed
        } else if let expectedNextTime, expectedNextTime.isNumeric {
            accepted = expectedNextTime
        } else {
            return .drop
        }

        var discontinuity = false
        if let lastAcceptedTime, lastAcceptedTime.isNumeric {
            let delta = CMTimeSubtract(accepted, lastAcceptedTime).seconds
            guard delta.isFinite else { return .drop }
            if delta < -Self.maximumBackwardJitterSeconds {
                if abs(delta) < Self.maximumContinuousJumpSeconds { return .drop }
                discontinuity = true
            } else if delta > Self.maximumContinuousJumpSeconds {
                discontinuity = true
            }
        }
        lastAcceptedTime = accepted
        expectedNextTime = CMTimeAdd(accepted, safeDuration)
        return .accept(accepted, beginsDiscontinuity: discontinuity)
    }
}

private enum VideoTimestampValidationError: Error {
    case dropFrame
}

enum SoftwareVideoOutputMode {
    case bgra
    /// Stage-1 route that surfaces conversion/allocation failures directly.
    case planarExperiment(rendererAttributes: [String: Any])
    /// Qualified software route. Conversion/allocation failures fall back to
    /// BGRA; cancellation and stale-generation fencing still propagate.
    case planarPreferred(rendererAttributes: [String: Any])
}

struct SoftwarePlanarPoolDiagnostics: Equatable {
    var checkouts = 0
    /// Distinct CVPixelBuffer object identities observed during this pool's
    /// lifetime. This is a lifetime allocation/reuse diagnostic, not a live
    /// ownership count.
    var uniqueBuffers = 0
    var reusedCheckouts = 0
    var bytesPerBuffer = 0
    var maximumBufferCount = 0
    /// CoreVideo exposes no exact live-buffer query. `inUseUpperBound` is the
    /// configured allocation threshold after the first checkout, not measured
    /// occupancy. The global free-buffer notification is counted but is not
    /// treated as pool-specific availability evidence.
    var inUseUpperBound = 0
    var peakInUseUpperBound = 0
    var freeLowerBound = 0
    var freeNotifications = 0
    var thresholdWaits = 0
    var timeouts = 0
    var cancellations = 0
    var bgraFallbacks = 0
}

/// Format-scoped BGRA storage for software decode output. Production admission
/// reserves capacity before checkout, so reaching the allocation threshold is
/// backpressure: checkout waits until ownership returns or the generation is
/// cancelled. Explicit diagnostic timeouts remain available to tests.
final class SoftwareBGRAOutputPool {
    static let qualifiedMaximumBufferCount = 16

    let width: Int
    let height: Int
    let maximumBufferCount: Int
    private let pool: CVPixelBufferPool
    private let allocationAttributes: CFDictionary
    private let available = NSCondition()
    private let waitTimeoutMilliseconds: Int?
    private var freeBufferObserver: NSObjectProtocol?
    private(set) var allocationCount = 0
    private(set) var exhaustionWaitCount = 0

    init(
        width: Int,
        height: Int,
        maximumBufferCount: Int = qualifiedMaximumBufferCount,
        waitTimeoutMilliseconds: Int? = nil
    ) throws {
        precondition(width > 0 && height > 0 && maximumBufferCount > 0)
        self.width = width
        self.height = height
        self.maximumBufferCount = maximumBufferCount
        self.waitTimeoutMilliseconds = waitTimeoutMilliseconds.map { max(0, $0) }
        let pixelAttributes: [CFString: Any] = [
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:],
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
        var created: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            nil,
            pixelAttributes as CFDictionary,
            &created
        )
        guard status == kCVReturnSuccess, let created else {
            throw SoftwarePixelBufferPoolError.creation(status)
        }
        pool = created
        allocationAttributes = [
            kCVPixelBufferPoolAllocationThresholdKey: maximumBufferCount,
        ] as CFDictionary
        let name = Notification.Name(
            rawValue: kCVPixelBufferPoolFreeBufferNotification as String
        )
        freeBufferObserver = NotificationCenter.default.addObserver(
            forName: name,
            object: nil,
            queue: nil
        ) { [available] _ in
            available.lock()
            available.signal()
            available.unlock()
        }
    }

    deinit {
        if let freeBufferObserver {
            NotificationCenter.default.removeObserver(freeBufferObserver)
        }
    }

    func makePixelBuffer(
        while shouldContinue: () -> Bool = { true }
    ) throws -> CVPixelBuffer {
        let deadline = waitTimeoutMilliseconds.map {
            Date().addingTimeInterval(Double($0) / 1_000)
        }
        while true {
            guard shouldContinue() else {
                throw SoftwarePixelBufferPoolError.cancelled
            }
            var output: CVPixelBuffer?
            let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
                kCFAllocatorDefault,
                pool,
                allocationAttributes,
                &output
            )
            if status == kCVReturnSuccess, let output {
                allocationCount += 1
                return output
            }
            guard status == kCVReturnWouldExceedAllocationThreshold else {
                throw SoftwarePixelBufferPoolError.allocation(status)
            }
            exhaustionWaitCount += 1
            if let deadline, Date() >= deadline {
                throw SoftwarePixelBufferPoolError.exhausted
            }
            available.lock()
            let pollDeadline = Date().addingTimeInterval(0.01)
            _ = available.wait(until: deadline.map {
                min($0, pollDeadline)
            } ?? pollDeadline)
            available.unlock()
        }
    }
}

/// Generation- and format-scoped planar software-output storage. Experiment
/// mode surfaces failures while production preferred mode retains BGRA as its
/// correctness fallback.
final class SoftwarePlanarOutputPool: @unchecked Sendable {
    let generation: Int
    let width: Int
    let height: Int
    let pixelFormat: OSType
    let maximumBufferCount: Int
    private let pool: CVPixelBufferPool
    private let allocationAttributes: CFDictionary
    private let available = NSCondition()
    private let waitTimeoutMilliseconds: Int
    private let ownershipLedger: PlanarBufferOwnershipLedger
    private let stateLock = NSLock()
    private var freeBufferObserver: NSObjectProtocol?
    private var state = SoftwarePlanarPoolDiagnostics()
    private var bufferIdentities: Set<UInt> = []

    init(
        generation: Int,
        width: Int,
        height: Int,
        pixelFormat: OSType,
        rendererAttributes: [String: Any],
        ownershipLedger: PlanarBufferOwnershipLedger = PlanarBufferOwnershipLedger(),
        maximumBufferCount: Int = SoftwareBGRAOutputPool.qualifiedMaximumBufferCount,
        waitTimeoutMilliseconds: Int = 500
    ) throws {
        precondition(width > 0 && height > 0 && maximumBufferCount > 0)
        self.generation = generation
        self.width = width
        self.height = height
        self.pixelFormat = pixelFormat
        self.maximumBufferCount = maximumBufferCount
        self.waitTimeoutMilliseconds = max(0, waitTimeoutMilliseconds)
        self.ownershipLedger = ownershipLedger
        state.maximumBufferCount = maximumBufferCount
        var pixelAttributes = rendererAttributes
        pixelAttributes[kCVPixelBufferWidthKey as String] = width
        pixelAttributes[kCVPixelBufferHeightKey as String] = height
        pixelAttributes[kCVPixelBufferPixelFormatTypeKey as String] = pixelFormat
        pixelAttributes[kCVPixelBufferIOSurfacePropertiesKey as String] = [:]
        var created: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            nil,
            pixelAttributes as CFDictionary,
            &created
        )
        guard status == kCVReturnSuccess, let created else {
            throw SoftwarePixelBufferPoolError.creation(status)
        }
        pool = created
        allocationAttributes = [
            kCVPixelBufferPoolAllocationThresholdKey: maximumBufferCount,
        ] as CFDictionary
        let name = Notification.Name(
            rawValue: kCVPixelBufferPoolFreeBufferNotification as String
        )
        freeBufferObserver = NotificationCenter.default.addObserver(
            forName: name,
            // CoreVideo posts this notification without bridging the pool as
            // the Foundation notification object. Match the proven BGRA-pool
            // behavior and observe the name globally; experiment runs own a
            // single planar pool at a time.
            object: nil,
            queue: nil
        ) { [weak self, available] _ in
            self?.stateLock.withLock {
                guard let self else { return }
                self.state.freeNotifications += 1
            }
            available.lock()
            available.signal()
            available.unlock()
        }
    }

    deinit {
        if let freeBufferObserver {
            NotificationCenter.default.removeObserver(freeBufferObserver)
        }
    }

    var diagnostics: SoftwarePlanarPoolDiagnostics {
        stateLock.withLock { state }
    }

    /// Temporarily checks out and immediately releases as many buffers as the
    /// allocation threshold permits. This perturbs pool allocation state and
    /// is for isolated lifecycle diagnostics only; production playback must
    /// never call it while active.
    func immediatelyAvailableBufferCountForDiagnostics() -> Int {
        var held: [CVPixelBuffer] = []
        held.reserveCapacity(maximumBufferCount)
        for _ in 0..<maximumBufferCount {
            var output: CVPixelBuffer?
            let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
                kCFAllocatorDefault,
                pool,
                allocationAttributes,
                &output
            )
            guard status == kCVReturnSuccess, let output else { break }
            held.append(output)
        }
        return held.count
    }

    func makePixelBuffer(
        while shouldContinue: () -> Bool = { true }
    ) throws -> CVPixelBuffer {
        let deadline = Date().addingTimeInterval(
            Double(waitTimeoutMilliseconds) / 1_000
        )
        var recordedThresholdWait = false
        while true {
            guard shouldContinue() else {
                stateLock.withLock { state.cancellations += 1 }
                throw SoftwarePixelBufferPoolError.cancelled
            }
            var output: CVPixelBuffer?
            let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
                kCFAllocatorDefault,
                pool,
                allocationAttributes,
                &output
            )
            if status == kCVReturnSuccess, let output {
                stateLock.withLock {
                    state.checkouts += 1
                    let identity = UInt(bitPattern: Unmanaged
                        .passUnretained(output)
                        .toOpaque())
                    let insertion = bufferIdentities.insert(identity)
                    state.uniqueBuffers = bufferIdentities.count
                    if !insertion.inserted {
                        state.reusedCheckouts += 1
                    }
                    state.bytesPerBuffer = max(
                        state.bytesPerBuffer,
                        CVPixelBufferGetDataSize(output)
                    )
                    state.freeLowerBound = 0
                    state.inUseUpperBound = maximumBufferCount
                    state.peakInUseUpperBound = max(
                        state.peakInUseUpperBound,
                        state.inUseUpperBound
                    )
                }
                return output
            }
            guard status == kCVReturnWouldExceedAllocationThreshold else {
                throw SoftwarePixelBufferPoolError.allocation(status)
            }
            if !recordedThresholdWait {
                stateLock.withLock { state.thresholdWaits += 1 }
                ownershipLedger.recordPoolThresholdWait(generation: generation)
                recordedThresholdWait = true
            }
            if waitTimeoutMilliseconds == 0 || Date() >= deadline {
                stateLock.withLock { state.timeouts += 1 }
                ownershipLedger.recordPoolTimeout(generation: generation)
                throw SoftwarePixelBufferPoolError.exhausted
            }
            available.lock()
            _ = available.wait(until: min(
                deadline,
                Date().addingTimeInterval(0.01)
            ))
            available.unlock()
        }
    }
}

final class VideoDecoder {
    private final class SeekPrerollFallback {
        var frame: UnsafeMutablePointer<AVFrame>?
        let generation: Int
        let timeBase: FFmpegRational
        let filtered: Bool
        let copiedHardware: Bool
        let pts: CMTime
        let discontinuity: Bool
        init(output: VideoDeinterlacer.Output, generation: Int, pts: CMTime, discontinuity: Bool) throws {
            guard let copy = av_frame_clone(output.frame) else {
                throw FFmpegError(operation: "Retain thumbnail EOF fallback", code: -12)
            }
            frame = copy
            self.generation = generation
            timeBase = output.timeBase
            filtered = output.filtered
            copiedHardware = output.copiedHardware
            self.pts = pts
            self.discontinuity = discontinuity
        }
        deinit { av_frame_free(&frame) }
    }
    private struct OutputDeliveryError: Error { let underlying: Error }
    private let deinterlacer: VideoDeinterlacer?
    private var deinterlacingFailure: String?
    private var context: UnsafeMutablePointer<AVCodecContext>?
    private var frame: UnsafeMutablePointer<AVFrame>?
    private var parameters: UnsafeMutablePointer<AVCodecParameters>?
    private var conversionContext: UnsafeMutablePointer<SwsContext>?
    private var softwarePixelBufferPool: SoftwareBGRAOutputPool?
    private var softwarePlanarPixelBufferPool: SoftwarePlanarOutputPool?
    private var retiredPlanarDiagnostics = SoftwarePlanarPoolDiagnostics()
    private var planarFallbackGeneration: Int?
    private let softwareOutputMode: SoftwareVideoOutputMode
    private let softwareDecoderThreadCount: Int
    private let softwarePlanarOutputMaximumBufferCount: Int
    private let planarOwnershipLedger = PlanarBufferOwnershipLedger()
    private let stream: FFmpegStreamInfo
    var streamInfo: FFmpegStreamInfo { stream }
    private let timelineOriginSeconds: Double
    private(set) var hardwareWasConfigured = false
    private(set) var hardwareWasRequested = false
    private(set) var hardwareCapabilityWasAdvertised = false
    private(set) var hardwarePlatformWasSupported = false
    private(set) var hardwareFallbackReason: String?
    private(set) var softwareFallbackActivated = false
    private(set) var droppedSoftwareDecodeErrors = 0
    private(set) var droppedCorruptSoftwareFrames = 0
    private(set) var discardedSeekPrerollFrames = 0
    private(set) var seekPrerollNonReferencePackets = 0
    private let seekPrerollFrameSkippingEnabled: Bool
    private let softwareSeekAccelerationEnabled: Bool
    private(set) var isAcceleratingSeekInSoftware = false
    private(set) var softwareSeekAccelerationCount = 0
    private(set) var hardwareSeekRestorationCount = 0
    private var seekAccelerationNeedsDecision = true
    private let streamDeclaresProgressive: Bool
    private var observedInterlacedFrame = false
    private var seekPrerollDecodePolicy = SeekPrerollDecodePolicy()
    // Set only by the owning decode worker, after any generation flush.
    var seekOutputFloor: (generation: Int, seconds: Double)?
    // Thumbnail-only EOF fallback: one reference-counted native frame, never
    // a history of converted images or compressed packets. Playback leaves off.
    var retainsSeekPrerollFallback = false
    private var seekPrerollFallback: SeekPrerollFallback?
    var seekPrerollFallbackProgress: (seconds: Double, filtered: Bool, discontinuity: Bool)? {
        seekPrerollFallback.map { ($0.pts.seconds, $0.filtered, $0.discontinuity) }
    }
    private var softwareDecodeProgress = SoftwareVideoDecodeProgressBudget()
    private var timestampValidator = VideoTimestampValidator()

    init(
        parameters: UnsafePointer<AVCodecParameters>,
        stream: FFmpegStreamInfo,
        preferHardware: Bool,
        timelineOriginSeconds: Double = 0,
        softwareOutputMode: SoftwareVideoOutputMode = .bgra,
        softwareDecoderThreadCount: Int = 0,
        softwarePlanarOutputMaximumBufferCount: Int =
            SoftwareBGRAOutputPool.qualifiedMaximumBufferCount,
        deinterlacingEnabled: Bool = true,
        seekPrerollFrameSkippingEnabled: Bool = true,
        softwareSeekAccelerationEnabled: Bool = true
    ) throws {
        self.seekPrerollFrameSkippingEnabled = seekPrerollFrameSkippingEnabled
        self.softwareSeekAccelerationEnabled = softwareSeekAccelerationEnabled
        streamDeclaresProgressive = parameters.pointee.field_order == AV_FIELD_PROGRESSIVE
        self.stream = stream
        deinterlacer = deinterlacingEnabled ? try VideoDeinterlacer(timeBase: stream.timeBase, nominalFrameRate: stream.averageFrameRate) : nil
        self.timelineOriginSeconds = timelineOriginSeconds
        self.softwareOutputMode = softwareOutputMode
        self.softwareDecoderThreadCount = max(0, softwareDecoderThreadCount)
        self.softwarePlanarOutputMaximumBufferCount = max(
            1,
            softwarePlanarOutputMaximumBufferCount
        )
        hardwareWasRequested = preferHardware
        hardwareCapabilityWasAdvertised =
            illiquid_decoder_supports_videotoolbox(parameters) != 0
        hardwarePlatformWasSupported = Self.platformSupportsHardwareDecode(
            codecName: stream.codecName,
            registerSupplementalVP9: Self.isVP9HardwareExperimentEnabled
        )
        let shouldRequestHardware = preferHardware
            && hardwareCapabilityWasAdvertised
            && hardwarePlatformWasSupported
        var createdContext: UnsafeMutablePointer<AVCodecContext>?
        var hardwareConfigured: Int32 = 0
        try checkFFmpeg(
            illiquid_create_decoder_with_thread_count(
                parameters,
                shouldRequestHardware ? 1 : 0,
                Int32(self.softwareDecoderThreadCount),
                &createdContext,
                &hardwareConfigured
            ),
            operation: "Open \(stream.codecName) video decoder"
        )
        guard let createdContext, let frame = av_frame_alloc() else {
            avcodec_free_context(&createdContext)
            throw FFmpegError(
                operation: "Allocate video decoder frame",
                code: illiquid_averror_nomem()
            )
        }

        guard let copiedParameters = avcodec_parameters_alloc() else {
            var disposableContext: UnsafeMutablePointer<AVCodecContext>? = createdContext
            var disposableFrame: UnsafeMutablePointer<AVFrame>? = frame
            av_frame_free(&disposableFrame)
            avcodec_free_context(&disposableContext)
            throw FFmpegError(
                operation: "Allocate retained video codec parameters",
                code: illiquid_averror_nomem()
            )
        }
        let copyResult = avcodec_parameters_copy(copiedParameters, parameters)
        guard copyResult >= 0 else {
            var disposableContext: UnsafeMutablePointer<AVCodecContext>? = createdContext
            var disposableParameters: UnsafeMutablePointer<AVCodecParameters>? = copiedParameters
            var disposableFrame: UnsafeMutablePointer<AVFrame>? = frame
            avcodec_parameters_free(&disposableParameters)
            av_frame_free(&disposableFrame)
            avcodec_free_context(&disposableContext)
            throw FFmpegError(
                operation: "Retain video codec parameters",
                code: copyResult
            )
        }

        context = createdContext
        self.frame = frame
        self.parameters = copiedParameters
        hardwareWasConfigured = hardwareConfigured != 0
        if preferHardware, !hardwareWasConfigured {
            if !hardwareCapabilityWasAdvertised {
                hardwareFallbackReason = "Codec does not advertise VideoToolbox decoding"
            } else if !hardwarePlatformWasSupported {
                hardwareFallbackReason = "VideoToolbox does not support this codec on this Mac"
            } else {
                hardwareFallbackReason = "VideoToolbox decoder initialization failed"
            }
        }
    }

    var hardwareStatusDescription: String {
        if isAcceleratingSeekInSoftware { return "Bounded software seek acceleration" }
        if hardwareWasConfigured { return "FFmpeg VideoToolbox configured" }
        if let hardwareFallbackReason { return "Software decoder — \(hardwareFallbackReason)" }
        return "Software decoder"
    }

    private static let isVP9HardwareExperimentEnabled = supplementalVP9ExperimentEnabled()

    static func supplementalVP9ExperimentEnabled(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> Bool {
        bundleIdentifier == "com.example.IlliquidBenchmark"
            && environment["ILLIQUID_ENABLE_BENCHMARK_OVERRIDES"] == "1"
            && environment["ILLIQUID_BENCHMARK_VP9_HARDWARE"] == "1"
    }

    static func platformSupportsHardwareDecode(
        codecName: String,
        registerSupplementalVP9: Bool = false,
        registerSupplemental: (CMVideoCodecType) -> Void = VTRegisterSupplementalVideoDecoderIfAvailable,
        isSupported: (CMVideoCodecType) -> Bool = VTIsHardwareDecodeSupported
    ) -> Bool {
        let normalizedName = codecName.lowercased()
        let codecType: CMVideoCodecType? = switch normalizedName {
        case "h264": kCMVideoCodecType_H264
        case "hevc": kCMVideoCodecType_HEVC
        case "vp9": CMVideoCodecType(0x7670_3039) // vp09
        case "av1": CMVideoCodecType(0x6176_3031) // av01
        default: nil
        }
        guard let codecType else { return true }
        // Supplemental VP9 reduces steady CPU, but measured first-open/seek
        // latency needs further work. Keep opt-in discovery benchmark-only until
        // both paths qualify together. Registration alone never implies support.
        if normalizedName == "vp9", registerSupplementalVP9 {
            registerSupplemental(codecType)
        }
        return isSupported(codecType)
    }

    deinit {
        illiquid_free_sws_context(conversionContext)
        avcodec_parameters_free(&parameters)
        av_frame_free(&frame)
        avcodec_free_context(&context)
    }

    /// Recreates the decoder without a hardware device. The caller must next
    /// submit packets beginning at a decodable keyframe, either from a bounded
    /// compressed-packet replay or an exact seek, because the replacement has
    /// no reference frames from the previous decoder.
    func switchToSoftware() throws -> Bool {
        guard hardwareWasConfigured,
              !softwareFallbackActivated,
              let parameters
        else { return false }

        var replacement: UnsafeMutablePointer<AVCodecContext>?
        var hardwareConfigured: Int32 = 0
        try checkFFmpeg(
            illiquid_create_decoder_with_thread_count(
                parameters,
                0,
                Int32(softwareDecoderThreadCount),
                &replacement,
                &hardwareConfigured
            ),
            operation: "Open software \(stream.codecName) video decoder"
        )
        guard let replacement else {
            throw FFmpegError(
                operation: "Create software video decoder",
                code: illiquid_averror_nomem()
            )
        }

        if let frame { av_frame_unref(frame) }
        avcodec_free_context(&context)
        context = replacement
        illiquid_free_sws_context(conversionContext)
        conversionContext = nil
        softwarePixelBufferPool = nil
        retirePlanarPool()
        hardwareWasConfigured = false
        softwareFallbackActivated = true
        softwareDecodeProgress.recordFrame()
        timestampValidator.reset()
        deinterlacer?.reset()
        deinterlacingFailure = nil
        return true
    }

    func restartSoftwareDecoder() throws -> Bool {
        guard !hardwareWasConfigured, let parameters else { return false }
        var replacement: UnsafeMutablePointer<AVCodecContext>?
        var hardwareConfigured: Int32 = 0
        try checkFFmpeg(
            illiquid_create_decoder_with_thread_count(
                parameters,
                0,
                Int32(softwareDecoderThreadCount),
                &replacement,
                &hardwareConfigured
            ),
            operation: "Restart software \(stream.codecName) video decoder"
        )
        guard let replacement else { return false }
        if let frame { av_frame_unref(frame) }
        avcodec_free_context(&context)
        context = replacement
        illiquid_free_sws_context(conversionContext)
        conversionContext = nil
        softwarePixelBufferPool = nil
        retirePlanarPool()
        planarFallbackGeneration = nil
        softwareDecodeProgress.recordFrame()
        timestampValidator.reset()
        deinterlacer?.reset()
        deinterlacingFailure = nil
        return true
    }

    func decode(_ packet: FFmpegPacket) throws -> [NativeDecodedVideoFrame] {
        var output: [NativeDecodedVideoFrame] = []
        try decode(packet, while: { true }) { output.append($0) }
        return output
    }

    func decode(
        _ packet: FFmpegPacket,
        while shouldContinue: () -> Bool,
        reserveSoftwareOutput: (() -> VideoFrameCapacityPermit?)? = nil,
        emit: (NativeDecodedVideoFrame) throws -> Void
    ) throws {
        guard shouldContinue() else {
            retiredPlanarDiagnostics.cancellations += 1
            throw SoftwarePixelBufferPoolError.cancelled
        }
        try prepareSeekDecoder(for: packet, while: shouldContinue,
            reserveSoftwareOutput: reserveSoftwareOutput, emit: emit)
        guard let context, let packetPointer = packet.pointer else { return }
        let floor = seekOutputFloor.flatMap { $0.generation == packet.generation ? $0.seconds : nil }
        let skipsNonReference = seekPrerollDecodePolicy.shouldSkipNonReference(
            generation: packet.generation, target: floor,
            presentationTime: packet.presentationSeconds.map { $0 - timelineOriginSeconds },
            decodeTime: packet.decodeSeconds.map { $0 - timelineOriginSeconds },
            frameRate: stream.averageFrameRate,
            eligible: seekPrerollFrameSkippingEnabled && streamDeclaresProgressive
                && !observedInterlacedFrame && !retainsSeekPrerollFallback && !packet.isCorrupt
                && ["h264", "hevc"].contains(stream.codecName)
        )
        context.pointee.skip_frame = skipsNonReference ? AVDISCARD_NONREF : AVDISCARD_DEFAULT
        if skipsNonReference { seekPrerollNonReferencePackets += 1 }
        defer { context.pointee.skip_frame = AVDISCARD_DEFAULT }
        var sendResult = avcodec_send_packet(context, packetPointer)
        if sendResult == illiquid_averror_eagain() {
            try receiveFrames(
                generation: packet.generation,
                while: shouldContinue,
                reserveSoftwareOutput: reserveSoftwareOutput,
                emit: emit
            )
            if observedInterlacedFrame { context.pointee.skip_frame = AVDISCARD_DEFAULT }
            sendResult = avcodec_send_packet(context, packetPointer)
        }
        // libavcodec's software decoders remain usable after malformed access
        // units. mpv consumes these failures and keeps feeding later packets;
        // do the same instead of promoting every damaged region to a terminal
        // playback failure. Allocation failure is different: the decoder may
        // not have consumed the packet and the process is out of memory.
        if sendResult < 0,
           !hardwareWasConfigured,
           sendResult != illiquid_averror_nomem()
        {
            try recordSoftwareDecodeError()
            return
        }
        try checkFFmpeg(sendResult, operation: "Submit video packet")
        try receiveFrames(
            generation: packet.generation,
            while: shouldContinue,
            reserveSoftwareOutput: reserveSoftwareOutput,
            emit: emit
        )
    }

    func drain(generation: Int) throws -> [NativeDecodedVideoFrame] {
        var output: [NativeDecodedVideoFrame] = []
        try drain(generation: generation, while: { true }) { output.append($0) }
        return output
    }

    func drain(
        generation: Int,
        while shouldContinue: () -> Bool,
        reserveSoftwareOutput: (() -> VideoFrameCapacityPermit?)? = nil,
        emit: (NativeDecodedVideoFrame) throws -> Void
    ) throws {
        guard let context else { return }
        let result = avcodec_send_packet(context, nil)
        if result != illiquid_averror_eof(),
           result != illiquid_averror_eagain()
        {
            if result < 0,
               !hardwareWasConfigured,
               result != illiquid_averror_nomem()
            {
                try recordSoftwareDecodeError()
                return
            }
            try checkFFmpeg(result, operation: "Drain video decoder")
        }
        try receiveFrames(
            generation: generation,
            while: shouldContinue,
            reserveSoftwareOutput: reserveSoftwareOutput,
            emit: emit
        )
        if let deinterlacer, deinterlacingFailure == nil {
            try deinterlacer.drain(while: shouldContinue) { output in
                try deliver(output, generation: generation, while: shouldContinue,
                            reserveSoftwareOutput: reserveSoftwareOutput, emit: emit)
            }
        }
    }

    func flush() {
        seekAccelerationNeedsDecision = true
        softwareSeekAccelerationCount = 0
        hardwareSeekRestorationCount = 0
        seekPrerollFallback = nil
        seekPrerollDecodePolicy.reset()
        seekPrerollNonReferencePackets = 0
        guard let context else { return }
        context.pointee.skip_frame = AVDISCARD_DEFAULT
        avcodec_flush_buffers(context)
        seekOutputFloor = nil
        discardedSeekPrerollFrames = 0
        softwarePixelBufferPool = nil
        retirePlanarPool()
        planarFallbackGeneration = nil
        softwareDecodeProgress.recordFrame()
        timestampValidator.reset()
        deinterlacer?.reset()
        deinterlacingFailure = nil
    }

    private func prepareSeekDecoder(
        for packet: FFmpegPacket, while shouldContinue: () -> Bool,
        reserveSoftwareOutput: (() -> VideoFrameCapacityPermit?)?,
        emit: (NativeDecodedVideoFrame) throws -> Void
    ) throws {
        guard let parameters, let pointer = packet.pointer else { return }
        let firstPacket = seekAccelerationNeedsDecision
        seekAccelerationNeedsDecision = false
        guard firstPacket || isAcceleratingSeekInSoftware else { return }
        let idr = illiquid_packet_is_h264_idr(pointer, parameters) != 0
        let floor = seekOutputFloor.flatMap { $0.generation == packet.generation ? $0.seconds : nil }
        let packetTime = packet.presentationSeconds.map { $0 - timelineOriginSeconds }
        let process = ProcessInfo.processInfo
        let mayAccelerate = firstPacket && SoftwareSeekAccelerationPolicy.shouldAccelerate(
            target: floor, packetTime: packetTime,
            width: Int(parameters.pointee.width), height: Int(parameters.pointee.height),
            eligible: softwareSeekAccelerationEnabled && hardwareWasRequested
                && (hardwareWasConfigured || isAcceleratingSeekInSoftware)
                && !softwareFallbackActivated && idr && streamDeclaresProgressive
                && !observedInterlacedFrame && !retainsSeekPrerollFallback
                && planarConfiguration != nil && parameters.pointee.format == AV_PIX_FMT_YUV420P.rawValue
                && stream.averageFrameRate.map { $0.isFinite && $0 > 0 && $0 <= 60 } == true
                && process.physicalMemory >= 8 * 1_024 * 1_024 * 1_024
                && !process.isLowPowerModeEnabled
                && (process.thermalState == .nominal || process.thermalState == .fair)
        )
        if mayAccelerate && isAcceleratingSeekInSoftware {
            softwareSeekAccelerationCount += 1
            return
        }
        let restoreHardware = isAcceleratingSeekInSoftware && idr && !mayAccelerate
            && (firstPacket || floor == nil || (packetTime ?? -.infinity) >= (floor ?? 0))
        guard mayAccelerate || restoreHardware else { return }
        var replacement: UnsafeMutablePointer<AVCodecContext>?
        var hardware: Int32 = 0
        let threads = restoreHardware ? softwareDecoderThreadCount
            : min(SoftwareSeekAccelerationPolicy.maximumThreads, max(1, process.activeProcessorCount))
        let result = illiquid_create_decoder_with_thread_count(
            parameters, restoreHardware ? 1 : 0, Int32(threads), &replacement, &hardware)
        defer { avcodec_free_context(&replacement) }
        // Acceleration is optional; retain the working decoder on allocation
        // or initialization failure. Never drain it before replacement exists.
        guard result >= 0, replacement != nil, !restoreHardware || hardware != 0 else { return }
        if restoreHardware && !firstPacket {
            // Frame threading and B pictures can retain output preceding IDR.
            // Deliver it before changing contexts, preserving PTS continuity.
            try drain(generation: packet.generation, while: shouldContinue,
                      reserveSoftwareOutput: reserveSoftwareOutput, emit: emit)
        }
        guard shouldContinue() else { throw SoftwarePixelBufferPoolError.cancelled }
        if let frame { av_frame_unref(frame) }
        avcodec_free_context(&context)
        context = replacement
        replacement = nil
        hardwareWasConfigured = restoreHardware
        isAcceleratingSeekInSoftware = !restoreHardware
        illiquid_free_sws_context(conversionContext)
        conversionContext = nil
        softwarePixelBufferPool = nil
        retirePlanarPool()
        deinterlacer?.reset()
        deinterlacingFailure = nil
        if restoreHardware { hardwareSeekRestorationCount += 1 }
        else { softwareSeekAccelerationCount += 1 }
    }

    func takeSeekPrerollFallback(generation: Int, while shouldContinue: () -> Bool) throws -> NativeDecodedVideoFrame? {
        guard let retained = seekPrerollFallback, retained.generation == generation else { return nil }
        seekPrerollFallback = nil
        guard let frame = retained.frame,
              shouldContinue() else { return nil }
        return try makeFrame(frame, generation: generation, while: shouldContinue,
            reserveSoftwareOutput: nil,
            filteredOutput: .init(frame: frame, timeBase: retained.timeBase,
                                  filtered: retained.filtered, copiedHardware: retained.copiedHardware),
            validatedTimestamp: retained.pts, validatedDiscontinuity: retained.discontinuity)
    }

    var planarExperimentDiagnostics: SoftwarePlanarPoolDiagnostics? {
        softwarePlanarPixelBufferPool?.diagnostics
    }

    var currentPlanarOutputDiagnostics: SoftwarePlanarPoolDiagnostics? {
        softwarePlanarPixelBufferPool?.diagnostics
    }

    var planarOutputDiagnostics: SoftwarePlanarPoolDiagnostics? {
        guard softwarePlanarPixelBufferPool != nil
            || retiredPlanarDiagnostics.checkouts > 0
            || retiredPlanarDiagnostics.bgraFallbacks > 0
            || retiredPlanarDiagnostics.cancellations > 0
            || retiredPlanarDiagnostics.thresholdWaits > 0
            || retiredPlanarDiagnostics.timeouts > 0
        else { return nil }
        return combinedPlanarDiagnostics()
    }

    /// Renderer ownership outlives the decoder's pool reference, and CoreVideo
    /// exposes no generation-scoped live-buffer query. A cumulative retired
    /// pool cap is not evidence that old-generation buffers remain retained.
    var oldGenerationPlanarBuffersRetainedUpperBound: Int? {
        nil
    }

    func planarOwnershipSnapshot(activeGeneration: Int) -> PlanarBufferOwnershipSnapshot {
        planarOwnershipLedger.snapshot(activeGeneration: activeGeneration)
    }

    func planarPoolImmediateAvailabilityForDiagnostics() -> Int? {
        softwarePlanarPixelBufferPool?.immediatelyAvailableBufferCountForDiagnostics()
    }

    func recordPlanarFlushRequested(activeGeneration: Int) {
        planarOwnershipLedger.recordFlushRequested(activeGeneration: activeGeneration)
    }

    func planarVideoFlushCompletionRecorder(
        activeGeneration: Int
    ) -> @Sendable () -> Void {
        let ledger = planarOwnershipLedger
        return {
            ledger.recordVideoFlushCompleted(activeGeneration: activeGeneration)
        }
    }

    private func receiveFrames(
        generation: Int,
        while shouldContinue: () -> Bool,
        reserveSoftwareOutput: (() -> VideoFrameCapacityPermit?)?,
        emit: (NativeDecodedVideoFrame) throws -> Void
    ) throws {
        guard let context, let frame else { return }

        while true {
            guard shouldContinue() else {
                retiredPlanarDiagnostics.cancellations += 1
                throw SoftwarePixelBufferPoolError.cancelled
            }
            av_frame_unref(frame)
            let result = avcodec_receive_frame(context, frame)
            if result == illiquid_averror_eagain()
                || result == illiquid_averror_eof()
            {
                break
            }
            if result < 0,
               !hardwareWasConfigured,
               result != illiquid_averror_nomem()
            {
                try recordSoftwareDecodeError()
                break
            }
            try checkFFmpeg(result, operation: "Decode video frame")
            if frame.pointee.flags & AV_FRAME_FLAG_INTERLACED != 0 {
                observedInterlacedFrame = true
                context.pointee.skip_frame = AVDISCARD_DEFAULT
            }
            if !hardwareWasConfigured,
               illiquid_frame_is_corrupt(frame) != 0
            {
                droppedCorruptSoftwareFrames += 1
                try recordSoftwareDecodeError()
                continue
            }
            if let deinterlacer, deinterlacingFailure == nil {
                var delivered = false
                do {
                    try deinterlacer.process(frame, while: shouldContinue) { output in
                        do {
                            try deliver(output, generation: generation, while: shouldContinue,
                                        reserveSoftwareOutput: reserveSoftwareOutput, emit: emit)
                            delivered = true
                        } catch { throw OutputDeliveryError(underlying: error) }
                    }
                    continue
                } catch let error as OutputDeliveryError {
                    throw error.underlying
                } catch SoftwarePixelBufferPoolError.cancelled {
                    throw SoftwarePixelBufferPoolError.cancelled
                } catch {
                    // Automatic filtering must preserve playability if its
                    // format/resource contract rejects a source. Pin fallback
                    // for this generation and report it with subsequent frames.
                    deinterlacingFailure = error.localizedDescription
                    deinterlacer.reset()
                    if delivered { continue }
                }
            }
            try deliver(.init(frame: frame, timeBase: stream.timeBase, filtered: false, copiedHardware: false),
                        generation: generation, while: shouldContinue, reserveSoftwareOutput: reserveSoftwareOutput, emit: emit)
        }
    }

    private func deliver(_ output: VideoDeinterlacer.Output, generation: Int,
                         while shouldContinue: () -> Bool,
                         reserveSoftwareOutput: (() -> VideoFrameCapacityPermit?)?,
                         emit: (NativeDecodedVideoFrame) throws -> Void) throws {
        let decoded: NativeDecodedVideoFrame
        do {
            decoded = try makeFrame(output.frame, generation: generation, while: shouldContinue,
                                    reserveSoftwareOutput: reserveSoftwareOutput, filteredOutput: output)
        } catch VideoTimestampValidationError.dropFrame { return }
        softwareDecodeProgress.recordFrame()
        try emit(decoded)
    }

    private func recordSoftwareDecodeError() throws {
        droppedSoftwareDecodeErrors += 1
        if softwareDecodeProgress.recordError() {
            throw SoftwareVideoDecoderNoProgressError(
                consecutiveErrors: softwareDecodeProgress.consecutiveErrors
            )
        }
    }

    private func makeFrame(
        _ frame: UnsafeMutablePointer<AVFrame>,
        generation: Int,
        while shouldContinue: () -> Bool,
        reserveSoftwareOutput: (() -> VideoFrameCapacityPermit?)?,
        filteredOutput: VideoDeinterlacer.Output,
        validatedTimestamp: CMTime? = nil,
        validatedDiscontinuity: Bool = false
    ) throws -> NativeDecodedVideoFrame {
        let width = illiquid_frame_width(frame)
        let height = illiquid_frame_height(frame)
        guard width > 0, height > 0 else {
            throw FFmpegError(operation: "Decode video dimensions", code: -22)
        }

        let pixelFormat = illiquid_frame_pixel_format(frame)
        let pixelFormatName = illiquid_frame_pixel_format_name(frame)
            .map(String.init(cString:)) ?? "unknown"
        let isHardware = pixelFormat == AV_PIX_FMT_VIDEOTOOLBOX
        let rawDuration = illiquid_frame_duration(frame)
        let duration: CMTime
        if rawDuration > 0 {
            duration = MediaTime.cmTime(rawDuration, timeBase: filteredOutput.timeBase)
        } else if let rate = stream.averageFrameRate, rate > 0 {
            duration = CMTime(seconds: 1 / (rate * (filteredOutput.filtered ? 2 : 1)), preferredTimescale: 60_000)
        } else {
            duration = CMTime(value: 1, timescale: 30)
        }
        let sourcePTS = MediaTime.cmTime(
            filteredOutput.filtered ? frame.pointee.pts : illiquid_frame_best_effort_timestamp(frame),
            timeBase: filteredOutput.timeBase
        )
        let normalizedPTS = sourcePTS.isNumeric
            ? CMTimeSubtract(
                sourcePTS,
                CMTime(seconds: timelineOriginSeconds, preferredTimescale: 60_000)
            )
            : sourcePTS
        let pts: CMTime
        let beginsTimelineDiscontinuity: Bool
        if let validatedTimestamp {
            pts = validatedTimestamp
            beginsTimelineDiscontinuity = validatedDiscontinuity
        } else {
            switch timestampValidator.validate(normalizedPTS, duration: duration) {
            case let .accept(accepted, beginsDiscontinuity):
                pts = accepted
                beginsTimelineDiscontinuity = beginsDiscontinuity
            case .drop:
                throw VideoTimestampValidationError.dropFrame
            }
        }

        // Preserve codec references, deinterlacing history and timestamp
        // validation, but do not allocate/convert output that cannot be shown.
        if validatedTimestamp == nil, let floor = seekOutputFloor, floor.generation == generation,
           pts.seconds + 0.001 < floor.seconds {
            if retainsSeekPrerollFallback {
                seekPrerollFallback = try SeekPrerollFallback(output: filteredOutput,
                    generation: generation, pts: pts, discontinuity: beginsTimelineDiscontinuity)
            }
            discardedSeekPrerollFrames += 1
            softwareDecodeProgress.recordFrame()
            throw VideoTimestampValidationError.dropFrame
        }
        seekPrerollFallback = nil

        let pixelAspect = effectivePixelAspectRatio(frame)
        let cropLeft = min(Int(illiquid_frame_crop_left(frame)), Int(width))
        let cropTop = min(Int(illiquid_frame_crop_top(frame)), Int(height))
        let cropRight = min(Int(illiquid_frame_crop_right(frame)), Int(width) - cropLeft)
        let cropBottom = min(Int(illiquid_frame_crop_bottom(frame)), Int(height) - cropTop)
        let visibleWidth = max(1, Int(width) - cropLeft - cropRight)
        let visibleHeight = max(1, Int(height) - cropTop - cropBottom)
        let frameRotation = illiquid_frame_rotation_degrees(frame)
        let rotation = frameRotation.isFinite ? frameRotation : stream.rotationDegrees
        let unrotatedDisplay = CGSize(
            width: CGFloat(visibleWidth) * pixelAspect.width / max(pixelAspect.height, 1),
            height: CGFloat(visibleHeight)
        )
        let normalizedRotation = abs(rotation.truncatingRemainder(dividingBy: 180))
        let displaySize = abs(normalizedRotation - 90) < 1
            ? CGSize(width: unrotatedDisplay.height, height: unrotatedDisplay.width)
            : unrotatedDisplay
        let cleanAperture = CGRect(
            x: cropLeft,
            y: cropTop,
            width: visibleWidth,
            height: visibleHeight
        )
        let pipelineCapacityPermit: VideoFrameCapacityPermit?
        if !isHardware, let reserveSoftwareOutput {
            guard let permit = reserveSoftwareOutput() else {
                throw SoftwarePixelBufferPoolError.cancelled
            }
            pipelineCapacityPermit = permit
        } else {
            pipelineCapacityPermit = nil
        }
        let pixelBuffer: CVPixelBuffer
        var planarOwnershipToken: PlanarFrameOwnershipToken?

        if isHardware, let source = illiquid_videotoolbox_pixel_buffer(frame) {
            pixelBuffer = source.retain().takeRetainedValue()
        } else if planarFallbackGeneration != generation,
                  let planar = planarConfiguration,
                  supportsQualifiedPlanarOutput(frame)
        {
            do {
                pixelBuffer = try makePlanarPixelBuffer(
                    frame,
                    generation: generation,
                    width: Int(width),
                    height: Int(height),
                    rendererAttributes: planar.rendererAttributes,
                    while: shouldContinue
                )
                planarOwnershipToken = planarOwnershipLedger.checkout(
                    generation: generation,
                    pixelBuffer: pixelBuffer
                )
            } catch SoftwarePixelBufferPoolError.cancelled {
                throw SoftwarePixelBufferPoolError.cancelled
            } catch where planar.fallsBackToBGRA {
                retiredPlanarDiagnostics.bgraFallbacks += 1
                retirePlanarPool()
                // A conversion, renderer-compatibility, or pool failure is a
                // format-epoch decision. Do not alternate planar/BGRA frames
                // and repeatedly flush the renderer within one generation.
                planarFallbackGeneration = generation
                pixelBuffer = try makeBGRAPixelBuffer(
                    frame,
                    width: Int(width),
                    height: Int(height),
                    while: shouldContinue
                )
            }
        } else {
            if planarConfiguration != nil {
                retiredPlanarDiagnostics.bgraFallbacks += 1
            }
            pixelBuffer = try makeBGRAPixelBuffer(
                frame,
                width: Int(width),
                height: Int(height),
                while: shouldContinue
            )
        }

        applyColorMetadata(frame: frame, pixelBuffer: pixelBuffer)
        applyPixelAspectMetadata(pixelBuffer: pixelBuffer, pixelAspect: pixelAspect)
        applyCleanApertureMetadata(
            pixelBuffer: pixelBuffer,
            width: visibleWidth,
            height: visibleHeight,
            horizontalOffset: Double(cropLeft - cropRight) / 2,
            verticalOffset: Double(cropBottom - cropTop) / 2
        )

        let codedSize = CGSize(width: Int(width), height: Int(height))
        let masteringMetadata = masteringDisplayPayload(frame)
        let contentLightMetadata = contentLightPayload(frame)

        var decodedFrame = NativeDecodedVideoFrame(
            pixelBuffer: pixelBuffer,
            planarOwnershipToken: planarOwnershipToken,
            presentationTime: pts,
            duration: duration,
            generation: generation,
            codedSize: codedSize,
            displaySize: displaySize,
            pixelAspectRatio: pixelAspect,
            rotationDegrees: rotation,
            colorPrimaries: optionalColorValue(
                Int32(illiquid_frame_color_primaries(frame).rawValue)
            ),
            transferCharacteristic: optionalColorValue(
                Int32(illiquid_frame_color_transfer(frame).rawValue)
            ),
            matrixCoefficients: optionalColorValue(
                Int32(illiquid_frame_color_space(frame).rawValue)
            ),
            isFullRange: illiquid_frame_is_full_range(frame) != 0,
            hasMasteringDisplayMetadata: CVBufferCopyAttachment(
                pixelBuffer,
                kCVImageBufferMasteringDisplayColorVolumeKey,
                nil
            ) != nil,
            hasContentLightMetadata: CVBufferCopyAttachment(
                pixelBuffer,
                kCVImageBufferContentLightLevelInfoKey,
                nil
            ) != nil,
            sourceComponentDepth: Int(illiquid_frame_source_component_depth(frame)),
            ffmpegPixelFormat: pixelFormatName,
            isHardwareDecoded: isHardware || filteredOutput.copiedHardware,
            isCopiedHardwarePath: filteredOutput.copiedHardware,
            isNearZeroCopy: isHardware,
            chromaLocation: optionalColorValue(
                Int32(illiquid_frame_chroma_location(frame).rawValue)
            ),
            cleanAperture: cleanAperture,
            masteringDisplayMetadata: masteringMetadata,
            contentLightMetadata: contentLightMetadata,
            beginsTimelineDiscontinuity: beginsTimelineDiscontinuity,
            isHorizontallyMirrored: stream.isMirrored,
            usesDeinterlacingFilter: filteredOutput.filtered,
            deinterlacingFailure: deinterlacingFailure
        )
        decodedFrame.pipelineCapacityPermit = pipelineCapacityPermit
        return decodedFrame
    }

    private var planarConfiguration: (
        rendererAttributes: [String: Any],
        fallsBackToBGRA: Bool
    )? {
        switch softwareOutputMode {
        case .bgra:
            nil
        case .planarExperiment(let rendererAttributes):
            (rendererAttributes, false)
        case .planarPreferred(let rendererAttributes):
            (rendererAttributes, true)
        }
    }

    private func supportsQualifiedPlanarOutput(
        _ frame: UnsafeMutablePointer<AVFrame>
    ) -> Bool {
        Self.preferredPlanarPixelFormat(for: frame) != nil
    }

    static func preferredPlanarPixelFormat(for frame: UnsafePointer<AVFrame>) -> OSType? {
        let pixelFormat = illiquid_frame_pixel_format(frame)
        let depth = illiquid_frame_source_component_depth(frame)
        let fullRange = illiquid_frame_is_full_range(frame) != 0
        if depth <= 8 {
            guard pixelFormat == AV_PIX_FMT_YUV420P
                || pixelFormat == AV_PIX_FMT_YUVJ420P
                || pixelFormat == AV_PIX_FMT_NV12 else { return nil }
            return fullRange ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        }
        guard depth <= 10,
              pixelFormat == AV_PIX_FMT_YUV420P10LE || pixelFormat == AV_PIX_FMT_P010LE
        else { return nil }
        return fullRange ? kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
            : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
    }

    private func makePlanarPixelBuffer(
        _ frame: UnsafeMutablePointer<AVFrame>,
        generation: Int,
        width: Int,
        height: Int,
        rendererAttributes: [String: Any],
        while shouldContinue: () -> Bool
    ) throws -> CVPixelBuffer {
        guard let outputFormat = Self.preferredPlanarPixelFormat(for: frame) else {
            throw PresentationError("Source format is not supported by planar software output")
        }
        let outputPool: SoftwarePlanarOutputPool
        if let existing = softwarePlanarPixelBufferPool,
           existing.generation == generation,
           existing.width == width,
           existing.height == height,
           existing.pixelFormat == outputFormat
        {
            outputPool = existing
        } else {
            retirePlanarPool()
            outputPool = try SoftwarePlanarOutputPool(
                generation: generation,
                width: width,
                height: height,
                pixelFormat: outputFormat,
                rendererAttributes: rendererAttributes,
                ownershipLedger: planarOwnershipLedger,
                maximumBufferCount: softwarePlanarOutputMaximumBufferCount
            )
            softwarePlanarPixelBufferPool = outputPool
        }
        let created = try withNativeVideoSignpost("PlanarPixelBufferCheckout") {
            try outputPool.makePixelBuffer(while: shouldContinue)
        }
        clearPlanarMetadata(pixelBuffer: created)
        try withNativeVideoSignpost("PlanarConversion") {
            try checkFFmpeg(
                illiquid_copy_frame_to_biplanar_pixel_buffer(
                    frame,
                    created,
                    &conversionContext
                ),
                operation: "Convert software video frame to planar output"
            )
        }
        applyPlanarGeometryMetadata(frame: frame, pixelBuffer: created)
        return created
    }

    private func makeBGRAPixelBuffer(
        _ frame: UnsafeMutablePointer<AVFrame>,
        width: Int,
        height: Int,
        while shouldContinue: () -> Bool
    ) throws -> CVPixelBuffer {
        let outputPool: SoftwareBGRAOutputPool
        if let existing = softwarePixelBufferPool,
           existing.width == width, existing.height == height
        {
            outputPool = existing
        } else {
            outputPool = try SoftwareBGRAOutputPool(width: width, height: height)
            softwarePixelBufferPool = outputPool
        }
        let created = try withNativeVideoSignpost("BGRAPixelBufferCheckout") {
            try outputPool.makePixelBuffer(while: shouldContinue)
        }
        try withNativeVideoSignpost("BGRAConversion") {
            try checkFFmpeg(
                illiquid_copy_frame_to_bgra_pixel_buffer(
                    frame,
                    created,
                    &conversionContext
                ),
                operation: "Convert software video frame"
            )
        }
        return created
    }

    private func retirePlanarPool() {
        guard let pool = softwarePlanarPixelBufferPool else { return }
        accumulatePlanarDiagnostics(pool.diagnostics, into: &retiredPlanarDiagnostics)
        softwarePlanarPixelBufferPool = nil
    }

    private func combinedPlanarDiagnostics() -> SoftwarePlanarPoolDiagnostics {
        var result = retiredPlanarDiagnostics
        if let current = softwarePlanarPixelBufferPool?.diagnostics {
            accumulatePlanarDiagnostics(current, into: &result)
        }
        return result
    }

    private func accumulatePlanarDiagnostics(
        _ source: SoftwarePlanarPoolDiagnostics,
        into destination: inout SoftwarePlanarPoolDiagnostics
    ) {
        destination.checkouts += source.checkouts
        destination.uniqueBuffers += source.uniqueBuffers
        destination.reusedCheckouts += source.reusedCheckouts
        destination.bytesPerBuffer = max(
            destination.bytesPerBuffer,
            source.bytesPerBuffer
        )
        destination.maximumBufferCount = max(
            destination.maximumBufferCount,
            source.maximumBufferCount
        )
        destination.inUseUpperBound += source.inUseUpperBound
        destination.peakInUseUpperBound = max(
            destination.peakInUseUpperBound,
            source.peakInUseUpperBound
        )
        destination.freeLowerBound += source.freeLowerBound
        destination.freeNotifications += source.freeNotifications
        destination.thresholdWaits += source.thresholdWaits
        destination.timeouts += source.timeouts
        destination.cancellations += source.cancellations
        destination.bgraFallbacks += source.bgraFallbacks
    }

    private func optionalColorValue(_ value: Int32) -> Int32? {
        value > 0 ? value : nil
    }

    private func applyColorMetadata(
        frame: UnsafeMutablePointer<AVFrame>,
        pixelBuffer: CVPixelBuffer
    ) {
        let primaries = illiquid_frame_color_primaries(frame)
        let transfer = illiquid_frame_color_transfer(frame)
        let matrix = illiquid_frame_color_space(frame)

        if let value = colorPrimariesAttachment(primaries) {
            CVBufferSetAttachment(
                pixelBuffer,
                kCVImageBufferColorPrimariesKey,
                value,
                .shouldPropagate
            )
        }
        if let value = transferAttachment(transfer) {
            CVBufferSetAttachment(
                pixelBuffer,
                kCVImageBufferTransferFunctionKey,
                value,
                .shouldPropagate
            )
        }
        if CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA {
            // Source YCbCr coefficients were already applied by swscale.
            // Primaries and transfer still describe RGB; a YCbCr matrix does not.
            CVBufferRemoveAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey)
        } else if let value = matrixAttachment(matrix) {
            CVBufferSetAttachment(
                pixelBuffer,
                kCVImageBufferYCbCrMatrixKey,
                value,
                .shouldPropagate
            )
        }

        var masteringPayload = [UInt8](repeating: 0, count: 24)
        let masteringSize = illiquid_frame_mastering_display_payload(
            frame,
            &masteringPayload,
            masteringPayload.count
        )
        if masteringSize == masteringPayload.count {
            CVBufferSetAttachment(
                pixelBuffer,
                kCVImageBufferMasteringDisplayColorVolumeKey,
                Data(masteringPayload) as CFData,
                .shouldPropagate
            )
        }

        var contentLightPayload = [UInt8](repeating: 0, count: 4)
        let contentLightSize = illiquid_frame_content_light_payload(
            frame,
            &contentLightPayload,
            contentLightPayload.count
        )
        if contentLightSize == contentLightPayload.count {
            CVBufferSetAttachment(
                pixelBuffer,
                kCVImageBufferContentLightLevelInfoKey,
                Data(contentLightPayload) as CFData,
                .shouldPropagate
            )
        }
    }

    private func clearPlanarMetadata(pixelBuffer: CVPixelBuffer) {
        let keys = [
            kCVImageBufferColorPrimariesKey,
            kCVImageBufferTransferFunctionKey,
            kCVImageBufferYCbCrMatrixKey,
            kCVImageBufferChromaLocationTopFieldKey,
            kCVImageBufferChromaLocationBottomFieldKey,
            kCVImageBufferPixelAspectRatioKey,
            kCVImageBufferCleanApertureKey,
            kCVImageBufferMasteringDisplayColorVolumeKey,
            kCVImageBufferContentLightLevelInfoKey,
        ]
        for key in keys { CVBufferRemoveAttachment(pixelBuffer, key) }
    }

    private func applyPlanarGeometryMetadata(
        frame: UnsafeMutablePointer<AVFrame>,
        pixelBuffer: CVPixelBuffer
    ) {
        if let chromaLocation = chromaLocationAttachment(
            illiquid_frame_chroma_location(frame)
        ) {
            CVBufferSetAttachment(
                pixelBuffer,
                kCVImageBufferChromaLocationTopFieldKey,
                chromaLocation,
                .shouldPropagate
            )
            CVBufferSetAttachment(
                pixelBuffer,
                kCVImageBufferChromaLocationBottomFieldKey,
                chromaLocation,
                .shouldPropagate
            )
        }
        applyPixelAspectMetadata(
            pixelBuffer: pixelBuffer,
            pixelAspect: effectivePixelAspectRatio(frame)
        )
    }

    private func effectivePixelAspectRatio(
        _ frame: UnsafeMutablePointer<AVFrame>
    ) -> CGSize {
        let numerator = illiquid_frame_sample_aspect_ratio_num(frame)
        let denominator = illiquid_frame_sample_aspect_ratio_den(frame)
        if numerator > 0, denominator > 0 {
            return CGSize(width: Int(numerator), height: Int(denominator))
        }
        return stream.pixelAspectRatio ?? CGSize(width: 1, height: 1)
    }

    private func applyPixelAspectMetadata(
        pixelBuffer: CVPixelBuffer,
        pixelAspect: CGSize
    ) {
        guard pixelAspect.width.isFinite, pixelAspect.height.isFinite,
              pixelAspect.width > 0, pixelAspect.height > 0
        else {
            return
        }
        let value: [CFString: Any] = [
            kCVImageBufferPixelAspectRatioHorizontalSpacingKey: Int(pixelAspect.width.rounded()),
            kCVImageBufferPixelAspectRatioVerticalSpacingKey: Int(pixelAspect.height.rounded()),
        ]
        CVBufferSetAttachment(
            pixelBuffer,
            kCVImageBufferPixelAspectRatioKey,
            value as CFDictionary,
            .shouldPropagate
        )
    }

    private func masteringDisplayPayload(
        _ frame: UnsafeMutablePointer<AVFrame>
    ) -> Data? {
        var payload = [UInt8](repeating: 0, count: 24)
        let count = illiquid_frame_mastering_display_payload(
            frame,
            &payload,
            payload.count
        )
        return count > 0 ? Data(payload.prefix(Int(count))) : nil
    }

    private func applyCleanApertureMetadata(
        pixelBuffer: CVPixelBuffer,
        width: Int,
        height: Int,
        horizontalOffset: Double,
        verticalOffset: Double
    ) {
        let aperture: [CFString: Any] = [
            kCVImageBufferCleanApertureWidthKey: width,
            kCVImageBufferCleanApertureHeightKey: height,
            kCVImageBufferCleanApertureHorizontalOffsetKey: horizontalOffset,
            kCVImageBufferCleanApertureVerticalOffsetKey: verticalOffset,
        ]
        CVBufferSetAttachment(
            pixelBuffer,
            kCVImageBufferCleanApertureKey,
            aperture as CFDictionary,
            .shouldPropagate
        )
    }

    private func contentLightPayload(
        _ frame: UnsafeMutablePointer<AVFrame>
    ) -> Data? {
        var payload = [UInt8](repeating: 0, count: 4)
        let count = illiquid_frame_content_light_payload(
            frame,
            &payload,
            payload.count
        )
        return count > 0 ? Data(payload.prefix(Int(count))) : nil
    }

    private func chromaLocationAttachment(_ value: AVChromaLocation) -> CFString? {
        switch value {
        case AVCHROMA_LOC_LEFT: kCVImageBufferChromaLocation_Left
        case AVCHROMA_LOC_CENTER: kCVImageBufferChromaLocation_Center
        case AVCHROMA_LOC_TOPLEFT: kCVImageBufferChromaLocation_TopLeft
        case AVCHROMA_LOC_TOP: kCVImageBufferChromaLocation_Top
        case AVCHROMA_LOC_BOTTOMLEFT: kCVImageBufferChromaLocation_BottomLeft
        case AVCHROMA_LOC_BOTTOM: kCVImageBufferChromaLocation_Bottom
        default: nil
        }
    }

    private func colorPrimariesAttachment(
        _ value: AVColorPrimaries
    ) -> CFString? {
        switch value {
        case AVCOL_PRI_BT709: kCVImageBufferColorPrimaries_ITU_R_709_2
        case AVCOL_PRI_BT2020: kCVImageBufferColorPrimaries_ITU_R_2020
        case AVCOL_PRI_SMPTE170M: kCVImageBufferColorPrimaries_SMPTE_C
        default: nil
        }
    }

    private func transferAttachment(
        _ value: AVColorTransferCharacteristic
    ) -> CFString? {
        switch value {
        case AVCOL_TRC_BT709: kCVImageBufferTransferFunction_ITU_R_709_2
        case AVCOL_TRC_SMPTE2084: kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
        case AVCOL_TRC_ARIB_STD_B67: kCVImageBufferTransferFunction_ITU_R_2100_HLG
        default: nil
        }
    }

    private func matrixAttachment(_ value: AVColorSpace) -> CFString? {
        switch value {
        case AVCOL_SPC_BT709: kCVImageBufferYCbCrMatrix_ITU_R_709_2
        case AVCOL_SPC_BT2020_NCL: kCVImageBufferYCbCrMatrix_ITU_R_2020
        case AVCOL_SPC_SMPTE170M: kCVImageBufferYCbCrMatrix_ITU_R_601_4
        default: nil
        }
    }
}
