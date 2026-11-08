import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// Decides which output times fall between consecutive source frames.
///
/// Output times lie on a fixed grid anchored at the first source frame after
/// each reset, so the cadence stays uniform across source intervals. A grid
/// time that coincides with a source frame shows that frame; every other grid
/// time is synthesized. Source frames between grid times are not shown.
struct FrameRateCadencePlanner: Equatable, Sendable {
    struct SynthesizedTime: Equatable, Sendable {
        let seconds: Double
        let phase: Float
    }

    struct Plan: Equatable, Sendable {
        var synthesized: [SynthesizedTime]
        var emitsSource: Bool
        /// True when the source rate already meets the target and frames
        /// pass through unchanged.
        var isPassThrough: Bool
        /// True when this frame starts a new grid (first frame, discontinuity
        /// or pass-through).
        var reanchored: Bool
    }

    /// Gaps longer than this are timeline breaks, not slow frames.
    static let maximumGap = 0.25

    let interval: Double
    let tolerance: Double
    private(set) var anchor: Double?
    private(set) var previous: Double?

    init(targetFrameRate: Double) {
        // An unsupported rate passes every frame through rather than
        // looping over a zero or non-finite grid.
        interval = VideoFrameRateConversion.supportedTargetFrameRates.contains(targetFrameRate)
            ? 1 / targetFrameRate
            : .infinity
        // Output frames within a tenth of an output interval (capped at 2 ms)
        // of a source frame show that source frame instead of a generated one.
        tolerance = min(0.002, interval * 0.1)
    }

    mutating func reset() {
        anchor = nil
        previous = nil
    }

    /// Restarts the grid at `seconds`, which is shown as a source frame.
    mutating func reanchor(at seconds: Double) {
        anchor = seconds
        previous = seconds
    }

    mutating func plan(next seconds: Double) -> Plan {
        guard let previous, let anchor else {
            reanchor(at: seconds)
            return Plan(synthesized: [], emitsSource: true, isPassThrough: false, reanchored: true)
        }
        let gap = seconds - previous
        guard gap > 0, gap <= Self.maximumGap else {
            reanchor(at: seconds)
            return Plan(synthesized: [], emitsSource: true, isPassThrough: false, reanchored: true)
        }
        guard gap > interval * 1.01 else {
            reanchor(at: seconds)
            return Plan(synthesized: [], emitsSource: true, isPassThrough: true, reanchored: true)
        }
        var synthesized: [SynthesizedTime] = []
        var emitsSource = false
        var index = ((previous + tolerance - anchor) / interval).rounded(.down) + 1
        while true {
            let time = anchor + index * interval
            if time > seconds + tolerance { break }
            if abs(time - seconds) <= tolerance {
                emitsSource = true
            } else if time > previous + tolerance {
                let phase = Float((time - previous) / gap)
                if phase > 0, phase < 1 {
                    synthesized.append(SynthesizedTime(seconds: time, phase: phase))
                }
            }
            index += 1
        }
        self.previous = seconds
        return Plan(
            synthesized: synthesized,
            emitsSource: emitsSource,
            isPassThrough: false,
            reanchored: false
        )
    }
}

/// Generates pictures between two frames. VideoToolbox's frame-rate
/// conversion is the default; Core ML or external tools can provide others.
protocol VideoFrameInterpolator: AnyObject {
    var name: String { get }
    /// Pixel formats accepted for frames of this size; empty when the
    /// interpolator is unavailable on this Mac.
    func supportedPixelFormats(width: Int, height: Int) -> [OSType]
    /// Prepares for frames of this size and format. Throws when unsupported.
    func configure(width: Int, height: Int, pixelFormat: OSType) throws
    /// Extra attributes source and destination pools must carry.
    var sourceBufferAttributes: [String: Any] { get }
    var destinationBufferAttributes: [String: Any] { get }
    /// Fills `destinations[i]` with the picture at `phases[i]` between
    /// `previous` and `next`. Blocks until complete.
    func interpolate(
        previous: CVPixelBuffer, previousTime: CMTime,
        next: CVPixelBuffer, nextTime: CMTime,
        phases: [Float],
        destinations: [CVPixelBuffer],
        continuesPreviousCall: Bool
    ) throws
    func reset()
    /// True when starting needs model loading that must not run on the
    /// presentation thread.
    var requiresWarmUp: Bool { get }
    /// Starts sessions and runs one throwaway request so the first real
    /// frame does not pay for model loading. Runs on a background queue
    /// after `configure`; may take seconds on first use.
    func warmUp() throws
}

