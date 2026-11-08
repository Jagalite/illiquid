import Foundation

/// How much decoded and compressed media a session may hold ahead of playback.
struct AdaptiveBufferTargets: Equatable, Sendable {
    var videoFrames: Int
    var videoPacketSeconds: Double
    var audioPacketSeconds: Double
}

/// One telemetry window, reduced to the signals the policy acts on. Times are
/// seconds; nil means the stage produced no samples in the window.
struct AdaptiveBufferInputs: Equatable, Sendable {
    var playing: Bool
    var seeked: Bool
    var frameInterval: Double?
    var videoDecodeP95: Double?
    var demuxReadMaximum: Double?
    var demuxStalls: Int
    var starvations: Int
    var videoFrameQueueLow: Int?
    var videoPacketAheadLow: Double?
    var audioPacketAheadLow: Double?
    var rendererVideoAheadLow: Double?
    /// Memory pressure, Low Power Mode, or serious/critical thermal state.
    var constrained: Bool

    init(playing: Bool, seeked: Bool = false, frameInterval: Double? = nil,
         videoDecodeP95: Double? = nil, demuxReadMaximum: Double? = nil, demuxStalls: Int = 0,
         starvations: Int = 0, videoFrameQueueLow: Int? = nil, videoPacketAheadLow: Double? = nil,
         audioPacketAheadLow: Double? = nil, rendererVideoAheadLow: Double? = nil,
         constrained: Bool = false) {
        self.playing = playing; self.seeked = seeked; self.frameInterval = frameInterval
        self.videoDecodeP95 = videoDecodeP95; self.demuxReadMaximum = demuxReadMaximum
        self.demuxStalls = demuxStalls; self.starvations = starvations
        self.videoFrameQueueLow = videoFrameQueueLow; self.videoPacketAheadLow = videoPacketAheadLow
        self.audioPacketAheadLow = audioPacketAheadLow; self.rendererVideoAheadLow = rendererVideoAheadLow
        self.constrained = constrained
    }
}

/// Sizes playback buffers from measured risk instead of a fixed worst case.
///
/// Memory freed after the fact does not leave the process footprint (the
/// allocator keeps the pages), so the policy starts small and grows only on
/// evidence: starvation, a stage running nearly dry, decode time approaching
/// the frame interval, or slow input. It grows quickly, shrinks one step after a
/// sustained healthy run, ignores paused and seeking windows, and caps itself
/// under memory, power or thermal pressure.
struct AdaptiveBufferPolicy: Equatable, Sendable {
    static let minimum = AdaptiveBufferTargets(videoFrames: 3, videoPacketSeconds: 0.75, audioPacketSeconds: 0.75)
    static let initial = AdaptiveBufferTargets(videoFrames: 4, videoPacketSeconds: 1, audioPacketSeconds: 1)
    static let maximum = AdaptiveBufferTargets(videoFrames: 12, videoPacketSeconds: 4, audioPacketSeconds: 4)
    static let constrainedCeiling = AdaptiveBufferTargets(videoFrames: 6, videoPacketSeconds: 1.5, audioPacketSeconds: 1.5)
    static let healthyWindowsBeforeShrinking = 10

    private(set) var targets = AdaptiveBufferPolicy.initial
    private(set) var healthyWindows = 0

    @discardableResult
    mutating func update(_ input: AdaptiveBufferInputs) -> AdaptiveBufferTargets {
        defer { targets = clamp(targets, constrained: input.constrained) }
        // Paused, seeking and prerolling windows describe deliberate refills,
        // not supply risk; neither grow nor shrink from them.
        guard input.playing, !input.seeked else { return clamp(targets, constrained: input.constrained) }

        let interval = input.frameInterval ?? (1.0 / 30)
        let decodeLoad = input.videoDecodeP95.map { $0 / interval } ?? 0
        let starved = input.starvations > 0
        let frameRisk = starved
            || input.videoFrameQueueLow == 0
            || (input.rendererVideoAheadLow.map { $0 < 2 * interval } ?? false)
            || decodeLoad > 0.5
        let inputRisk = input.demuxStalls > 0 || (input.demuxReadMaximum ?? 0) > 0.1
        let videoPacketRisk = starved || inputRisk
            || (input.videoPacketAheadLow.map { $0 < 0.25 * targets.videoPacketSeconds } ?? false)
        let audioPacketRisk = starved || inputRisk
            || (input.audioPacketAheadLow.map { $0 < 0.25 * targets.audioPacketSeconds } ?? false)

        if frameRisk {
            targets.videoFrames = max(targets.videoFrames + 2, targets.videoFrames * 3 / 2)
        }
        // Decode cost near the frame interval needs depth to absorb variance,
        // independent of whether this window happened to run dry.
        if decodeLoad > 0.8 {
            targets.videoFrames = max(targets.videoFrames, Self.maximum.videoFrames)
        } else if decodeLoad > 0.5 {
            targets.videoFrames = max(targets.videoFrames, 8)
        }
        if videoPacketRisk { targets.videoPacketSeconds *= 2 }
        if audioPacketRisk { targets.audioPacketSeconds *= 2 }

        if frameRisk || videoPacketRisk || audioPacketRisk {
            healthyWindows = 0
        } else {
            healthyWindows += 1
            if healthyWindows >= Self.healthyWindowsBeforeShrinking {
                healthyWindows = 0
                targets.videoFrames -= 1
                targets.videoPacketSeconds -= 0.25
                targets.audioPacketSeconds -= 0.25
            }
        }
        return clamp(targets, constrained: input.constrained)
    }

    private func clamp(_ value: AdaptiveBufferTargets, constrained: Bool) -> AdaptiveBufferTargets {
        let ceiling = constrained ? Self.constrainedCeiling : Self.maximum
        return AdaptiveBufferTargets(
            videoFrames: min(max(value.videoFrames, Self.minimum.videoFrames), ceiling.videoFrames),
            videoPacketSeconds: min(max(value.videoPacketSeconds, Self.minimum.videoPacketSeconds), ceiling.videoPacketSeconds),
            audioPacketSeconds: min(max(value.audioPacketSeconds, Self.minimum.audioPacketSeconds), ceiling.audioPacketSeconds))
    }
}
