import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import Metal
import simd

/// Maps output pixels back to source texture coordinates for one transform.
struct VideoTransformGeometry: Equatable, Sendable {
    let outputWidth: Int
    let outputHeight: Int
    /// Source normalized x = dot(mapX, (u, v, 1)) for output normalized u, v.
    let mapX: SIMD3<Double>
    let mapY: SIMD3<Double>
    /// Normalized source bounds of the crop; sampling never leaves them.
    let sourceMin: SIMD2<Double>
    let sourceMax: SIMD2<Double>

    init(input: VideoProcessingFormat, transform: VideoFrameTransform) throws {
        guard let layout = VideoProcessingPlaneLayout.layout(for: input.pixelFormat) else {
            throw VideoFrameProcessingError.unsupportedPixelFormat(input.pixelFormat)
        }
        let bufferWidth = Double(input.width)
        let bufferHeight = Double(input.height)
        let visible = input.cleanAperture.intersection(
            CGRect(x: 0, y: 0, width: input.width, height: input.height)
        )
        guard !visible.isNull, visible.width >= 1, visible.height >= 1 else {
            throw VideoFrameProcessingError.invalidConfiguration("Empty visible region")
        }
        let crop = transform.crop ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        let cropRect = CGRect(
            x: visible.minX + crop.minX * visible.width,
            y: visible.minY + crop.minY * visible.height,
            width: crop.width * visible.width,
            height: crop.height * visible.height
        )
        guard cropRect.width >= 1, cropRect.height >= 1 else {
            throw VideoFrameProcessingError.invalidConfiguration("Crop is smaller than one pixel")
        }

        let pixelAspect = input.pixelAspectRatio.width / max(input.pixelAspectRatio.height, 1)
        var baseWidth = Double(cropRect.width) * Double(pixelAspect)
        var baseHeight = Double(cropRect.height)
        if transform.rotation.swapsAxes { swap(&baseWidth, &baseHeight) }

        let size: (Double, Double)
        switch transform.outputSize {
        case .source:
            size = (baseWidth, baseHeight)
        case let .scale(factor):
            guard factor.isFinite, factor > 0 else {
                throw VideoFrameProcessingError.invalidConfiguration("Scale must be positive")
            }
            size = (baseWidth * factor, baseHeight * factor)
        case let .fit(width, height):
            let fit = min(Double(width) / baseWidth, Double(height) / baseHeight)
            size = (baseWidth * fit, baseHeight * fit)
        case let .exact(width, height):
            size = (Double(width), Double(height))
        }
        let even = layout.requiresEvenDimensions
        outputWidth = Self.dimension(size.0, even: even)
        outputHeight = Self.dimension(size.1, even: even)

        // Output (u, v) -> flips -> inverse rotation -> crop -> source.
        let flipH = transform.flipsHorizontally
        let flipV = transform.flipsVertically
        let rotation = transform.rotation
        func source(_ u: Double, _ v: Double) -> SIMD2<Double> {
            let fu = flipH ? 1 - u : u
            let fv = flipV ? 1 - v : v
            let (cu, cv): (Double, Double) = switch rotation {
            case .none: (fu, fv)
            case .clockwise90: (fv, 1 - fu)
            case .clockwise180: (1 - fu, 1 - fv)
            case .clockwise270: (1 - fv, fu)
            }
            return SIMD2(
                (Double(cropRect.minX) + cu * Double(cropRect.width)) / bufferWidth,
                (Double(cropRect.minY) + cv * Double(cropRect.height)) / bufferHeight
            )
        }
        let origin = source(0, 0)
        let alongU = source(1, 0) - origin
        let alongV = source(0, 1) - origin
        mapX = SIMD3(alongU.x, alongV.x, origin.x)
        mapY = SIMD3(alongU.y, alongV.y, origin.y)
        sourceMin = SIMD2(Double(cropRect.minX) / bufferWidth, Double(cropRect.minY) / bufferHeight)
        sourceMax = SIMD2(Double(cropRect.maxX) / bufferWidth, Double(cropRect.maxY) / bufferHeight)
    }

    func sourceCoordinate(u: Double, v: Double) -> SIMD2<Double> {
        let point = SIMD3(u, v, 1)
        return SIMD2(simd_dot(mapX, point), simd_dot(mapY, point))
    }

    /// Source buffer pixels covered by one output pixel along each axis.
    func sourcePixelsPerOutputPixel(inputWidth: Int, inputHeight: Int) -> Double {
        let du = SIMD2(mapX.x * Double(inputWidth), mapY.x * Double(inputHeight)) / Double(outputWidth)
        let dv = SIMD2(mapX.y * Double(inputWidth), mapY.y * Double(inputHeight)) / Double(outputHeight)
        return max(simd_length(du), simd_length(dv))
    }

    func outputFormat(from input: VideoProcessingFormat) -> VideoProcessingFormat {
        VideoProcessingFormat(
            width: outputWidth,
            height: outputHeight,
            pixelFormat: input.pixelFormat,
            cleanAperture: CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight),
            pixelAspectRatio: CGSize(width: 1, height: 1),
            rotationDegrees: input.rotationDegrees,
            isFullRange: input.isFullRange,
            sourceComponentDepth: input.sourceComponentDepth
        )
    }

    private static func dimension(_ value: Double, even: Bool) -> Int {
        guard even else { return max(2, min(16_384, Int(value.rounded()))) }
        return max(2, min(16_384, Int((value / 2).rounded()) * 2))
    }
}

