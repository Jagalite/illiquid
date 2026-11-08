import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation

struct VideoFrameProcessingSnapshot: Equatable, Sendable {
    var stageNames: [String] = []
    var inputFrames = 0
    var outputFrames = 0
    var synthesizedFrames = 0
    var overruns = 0
    var synthesisSuspended = false
    /// Why the pipeline stopped processing for this session, if it did.
    var bypassReason: String?
    var lastProcessingMilliseconds = 0.0
    /// Time spent preparing stages for the current format, including
    /// machine-learning model loading.
    var configurationMilliseconds = 0.0
    /// A stage is loading a model; frames pass through until it is ready.
    var warmingUp = false
    /// A stage that cannot do its work, e.g. a model that failed to load.
    var stageUnavailableReason: String?
}

/// Runs the configured stages between the decoder and the renderer.
///
/// Used from the video presentation thread. Each call processes one decoded
/// frame and returns the frames to present, in order. GPU work for the call
/// is complete before it returns, so the decoder's buffer and capacity
/// permit can be released as soon as the caller drops the input frame.
///
/// Failures never stop playback: the pipeline records the reason and passes
/// frames through unchanged until its configuration next changes.
///
/// The configuration can change while playing. Stages whose settings did not
/// change are kept, with their history and loaded models, and are only
/// reconfigured when their input format changes.
final class VideoFrameProcessingPipeline: @unchecked Sendable {
    /// Consecutive slow frames before generated frames are suspended.
    static let overrunLimit = 5
    /// Processing may use this share of a source frame's duration.
    static let budgetShare = 0.8

