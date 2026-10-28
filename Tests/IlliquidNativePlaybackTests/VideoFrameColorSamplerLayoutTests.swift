import CoreVideo
import Foundation
import IlliquidCore
import Testing
@testable import IlliquidNativePlayback

@Suite("Video frame color sampler layouts")
struct VideoFrameColorSamplerLayoutTests {
    private struct PlanarFormat {
        let pixelFormat: OSType
        let tenBit: Bool
        let fullRange: Bool

        var maximum: Int { tenBit ? 1023 : 255 }
        var bytesPerComponent: Int { tenBit ? 2 : 1 }
    }

    private let formats = [
        PlanarFormat(pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                     tenBit: false, fullRange: false),
        PlanarFormat(pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                     tenBit: false, fullRange: true),
        PlanarFormat(pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                     tenBit: true, fullRange: false),
        PlanarFormat(pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
                     tenBit: true, fullRange: true),
    ]

    @Test func paddedBGRARowsAndImagesSmallerThanTheGrid() throws {
        for (width, height) in [(1, 1), (3, 2), (19, 13)] {
            try withBGRA(width: width, height: height,
                         rowBytes: max(64, width * 4 + 28), seed: 7) { buffer in
                let sample = try #require(VideoFrameColorSampler.sample(buffer))
                try expectGrid(sample, width: width, height: height) { x, y in
                    bgraExpected(x: x, y: y, seed: 7)
                }
            }
        }
    }

