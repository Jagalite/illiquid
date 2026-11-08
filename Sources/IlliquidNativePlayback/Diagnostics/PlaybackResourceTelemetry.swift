import Foundation

/// Windowed playback telemetry for `AdaptiveBufferPolicy`: decode headroom,
/// input latency, and how close each stage came to running dry. Recording is a
/// short lock and a few additions per packet or frame; `drain()` returns the
/// window and starts a new one.
final class PlaybackResourceTelemetry: @unchecked Sendable {
    /// Keeps up to `exactSampleLimit` raw samples per window for exact
    /// quantiles (a one-second window holds roughly 24–120 video samples) and
    /// fixed log-spaced buckets beyond that, so memory stays bounded.
    struct Distribution: Equatable, Sendable {
        static let upperBoundsMilliseconds: [Double] =
            [0.5, 1, 2, 4, 8, 12, 16, 24, 33, 50, 100, 250, .infinity]
        static let exactSampleLimit = 512
        private(set) var samples: [Double] = []
        private(set) var count = 0
        private(set) var maximumMilliseconds = 0.0
        private(set) var buckets = [Int](repeating: 0, count: upperBoundsMilliseconds.count)

        mutating func record(milliseconds: Double) {
            guard milliseconds.isFinite, milliseconds >= 0 else { return }
            count += 1
            if samples.count < Self.exactSampleLimit { samples.append(milliseconds) }
            maximumMilliseconds = max(maximumMilliseconds, milliseconds)
            let index = Self.upperBoundsMilliseconds.firstIndex { milliseconds <= $0 }
                ?? Self.upperBoundsMilliseconds.count - 1
            buckets[index] += 1
        }

        /// Nearest-rank quantile. Exact while every sample is retained;
        /// otherwise the upper bound of the bucket holding it, capped by the
        /// observed maximum. Bucket bounds alone overstated a healthy 60 fps
        /// p95 of 8.1 ms as 12 ms, enough to grow buffers needlessly.
        func quantileUpperBound(_ quantile: Double) -> Double? {
            guard count > 0 else { return nil }
            let rank = max(1, Int((Double(count) * min(max(quantile, 0), 1)).rounded(.up)))
            if samples.count == count { return samples.sorted()[rank - 1] }
            var seen = 0
            for (index, value) in buckets.enumerated() {
                seen += value
                if seen >= rank {
                    return min(Self.upperBoundsMilliseconds[index], maximumMilliseconds)
                }
            }
            return maximumMilliseconds
        }

        /// Samples in buckets whose lower bound is at least `milliseconds`.
        func count(above milliseconds: Double) -> Int {
            zip(Self.upperBoundsMilliseconds, buckets).reduce(0) { total, entry in
                let lowerBound = Self.upperBoundsMilliseconds.last { $0 < entry.0 } ?? 0
                return lowerBound >= milliseconds ? total + entry.1 : total
            }
        }
    }

    struct Window: Equatable, Sendable {
        /// Decoder work only: output-capacity and frame-queue waits are excluded.
        var videoDecode = Distribution()
        var demuxRead = Distribution()
        /// Low-water marks sampled whenever a stage hands work downstream.
        var videoPacketAheadLowSeconds: Double?
        var audioPacketAheadLowSeconds: Double?
        var videoFrameQueueLow: Int?
        var rendererVideoAheadLowSeconds: Double?
    }

    private let lock = NSLock()
    private var window = Window()

    func recordVideoDecode(milliseconds: Double) {
        lock.withLock { window.videoDecode.record(milliseconds: milliseconds) }
    }

    func recordDemuxRead(milliseconds: Double) {
        lock.withLock { window.demuxRead.record(milliseconds: milliseconds) }
    }

    func observeVideoPackets(_ budget: BoundedQueueBudgetSnapshot) {
        let seconds = Double(budget.durationMicroseconds) / 1_000_000
        lock.withLock {
            window.videoPacketAheadLowSeconds = min(window.videoPacketAheadLowSeconds ?? seconds, seconds)
        }
    }

    func observeAudioPackets(_ budget: BoundedQueueBudgetSnapshot) {
        let seconds = Double(budget.durationMicroseconds) / 1_000_000
        lock.withLock {
            window.audioPacketAheadLowSeconds = min(window.audioPacketAheadLowSeconds ?? seconds, seconds)
        }
    }

    func observeVideoFrameQueue(depth: Int) {
        lock.withLock { window.videoFrameQueueLow = min(window.videoFrameQueueLow ?? depth, depth) }
    }

    func observeRendererVideoAhead(_ seconds: Double) {
        guard seconds.isFinite else { return }
        lock.withLock {
            window.rendererVideoAheadLowSeconds = min(window.rendererVideoAheadLowSeconds ?? seconds, seconds)
        }
    }

    func drain() -> Window {
        lock.withLock {
            let completed = window
            window = Window()
            return completed
        }
    }

    /// Restarts the window without reporting it, for example after a seek
    /// flush whose empty queues are not a supply failure.
    func reset() {
        lock.withLock { window = Window() }
    }
}