    private(set) var configuration: VideoFrameProcessingConfiguration
    private let context: VideoFrameProcessingContext
    private var stages: [any VideoFrameProcessingStage]
    /// Input and output format each stage was last configured for.
    private var configuredFormats: [ObjectIdentifier: (input: VideoProcessingFormat, output: VideoProcessingFormat)] = [:]
    /// Serializes processing. Held across GPU and VideoToolbox waits.
    private let lock = NSLock()
    /// Guards only the published counters, so observers never wait on
    /// processing.
    private let snapshotLock = NSLock()
    private var snapshotState = VideoFrameProcessingSnapshot()
    private var inputFormat: VideoProcessingFormat?
    private var outputFormat: VideoProcessingFormat?
    private var generation: Int?
    private var consecutiveOverruns = 0
    private var bypassed = false
    /// Stream metadata from the latest input, for frames emitted at end of
    /// stream. It holds a placeholder picture, never the decoder's buffer,
    /// token or permit.
    private struct MetadataTemplate {
        let frame: NativeDecodedVideoFrame
        /// Whether outputs replace the source geometry, decided against the
        /// real source buffer.
        let geometryChanged: Bool
    }
    private var lastTemplate: MetadataTemplate?
    private lazy var placeholderBuffer: CVPixelBuffer? = {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 2, 2, kCVPixelFormatType_32BGRA, nil, &buffer)
        return buffer
    }()

    init(
        configuration: VideoFrameProcessingConfiguration,
        context: VideoFrameProcessingContext? = nil,
        stages: [any VideoFrameProcessingStage]? = nil
    ) throws {
        try Self.validate(configuration)
        self.configuration = configuration
        self.context = try context ?? VideoFrameProcessingContext()
        self.stages = stages ?? Self.makeStages(for: configuration)
        snapshotState.stageNames = self.stages.map(\.name)
    }

    static func validate(_ configuration: VideoFrameProcessingConfiguration) throws {
        if let rate = configuration.frameRateConversion?.targetFrameRate,
           !VideoFrameRateConversion.supportedTargetFrameRates.contains(rate) {
            throw VideoFrameProcessingError.invalidConfiguration(
                "Target frame rate \(rate) is outside \(VideoFrameRateConversion.supportedTargetFrameRates)"
            )
        }
    }

    /// Stage order: clean up the source first (denoise, deband), then color,
    /// geometry, sharpening at output size, and frame generation last so it
    /// works on finished pictures and its RGBA conversion, when needed, never
    /// reaches the other stages.
    static func makeStages(
        for configuration: VideoFrameProcessingConfiguration,
        reusing existing: [any VideoFrameProcessingStage] = []
    ) -> [any VideoFrameProcessingStage] {
        func reuse<Stage: VideoFrameProcessingStage>(
            _ type: Stage.Type,
            where matches: (Stage) -> Bool = { _ in true }
        ) -> Stage? {
            existing.lazy.compactMap { $0 as? Stage }.first(where: matches)
        }
        var stages: [any VideoFrameProcessingStage] = []
        if configuration.filters.contains(.denoise) {
            stages.append(reuse(DenoiseStage.self) ?? DenoiseStage())
        }
        if configuration.filters.contains(.deband) {
            stages.append(reuse(DebandStage.self) ?? DebandStage())
        }
        if let adjustments = configuration.pictureAdjustments, !adjustments.isNeutral {
            if let stage = reuse(PictureAdjustmentStage.self) {
                stage.update(adjustments)
                stages.append(stage)
            } else {
                stages.append(PictureAdjustmentStage(adjustments: adjustments))
            }
        }
        if let transform = configuration.transform, !MetalTransformStage.isIdentity(transform) {
            stages.append(
                reuse(MetalTransformStage.self, where: { $0.transform == transform })
                    ?? MetalTransformStage(transform: transform)
            )
        }
        if configuration.filters.contains(.sharpen) {
            stages.append(reuse(SharpenStage.self) ?? SharpenStage())
        }
        if let conversion = configuration.frameRateConversion {
            stages.append(
                reuse(FrameRateConversionStage.self, where: { $0.conversion == conversion })
                    ?? FrameRateConversionStage(conversion: conversion)
            )
        }
        return stages
    }

    /// Applies a new configuration from the next frame on. Unchanged stages
    /// keep their state; a pipeline that fell back to pass-through tries
    /// again.
    ///
    /// Never waits for processing: callers include UI controls on the main
    /// thread, while a frame can hold the processing lock across a GPU or
    /// VideoToolbox wait. The newest pending configuration wins.
    func update(configuration: VideoFrameProcessingConfiguration) throws {
        try Self.validate(configuration)
        pendingLock.withLock { pendingConfiguration = configuration }
        // Publish the intended stages now so diagnostics reflect the change
        // even while paused.
        let names = Self.makeStages(for: configuration).map(\.name)
        updateSnapshot { $0.stageNames = names }
    }

    private let pendingLock = NSLock()
    private var pendingConfiguration: VideoFrameProcessingConfiguration?

    private func applyPendingConfigurationLocked() {
        guard let configuration = pendingLock.withLock({ () -> VideoFrameProcessingConfiguration? in
            defer { pendingConfiguration = nil }
            return pendingConfiguration
        }) else { return }
        guard configuration != self.configuration || bypassed else { return }
        self.configuration = configuration
        stages = Self.makeStages(for: configuration, reusing: stages)
        let kept = Set(stages.map { ObjectIdentifier($0) })
        configuredFormats = configuredFormats.filter { kept.contains($0.key) }
        inputFormat = nil
        outputFormat = nil
        if bypassed {
            bypassed = false
            updateSnapshot { $0.bypassReason = nil }
        }
        let names = stages.map(\.name)
        updateSnapshot { $0.stageNames = names }
    }

    var snapshot: VideoFrameProcessingSnapshot {
        snapshotLock.withLock { snapshotState }
    }

    private func updateSnapshot(_ update: (inout VideoFrameProcessingSnapshot) -> Void) {
        snapshotLock.withLock { update(&snapshotState) }
    }

    func setContinuationCheck(_ shouldContinue: @escaping () -> Bool) {
        lock.withLock { context.shouldContinue = shouldContinue }
    }

    func process(_ frame: NativeDecodedVideoFrame) -> [NativeDecodedVideoFrame] {
        lock.withLock { processLocked(frame) }
    }

    /// Test hook: waits for background model loading started by the first
    /// processed frame.
    func waitUntilReady(timeout: TimeInterval) -> Bool {
        lock.withLock { stages }.compactMap { $0 as? FrameRateConversionStage }
            .allSatisfy { $0.waitUntilReady(timeout: timeout) }
    }

    /// Drops stage history. Call on flush and seek.
    func reset() {
        lock.withLock { resetLocked() }
    }

    /// Returns frames still held at end of stream.
    func finish() -> [NativeDecodedVideoFrame] {
        lock.withLock {
            guard !bypassed, let template = lastTemplate, let outputFormat else {
                resetLocked()
                return []
            }
            var outputs: [VideoProcessingFrame] = []
            do {
                for (index, stage) in stages.enumerated() {
                    var tail: [VideoProcessingFrame] = []
                    try stage.finish(context: context) { tail.append($0) }
                    for frame in tail {
                        outputs.append(contentsOf: try run(frame, from: index + 1))
                    }
                }
                try context.synchronize()
            } catch {
                bypassLocked(reason: String(describing: error))
                return []
            }
            resetLocked()
            return outputs.map {
                template.frame.replacingPicture(
                    pixelBuffer: $0.pixelBuffer,
                    presentationTime: $0.presentationTime,
                    duration: $0.duration,
                    origin: $0.origin,
                    format: outputFormat,
                    geometryChanged: template.geometryChanged
                )
            }
        }
    }

    private func processLocked(_ frame: NativeDecodedVideoFrame) -> [NativeDecodedVideoFrame] {
        applyPendingConfigurationLocked()
        // Every stage switched off: the frame takes the unprocessed path.
        guard !stages.isEmpty else { return [frame] }
        updateSnapshot { $0.inputFrames += 1 }
        guard !bypassed else { return passThrough(frame) }
        if generation != frame.generation || frame.beginsTimelineDiscontinuity {
            resetLocked()
            generation = frame.generation
        }
        var started = ProcessInfo.processInfo.systemUptime
        do {
            let format = Self.format(of: frame)
            if format != inputFormat {
                let configurationStarted = ProcessInfo.processInfo.systemUptime
                outputFormat = try configureLocked(input: format)
                inputFormat = format
                let elapsed = (ProcessInfo.processInfo.systemUptime - configurationStarted) * 1_000
                updateSnapshot { $0.configurationMilliseconds = elapsed }
                // Model loading is a one-time cost, not a sign that frames
                // cannot keep up.
                started = ProcessInfo.processInfo.systemUptime
            }
            guard let outputFormat else { return passThrough(frame) }
            let source = VideoProcessingFrame(
                pixelBuffer: frame.pixelBuffer,
                presentationTime: frame.presentationTime,
                duration: frame.duration,
                origin: .decoded,
                isPipelineOwned: false
            )
            let outputs = try run(source, from: 0)
            try context.synchronize()
            recordTiming(since: started, sourceDuration: frame.duration.seconds)
            let warmingUp = stages.contains { $0.isWarmingUp }
            let unavailable = stages.lazy.compactMap(\.unavailableReason).first
            updateSnapshot {
                $0.outputFrames += outputs.count
                $0.warmingUp = warmingUp
                $0.stageUnavailableReason = unavailable
            }
            updateSnapshot { $0.synthesizedFrames += outputs.filter { $0.origin.isSynthesized }.count }
            if let placeholderBuffer {
                lastTemplate = MetadataTemplate(
                    frame: frame.replacingPicture(
                        pixelBuffer: placeholderBuffer,
                        presentationTime: frame.presentationTime,
                        duration: frame.duration,
                        origin: .decoded,
                        format: format,
                        geometryChanged: false
                    ),
                    geometryChanged: outputFormat != format
                )
            }
            return outputs.map { output(for: $0, template: frame, format: outputFormat) }
        } catch VideoFrameProcessingError.cancelled {
            try? context.synchronize()
            return []
        } catch {
            try? context.synchronize()
            bypassLocked(reason: String(describing: error))
            return passThrough(frame)
        }
    }

    private func run(
        _ frame: VideoProcessingFrame,
        from stageIndex: Int
    ) throws -> [VideoProcessingFrame] {
        var frames = [frame]
        for stage in stages[stageIndex...] {
            var next: [VideoProcessingFrame] = []
            for item in frames {
                try stage.process(item, context: context) { next.append($0) }
            }
            frames = next
            if frames.isEmpty { break }
        }
        return frames
    }

    private func configureLocked(input: VideoProcessingFormat) throws -> VideoProcessingFormat {
        var format = input
        for stage in stages {
            let key = ObjectIdentifier(stage)
            if let cached = configuredFormats[key], cached.input == format {
                // Same input as before: keep the stage's pools, history and
                // any loaded model.
                format = cached.output
                continue
            }
            let output = try stage.configure(input: format, context: context)
            configuredFormats[key] = (format, output)
            format = output
        }
        return format
    }

    private func resetLocked() {
        for stage in stages { stage.reset() }
        lastTemplate = nil
        consecutiveOverruns = 0
        context.allowsSynthesis = true
        updateSnapshot { $0.synthesisSuspended = false }
    }

    private func bypassLocked(reason: String) {
        configuredFormats.removeAll()
        bypassed = true
        updateSnapshot { $0.bypassReason = reason }
        lastTemplate = nil
        for stage in stages { stage.reset() }
        context.flushTextureCache()
    }

    private func passThrough(_ frame: NativeDecodedVideoFrame) -> [NativeDecodedVideoFrame] {
        updateSnapshot { $0.outputFrames += 1 }
        return [frame]
    }

    private func recordTiming(since started: TimeInterval, sourceDuration: Double) {
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        updateSnapshot { $0.lastProcessingMilliseconds = elapsed * 1_000 }
        guard sourceDuration.isFinite, sourceDuration > 0 else { return }
        if elapsed > sourceDuration * Self.budgetShare {
            consecutiveOverruns += 1
            updateSnapshot { $0.overruns += 1 }
            if consecutiveOverruns >= Self.overrunLimit, context.allowsSynthesis {
                // Falling behind real time costs more than missing frames:
                // keep showing source frames until the next seek.
                context.allowsSynthesis = false
                updateSnapshot { $0.synthesisSuspended = true }
            }
        } else {
            consecutiveOverruns = 0
        }
    }

    private func output(
        for frame: VideoProcessingFrame,
        template: NativeDecodedVideoFrame,
        format: VideoProcessingFormat
    ) -> NativeDecodedVideoFrame {
        if frame.pixelBuffer === template.pixelBuffer {
            // Unchanged decoder buffer: keep its ownership token and permit.
            return template.replacingTiming(
                presentationTime: frame.presentationTime,
                duration: frame.duration,
                origin: frame.origin
            )
        }
        return template.replacingPicture(
            pixelBuffer: frame.pixelBuffer,
            presentationTime: frame.presentationTime,
            duration: frame.duration,
            origin: frame.origin,
            format: format
        )
    }

    static func format(of frame: NativeDecodedVideoFrame) -> VideoProcessingFormat {
        let width = CVPixelBufferGetWidth(frame.pixelBuffer)
        let height = CVPixelBufferGetHeight(frame.pixelBuffer)
        return VideoProcessingFormat(
            width: width,
            height: height,
            pixelFormat: CVPixelBufferGetPixelFormatType(frame.pixelBuffer),
            cleanAperture: frame.cleanAperture
                ?? CGRect(x: 0, y: 0, width: width, height: height),
            pixelAspectRatio: frame.pixelAspectRatio.width > 0 && frame.pixelAspectRatio.height > 0
                ? frame.pixelAspectRatio
                : CGSize(width: 1, height: 1),
            rotationDegrees: frame.rotationDegrees,
            isFullRange: frame.isFullRange,
            sourceComponentDepth: frame.sourceComponentDepth
        )
    }
}

