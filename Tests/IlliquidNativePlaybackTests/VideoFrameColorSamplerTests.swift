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

    @Test(arguments: [
        kCVPixelFormatType_32BGRA,
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
        kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
    ])
    func samplesPaddedPlanesAndRereadsMutatedBuffers(pixelFormat: OSType) throws {
        // Tiny inputs repeat pixels across the grid; non-grid-aligned inputs
        // exercise row addressing and 4:2:0 chroma coordinates.
        var sizes = [(2, 2), (26, 18)]
        if pixelFormat == kCVPixelFormatType_32BGRA { sizes += [(1, 1), (17, 9)] }
        for (width, height) in sizes {
            let buffer = try makePixelBuffer(width: width, height: height,
                pixelFormat: pixelFormat, bytesPerRowAlignment: 256)
            try fillPattern(buffer, phase: 0)
            let first = try #require(VideoFrameColorSampler.sample(buffer))
            expectPattern(first, width: width, height: height, format: pixelFormat, phase: 0)

            // The next lock must see new bytes. The earlier value owns its
            // sampled colors and must remain unchanged after the source edit.
            try fillPattern(buffer, phase: 1)
            let second = try #require(VideoFrameColorSampler.sample(buffer))
            expectPattern(second, width: width, height: height, format: pixelFormat, phase: 1)
            expectPattern(first, width: width, height: height, format: pixelFormat, phase: 0)
            #expect(first != second)
        }
    }

    @Test func unsupportedPixelFormatReturnsNil() throws {
        let buffer = try makePixelBuffer(width: 48, height: 32,
            pixelFormat: kCVPixelFormatType_OneComponent8)
        #expect(VideoFrameColorSampler.sample(buffer) == nil)
    }

    private func patternValue(x: Int, y: Int, component: Int, phase: Int, maximum: Int) -> Int {
        (x * 29 + y * 43 + component * 71 + phase * 97) % (maximum + 1)
    }

    private func fillPattern(_ buffer: CVPixelBuffer, phase: Int) throws {
        let format = CVPixelBufferGetPixelFormatType(buffer)
        let tenBit = format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            || format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        try withLockedPixelBuffer(buffer) {
            if format == kCVPixelFormatType_32BGRA {
                let base = try #require(CVPixelBufferGetBaseAddress(buffer))
                let stride = CVPixelBufferGetBytesPerRow(buffer)
                let width = CVPixelBufferGetWidth(buffer)
                #expect(stride > width * 4)
                for y in 0..<CVPixelBufferGetHeight(buffer) {
                    let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
                    memset(row, phase == 0 ? 0xCD : 0x36, stride)
                    for x in 0..<width {
                        for component in 0..<3 {
                            row[x * 4 + component] = UInt8(patternValue(x: x, y: y,
                                component: component, phase: phase, maximum: 255))
                        }
                        row[x * 4 + 3] = 255
                    }
                }
                return
            }

            for plane in 0..<2 {
                let base = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, plane))
                let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
                let width = CVPixelBufferGetWidthOfPlane(buffer, plane)
                let components = plane == 0 ? 1 : 2
                #expect(stride > width * components * (tenBit ? 2 : 1))
                for y in 0..<CVPixelBufferGetHeightOfPlane(buffer, plane) {
                    let row = base.advanced(by: y * stride)
                    memset(row, phase == 0 ? 0xCD : 0x36, stride)
                    for x in 0..<width {
                        for component in 0..<components {
                            let value = patternValue(x: x, y: y,
                                component: plane == 0 ? 0 : component + 1,
                                phase: phase, maximum: tenBit ? 1023 : 255)
                            if tenBit {
                                // The low six bits are not part of P010's sample.
                                row.assumingMemoryBound(to: UInt16.self)[x * components + component]
                                    = UInt16(value << 6) | 0x2D
                            } else {
                                row.assumingMemoryBound(to: UInt8.self)[x * components + component]
                                    = UInt8(value)
                            }
                        }
                    }
                }
            }
        }
    }

    private func expectPattern(
        _ sample: VideoColorSample, width: Int, height: Int, format: OSType, phase: Int
    ) {
        #expect(sample.columns == 12)
        #expect(sample.rows == 8)
        let tenBit = format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            || format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        let fullRange = format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            || format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        for row in 0..<8 {
            let y = min(height - 1, (2 * row + 1) * height / 16)
            for column in 0..<12 {
                let x = min(width - 1, (2 * column + 1) * width / 24)
                let expected: SampledVideoColor
                if format == kCVPixelFormatType_32BGRA {
                    expected = SampledVideoColor(
                        red: Double(patternValue(x: x, y: y, component: 2, phase: phase, maximum: 255)) / 255,
                        green: Double(patternValue(x: x, y: y, component: 1, phase: phase, maximum: 255)) / 255,
                        blue: Double(patternValue(x: x, y: y, component: 0, phase: phase, maximum: 255)) / 255
                    )
                } else {
                    let maximum = tenBit ? 1023 : 255
                    let rawY = Double(patternValue(x: x, y: y, component: 0, phase: phase, maximum: maximum))
                    let rawCb = Double(patternValue(x: x / 2, y: y / 2, component: 1, phase: phase, maximum: maximum))
                    let rawCr = Double(patternValue(x: x / 2, y: y / 2, component: 2, phase: phase, maximum: maximum))
                    let normalizedY = fullRange ? rawY / Double(maximum)
                        : (rawY - (tenBit ? 64 : 16)) / (tenBit ? 876 : 219)
                    let cb = (rawCb - (tenBit ? 512 : 128))
                        / (fullRange ? Double(maximum) : (tenBit ? 896 : 224))
                    let cr = (rawCr - (tenBit ? 512 : 128))
                        / (fullRange ? Double(maximum) : (tenBit ? 896 : 224))
                    // Independent BT.709 reference. The sampler deliberately
                    // rounds its coefficients through Float, hence the tolerance.
                    let kr = 0.2126, kb = 0.0722, kg = 1 - kr - kb
                    expected = SampledVideoColor(
                        red: normalizedY + 2 * (1 - kr) * cr,
                        green: normalizedY - 2 * kb * (1 - kb) / kg * cb - 2 * kr * (1 - kr) / kg * cr,
                        blue: normalizedY + 2 * (1 - kb) * cb
                    )
                }
                let actual = sample.color(column: column, row: row)
                #expect(abs(actual.red - expected.red) < 0.000001)
                #expect(abs(actual.green - expected.green) < 0.000001)
                #expect(abs(actual.blue - expected.blue) < 0.000001)
            }
        }
    }

    private func makePixelBuffer(
        width: Int,
        height: Int,
        pixelFormat: OSType,
        bytesPerRowAlignment: Int? = nil
    ) throws -> CVPixelBuffer {
        var attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:]]
        if let bytesPerRowAlignment {
            attributes[kCVPixelBufferBytesPerRowAlignmentKey] = bytesPerRowAlignment
        }
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            pixelFormat,
            attributes as CFDictionary,
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
