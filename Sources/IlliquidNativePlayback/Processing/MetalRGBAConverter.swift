import CoreVideo
import Foundation
import Metal

/// Matches `VideoColorConversionUniforms` in NativePlaybackShaders.metal.
struct VideoColorConversionUniforms: Equatable {
    /// R = Y + x·Cr, G = Y − y·Cb − z·Cr, B = Y + w·Cb.
    var coefficients: SIMD4<Float>
    var lumaOffset: Float
    var lumaScale: Float
    var chromaOffset: Float
    var chromaScale: Float

    /// Coefficients for a Y'CbCr matrix with luma weights `kr` and `kb`.
    static func coefficients(kr: Float, kb: Float) -> SIMD4<Float> {
        let kg = 1 - kr - kb
        return SIMD4(
            2 * (1 - kr),
            2 * (1 - kb) * kb / kg,
            2 * (1 - kr) * kr / kg,
            2 * (1 - kb)
        )
    }

    static func make(
        pixelFormat: OSType,
        matrix: CFString?
    ) -> VideoColorConversionUniforms? {
        let isTenBit: Bool
        let isFullRange: Bool
        switch pixelFormat {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange: (isTenBit, isFullRange) = (false, false)
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange: (isTenBit, isFullRange) = (false, true)
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange: (isTenBit, isFullRange) = (true, false)
        case kCVPixelFormatType_420YpCbCr10BiPlanarFullRange: (isTenBit, isFullRange) = (true, true)
        default: return nil
        }
        let weights: (Float, Float)
        if let matrix, CFEqual(matrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2) {
            weights = (0.2126, 0.0722)
        } else if let matrix, CFEqual(matrix, kCVImageBufferYCbCrMatrix_ITU_R_2020) {
            weights = (0.2627, 0.0593)
        } else if let matrix, CFEqual(matrix, kCVImageBufferYCbCrMatrix_SMPTE_240M_1995) {
            weights = (0.212, 0.087)
        } else {
            // BT.601, and untagged buffers: the display layer shows untagged
            // Y'CbCr with BT.601 at every size (and swscale and the timeline
            // thumbnails use the same default). Converted frames must look the
            // same as the unprocessed path, so they follow it.
            weights = (0.299, 0.114)
        }
        // Ten-bit samples sit in the high bits of 16-bit words, so normalized
        // code values are (value << 6) / 65535.
        let unit: Float = isTenBit ? 64.0 / 65_535 : 1.0 / 255
        let lumaBlack: Float = isFullRange ? 0 : (isTenBit ? 64 : 16)
        let lumaRange: Float = isFullRange ? (isTenBit ? 1_023 : 255) : (isTenBit ? 876 : 219)
        let chromaZero: Float = isTenBit ? 512 : 128
        let chromaRange: Float = isFullRange ? (isTenBit ? 1_023 : 255) : (isTenBit ? 896 : 224)
        return VideoColorConversionUniforms(
            coefficients: coefficients(kr: weights.0, kb: weights.1),
            lumaOffset: lumaBlack * unit,
            lumaScale: 1 / (lumaRange * unit),
            chromaOffset: chromaZero * unit,
            chromaScale: 1 / (chromaRange * unit)
        )
    }
}

/// Converts decoded pictures to 64-bit RGBA half-float on the GPU.
///
/// Machine-learning processors (VideoToolbox frame-rate conversion, Core ML
/// models, most external tools) take RGB input. Values keep the source's
/// transfer function and primaries; only the Y'CbCr matrix and range are
/// removed, and the output's attachments say so.
final class MetalRGBAConverter {
    static let outputPixelFormat = kCVPixelFormatType_64RGBAHalf

    static func canConvert(_ pixelFormat: OSType) -> Bool {
        pixelFormat == kCVPixelFormatType_32BGRA
            || VideoColorConversionUniforms.make(pixelFormat: pixelFormat, matrix: nil) != nil
    }

    let pool: VideoProcessingBufferPool

    init(width: Int, height: Int, maximumBufferCount: Int, additionalAttributes: [String: Any] = [:]) throws {
        pool = try VideoProcessingBufferPool(
            width: width,
            height: height,
            pixelFormat: Self.outputPixelFormat,
            maximumBufferCount: maximumBufferCount,
            additionalAttributes: additionalAttributes
        )
    }

    /// Encodes the conversion; the result is complete after the context's
    /// next `synchronize()`.
    func convert(
        _ source: CVPixelBuffer,
        context: VideoFrameProcessingContext
    ) throws -> CVPixelBuffer {
        let format = CVPixelBufferGetPixelFormatType(source)
        let destination = try pool.makeBuffer(while: context.shouldContinue)
        let output = try context.texture(
            for: destination, plane: 0, pixelFormat: .rgba16Float, usage: .shaderWrite
        )
        // Resolve every texture and the kernel before the encoder: a throw
        // with an encoder open would leave the shared command buffer unusable.
        let pipeline: any MTLComputePipelineState
        let inputs: [any MTLTexture]
        var uniforms: VideoColorConversionUniforms?
        if format == kCVPixelFormatType_32BGRA {
            pipeline = try context.computePipeline(named: "video_bgra_to_rgba")
            inputs = [try context.texture(for: source, plane: 0, pixelFormat: .bgra8Unorm, usage: .shaderRead)]
        } else {
            guard let layout = VideoProcessingPlaneLayout.layout(for: format),
                  let conversion = VideoColorConversionUniforms.make(
                      pixelFormat: format,
                      matrix: CVBufferCopyAttachment(source, kCVImageBufferYCbCrMatrixKey, nil)
                          .flatMap { $0 as? String }.map { $0 as CFString }
                  )
            else {
                throw VideoFrameProcessingError.unsupportedPixelFormat(format)
            }
            pipeline = try context.computePipeline(named: "video_ycbcr_to_rgba")
            inputs = try (0..<2).map { plane in
                try context.texture(
                    for: source, plane: plane, pixelFormat: layout.planes[plane].pixelFormat, usage: .shaderRead
                )
            }
            uniforms = conversion
        }
        let commandBuffer = try context.commandBuffer()
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw VideoFrameProcessingError.commandBufferFailed("Compute encoder unavailable")
        }
        encoder.label = "Convert video frame to RGBA"
        for (index, texture) in inputs.enumerated() {
            encoder.setTexture(texture, index: index)
        }
        encoder.setTexture(output, index: inputs.count)
        if var uniforms {
            encoder.setBytes(&uniforms, length: MemoryLayout<VideoColorConversionUniforms>.stride, index: 0)
        }
        encoder.setComputePipelineState(pipeline)
        let width = pipeline.threadExecutionWidth
        let height = max(1, pipeline.maxTotalThreadsPerThreadgroup / width)
        encoder.dispatchThreads(
            MTLSize(width: output.width, height: output.height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: width, height: height, depth: 1)
        )
        encoder.endEncoding()
        Self.applyOutputAttachments(from: source, to: destination)
        return destination
    }

    static func applyOutputAttachments(from source: CVPixelBuffer, to destination: CVPixelBuffer) {
        CVBufferPropagateAttachments(source, destination)
        CVBufferRemoveAttachment(destination, kCVImageBufferYCbCrMatrixKey)
        CVBufferRemoveAttachment(destination, kCVImageBufferChromaLocationTopFieldKey)
        CVBufferRemoveAttachment(destination, kCVImageBufferChromaLocationBottomFieldKey)
    }
}