extension NativeDecodedVideoFrame {
    /// The same picture at a different time; keeps buffer ownership.
    func replacingTiming(
        presentationTime: CMTime,
        duration: CMTime,
        origin: VideoFrameOrigin
    ) -> NativeDecodedVideoFrame {
        var copy = self
        copy.presentationTime = presentationTime
        copy.duration = duration
        copy.origin = origin
        return copy
    }

    /// A pipeline-owned picture that inherits this frame's stream metadata.
    /// It carries no decoder ownership token or capacity permit.
    func replacingPicture(
        pixelBuffer: CVPixelBuffer,
        presentationTime: CMTime,
        duration: CMTime,
        origin: VideoFrameOrigin,
        format: VideoProcessingFormat,
        geometryChanged knownGeometryChange: Bool? = nil
    ) -> NativeDecodedVideoFrame {
        // Stages that keep the geometry (frame-rate conversion alone) must
        // produce frames whose metadata matches the source exactly, or every
        // generated frame would look like a format change.
        let geometryChanged = knownGeometryChange
            ?? (format != VideoFrameProcessingPipeline.format(of: self))
        return NativeDecodedVideoFrame(
            pixelBuffer: pixelBuffer,
            planarOwnershipToken: nil,
            pipelineCapacityPermit: nil,
            presentationTime: presentationTime,
            duration: duration,
            generation: generation,
            codedSize: geometryChanged ? CGSize(width: format.width, height: format.height) : codedSize,
            displaySize: geometryChanged ? format.displaySize : displaySize,
            pixelAspectRatio: geometryChanged ? format.pixelAspectRatio : pixelAspectRatio,
            rotationDegrees: rotationDegrees,
            colorPrimaries: colorPrimaries,
            transferCharacteristic: transferCharacteristic,
            matrixCoefficients: matrixCoefficients,
            isFullRange: isFullRange,
            hasMasteringDisplayMetadata: hasMasteringDisplayMetadata,
            hasContentLightMetadata: hasContentLightMetadata,
            sourceComponentDepth: sourceComponentDepth,
            ffmpegPixelFormat: ffmpegPixelFormat,
            isHardwareDecoded: isHardwareDecoded,
            isCopiedHardwarePath: isCopiedHardwarePath,
            isNearZeroCopy: false,
            chromaLocation: chromaLocation,
            cleanAperture: geometryChanged
                ? (format.hasFullAperture ? nil : format.cleanAperture)
                : cleanAperture,
            masteringDisplayMetadata: masteringDisplayMetadata,
            contentLightMetadata: contentLightMetadata,
            beginsTimelineDiscontinuity: false,
            isHorizontallyMirrored: isHorizontallyMirrored,
            usesDeinterlacingFilter: usesDeinterlacingFilter,
            deinterlacingFailure: deinterlacingFailure,
            origin: origin
        )
    }
}
