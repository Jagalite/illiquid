import CFFmpeg
import CoreVideo
import Darwin
import Foundation
import Testing
@testable import SuperplayrNativePlayback

/// The expected code values are authored here, without an RGB round trip or
/// another call to swscale. These tests measure storage precision, not a display.
@Suite("Planar output independent precision references", .serialized)
struct PlanarPrecisionReferenceTests {
    @Test func pixelFormatPolicyPreservesImplicitFullRangeAndRejectsUnqualifiedInputs() throws {
        var frame = av_frame_alloc()
        let source = try #require(frame)
        defer { av_frame_free(&frame) }
        source.pointee.format = Int32(AV_PIX_FMT_YUVJ420P.rawValue)
        source.pointee.color_range = AVCOL_RANGE_UNSPECIFIED
        #expect(VideoDecoder.preferredPlanarPixelFormat(for: source) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
        source.pointee.color_range = AVCOL_RANGE_MPEG
        #expect(VideoDecoder.preferredPlanarPixelFormat(for: source) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        source.pointee.format = Int32(AV_PIX_FMT_YUV420P10LE.rawValue)
        #expect(VideoDecoder.preferredPlanarPixelFormat(for: source) == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
        source.pointee.color_range = AVCOL_RANGE_JPEG
        #expect(VideoDecoder.preferredPlanarPixelFormat(for: source) == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange)
        for format in [AV_PIX_FMT_YUV444P, AV_PIX_FMT_YUV420P12LE, AV_PIX_FMT_RGBA, AV_PIX_FMT_NONE] {
            source.pointee.format = Int32(format.rawValue)
            #expect(VideoDecoder.preferredPlanarPixelFormat(for: source) == nil)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SUPERPLAYR_MEASURE_PLANAR_CONVERSION"] == "1",
                   "Opt-in conversion-only timing; does not measure decode, renderer, energy or playback"))
    func measureWarmConversionCostWithoutRendererOrAllocation() throws {
        for (width, height) in [(1_920, 1_080), (3_840, 2_160)] {
            for tenBit in [false, true] {
                var frame = av_frame_alloc()
                let source = try #require(frame)
                defer { av_frame_free(&frame) }
                source.pointee.width = Int32(width)
                source.pointee.height = Int32(height)
                source.pointee.format = Int32((tenBit ? AV_PIX_FMT_YUV420P10LE : AV_PIX_FMT_YUV420P).rawValue)
                source.pointee.color_range = AVCOL_RANGE_MPEG
                source.pointee.colorspace = AVCOL_SPC_BT709
                #expect(av_frame_get_buffer(source, 32) >= 0)
                let planes = [source.pointee.data.0, source.pointee.data.1, source.pointee.data.2]
                let strides = [source.pointee.linesize.0, source.pointee.linesize.1, source.pointee.linesize.2].map(Int.init)
                for plane in 0..<3 {
                    let pointer = try #require(planes[plane])
                    for row in 0..<(plane == 0 ? height : height / 2) {
                        let address = pointer.advanced(by: row * strides[plane])
                        if tenBit {
                            UnsafeMutableRawPointer(address).assumingMemoryBound(to: UInt16.self)
                                .initialize(repeating: plane == 0 ? 400 : 512, count: plane == 0 ? width : width / 2)
                        } else { memset(address, plane == 0 ? 100 : 128, plane == 0 ? width : width / 2) }
                    }
                }
                var createdBGRA: CVPixelBuffer?
                var createdPlanar: CVPixelBuffer?
                let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
                #expect(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attributes, &createdBGRA) == kCVReturnSuccess)
                #expect(CVPixelBufferCreate(nil, width, height, tenBit ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
                    : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attributes, &createdPlanar) == kCVReturnSuccess)
                let bgra = try #require(createdBGRA), planar = try #require(createdPlanar)
                var bgraContext: UnsafeMutablePointer<SwsContext>?
                var planarContext: UnsafeMutablePointer<SwsContext>?
                defer { sws_freeContext(bgraContext); sws_freeContext(planarContext) }
                func convert(planar usePlanar: Bool) -> Int32 {
                    usePlanar ? superplayr_copy_frame_to_biplanar_pixel_buffer(source, planar, &planarContext)
                        : superplayr_copy_frame_to_bgra_pixel_buffer(source, bgra, &bgraContext)
                }
                func cpuNanoseconds() -> UInt64 {
                    var stamp = timespec()
                    _ = clock_gettime(CLOCK_THREAD_CPUTIME_ID, &stamp)
                    return UInt64(stamp.tv_sec) * 1_000_000_000 + UInt64(stamp.tv_nsec)
                }
                for _ in 0..<5 { #expect(convert(planar: false) >= 0); #expect(convert(planar: true) >= 0) }
                var cpu: [[Double]] = [[], []], wall: [[Double]] = [[], []]
                for round in 0..<3 {
                    for route in round.isMultiple(of: 2) ? [0, 1] : [1, 0] {
                        let cpuStart = cpuNanoseconds(), wallStart = DispatchTime.now().uptimeNanoseconds
                        var failed = false
                        for _ in 0..<20 { if convert(planar: route == 1) < 0 { failed = true } }
                        wall[route].append(Double(DispatchTime.now().uptimeNanoseconds - wallStart) / 20_000_000)
                        cpu[route].append(Double(cpuNanoseconds() - cpuStart) / 20_000_000)
                        #expect(!failed)
                    }
                }
                for route in 0..<2 {
                    print("PLANAR_CONVERSION_REFERENCE size=\(width)x\(height) depth=\(tenBit ? 10 : 8) route=\(route == 1 ? "planar" : "bgra") "
                        + String(format: "wall_ms=%.3f thread_cpu_ms=%.3f", wall[route].sorted()[1], cpu[route].sorted()[1]))
                }
            }
        }
    }

    @Test(arguments: ["yuv420p", "yuvj420p", "nv12", "yuv420p10le", "p010le"])
    func preservesEveryLumaAndChromaCodeIncludingLowTenBitValues(name: String) throws {
        let format = av_get_pix_fmt(name)
        let tenBit = name.contains("10")
        let interleaved = name == "nv12" || name == "p010le"
        let bytesPerComponent = tenBit ? 2 : 1
        let sourceShift = name == "p010le" ? 6 : 0
        let luma: [UInt16] = tenBit
            ? [0, 1, 2, 3, 4, 63, 64, 65, 66, 67, 511, 512, 940, 941, 1022, 1023]
            : [0, 1, 2, 3, 4, 15, 16, 17, 18, 19, 127, 128, 234, 235, 254, 255]
        let chroma: [UInt16] = tenBit ? [0, 1, 510, 511, 512, 513, 1022, 1023]
            : [0, 1, 126, 127, 128, 129, 254, 255]
        var frame = av_frame_alloc()
        let source = try #require(frame)
        defer { av_frame_free(&frame) }
        source.pointee.width = 16
        source.pointee.height = 16
        source.pointee.format = Int32(format.rawValue)
        #expect(av_frame_get_buffer(source, 32) >= 0)
        let planes = [source.pointee.data.0, source.pointee.data.1, source.pointee.data.2]
        let strides = [source.pointee.linesize.0, source.pointee.linesize.1, source.pointee.linesize.2].map(Int.init)
        func write(_ value: UInt16, plane: Int, row: Int, column: Int) throws {
            let pointer = try #require(planes[plane]).advanced(by: row * strides[plane] + column * bytesPerComponent)
            if tenBit {
                UnsafeMutableRawPointer(pointer).storeBytes(of: (value << sourceShift).littleEndian, as: UInt16.self)
            } else { pointer.pointee = UInt8(value) }
        }
        for row in 0..<16 {
            for x in 0..<16 { try write(luma[(x + row) % luma.count], plane: 0, row: row, column: x) }
        }
        for row in 0..<8 {
            for x in 0..<8 {
                try write(chroma[(x + row) % chroma.count], plane: 1, row: row, column: interleaved ? x * 2 : x)
                try write(chroma[(x + row + 3) % chroma.count], plane: interleaved ? 1 : 2,
                          row: row, column: interleaved ? x * 2 + 1 : x)
            }
        }
        var context: UnsafeMutablePointer<SwsContext>?
        defer { sws_freeContext(context) }
        for matrix in [AVCOL_SPC_BT709, AVCOL_SPC_BT2020_NCL, AVCOL_SPC_SMPTE170M] {
            source.pointee.colorspace = matrix
            for fullRange in [false, true, false] {
                let isFull = fullRange || name == "yuvj420p"
                source.pointee.color_range = name == "yuvj420p" ? AVCOL_RANGE_UNSPECIFIED
                    : isFull ? AVCOL_RANGE_JPEG : AVCOL_RANGE_MPEG
                let outputFormat = tenBit
                    ? (isFull ? kCVPixelFormatType_420YpCbCr10BiPlanarFullRange : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
                    : isFull ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                var created: CVPixelBuffer?
                #expect(CVPixelBufferCreate(nil, 16, 16, outputFormat, nil, &created) == kCVReturnSuccess)
                let output = try #require(created)
                #expect(superplayr_copy_frame_to_biplanar_pixel_buffer(source, output, &context) >= 0)
                #expect(CVPixelBufferLockBaseAddress(output, .readOnly) == kCVReturnSuccess)
                defer { CVPixelBufferUnlockBaseAddress(output, .readOnly) }
                func read(plane: Int, row: Int, column: Int) throws -> UInt16 {
                    let pointer = try #require(CVPixelBufferGetBaseAddressOfPlane(output, plane))
                        .advanced(by: row * CVPixelBufferGetBytesPerRowOfPlane(output, plane) + column * bytesPerComponent)
                    return tenBit ? UInt16(littleEndian: pointer.load(as: UInt16.self))
                        : UInt16(pointer.load(as: UInt8.self))
                }
                let shift = tenBit ? 6 : 0
                for row in 0..<16 {
                    for x in 0..<16 {
                        #expect(try read(plane: 0, row: row, column: x) == luma[(x + row) % luma.count] << shift)
                    }
                }
                for row in 0..<8 {
                    for x in 0..<8 {
                        #expect(try read(plane: 1, row: row, column: x * 2) == chroma[(x + row) % chroma.count] << shift)
                        #expect(try read(plane: 1, row: row, column: x * 2 + 1) == chroma[(x + row + 3) % chroma.count] << shift)
                    }
                }
            }
        }
    }
}
