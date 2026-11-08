import Foundation
import Testing
@testable import IlliquidNativePlayback

@Suite("Playback resource telemetry")
struct PlaybackResourceTelemetryTests {
    @Test func distributionReportsQuantileMaximumAndStalls() {
        var distribution = PlaybackResourceTelemetry.Distribution()
        #expect(distribution.quantileUpperBound(0.95) == nil)
        for _ in 0..<95 { distribution.record(milliseconds: 3) }
        for _ in 0..<5 { distribution.record(milliseconds: 70) }
        distribution.record(milliseconds: .nan)
        distribution.record(milliseconds: -1)
        #expect(distribution.count == 100)
        // Exact nearest-rank quantiles while every sample is retained.
        #expect(distribution.quantileUpperBound(0.95) == 3)
        #expect(distribution.quantileUpperBound(0.96) == 70)
        #expect(distribution.maximumMilliseconds == 70)
        #expect(distribution.count(above: 50) == 5)
        #expect(distribution.count(above: 4) == 5)
    }

    @Test func beyondTheSampleLimitQuantilesFallBackToBucketBounds() {
        var distribution = PlaybackResourceTelemetry.Distribution()
        for _ in 0..<PlaybackResourceTelemetry.Distribution.exactSampleLimit { distribution.record(milliseconds: 3) }
        // Past the limit, the (2, 4] bucket bound applies; the 9 ms maximum
        // keeps the bound from being capped back down to the 3 ms samples.
        distribution.record(milliseconds: 9)
        #expect(distribution.samples.count == PlaybackResourceTelemetry.Distribution.exactSampleLimit)
        #expect(distribution.quantileUpperBound(0.95) == 4)
    }

    @Test func windowTracksLowWaterMarksThenResets() {
        let telemetry = PlaybackResourceTelemetry()
        telemetry.observeVideoPackets(BoundedQueueBudgetSnapshot(items: 10, bytes: 4_000, durationMicroseconds: 2_000_000))
        telemetry.observeVideoPackets(BoundedQueueBudgetSnapshot(items: 2, bytes: 9_000, durationMicroseconds: 250_000))
        telemetry.observeAudioPackets(BoundedQueueBudgetSnapshot(items: 4, bytes: 512, durationMicroseconds: 500_000))
        telemetry.observeVideoFrameQueue(depth: 8)
        telemetry.observeVideoFrameQueue(depth: 1)
        telemetry.observeRendererVideoAhead(0.4)
        telemetry.observeRendererVideoAhead(0.1)
        telemetry.observeRendererVideoAhead(.infinity)
        telemetry.recordDemuxRead(milliseconds: 2)
        let window = telemetry.drain()
        #expect(window.videoPacketAheadLowSeconds == 0.25)
        #expect(window.audioPacketAheadLowSeconds == 0.5)
        #expect(window.videoFrameQueueLow == 1)
        #expect(window.rendererVideoAheadLowSeconds == 0.1)
        #expect(window.demuxRead.count == 1)

        let next = telemetry.drain()
        #expect(next.videoFrameQueueLow == nil)
        #expect(next.demuxRead.count == 0)

        telemetry.observeVideoFrameQueue(depth: 0)
        telemetry.reset()
        #expect(telemetry.drain().videoFrameQueueLow == nil)
    }
}
