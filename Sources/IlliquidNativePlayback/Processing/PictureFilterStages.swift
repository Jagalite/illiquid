import CoreMedia
import CoreVideo
import Foundation
import IlliquidCore
import Metal

/// Which kernel runs on each plane of a supported layout.
struct PlaneKernels {
    /// Luma of bi-planar 4:2:0.
    var luma: String?
    /// Interleaved CbCr of bi-planar 4:2:0. Nil copies the plane unchanged.
    var chroma: String?
    /// The single plane of BGRA or RGBA half-float.
    var rgb: String
}

/// Shared plumbing for filters that read one frame and write a same-size
/// frame plane by plane.
final class PlaneFilterRunner {
    static let maximumBufferCount = 24

    private(set) var layout: VideoProcessingPlaneLayout?
    private(set) var pixelFormat: OSType = 0
    private var pool: VideoProcessingBufferPool?

    var isPlanar: Bool { (layout?.planes.count ?? 0) > 1 }

    func configure(input: VideoProcessingFormat, kernels: PlaneKernels, context: VideoFrameProcessingContext) throws {
        guard let layout = VideoProcessingPlaneLayout.layout(for: input.pixelFormat) else {
            throw VideoFrameProcessingError.unsupportedPixelFormat(input.pixelFormat)
        }
        for name in [kernels.luma, kernels.chroma, kernels.rgb].compactMap({ $0 }) {
            _ = try context.computePipeline(named: name)
        }
        if pool?.matches(width: input.width, height: input.height, pixelFormat: input.pixelFormat) != true {
            pool = try VideoProcessingBufferPool(
                width: input.width, height: input.height, pixelFormat: input.pixelFormat,
                maximumBufferCount: Self.maximumBufferCount
            )
        }
        self.layout = layout
        pixelFormat = input.pixelFormat
    }

    /// Encodes the filter and returns the destination buffer. `uniforms`
    /// supplies each plane's bytes (plane index, is chroma).
    func run(
        _ source: CVPixelBuffer,
        kernels: PlaneKernels,
        history: CVPixelBuffer? = nil,
        context: VideoFrameProcessingContext,
        uniforms: (_ plane: Int, _ isChroma: Bool) -> [UInt8]
    ) throws -> CVPixelBuffer {
        guard let layout, let pool else {
            throw VideoFrameProcessingError.invalidConfiguration("Filter is not configured")
        }
        let destination = try pool.makeBuffer(while: context.shouldContinue)
        struct PlaneWork {
            let kernel: String?
            let input: any MTLTexture
            let output: any MTLTexture
            let history: (any MTLTexture)?
            let bytes: [UInt8]
        }
        // Resolve everything that can throw before any encoder opens.
        let work: [PlaneWork] = try layout.planes.enumerated().map { index, plane in
            let isChroma = layout.planes.count > 1 && index == 1
            let kernel = layout.planes.count == 1 ? kernels.rgb : (isChroma ? kernels.chroma : kernels.luma)
            return PlaneWork(
                kernel: kernel,
                input: try context.texture(
                    for: source, plane: index, pixelFormat: plane.pixelFormat, usage: .shaderRead
                ),
                output: try context.texture(
                    for: destination, plane: index, pixelFormat: plane.pixelFormat, usage: .shaderWrite
                ),
                history: try history.map {
                    try context.texture(for: $0, plane: index, pixelFormat: plane.pixelFormat, usage: .shaderRead)
                },
                bytes: uniforms(index, isChroma)
            )
        }
        let pipelines = try work.map { try $0.kernel.map { try context.computePipeline(named: $0) } }
        let commandBuffer = try context.commandBuffer()
        if work.contains(where: { $0.kernel != nil }) {
            guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
                throw VideoFrameProcessingError.commandBufferFailed("Compute encoder unavailable")
            }
            for (item, pipeline) in zip(work, pipelines) {
                guard let pipeline else { continue }
                encoder.setComputePipelineState(pipeline)
                encoder.setTexture(item.input, index: 0)
                encoder.setTexture(item.output, index: 1)
                // Kernels that take history always get a texture; without
                // history they ignore it.
                encoder.setTexture(item.history ?? item.input, index: 2)
                item.bytes.withUnsafeBytes { bytes in
                    encoder.setBytes(bytes.baseAddress!, length: bytes.count, index: 0)
                }
                let width = pipeline.threadExecutionWidth
                let height = max(1, pipeline.maxTotalThreadsPerThreadgroup / width)
                encoder.dispatchThreads(
                    MTLSize(width: item.output.width, height: item.output.height, depth: 1),
                    threadsPerThreadgroup: MTLSize(width: width, height: height, depth: 1)
                )
            }
            encoder.endEncoding()
        }
        let copies = zip(work, pipelines).filter { $0.1 == nil }.map(\.0)
        if !copies.isEmpty {
            guard let blit = commandBuffer.makeBlitCommandEncoder() else {
                throw VideoFrameProcessingError.commandBufferFailed("Blit encoder unavailable")
            }
            for item in copies {
                blit.copy(
                    from: item.input, sourceSlice: 0, sourceLevel: 0,
                    sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                    sourceSize: MTLSize(width: item.output.width, height: item.output.height, depth: 1),
                    to: item.output, destinationSlice: 0, destinationLevel: 0,
                    destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
                )
            }
            blit.endEncoding()
        }
        CVBufferPropagateAttachments(source, destination)
        return destination
    }
}