extension VideoFrameInterpolator {
    var requiresWarmUp: Bool { false }
    func warmUp() throws {}
}

/// Whether the selected interpolator has finished warming up. Written by the
/// warm-up queue, read by the presentation thread.
private final class InterpolatorReadiness: @unchecked Sendable {
    private let lock = NSLock()
    private var ready = false
    private var failure: String?

    var isReady: Bool { lock.withLock { ready } }
    var isStarting: Bool { lock.withLock { !ready && failure == nil } }
    var failureReason: String? { lock.withLock { failure } }

    func markReady() { lock.withLock { ready = true } }
    func markFailed(_ reason: String) { lock.withLock { failure = reason } }

    /// Test hook: blocks until warm-up finishes or the timeout passes.
    func wait(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !isStarting { return isReady }
            Thread.sleep(forTimeInterval: 0.005)
        }
        return isReady
    }
}

private final class InterpolatorBox: @unchecked Sendable {
    let interpolator: any VideoFrameInterpolator
    init(_ interpolator: any VideoFrameInterpolator) { self.interpolator = interpolator }
}

/// Inserts generated frames so playback runs on a steady output cadence.
final class FrameRateConversionStage: VideoFrameProcessingStage {
    let name = "frame-rate-conversion"
    let kind = VideoFrameProcessingStageKind.temporal
    let conversion: VideoFrameRateConversion

    static let maximumDestinationBufferCount = 24
    /// Generated frames per source interval. Longer gaps show the source
    /// instead, so one batch can never fill the destination pool by itself.
    static let maximumSynthesizedPerInterval = 8
    /// Destinations come back as the renderer displays or flushes them. If
    /// none return in this time, the source frame is shown instead.
    static let destinationAllocationTimeout: TimeInterval = 1
    /// Shorter end-of-stream remainders are rounding, not a picture to show.
    static let minimumTailSeconds = 0.0001
    /// Previous and current copies, plus one in flight. Only this stage
    /// releases them, so allocation fails fast instead of waiting.
    static let historyBufferCount = 4
    static let historyAllocationTimeout: TimeInterval = 0.05

    /// Candidates in preference order; `configure` picks the first that
    /// accepts the input directly, then the first that accepts RGBA.
    /// Factories, so every configuration gets fresh instances: a warm-up
    /// still running for an earlier format never shares state with the new
    /// one.
    private let candidates: [() -> any VideoFrameInterpolator]
    private var interpolator: (any VideoFrameInterpolator)?
    private var readiness: InterpolatorReadiness?
    private var converter: MetalRGBAConverter?
    private var planner: FrameRateCadencePlanner
    private var historyPool: VideoProcessingBufferPool?
    private var destinationPool: VideoProcessingBufferPool?
    private var history: VideoProcessingFrame?
    /// End of the latest emitted frame and of the latest source frame, for
    /// completing the source's duration at end of stream.
    private var lastOutputEnd: Double?
    private var lastSourceEnd: Double?
    private var lastPairWasInterpolated = false
    private var interpolatedSinceReset = false
    private(set) var interpolationFailures = 0

    init(
        conversion: VideoFrameRateConversion,
        interpolators: [any VideoFrameInterpolator]? = nil
    ) {
        self.conversion = conversion
        if let interpolators {
            candidates = interpolators.map { instance in { instance } }
        } else {
            let quality = conversion.quality
            let lowLatency: () -> any VideoFrameInterpolator = { VideoToolboxLowLatencyInterpolator() }
            let full: () -> any VideoFrameInterpolator = { VideoToolboxFrameInterpolator(quality: quality) }
            candidates = quality == .high ? [full, lowLatency] : [lowLatency, full]
        }
        planner = FrameRateCadencePlanner(targetFrameRate: conversion.targetFrameRate)
    }

    convenience init(conversion: VideoFrameRateConversion, interpolator: any VideoFrameInterpolator) {
        self.init(conversion: conversion, interpolators: [interpolator])
    }

    // Default order: low-latency interpolation runs on 8-bit 4:2:0 directly
    // and suits real-time playback. Full frame-rate conversion needs RGBA
    // input but has a quality mode, so it leads when quality is requested.

