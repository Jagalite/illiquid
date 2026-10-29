import CoreMedia
import CoreVideo
import Dispatch
import Foundation
import Testing
@testable import IlliquidNativePlayback

@Suite("Video format description reuse")
struct VideoFormatDescriptionCacheTests {
    @Test func reusesOneDescriptionAcrossDistinctCompatibleBuffers() throws {
        let cache = VideoFormatDescriptionCache()
        let buffers = try [newFormatCacheBuffer(), newFormatCacheBuffer()]
        #expect(buffers[0] !== buffers[1])
        var creations = 0
        var first: CMVideoFormatDescription?
        for index in 0..<32 {
            let buffer = buffers[index % buffers.count]
            let result = try cache.description(for: buffer) {
                creations += 1
                return try newFormatCacheDescription(buffer)
            }
            if let first { #expect(result === first) } else { first = result }
            #expect(CMVideoFormatDescriptionMatchesImageBuffer(result, imageBuffer: buffer))
        }
        #expect(creations == 1)
    }

    @Test(arguments: [0, 1, 2])
    func replacesOnWidthHeightOrPixelFormatChanges(_ variant: Int) throws {
        let cache = VideoFormatDescriptionCache()
        let original = try newFormatCacheBuffer()
        let changed = try newFormatCacheBuffer(
            width: variant == 0 ? 24 : 16, height: variant == 1 ? 24 : 16,
            format: variant == 2 ? kCVPixelFormatType_32ARGB : kCVPixelFormatType_32BGRA
        )
        let first = try cache.description(for: original) { try newFormatCacheDescription(original) }
        #expect(!CMVideoFormatDescriptionMatchesImageBuffer(first, imageBuffer: changed))
        let next = try cache.description(for: changed) { try newFormatCacheDescription(changed) }
        #expect(next !== first)
        let baseline = try newFormatCacheDescription(changed)
        #expect(CMFormatDescriptionEqual(next, otherFormatDescription: baseline))
        _ = try newFormatCacheSample(changed, description: next)
    }

    @Test func alternatingFormatsReplaceTheSingleEntry() throws {
        let cache = VideoFormatDescriptionCache()
        let buffers = try [newFormatCacheBuffer(), newFormatCacheBuffer(width: 24)]
        var creations = 0
        for index in 0..<32 {
            let buffer = buffers[index % buffers.count]
            let result = try cache.description(for: buffer) {
                creations += 1
                return try newFormatCacheDescription(buffer)
            }
            #expect(CMVideoFormatDescriptionMatchesImageBuffer(result, imageBuffer: buffer))
        }
        #expect(creations == 32)
    }

    @Test func rowStrideChangesPreserveFreshDescriptionParity() throws {
        let cache = VideoFormatDescriptionCache()
        let narrow = try ownedFormatCacheBuffer(bytesPerRow: 64)
        let padded = try ownedFormatCacheBuffer(bytesPerRow: 128)
        #expect(CVPixelBufferGetBytesPerRow(narrow) == 64)
        #expect(CVPixelBufferGetBytesPerRow(padded) == 128)
        for buffer in [narrow, padded, narrow] {
            let actual = try cache.description(for: buffer) { try newFormatCacheDescription(buffer) }
            let baseline = try newFormatCacheDescription(buffer)
            #expect(CMFormatDescriptionEqual(actual, otherFormatDescription: baseline))
            #expect(CMVideoFormatDescriptionMatchesImageBuffer(actual, imageBuffer: buffer))
            _ = try newFormatCacheSample(buffer, description: actual)
        }
    }

    @Test(arguments: Attachment.allCases)
    func addingChangingAndRemovingAttachmentsMatchesFreshCreation(_ attachment: Attachment) throws {
        let cache = VideoFormatDescriptionCache()
        let buffer = try newFormatCacheBuffer(format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        for phase in 0..<5 {
            if phase == 0 || phase == 3 {
                CVBufferRemoveAttachment(buffer, attachment.key)
            } else {
                CVBufferSetAttachment(buffer, attachment.key, attachment.value(alternate: phase == 2), .shouldPropagate)
            }
            let baseline = try newFormatCacheDescription(buffer)
            let actual = try cache.description(for: buffer) { try newFormatCacheDescription(buffer) }
            // Require parity even for attachments this OS leaves on the image
            // buffer instead of copying into its format description.
            #expect(CMFormatDescriptionEqual(actual, otherFormatDescription: baseline))
            #expect(CMVideoFormatDescriptionMatchesImageBuffer(actual, imageBuffer: buffer))
            _ = try newFormatCacheSample(buffer, description: actual)
        }
    }

    @Test func detectsInPlaceMutationOfAnAttachmentDictionary() throws {
        let cache = VideoFormatDescriptionCache()
        let buffer = try newFormatCacheBuffer()
        let values: [String: Any] = [
            kCVImageBufferPixelAspectRatioHorizontalSpacingKey as String: 4,
            kCVImageBufferPixelAspectRatioVerticalSpacingKey as String: 3,
        ]
        let mutable = try #require(CFDictionaryCreateMutableCopy(nil, 0, values as CFDictionary))
        CVBufferSetAttachment(buffer, kCVImageBufferPixelAspectRatioKey, mutable, .shouldPropagate)
        let before = try cache.description(for: buffer) { try newFormatCacheDescription(buffer) }
        let replacement = NSNumber(value: 16)
        CFDictionarySetValue(
            mutable, Unmanaged.passUnretained(kCVImageBufferPixelAspectRatioHorizontalSpacingKey).toOpaque(),
            Unmanaged.passUnretained(replacement).toOpaque()
        )
        let baseline = try newFormatCacheDescription(buffer)
        #expect(!CMFormatDescriptionEqual(before, otherFormatDescription: baseline))
        let after = try cache.description(for: buffer) { try newFormatCacheDescription(buffer) }
        #expect(after !== before)
        #expect(CMFormatDescriptionEqual(after, otherFormatDescription: baseline))
        _ = try newFormatCacheSample(buffer, description: after)
    }

    @Test func resetAndReplacementLeaveOutstandingSamplesValid() throws {
        let cache = VideoFormatDescriptionCache()
        let probe = FormatCacheProbe()
        var creations = 0
        try autoreleasepool {
            let sample = try autoreleasepool {
                let buffer = try ownedFormatCacheBuffer(probe: probe)
                let description = try cache.description(for: buffer) {
                    creations += 1
                    return try newFormatCacheDescription(buffer)
                }
                return try newFormatCacheSample(buffer, description: description)
            }
            cache.removeAll()
            for width in [16, 24] {
                let buffer = try newFormatCacheBuffer(width: width)
                _ = try cache.description(for: buffer) {
                    creations += 1
                    return try newFormatCacheDescription(buffer)
                }
            }
            #expect(creations == 3)
            let image = try #require(CMSampleBufferGetImageBuffer(sample))
            let description = try #require(CMSampleBufferGetFormatDescription(sample))
            #expect(CVPixelBufferGetWidth(image) == 16)
            #expect(CMSampleBufferIsValid(sample))
            #expect(CMVideoFormatDescriptionMatchesImageBuffer(description, imageBuffer: image))
            #expect(CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(sample), CMTime(value: 7, timescale: 30)) == 0)
            #expect(probe.snapshot.count == 0)
        }
        #expect(probe.snapshot.count == 1)
        withExtendedLifetime(cache) {}
    }

    @Test func aThrowingFactoryPreservesThePreviousEntryAndUnlocks() throws {
        let cache = VideoFormatDescriptionCache()
        let original = try newFormatCacheBuffer()
        let changed = try newFormatCacheBuffer(width: 24)
        var attempts = 0
        let first = try cache.description(for: original) {
            attempts += 1
            return try newFormatCacheDescription(original)
        }
        var caught = false
        do {
            _ = try cache.description(for: changed) {
                attempts += 1
                throw FormatCacheTestError.injected
            }
        } catch FormatCacheTestError.injected {
            caught = true
        }
        #expect(caught)
        let retained = try cache.description(for: original) {
            attempts += 1
            return try newFormatCacheDescription(original)
        }
        #expect(retained === first)
        #expect(attempts == 2)
        let retry = try cache.description(for: changed) {
            attempts += 1
            return try newFormatCacheDescription(changed)
        }
        #expect(attempts == 3)
        #expect(CMVideoFormatDescriptionMatchesImageBuffer(retry, imageBuffer: changed))
    }

    @Test func cachedMetadataDoesNotRetainPixelStorage() throws {
        let cache = VideoFormatDescriptionCache()
        let probe = FormatCacheProbe()
        let description = try autoreleasepool {
            let buffer = try ownedFormatCacheBuffer(probe: probe)
            return try cache.description(for: buffer) { try newFormatCacheDescription(buffer) }
        }
        #expect(probe.snapshot.count == 1)
        withExtendedLifetime((cache, description)) {}
    }

    @Test func concurrentCompatibleMissesCreateOnce() {
        let cache = VideoFormatDescriptionCache()
        let creations = FormatCacheProbe()
        let results = FormatCacheProbe()
        DispatchQueue.concurrentPerform(iterations: 32) { _ in
            autoreleasepool {
                do {
                    let buffer = try newFormatCacheBuffer()
                    let result = try cache.description(for: buffer) {
                        creations.record()
                        return try newFormatCacheDescription(buffer)
                    }
                    results.record(
                        CMVideoFormatDescriptionMatchesImageBuffer(result, imageBuffer: buffer)
                            ? nil : "Incompatible description"
                    )
                } catch {
                    results.record(String(describing: error))
                }
            }
        }
        #expect(creations.snapshot.count == 1)
        #expect(results.snapshot.count == 32)
        #expect(results.snapshot.failures.isEmpty)
    }

    @Test func concurrentLookupsAndResetsReturnCompatibleDescriptions() {
        let cache = VideoFormatDescriptionCache()
        let probe = FormatCacheProbe()
        DispatchQueue.concurrentPerform(iterations: 64) { index in
            autoreleasepool {
                do {
                    if index.isMultiple(of: 4) { cache.removeAll() }
                    // Buffers remain worker-local; only the synchronized cache is shared.
                    let buffer = try newFormatCacheBuffer(width: 16 + 8 * (index % 3))
                    let result = try cache.description(for: buffer) { try newFormatCacheDescription(buffer) }
                    let baseline = try newFormatCacheDescription(buffer)
                    guard CMFormatDescriptionEqual(result, otherFormatDescription: baseline) else {
                        probe.record("Incompatible description for worker \(index)")
                        return
                    }
                    _ = try newFormatCacheSample(buffer, description: result)
                    probe.record()
                } catch {
                    probe.record(String(describing: error))
                }
            }
        }
        #expect(probe.snapshot.count == 64)
        #expect(probe.snapshot.failures.isEmpty)
    }

    enum Attachment: String, CaseIterable, Sendable {
        case aperture, aspect, primaries, transfer, matrix, gamma
        case chromaTop, chromaBottom, mastering, contentLight

        var key: CFString {
            switch self {
            case .aperture: kCVImageBufferCleanApertureKey
            case .aspect: kCVImageBufferPixelAspectRatioKey
            case .primaries: kCVImageBufferColorPrimariesKey
            case .transfer: kCVImageBufferTransferFunctionKey
            case .matrix: kCVImageBufferYCbCrMatrixKey
            case .gamma: kCVImageBufferGammaLevelKey
            case .chromaTop: kCVImageBufferChromaLocationTopFieldKey
            case .chromaBottom: kCVImageBufferChromaLocationBottomFieldKey
            case .mastering: kCVImageBufferMasteringDisplayColorVolumeKey
            case .contentLight: kCVImageBufferContentLightLevelInfoKey
            }
        }

        func value(alternate: Bool) -> CFTypeRef {
            switch self {
            case .aperture:
                let value: [String: Any] = [
                    kCVImageBufferCleanApertureWidthKey as String: alternate ? 12 : 14,
                    kCVImageBufferCleanApertureHeightKey as String: 14,
                    kCVImageBufferCleanApertureHorizontalOffsetKey as String: 0.0,
                    kCVImageBufferCleanApertureVerticalOffsetKey as String: 0.0,
                ]
                return value as CFDictionary
            case .aspect:
                let value: [String: Any] = [
                    kCVImageBufferPixelAspectRatioHorizontalSpacingKey as String: alternate ? 16 : 4,
                    kCVImageBufferPixelAspectRatioVerticalSpacingKey as String: 3,
                ]
                return value as CFDictionary
            case .primaries:
                return alternate ? kCVImageBufferColorPrimaries_ITU_R_2020 : kCVImageBufferColorPrimaries_ITU_R_709_2
            case .transfer:
                return alternate ? kCVImageBufferTransferFunction_ITU_R_2100_HLG : kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
            case .matrix:
                return alternate ? kCVImageBufferYCbCrMatrix_ITU_R_2020 : kCVImageBufferYCbCrMatrix_ITU_R_709_2
            case .gamma:
                return NSNumber(value: alternate ? 1.8 : 2.2)
            case .chromaTop, .chromaBottom:
                return alternate ? kCVImageBufferChromaLocation_Center : kCVImageBufferChromaLocation_Left
            case .mastering:
                var bytes = Data([
                    0x33, 0xc2, 0x86, 0xc4, 0x1d, 0x4c, 0x0b, 0xb8,
                    0x84, 0xd0, 0x3e, 0x80, 0x3d, 0x13, 0x40, 0x42,
                    0x00, 0x98, 0x96, 0x80, 0x00, 0x00, 0x00, 0x32,
                ])
                if alternate { bytes[19] = 0x81 }
                return bytes as CFData
            case .contentLight:
                return Data([0x03, alternate ? 0xe9 : 0xe8, 0x01, 0x90]) as CFData
            }
        }
    }
}

private enum FormatCacheTestError: Error { case injected }

private func newFormatCacheBuffer(
    width: Int = 16, height: Int = 16, format: OSType = kCVPixelFormatType_32BGRA
) throws -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(nil, width, height, format, nil, &buffer)
    try #require(status == kCVReturnSuccess)
    return try #require(buffer)
}

private func newFormatCacheDescription(_ buffer: CVPixelBuffer) throws -> CMVideoFormatDescription {
    var description: CMVideoFormatDescription?
    let status = CMVideoFormatDescriptionCreateForImageBuffer(
        allocator: nil, imageBuffer: buffer, formatDescriptionOut: &description
    )
    try #require(status == noErr)
    return try #require(description)
}

private func newFormatCacheSample(
    _ buffer: CVPixelBuffer, description: CMVideoFormatDescription
) throws -> CMSampleBuffer {
    var timing = CMSampleTimingInfo(
        duration: CMTime(value: 1, timescale: 30),
        presentationTimeStamp: CMTime(value: 7, timescale: 30), decodeTimeStamp: .invalid
    )
    var sample: CMSampleBuffer?
    let status = CMSampleBufferCreateReadyWithImageBuffer(
        allocator: nil, imageBuffer: buffer, formatDescription: description,
        sampleTiming: &timing, sampleBufferOut: &sample
    )
    try #require(status == noErr)
    return try #require(sample)
}

private func ownedFormatCacheBuffer(
    bytesPerRow: Int = 64, probe: FormatCacheProbe? = nil
) throws -> CVPixelBuffer {
    let storage = FormatCachePixelStorage(byteCount: bytesPerRow * 16, probe: probe)
    let retained = Unmanaged.passRetained(storage).toOpaque()
    var buffer: CVPixelBuffer?
    let status = CVPixelBufferCreateWithBytes(
        nil, 16, 16, kCVPixelFormatType_32BGRA, storage.bytes, bytesPerRow,
        { context, _ in
            if let context { Unmanaged<FormatCachePixelStorage>.fromOpaque(context).release() }
        },
        retained, nil, &buffer
    )
    if status != kCVReturnSuccess {
        Unmanaged<FormatCachePixelStorage>.fromOpaque(retained).release()
    }
    try #require(status == kCVReturnSuccess)
    return try #require(buffer)
}

private final class FormatCachePixelStorage {
    let bytes: UnsafeMutableRawPointer
    let probe: FormatCacheProbe?
    init(byteCount: Int, probe: FormatCacheProbe?) {
        bytes = .allocate(byteCount: byteCount, alignment: 64)
        bytes.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)
        self.probe = probe
    }
    deinit { bytes.deallocate(); probe?.record() }
}

private final class FormatCacheProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var failures: [String] = []
    var snapshot: (count: Int, failures: [String]) {
        lock.withLock { (count, failures) }
    }
    func record(_ failure: String? = nil) {
        lock.withLock {
            count += 1
            if let failure { failures.append(failure) }
        }
    }
}