    @Test func independentPlanarStridesRangesAndMatrixAttachments() throws {
        let matrices: [(CFString?, Double, Double)] = [
            (nil, 0.2126, 0.0722),
            (kCVImageBufferYCbCrMatrix_ITU_R_601_4, 0.299, 0.114),
            (kCVImageBufferYCbCrMatrix_ITU_R_709_2, 0.2126, 0.0722),
            (kCVImageBufferYCbCrMatrix_ITU_R_2020, 0.2627, 0.0593),
            ("unrecognized-test-matrix" as CFString, 0.2126, 0.0722),
        ]
        for format in formats {
            // Even planar dimensions avoid format-dependent rules for odd
            // subsampled images. 2x2 still exercises repeated grid points.
            for (width, height) in [(2, 2), (26, 18)] {
                try withPlanar(width: width, height: height,
                               format: format, seed: 11) { buffer in
                    for (attachment, kr, kb) in matrices {
                        if let attachment {
                            CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey,
                                                  attachment, .shouldPropagate)
                        } else {
                            CVBufferRemoveAttachment(buffer, kCVImageBufferYCbCrMatrixKey)
                        }
                        let sample = try #require(VideoFrameColorSampler.sample(buffer))
                        try expectGrid(sample, width: width, height: height) { x, y in
                            planarExpected(x: x, y: y, format: format, seed: 11, kr: kr, kb: kb)
                        }
                    }
                    // Return to unspecified/709 on the very same buffer.
                    CVBufferRemoveAttachment(buffer, kCVImageBufferYCbCrMatrixKey)
                    let sample = try #require(VideoFrameColorSampler.sample(buffer))
                    try expectGrid(sample, width: width, height: height) { x, y in
                        planarExpected(x: x, y: y, format: format, seed: 11,
                                       kr: 0.2126, kb: 0.0722)
                    }
                }
            }
        }
    }

    @Test func oneSamplerUsesTheCurrentBuffersLayout() throws {
        let sampler = VideoFrameColorSampler(minimumInterval: 0, smoothingTimeConstant: 0)
        try withBGRA(width: 19, height: 13, rowBytes: 104, seed: 7) { first in
            try withBGRA(width: 1, height: 1, rowBytes: 64, seed: 0) { second in
                try withPlanar(width: 6, height: 4, format: formats[3], seed: 31) { third in
                    // Keep all allocations alive, then return to the first buffer.
                    for (index, buffer) in [first, second, third, first].enumerated() {
                        let expected = try #require(VideoFrameColorSampler.sample(buffer))
                        let actual = try #require(sampler.sampleIfNeeded(
                            buffer, uptimeNanoseconds: UInt64(index + 1) * 1_000_000_000
                        ))
                        #expect(actual == expected)
                    }
                }
            }
        }
    }

    @Test func unsupportedPackedFormatStillReturnsNil() throws {
        try withBGRA(width: 19, height: 13, rowBytes: 104, seed: 7,
                     pixelFormat: kCVPixelFormatType_32ARGB) { buffer in
            #expect(VideoFrameColorSampler.sample(buffer) == nil)
        }
    }

    private func expectGrid(
        _ sample: VideoColorSample, width: Int, height: Int,
        expected: (Int, Int) -> SampledVideoColor
    ) throws {
        try #require(sample.columns == 12 && sample.rows == 8)
        try #require(sample.colors.count == 96)
        for row in 0..<8 {
            for column in 0..<12 {
                // Independent integer expression for the center of each cell.
                let x = (2 * column + 1) * width / 24
                let y = (2 * row + 1) * height / 16
                let wanted = expected(x, y)
                let actual = sample.colors[row * 12 + column]
                // Production uses Float coefficients; the oracle uses Double
                // equations and permits only their small rounding difference.
                #expect(abs(actual.red - wanted.red) < 0.000002)
                #expect(abs(actual.green - wanted.green) < 0.000002)
                #expect(abs(actual.blue - wanted.blue) < 0.000002)
            }
        }
    }

    private func bgraExpected(x: Int, y: Int, seed: Int) -> SampledVideoColor {
        SampledVideoColor(
            red: Double((13 * x + 7 * y + seed) % 256) / 255,
            green: Double((5 * x + 19 * y + 3 * seed) % 256) / 255,
            blue: Double((23 * x + 3 * y + 5 * seed) % 256) / 255
        )
    }

    private func lumaCode(x: Int, y: Int, seed: Int, maximum: Int) -> Int {
        (37 * x + 53 * y + 11 * seed) % (maximum + 1)
    }

    private func chromaCodes(x: Int, y: Int, seed: Int, maximum: Int) -> (cb: Int, cr: Int) {
        ((29 * x + 13 * y + 17 * seed + 70) % (maximum + 1),
         (7 * x + 31 * y + 23 * seed + 140) % (maximum + 1))
    }

    private func planarExpected(
        x: Int, y: Int, format: PlanarFormat, seed: Int, kr: Double, kb: Double
    ) -> SampledVideoColor {
        let rawY = Double(lumaCode(x: x, y: y, seed: seed, maximum: format.maximum))
        let chroma = chromaCodes(x: x / 2, y: y / 2, seed: seed, maximum: format.maximum)
        let minimumY = format.fullRange ? 0.0 : (format.tenBit ? 64.0 : 16.0)
        let spanY = format.fullRange
            ? Double(format.maximum) : (format.tenBit ? 876.0 : 219.0)
        let center = format.tenBit ? 512.0 : 128.0
        let spanC = format.fullRange
            ? Double(format.maximum) : (format.tenBit ? 896.0 : 224.0)
        let y = (rawY - minimumY) / spanY
        let cb = (Double(chroma.cb) - center) / spanC
        let cr = (Double(chroma.cr) - center) / spanC
        let kg = 1 - kr - kb
        return SampledVideoColor(
            red: y + 2 * (1 - kr) * cr,
            green: y - 2 * kb * (1 - kb) / kg * cb - 2 * kr * (1 - kr) / kg * cr,
            blue: y + 2 * (1 - kb) * cb
        )
    }

    private func withBGRA(
        width: Int, height: Int, rowBytes: Int, seed: Int,
        pixelFormat: OSType = kCVPixelFormatType_32BGRA,
        operation: (CVPixelBuffer) throws -> Void
    ) throws {
        let base = UnsafeMutableRawPointer.allocate(byteCount: rowBytes * height, alignment: 64)
        defer { base.deallocate() }
        memset(base, 0xEF, rowBytes * height)
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * rowBytes + x * 4
                base.storeBytes(of: UInt8((23 * x + 3 * y + 5 * seed) % 256),
                                toByteOffset: offset, as: UInt8.self)
                base.storeBytes(of: UInt8((5 * x + 19 * y + 3 * seed) % 256),
                                toByteOffset: offset + 1, as: UInt8.self)
                base.storeBytes(of: UInt8((13 * x + 7 * y + seed) % 256),
                                toByteOffset: offset + 2, as: UInt8.self)
                base.storeBytes(of: UInt8(255), toByteOffset: offset + 3, as: UInt8.self)
            }
        }
        var storage: CVPixelBuffer?
        let status = CVPixelBufferCreateWithBytes(
            kCFAllocatorDefault, width, height, pixelFormat,
            base, rowBytes, nil, nil, nil, &storage
        )
        try #require(status == kCVReturnSuccess)
        let buffer = try #require(storage)
        #expect(CVPixelBufferGetBytesPerRow(buffer) == rowBytes)
        try operation(buffer)
        withExtendedLifetime(buffer) {}
    }

    private func withPlanar(
        width: Int, height: Int, format: PlanarFormat, seed: Int,
        operation: (CVPixelBuffer) throws -> Void
    ) throws {
        let bytes = format.bytesPerComponent
        let lumaStride = ((width * bytes + 63) / 64 + 1) * 64
        let chromaStride = lumaStride + 64
        let luma = UnsafeMutableRawPointer.allocate(byteCount: lumaStride * height, alignment: 64)
        let chroma = UnsafeMutableRawPointer.allocate(
            byteCount: chromaStride * (height / 2), alignment: 64
        )
        defer { luma.deallocate(); chroma.deallocate() }
        memset(luma, 0xEF, lumaStride * height)
        memset(chroma, 0xEF, chromaStride * (height / 2))

        func write(_ value: Int, to base: UnsafeMutableRawPointer, offset: Int) {
            if format.tenBit {
                // Nonzero unused bits catch failing to discard the low six bits.
                base.storeBytes(of: UInt16((value << 6) | 0x35),
                                toByteOffset: offset, as: UInt16.self)
            } else {
                base.storeBytes(of: UInt8(value), toByteOffset: offset, as: UInt8.self)
            }
        }
        for y in 0..<height {
            for x in 0..<width {
                write(lumaCode(x: x, y: y, seed: seed, maximum: format.maximum),
                      to: luma, offset: y * lumaStride + x * bytes)
            }
        }
        for y in 0..<(height / 2) {
            for x in 0..<(width / 2) {
                let pair = chromaCodes(x: x, y: y, seed: seed, maximum: format.maximum)
                let offset = y * chromaStride + x * 2 * bytes
                write(pair.cb, to: chroma, offset: offset)
                write(pair.cr, to: chroma, offset: offset + bytes)
            }
        }

        var bases: [UnsafeMutableRawPointer?] = [luma, chroma]
        var widths = [width, width / 2]
        var heights = [height, height / 2]
        var strides = [lumaStride, chromaStride]
        var storage: CVPixelBuffer?
        let status = CVPixelBufferCreateWithPlanarBytes(
            kCFAllocatorDefault, width, height, format.pixelFormat,
            nil, 0, 2, &bases, &widths, &heights, &strides,
            nil, nil, nil, &storage
        )
        try #require(status == kCVReturnSuccess)
        let buffer = try #require(storage)
        #expect(CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) == lumaStride)
        #expect(CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) == chromaStride)
        try operation(buffer)
        withExtendedLifetime(buffer) {}
    }
}
