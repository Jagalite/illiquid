import Foundation

/// Qualification-only, serial-worker-owned compressed packet window. Payload
/// bytes and packet count are bounded separately. A partial GOP is never replayed.
final class ThumbnailPacketWindow {
    let maximumBytes: Int
    let maximumPackets: Int
    private(set) var packets: [FFmpegPacket] = []
    private(set) var bytes = 0
    private(set) var revision = 0
    private var cursor: Int?
    var isAtDemuxFrontier: Bool { cursor == nil || cursor == packets.count }

    init(maximumBytes: Int, maximumPackets: Int = 512) {
        self.maximumBytes = max(0, maximumBytes)
        self.maximumPackets = max(1, maximumPackets)
    }

    func reset() {
        packets = []; bytes = 0; cursor = nil; revision += 1
    }

    func append(_ packet: FFmpegPacket) {
        guard !packet.isCorrupt else { reset(); return }
        if packets.isEmpty && !packet.isKeyframe { return }
        guard packet.byteCount <= maximumBytes - bytes, packets.count < maximumPackets else {
            reset()
            return
        }
        packets.append(packet); bytes += packet.byteCount
    }

    /// Require the same indexed keyframe a normal demux seek would use. If the
    /// demuxer has no usable index, fall back to its established seek path.
    func beginReplay(keyframeSeconds: Double?, targetSeconds: Double) -> Bool {
        guard let keyframeSeconds, keyframeSeconds.isFinite, targetSeconds.isFinite, targetSeconds >= keyframeSeconds,
              let end = packets.compactMap(\.presentationSeconds).max(), targetSeconds <= end,
              let index = packets.lastIndex(where: {
                  $0.isKeyframe && $0.presentationSeconds.map { abs($0 - keyframeSeconds) < 0.000_001 } == true
              }) else { return false }
        cursor = index
        return true
    }

    func next() -> FFmpegPacket? {
        guard let index = cursor, index < packets.count else { cursor = nil; return nil }
        cursor = index + 1
        return packets[index]
    }

    /// Read-ahead moved the demuxer, but not the decoder. Deliver these packets
    /// before reading at the new physical position on the next continuation.
    func replayPrefetched(from index: Int, revision expected: Int) -> Bool {
        guard revision == expected, index >= 0, index <= packets.count else { return false }
        cursor = index
        return true
    }
}