    /// The interpolator chosen for the current format, for diagnostics.
    var selectedInterpolatorName: String? { interpolator?.name }
    var convertsToRGBA: Bool { converter != nil }
    var isWarmingUp: Bool { readiness?.isStarting ?? false }
    var unavailableReason: String? { readiness?.failureReason }

    /// Test hook: waits for the current warm-up to finish.
    func waitUntilReady(timeout: TimeInterval) -> Bool {
        readiness?.wait(timeout: timeout) ?? false
    }

    func configure(
        input: VideoProcessingFormat,
        context: VideoFrameProcessingContext
    ) throws -> VideoProcessingFormat {
        interpolator = nil
        converter = nil
        readiness = nil
        let candidates = candidates.map { $0() }
        let direct = candidates.first {
            $0.supportedPixelFormats(width: input.width, height: input.height).contains(input.pixelFormat)
        }
        let selected: any VideoFrameInterpolator
        let workingFormat: OSType
        if let direct {
            selected = direct
            workingFormat = input.pixelFormat
        } else if MetalRGBAConverter.canConvert(input.pixelFormat),
                  let rgba = candidates.first(where: {
                      $0.supportedPixelFormats(width: input.width, height: input.height)
                          .contains(MetalRGBAConverter.outputPixelFormat)
                  }) {
            selected = rgba
            workingFormat = MetalRGBAConverter.outputPixelFormat
        } else {
            let names = candidates.map(\.name).joined(separator: ", ")
            throw VideoFrameProcessingError.processorUnavailable(
                "No interpolator (\(names)) accepts \(VideoProcessingPlaneLayout.fourCC(input.pixelFormat))"
            )
        }
        try selected.configure(width: input.width, height: input.height, pixelFormat: workingFormat)
        if workingFormat != input.pixelFormat {
            _ = try context.computePipeline(named: input.pixelFormat == kCVPixelFormatType_32BGRA
                ? "video_bgra_to_rgba" : "video_ycbcr_to_rgba")
            converter = try MetalRGBAConverter(
                width: input.width,
                height: input.height,
                maximumBufferCount: Self.maximumDestinationBufferCount,
                additionalAttributes: selected.sourceBufferAttributes
            )
        }
        historyPool = try VideoProcessingBufferPool(
            width: input.width,
            height: input.height,
            pixelFormat: workingFormat,
            maximumBufferCount: Self.historyBufferCount,
            additionalAttributes: selected.sourceBufferAttributes
        )
        destinationPool = try VideoProcessingBufferPool(
            width: input.width,
            height: input.height,
            pixelFormat: workingFormat,
            maximumBufferCount: Self.maximumDestinationBufferCount,
            additionalAttributes: selected.destinationBufferAttributes
        )
        interpolator = selected
        // Model loading can take seconds the first time. Doing it here would
        // hold up preroll and can make opening the file time out, so it runs
        // in the background; until it finishes, source frames pass through
        // in the same pixel format and no frames are generated.
        let readiness = InterpolatorReadiness()
        self.readiness = readiness
        if selected.requiresWarmUp {
            let box = InterpolatorBox(selected)
            let label = "\(selected.name) at \(input.width)x\(input.height)"
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try box.interpolator.warmUp()
                    readiness.markReady()
                } catch {
                    // For example, low-latency interpolation reports success
                    // when its session starts above 1280x720 on some Macs,
                    // then fails every request.
                    readiness.markFailed("\(label): \(error)")
                }
            }
        } else {
            readiness.markReady()
        }
        reset()
        var output = input
        output.pixelFormat = workingFormat
        return output
    }

    func process(
        _ input: VideoProcessingFrame,
        context: VideoFrameProcessingContext,
        emit: (VideoProcessingFrame) -> Void
    ) throws {
        var frame = input
        if let converter {
            // Every frame converts, not only interpolated pairs, so the
            // renderer sees one pixel format for the whole session.
            frame.pixelBuffer = try converter.convert(input.pixelBuffer, context: context)
            frame.isPipelineOwned = true
            if frame.origin == .decoded { frame.origin = .processed }
        }
        let seconds = frame.presentationTime.seconds
        var plan = planner.plan(next: seconds)
        let previous = history

        // Keep a pipeline-owned copy while interpolating so the decoder's
        // buffer returns to it as soon as the frame is presented.
        let keepsHistory = !plan.isPassThrough || lastPairWasInterpolated
        var current: VideoProcessingFrame?
        if keepsHistory {
            do {
                current = try retainedCopy(of: frame, context: context)
            } catch VideoFrameProcessingError.cancelled {
                throw VideoFrameProcessingError.cancelled
            } catch {
                // No copy means no interpolation into this frame; the
                // source is still shown below.
                interpolationFailures += 1
                current = nil
            }
        }

        var synthesized: [VideoProcessingFrame] = []
        if !plan.synthesized.isEmpty {
            if context.allowsSynthesis, readiness?.isReady == true, let previous, let current {
                do {
                    synthesized = try interpolate(
                        previous: previous, next: current, plan: plan, context: context
                    )
                } catch let error as VideoFrameProcessingError where error == .cancelled {
                    throw error
                } catch {
                    interpolationFailures += 1
                    synthesized = []
                }
            }
            if synthesized.isEmpty {
                // Without generated frames the grid has a hole; show the
                // source and restart the grid from it.
                planner.reanchor(at: seconds)
                plan = FrameRateCadencePlanner.Plan(
                    synthesized: [], emitsSource: true, isPassThrough: false, reanchored: true
                )
            }
        }

        // Nothing may outlast this source frame: the next source, or end of
        // stream, takes over from its end.
        let sourceEnd = seconds + input.duration.seconds
        func send(_ output: VideoProcessingFrame) {
            var output = output
            let start = output.presentationTime.seconds
            if sourceEnd.isFinite, sourceEnd > start,
               start + output.duration.seconds > sourceEnd {
                output.duration = CMTime(seconds: sourceEnd - start, preferredTimescale: 600_000)
            }
            lastOutputEnd = start + output.duration.seconds
            emit(output)
        }
        synthesized.forEach(send)
        if plan.emitsSource {
            var shown = frame
            // On the grid every frame lasts one output interval, so a source
            // frame never overlaps the generated frame after it.
            if !plan.isPassThrough {
                shown.duration = CMTime(seconds: planner.interval, preferredTimescale: 600_000)
            }
            send(shown)
        }

        lastPairWasInterpolated = !synthesized.isEmpty || (!plan.isPassThrough && !plan.reanchored)
        lastSourceEnd = sourceEnd.isFinite ? sourceEnd : nil
        // Hold the pipeline-owned copy, never the decoder's buffer.
        history = current
    }

    func reset() {
        planner.reset()
        history = nil
        lastOutputEnd = nil
        lastSourceEnd = nil
        lastPairWasInterpolated = false
        interpolatedSinceReset = false
        interpolator?.reset()
    }

    func finish(
        context: VideoFrameProcessingContext,
        emit: (VideoProcessingFrame) -> Void
    ) throws {
        // Output frames last one grid interval, so the final source frame's
        // time runs past the last output. Show the final picture from the
        // last output's end to the source's end: it is either an off-grid
        // source never shown, or an on-grid one whose duration was shortened.
        if let history, let lastOutputEnd, let lastSourceEnd,
           lastSourceEnd - lastOutputEnd > Self.minimumTailSeconds {
            var tail = history
            tail.presentationTime = CMTime(seconds: lastOutputEnd, preferredTimescale: 600_000)
            tail.duration = CMTime(seconds: lastSourceEnd - lastOutputEnd, preferredTimescale: 600_000)
            emit(tail)
        }
        reset()
    }

    /// Returns a frame whose buffer the interpolator may read.
    ///
    /// VideoToolbox's interpolators require buffers created with their
    /// source attributes, which include padding beyond the visible picture
    /// (`ExtendedPixelsRight`/`Bottom`). Handing them any other buffer, even
    /// another stage's IOSurface output, lets them write past its end and
    /// corrupts memory. Only the RGBA converter's pool and this stage's
    /// history pool carry those attributes, so everything else is copied.
    private func retainedCopy(
        of frame: VideoProcessingFrame,
        context: VideoFrameProcessingContext
    ) throws -> VideoProcessingFrame {
        if converter != nil { return frame }
        guard let historyPool else {
            throw VideoFrameProcessingError.invalidConfiguration("Frame-rate stage is not configured")
        }
        var copy = frame
        copy.pixelBuffer = try context.copy(
            frame.pixelBuffer, using: historyPool, timeout: Self.historyAllocationTimeout
        )
        copy.isPipelineOwned = true
        return copy
    }

    private func interpolate(
        previous: VideoProcessingFrame,
        next: VideoProcessingFrame,
        plan: FrameRateCadencePlanner.Plan,
        context: VideoFrameProcessingContext
    ) throws -> [VideoProcessingFrame] {
        guard let destinationPool, let interpolator else {
            throw VideoFrameProcessingError.invalidConfiguration("Frame-rate stage is not configured")
        }
        guard plan.synthesized.count <= Self.maximumSynthesizedPerInterval else {
            throw VideoFrameProcessingError.processorFailed(
                "\(plan.synthesized.count) frames exceed the per-interval limit"
            )
        }
        let destinations = try plan.synthesized.map { _ in
            try destinationPool.makeBuffer(
                while: context.shouldContinue, timeout: Self.destinationAllocationTimeout
            )
        }
        // Earlier GPU copies and transforms must land before VideoToolbox
        // reads the buffers.
        try context.synchronize()
        try interpolator.interpolate(
            previous: previous.pixelBuffer, previousTime: previous.presentationTime,
            next: next.pixelBuffer, nextTime: next.presentationTime,
            phases: plan.synthesized.map(\.phase),
            destinations: destinations,
            continuesPreviousCall: interpolatedSinceReset && lastPairWasInterpolated
        )
        interpolatedSinceReset = true
        let duration = CMTime(seconds: planner.interval, preferredTimescale: 600_000)
        return zip(plan.synthesized, destinations).map { time, buffer in
            CVBufferPropagateAttachments(next.pixelBuffer, buffer)
            return VideoProcessingFrame(
                pixelBuffer: buffer,
                presentationTime: CMTime(seconds: time.seconds, preferredTimescale: 600_000),
                duration: duration,
                origin: .synthesized(
                    previousSeconds: previous.presentationTime.seconds,
                    nextSeconds: next.presentationTime.seconds,
                    phase: time.phase
                ),
                isPipelineOwned: true
            )
        }
    }
}

