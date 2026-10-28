import CoreVideo
import Foundation
import IlliquidCore
import Testing
@testable import IlliquidNativePlayback

@Suite("Video frame color sampler layouts")
struct VideoFrameColorSamplerLayoutTests {
    private struct Format: Sendable {
        let pixelFormat: OSType
        let bits: Int
        let fullRange: Bool
        var isBGRA: Bool { pixelFormat == kCVPixelFormatType_32BGRA }
        var lumaMinimum: Int { fullRange ? 0 : (bits == 10 ? 64 : 16) }
        var lumaMaximum: Int {
            fullRange ? (bits == 10 ? 1023 : 255) : (bits == 10 ? 940 : 235)
        }
        var chromaCenter: Int { bits == 10 ? 512 : 128 }
        var chromaRange: Int {
            fullRange ? (bits == 10 ? 1023 : 255) : (bits == 10 ? 896 : 224)
        }
    }

    private static let formats: [Format] = [
        .init(pixelFormat: kCVPixelFormatType_32BGRA, bits: 8, fullRange: true),
        .init(pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
              bits: 8, fullRange: false),
        .init(pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
              bits: 8, fullRange: true),
        .init(pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
              bits: 10, fullRange: false),
        .init(pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
              bits: 10, fullRange: true),
    ]

    @Test func everySupportedFormatSamplesPatternedPaddedRows() throws {
        for (index, format) in Self.formats.enumerated() {
            let buffer = try makeBuffer(width: 26, height: 18,
                                        pixelFormat: format.pixelFormat, alignment: 128)
            let seed = index + 1
            try fillPattern(buffer, format: format, seed: seed)
            if format.isBGRA {
                #expect(CVPixelBufferGetBytesPerRow(buffer) > 26 * 4)
            } else {
                let bytesPerComponent = format.bits == 10 ? 2 : 1
                #expect(CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) > 26 * bytesPerComponent)
                #expect(CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) > 26 * bytesPerComponent)
            }
            let sample = try #require(VideoFrameColorSampler.sample(buffer))
            expectPattern(sample, width: 26, height: 18, format: format, seed: seed)
        }
    }

    @Test func samplesOddAndSinglePixelPackedLayouts() throws {
        let format = Self.formats[0]
        for (width, height) in [(13, 9), (1, 1)] {
            let buffer = try makeBuffer(width: width, height: height,
                                        pixelFormat: format.pixelFormat, alignment: 128)
            try fillPattern(buffer, format: format, seed: 9)
            let sample = try #require(VideoFrameColorSampler.sample(buffer))
            expectPattern(sample, width: width, height: height, format: format, seed: 9)
        }
    }

