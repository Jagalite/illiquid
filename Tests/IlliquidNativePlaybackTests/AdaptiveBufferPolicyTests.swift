import Foundation
import Testing
@testable import IlliquidNativePlayback

@Suite("Adaptive buffer policy")
struct AdaptiveBufferPolicyTests {
    private let interval = 1.0 / 24
    private func healthy() -> AdaptiveBufferInputs {
        AdaptiveBufferInputs(playing: true, frameInterval: interval, videoDecodeP95: 0.004,
            demuxReadMaximum: 0.002, videoFrameQueueLow: 3, videoPacketAheadLow: 0.8,
            audioPacketAheadLow: 0.8, rendererVideoAheadLow: 0.2)
    }

    @Test func startsSmallAndIgnoresPausedOrSeekingWindows() {
        var policy = AdaptiveBufferPolicy()
        #expect(policy.targets == AdaptiveBufferPolicy.initial)
        var starving = healthy(); starving.starvations = 3; starving.playing = false
        #expect(policy.update(starving) == AdaptiveBufferPolicy.initial)
        starving.playing = true; starving.seeked = true
        #expect(policy.update(starving) == AdaptiveBufferPolicy.initial)
    }

    @Test func starvationGrowsEveryStageQuickly() {
        var policy = AdaptiveBufferPolicy()
        var input = healthy(); input.starvations = 1
        let grown = policy.update(input)
        #expect(grown.videoFrames == 6)
        #expect(grown.videoPacketSeconds == 2)
        #expect(grown.audioPacketSeconds == 2)
        let again = policy.update(input)
        #expect(again.videoFrames == 9)
        #expect(again.videoPacketSeconds == 4)
        #expect(policy.update(input) == AdaptiveBufferPolicy.maximum)
    }

    @Test func decodeCostNearTheFrameIntervalRaisesFrameDepth() {
        var policy = AdaptiveBufferPolicy()
        var input = healthy(); input.videoDecodeP95 = interval * 0.6
        #expect(policy.update(input).videoFrames == 8)
        input.videoDecodeP95 = interval * 0.9
        #expect(policy.update(input).videoFrames == 12)
        // Decode headroom alone does not grow compressed read-ahead.
        #expect(policy.targets.videoPacketSeconds == AdaptiveBufferPolicy.initial.videoPacketSeconds)
    }

    /// Review regression: bucket bounds reported this healthy 60 fps window's
    /// p95 as 12 ms (> half the frame interval) and grew buffers needlessly.
    @Test func healthyDecodeNearABucketEdgeDoesNotGrowBuffers() {
        var distribution = PlaybackResourceTelemetry.Distribution()
        for _ in 0..<95 { distribution.record(milliseconds: 8.1) }
        for _ in 0..<5 { distribution.record(milliseconds: 12) }
        var policy = AdaptiveBufferPolicy()
        var input = healthy()
        input.frameInterval = 1.0 / 60
        input.videoDecodeP95 = distribution.quantileUpperBound(0.95).map { $0 / 1_000 }
        #expect(abs((input.videoDecodeP95 ?? 0) - 0.0081) < 1e-9)
        #expect(policy.update(input) == AdaptiveBufferPolicy.initial)
        #expect(policy.healthyWindows == 1)
    }

    @Test func slowInputGrowsReadAheadButNotFrames() {
        var policy = AdaptiveBufferPolicy()
        var input = healthy(); input.demuxStalls = 1; input.demuxReadMaximum = 0.2
        let targets = policy.update(input)
        #expect(targets.videoFrames == AdaptiveBufferPolicy.initial.videoFrames)
        #expect(targets.videoPacketSeconds == 2)
        #expect(targets.audioPacketSeconds == 2)
    }

    @Test func shrinksOneStepAfterSustainedHealthAndNeverBelowMinimum() {
        var policy = AdaptiveBufferPolicy()
        var starving = healthy(); starving.starvations = 1
        policy.update(starving)
        let grown = policy.targets
        for _ in 0..<(AdaptiveBufferPolicy.healthyWindowsBeforeShrinking - 1) { policy.update(healthy()) }
        #expect(policy.targets == grown)
        policy.update(healthy())
        #expect(policy.targets.videoFrames == grown.videoFrames - 1)
        #expect(policy.targets.videoPacketSeconds == grown.videoPacketSeconds - 0.25)
        for _ in 0..<500 { policy.update(healthy()) }
        #expect(policy.targets == AdaptiveBufferPolicy.minimum)
    }

    @Test func riskResetsTheHealthyRun() {
        var policy = AdaptiveBufferPolicy()
        for _ in 0..<(AdaptiveBufferPolicy.healthyWindowsBeforeShrinking - 1) { policy.update(healthy()) }
        var nearlyDry = healthy(); nearlyDry.videoFrameQueueLow = 0
        policy.update(nearlyDry)
        #expect(policy.healthyWindows == 0)
        #expect(policy.targets.videoFrames == 6)
    }

    @Test func pressureCapsTargets() {
        var policy = AdaptiveBufferPolicy()
        var input = healthy(); input.starvations = 1
        for _ in 0..<4 { policy.update(input) }
        #expect(policy.targets == AdaptiveBufferPolicy.maximum)
        var constrained = healthy(); constrained.constrained = true
        #expect(policy.update(constrained) == AdaptiveBufferPolicy.constrainedCeiling)
        // Pressure applies even while paused.
        var paused = constrained; paused.playing = false
        #expect(policy.update(paused) == AdaptiveBufferPolicy.constrainedCeiling)
    }

    @Test func softLimitsGateAdmissionWithoutDroppingQueuedItems() async {
        let queue = BoundedQueue<Int>(capacity: 8)
        for value in 0..<6 { #expect(queue.push(value)) }
        queue.setSoftLimits(count: 3)
        #expect(queue.count == 6)
        #expect(queue.tryPush(99) == .wouldBlock)
        for _ in 0..<4 { _ = queue.pop() }
        #expect(queue.tryPush(6) == .pushed)
        #expect(queue.tryPush(7) == .wouldBlock)
        queue.setSoftLimits(count: 100)
        #expect(queue.softLimits.count == 8)
        #expect(queue.tryPush(7) == .pushed)
    }
}