/// VideoToolbox's machine-learning frame-rate conversion.
final class VideoToolboxFrameInterpolator: VideoFrameInterpolator {
    let name = "vt-frame-rate-conversion"

    private let quality: VideoFrameRateConversion.Quality
    private var processor: VTFrameProcessor?
    private var configuration: VTFrameRateConversionConfiguration?
    private var width = 0
    private var height = 0
    private var pixelFormat: OSType = 0

    init(quality: VideoFrameRateConversion.Quality) {
        self.quality = quality
    }

    deinit { processor?.endSession() }

    static var isSupported: Bool { VTFrameRateConversionConfiguration.isSupported }

    func supportedPixelFormats(width: Int, height: Int) -> [OSType] {
        guard Self.isSupported else { return [] }
        return VTFrameRateConversionConfiguration(
            frameWidth: width,
            frameHeight: height,
            usePrecomputedFlow: false,
            qualityPrioritization: quality == .high ? .quality : .normal,
            revision: VTFrameRateConversionConfiguration.defaultRevision
        )?.supportedPixelFormats ?? []
    }

    var sourceBufferAttributes: [String: Any] {
        configuration.map { $0.sourcePixelBufferAttributes as [String: Any] } ?? [:]
    }

    var destinationBufferAttributes: [String: Any] {
        configuration.map { $0.destinationPixelBufferAttributes as [String: Any] } ?? [:]
    }