func uniformBytes<T>(_ value: T) -> [UInt8] {
    withUnsafeBytes(of: value) { Array($0) }
}

/// Brightness, contrast, saturation, gamma and hue, each -100...100 with 0
/// meaning unchanged, as in mpv and the app's equalizer.
public struct VideoPictureAdjustments: Equatable, Sendable {
    public var brightness: Double
    public var contrast: Double
    public var saturation: Double
    public var gamma: Double
    public var hue: Double

    public init(brightness: Double = 0, contrast: Double = 0, saturation: Double = 0, gamma: Double = 0, hue: Double = 0) {
        self.brightness = brightness
        self.contrast = contrast
        self.saturation = saturation
        self.gamma = gamma
        self.hue = hue
    }

    public init(_ state: VideoAdjustmentState) {
        self.init(brightness: state.brightness, contrast: state.contrast,
                  saturation: state.saturation, gamma: state.gamma, hue: state.hue)
    }

    public var isNeutral: Bool {
        brightness == 0 && contrast == 0 && saturation == 0 && gamma == 0 && hue == 0
    }

    func clamped() -> VideoPictureAdjustments {
        func clamp(_ value: Double) -> Double { value.isFinite ? min(max(value, -100), 100) : 0 }
        return VideoPictureAdjustments(
            brightness: clamp(brightness), contrast: clamp(contrast), saturation: clamp(saturation),
            gamma: clamp(gamma), hue: clamp(hue)
        )
    }
}

/// Matches `PictureAdjustmentUniforms` in NativePlaybackShaders.metal.
struct PictureAdjustmentUniforms: Equatable {
    var brightness: Float
    var contrast: Float
    var saturation: Float
    var gammaExponent: Float
    var hueCos: Float
    var hueSin: Float
    var lumaOffset: Float = 0
    var lumaScale: Float = 1
    var chromaOffset: Float = 0.5
    var chromaScale: Float = 1
    var padding0: Float = 0
    var padding1: Float = 0

    /// Maps -100...100 controls the way mpv does: brightness adds up to one
    /// full luma range, contrast and saturation scale by 0...2, gamma spans
    /// 1/8...8, hue rotates by up to 180 degrees.
    init(_ adjustments: VideoPictureAdjustments) {
        let value = adjustments.clamped()
        brightness = Float(value.brightness / 100)
        contrast = Float((value.contrast + 100) / 100)
        saturation = Float((value.saturation + 100) / 100)
        gammaExponent = Float(1 / exp(log(8.0) * value.gamma / 100))
        let angle = value.hue / 100 * Double.pi
        hueCos = Float(cos(angle))
        hueSin = Float(sin(angle))
    }

