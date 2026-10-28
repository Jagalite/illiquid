import CoreMedia
import CoreVideo
import Dispatch
import Foundation
import Testing
@testable import IlliquidNativePlayback

@Suite("Video format description cache")
struct VideoFormatDescriptionCacheTests {
    @Test(arguments: [
        kCVPixelFormatType_32BGRA,
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
        kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
    ])
    func reusesDescriptionAcrossDistinctBuffersWithTheSameLayout(pixelFormat: OSType) throws {
        let cache = VideoFormatDescriptionCache()
        let first = try VideoFormatCacheFixtures.buffer(pixelFormat: pixelFormat)
        let second = try VideoFormatCacheFixtures.buffer(pixelFormat: pixelFormat)
        #expect(first !== second)
        var creations = 0
        let original = try cache.formatDescription(for: first) {
            creations += 1
            return try VideoFormatCacheFixtures.description(for: first)
        }

        for buffer in [second, first, second] {
            let actual = try cache.formatDescription(for: buffer) {
                creations += 1
                return try VideoFormatCacheFixtures.description(for: buffer)
            }
            let fresh = try VideoFormatCacheFixtures.description(for: buffer)
            #expect(actual === original)
            #expect(CMFormatDescriptionEqual(actual, otherFormatDescription: fresh))
            #expect(CMVideoFormatDescriptionMatchesImageBuffer(actual, imageBuffer: buffer))
        }
        #expect(creations == 1)
    }

    @Test func formatAndDimensionChangesReplaceTheSingleCachedEntry() throws {
        let layouts: [(format: OSType, width: Int, height: Int)] = [
            (kCVPixelFormatType_32BGRA, 128, 72),
            (kCVPixelFormatType_32BGRA, 130, 72),
            (kCVPixelFormatType_32BGRA, 130, 74),
            (kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, 128, 72),
            (kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, 128, 72),
            (kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, 128, 72),
            (kCVPixelFormatType_420YpCbCr10BiPlanarFullRange, 128, 72),
            (kCVPixelFormatType_32BGRA, 128, 72),
        ]
        let cache = VideoFormatDescriptionCache()
        var creations = 0

        for (index, layout) in layouts.enumerated() {
            let buffer = try VideoFormatCacheFixtures.buffer(
                pixelFormat: layout.format, width: layout.width, height: layout.height
            )
            let actual = try cache.formatDescription(for: buffer) {
                creations += 1
                return try VideoFormatCacheFixtures.description(for: buffer)
            }
            let fresh = try VideoFormatCacheFixtures.description(for: buffer)
            #expect(creations == index + 1)
            #expect(CMFormatDescriptionEqual(actual, otherFormatDescription: fresh))
            #expect(CMFormatDescriptionGetMediaSubType(actual) == layout.format)
            let dimensions = CMVideoFormatDescriptionGetDimensions(actual)
            #expect(dimensions.width == Int32(layout.width))
            #expect(dimensions.height == Int32(layout.height))
        }
    }

