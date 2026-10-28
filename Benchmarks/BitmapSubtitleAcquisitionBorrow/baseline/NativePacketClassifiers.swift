import CFFmpeg
import Foundation

enum FFmpegDemuxReadRetryDecision: Equatable {
    case retry
    case fail
}

/// Bounded no-progress policy for `av_read_frame`. A successful packet creates
/// a fresh policy through the next `readPacket` call, so sparse errors never
/// consume a lifetime budget.
struct FFmpegDemuxReadRetryPolicy {
    static let maximumConsecutiveInvalidDataReads = 256
    static let maximumConsecutiveOtherErrors = 10
    static let maximumNoProgressSeconds = 1.0

    private(set) var invalidDataReads = 0
    private(set) var otherErrors = 0

    mutating func decision(
        for code: Int32,
        elapsedNoProgressSeconds: TimeInterval
    ) -> FFmpegDemuxReadRetryDecision {
        guard elapsedNoProgressSeconds < Self.maximumNoProgressSeconds else {
            return .fail
        }
        if code == illiquid_averror_invaliddata() {
            guard invalidDataReads < Self.maximumConsecutiveInvalidDataReads else {
                return .fail
            }
            invalidDataReads += 1
            return .retry
        }
        guard code != illiquid_averror_exit(),
              otherErrors < Self.maximumConsecutiveOtherErrors
        else {
            return .fail
        }
        otherErrors += 1
        return .retry
    }
}