    @Test func oneSamplerRefreshesLayoutForEveryBuffer() throws {
        let sampler = VideoFrameColorSampler(minimumInterval: 0, smoothingTimeConstant: 0)
        // Keep every allocation alive while format, dimensions and stride change.
        let layouts = [
            (format: 0, width: 13, height: 9, alignment: 128),
            (format: 1, width: 26, height: 18, alignment: 256),
            (format: 4, width: 58, height: 34, alignment: 128),
            (format: 2, width: 122, height: 70, alignment: 256),
            (format: 3, width: 74, height: 66, alignment: 128),
            (format: 0, width: 31, height: 17, alignment: 256),
        ]
        let buffers = try layouts.map {
            try makeBuffer(width: $0.width, height: $0.height,
                           pixelFormat: Self.formats[$0.format].pixelFormat, alignment: $0.alignment)
        }
        for (index, layout) in layouts.enumerated() {
            let format = Self.formats[layout.format]
            let seed = 17 + index * 29
            try fillPattern(buffers[index], format: format, seed: seed)
            let sample = try #require(sampler.sampleIfNeeded(
                buffers[index], uptimeNanoseconds: UInt64(index + 1) * 1_000_000_000
            ))
            expectPattern(sample, width: layout.width, height: layout.height,
                          format: format, seed: seed)
        }
        withExtendedLifetime(buffers) {}
    }

    @Test func unsupportedFormatDoesNotPoisonTheNextSample() throws {
        let sampler = VideoFrameColorSampler(minimumInterval: 0, smoothingTimeConstant: 0)
        let unsupported = try makeBuffer(width: 26, height: 18,
                                         pixelFormat: kCVPixelFormatType_OneComponent8, alignment: 128)
        #expect(VideoFrameColorSampler.sample(unsupported) == nil)
        #expect(sampler.sampleIfNeeded(unsupported, uptimeNanoseconds: 1_000_000_000) == nil)
        let format = Self.formats[4]
        let supported = try makeBuffer(width: 26, height: 18,
                                       pixelFormat: format.pixelFormat, alignment: 256)
        try fillPattern(supported, format: format, seed: 43)
        let sample = try #require(sampler.sampleIfNeeded(supported, uptimeNanoseconds: 2_000_000_000))
        expectPattern(sample, width: 26, height: 18, format: format, seed: 43)
    }

    private func makeBuffer(width: Int, height: Int, pixelFormat: OSType,
                            alignment: Int) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, pixelFormat,
            [kCVPixelBufferBytesPerRowAlignmentKey: alignment] as CFDictionary, &buffer
        )
        #expect(status == kCVReturnSuccess)
        return try #require(buffer)
    }

    private func fillPattern(_ buffer: CVPixelBuffer, format: Format, seed: Int) throws {
        try #require(CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        if format.isBGRA {
            let base = try #require(CVPixelBufferGetBaseAddress(buffer))
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            memset(base, 0xA5, stride * height)
            for y in 0..<height {
                let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
                for x in 0..<width {
                    row[x * 4] = UInt8((7 * x + 11 * y + 19 * seed) % 256)
                    row[x * 4 + 1] = UInt8((13 * x + 5 * y + 43 * seed) % 256)
                    row[x * 4 + 2] = UInt8((3 * x + 17 * y + 71 * seed) % 256)
                    row[x * 4 + 3] = 255
                }
            }
            return
        }
        try #require(CVPixelBufferGetPlaneCount(buffer) == 2)
        for plane in 0..<2 {
            let base = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, plane))
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
            let planeWidth = CVPixelBufferGetWidthOfPlane(buffer, plane)
            let planeHeight = CVPixelBufferGetHeightOfPlane(buffer, plane)
            memset(base, 0xA5, stride * planeHeight)
            for y in 0..<planeHeight {
                let row = base.advanced(by: y * stride)
                for x in 0..<planeWidth {
                    let values = plane == 0
                        ? [luma(x: x, y: y, seed: seed, format: format)]
                        : [chroma(x: x, y: y, seed: seed, isCr: false, format: format),
                           chroma(x: x, y: y, seed: seed, isCr: true, format: format)]
                    for (component, value) in values.enumerated() {
                        let offset = x * values.count + component
                        if format.bits == 8 {
                            row.assumingMemoryBound(to: UInt8.self)[offset] = UInt8(value)
                        } else {
                            // P010's unused low six bits must not affect colors.
                            let lowBits = (x + y + seed + component) % 64
                            row.assumingMemoryBound(to: UInt16.self)[offset] = UInt16(value * 64 + lowBits)
                        }
                    }
                }
            }
        }
    }

    private func luma(x: Int, y: Int, seed: Int, format: Format) -> Int {
        format.lumaMinimum + (29 * x + 17 * y + 13 * seed)
            % (format.lumaMaximum - format.lumaMinimum + 1)
    }

    private func chroma(x: Int, y: Int, seed: Int, isCr: Bool, format: Format) -> Int {
        let radius = format.bits == 10 ? 128 : 32
        let pattern = isCr ? 23 * x + 3 * y + 7 * seed : 11 * x + 17 * y + 19 * seed
        return format.chromaCenter - radius + pattern % (2 * radius + 1)
    }

    private func expectPattern(_ sample: VideoColorSample, width: Int, height: Int,
                               format: Format, seed: Int) {
        #expect(sample.columns == 12)
        #expect(sample.rows == 8)
        #expect(sample.colors.count == 96)
        for row in 0..<8 {
            let y = min(height - 1, Int((Double(row) + 0.5) / 8 * Double(height)))
            for column in 0..<12 {
                let x = min(width - 1, Int((Double(column) + 0.5) / 12 * Double(width)))
                let expected: SampledVideoColor
                if format.isBGRA {
                    expected = SampledVideoColor(
                        red: Double((3 * x + 17 * y + 71 * seed) % 256) / 255,
                        green: Double((13 * x + 5 * y + 43 * seed) % 256) / 255,
                        blue: Double((7 * x + 11 * y + 19 * seed) % 256) / 255
                    )
                } else {
                    let luminance = Double(luma(x: x, y: y, seed: seed, format: format)
                        - format.lumaMinimum) / Double(format.lumaMaximum - format.lumaMinimum)
                    let cb = Double(chroma(x: x / 2, y: y / 2, seed: seed, isCr: false, format: format)
                        - format.chromaCenter) / Double(format.chromaRange)
                    let cr = Double(chroma(x: x / 2, y: y / 2, seed: seed, isCr: true, format: format)
                        - format.chromaCenter) / Double(format.chromaRange)
                    // Independent Double BT.709 oracle; production coefficients
                    // are Float, so the unit assertion permits rounding error.
                    let kr = 0.2126, kb = 0.0722
                    let kg = 1 - kr - kb
                    expected = SampledVideoColor(
                        red: luminance + 2 * (1 - kr) * cr,
                        green: luminance - 2 * kb * (1 - kb) / kg * cb - 2 * kr * (1 - kr) / kg * cr,
                        blue: luminance + 2 * (1 - kb) * cb
                    )
                }
                let actual = sample.color(column: column, row: row)
                #expect(abs(actual.red - expected.red) < 0.000001)
                #expect(abs(actual.green - expected.green) < 0.000001)
                #expect(abs(actual.blue - expected.blue) < 0.000001)
            }
        }
    }
}
