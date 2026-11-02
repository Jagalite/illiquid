import CoreVideo
import IlliquidCore
import Testing
@testable import IlliquidNativePlayback

@Suite("Video frame color sampler")
struct VideoFrameColorSamplerTests {
    @Test func throttlesSamplingToFourTimesPerSecond() throws {
        let sampler = VideoFrameColorSampler()
        let pixelBuffer = try makePixelBuffer(
            width: 48,
            height: 32,
            pixelFormat: kCVPixelFormatType_32BGRA
        )
        try fillBGRA(pixelBuffer, red: 0, green: 0, blue: 0)
        #expect(sampler.sampleIfNeeded(
            pixelBuffer,
            uptimeNanoseconds: 1_000_000_000
        ) != nil)

        try fillBGRA(pixelBuffer, red: 255, green: 255, blue: 255)
        #expect(sampler.sampleIfNeeded(
            pixelBuffer,
            uptimeNanoseconds: 1_249_999_999
        ) == nil)
        let changed = try #require(sampler.sampleIfNeeded(
            pixelBuffer,
            uptimeNanoseconds: 1_250_000_000
        ))
        #expect(changed.overall.red > 0.99)
    }

    @Test func smoothingUsesElapsedTimeAtFourHertz() throws {
        let sampler = VideoFrameColorSampler(
            minimumInterval: 0.25,
            smoothingTimeConstant: 0.65
        )
        let pixelBuffer = try makePixelBuffer(
            width: 48,
            height: 32,
            pixelFormat: kCVPixelFormatType_32BGRA
        )
        try fillBGRA(pixelBuffer, red: 0, green: 0, blue: 0)
        _ = try #require(sampler.sampleIfNeeded(
            pixelBuffer,
            uptimeNanoseconds: 1_000_000_000
        ))

        try fillBGRA(pixelBuffer, red: 51, green: 51, blue: 51)
        let smoothed = try #require(sampler.sampleIfNeeded(
            pixelBuffer,
            uptimeNanoseconds: 1_250_000_000
        ))
        let expectedWeight = VideoFrameColorSampler.smoothingWeight(
            elapsed: 0.25,
            timeConstant: 0.65
        )
        #expect(abs(smoothed.overall.red - 0.2 * expectedWeight) < 0.001)
    }

    @Test func suppressesTinyChangesButPublishesSceneCutsImmediately() throws {
        let sampler = VideoFrameColorSampler()
        let pixelBuffer = try makePixelBuffer(
            width: 48,
            height: 32,
            pixelFormat: kCVPixelFormatType_32BGRA
        )
        try fillBGRA(pixelBuffer, red: 0, green: 0, blue: 0)
        _ = try #require(sampler.sampleIfNeeded(
            pixelBuffer,
            uptimeNanoseconds: 1_000_000_000
        ))

        try fillBGRA(pixelBuffer, red: 1, green: 1, blue: 1)
        #expect(sampler.sampleIfNeeded(
            pixelBuffer,
            uptimeNanoseconds: 1_250_000_000
        ) == nil)

        try fillBGRA(pixelBuffer, red: 255, green: 255, blue: 255)
        let cut = try #require(sampler.sampleIfNeeded(
            pixelBuffer,
            uptimeNanoseconds: 1_500_000_000
        ))
        #expect(cut.overall.red > 0.99)
        #expect(cut.overall.green > 0.99)
        #expect(cut.overall.blue > 0.99)
    }

    @Test func samplesDistinctLeadingAndBottomBGRARegions() throws {
        let pixelBuffer = try makePixelBuffer(
            width: 120,
            height: 80,
            pixelFormat: kCVPixelFormatType_32BGRA
        )
        try withLockedPixelBuffer(pixelBuffer) {
            let base = try #require(CVPixelBufferGetBaseAddress(pixelBuffer))
            let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
            for y in 0..<80 {
                for x in 0..<120 {
                    let pixel = base
                        .advanced(by: y * bytesPerRow + x * 4)
                        .assumingMemoryBound(to: UInt8.self)
                    let color: (blue: UInt8, green: UInt8, red: UInt8)
                    if y >= 56 {
                        color = (255, 0, 0)
                    } else if x < 40 {
                        color = (0, 0, 255)
                    } else {
                        color = (0, 255, 0)
                    }
                    pixel[0] = color.blue
                    pixel[1] = color.green
                    pixel[2] = color.red
                    pixel[3] = 255
                }
            }
        }

        let sample = try #require(VideoFrameColorSampler.sample(pixelBuffer))
        #expect(sample.columns == 12)
        #expect(sample.rows == 8)
        #expect(sample.color(column: 0, row: 0).red > 0.98)
        #expect(sample.color(column: 11, row: 0).green > 0.98)
        #expect(sample.color(column: 11, row: 7).blue > 0.98)
        #expect(sample.leading.red > 0.7)
        #expect(sample.leading.blue > 0.2)
        #expect(sample.leading.green < 0.05)
        #expect(sample.bottom.blue > 0.98)
        #expect(abs(sample.overall.red - 0.25) < 0.03)
        #expect(abs(sample.overall.green - 0.5) < 0.03)
        #expect(abs(sample.overall.blue - 0.25) < 0.03)
    }

    @Test func samplesFullRangeBiPlanarWhite() throws {
        let pixelBuffer = try makePixelBuffer(
            width: 48,
            height: 32,
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        )
        try withLockedPixelBuffer(pixelBuffer) {
            let luma = try #require(CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0))
            memset(
                luma,
                255,
                CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
                    * CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
            )
            let chroma = try #require(CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1))
            memset(
                chroma,
                128,
                CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
                    * CVPixelBufferGetHeightOfPlane(pixelBuffer, 1)
            )
        }

        let sample = try #require(VideoFrameColorSampler.sample(pixelBuffer))
        #expect(sample.overall.red > 0.99)
        #expect(sample.overall.green > 0.99)
        #expect(sample.overall.blue > 0.99)
    }

    @Test func samplesVideoRangeTenBitBiPlanarWhite() throws {
        let pixelBuffer = try makePixelBuffer(
            width: 48,
            height: 32,
            pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        )
        try withLockedPixelBuffer(pixelBuffer) {
            let lumaBase = try #require(
                CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)
            )
            let lumaBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(
                pixelBuffer,
                0
            )
            for y in 0..<CVPixelBufferGetHeightOfPlane(pixelBuffer, 0) {
                let row = lumaBase
                    .advanced(by: y * lumaBytesPerRow)
                    .assumingMemoryBound(to: UInt16.self)
                for x in 0..<CVPixelBufferGetWidthOfPlane(pixelBuffer, 0) {
                    row[x] = 940 << 6
                }
            }

            let chromaBase = try #require(
                CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1)
            )
            let chromaBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(
                pixelBuffer,
                1
            )
            for y in 0..<CVPixelBufferGetHeightOfPlane(pixelBuffer, 1) {
                let row = chromaBase
                    .advanced(by: y * chromaBytesPerRow)
                    .assumingMemoryBound(to: UInt16.self)
                for word in 0..<(chromaBytesPerRow / 2) {
                    row[word] = 512 << 6
                }
            }
        }

        let sample = try #require(VideoFrameColorSampler.sample(pixelBuffer))
        #expect(sample.overall.red > 0.99)
        #expect(sample.overall.green > 0.99)
        #expect(sample.overall.blue > 0.99)
    }

    @Test func matrixAttachmentsChangePaletteSamplesWithoutAStaleCoefficientCache() throws {
        let buffer = try makePixelBuffer(width: 48, height: 32,
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        try withLockedPixelBuffer(buffer) {
            let luma = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, 0))
            memset(luma, 126, CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) * 32)
            let chroma = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, 1))
            for row in 0..<16 {
                let bytes = chroma.advanced(by: row * CVPixelBufferGetBytesPerRowOfPlane(buffer, 1))
                    .assumingMemoryBound(to: UInt8.self)
                for x in 0..<24 { bytes[x * 2] = 100; bytes[x * 2 + 1] = 170 }
            }
        }
        for (matrix, kr, kb) in [
            (kCVImageBufferYCbCrMatrix_ITU_R_601_4, 0.299, 0.114),
            (kCVImageBufferYCbCrMatrix_ITU_R_709_2, 0.2126, 0.0722),
            (kCVImageBufferYCbCrMatrix_ITU_R_2020, 0.2627, 0.0593),
        ] {
            CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, matrix, .shouldPropagate)
            let actual = try #require(VideoFrameColorSampler.sample(buffer)).overall
            let y = 110.0 / 219, cb = -28.0 / 224, cr = 42.0 / 224
            #expect(abs(actual.red - (y + 2 * (1 - kr) * cr)) < 0.00001)
            #expect(abs(actual.blue - (y + 2 * (1 - kb) * cb)) < 0.00001)
            #expect(abs(actual.green - (y - 2 * kb * (1 - kb) / (1 - kr - kb) * cb
                - 2 * kr * (1 - kr) / (1 - kr - kb) * cr)) < 0.00001)
        }
    }


    @Test func samplesEveryGridPointAcrossPaddedFormatsAndSmallSizes() throws {
        let formats: [OSType] = [
            kCVPixelFormatType_32BGRA,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
        ]
        for format in formats {
            // Odd BGRA sizes and tiny even YUV sizes are valid native buffers.
            let sizes = format == kCVPixelFormatType_32BGRA
                ? [(1, 1), (13, 9), (37, 29)] : [(2, 2), (14, 10), (38, 30)]
            for (width, height) in sizes {
                let buffer = try makePixelBuffer(
                    width: width, height: height, pixelFormat: format,
                    bytesPerRowAlignment: 256
                )
                let bytesPerPixel = isTenBit(format) ? 2 : 1
                if format == kCVPixelFormatType_32BGRA {
                    #expect(CVPixelBufferGetBytesPerRow(buffer) > width * 4)
                } else {
                    #expect(CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) > width * bytesPerPixel)
                    #expect(CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) > width * bytesPerPixel)
                }
                try fillPattern(buffer, phase: 0)
                try expectPattern(buffer, phase: 0)
            }
        }
    }

    @Test func rereadsLayoutAndPixelsWhenBuffersAreReusedOrFormatsChange() throws {
        let formats: [OSType] = [
            kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
            kCVPixelFormatType_32BGRA,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ]
        var buffers: [CVPixelBuffer] = []
        for (index, format) in formats.enumerated() {
            buffers.append(try makePixelBuffer(
                width: 18 + index * 8, height: 10 + index * 6,
                pixelFormat: format, bytesPerRowAlignment: 128 << index
            ))
        }
        for phase in 0..<3 {
            for buffer in phase.isMultiple(of: 2) ? buffers : Array(buffers.reversed()) {
                try fillPattern(buffer, phase: phase)
                try expectPattern(buffer, phase: phase)
            }
        }
    }

    @Test func rejectsUnsupportedPixelFormats() throws {
        let buffer = try makePixelBuffer(
            width: 16, height: 16, pixelFormat: kCVPixelFormatType_OneComponent8
        )
        #expect(VideoFrameColorSampler.sample(buffer) == nil)
    }

    private func isTenBit(_ format: OSType) -> Bool {
        format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            || format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
    }

    private func pattern(x: Int, y: Int, channel: Int, phase: Int, maximum: Int) -> Int {
        // Distinct axes and channels expose row-stride, plane and channel swaps.
        let xWeights = [13, 29, 43]
        let yWeights = [37, 7, 23]
        return (x * xWeights[channel] + y * yWeights[channel]
            + channel * 71 + phase * 59) % (maximum + 1)
    }

    private func fillPattern(_ buffer: CVPixelBuffer, phase: Int) throws {
        try withLockedPixelBuffer(buffer) {
            let format = CVPixelBufferGetPixelFormatType(buffer)
            if format == kCVPixelFormatType_32BGRA {
                let base = try #require(CVPixelBufferGetBaseAddress(buffer))
                let stride = CVPixelBufferGetBytesPerRow(buffer)
                memset(base, 0xA5, stride * CVPixelBufferGetHeight(buffer))
                for y in 0..<CVPixelBufferGetHeight(buffer) {
                    let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
                    for x in 0..<CVPixelBufferGetWidth(buffer) {
                        for channel in 0..<3 {
                            row[x * 4 + channel] = UInt8(pattern(
                                x: x, y: y, channel: channel, phase: phase, maximum: 255
                            ))
                        }
                        row[x * 4 + 3] = 0 // Sampling ignores alpha.
                    }
                }
                return
            }
            let tenBit = isTenBit(format)
            for plane in 0..<2 {
                let base = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, plane))
                let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
                let width = CVPixelBufferGetWidthOfPlane(buffer, plane)
                let height = CVPixelBufferGetHeightOfPlane(buffer, plane)
                memset(base, 0xA5, stride * height)
                let channels = plane == 0 ? 1 : 2
                for y in 0..<height {
                    let row = base.advanced(by: y * stride)
                    for x in 0..<width {
                        for channel in 0..<channels {
                            let value = pattern(
                                x: x, y: y, channel: plane + channel, phase: phase,
                                maximum: tenBit ? 1023 : 255
                            )
                            let index = x * channels + channel
                            if tenBit {
                                // The unused six bits must not influence the result.
                                row.assumingMemoryBound(to: UInt16.self)[index] = UInt16(value << 6) | 63
                            } else {
                                row.assumingMemoryBound(to: UInt8.self)[index] = UInt8(value)
                            }
                        }
                    }
                }
            }
        }
    }

    private func expectPattern(_ buffer: CVPixelBuffer, phase: Int) throws {
        let sample = try #require(VideoFrameColorSampler.sample(buffer))
        #expect(sample.columns == 12)
        #expect(sample.rows == 8)
        #expect(sample.colors.count == 96)
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let format = CVPixelBufferGetPixelFormatType(buffer)
        let tenBit = isTenBit(format)
        let fullRange = format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            || format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        for row in 0..<8 {
            for column in 0..<12 {
                // Integer cell centers are an independent oracle for this fixture.
                let x = (2 * column + 1) * width / 24
                let y = (2 * row + 1) * height / 16
                let expected: SampledVideoColor
                if format == kCVPixelFormatType_32BGRA {
                    expected = SampledVideoColor(
                        red: Double(pattern(x: x, y: y, channel: 2, phase: phase, maximum: 255)) / 255,
                        green: Double(pattern(x: x, y: y, channel: 1, phase: phase, maximum: 255)) / 255,
                        blue: Double(pattern(x: x, y: y, channel: 0, phase: phase, maximum: 255)) / 255
                    )
                } else {
                    let maximum = tenBit ? 1023 : 255
                    let codeY = Double(pattern(x: x, y: y, channel: 0, phase: phase, maximum: maximum))
                    let codeCb = Double(pattern(x: x / 2, y: y / 2, channel: 1, phase: phase, maximum: maximum))
                    let codeCr = Double(pattern(x: x / 2, y: y / 2, channel: 2, phase: phase, maximum: maximum))
                    let scale = tenBit ? 4.0 : 1.0
                    let luma = fullRange ? codeY / Double(maximum) : (codeY - 16 * scale) / (219 * scale)
                    let chromaRange = fullRange ? Double(maximum) : 224 * scale
                    let cb = (codeCb - 128 * scale) / chromaRange
                    let cr = (codeCr - 128 * scale) / chromaRange
                    // Unspecified matrix is BT.709. Derive independently in Double.
                    let kr = 0.2126, kb = 0.0722, kg = 1 - kr - kb
                    expected = SampledVideoColor(
                        red: luma + 2 * (1 - kr) * cr,
                        green: luma - 2 * kb * (1 - kb) / kg * cb - 2 * kr * (1 - kr) / kg * cr,
                        blue: luma + 2 * (1 - kb) * cb
                    )
                }
                let actual = sample.color(column: column, row: row)
                #expect(abs(actual.red - expected.red) < 0.00001)
                #expect(abs(actual.green - expected.green) < 0.00001)
                #expect(abs(actual.blue - expected.blue) < 0.00001)
            }
        }
    }

    private func makePixelBuffer(
        width: Int,
        height: Int,
        pixelFormat: OSType,
        bytesPerRowAlignment: Int = 64
    ) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            pixelFormat,
            [
                kCVPixelBufferIOSurfacePropertiesKey: [:],
                kCVPixelBufferBytesPerRowAlignmentKey: bytesPerRowAlignment,
            ] as CFDictionary,
            &pixelBuffer
        )
        #expect(status == kCVReturnSuccess)
        return try #require(pixelBuffer)
    }

    private func fillBGRA(
        _ pixelBuffer: CVPixelBuffer,
        red: UInt8,
        green: UInt8,
        blue: UInt8
    ) throws {
        try withLockedPixelBuffer(pixelBuffer) {
            let base = try #require(CVPixelBufferGetBaseAddress(pixelBuffer))
            let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
            for y in 0..<CVPixelBufferGetHeight(pixelBuffer) {
                for x in 0..<CVPixelBufferGetWidth(pixelBuffer) {
                    let pixel = base
                        .advanced(by: y * bytesPerRow + x * 4)
                        .assumingMemoryBound(to: UInt8.self)
                    pixel[0] = blue
                    pixel[1] = green
                    pixel[2] = red
                    pixel[3] = 255
                }
            }
        }
    }

    private func withLockedPixelBuffer(
        _ pixelBuffer: CVPixelBuffer,
        operation: () throws -> Void
    ) throws {
        #expect(CVPixelBufferLockBaseAddress(pixelBuffer, []) == kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        try operation()
    }
}