/// Matches `VideoTransformUniforms` in NativePlaybackShaders.metal.
struct VideoTransformUniforms {
    var mapX: SIMD4<Float>
    var mapY: SIMD4<Float>
    var sourceMin: SIMD2<Float>
    var sourceMax: SIMD2<Float>
    /// Source-space offsets for 2x2 supersampling; zero disables it.
    var stepU: SIMD2<Float>
    var stepV: SIMD2<Float>
}

/// Crops, scales, rotates and flips each plane on the GPU.
final class MetalTransformStage: VideoFrameProcessingStage {
    let name = "metal-transform"
    let kind = VideoFrameProcessingStageKind.spatial
    let transform: VideoFrameTransform

    /// True when the transform changes nothing, so the stage can be skipped.
    static func isIdentity(_ transform: VideoFrameTransform) -> Bool {
        transform.crop == nil && transform.outputSize == .source && transform.rotation == .none
            && !transform.flipsHorizontally && !transform.flipsVertically
    }

    /// Renderer retention plus frames in flight; allocation waits beyond it.
    static let maximumBufferCount = 24

    private var geometry: VideoTransformGeometry?
    private var layout: VideoProcessingPlaneLayout?
    private var uniforms: VideoTransformUniforms?
    private var pool: VideoProcessingBufferPool?
    private var outputFormat: VideoProcessingFormat?

    init(transform: VideoFrameTransform) {
        self.transform = transform
    }

    func configure(
        input: VideoProcessingFormat,
        context: VideoFrameProcessingContext
    ) throws -> VideoProcessingFormat {
        guard let layout = VideoProcessingPlaneLayout.layout(for: input.pixelFormat) else {
            throw VideoFrameProcessingError.unsupportedPixelFormat(input.pixelFormat)
        }
        let geometry = try VideoTransformGeometry(input: input, transform: transform)
        _ = try context.computePipeline(named: "video_transform_plane")
        let output = geometry.outputFormat(from: input)
        if pool?.matches(width: output.width, height: output.height, pixelFormat: output.pixelFormat) != true {
            pool = try VideoProcessingBufferPool(
                width: output.width,
                height: output.height,
                pixelFormat: output.pixelFormat,
                maximumBufferCount: Self.maximumBufferCount
            )
        }
        let footprint = geometry.sourcePixelsPerOutputPixel(
            inputWidth: input.width, inputHeight: input.height
        )
        // Bilinear filtering alone aliases when one output pixel covers more
        // than about one and a quarter source pixels.
        let supersample = footprint > 1.25
        let stepU = supersample
            ? SIMD2(Float(geometry.mapX.x), Float(geometry.mapY.x)) / Float(geometry.outputWidth) * 0.25
            : .zero
        let stepV = supersample
            ? SIMD2(Float(geometry.mapX.y), Float(geometry.mapY.y)) / Float(geometry.outputHeight) * 0.25
            : .zero
        uniforms = VideoTransformUniforms(
            mapX: SIMD4(SIMD3<Float>(geometry.mapX), 0),
            mapY: SIMD4(SIMD3<Float>(geometry.mapY), 0),
            sourceMin: SIMD2<Float>(geometry.sourceMin),
            sourceMax: SIMD2<Float>(geometry.sourceMax),
            stepU: stepU,
            stepV: stepV
        )
        self.geometry = geometry
        self.layout = layout
        outputFormat = output
        return output
    }

    func process(
        _ frame: VideoProcessingFrame,
        context: VideoFrameProcessingContext,
        emit: (VideoProcessingFrame) -> Void
    ) throws {
        guard let layout, var uniforms, let pool else {
            throw VideoFrameProcessingError.invalidConfiguration("Transform stage is not configured")
        }
        let destination = try pool.makeBuffer(while: context.shouldContinue)
        let pipeline = try context.computePipeline(named: "video_transform_plane")
        // Create every texture before the encoder: a throw with an encoder
        // open would leave the shared command buffer unusable.
        let planes = try layout.planes.enumerated().map { index, plane in
            (
                try context.texture(
                    for: frame.pixelBuffer, plane: index, pixelFormat: plane.pixelFormat, usage: .shaderRead
                ),
                try context.texture(
                    for: destination, plane: index, pixelFormat: plane.pixelFormat, usage: .shaderWrite
                )
            )
        }
        let commandBuffer = try context.commandBuffer()
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw VideoFrameProcessingError.commandBufferFailed("Compute encoder unavailable")
        }
        encoder.label = "Transform video frame"
        encoder.setComputePipelineState(pipeline)
        for (input, output) in planes {
            encoder.setTexture(input, index: 0)
            encoder.setTexture(output, index: 1)
            encoder.setBytes(&uniforms, length: MemoryLayout<VideoTransformUniforms>.stride, index: 0)
            let width = pipeline.threadExecutionWidth
            let height = max(1, pipeline.maxTotalThreadsPerThreadgroup / width)
            encoder.dispatchThreads(
                MTLSize(width: output.width, height: output.height, depth: 1),
                threadsPerThreadgroup: MTLSize(width: width, height: height, depth: 1)
            )
        }
        encoder.endEncoding()
        Self.applyOutputAttachments(from: frame.pixelBuffer, to: destination)
        emit(VideoProcessingFrame(
            pixelBuffer: destination,
            presentationTime: frame.presentationTime,
            duration: frame.duration,
            origin: frame.origin == .decoded ? .processed : frame.origin,
            isPipelineOwned: true
        ))
    }

    func reset() {}

    /// Keeps color metadata; drops geometry the transform already applied.
    static func applyOutputAttachments(from source: CVPixelBuffer, to destination: CVPixelBuffer) {
        CVBufferPropagateAttachments(source, destination)
        CVBufferRemoveAttachment(destination, kCVImageBufferCleanApertureKey)
        CVBufferRemoveAttachment(destination, kCVImageBufferPixelAspectRatioKey)
    }
}
