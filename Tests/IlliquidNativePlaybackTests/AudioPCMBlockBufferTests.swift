import CoreMedia
import Foundation
import Synchronization
import Testing
@testable import IlliquidNativePlayback

@Suite("PCM block buffer ownership")
struct AudioPCMBlockBufferTests {
    @Test(arguments: [1, 4, 8, 12, 15, 16, 17, 32, 4_096, 65_536])
    func preservesInlineAndHeapData(byteCount: Int) throws {
        let data = pattern(byteCount)
        let block = try AudioPCMBlockBuffer.make(data)
        #expect(CMBlockBufferGetDataLength(block) == data.count)
        #expect(CMBlockBufferIsRangeContiguous(block, atOffset: 0, length: data.count))
        #expect(try copyBytes(block) == data)
    }

    @Test func rejectsEmptyPCM() {
        #expect(throws: PresentationError.self) {
            try AudioPCMBlockBuffer.make(Data())
        }
    }

    @Test func preservesNonzeroSliceOffsets() throws {
        let parent = pattern(65_536)
        let slice = parent[123..<32_891]
        #expect(slice.startIndex == 123)
        let block = try AudioPCMBlockBuffer.make(slice)
        #expect(CMBlockBufferGetDataLength(block) == slice.count)
        #expect(try copyBytes(block) == slice)
    }

    @Test func preservesPrefixOfLargerBackingStorage() throws {
        let prefix = pattern(1_048_576).prefix(1_024)
        let block = try AudioPCMBlockBuffer.make(prefix)
        #expect(CMBlockBufferGetDataLength(block) == 1_024)
        #expect(try copyBytes(block) == pattern(1_024))
    }

    @Test func preservesDecoderCapacityAfterTrimmingOutputCount() throws {
        // AudioDecoder allocates the resampler's upper bound, fills it, then
        // reduces count to the number of samples the resampler actually wrote.
        var data = Data(count: 16_384)
        data.withUnsafeMutableBytes { bytes in
            for index in bytes.indices { bytes[index] = UInt8(truncatingIfNeeded: index) }
        }
        data.count = 8_192
        let block = try AudioPCMBlockBuffer.make(data)
        #expect(CMBlockBufferGetDataLength(block) == 8_192)
        #expect(try copyBytes(block) == pattern(8_192))
    }

    @Test(arguments: [8, 8_192, 65_536])
    func mutatingSourceAndAliasPreservesPresentationBytes(byteCount: Int) throws {
        var source = pattern(byteCount)
        var alias = source
        let block = try AudioPCMBlockBuffer.make(source)
        source.withUnsafeMutableBytes { bytes in
            bytes.initializeMemory(as: UInt8.self, repeating: 0xA5)
        }
        alias.replaceSubrange(alias.startIndex..<alias.endIndex, with: repeatElement(UInt8(0x5A), count: byteCount))
        #expect(source != alias)
        #expect(try copyBytes(block) == pattern(byteCount))
    }

    @Test func releasesSharedBackingOnceAfterLastBlockReference() throws {
        let releases = ReleaseCounter()
        var original: CMBlockBuffer? = try autoreleasepool {
            try AudioPCMBlockBuffer.make(trackedData(byteCount: 8_192, releases: releases))
        }
        #expect(releases.count == 0)
        var reference: CMBlockBuffer?
        try checkOSStatus(
            CMBlockBufferCreateWithBufferReference(
                allocator: kCFAllocatorDefault,
                referenceBuffer: try #require(original),
                offsetToData: 128,
                dataLength: 4_096,
                flags: 0,
                blockBufferOut: &reference
            ),
            operation: "Reference retained PCM"
        )
        autoreleasepool { original = nil }
        #expect(releases.count == 0)
        #expect(try copyBytes(try #require(reference)) == pattern(8_192)[128..<4_224])
        autoreleasepool { reference = nil }
        #expect(releases.count == 1)
    }

    @Test(arguments: [1, 2, 6, 8])
    func sampleBufferOutlivesDecodedFrameAndReleasesItsPCM(channels: Int) throws {
        let sampleCount = 257
        let byteCount = sampleCount * channels * MemoryLayout<Float>.size
        let releases = ReleaseCounter()
        let time = CMTime(value: 12_345, timescale: 48_000)
        var sample: CMSampleBuffer? = try autoreleasepool {
            let frame = makeFrame(
                data: trackedData(byteCount: byteCount, releases: releases),
                sampleCount: sampleCount,
                channels: channels,
                time: time
            )
            let format = try SampleBufferAudioPresenter.makeFormatDescription(
                sampleRate: frame.sampleRate,
                channelCount: channels
            )
            return try SampleBufferAudioPresenter.makeSampleBuffer(frame, formatDescription: format)
        }
        #expect(releases.count == 0)
        try autoreleasepool {
            let retainedSample = try #require(sample)
            #expect(CMSampleBufferGetNumSamples(retainedSample) == sampleCount)
            #expect(CMSampleBufferGetPresentationTimeStamp(retainedSample) == time)
            #expect(CMSampleBufferGetDuration(retainedSample) == CMTime(value: Int64(sampleCount), timescale: 48_000))
            let block = try #require(CMSampleBufferGetDataBuffer(retainedSample))
            #expect(try copyBytes(block) == pattern(byteCount))
        }
        autoreleasepool { sample = nil }
        #expect(releases.count == 1)
    }

    @Test func frameValidationStillRejectsMismatchedBackingBytes() throws {
        let format = try SampleBufferAudioPresenter.makeFormatDescription(sampleRate: 48_000, channelCount: 2)
        let frame = makeFrame(data: pattern(15), sampleCount: 2, channels: 2, time: .zero)
        #expect(throws: PresentationError.self) {
            try SampleBufferAudioPresenter.makeSampleBuffer(frame, formatDescription: format)
        }
    }

    private func pattern(_ count: Int) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: $0) })
    }

    private func copyBytes(_ block: CMBlockBuffer) throws -> Data {
        var data = Data(count: CMBlockBufferGetDataLength(block))
        let status = data.withUnsafeMutableBytes { bytes in
            CMBlockBufferCopyDataBytes(
                block,
                atOffset: 0,
                dataLength: bytes.count,
                destination: bytes.baseAddress!
            )
        }
        try checkOSStatus(status, operation: "Read retained PCM")
        return data
    }

    private func trackedData(byteCount: Int, releases: ReleaseCounter) -> Data {
        let memory = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: MemoryLayout<Float>.alignment)
        let bytes = memory.bindMemory(to: UInt8.self, capacity: byteCount)
        for index in 0..<byteCount { bytes[index] = UInt8(truncatingIfNeeded: index) }
        return Data(bytesNoCopy: memory, count: byteCount, deallocator: .custom { memory, _ in
            memory.deallocate()
            releases.record()
        })
    }

    private func makeFrame(data: Data, sampleCount: Int, channels: Int, time: CMTime) -> NativeDecodedAudioFrame {
        NativeDecodedAudioFrame(
            interleavedFloatPCM: data,
            presentationTime: time,
            duration: CMTime(value: Int64(sampleCount), timescale: 48_000),
            generation: 7,
            sampleRate: 48_000,
            channelCount: channels,
            sampleCount: sampleCount,
            sourceSampleRate: 48_000,
            sourceChannelCount: channels,
            sourceChannelLayout: "test",
            downmixOccurred: false,
            conversionOccurred: false
        )
    }

    private final class ReleaseCounter: Sendable {
        private let value = Atomic(0)
        var count: Int { value.load(ordering: .acquiring) }
        func record() { _ = value.add(1, ordering: .releasing) }
    }
}