    @Test func changedRowStrideStaysEquivalentToFreshDescriptions() throws {
        let compact = try VideoFormatCacheFixtures.buffer(
            pixelFormat: kCVPixelFormatType_32BGRA, width: 64, height: 8, alignment: 64
        )
        let padded = try VideoFormatCacheFixtures.buffer(
            pixelFormat: kCVPixelFormatType_32BGRA, width: 64, height: 8, alignment: 4096
        )
        try #require(CVPixelBufferGetBytesPerRow(compact) != CVPixelBufferGetBytesPerRow(padded))
        let cache = VideoFormatDescriptionCache()
        var creations = 0
        let original = try cache.formatDescription(for: compact) {
            creations += 1
            return try VideoFormatCacheFixtures.description(for: compact)
        }
        let fresh = try VideoFormatCacheFixtures.description(for: padded)
        let changed = !CMFormatDescriptionEqual(original, otherFormatDescription: fresh)
        let actual = try cache.formatDescription(for: padded) {
            creations += 1
            return try VideoFormatCacheFixtures.description(for: padded)
        }

        #expect(CMFormatDescriptionEqual(actual, otherFormatDescription: fresh))
        #expect(CMVideoFormatDescriptionMatchesImageBuffer(actual, imageBuffer: padded))
        // CoreMedia checks bytes per row when that extension is applicable.
        if changed { #expect(creations == 2) }
        let hit = try cache.formatDescription(for: padded) {
            throw VideoFormatCacheFixtureError.injected
        }
        #expect(hit === actual)
    }

    @Test func sameBufferAttachmentChangesAndRemovalsMatchFreshDescriptions() throws {
        for fixture in VideoFormatCacheFixtures.attachments() {
            let buffer = try VideoFormatCacheFixtures.buffer(
                pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            )
            let cache = VideoFormatDescriptionCache()
            var creations = 0
            var previous = try cache.formatDescription(for: buffer) {
                creations += 1
                return try VideoFormatCacheFixtures.description(for: buffer)
            }

            for value in fixture.values {
                CVBufferSetAttachment(buffer, fixture.key, value, .shouldPropagate)
                let fresh = try VideoFormatCacheFixtures.description(for: buffer)
                if fixture.requiresExtension {
                    #expect(
                        CMFormatDescriptionGetExtension(fresh, extensionKey: fixture.key) != nil,
                        "CoreMedia must retain the fixture's \(fixture.name) extension"
                    )
                }
                let changed = !CMFormatDescriptionEqual(previous, otherFormatDescription: fresh)
                let previousCreations = creations
                let actual = try cache.formatDescription(for: buffer) {
                    creations += 1
                    return try VideoFormatCacheFixtures.description(for: buffer)
                }
                #expect(
                    CMFormatDescriptionEqual(actual, otherFormatDescription: fresh),
                    "Attachment value changed on the same pixel buffer: \(fixture.name)"
                )
                #expect(CMVideoFormatDescriptionMatchesImageBuffer(actual, imageBuffer: buffer))
                if changed { #expect(creations == previousCreations + 1) }
                previous = actual
            }

            CVBufferRemoveAttachment(buffer, fixture.key)
            let fresh = try VideoFormatCacheFixtures.description(for: buffer)
            let changed = !CMFormatDescriptionEqual(previous, otherFormatDescription: fresh)
            let previousCreations = creations
            let actual = try cache.formatDescription(for: buffer) {
                creations += 1
                return try VideoFormatCacheFixtures.description(for: buffer)
            }
            #expect(
                CMFormatDescriptionEqual(actual, otherFormatDescription: fresh),
                "Attachment removed from the same pixel buffer: \(fixture.name)"
            )
            #expect(CMVideoFormatDescriptionMatchesImageBuffer(actual, imageBuffer: buffer))
            if changed { #expect(creations == previousCreations + 1) }
            let hit = try cache.formatDescription(for: buffer) {
                throw VideoFormatCacheFixtureError.injected
            }
            #expect(hit === actual)
        }
    }

    @Test func resetForcesCreationForAnOtherwiseMatchingBuffer() throws {
        let cache = VideoFormatDescriptionCache()
        let buffer = try VideoFormatCacheFixtures.buffer()
        var creations = 0
        let before = try cache.formatDescription(for: buffer) {
            creations += 1
            return try VideoFormatCacheFixtures.description(for: buffer)
        }
        cache.reset()
        cache.reset()
        let after = try cache.formatDescription(for: buffer) {
            creations += 1
            return try VideoFormatCacheFixtures.description(for: buffer)
        }
        #expect(creations == 2)
        #expect(CMFormatDescriptionEqual(before, otherFormatDescription: after))
        let hit = try cache.formatDescription(for: buffer) {
            throw VideoFormatCacheFixtureError.injected
        }
        #expect(hit === after)
    }

    @Test func failedReplacementPreservesThePreviousDescriptionAndPropagatesTheError() throws {
        let cache = VideoFormatDescriptionCache()
        let first = try VideoFormatCacheFixtures.buffer()
        let second = try VideoFormatCacheFixtures.buffer(width: 130)
        var creations = 0
        let original = try cache.formatDescription(for: first) {
            creations += 1
            return try VideoFormatCacheFixtures.description(for: first)
        }

        do {
            _ = try cache.formatDescription(for: second) {
                throw VideoFormatCacheFixtureError.injected
            }
            Issue.record("The failed creation must throw its original error")
        } catch {
            #expect(error as? VideoFormatCacheFixtureError == .injected)
        }

        let retained = try cache.formatDescription(for: first) {
            throw VideoFormatCacheFixtureError.injected
        }
        #expect(retained === original)
        #expect(creations == 1)

        let recovered = try cache.formatDescription(for: second) {
            creations += 1
            return try VideoFormatCacheFixtures.description(for: second)
        }
        let fresh = try VideoFormatCacheFixtures.description(for: second)
        #expect(creations == 2)
        #expect(CMFormatDescriptionEqual(recovered, otherFormatDescription: fresh))
    }

