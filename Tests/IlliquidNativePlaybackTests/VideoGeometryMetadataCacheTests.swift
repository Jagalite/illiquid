import CoreVideo
import Foundation
import Testing
@testable import IlliquidNativePlayback

@Suite("Video geometry metadata attachments")
struct VideoGeometryMetadataCacheTests {
    @Test func attachesIntegerPixelAspectToEveryRotatingBuffer() throws {
        let cache = VideoGeometryMetadataCache()
        let buffers = try (0..<3).map { _ in try makeBuffer() }

        for index in 0..<12 {
            let buffer = buffers[index % buffers.count]
            cache.applyPixelAspectMetadata(
                pixelBuffer: buffer,
                pixelAspect: CGSize(width: 40, height: 33)
            )
            try expectAspect(buffer, horizontal: 40, vertical: 33)
        }
    }

    @Test func roundsPixelAspectComponentsIndependently() throws {
        let cache = VideoGeometryMetadataCache()
        let buffer = try makeBuffer()
        let cases: [(Double, Double, Int, Int)] = [
            (1.49, 2.49, 1, 2),
            (1.5, 2.5, 2, 3),
            (1.51, 2.51, 2, 3),
            (0.1, 0.49, 0, 0),
            (0.5, 0.5, 1, 1),
            (65_535, 32_767, 65_535, 32_767),
        ]

        for (width, height, horizontal, vertical) in cases {
            cache.applyPixelAspectMetadata(
                pixelBuffer: buffer,
                pixelAspect: CGSize(width: width, height: height)
            )
            try expectAspect(buffer, horizontal: horizontal, vertical: vertical)
        }
    }

    @Test func replacesPixelAspectWhenEitherComponentChangesAndWhenRevisited() throws {
        let cache = VideoGeometryMetadataCache()
        let buffer = try makeBuffer()

        for (horizontal, vertical) in [(4, 3), (8, 3), (8, 6), (4, 3), (1, 1)] {
            cache.applyPixelAspectMetadata(
                pixelBuffer: buffer,
                pixelAspect: CGSize(width: horizontal, height: vertical)
            )
            try expectAspect(buffer, horizontal: horizontal, vertical: vertical)
        }
    }

    @Test func invalidPixelAspectsLeaveNewBuffersWithoutAnAttachment() throws {
        let cache = VideoGeometryMetadataCache()
        let buffer = try makeBuffer()
        #expect(CVBufferCopyAttachment(buffer, kCVImageBufferPixelAspectRatioKey, nil) == nil)

        for aspect in invalidAspects {
            cache.applyPixelAspectMetadata(pixelBuffer: buffer, pixelAspect: aspect)
            #expect(CVBufferCopyAttachment(buffer, kCVImageBufferPixelAspectRatioKey, nil) == nil)
        }
    }

    @Test func invalidPixelAspectsPreserveExistingValuesAndPropagationMode() throws {
        let cache = VideoGeometryMetadataCache()
        let warmBuffer = try makeBuffer()
        cache.applyPixelAspectMetadata(
            pixelBuffer: warmBuffer,
            pixelAspect: CGSize(width: 4, height: 3)
        )
        let buffer = try makeBuffer()
        let previous: [CFString: Any] = [
            kCVImageBufferPixelAspectRatioHorizontalSpacingKey: 17,
            kCVImageBufferPixelAspectRatioVerticalSpacingKey: 19,
            "preserved-marker" as CFString: "existing attachment",
        ]
        CVBufferSetAttachment(
            buffer, kCVImageBufferPixelAspectRatioKey,
            previous as CFDictionary, .shouldNotPropagate
        )

        for aspect in invalidAspects {
            cache.applyPixelAspectMetadata(pixelBuffer: buffer, pixelAspect: aspect)
            try expectAttachment(
                buffer, key: kCVImageBufferPixelAspectRatioKey,
                expected: previous, mode: .shouldNotPropagate
            )
        }

        cache.applyPixelAspectMetadata(
            pixelBuffer: buffer,
            pixelAspect: CGSize(width: 4, height: 3)
        )
        try expectAspect(buffer, horizontal: 4, vertical: 3)
    }

