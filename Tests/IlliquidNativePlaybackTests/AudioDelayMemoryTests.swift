import CoreMedia
import Foundation
import Testing
@testable import IlliquidNativePlayback

@Suite("Audio delay PCM ownership")
struct AudioDelayMemoryTests {
    @Test(arguments: [0.0, 0.1, -0.005])
    func sourcePCMIsReleasedAfterEmittedFramesAreDiscarded(delay: Double) {
        let tracker = AudioDelayAllocationTracker()
        var timeline = AudioDelayTimeline(delay: delay)
        var emitted = 0
        let consumed = consumeTrackedFrame(in: &timeline, tracker: tracker) { frame in
            #expect(frame.sampleCount > 0)
            emitted += 1
            return true
        }
        #expect(consumed)
        #expect(emitted > 0)
        #expect(tracker.snapshot == .init(allocations: 1, releases: 1, liveBytes: 0))
        // The timeline remains usable after its source PCM allocation is gone.
        #expect(timeline.finish(duration: nil, fallback: makeFrame()) { _ in true })
    }

    @Test func fullyTrimmedSourcePCMIsReleased() {
        let tracker = AudioDelayAllocationTracker()
        var timeline = AudioDelayTimeline(delay: -1, target: 2)
        var emitted = 0
        #expect(consumeTrackedFrame(in: &timeline, tracker: tracker) { _ in
            emitted += 1
            return true
        })
        #expect(emitted == 0)
        #expect(timeline.cursor == 2)
        #expect(tracker.snapshot == .init(allocations: 1, releases: 1, liveBytes: 0))

        var fallbackOutput: [NativeDecodedAudioFrame] = []
        #expect(timeline.finish(duration: nil, fallback: makeFrame(channelCount: 1)) {
            fallbackOutput.append($0)
            return true
        })
        checkSilence(fallbackOutput, samples: 1, channelCount: 2, startingAt: 96_000)
        #expect(fallbackOutput.first?.generation == 17)
        #expect(fallbackOutput.first?.formatRevision == 23)
    }

    @Test func canceledSourceEmissionReleasesPCM() {
        let tracker = AudioDelayAllocationTracker()
        var timeline = AudioDelayTimeline(delay: 0)
        var calls = 0
        let consumed = consumeTrackedFrame(in: &timeline, tracker: tracker) { frame in
            calls += 1
            #expect(frame.sampleCount == 2_048)
            return false
        }
        #expect(!consumed)
        #expect(calls == 1)
        #expect(timeline.cursor == 0)
        #expect(tracker.snapshot == .init(allocations: 1, releases: 1, liveBytes: 0))
        withExtendedLifetime(timeline) {}
    }

    @Test(arguments: [0, 2])
    func canceledSilenceEmissionReleasesSourceAndPreservesAcceptedCursor(acceptedChunks: Int) {
        let tracker = AudioDelayAllocationTracker()
        var timeline = AudioDelayTimeline(delay: 0.1)
        var calls = 0
        let consumed = consumeTrackedFrame(in: &timeline, tracker: tracker) { frame in
            calls += 1
            #expect(frame.sampleCount == 1_024)
            #expect(frame.interleavedFloatPCM.allSatisfy { $0 == 0 })
            return calls <= acceptedChunks
        }
        #expect(!consumed)
        #expect(calls == acceptedChunks + 1)
        #expect(timeline.cursor == Double(acceptedChunks * 1_024) / 48_000)
        #expect(tracker.snapshot == .init(allocations: 1, releases: 1, liveBytes: 0))
        withExtendedLifetime(timeline) {}
    }

    @Test func emittedPCMRemainsAliveUntilConsumerReleasesIt() {
        let tracker = AudioDelayAllocationTracker()
        var timeline = AudioDelayTimeline(delay: 0)
        var retained: NativeDecodedAudioFrame?
        #expect(consumeTrackedFrame(in: &timeline, tracker: tracker) {
            retained = $0
            return true
        })
        withExtendedLifetime(retained) {
            #expect(retained?.sampleCount == 2_048)
            #expect(tracker.snapshot == .init(allocations: 1, releases: 0, liveBytes: 16_384))
            #expect(retained?.interleavedFloatPCM.withUnsafeBytes {
                $0.loadUnaligned(as: Float.self)
            } == 0.25)
        }
        retained = nil
        #expect(tracker.snapshot == .init(allocations: 1, releases: 1, liveBytes: 0))
        #expect(timeline.finish(duration: nil, fallback: makeFrame()) { _ in true })
    }

    @Test func latestSourceMetadataDrivesTailSilence() {
        var timeline = AudioDelayTimeline(delay: -10)
        let first = makeFrame(sampleRate: 44_100, generation: 1, formatRevision: 2)
        let latest = makeFrame(
            time: 1, sampleCount: 720, channelCount: 6,
            generation: 31, sourceSampleRate: 96_000, sourceChannelCount: 8,
            sourceChannelLayout: "7.1", downmixOccurred: true,
            conversionOccurred: true, formatRevision: 47
        )
        var initialOutput: [NativeDecodedAudioFrame] = []
        for source in [first, latest] {
            #expect(timeline.consume(source) { initialOutput.append($0); return true })
        }
        #expect(initialOutput.isEmpty)

        var output: [NativeDecodedAudioFrame] = []
        #expect(timeline.finish(
            duration: 2_305.0 / 48_000,
            fallback: makeFrame(channelCount: 1, generation: 99, formatRevision: 99)
        ) { output.append($0); return true })
        checkSilence(output, samples: 2_305, channelCount: 6)
        for frame in output {
            #expect(frame.generation == latest.generation)
            #expect(frame.sampleRate == latest.sampleRate)
            #expect(frame.sourceSampleRate == latest.sourceSampleRate)
            #expect(frame.sourceChannelCount == latest.sourceChannelCount)
            #expect(frame.sourceChannelLayout == latest.sourceChannelLayout)
            #expect(frame.downmixOccurred == latest.downmixOccurred)
            #expect(frame.conversionOccurred == latest.conversionOccurred)
            #expect(frame.formatRevision == latest.formatRevision)
        }
        #expect(timeline.cursor == 2_305.0 / 48_000)
    }

    @Test(arguments: [1, 2, 6, 8], [1, 1_024, 1_025, 2_305])
    func positivePaddingPreservesSilenceBoundaries(channelCount: Int, paddingSamples: Int) {
        let delay = Double(paddingSamples) / 48_000
        var timeline = AudioDelayTimeline(delay: delay)
        let source = makeFrame(sampleCount: 17, channelCount: channelCount)
        var output: [NativeDecodedAudioFrame] = []
        #expect(timeline.consume(source) { output.append($0); return true })
        checkSilence(Array(output.dropLast()), samples: paddingSamples, channelCount: channelCount)
        #expect(output.last?.interleavedFloatPCM == source.interleavedFloatPCM)
        #expect(output.last?.sampleCount == source.sampleCount)
        #expect(output.last?.presentationTime == CMTimeAdd(
            source.presentationTime, CMTime(seconds: delay, preferredTimescale: 60_000)
        ))
        #expect(output.last?.duration == source.duration)
        #expect(output.allSatisfy { $0.generation == source.generation && $0.formatRevision == source.formatRevision })
    }

    @Test(arguments: [1, 2, 6, 8])
    func emptyTimelineEmitsOneSilentFallbackSample(channelCount: Int) {
        var timeline = AudioDelayTimeline(delay: 0, target: 2)
        let fallback = makeFrame(channelCount: channelCount, generation: 11, formatRevision: 13)
        var output: [NativeDecodedAudioFrame] = []
        #expect(timeline.finish(duration: nil, fallback: fallback) {
            output.append($0)
            return true
        })
        checkSilence(output, samples: 1, channelCount: channelCount, startingAt: 96_000)
        #expect(output.first?.generation == 11)
        #expect(output.first?.formatRevision == 13)
        #expect(timeline.cursor == 96_001.0 / 48_000)
    }

    @Test(arguments: [1, 2, 6, 8])
    func silenceFramesKeepValueSemanticsWhenCopiedAndTrimmed(channelCount: Int) throws {
        var timeline = AudioDelayTimeline(delay: 2_305.0 / 48_000)
        var output: [NativeDecodedAudioFrame] = []
        #expect(timeline.consume(makeFrame(channelCount: channelCount)) {
            output.append($0)
            return true
        })
        let silence = Array(output.dropLast())
        #expect(silence.count == 3)
        let first = try #require(silence.first)
        var changed = first.interleavedFloatPCM
        changed[changed.startIndex] = 0xff
        #expect(changed.first == 0xff)
        #expect(first.interleavedFloatPCM.allSatisfy { $0 == 0 })
        #expect(silence.allSatisfy { $0.interleavedFloatPCM.allSatisfy { $0 == 0 } })

        let trimmed = try #require(first.trimmingSamples(before: 256.0 / 48_000))
        #expect(trimmed.sampleCount > 0 && trimmed.sampleCount < first.sampleCount)
        var changedTrim = trimmed.interleavedFloatPCM
        changedTrim[changedTrim.startIndex] = 0x7f
        #expect(changedTrim.first == 0x7f)
        #expect(trimmed.interleavedFloatPCM.allSatisfy { $0 == 0 })
        #expect(silence.allSatisfy { $0.interleavedFloatPCM.allSatisfy { $0 == 0 } })
    }

    private func checkSilence(
        _ frames: [NativeDecodedAudioFrame], samples: Int,
        channelCount: Int, startingAt start: Int64 = 0
    ) {
        #expect(frames.count == (samples + 1_023) / 1_024)
        var remaining = samples
        var nextSample = start
        for frame in frames {
            let count = min(1_024, remaining)
            #expect(frame.sampleCount == count)
            #expect(frame.channelCount == channelCount)
            #expect(frame.sampleRate == 48_000)
            #expect(frame.interleavedFloatPCM.count == count * channelCount * MemoryLayout<Float>.size)
            #expect(frame.interleavedFloatPCM.allSatisfy { $0 == 0 })
            #expect(frame.presentationTime == CMTime(value: nextSample, timescale: 48_000))
            #expect(frame.duration == CMTime(value: Int64(count), timescale: 48_000))
            remaining -= count
            nextSample += Int64(count)
        }
        #expect(remaining == 0)
    }

    /// Keep the source's ownership in a separate call frame so the release
    /// assertion does not depend on debug versus optimized local lifetimes.
    @inline(never)
    private func consumeTrackedFrame(
        in timeline: inout AudioDelayTimeline,
        tracker: AudioDelayAllocationTracker,
        emit: (NativeDecodedAudioFrame) -> Bool
    ) -> Bool {
        let sampleCount = 2_048
        let channelCount = 2
        let byteCount = sampleCount * channelCount * MemoryLayout<Float>.size
        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: byteCount, alignment: MemoryLayout<Float>.alignment
        )
        storage.initializeMemory(as: Float.self, repeating: 0.25, count: sampleCount * channelCount)
        tracker.allocated(byteCount)
        let data = Data(bytesNoCopy: storage, count: byteCount, deallocator: .custom { pointer, count in
            pointer.deallocate()
            tracker.released(count)
        })
        let source = makeFrame(sampleCount: sampleCount, data: data)
        return timeline.consume(source, emit: emit)
    }

    private func makeFrame(
        time: Double = 0, sampleCount: Int = 16, channelCount: Int = 2,
        sampleRate: Int = 48_000, generation: Int = 17,
        sourceSampleRate: Int? = nil, sourceChannelCount: Int? = nil,
        sourceChannelLayout: String = "stereo", downmixOccurred: Bool = false,
        conversionOccurred: Bool = false, formatRevision: UInt64 = 23,
        data: Data? = nil
    ) -> NativeDecodedAudioFrame {
        NativeDecodedAudioFrame(
            interleavedFloatPCM: data ?? Data(repeating: 0x3f, count: sampleCount * channelCount * MemoryLayout<Float>.size),
            presentationTime: CMTime(seconds: time, preferredTimescale: Int32(sampleRate)),
            duration: CMTime(value: Int64(sampleCount), timescale: Int32(sampleRate)),
            generation: generation, sampleRate: sampleRate, channelCount: channelCount,
            sampleCount: sampleCount, sourceSampleRate: sourceSampleRate ?? sampleRate,
            sourceChannelCount: sourceChannelCount ?? channelCount, sourceChannelLayout: sourceChannelLayout,
            downmixOccurred: downmixOccurred, conversionOccurred: conversionOccurred,
            formatRevision: formatRevision
        )
    }
}

private final class AudioDelayAllocationTracker: @unchecked Sendable {
    struct Snapshot: Equatable {
        var allocations = 0
        var releases = 0
        var liveBytes = 0
    }

    private let lock = NSLock()
    private var state = Snapshot()

    var snapshot: Snapshot { lock.withLock { state } }

    func allocated(_ bytes: Int) {
        lock.withLock {
            state.allocations += 1
            state.liveBytes += bytes
        }
    }

    func released(_ bytes: Int) {
        lock.withLock {
            state.releases += 1
            state.liveBytes -= bytes
        }
    }
}
