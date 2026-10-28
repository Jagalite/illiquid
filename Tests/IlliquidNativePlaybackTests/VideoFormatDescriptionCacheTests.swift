import CoreMedia
import CoreVideo
import Foundation
import Testing
@testable import IlliquidNativePlayback

@Suite("Video format description reuse")
struct VideoFormatDescriptionCacheTests {
    @Test func reusesEqualFormatsAcrossDistinctBuffers() throws {
        let cache = VideoFormatDescriptionCache()
        var creations = 0
        var first: CMVideoFormatDescription?
        for _ in 0..<12 {
            let image = try Self.makeBuffer()
            CVBufferSetAttachment(image, kCVImageBufferColorPrimariesKey,
                                  kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
            let aspect: [CFString: Int] = [
                kCVImageBufferPixelAspectRatioHorizontalSpacingKey: 4,
                kCVImageBufferPixelAspectRatioVerticalSpacingKey: 3,
            ]
            CVBufferSetAttachment(image, kCVImageBufferPixelAspectRatioKey,
                                  aspect as CFDictionary, .shouldPropagate)
            let actual = try cache.resolve(for: image) {
                creations += 1
                return try Self.makeDescription(image)
            }
            if let first { #expect(actual === first) } else { first = actual }
            try Self.expectFreshEquivalent(actual, image: image)
        }
        #expect(creations == 1)
    }

    @Test func changedAddedAndRemovedAttachmentsMatchFreshDescriptions() throws {
        let cache = VideoFormatDescriptionCache()
        let image = try Self.makeBuffer()
        let aspect: [CFString: Int] = [
            kCVImageBufferPixelAspectRatioHorizontalSpacingKey: 40,
            kCVImageBufferPixelAspectRatioVerticalSpacingKey: 33,
        ]
        let aperture: [CFString: Any] = [
            kCVImageBufferCleanApertureWidthKey: 60,
            kCVImageBufferCleanApertureHeightKey: 44,
            kCVImageBufferCleanApertureHorizontalOffsetKey: -0.5,
            kCVImageBufferCleanApertureVerticalOffsetKey: 0.5,
        ]
        let mastering = Data([
            0x33, 0xc2, 0x86, 0xc4, 0x1d, 0x4c, 0x0b, 0xb8,
            0x84, 0xd0, 0x3e, 0x80, 0x3d, 0x13, 0x40, 0x42,
            0x00, 0x98, 0x96, 0x80, 0x00, 0x00, 0x00, 0x32,
        ])
        var changedMastering = mastering
        changedMastering[23] = 0x33
        let cases: [(CFString, [CFTypeRef])] = [
            (kCVImageBufferColorPrimariesKey, [
                kCVImageBufferColorPrimaries_ITU_R_709_2,
                kCVImageBufferColorPrimaries_ITU_R_2020]),
            (kCVImageBufferTransferFunctionKey, [
                kCVImageBufferTransferFunction_ITU_R_709_2,
                kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ]),
            (kCVImageBufferYCbCrMatrixKey, [
                kCVImageBufferYCbCrMatrix_ITU_R_709_2,
                kCVImageBufferYCbCrMatrix_ITU_R_2020]),
            (kCVImageBufferChromaLocationTopFieldKey, [
                kCVImageBufferChromaLocation_Left, kCVImageBufferChromaLocation_Center]),
            (kCVImageBufferPixelAspectRatioKey, [aspect as CFDictionary]),
            (kCVImageBufferCleanApertureKey, [aperture as CFDictionary]),
            (kCVImageBufferMasteringDisplayColorVolumeKey, [
                mastering as CFData, changedMastering as CFData]),
            (kCVImageBufferContentLightLevelInfoKey, [
                Data([0x03, 0xe8, 0x01, 0x90]) as CFData,
                Data([0x07, 0xd0, 0x02, 0xbc]) as CFData]),
        ]
        let initial = try cache.resolve(for: image) { try Self.makeDescription(image) }
        try Self.expectFreshEquivalent(initial, image: image)
        for (key, values) in cases {
            for value in values {
                CVBufferSetAttachment(image, key, value, .shouldPropagate)
                let actual = try cache.resolve(for: image) { try Self.makeDescription(image) }
                try Self.expectFreshEquivalent(actual, image: image)
            }
            CVBufferRemoveAttachment(image, key)
            let removed = try cache.resolve(for: image) { try Self.makeDescription(image) }
            try Self.expectFreshEquivalent(removed, image: image)
        }
    }

    @Test func dimensionsPixelFormatAndRowStrideChangesMatchFreshDescriptions() throws {
        let cache = VideoFormatDescriptionCache()
        let images = try [
            Self.makeBuffer(),
            Self.makeBuffer(width: 32),
            Self.makeBuffer(height: 24),
            Self.makeBuffer(format: kCVPixelFormatType_32ARGB),
            Self.makeOwnedBuffer(rowBytes: 288),
            Self.makeOwnedBuffer(rowBytes: 320),
        ]
        #expect(CVPixelBufferGetBytesPerRow(images[4]) == 288)
        #expect(CVPixelBufferGetBytesPerRow(images[5]) == 320)
        for image in images + Array(images.reversed()) {
            let actual = try cache.resolve(for: image) { try Self.makeDescription(image) }
            try Self.expectFreshEquivalent(actual, image: image)
        }
    }

    @Test func oldSamplesKeepTheirImageFormatAndTimingAfterReplacementAndReset() throws {
        let cache = VideoFormatDescriptionCache()
        let firstImage = try Self.makeBuffer()
        let firstFormat = try cache.resolve(for: firstImage) { try Self.makeDescription(firstImage) }
        let firstTime = CMTime(value: 7, timescale: 30)
        let firstSample = try Self.makeSample(firstImage, format: firstFormat, time: firstTime)
        let secondImage = try Self.makeBuffer(width: 32)
        let secondFormat = try cache.resolve(for: secondImage) { try Self.makeDescription(secondImage) }
        let secondTime = CMTime(value: 11, timescale: 30)
        let secondSample = try Self.makeSample(secondImage, format: secondFormat, time: secondTime)
        cache.reset()

        #expect(CMSampleBufferGetImageBuffer(firstSample) === firstImage)
        #expect(CMSampleBufferGetImageBuffer(secondSample) === secondImage)
        #expect(CMFormatDescriptionEqual(CMSampleBufferGetFormatDescription(firstSample),
                                        otherFormatDescription: firstFormat))
        #expect(CMFormatDescriptionEqual(CMSampleBufferGetFormatDescription(secondSample),
                                        otherFormatDescription: secondFormat))
        #expect(CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(firstSample), firstTime) == 0)
        #expect(CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(secondSample), secondTime) == 0)
        #expect(CMTimeCompare(CMSampleBufferGetDuration(firstSample),
                              CMTime(value: 1, timescale: 30)) == 0)
    }

    @Test func throwingFactoryPreservesPriorEntryAndCanRetry() throws {
        let cache = VideoFormatDescriptionCache()
        let firstImage = try Self.makeBuffer()
        let secondImage = try Self.makeBuffer(width: 32)
        var creations = 0
        let first = try cache.resolve(for: firstImage) {
            creations += 1
            return try Self.makeDescription(firstImage)
        }
        #expect(throws: TestError.forced) {
            try cache.resolve(for: secondImage) {
                creations += 1
                throw TestError.forced
            }
        }
        let preserved = try cache.resolve(for: firstImage) {
            creations += 1
            return try Self.makeDescription(firstImage)
        }
        #expect(preserved === first)
        #expect(creations == 2)
        let retried = try cache.resolve(for: secondImage) {
            creations += 1
            return try Self.makeDescription(secondImage)
        }
        try Self.expectFreshEquivalent(retried, image: secondImage)
        #expect(creations == 3)
        cache.reset()
        cache.reset()
        let recreated = try cache.resolve(for: secondImage) {
            creations += 1
            return try Self.makeDescription(secondImage)
        }
        #expect(creations == 4)
        try Self.expectFreshEquivalent(recreated, image: secondImage)
    }

    @Test func cachedDescriptionDoesNotRetainPixelStorage() throws {
        let cache = VideoFormatDescriptionCache()
        let releases = Counts()
        try autoreleasepool {
            let image = try Self.makeOwnedBuffer(rowBytes: 288, releases: releases)
            _ = try cache.resolve(for: image) { try Self.makeDescription(image) }
            withExtendedLifetime(image) { #expect(releases.releases == 0) }
        }
        #expect(releases.releases == 1)
        cache.reset()
        #expect(releases.releases == 1)
    }

    @Test func concurrentCompatibleCallersShareOneEntry() {
        let cache = VideoFormatDescriptionCache()
        let counts = Counts()
        DispatchQueue.concurrentPerform(iterations: 48) { _ in
            do {
                let image = try Self.makeBuffer()
                let actual = try cache.resolve(for: image) {
                    counts.created()
                    return try Self.makeDescription(image)
                }
                let fresh = try Self.makeDescription(image)
                if !CMFormatDescriptionEqual(actual, otherFormatDescription: fresh) {
                    counts.failed("Concurrent result differs from a fresh description")
                }
                _ = try Self.makeSample(image, format: actual)
            } catch { counts.failed(String(describing: error)) }
        }
        #expect(counts.creations == 1)
        #expect(counts.failures.isEmpty)
    }

    private enum TestError: Error, Equatable { case forced }

    private final class Counts: @unchecked Sendable {
        private let lock = NSLock()
        private var createdCount = 0
        private var releasedCount = 0
        private var errors: [String] = []
        var creations: Int { lock.withLock { createdCount } }
        var releases: Int { lock.withLock { releasedCount } }
        var failures: [String] { lock.withLock { errors } }
        func created() { lock.withLock { createdCount += 1 } }
        func released() { lock.withLock { releasedCount += 1 } }
        func failed(_ message: String) { lock.withLock { errors.append(message) } }
    }

    private static func makeBuffer(
        width: Int = 64, height: Int = 48,
        format: OSType = kCVPixelFormatType_32BGRA
    ) throws -> CVPixelBuffer {
        var image: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, format, nil, &image)
        guard status == kCVReturnSuccess, let image else {
            throw NSError(domain: "VideoFormatCacheTest.Buffer", code: Int(status))
        }
        return image
    }

    private static func makeOwnedBuffer(rowBytes: Int, releases: Counts = Counts()) throws -> CVPixelBuffer {
        let bytes = UnsafeMutableRawPointer.allocate(byteCount: rowBytes * 48, alignment: 16)
        bytes.initializeMemory(as: UInt8.self, repeating: 0, count: rowBytes * 48)
        let context = Unmanaged.passRetained(releases).toOpaque()
        var image: CVPixelBuffer?
        let status = CVPixelBufferCreateWithBytes(
            kCFAllocatorDefault, 64, 48, kCVPixelFormatType_32BGRA,
            bytes, rowBytes, { context, baseAddress in
                UnsafeMutableRawPointer(mutating: baseAddress!).deallocate()
                Unmanaged<Counts>.fromOpaque(context!).takeRetainedValue().released()
            }, context, nil, &image
        )
        guard status == kCVReturnSuccess, let image else {
            bytes.deallocate()
            Unmanaged<Counts>.fromOpaque(context).release()
            throw NSError(domain: "VideoFormatCacheTest.OwnedBuffer", code: Int(status))
        }
        return image
    }

    private static func makeDescription(_ image: CVPixelBuffer) throws -> CMVideoFormatDescription {
        var result: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: image, formatDescriptionOut: &result
        )
        guard status == noErr, let result else {
            throw NSError(domain: "VideoFormatCacheTest.Description", code: Int(status))
        }
        return result
    }

    private static func makeSample(
        _ image: CVPixelBuffer, format: CMVideoFormatDescription,
        time: CMTime = .zero
    ) throws -> CMSampleBuffer {
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
                                        presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var result: CMSampleBuffer?
        let status = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: image, formatDescription: format,
            sampleTiming: &timing, sampleBufferOut: &result
        )
        guard status == noErr, let result else {
            throw NSError(domain: "VideoFormatCacheTest.Sample", code: Int(status))
        }
        return result
    }

    private static func expectFreshEquivalent(
        _ actual: CMVideoFormatDescription, image: CVPixelBuffer
    ) throws {
        let fresh = try makeDescription(image)
        #expect(CMFormatDescriptionEqual(actual, otherFormatDescription: fresh))
        #expect(CMVideoFormatDescriptionMatchesImageBuffer(actual, imageBuffer: image))
        _ = try makeSample(image, format: actual)
    }
}
