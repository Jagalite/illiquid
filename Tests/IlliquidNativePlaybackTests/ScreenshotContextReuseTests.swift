import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import IlliquidCore
import Testing
@testable import IlliquidNativePlayback

@Suite("Screenshot context reuse", .serialized)
struct ScreenshotContextReuseTests {
    @Test func repeatedCapturesReadCurrentBytesFromTheSamePixelBuffer() throws {
        let buffer = try Self.makeBuffer(width: 32, height: 20)
        try Self.fillBGRA(buffer, variant: 0)
        let capture = Self.capture(buffer)
        let first = try Self.render(capture)

        try Self.fillBGRA(buffer, variant: 1)
        let changed = try Self.render(capture)
        #expect(changed != first)

        try Self.fillBGRA(buffer, variant: 0)
        #expect(try Self.render(capture) == first)
        #expect(try Self.render(capture) == first)
    }

    @Test func reusedBufferMatrixAttachmentsDoNotReusePreviousColors() throws {
        let buffer = try Self.makeBuffer(
            width: 16, height: 12,
            format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        )
        try Self.fillNV12(buffer)
        let capture = Self.capture(buffer)

        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey,
            kCVImageBufferYCbCrMatrix_ITU_R_601_4, .shouldPropagate)
        let rec601 = try Self.render(capture)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey,
            kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        let rec709 = try Self.render(capture)
        #expect(rec601 != rec709)

        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey,
            kCVImageBufferYCbCrMatrix_ITU_R_601_4, .shouldPropagate)
        #expect(try Self.render(capture) == rec601)
    }

    @Test func changesToGeometryDoNotCarryAcrossCaptures() throws {
        let buffer = try Self.makeBuffer(width: 32, height: 20)
        try Self.fillBGRA(buffer, variant: 0)
        let original = try Self.render(Self.capture(buffer))

        let mirrored = try Self.render(Self.capture(buffer, mirrored: true))
        #expect(mirrored == original.horizontallyMirrored())
        #expect(mirrored != original)

        // A square crop at the original pixel scale retains the middle 20
        // columns of this 32-by-20 image, with no resampling.
        let cropped = try Self.render(Self.capture(
            buffer, size: CGSize(width: 20, height: 20),
            adjustments: VideoAdjustmentState(crop: "1:1")
        ))
        #expect(cropped == original.columns(6..<26))

        let rotatedCapture = Self.capture(
            buffer, displaySize: CGSize(width: 20, height: 32),
            rotation: 90, size: CGSize(width: 20, height: 32)
        )
        let rotated = try Self.render(rotatedCapture)
        #expect(rotated.width == 20 && rotated.height == 32)
        #expect(try Self.render(Self.capture(buffer)) == original)
        #expect(try Self.render(rotatedCapture) == rotated)
        #expect(try Self.render(Self.capture(buffer, mirrored: true)) == mirrored)
    }

    @Test func paddedTextAndBitmapSubtitleRegionsRemainIndependentOfImageReuse() throws {
        let buffer = try Self.makeBuffer(width: 12, height: 12)
        try Self.withLocked(buffer) {
            let base = try #require(CVPixelBufferGetBaseAddress(buffer))
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            for y in 0..<12 {
                let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
                for x in 0..<12 {
                    row[x * 4] = 0
                    row[x * 4 + 1] = 0
                    row[x * 4 + 2] = 0
                    row[x * 4 + 3] = 255
                }
            }
        }
        let plain = try Self.render(Self.capture(buffer))
        let text = ASSRenderedRegion(
            bitmap: Data([255, 128, 0, 99, 99, 128, 255, 0, 99, 99]),
            color: 0xff000000, frame: CGRect(x: 2, y: 1, width: 3, height: 2),
            stride: 5
        )
        let bitmap = ASSRenderedRegion(
            bitmap: Data([
                255, 0, 0, 255, 255, 0, 0, 255, 99, 99, 99, 99,
                255, 0, 0, 255, 255, 0, 0, 255, 99, 99, 99, 99,
            ]),
            color: 0, frame: CGRect(x: 7, y: 7, width: 2, height: 2),
            stride: 12, bitmapSize: CGSize(width: 2, height: 2),
            isPremultipliedBGRA: true
        )
        let capture = Self.capture(buffer, regions: [text, bitmap])
        let composited = try Self.render(capture)
        let bytes = [UInt8](composited.rgba)
        let redPixels = (0..<(12 * 12)).filter {
            bytes[$0 * 4] > 64 && bytes[$0 * 4 + 1] == 0 && bytes[$0 * 4 + 2] == 0
        }
        let bluePixels = (0..<(12 * 12)).filter {
            bytes[$0 * 4] == 0 && bytes[$0 * 4 + 1] == 0 && bytes[$0 * 4 + 2] > 240
        }
        #expect(redPixels.count == 4)
        #expect(bluePixels.count == 4)
        #expect(Set(redPixels.map { $0 % 12 }) == [2, 3])
        #expect(Set(bluePixels.map { $0 % 12 }) == [7, 8])
        #expect(try Self.render(Self.capture(buffer)) == plain)
        #expect(try Self.render(capture) == composited)
    }

    @Test func concurrentImmutableCapturesMatchSerialPixels() async throws {
        let captures = try (0..<8).map { index in
            let buffer = try Self.makeBuffer(width: 24 + index * 2, height: 16 + index * 2)
            try Self.fillBGRA(buffer, variant: index)
            return Self.capture(buffer, mirrored: index.isMultiple(of: 2))
        }
        let expected = try captures.map { try Self.render($0) }
        let actual = try await withThrowingTaskGroup(of: (Int, Pixels).self) { group in
            for repetition in 0..<3 {
                for (index, capture) in captures.enumerated() {
                    group.addTask {
                        (repetition * captures.count + index, try Self.render(capture))
                    }
                }
            }
            var results: [(Int, Pixels)] = []
            for try await result in group { results.append(result) }
            return results.sorted { $0.0 < $1.0 }.map(\.1)
        }
        #expect(actual.count == captures.count * 3)
        for (index, pixels) in actual.enumerated() {
            #expect(pixels == expected[index % expected.count])
        }
    }

    @Test func invalidOutputDimensionsKeepTheExistingFailureContract() throws {
        let buffer = try Self.makeBuffer(width: 8, height: 8)
        for size in [
            CGSize.zero, CGSize(width: -1, height: 8), CGSize(width: 0.5, height: 8),
            CGSize(width: CGFloat.nan, height: 8), CGSize(width: 8, height: CGFloat.infinity),
            CGSize(width: 8193, height: 8), CGSize(width: 8, height: 8193),
            CGSize(width: 8192, height: 8192),
        ] {
            let capture = Self.capture(buffer, size: size)
            #expect(throws: PresentationError.self) { try capture.png() }
        }
    }

    private struct Pixels: Equatable, Sendable {
        let width: Int
        let height: Int
        let rgba: Data

        func horizontallyMirrored() -> Self {
            var result = Data()
            result.reserveCapacity(rgba.count)
            for y in 0..<height {
                for x in (0..<width).reversed() {
                    let offset = (y * width + x) * 4
                    result.append(rgba[offset..<(offset + 4)])
                }
            }
            return Self(width: width, height: height, rgba: result)
        }

        func columns(_ range: Range<Int>) -> Self {
            var result = Data()
            result.reserveCapacity(range.count * height * 4)
            for y in 0..<height {
                let lower = (y * width + range.lowerBound) * 4
                let upper = (y * width + range.upperBound) * 4
                result.append(rgba[lower..<upper])
            }
            return Self(width: range.count, height: height, rgba: result)
        }
    }

    private static func capture(
        _ buffer: CVPixelBuffer,
        displaySize: CGSize? = nil,
        rotation: Double = 0,
        mirrored: Bool = false,
        size: CGSize? = nil,
        adjustments: VideoAdjustmentState = .standard,
        regions: [ASSRenderedRegion] = []
    ) -> NativeScreenshot {
        let sourceSize = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
        return NativeScreenshot(
            buffer: buffer, displaySize: displaySize ?? sourceSize,
            rotation: rotation, mirrored: mirrored, size: size ?? sourceSize,
            adjustments: adjustments, regions: regions
        )
    }

    private static func render(_ capture: NativeScreenshot) throws -> Pixels {
        try autoreleasepool {
            let png = try capture.png()
            let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
            let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
            let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
            let context = try #require(CGContext(
                data: nil, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.interpolationQuality = .none
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return Pixels(width: image.width, height: image.height,
                rgba: Data(bytes: try #require(context.data), count: image.width * image.height * 4))
        }
    }

    private static func makeBuffer(
        width: Int, height: Int, format: OSType = kCVPixelFormatType_32BGRA
    ) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(nil, width, height, format, nil, &buffer)
        #expect(status == kCVReturnSuccess)
        return try #require(buffer)
    }

    private static func withLocked(_ buffer: CVPixelBuffer, _ body: () throws -> Void) throws {
        let status = CVPixelBufferLockBaseAddress(buffer, [])
        #expect(status == kCVReturnSuccess)
        guard status == kCVReturnSuccess else { return }
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        try body()
    }

    private static func fillBGRA(_ buffer: CVPixelBuffer, variant: Int) throws {
        try withLocked(buffer) {
            let base = try #require(CVPixelBufferGetBaseAddress(buffer))
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            for y in 0..<CVPixelBufferGetHeight(buffer) {
                let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
                for x in 0..<CVPixelBufferGetWidth(buffer) {
                    row[x * 4] = UInt8((x * 13 + y * 7 + variant * 31) % 256)
                    row[x * 4 + 1] = UInt8((x * 3 + y * 17 + variant * 53) % 256)
                    row[x * 4 + 2] = UInt8((x * 19 + y * 5 + variant * 71) % 256)
                    row[x * 4 + 3] = 255
                }
            }
        }
    }

    private static func fillNV12(_ buffer: CVPixelBuffer) throws {
        try withLocked(buffer) {
            let luma = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, 0))
            let chroma = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, 1))
            let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
            for y in 0..<CVPixelBufferGetHeightOfPlane(buffer, 0) {
                let row = luma.advanced(by: y * lumaStride).assumingMemoryBound(to: UInt8.self)
                for x in 0..<CVPixelBufferGetWidthOfPlane(buffer, 0) { row[x] = 126 }
            }
            for y in 0..<CVPixelBufferGetHeightOfPlane(buffer, 1) {
                let row = chroma.advanced(by: y * chromaStride).assumingMemoryBound(to: UInt8.self)
                for x in 0..<CVPixelBufferGetWidthOfPlane(buffer, 1) {
                    row[x * 2] = 100
                    row[x * 2 + 1] = 170
                }
            }
        }
    }
}