    @Test func reappliesPixelAspectAfterAttachmentRemovalOrReplacement() throws {
        let cache = VideoGeometryMetadataCache()
        let buffer = try makeBuffer()
        let aspect = CGSize(width: 16, height: 15)
        cache.applyPixelAspectMetadata(pixelBuffer: buffer, pixelAspect: aspect)
        CVBufferRemoveAttachment(buffer, kCVImageBufferPixelAspectRatioKey)
        cache.applyPixelAspectMetadata(pixelBuffer: buffer, pixelAspect: aspect)
        try expectAspect(buffer, horizontal: 16, vertical: 15)

        let stale: [CFString: Any] = [
            kCVImageBufferPixelAspectRatioHorizontalSpacingKey: 1,
            kCVImageBufferPixelAspectRatioVerticalSpacingKey: 1,
        ]
        CVBufferSetAttachment(
            buffer, kCVImageBufferPixelAspectRatioKey,
            stale as CFDictionary, .shouldNotPropagate
        )
        cache.applyPixelAspectMetadata(pixelBuffer: buffer, pixelAspect: aspect)
        try expectAspect(buffer, horizontal: 16, vertical: 15)
    }

    @Test func attachesApertureToEveryRotatingBuffer() throws {
        let cache = VideoGeometryMetadataCache()
        let buffers = try (0..<3).map { _ in try makeBuffer() }

        for index in 0..<12 {
            let buffer = buffers[index % buffers.count]
            cache.applyCleanApertureMetadata(
                pixelBuffer: buffer, width: 1920, height: 1080,
                horizontalOffset: -0.5, verticalOffset: 1.25
            )
            try expectAperture(
                buffer, width: 1920, height: 1080,
                horizontalOffset: -0.5, verticalOffset: 1.25
            )
        }
    }

    @Test func changesEveryApertureFieldIndependentlyAndRevisitsEarlierGeometry() throws {
        let cache = VideoGeometryMetadataCache()
        let buffer = try makeBuffer()
        let cases: [(Int, Int, Double, Double)] = [
            (1920, 1080, -0.5, 0.25),
            (1918, 1080, -0.5, 0.25),
            (1918, 1078, -0.5, 0.25),
            (1918, 1078, 0.5, 0.25),
            (1918, 1078, 0.5, -0.25),
            (1920, 1080, -0.5, 0.25),
        ]

        for (width, height, horizontalOffset, verticalOffset) in cases {
            cache.applyCleanApertureMetadata(
                pixelBuffer: buffer, width: width, height: height,
                horizontalOffset: horizontalOffset, verticalOffset: verticalOffset
            )
            try expectAperture(
                buffer, width: width, height: height,
                horizontalOffset: horizontalOffset, verticalOffset: verticalOffset
            )
        }
    }

