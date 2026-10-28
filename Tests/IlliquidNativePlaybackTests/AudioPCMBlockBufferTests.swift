import AudioToolbox
import CoreMedia
import Foundation
import Testing
@testable import IlliquidNativePlayback

@Suite("PCM presentation storage ownership")
struct AudioPCMBlockBufferTests {
    @Test(arguments: [1, 2, 6, 8])
    func bytesAndTimingRemainExact(channels: Int) throws {
        for rate in [44_100, 48_000, 96_000] {
            // Single mono/stereo samples exercise Data's inline representation.
            for count in [1, 257] {
                let data = Self.pcm(samples: count, channels: channels)
                let timestamp = CMTime(value: -137, timescale: Int32(rate))
                let format = try Self.format(rate: rate, channels: channels)
                let sample = try SampleBufferAudioPresenter.makeSampleBuffer(
                    Self.frame(data, samples: count, channels: channels,
                               rate: rate, timestamp: timestamp),
                    formatDescription: format
                )
                #expect(CMSampleBufferIsValid(sample))
                #expect(CMSampleBufferDataIsReady(sample))
                #expect(CMSampleBufferGetNumSamples(sample) == count)
                #expect(CMSampleBufferGetTotalSampleSize(sample) == data.count)
                #expect(CMSampleBufferGetSampleSize(sample, at: 0) == channels * 4)
                #expect(CMSampleBufferGetSampleSize(sample, at: count - 1) == channels * 4)
                #expect(CMSampleBufferGetPresentationTimeStamp(sample) == timestamp)
                #expect(!CMSampleBufferGetDecodeTimeStamp(sample).isValid)
                #expect(CMTimeCompare(
                    CMSampleBufferGetDuration(sample),
                    CMTime(value: Int64(count), timescale: Int32(rate))
                ) == 0)
                var timing = CMSampleTimingInfo(
                    duration: .invalid, presentationTimeStamp: .invalid,
                    decodeTimeStamp: .invalid
                )
                #expect(CMSampleBufferGetSampleTimingInfo(
                    sample, at: 0, timingInfoOut: &timing
                ) == noErr)
                #expect(timing.duration == CMTime(value: 1, timescale: Int32(rate)))
                #expect(timing.presentationTimeStamp == timestamp)
                let actualFormat = try #require(CMSampleBufferGetFormatDescription(sample))
                #expect(CMFormatDescriptionEqual(actualFormat, otherFormatDescription: format))
                #expect(try Self.bytes(CMSampleBufferGetDataBuffer(sample)) == data)
            }
        }
    }

    @Test(arguments: [1, 2, 6, 8])
    func heapBackedFramesShareStorage(channels: Int) throws {
        let frame = Self.frame(Self.pcm(samples: 1_024, channels: channels),
                               samples: 1_024, channels: channels)
        let sample = try SampleBufferAudioPresenter.makeSampleBuffer(
            frame, formatDescription: Self.format(channels: channels)
        )
        let block = try #require(CMSampleBufferGetDataBuffer(sample))
        var contiguous = 0
        var total = 0
        var pointer: UnsafeMutablePointer<CChar>?
        #expect(CMBlockBufferGetDataPointer(
            block, atOffset: 0, lengthAtOffsetOut: &contiguous,
            totalLengthOut: &total, dataPointerOut: &pointer
        ) == noErr)
        let blockPointer = try #require(pointer)
        frame.interleavedFloatPCM.withUnsafeBytes { original in
            #expect(UnsafeRawPointer(blockPointer) == original.baseAddress)
            #expect(contiguous == original.count)
            #expect(total == original.count)
        }
        withExtendedLifetime((frame, sample, block)) {}
    }

    @Test func lastCoreMediaOwnerReleasesOriginalPCMExactlyOnce() throws {
        let released = ReleaseProbe()
        var samples = try autoreleasepool { try Self.ownedSamples(released: released) }
        try #require(samples.count == 2)
        #expect(released.count == 0)
        var retainedBlock: CMBlockBuffer? = CMSampleBufferGetDataBuffer(samples[0])
        autoreleasepool { _ = samples.removeFirst() }
        #expect(released.count == 0)
        #expect(try Self.bytes(CMSampleBufferGetDataBuffer(samples[0])) ==
            Data(repeating: 0x3f, count: Self.ownedByteCount))
        autoreleasepool { samples.removeAll(keepingCapacity: false) }
        #expect(released.count == 0)
        #expect(try Self.bytes(retainedBlock) == Data(repeating: 0x3f, count: Self.ownedByteCount))
        autoreleasepool { retainedBlock = nil }
        #expect(released.count == 1)
    }

    @Test func callerMutationDoesNotChangePresentedBytes() throws {
        var source = Self.pcm(samples: 1_024, channels: 2)
        // An Array snapshot avoids introducing a second Data storage owner.
        let expected = Array(source)
        let format = try Self.format()
        let sample = try autoreleasepool {
            try SampleBufferAudioPresenter.makeSampleBuffer(
                Self.frame(source, samples: 1_024, channels: 2),
                formatDescription: format
            )
        }
        withExtendedLifetime(sample) {
            source.withUnsafeMutableBytes { bytes in
                _ = bytes.initializeMemory(as: UInt8.self, repeating: 0xa5)
            }
        }
        #expect(source.allSatisfy { $0 == 0xa5 })
        #expect(Array(try Self.bytes(CMSampleBufferGetDataBuffer(sample))) == expected)
    }

    @Test(arguments: [1, 3, 16, 31])
    func slicesSurviveTheirParentAndPreserveTheirByteRange(prefix: Int) throws {
        let expected = Self.pcm(samples: 257, channels: 6)
        let sample = try autoreleasepool {
            let backing = Data(repeating: 0xa5, count: prefix)
                + expected + Data(repeating: 0x5a, count: 29)
            let slice = backing[prefix..<(prefix + expected.count)]
            #expect(slice.startIndex == prefix)
            return try SampleBufferAudioPresenter.makeSampleBuffer(
                Self.frame(slice, samples: 257, channels: 6),
                formatDescription: Self.format(channels: 6)
            )
        }
        #expect(try Self.bytes(CMSampleBufferGetDataBuffer(sample)) == expected)
        #expect(CMSampleBufferGetNumSamples(sample) == 257)
    }

    @Test func invalidFramesRemainRejected() throws {
        let format = try Self.format()
        let invalid: [(bytes: Int, samples: Int, channels: Int, rate: Int)] = [
            (0, 0, 2, 48_000), (0, -1, 2, 48_000), (8, 1, 2, 0),
            (12, 1, 3, 48_000), (0, 1, 0, 48_000), (7, 1, 2, 48_000),
            (9, 1, 2, 48_000), (8, Int.max, 2, 48_000),
            (8, 1, 2, 44_100), (32, 1, 8, 48_000),
        ]
        for value in invalid {
            let frame = Self.frame(Data(count: value.bytes), samples: value.samples,
                                   channels: value.channels, rate: value.rate)
            #expect(throws: PresentationError.self) {
                try SampleBufferAudioPresenter.makeSampleBuffer(frame, formatDescription: format)
            }
        }
    }

    @Test func emptyPCMIsRejected() {
        let backing = Data(repeating: 0x3f, count: 64)
        for empty in [Data(), backing[32..<32]] {
            #expect(throws: PresentationError.self) { try AudioPCMBlockBuffer.make(empty) }
        }
    }

    @Test func failedBlockAllocationDoesNotLeakOrFreeCallerStorage() {
        let released = ReleaseProbe()
        for expectedReleases in 1...3 {
            autoreleasepool { Self.attemptRejectedAllocation(released: released) }
            #expect(released.count == expectedReleases)
        }
    }

    @inline(never)
    private static func attemptRejectedAllocation(released: ReleaseProbe) {
        let previous = released.count
        let data = trackedPCM(released: released)
        // Fail the CMBlockBuffer structure allocation, before ownership transfer.
        #expect(throws: (any Error).self) {
            try AudioPCMBlockBuffer.make(data, allocator: kCFAllocatorNull)
        }
        withExtendedLifetime(data) {
            #expect(released.count == previous)
            #expect(data.count == ownedByteCount)
            #expect(data.allSatisfy { $0 == 0x3f })
        }
    }

    private static let ownedSamplesCount = 4_096
    private static let ownedByteCount = ownedSamplesCount * 2 * MemoryLayout<Float>.size

    private static func format(rate: Int = 48_000, channels: Int = 2) throws -> CMAudioFormatDescription {
        try SampleBufferAudioPresenter.makeFormatDescription(sampleRate: rate, channelCount: channels)
    }

    private static func pcm(samples: Int, channels: Int) -> Data {
        let values = (0..<(samples * channels)).map { Float(($0 % 31) - 15) / 32 }
        return values.withUnsafeBytes { Data($0) }
    }

    private static func frame(_ data: Data, samples: Int, channels: Int, rate: Int = 48_000,
                              timestamp: CMTime = .zero) -> NativeDecodedAudioFrame {
        NativeDecodedAudioFrame(
            interleavedFloatPCM: data, presentationTime: timestamp,
            duration: CMTime(value: Int64(samples), timescale: Int32(clamping: rate)),
            generation: 4, sampleRate: rate, channelCount: channels, sampleCount: samples,
            sourceSampleRate: 44_100, sourceChannelCount: 8, sourceChannelLayout: "7.1",
            downmixOccurred: channels < 8, conversionOccurred: true, formatRevision: 17
        )
    }

    private static func trackedPCM(released: ReleaseProbe) -> Data {
        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: ownedByteCount, alignment: MemoryLayout<Float>.alignment
        )
        storage.initializeMemory(as: UInt8.self, repeating: 0x3f, count: ownedByteCount)
        return Data(bytesNoCopy: storage, count: ownedByteCount, deallocator: .custom { pointer, _ in
            pointer.deallocate()
            released.record()
        })
    }

    @inline(never)
    private static func ownedSamples(released: ReleaseProbe) throws -> [CMSampleBuffer] {
        let frame = Self.frame(trackedPCM(released: released), samples: ownedSamplesCount, channels: 2)
        let format = try Self.format()
        return [
            try SampleBufferAudioPresenter.makeSampleBuffer(frame, formatDescription: format),
            try SampleBufferAudioPresenter.makeSampleBuffer(frame, formatDescription: format),
        ]
    }

    private static func bytes(_ optionalBlock: CMBlockBuffer?) throws -> Data {
        let block = try #require(optionalBlock)
        var result = Data(count: CMBlockBufferGetDataLength(block))
        let status = result.withUnsafeMutableBytes { bytes in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes.count,
                                       destination: bytes.baseAddress!)
        }
        try #require(status == noErr)
        return result
    }

    private final class ReleaseProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var releases = 0
        var count: Int { lock.withLock { releases } }
        func record() { lock.withLock { releases += 1 } }
    }
}