    @Test func failedInitialCreationCanBeRetried() throws {
        let cache = VideoFormatDescriptionCache()
        let buffer = try VideoFormatCacheFixtures.buffer()
        var attempts = 0
        do {
            _ = try cache.formatDescription(for: buffer) {
                attempts += 1
                throw VideoFormatCacheFixtureError.injected
            }
            Issue.record("An initial creation failure must be propagated")
        } catch {
            #expect(error as? VideoFormatCacheFixtureError == .injected)
        }

        let recovered = try cache.formatDescription(for: buffer) {
            attempts += 1
            return try VideoFormatCacheFixtures.description(for: buffer)
        }
        #expect(attempts == 2)
        #expect(CMVideoFormatDescriptionMatchesImageBuffer(recovered, imageBuffer: buffer))
    }

    @Test(arguments: [
        kCVPixelFormatType_32BGRA,
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
        kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
    ])
    func cachedDescriptionsProduceEquivalentSamplesWithExactTiming(pixelFormat: OSType) throws {
        let cache = VideoFormatDescriptionCache()
        let buffers = try [
            VideoFormatCacheFixtures.buffer(pixelFormat: pixelFormat),
            VideoFormatCacheFixtures.buffer(pixelFormat: pixelFormat),
        ]
        var creations = 0

        for index in 0..<4 {
            let buffer = buffers[index % buffers.count]
            let cached = try cache.formatDescription(for: buffer) {
                creations += 1
                return try VideoFormatCacheFixtures.description(for: buffer)
            }
            let fresh = try VideoFormatCacheFixtures.description(for: buffer)
            let duration = CMTime(value: 1001, timescale: 24_000)
            let presentation = CMTime(value: -1001 + Int64(index) * 1001, timescale: 24_000)
            let actualSample = try VideoFormatCacheFixtures.sample(
                for: buffer, description: cached, duration: duration, presentation: presentation
            )
            let freshSample = try VideoFormatCacheFixtures.sample(
                for: buffer, description: fresh, duration: duration, presentation: presentation
            )

            #expect(CMSampleBufferDataIsReady(actualSample))
            #expect(CMSampleBufferGetNumSamples(actualSample) == 1)
            #expect(CMSampleBufferGetImageBuffer(actualSample) === buffer)
            #expect(CMFormatDescriptionEqual(
                CMSampleBufferGetFormatDescription(actualSample),
                otherFormatDescription: CMSampleBufferGetFormatDescription(freshSample)
            ))
            let actualPresentation = CMSampleBufferGetPresentationTimeStamp(actualSample)
            let actualDuration = CMSampleBufferGetDuration(actualSample)
            #expect(actualPresentation.value == presentation.value)
            #expect(actualPresentation.timescale == presentation.timescale)
            #expect(actualPresentation.epoch == presentation.epoch)
            #expect(actualPresentation.flags == presentation.flags)
            #expect(actualDuration.value == duration.value)
            #expect(actualDuration.timescale == duration.timescale)
            #expect(actualDuration.flags == duration.flags)
            #expect(!CMSampleBufferGetDecodeTimeStamp(actualSample).isValid)
            #expect(CMTimeCompare(
                actualPresentation, CMSampleBufferGetPresentationTimeStamp(freshSample)
            ) == 0)
            #expect(CMTimeCompare(actualDuration, CMSampleBufferGetDuration(freshSample)) == 0)
        }
        #expect(creations == 1)
    }

    @Test func concurrentMatchingRequestsCreateOnlyOneDescription() {
        let cache = VideoFormatDescriptionCache()
        let results = VideoFormatCacheConcurrentResults()
        let iterations = 64

        DispatchQueue.concurrentPerform(iterations: iterations) { _ in
            do {
                // Each worker owns its buffer; none mutates shared attachments.
                let buffer = try VideoFormatCacheFixtures.buffer()
                let actual = try cache.formatDescription(for: buffer) {
                    results.recordCreation()
                    return try VideoFormatCacheFixtures.description(for: buffer)
                }
                let fresh = try VideoFormatCacheFixtures.description(for: buffer)
                results.record(
                    actual,
                    matches: CMVideoFormatDescriptionMatchesImageBuffer(actual, imageBuffer: buffer)
                        && CMFormatDescriptionEqual(actual, otherFormatDescription: fresh)
                )
            } catch {
                results.recordFailure(String(describing: error))
            }
        }

        let snapshot = results.snapshot()
        #expect(snapshot.failures.isEmpty)
        #expect(snapshot.results == iterations)
        #expect(snapshot.mismatches == 0)
        #expect(snapshot.creations == 1)
        #expect(snapshot.identifiers.count == 1)
    }

    @Test func concurrentResetsAndFormatChangesRemainCompatible() {
        let cache = VideoFormatDescriptionCache()
        let results = VideoFormatCacheConcurrentResults()
        let iterations = 64

        DispatchQueue.concurrentPerform(iterations: iterations) { index in
            do {
                if index.isMultiple(of: 5) { cache.reset() }
                let format = index.isMultiple(of: 2)
                    ? kCVPixelFormatType_32BGRA : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                let buffer = try VideoFormatCacheFixtures.buffer(
                    pixelFormat: format, width: index.isMultiple(of: 3) ? 130 : 128
                )
                let actual = try cache.formatDescription(for: buffer) {
                    results.recordCreation()
                    return try VideoFormatCacheFixtures.description(for: buffer)
                }
                let fresh = try VideoFormatCacheFixtures.description(for: buffer)
                results.record(
                    actual,
                    matches: CMVideoFormatDescriptionMatchesImageBuffer(actual, imageBuffer: buffer)
                        && CMFormatDescriptionEqual(actual, otherFormatDescription: fresh)
                )
            } catch {
                results.recordFailure(String(describing: error))
            }
        }

        let snapshot = results.snapshot()
        #expect(snapshot.failures.isEmpty)
        #expect(snapshot.results == iterations)
        #expect(snapshot.mismatches == 0)
        #expect((1...iterations).contains(snapshot.creations))
    }
}