    func configure(width: Int, height: Int, pixelFormat: OSType) throws {
        processor?.endSession()
        processor = nil
        configuration = nil
        guard Self.isSupported else {
            throw VideoFrameProcessingError.processorUnavailable(
                "VideoToolbox frame-rate conversion is not supported on this Mac"
            )
        }
        guard let configuration = VTFrameRateConversionConfiguration(
            frameWidth: width,
            frameHeight: height,
            usePrecomputedFlow: false,
            qualityPrioritization: quality == .high ? .quality : .normal,
            revision: VTFrameRateConversionConfiguration.defaultRevision
        ) else {
            throw VideoFrameProcessingError.processorUnavailable(
                "VideoToolbox rejected \(width)x\(height) frames"
            )
        }
        guard configuration.supportedPixelFormats.contains(pixelFormat) else {
            throw VideoFrameProcessingError.unsupportedPixelFormat(pixelFormat)
        }
        // The session starts in warmUp(), off the presentation thread.
        self.configuration = configuration
        self.width = width
        self.height = height
        self.pixelFormat = pixelFormat
    }

    var requiresWarmUp: Bool { true }

    func warmUp() throws {
        let (previous, next, destination) = try InterpolatorWarmUp.buffers(
            width: width, height: height, pixelFormat: pixelFormat,
            source: sourceBufferAttributes, destination: destinationBufferAttributes
        )
        try perform(
            previous: previous, previousTime: .zero,
            next: next, nextTime: CMTime(value: 1, timescale: 24),
            phases: [0.5], destinations: [destination],
            continuesPreviousCall: false, timeout: InterpolatorWarmUp.timeout
        )
    }

