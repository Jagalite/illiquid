import CoreMedia
import Foundation
import Testing
@testable import IlliquidNativePlayback

@Suite("Audio delay PCM ownership")
struct AudioDelayMemoryTests {
    @Test(arguments: [1, 2, 6, 8])
    func retainedFullSilenceChunksShareStorageAndTailHasExactSize(channels: Int) throws {
        let silenceSamples = 3 * 1_024 + 76
        let source = frame(samples: 480, channels: channels)
        var timeline = AudioDelayTimeline(delay: Double(silenceSamples) / 48_000)
        var output: [NativeDecodedAudioFrame] = []
        #expect(timeline.consume(source) { output.append($0); return true })
        try #require(output.count == 5)

        for index in 0..<3 {
            #expect(output[index].sampleCount == 1_024)
            #expect(output[index].interleavedFloatPCM.count == 1_024 * channels * 4)
            #expect(abs(output[index].presentationTime.seconds - Double(index * 1_024) / 48_000) < 1e-9)
            expectSharedStorage(output[0].interleavedFloatPCM, output[index].interleavedFloatPCM)
        }
        #expect(output[3].sampleCount == 76)
        #expect(output[3].interleavedFloatPCM.count == 76 * channels * 4)
        #expect(output.dropLast().allSatisfy { $0.interleavedFloatPCM.allSatisfy { $0 == 0 } })
        #expect(output.dropLast().reduce(0) { $0 + $1.sampleCount } == silenceSamples)
        #expect(output.last?.interleavedFloatPCM == source.interleavedFloatPCM)
        for emitted in output { expectFormat(emitted, matches: source) }
        withExtendedLifetime((source, output)) {}
    }

    @Test func mutatingOneSilenceCopyDoesNotChangeOtherOwners() throws {
        let source = frame(samples: 480, channels: 8)
        var timeline = AudioDelayTimeline(delay: Double(3 * 1_024) / 48_000)
        var output: [NativeDecodedAudioFrame] = []
        #expect(timeline.consume(source) { output.append($0); return true })
        try #require(output.count == 4)
        expectSharedStorage(output[0].interleavedFloatPCM, output[1].interleavedFloatPCM)

        var changed = output[0].interleavedFloatPCM
        changed.withUnsafeMutableBytes { bytes in
            bytes[0] = UInt8(0x7f)
            bytes[bytes.count - 1] = UInt8(0x3f)
        }
        #expect(changed.first == 0x7f)
        #expect(changed.last == 0x3f)
        #expect(output.allSatisfy { $0.interleavedFloatPCM.allSatisfy { $0 == 0 } })
        #expect(source.interleavedFloatPCM.allSatisfy { $0 == 0 })

        // Removing one retained frame cannot invalidate its siblings.
        output.removeFirst()
        #expect(output.allSatisfy { $0.interleavedFloatPCM.allSatisfy { $0 == 0 } })
        withExtendedLifetime((source, output, changed)) {}
    }