    /// Adds the code-value range of a Y'CbCr format.
    func withRange(of pixelFormat: OSType) -> PictureAdjustmentUniforms {
        guard let range = VideoColorConversionUniforms.make(pixelFormat: pixelFormat, matrix: nil) else {
            return self
        }
        var copy = self
        copy.lumaOffset = range.lumaOffset
        copy.lumaScale = range.lumaScale
        copy.chromaOffset = range.chromaOffset
        copy.chromaScale = range.chromaScale
        return copy
    }
}

/// The app's equalizer, applied on the GPU.
final class PictureAdjustmentStage: VideoFrameProcessingStage {
    let name = "picture-adjust"
    let kind = VideoFrameProcessingStageKind.spatial
    private static let kernels = PlaneKernels(
        luma: "picture_adjust_luma", chroma: "picture_adjust_chroma", rgb: "picture_adjust_rgb"
    )
    private let runner = PlaneFilterRunner()
    private let lock = NSLock()
    private var adjustments: VideoPictureAdjustments

    init(adjustments: VideoPictureAdjustments) {
        self.adjustments = adjustments
    }

    /// Takes effect on the next frame; no reconfiguration needed.
    func update(_ adjustments: VideoPictureAdjustments) {
        lock.withLock { self.adjustments = adjustments }
    }

    func configure(input: VideoProcessingFormat, context: VideoFrameProcessingContext) throws -> VideoProcessingFormat {
        try runner.configure(input: input, kernels: Self.kernels, context: context)
        return input
    }

    func process(
        _ frame: VideoProcessingFrame,
        context: VideoFrameProcessingContext,
        emit: (VideoProcessingFrame) -> Void
    ) throws {
        let uniforms = PictureAdjustmentUniforms(lock.withLock { adjustments })
            .withRange(of: runner.pixelFormat)
        var output = frame
        output.pixelBuffer = try runner.run(frame.pixelBuffer, kernels: Self.kernels, context: context) { _, _ in
            uniformBytes(uniforms)
        }
        output.isPipelineOwned = true
        if output.origin == .decoded { output.origin = .processed }
        emit(output)
    }

    func reset() {}
}

/// Matches `SharpenUniforms` in NativePlaybackShaders.metal.
struct SharpenUniforms {
    var strength: Float
    var padding0: Float = 0
    var padding1: Float = 0
    var padding2: Float = 0
}

/// Gentle contrast-adaptive sharpening of luma (or RGB).
final class SharpenStage: VideoFrameProcessingStage {
    let name = "sharpen"
    let kind = VideoFrameProcessingStageKind.spatial
    static let strength: Float = 0.5
    private static let kernels = PlaneKernels(luma: "sharpen_plane", chroma: nil, rgb: "sharpen_plane")
    private let runner = PlaneFilterRunner()

    func configure(input: VideoProcessingFormat, context: VideoFrameProcessingContext) throws -> VideoProcessingFormat {
        try runner.configure(input: input, kernels: Self.kernels, context: context)
        return input
    }

    func process(
        _ frame: VideoProcessingFrame,
        context: VideoFrameProcessingContext,
        emit: (VideoProcessingFrame) -> Void
    ) throws {
        var output = frame
        output.pixelBuffer = try runner.run(frame.pixelBuffer, kernels: Self.kernels, context: context) { _, _ in
            uniformBytes(SharpenUniforms(strength: Self.strength))
        }
        output.isPipelineOwned = true
        if output.origin == .decoded { output.origin = .processed }
        emit(output)
    }

    func reset() {}
}

/// Matches `DebandUniforms` in NativePlaybackShaders.metal.
struct DebandUniforms {
    var threshold: Float
    var radius: Float
    var grain: Float
    var iterations: UInt32
    var seed: UInt32
    var padding0: UInt32 = 0
    var padding1: UInt32 = 0
    var padding2: UInt32 = 0
}