    func interpolate(
        previous: CVPixelBuffer, previousTime: CMTime,
        next: CVPixelBuffer, nextTime: CMTime,
        phases: [Float],
        destinations: [CVPixelBuffer],
        continuesPreviousCall: Bool
    ) throws {
        try perform(
            previous: previous, previousTime: previousTime, next: next, nextTime: nextTime,
            phases: phases, destinations: destinations,
            continuesPreviousCall: continuesPreviousCall, timeout: InterpolationCompletion.timeout
        )
    }

    private func perform(
        previous: CVPixelBuffer, previousTime: CMTime,
        next: CVPixelBuffer, nextTime: CMTime,
        phases: [Float],
        destinations: [CVPixelBuffer],
        continuesPreviousCall: Bool,
        timeout: DispatchTimeInterval
    ) throws {
        let processor = try activeProcessor()
        guard let source = VTFrameProcessorFrame(buffer: previous, presentationTimeStamp: previousTime),
              let following = VTFrameProcessorFrame(buffer: next, presentationTimeStamp: nextTime)
        else {
            throw VideoFrameProcessingError.processorFailed("Source frame was rejected")
        }
        let outputs = try zip(phases, destinations).map { phase, buffer in
            let time = CMTimeAdd(
                previousTime,
                CMTimeMultiplyByFloat64(CMTimeSubtract(nextTime, previousTime), multiplier: Float64(phase))
            )
            guard let frame = VTFrameProcessorFrame(buffer: buffer, presentationTimeStamp: time) else {
                throw VideoFrameProcessingError.processorFailed("Destination frame was rejected")
            }
            return frame
        }
        guard let parameters = VTFrameRateConversionParameters(
            sourceFrame: source,
            nextFrame: following,
            opticalFlow: nil,
            interpolationPhase: phases,
            submissionMode: continuesPreviousCall ? .sequential : .random,
            destinationFrames: outputs
        ) else {
            throw VideoFrameProcessingError.processorFailed("Parameters were rejected")
        }
        do {
            try InterpolationCompletion.run(
                processor: processor, parameters: parameters,
                retaining: [previous, next] + destinations, timeout: timeout
            )
        } catch VideoFrameProcessingError.processorTimedOut {
            // The late request may still be running: never submit to this
            // session again. A new one starts on the next call.
            self.processor = nil
            throw VideoFrameProcessingError.processorTimedOut
        }
    }

    private func activeProcessor() throws -> VTFrameProcessor {
        if let processor { return processor }
        guard let configuration else {
            throw VideoFrameProcessingError.processorUnavailable("Session not started")
        }
        let processor = VTFrameProcessor()
        do {
            try processor.startSession(configuration: configuration)
        } catch {
            throw VideoFrameProcessingError.processorUnavailable(String(describing: error))
        }
        self.processor = processor
        return processor
    }

    func reset() {}
}

/// VideoToolbox's low-latency interpolation. It generates pictures only at
/// k/2^n between two frames, so requested phases snap to the nearest such
/// point: one point (0.5) when every phase is the midpoint, otherwise eighths.
/// Presentation times stay on the exact output grid; at most the picture
/// content is 1/16 of a source interval away from its timestamp.
final class VideoToolboxLowLatencyInterpolator: VideoFrameInterpolator {
    let name = "vt-low-latency-interpolation"
    static let fineSubdivisionExponent = 3