    @Test func preservesSignedZeroOffsetsWhenTheyChangeAndReturn() throws {
        let cache = VideoGeometryMetadataCache()
        let buffer = try makeBuffer()
        let cases: [(Double, Double)] = [
            (0.0, 0.0), (-0.0, 0.0), (-0.0, -0.0),
            (0.0, -0.0), (0.0, 0.0), (-0.0, 0.0),
        ]

        for (horizontalOffset, verticalOffset) in cases {
            cache.applyCleanApertureMetadata(
                pixelBuffer: buffer, width: 1920, height: 1080,
                horizontalOffset: horizontalOffset, verticalOffset: verticalOffset
            )
            try expectAperture(
                buffer, width: 1920, height: 1080,
                horizontalOffset: horizontalOffset, verticalOffset: verticalOffset
            )
            let actual = try #require(CVBufferCopyAttachment(
                buffer, kCVImageBufferCleanApertureKey, nil
            ) as? [CFString: Any])
            for (key, offset) in [
                (kCVImageBufferCleanApertureHorizontalOffsetKey, horizontalOffset),
                (kCVImageBufferCleanApertureVerticalOffsetKey, verticalOffset),
            ] {
                let number = try #require(actual[key] as? NSNumber)
                #expect(number.doubleValue.bitPattern == NSNumber(value: offset).doubleValue.bitPattern)
            }
        }
    }

    @Test func reappliesApertureAfterAttachmentRemovalOrReplacement() throws {
        let cache = VideoGeometryMetadataCache()
        let buffer = try makeBuffer()
        cache.applyCleanApertureMetadata(
            pixelBuffer: buffer, width: 720, height: 480,
            horizontalOffset: -2.5, verticalOffset: 3.5
        )
        CVBufferRemoveAttachment(buffer, kCVImageBufferCleanApertureKey)
        cache.applyCleanApertureMetadata(
            pixelBuffer: buffer, width: 720, height: 480,
            horizontalOffset: -2.5, verticalOffset: 3.5
        )
        try expectAperture(
            buffer, width: 720, height: 480,
            horizontalOffset: -2.5, verticalOffset: 3.5
        )

        let stale: [CFString: Any] = [
            kCVImageBufferCleanApertureWidthKey: 1,
            kCVImageBufferCleanApertureHeightKey: 1,
            kCVImageBufferCleanApertureHorizontalOffsetKey: 0.0,
            kCVImageBufferCleanApertureVerticalOffsetKey: 0.0,
            "stale-extra-key" as CFString: true,
        ]
        CVBufferSetAttachment(
            buffer, kCVImageBufferCleanApertureKey,
            stale as CFDictionary, .shouldNotPropagate
        )
        cache.applyCleanApertureMetadata(
            pixelBuffer: buffer, width: 720, height: 480,
            horizontalOffset: -2.5, verticalOffset: 3.5
        )
        try expectAperture(
            buffer, width: 720, height: 480,
            horizontalOffset: -2.5, verticalOffset: 3.5
        )
    }

    @Test func aspectAndApertureUpdatesPreserveIndependentAttachments() throws {
        let cache = VideoGeometryMetadataCache()
        let buffer = try makeBuffer()
        CVBufferSetAttachment(
            buffer, kCVImageBufferYCbCrMatrixKey,
            kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldNotPropagate
        )
        cache.applyPixelAspectMetadata(
            pixelBuffer: buffer, pixelAspect: CGSize(width: 40, height: 33)
        )
        cache.applyCleanApertureMetadata(
            pixelBuffer: buffer, width: 704, height: 480,
            horizontalOffset: -0.5, verticalOffset: 0.5
        )
        cache.applyPixelAspectMetadata(
            pixelBuffer: buffer, pixelAspect: CGSize(width: 1, height: 1)
        )
        try expectAperture(
            buffer, width: 704, height: 480,
            horizontalOffset: -0.5, verticalOffset: 0.5
        )
        cache.applyCleanApertureMetadata(
            pixelBuffer: buffer, width: 1280, height: 720,
            horizontalOffset: 0.25, verticalOffset: -0.75
        )
        try expectAspect(buffer, horizontal: 1, vertical: 1)
        try expectAperture(
            buffer, width: 1280, height: 720,
            horizontalOffset: 0.25, verticalOffset: -0.75
        )
        var mode = CVAttachmentMode.shouldPropagate
        let matrix = try #require(CVBufferCopyAttachment(
            buffer, kCVImageBufferYCbCrMatrixKey, &mode
        ))
        #expect(CFEqual(matrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2))
        #expect(mode == .shouldNotPropagate)
    }

    @Test func cacheInstancesDoNotCarryGeometryBetweenDecoders() throws {
        let first = VideoGeometryMetadataCache()
        let second = VideoGeometryMetadataCache()
        let buffer = try makeBuffer()

        for (cache, horizontal, vertical) in [(first, 16, 15), (second, 4, 3), (first, 16, 15)] {
            cache.applyPixelAspectMetadata(
                pixelBuffer: buffer,
                pixelAspect: CGSize(width: horizontal, height: vertical)
            )
            try expectAspect(buffer, horizontal: horizontal, vertical: vertical)
        }
    }

    @Test func retainedBuffersKeepEarlierAndCurrentGeometryAfterCacheRelease() throws {
        let earlier = try makeBuffer()
        let current = try makeBuffer()
        weak var releasedCache: VideoGeometryMetadataCache?
        do {
            let cache = VideoGeometryMetadataCache()
            releasedCache = cache
            cache.applyPixelAspectMetadata(
                pixelBuffer: earlier, pixelAspect: CGSize(width: 40, height: 33)
            )
            cache.applyCleanApertureMetadata(
                pixelBuffer: earlier, width: 720, height: 480,
                horizontalOffset: -0.5, verticalOffset: 1.25
            )
            cache.applyPixelAspectMetadata(
                pixelBuffer: current, pixelAspect: CGSize(width: 1, height: 1)
            )
            cache.applyCleanApertureMetadata(
                pixelBuffer: current, width: 1920, height: 1080,
                horizontalOffset: 0.25, verticalOffset: -0.75
            )
        }
        #expect(releasedCache == nil)
        try expectAspect(earlier, horizontal: 40, vertical: 33)
        try expectAperture(
            earlier, width: 720, height: 480,
            horizontalOffset: -0.5, verticalOffset: 1.25
        )
        try expectAspect(current, horizontal: 1, vertical: 1)
        try expectAperture(
            current, width: 1920, height: 1080,
            horizontalOffset: 0.25, verticalOffset: -0.75
        )
    }

    private var invalidAspects: [CGSize] {
        let values: [Double] = [0, -1, .nan, .infinity, -.infinity]
        return values.flatMap { value in
            [CGSize(width: value, height: 1), CGSize(width: 1, height: value)]
        }
    }

    private func makeBuffer() throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, 2, 2, kCVPixelFormatType_32BGRA,
            nil, &buffer
        )
        #expect(status == kCVReturnSuccess)
        return try #require(buffer)
    }

    private func expectAspect(
        _ buffer: CVPixelBuffer,
        horizontal: Int,
        vertical: Int
    ) throws {
        let expected: [CFString: Any] = [
            kCVImageBufferPixelAspectRatioHorizontalSpacingKey: horizontal,
            kCVImageBufferPixelAspectRatioVerticalSpacingKey: vertical,
        ]
        try expectAttachment(
            buffer, key: kCVImageBufferPixelAspectRatioKey,
            expected: expected, mode: .shouldPropagate
        )
        let actual = try #require(CVBufferCopyAttachment(
            buffer, kCVImageBufferPixelAspectRatioKey, nil
        ) as? [CFString: Any])
        #expect(actual[kCVImageBufferPixelAspectRatioHorizontalSpacingKey] as? Int == horizontal)
        #expect(actual[kCVImageBufferPixelAspectRatioVerticalSpacingKey] as? Int == vertical)
    }

    private func expectAperture(
        _ buffer: CVPixelBuffer,
        width: Int,
        height: Int,
        horizontalOffset: Double,
        verticalOffset: Double
    ) throws {
        let expected: [CFString: Any] = [
            kCVImageBufferCleanApertureWidthKey: width,
            kCVImageBufferCleanApertureHeightKey: height,
            kCVImageBufferCleanApertureHorizontalOffsetKey: horizontalOffset,
            kCVImageBufferCleanApertureVerticalOffsetKey: verticalOffset,
        ]
        try expectAttachment(
            buffer, key: kCVImageBufferCleanApertureKey,
            expected: expected, mode: .shouldPropagate
        )
        let actual = try #require(CVBufferCopyAttachment(
            buffer, kCVImageBufferCleanApertureKey, nil
        ) as? [CFString: Any])
        #expect(actual[kCVImageBufferCleanApertureWidthKey] as? Int == width)
        #expect(actual[kCVImageBufferCleanApertureHeightKey] as? Int == height)
        #expect(actual[kCVImageBufferCleanApertureHorizontalOffsetKey] as? Double == horizontalOffset)
        #expect(actual[kCVImageBufferCleanApertureVerticalOffsetKey] as? Double == verticalOffset)
    }

    private func expectAttachment(
        _ buffer: CVPixelBuffer,
        key: CFString,
        expected: [CFString: Any],
        mode expectedMode: CVAttachmentMode
    ) throws {
        var mode = CVAttachmentMode.shouldNotPropagate
        let attachment = try #require(CVBufferCopyAttachment(buffer, key, &mode))
        #expect(CFGetTypeID(attachment) == CFDictionaryGetTypeID())
        let values = try #require(attachment as? [CFString: Any])
        #expect(Set(values.keys) == Set(expected.keys))
        #expect(CFEqual(attachment, expected as CFDictionary))
        #expect(mode == expectedMode)
    }
}