    @Test func completedInputStorageIsReleasedWhileTailFormatRemainsAvailable() throws {
        let released = ReleaseProbe()
        var timeline = AudioDelayTimeline(delay: -0.01)
        var output: [NativeDecodedAudioFrame] = []
        let accepted = timeline.consume(ownedFrame(released: released)) {
            output.append($0)
            return true
        }
        #expect(accepted)
        try #require(output.count == 1)
        #expect(output[0].sampleCount == 4_096)
        #expect(released.count == 0)

        withExtendedLifetime(output) {}
        output.removeAll()
        // The timeline remains alive and will need the source's format below,
        // but its metadata template must not keep the source allocation alive.
        #expect(released.count == 1)

        let endSamples = 4_096 + 1_024 + 53
        let fallback = frame(samples: 1, channels: 1, revision: 99)
        #expect(timeline.finish(duration: Double(endSamples) / 48_000, fallback: fallback) {
            output.append($0)
            return true
        })
        try #require(output.count == 2)
        #expect(output.map(\.sampleCount) == [1_024, 53])
        for emitted in output {
            #expect(emitted.channelCount == 2)
            #expect(emitted.sampleRate == 48_000)
            #expect(emitted.sourceSampleRate == 44_100)
            #expect(emitted.sourceChannelCount == 8)
            #expect(emitted.sourceChannelLayout == "7.1")
            #expect(emitted.generation == 4)
            #expect(emitted.formatRevision == 17)
            #expect(emitted.downmixOccurred)
            #expect(emitted.conversionOccurred)
            #expect(emitted.interleavedFloatPCM.count == emitted.sampleCount * 2 * 4)
            #expect(emitted.interleavedFloatPCM.allSatisfy { $0 == 0 })
        }
        #expect(abs(timeline.cursor - Double(endSamples) / 48_000) < 1e-9)
        #expect(released.count == 1)
        withExtendedLifetime((timeline, output)) {}
    }

    @Test(arguments: [0, 2, 3])
    func rejectedSilenceDoesNotAdvancePastAcceptedChunks(acceptedChunks: Int) throws {
        let source = frame(samples: 480, channels: 6)
        var timeline = AudioDelayTimeline(delay: Double(3 * 1_024 + 76) / 48_000)
        var attempts: [NativeDecodedAudioFrame] = []
        #expect(!timeline.consume(source) {
            attempts.append($0)
            return attempts.count <= acceptedChunks
        })
        try #require(attempts.count == acceptedChunks + 1)
        #expect(abs(timeline.cursor - Double(acceptedChunks * 1_024) / 48_000) < 1e-9)
        #expect(attempts.last?.sampleCount == (acceptedChunks == 3 ? 76 : 1_024))
        #expect(attempts.allSatisfy { $0.interleavedFloatPCM.allSatisfy { $0 == 0 } })
        for attempted in attempts { expectFormat(attempted, matches: source) }
        if attempts.count >= 2 {
            expectSharedStorage(attempts[0].interleavedFloatPCM, attempts[1].interleavedFloatPCM)
        }
        withExtendedLifetime(attempts) {}
    }

    @Test func tailPaddingUsesTheLatestFormatAfterAFormatChange() throws {
        var timeline = AudioDelayTimeline(delay: -0.01)
        let first = frame(time: 0.01, samples: 480, channels: 2)
        let latest = frame(time: 0.02, samples: 480, channels: 8, revision: 18, generation: 5)
        #expect(timeline.consume(first) { _ in true })
        #expect(timeline.consume(latest) { _ in true })
        let endSamples = 960 + 2 * 1_024 + 76
        var tail: [NativeDecodedAudioFrame] = []
        #expect(timeline.finish(duration: Double(endSamples) / 48_000, fallback: first) {
            tail.append($0)
            return true
        })
        try #require(tail.count == 3)
        #expect(tail.map(\.sampleCount) == [1_024, 1_024, 76])
        expectSharedStorage(tail[0].interleavedFloatPCM, tail[1].interleavedFloatPCM)
        for emitted in tail {
            expectFormat(emitted, matches: latest)
            #expect(emitted.interleavedFloatPCM.count == emitted.sampleCount * 8 * 4)
            #expect(emitted.interleavedFloatPCM.allSatisfy { $0 == 0 })
        }
        #expect(abs(timeline.cursor - Double(endSamples) / 48_000) < 1e-9)
    }

    @Test(arguments: [0, 128, 1_024, 1_028])
    func shortPrefixesPreserveExactSampleAndByteCounts(silenceSamples: Int) throws {
        let source = frame(samples: 480, channels: 1)
        var timeline = AudioDelayTimeline(delay: Double(silenceSamples) / 48_000)
        var output: [NativeDecodedAudioFrame] = []
        #expect(timeline.consume(source) { output.append($0); return true })
        try #require(!output.isEmpty)
        #expect(output.dropLast().reduce(0) { $0 + $1.sampleCount } == silenceSamples)
        #expect(output.dropLast().allSatisfy {
            $0.sampleCount > 0 && $0.sampleCount <= 1_024
                && $0.interleavedFloatPCM.count == $0.sampleCount * 4
                && $0.interleavedFloatPCM.allSatisfy { $0 == 0 }
        })
        #expect(output.last?.interleavedFloatPCM == source.interleavedFloatPCM)
        #expect(output.count == (silenceSamples + 1_023) / 1_024 + 1)
    }

    private func frame(time: Double = 0, samples: Int, channels: Int,
                       revision: UInt64 = 17, generation: Int = 4,
                       data: Data? = nil) -> NativeDecodedAudioFrame {
        NativeDecodedAudioFrame(
            interleavedFloatPCM: data ?? Data(count: samples * channels * 4),
            presentationTime: CMTime(seconds: time, preferredTimescale: 48_000),
            duration: CMTime(value: Int64(samples), timescale: 48_000),
            generation: generation, sampleRate: 48_000, channelCount: channels, sampleCount: samples,
            sourceSampleRate: 44_100, sourceChannelCount: 8, sourceChannelLayout: "7.1",
            downmixOccurred: channels < 8, conversionOccurred: true, formatRevision: revision
        )
    }

    @inline(never)
    private func ownedFrame(released: ReleaseProbe) -> NativeDecodedAudioFrame {
        let byteCount = 4_096 * 2 * MemoryLayout<Float>.size
        let storage = UnsafeMutableRawPointer.allocate(byteCount: byteCount,
                                                       alignment: MemoryLayout<Float>.alignment)
        storage.initializeMemory(as: UInt8.self, repeating: 0x3f, count: byteCount)
        let data = Data(bytesNoCopy: storage, count: byteCount, deallocator: .custom { pointer, _ in
            pointer.deallocate()
            released.record()
        })
        return frame(time: 0.01, samples: 4_096, channels: 2, data: data)
    }

    private func expectFormat(_ value: NativeDecodedAudioFrame, matches source: NativeDecodedAudioFrame) {
        #expect(value.generation == source.generation)
        #expect(value.sampleRate == source.sampleRate)
        #expect(value.channelCount == source.channelCount)
        #expect(value.sourceSampleRate == source.sourceSampleRate)
        #expect(value.sourceChannelCount == source.sourceChannelCount)
        #expect(value.sourceChannelLayout == source.sourceChannelLayout)
        #expect(value.downmixOccurred == source.downmixOccurred)
        #expect(value.conversionOccurred == source.conversionOccurred)
        #expect(value.formatRevision == source.formatRevision)
    }

    private func expectSharedStorage(_ lhs: Data, _ rhs: Data) {
        // Both borrows and both owners are alive at the comparison. These
        // buffers are larger than Data's inline representation.
        lhs.withUnsafeBytes { left in
            rhs.withUnsafeBytes { right in
                #expect(left.baseAddress == right.baseAddress)
                #expect(left.count == right.count)
            }
        }
    }

    private final class ReleaseProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var releases = 0
        var count: Int { lock.withLock { releases } }
        func record() { lock.withLock { releases += 1 } }
    }
}