    private var width = 0
    private var height = 0
    private var pixelFormat: OSType = 0
    /// Describes buffer requirements without starting a session.
    private var attributeConfiguration: VTLowLatencyFrameInterpolationConfiguration?
    private var sessions: [Int: (VTFrameProcessor, VTLowLatencyFrameInterpolationConfiguration)] = [:]

    deinit { endSessions() }

    static var isSupported: Bool { VTLowLatencyFrameInterpolationConfiguration.isSupported }

    var sourceBufferAttributes: [String: Any] {
        attributeConfiguration.map { $0.sourcePixelBufferAttributes as [String: Any] } ?? [:]
    }

    var destinationBufferAttributes: [String: Any] {
        attributeConfiguration.map { $0.destinationPixelBufferAttributes as [String: Any] } ?? [:]
    }

    func supportedPixelFormats(width: Int, height: Int) -> [OSType] {
        guard Self.isSupported else { return [] }
        return VTLowLatencyFrameInterpolationConfiguration(
            frameWidth: width, frameHeight: height, numberOfInterpolatedFrames: 1
        )?.supportedPixelFormats ?? []
    }

    func configure(width: Int, height: Int, pixelFormat: OSType) throws {
        endSessions()
        guard supportedPixelFormats(width: width, height: height).contains(pixelFormat) else {
            throw VideoFrameProcessingError.unsupportedPixelFormat(pixelFormat)
        }
        self.width = width
        self.height = height
        self.pixelFormat = pixelFormat
        attributeConfiguration = VTLowLatencyFrameInterpolationConfiguration(
            frameWidth: width, frameHeight: height, numberOfInterpolatedFrames: 1
        )
    }

    var requiresWarmUp: Bool { true }

    /// Loads both sessions (midpoint and eighths) and runs one request on
    /// each, so neither model loads during playback.
    func warmUp() throws {
        let (previous, next, destination) = try InterpolatorWarmUp.buffers(
            width: width, height: height, pixelFormat: pixelFormat,
            source: sourceBufferAttributes, destination: destinationBufferAttributes
        )
        for phase: Float in [0.5, 0.375] {
            try perform(
                previous: previous, previousTime: .zero,
                next: next, nextTime: CMTime(value: 1, timescale: 24),
                phases: [phase], destinations: [destination],
                timeout: InterpolatorWarmUp.timeout
            )
        }
    }

    /// Snaps each phase to the nearest of 2^n - 1 interior points.
    static func snappedPhases(_ phases: [Float]) -> (exponent: Int, phases: [Float]) {
        if phases.allSatisfy({ abs($0 - 0.5) < 0.001 }) {
            return (1, phases.map { _ in 0.5 })
        }
        let exponent = fineSubdivisionExponent
        let steps = Float(1 << exponent)
        let snapped = phases.map { phase in
            min(max((phase * steps).rounded(), 1), steps - 1) / steps
        }
        return (exponent, snapped)
    }

    func interpolate(
        previous: CVPixelBuffer, previousTime: CMTime,
        next: CVPixelBuffer, nextTime: CMTime,
        phases: [Float],
        destinations: [CVPixelBuffer],
        continuesPreviousCall: Bool
    ) throws {
        try perform(
            previous: previous, previousTime: previousTime, next: next, nextTime: nextTime,
            phases: phases, destinations: destinations, timeout: InterpolationCompletion.timeout
        )
    }

    private func perform(
        previous: CVPixelBuffer, previousTime: CMTime,
        next: CVPixelBuffer, nextTime: CMTime,
        phases: [Float],
        destinations: [CVPixelBuffer],
        timeout: DispatchTimeInterval
    ) throws {
        let (exponent, snapped) = Self.snappedPhases(phases)
        let (processor, _) = try session(exponent: exponent)
        guard let earlier = VTFrameProcessorFrame(buffer: previous, presentationTimeStamp: previousTime),
              let current = VTFrameProcessorFrame(buffer: next, presentationTimeStamp: nextTime)
        else {
            throw VideoFrameProcessingError.processorFailed("Source frame was rejected")
        }
        let outputs = try zip(snapped, destinations).map { phase, buffer in
            let time = CMTimeAdd(
                previousTime,
                CMTimeMultiplyByFloat64(CMTimeSubtract(nextTime, previousTime), multiplier: Float64(phase))
            )
            guard let frame = VTFrameProcessorFrame(buffer: buffer, presentationTimeStamp: time) else {
                throw VideoFrameProcessingError.processorFailed("Destination frame was rejected")
            }
            return frame
        }
        guard let parameters = VTLowLatencyFrameInterpolationParameters(
            sourceFrame: current,
            previousFrame: earlier,
            interpolationPhase: snapped,
            destinationFrames: outputs
        ) else {
            throw VideoFrameProcessingError.processorFailed("Parameters were rejected")
        }
        do {
            try InterpolationCompletion.run(
                processor: processor, parameters: parameters,
                retaining: [previous, next] + destinations, timeout: timeout
            )
        } catch VideoFrameProcessingError.processorTimedOut {
            // Retire the session; the next call starts a fresh one.
            sessions[exponent] = nil
            throw VideoFrameProcessingError.processorTimedOut
        }
    }