/// Smooths banding in gradients; real detail is above the threshold and
/// left alone.
final class DebandStage: VideoFrameProcessingStage {
    let name = "deband"
    let kind = VideoFrameProcessingStageKind.spatial
    /// About three 8-bit code values: banding steps are one or two.
    static let threshold: Float = 3.0 / 255
    static let lumaRadius: Float = 16
    static let iterations: UInt32 = 2
    /// Fine luma grain hides the remaining steps; chroma gets none.
    static let grain: Float = 1.5 / 255
    private static let kernels = PlaneKernels(luma: "deband_plane", chroma: "deband_plane", rgb: "deband_plane")
    private let runner = PlaneFilterRunner()
    private var frameCounter: UInt32 = 0

    func configure(input: VideoProcessingFormat, context: VideoFrameProcessingContext) throws -> VideoProcessingFormat {
        try runner.configure(input: input, kernels: Self.kernels, context: context)
        return input
    }

    func process(
        _ frame: VideoProcessingFrame,
        context: VideoFrameProcessingContext,
        emit: (VideoProcessingFrame) -> Void
    ) throws {
        frameCounter &+= 1
        let seed = frameCounter &* 7919
        var output = frame
        output.pixelBuffer = try runner.run(frame.pixelBuffer, kernels: Self.kernels, context: context) { _, isChroma in
            uniformBytes(DebandUniforms(
                threshold: Self.threshold,
                radius: isChroma ? Self.lumaRadius / 2 : Self.lumaRadius,
                grain: isChroma ? 0 : Self.grain,
                iterations: Self.iterations,
                seed: seed
            ))
        }
        output.isPipelineOwned = true
        if output.origin == .decoded { output.origin = .processed }
        emit(output)
    }

    func reset() {}
}

/// Matches `DenoiseUniforms` in NativePlaybackShaders.metal.
struct DenoiseUniforms {
    var rangeSigma: Float
    var temporalSigma: Float
    var temporalStrength: Float
    var hasHistory: UInt32
}

/// Moderate spatial and temporal noise reduction. Keeps the previous output
/// (a pipeline-owned buffer) as history; seeks and format changes clear it.
final class DenoiseStage: VideoFrameProcessingStage {
    let name = "denoise"
    let kind = VideoFrameProcessingStageKind.temporal
    static let rangeSigma: Float = 0.03
    static let temporalSigma: Float = 0.02
    static let temporalStrength: Float = 0.6
    /// Frames further apart than this are not blended.
    static let maximumHistoryGap = 0.25
    private static let kernels = PlaneKernels(luma: "denoise_plane", chroma: "denoise_plane", rgb: "denoise_plane")
    private let runner = PlaneFilterRunner()
    private var history: (buffer: CVPixelBuffer, seconds: Double)?

    func configure(input: VideoProcessingFormat, context: VideoFrameProcessingContext) throws -> VideoProcessingFormat {
        try runner.configure(input: input, kernels: Self.kernels, context: context)
        history = nil
        return input
    }

    func process(
        _ frame: VideoProcessingFrame,
        context: VideoFrameProcessingContext,
        emit: (VideoProcessingFrame) -> Void
    ) throws {
        let seconds = frame.presentationTime.seconds
        let usable = history.flatMap { previous -> CVPixelBuffer? in
            let gap = seconds - previous.seconds
            return gap > 0 && gap <= Self.maximumHistoryGap ? previous.buffer : nil
        }
        let uniforms = DenoiseUniforms(
            rangeSigma: Self.rangeSigma, temporalSigma: Self.temporalSigma,
            temporalStrength: Self.temporalStrength, hasHistory: usable == nil ? 0 : 1
        )
        var output = frame
        output.pixelBuffer = try runner.run(
            frame.pixelBuffer, kernels: Self.kernels, history: usable, context: context
        ) { _, _ in uniformBytes(uniforms) }
        output.isPipelineOwned = true
        if output.origin == .decoded { output.origin = .processed }
        history = (output.pixelBuffer, seconds)
        emit(output)
    }

    func reset() {
        history = nil
    }
}
