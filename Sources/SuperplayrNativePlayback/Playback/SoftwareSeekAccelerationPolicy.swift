import Foundation

/// A bounded CPU burst for qualified 4K H.264 exact seeks. Codec ownership stays
/// with VideoDecoder; hardware resumes only at a verified IDR boundary.
enum SoftwareSeekAccelerationPolicy {
    static let maximumThreads = 4
    static let minimumPrerollSeconds = 2.0

    static func shouldAccelerate(
        target: Double?, packetTime: Double?, width: Int, height: Int,
        eligible: Bool
    ) -> Bool {
        guard eligible, let target, target.isFinite,
              let packetTime, packetTime.isFinite,
              width > 0, height > 0, width <= 4_096, height <= 4_096 else { return false }
        let pixels = width * height
        return pixels >= 3_840 * 2_160 && pixels <= 4_096 * 2_304
            && target - packetTime >= minimumPrerollSeconds
    }
}
