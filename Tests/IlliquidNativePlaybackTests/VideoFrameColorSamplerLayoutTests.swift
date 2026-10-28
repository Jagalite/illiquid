import CoreVideo
import Foundation
import IlliquidCore
import Testing
@testable import IlliquidNativePlayback

@Suite("Video color sampler buffer layouts")
struct VideoFrameColorSamplerLayoutTests {
    private static let formats: [OSType] = [
        kCVPixelFormatType_32BGRA,
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
        kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
    ]

    @Test(arguments: Self.formats)
    func patternedPaddedBuffersPreserveEveryGridCell(format: OSType) throws {
        var sizes = [(2, 2), (14, 10), (50, 34)]
        if format == kCVPixelFormatType_32BGRA { sizes.insert((1, 1), at: 0) }
        for (width, height) in sizes {
            let buffer = try makeBuffer(format: format, width: width, height: height)
            try fill(buffer, phase: 2)
            let sample = try #require(VideoFrameColorSampler.sample(buffer))
            try verify(sample, format: format, width: width, height: height, phase: 2)
        }
    }

    @Test func oneSamplerRefreshesLayoutForDifferentBuffersAndFormats() throws {
        let sampler = VideoFrameColorSampler(minimumInterval: 0, smoothingTimeConstant: 0)
        for (index, format) in Self.formats.enumerated() {
            let width = index.isMultiple(of: 2) ? 50 : 14
            let height = index.isMultiple(of: 2) ? 34 : 10
            let buffer = try makeBuffer(format: format, width: width, height: height)
            try fill(buffer, phase: index + 1)
            let sample = try #require(sampler.sampleIfNeeded(
                buffer, uptimeNanoseconds: UInt64(index + 1) * 1_000_000_000))
            try verify(sample, format: format, width: width, height: height, phase: index + 1)
        }
    }

    @Test func removingMatrixAttachmentRestoresDefaultOnTheSameTenBitBuffer() throws {
        let format = kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        let buffer = try makeBuffer(format: format, width: 50, height: 34)
        try fill(buffer, phase: 1)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey,
                              kCVImageBufferYCbCrMatrix_ITU_R_601_4, .shouldPropagate)
        let explicit = try #require(VideoFrameColorSampler.sample(buffer))
        try verify(explicit, format: format, width: 50, height: 34, phase: 1,
                   weights: (0.299, 0.114))
        CVBufferRemoveAttachment(buffer, kCVImageBufferYCbCrMatrixKey)
        let unspecified = try #require(VideoFrameColorSampler.sample(buffer))
        try verify(unspecified, format: format, width: 50, height: 34, phase: 1)
        #expect(explicit != unspecified)
    }

    @Test func unsupportedSingleComponentBufferReturnsNil() throws {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, 14, 10,
            kCVPixelFormatType_OneComponent8, nil, &buffer)
        try #require(status == kCVReturnSuccess)
        let unsupported = try #require(buffer)
        #expect(VideoFrameColorSampler.sample(unsupported) == nil)
    }

    private func makeBuffer(format: OSType, width: Int, height: Int) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:],
            kCVPixelBufferBytesPerRowAlignmentKey: 256,
        ]
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, format,
                                        attributes as CFDictionary, &buffer)
        try #require(status == kCVReturnSuccess)
        return try #require(buffer)
    }

    private func isTenBit(_ format: OSType) -> Bool {
        format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            || format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
    }

    private func rgb(_ x: Int, _ y: Int, _ phase: Int) -> (red: Int, green: Int, blue: Int) {
        ((x * 37 + y * 13 + phase * 17) % 256,
         (x * 11 + y * 29 + phase * 47) % 256,
         (x * 23 + y * 7 + phase * 3) % 256)
    }

    private func yuv(_ x: Int, _ y: Int, _ phase: Int, _ tenBit: Bool)
        -> (luma: Int, cb: Int, cr: Int) {
        let levels = tenBit ? 1024 : 256
        return ((x * 31 + y * 17 + phase * 29 + levels / 4) % levels,
                (x * 43 + y * 11 + phase * 17 + levels / 2 - 47) % levels,
                (x * 13 + y * 37 + phase * 23 + levels / 2 + 29) % levels)
    }

    private func fill(_ buffer: CVPixelBuffer, phase: Int) throws {
        try #require(CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let format = CVPixelBufferGetPixelFormatType(buffer)
        if format == kCVPixelFormatType_32BGRA {
            let base = try #require(CVPixelBufferGetBaseAddress(buffer))
            let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            #expect(stride > width * 4)
            memset(base, 0xD3, stride * height)
            for y in 0..<height {
                let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
                for x in 0..<width {
                    let value = rgb(x, y, phase)
                    row[x * 4] = UInt8(value.blue); row[x * 4 + 1] = UInt8(value.green)
                    row[x * 4 + 2] = UInt8(value.red); row[x * 4 + 3] = 255
                }
            }
            return
        }
        try #require(CVPixelBufferGetPlaneCount(buffer) >= 2)
        let tenBit = isTenBit(format)
        for plane in 0..<2 {
            let base = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, plane))
            let width = CVPixelBufferGetWidthOfPlane(buffer, plane)
            let height = CVPixelBufferGetHeightOfPlane(buffer, plane)
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
            let channels = plane == 0 ? 1 : 2
            #expect(stride > width * channels * (tenBit ? 2 : 1))
            memset(base, 0xD3, stride * height)
            for y in 0..<height {
                let row = base.advanced(by: y * stride)
                for x in 0..<width {
                    let value = yuv(x, y, phase, tenBit)
                    let components = plane == 0 ? [value.luma] : [value.cb, value.cr]
                    for component in components.indices {
                        let index = x * channels + component
                        if tenBit {
                            // Low six bits deliberately vary; the ten-bit value occupies bits 6...15.
                            let noise = (x * 7 + y * 3 + phase + component) % 64
                            row.assumingMemoryBound(to: UInt16.self)[index] =
                                UInt16((components[component] << 6) | noise)
                        } else {
                            row.assumingMemoryBound(to: UInt8.self)[index] = UInt8(components[component])
                        }
                    }
                }
            }
        }
    }

    private func verify(_ sample: VideoColorSample, format: OSType, width: Int, height: Int,
                        phase: Int, weights: (Double, Double) = (0.2126, 0.0722)) throws {
        try #require(sample.columns == 12 && sample.rows == 8)
        for row in 0..<8 {
            for column in 0..<12 {
                // Integer center coordinates are independent of the sampler's floating-point grid.
                let x = (2 * column + 1) * width / 24, y = (2 * row + 1) * height / 16
                let expected: [Double]
                if format == kCVPixelFormatType_32BGRA {
                    let value = rgb(x, y, phase)
                    expected = [value.red, value.green, value.blue].map { Double($0) / 255 }
                } else {
                    let tenBit = isTenBit(format)
                    let full = format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                        || format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
                    let levels = tenBit ? 1024 : 256
                    let luma = yuv(x, y, phase, tenBit).luma
                    let chroma = yuv(x / 2, y / 2, phase, tenBit)
                    let yy = Double(luma - (full ? 0 : (tenBit ? 64 : 16)))
                        / Double(full ? levels - 1 : (tenBit ? 876 : 219))
                    let divisor = Double(full ? levels - 1 : (tenBit ? 896 : 224))
                    let cb = Double(chroma.cb - levels / 2) / divisor
                    let cr = Double(chroma.cr - levels / 2) / divisor
                    let (kr, kb) = weights
                    let kg = 1 - kr - kb
                    // Double-precision reference coefficients; do not call PiPVideoMapping.
                    expected = [yy + 2 * (1 - kr) * cr,
                        yy - 2 * kb * (1 - kb) / kg * cb - 2 * kr * (1 - kr) / kg * cr,
                        yy + 2 * (1 - kb) * cb].map { min(1, max(0, $0)) }
                }
                let actual = sample.colors[row * 12 + column]
                #expect(abs(actual.red - expected[0]) < 0.000001)
                #expect(abs(actual.green - expected[1]) < 0.000001)
                #expect(abs(actual.blue - expected[2]) < 0.000001)
            }
        }
    }
}
