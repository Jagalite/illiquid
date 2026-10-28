import CoreVideo
import Foundation
import IlliquidCore
import Testing
@testable import IlliquidNativePlayback

@Suite("Video frame color sampler layouts")
struct VideoFrameColorSamplerLayoutTests {
    @Test func samplesEveryCellAcrossPaddedPixelLayouts() throws {
        for layout in Layout.allCases {
            for (width, height) in [(2, 2), (26, 18)] {
                let buffer = try makeBuffer(
                    width: width, height: height, layout: layout, alignment: 128
                )
                try fill(buffer, layout: layout, seed: 7)
                let payloadBytes = width * (layout == .bgra ? 4 : layout.componentBytes)
                #expect(firstPlaneStride(buffer) > payloadBytes)
                let sample = try #require(VideoFrameColorSampler.sample(buffer))
                verify(sample, width: width, height: height, layout: layout, seed: 7)
            }
        }
    }

    @Test func alternatingBuffersResolveTheirOwnAddressesAndStrides() throws {
        let sampler = VideoFrameColorSampler(
            minimumInterval: 0, smoothingTimeConstant: 0
        )
        var now: UInt64 = 1_000_000_000
        for layout in Layout.allCases {
            let first = try makeBuffer(
                width: 26, height: 18, layout: layout, alignment: 128
            )
            let second = try makeBuffer(
                width: 130, height: 22, layout: layout, alignment: 256
            )
            try fill(first, layout: layout, seed: 3)
            try fill(second, layout: layout, seed: 19)
            #expect(firstPlaneStride(first) != firstPlaneStride(second))
            for (buffer, width, height, seed) in [
                (first, 26, 18, 3), (second, 130, 22, 19), (first, 26, 18, 3),
            ] {
                let sample = try #require(sampler.sampleIfNeeded(
                    buffer, uptimeNanoseconds: now
                ))
                verify(sample, width: width, height: height, layout: layout, seed: seed)
                now += 250_000_000
            }
        }
    }

    @Test func unsupportedARGBLayoutReturnsNoSample() throws {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, 26, 18, kCVPixelFormatType_32ARGB,
            nil, &buffer
        )
        #expect(status == kCVReturnSuccess)
        #expect(VideoFrameColorSampler.sample(try #require(buffer)) == nil)
    }

    private enum Layout: CaseIterable {
        case bgra, nv12Video, nv12Full, p010Video, p010Full

        var pixelFormat: OSType {
            switch self {
            case .bgra: kCVPixelFormatType_32BGRA
            case .nv12Video: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            case .nv12Full: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            case .p010Video: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            case .p010Full: kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
            }
        }

        var componentBytes: Int {
            self == .p010Video || self == .p010Full ? 2 : 1
        }

        var isFullRange: Bool { self == .nv12Full || self == .p010Full }
        var maximumCode: Int { componentBytes == 2 ? 1023 : 255 }
    }

    private func makeBuffer(
        width: Int, height: Int, layout: Layout, alignment: Int
    ) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, layout.pixelFormat,
            [
                kCVPixelBufferIOSurfacePropertiesKey: [:],
                kCVPixelBufferBytesPerRowAlignmentKey: alignment,
            ] as CFDictionary,
            &buffer
        )
        #expect(status == kCVReturnSuccess)
        return try #require(buffer)
    }

    private func firstPlaneStride(_ buffer: CVPixelBuffer) -> Int {
        CVPixelBufferIsPlanar(buffer)
            ? CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            : CVPixelBufferGetBytesPerRow(buffer)
    }

    // Deliberately vary both axes and every channel so a swapped chroma
    // component, tight-row assumption, or incorrect grid coordinate is visible.
    private func code(
        x: Int, y: Int, channel: Int, seed: Int, maximum: Int
    ) -> Int {
        (x * (17 + channel * 12) + y * (31 + channel * 7)
            + seed * (43 + channel * 18)) % (maximum + 1)
    }

    private func fill(
        _ buffer: CVPixelBuffer, layout: Layout, seed: Int
    ) throws {
        let status = CVPixelBufferLockBaseAddress(buffer, [])
        try #require(status == kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        if layout == .bgra {
            let base = try #require(CVPixelBufferGetBaseAddress(buffer))
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            memset(base, 0xCD, stride * height)
            for y in 0..<height {
                let row = base.advanced(by: y * stride)
                    .assumingMemoryBound(to: UInt8.self)
                for x in 0..<width {
                    for channel in 0..<3 {
                        row[x * 4 + channel] = UInt8(code(
                            x: x, y: y, channel: channel, seed: seed, maximum: 255
                        ))
                    }
                    row[x * 4 + 3] = UInt8((x + y + seed) % 256)
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
            #expect(planeWidth == (plane == 0 ? width : width / 2))
            #expect(planeHeight == (plane == 0 ? height : height / 2))
            let channels = plane == 0 ? 1 : 2
            #expect(stride > planeWidth * channels * layout.componentBytes)
            memset(base, 0xCD, stride * planeHeight)
            for y in 0..<planeHeight {
                let row = base.advanced(by: y * stride)
                for x in 0..<planeWidth {
                    for component in 0..<channels {
                        let value = code(
                            x: x, y: y,
                            channel: plane == 0 ? 0 : component + 1,
                            seed: seed, maximum: layout.maximumCode
                        )
                        let offset = x * channels + component
                        if layout.componentBytes == 2 {
                            // Nonzero unused bits prove P010 samples are shifted
                            // down before conversion, not treated as raw words.
                            let unusedBits = 1 + (x + y + component + seed) % 63
                            row.assumingMemoryBound(to: UInt16.self)[offset] =
                                UInt16((value << 6) | unusedBits)
                        } else {
                            row.assumingMemoryBound(to: UInt8.self)[offset] = UInt8(value)
                        }
                    }
                }
            }
        }
    }

    private func verify(
        _ sample: VideoColorSample, width: Int, height: Int,
        layout: Layout, seed: Int
    ) {
        #expect(sample.columns == 12)
        #expect(sample.rows == 8)
        #expect(sample.colors.count == 96)
        for row in 0..<8 {
            for column in 0..<12 {
                // Integer rational arithmetic is independent of the sampler's
                // normalized floating-point coordinate calculation.
                let x = (2 * column + 1) * width / 24
                let y = (2 * row + 1) * height / 16
                let expected = referenceColor(x: x, y: y, layout: layout, seed: seed)
                let actual = sample.color(column: column, row: row)
                #expect(abs(actual.red - expected.red) < 0.000001)
                #expect(abs(actual.green - expected.green) < 0.000001)
                #expect(abs(actual.blue - expected.blue) < 0.000001)
            }
        }
    }

    private func referenceColor(
        x: Int, y: Int, layout: Layout, seed: Int
    ) -> (red: Double, green: Double, blue: Double) {
        if layout == .bgra {
            return (
                Double(code(x: x, y: y, channel: 2, seed: seed, maximum: 255)) / 255,
                Double(code(x: x, y: y, channel: 1, seed: seed, maximum: 255)) / 255,
                Double(code(x: x, y: y, channel: 0, seed: seed, maximum: 255)) / 255
            )
        }
        let tenBit = layout.componentBytes == 2
        let lumaMinimum: Double = layout.isFullRange ? 0 : (tenBit ? 64 : 16)
        let lumaSpan = layout.isFullRange
            ? Double(layout.maximumCode) : (tenBit ? 876.0 : 219.0)
        let chromaCenter = tenBit ? 512.0 : 128.0
        let chromaSpan = layout.isFullRange
            ? Double(layout.maximumCode) : (tenBit ? 896.0 : 224.0)
        let luma = (Double(code(
            x: x, y: y, channel: 0, seed: seed, maximum: layout.maximumCode
        )) - lumaMinimum) / lumaSpan
        let cb = (Double(code(
            x: x / 2, y: y / 2, channel: 1, seed: seed, maximum: layout.maximumCode
        )) - chromaCenter) / chromaSpan
        let cr = (Double(code(
            x: x / 2, y: y / 2, channel: 2, seed: seed, maximum: layout.maximumCode
        )) - chromaCenter) / chromaSpan

        // Independent BT.709 equations; do not use PiPVideoMapping or the
        // sampler's conversion helper to compute the expected colors.
        let kr = 0.2126
        let kb = 0.0722
        let kg = 1 - kr - kb
        func clamp(_ value: Double) -> Double { min(1, max(0, value)) }
        return (
            clamp(luma + 2 * (1 - kr) * cr),
            clamp(luma - 2 * kb * (1 - kb) / kg * cb
                - 2 * kr * (1 - kr) / kg * cr),
            clamp(luma + 2 * (1 - kb) * cb)
        )
    }
}