    func reset() {}

    private func session(
        exponent: Int
    ) throws -> (VTFrameProcessor, VTLowLatencyFrameInterpolationConfiguration) {
        if let existing = sessions[exponent] { return existing }
        guard let configuration = VTLowLatencyFrameInterpolationConfiguration(
            frameWidth: width, frameHeight: height, numberOfInterpolatedFrames: exponent
        ) else {
            throw VideoFrameProcessingError.processorUnavailable(
                "VideoToolbox rejected \(width)x\(height) low-latency interpolation"
            )
        }
        let processor = VTFrameProcessor()
        do {
            try processor.startSession(configuration: configuration)
        } catch {
            throw VideoFrameProcessingError.processorUnavailable(String(describing: error))
        }
        sessions[exponent] = (processor, configuration)
        return (processor, configuration)
    }

    private func endSessions() {
        for (processor, _) in sessions.values { processor.endSession() }
        sessions.removeAll()
    }
}

/// Throwaway buffers for warming up a VideoToolbox session.
enum InterpolatorWarmUp {
    /// First use compiles the model; allow far longer than a playback frame.
    static let timeout: DispatchTimeInterval = .seconds(20)

    static func buffers(
        width: Int, height: Int, pixelFormat: OSType,
        source: [String: Any], destination: [String: Any]
    ) throws -> (CVPixelBuffer, CVPixelBuffer, CVPixelBuffer) {
        let sources = try VideoProcessingBufferPool(
            width: width, height: height, pixelFormat: pixelFormat,
            maximumBufferCount: 2, additionalAttributes: source
        )
        let destinations = try VideoProcessingBufferPool(
            width: width, height: height, pixelFormat: pixelFormat,
            maximumBufferCount: 1, additionalAttributes: destination
        )
        return (
            try sources.makeBuffer(timeout: 1),
            try sources.makeBuffer(timeout: 1),
            try destinations.makeBuffer(timeout: 1)
        )
    }
}

private final class RetainedBuffers: @unchecked Sendable {
    let buffers: [CVPixelBuffer]
    init(_ buffers: [CVPixelBuffer]) { self.buffers = buffers }
}

private final class InterpolationCompletion: @unchecked Sendable {
    static let timeout: DispatchTimeInterval = .milliseconds(500)

    /// Submits `parameters` and blocks the presentation thread until
    /// VideoToolbox finishes or the timeout passes.
    ///
    /// `retaining` stays alive until VideoToolbox reports completion, even
    /// after a timeout, so a late request never writes into a buffer that
    /// has gone back to its pool and been reused.
    static func run(
        processor: VTFrameProcessor,
        parameters: any VTFrameProcessorParameters,
        retaining buffers: [CVPixelBuffer],
        timeout: DispatchTimeInterval
    ) throws {
        let completion = InterpolationCompletion()
        let retained = RetainedBuffers(buffers)
        processor.process(parameters: parameters) { _, error in
            withExtendedLifetime(retained) {
                completion.finish(error.map { String(describing: $0) })
            }
        }
        guard let result = completion.wait(timeout: .now() + timeout) else {
            throw VideoFrameProcessingError.processorTimedOut
        }
        if let failure = result.failure {
            throw VideoFrameProcessingError.processorFailed(failure)
        }
    }

    struct Result { let failure: String? }

    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var result: Result?

    func finish(_ failure: String?) {
        lock.lock()
        result = Result(failure: failure)
        lock.unlock()
        semaphore.signal()
    }

    func wait(timeout: DispatchTime) -> Result? {
        guard semaphore.wait(timeout: timeout) == .success else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return result
    }
}
