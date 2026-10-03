import CFFmpeg
import CoreVideo
import Foundation
import Testing

@Suite("Software video color conversion")
struct SoftwareVideoColorConversionTests {
    @Test func respectsMatrixAndRangeAcrossCachedContextReuse() throws {
        var frame = av_frame_alloc()
        let source = try #require(frame)
        defer { av_frame_free(&frame) }
        source.pointee.width = 16
        source.pointee.height = 16
        source.pointee.format = Int32(AV_PIX_FMT_YUV420P.rawValue)
        #expect(av_frame_get_buffer(source, 32) >= 0)
        let planes = [source.pointee.data.0, source.pointee.data.1, source.pointee.data.2]
        let strides = [source.pointee.linesize.0, source.pointee.linesize.1, source.pointee.linesize.2]
        for plane in 0..<3 {
            let pointer = try #require(planes[plane])
            let size = plane == 0 ? 16 : 8
            for row in 0..<size {
                memset(pointer.advanced(by: row * Int(strides[plane])), [100, 90, 200][plane], size)
            }
        }
        var buffer: CVPixelBuffer?
        #expect(CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess)
        let output = try #require(buffer)
        var context: UnsafeMutablePointer<SwsContext>?
        defer { sws_freeContext(context) }

        // Reference uses the defining luma weights, not swscale's coefficient
        // table or another invocation of the implementation under test.
        let matrices: [(AVColorSpace, Double, Double)] = [
            (AVCOL_SPC_BT709, 0.2126, 0.0722),
            (AVCOL_SPC_SMPTE170M, 0.299, 0.114),
            (AVCOL_SPC_BT2020_NCL, 0.2627, 0.0593),
            (AVCOL_SPC_UNSPECIFIED, 0.299, 0.114),
            (AVCOL_SPC_BT709, 0.2126, 0.0722),
        ]
        for (matrix, kr, kb) in matrices {
            for fullRange in [false, true, false] {
                source.pointee.colorspace = matrix
                source.pointee.color_range = fullRange ? AVCOL_RANGE_JPEG : AVCOL_RANGE_MPEG
                #expect(superplayr_copy_frame_to_bgra_pixel_buffer(source, output, &context) >= 0)
                let y = fullRange ? 100.0 / 255 : (100.0 - 16) / 219
                let cb = (90.0 - 128) / (fullRange ? 255 : 224)
                let cr = (200.0 - 128) / (fullRange ? 255 : 224)
                let rgb = [
                    y + 2 * (1 - kr) * cr,
                    y - 2 * kb * (1 - kb) / (1 - kr - kb) * cb
                        - 2 * kr * (1 - kr) / (1 - kr - kb) * cr,
                    y + 2 * (1 - kb) * cb,
                ].map { Int((max(0, min(1, $0)) * 255).rounded()) }
                #expect(CVPixelBufferLockBaseAddress(output, .readOnly) == kCVReturnSuccess)
                let pixels = try #require(CVPixelBufferGetBaseAddress(output))
                    .assumingMemoryBound(to: UInt8.self)
                let actual = [Int(pixels[2]), Int(pixels[1]), Int(pixels[0])]
                CVPixelBufferUnlockBaseAddress(output, .readOnly)
                // Integer swscale conversion may differ by two code values.
                for channel in 0..<3 {
                    #expect(abs(actual[channel] - rgb[channel]) <= 2,
                            "matrix=\(matrix.rawValue) fullRange=\(fullRange) RGB=\(actual) reference=\(rgb)")
                }
            }
        }
    }

    @Test func unspecifiedRangePreservesFullRangePixelFormats() throws {
        var frame = av_frame_alloc()
        let source = try #require(frame)
        defer { av_frame_free(&frame) }
        source.pointee.color_range = AVCOL_RANGE_UNSPECIFIED
        for format in [AV_PIX_FMT_YUVJ420P, AV_PIX_FMT_YUVJ444P, AV_PIX_FMT_BGRA] {
            source.pointee.format = Int32(format.rawValue)
            #expect(superplayr_frame_is_full_range(source) == 1)
        }
        source.pointee.format = Int32(AV_PIX_FMT_YUV420P.rawValue)
        #expect(superplayr_frame_is_full_range(source) == 0)
        source.pointee.color_range = AVCOL_RANGE_JPEG
        #expect(superplayr_frame_is_full_range(source) == 1)
    }
}