private enum VideoFormatCacheFixtureError: Error, Equatable {
    case status(operation: String, value: Int32)
    case missingOutput(String)
    case injected
}

private enum VideoFormatCacheFixtures {
    struct Attachment {
        let name: String
        let key: CFString
        let values: [CFTypeRef]
        let requiresExtension: Bool
    }

    static func buffer(
        pixelFormat: OSType = kCVPixelFormatType_32BGRA,
        width: Int = 128,
        height: Int = 72,
        alignment: Int = 64
    ) throws -> CVPixelBuffer {
        let attributes: [CFString: Any] = [kCVPixelBufferBytesPerRowAlignmentKey: alignment]
        var output: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, pixelFormat, attributes as CFDictionary, &output
        )
        guard status == kCVReturnSuccess else {
            throw VideoFormatCacheFixtureError.status(operation: "CVPixelBufferCreate", value: status)
        }
        guard let output else {
            throw VideoFormatCacheFixtureError.missingOutput("CVPixelBufferCreate")
        }
        return output
    }

    static func description(for buffer: CVPixelBuffer) throws -> CMVideoFormatDescription {
        var output: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescriptionOut: &output
        )
        guard status == noErr else {
            throw VideoFormatCacheFixtureError.status(
                operation: "CMVideoFormatDescriptionCreateForImageBuffer", value: status
            )
        }
        guard let output else {
            throw VideoFormatCacheFixtureError.missingOutput("CMVideoFormatDescriptionCreateForImageBuffer")
        }
        return output
    }

    static func sample(
        for buffer: CVPixelBuffer,
        description: CMVideoFormatDescription,
        duration: CMTime,
        presentation: CMTime
    ) throws -> CMSampleBuffer {
        var timing = CMSampleTimingInfo(
            duration: duration, presentationTimeStamp: presentation, decodeTimeStamp: .invalid
        )
        var output: CMSampleBuffer?
        let status = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: buffer,
            formatDescription: description,
            sampleTiming: &timing,
            sampleBufferOut: &output
        )
        guard status == noErr else {
            throw VideoFormatCacheFixtureError.status(
                operation: "CMSampleBufferCreateReadyWithImageBuffer", value: status
            )
        }
        guard let output else {
            throw VideoFormatCacheFixtureError.missingOutput("CMSampleBufferCreateReadyWithImageBuffer")
        }
        return output
    }

    static func attachments() -> [Attachment] {
        let apertureA: [CFString: Any] = [
            kCVImageBufferCleanApertureWidthKey: 120,
            kCVImageBufferCleanApertureHeightKey: 64,
            kCVImageBufferCleanApertureHorizontalOffsetKey: 0.0,
            kCVImageBufferCleanApertureVerticalOffsetKey: 0.0,
        ]
        let apertureB: [CFString: Any] = [
            kCVImageBufferCleanApertureWidthKey: 112,
            kCVImageBufferCleanApertureHeightKey: 60,
            kCVImageBufferCleanApertureHorizontalOffsetKey: 1.0,
            kCVImageBufferCleanApertureVerticalOffsetKey: -1.0,
        ]
        let aspectA: [CFString: Any] = [
            kCVImageBufferPixelAspectRatioHorizontalSpacingKey: 4,
            kCVImageBufferPixelAspectRatioVerticalSpacingKey: 3,
        ]
        let aspectB: [CFString: Any] = [
            kCVImageBufferPixelAspectRatioHorizontalSpacingKey: 16,
            kCVImageBufferPixelAspectRatioVerticalSpacingKey: 15,
        ]
        // Valid big-endian HDR10 payloads, matching the native fixture layout:
        // G/B/R primaries, white point, maximum and minimum mastering luminance.
        let masteringA = Data([
            0x33, 0xc2, 0x86, 0xc4, 0x1d, 0x4c, 0x0b, 0xb8,
            0x84, 0xd0, 0x3e, 0x80, 0x3d, 0x13, 0x40, 0x42,
            0x00, 0x98, 0x96, 0x80, 0x00, 0x00, 0x00, 0x32,
        ])
        let masteringB = Data([
            0x33, 0xc2, 0x86, 0xc4, 0x1d, 0x4c, 0x0b, 0xb8,
            0x84, 0xd0, 0x3e, 0x80, 0x3d, 0x13, 0x40, 0x42,
            0x01, 0x31, 0x2d, 0x00, 0x00, 0x00, 0x00, 0x32,
        ])
        return [
            Attachment(
                name: "YCbCr matrix", key: kCVImageBufferYCbCrMatrixKey,
                values: [kCVImageBufferYCbCrMatrix_ITU_R_709_2, kCVImageBufferYCbCrMatrix_ITU_R_2020],
                requiresExtension: true
            ),
            Attachment(
                name: "color primaries", key: kCVImageBufferColorPrimariesKey,
                values: [kCVImageBufferColorPrimaries_ITU_R_709_2, kCVImageBufferColorPrimaries_ITU_R_2020],
                requiresExtension: true
            ),
            Attachment(
                name: "transfer function", key: kCVImageBufferTransferFunctionKey,
                values: [kCVImageBufferTransferFunction_ITU_R_709_2, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ],
                requiresExtension: true
            ),
            Attachment(
                name: "gamma", key: kCVImageBufferGammaLevelKey,
                values: [NSNumber(value: 2.2), NSNumber(value: 2.4)],
                requiresExtension: true
            ),
            Attachment(
                name: "clean aperture", key: kCVImageBufferCleanApertureKey,
                values: [apertureA as CFDictionary, apertureB as CFDictionary],
                requiresExtension: true
            ),
            Attachment(
                name: "pixel aspect ratio", key: kCVImageBufferPixelAspectRatioKey,
                values: [aspectA as CFDictionary, aspectB as CFDictionary],
                requiresExtension: true
            ),
            // Creation and matching use CoreMedia's current common-key set.
            // HDR keys not copied by a runtime still require equality to its
            // uncached output; supported keys must update without stale data.
            Attachment(
                name: "mastering display color volume", key: kCVImageBufferMasteringDisplayColorVolumeKey,
                values: [masteringA as CFData, masteringB as CFData],
                requiresExtension: false
            ),
            Attachment(
                name: "content light level", key: kCVImageBufferContentLightLevelInfoKey,
                values: [
                    Data([0x03, 0xe8, 0x01, 0x90]) as CFData,
                    Data([0x07, 0xd0, 0x02, 0x58]) as CFData,
                ],
                requiresExtension: false
            ),
        ]
    }
}

private final class VideoFormatCacheConcurrentResults: @unchecked Sendable {
    private let lock = NSLock()
    private var creations = 0
    private var results = 0
    private var mismatches = 0
    private var failures: [String] = []
    private var identifiers: Set<UInt> = []

    func recordCreation() {
        lock.withLock { creations += 1 }
    }

    func record(_ description: CMVideoFormatDescription, matches: Bool) {
        let identifier = UInt(bitPattern: Unmanaged.passUnretained(description).toOpaque())
        lock.withLock {
            results += 1
            if !matches { mismatches += 1 }
            identifiers.insert(identifier)
        }
    }

    func recordFailure(_ failure: String) {
        lock.withLock { failures.append(failure) }
    }

    func snapshot() -> (
        creations: Int, results: Int, mismatches: Int, failures: [String], identifiers: Set<UInt>
    ) {
        lock.withLock { (creations, results, mismatches, failures, identifiers) }
    }
}
