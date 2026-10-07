import Foundation

/// Decoder-worker state only. Preserve references while avoiding disposable
/// pictures well before an exact target. Once near the target, never re-enable
/// dropping for reordered packets in that generation.
struct SeekPrerollDecodePolicy {
    private var generation: Int?
    private var target: Double?
    private var fullDecodeRequired = false
    private var lastDecodeTime: Double?

    mutating func reset() { self = Self() }

    mutating func shouldSkipNonReference(
        generation: Int, target: Double?, presentationTime: Double?,
        decodeTime: Double?, frameRate: Double?, eligible: Bool
    ) -> Bool {
        if self.generation != generation || self.target != target {
            self.generation = generation
            self.target = target
            fullDecodeRequired = false
            lastDecodeTime = nil
        }
        guard eligible, let target, target.isFinite,
              let presentationTime, presentationTime.isFinite else {
            fullDecodeRequired = true
            return false
        }
        if let decodeTime {
            guard decodeTime.isFinite,
                  lastDecodeTime.map({ decodeTime >= $0 }) ?? true else {
                fullDecodeRequired = true
                return false
            }
            lastDecodeTime = decodeTime
        }
        // Keep at least eight nominal frames and 250 ms of full decode before
        // the target for reordering/timing history. Unknown cadence opts out.
        guard let frameRate, frameRate.isFinite, frameRate > 0 else {
            fullDecodeRequired = true
            return false
        }
        if presentationTime >= target - max(0.25, 8 / frameRate) {
            fullDecodeRequired = true
        }
        return !fullDecodeRequired
    }
}
