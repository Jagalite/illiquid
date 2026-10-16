import CFFmpeg
import Foundation

final class FFmpegPacket: @unchecked Sendable {
    private(set) var pointer: UnsafeMutablePointer<AVPacket>?
    let streamIndex: Int32
    let presentationTimestamp: Int64
    let decodeTimestamp: Int64
    let duration: Int64
    let timeBase: FFmpegRational
    let generation: Int
    let isCorrupt: Bool
    let isKeyframe: Bool

    init(
        moving source: UnsafeMutablePointer<AVPacket>,
        timeBase: AVRational,
        generation: Int
    ) throws {
        guard let packet = av_packet_alloc() else {
            throw FFmpegError(operation: "Allocate packet", code: illiquid_averror_nomem())
        }
        av_packet_move_ref(packet, source)
        pointer = packet
        streamIndex = packet.pointee.stream_index
        presentationTimestamp = packet.pointee.pts
        decodeTimestamp = packet.pointee.dts
        duration = packet.pointee.duration
        self.timeBase = FFmpegRational(timeBase)
        self.generation = generation
        isCorrupt = illiquid_packet_is_corrupt(packet) != 0
        isKeyframe = illiquid_packet_is_keyframe(packet) != 0
    }

    deinit {
        av_packet_free(&pointer)
    }

    var presentationSeconds: Double? {
        presentationTimestamp == illiquid_nopts_value()
            ? nil
            : MediaTime.seconds(presentationTimestamp, timeBase: timeBase)
    }

    var decodeSeconds: Double? {
        decodeTimestamp == illiquid_nopts_value()
            ? nil
            : MediaTime.seconds(decodeTimestamp, timeBase: timeBase)
    }

    var durationSeconds: Double? {
        duration > 0 ? MediaTime.seconds(duration, timeBase: timeBase) : nil
    }

    var data: Data? {
        guard let pointer, let bytes = pointer.pointee.data, pointer.pointee.size > 0 else {
            return nil
        }
        return Data(bytes: bytes, count: Int(pointer.pointee.size))
    }

    var byteCount: Int {
        guard let pointer else { return 0 }
        return max(Int(pointer.pointee.size), 0)
    }

    var durationMicroseconds: Int64 {
        guard let seconds = durationSeconds, seconds.isFinite, seconds > 0 else { return 0 }
        return Int64(min((seconds * 1_000_000).rounded(), Double(Int64.max)))
    }
}

/// Retains one bounded compressed-video GOP so a failed hardware decoder can
/// seed its software replacement without seeking or disturbing audio. The
/// buffer is intentionally invalidated if a GOP exceeds either bound: replay
/// must always begin at a real keyframe, never at an arbitrary retained tail.
final class VideoRecoveryPacketBuffer: @unchecked Sendable {
    static let maximumPacketCount = 512
    static let maximumByteCount = 32 * 1_024 * 1_024

    private let lock = NSLock()
    private var generation: Int?
    private var packets: [FFmpegPacket] = []
    private var byteCount = 0
    private var hasReplayableKeyframe = false

    func record(_ packet: FFmpegPacket) {
        lock.withLock {
            if generation != packet.generation {
                resetLocked(generation: packet.generation)
            }
            if packet.isKeyframe {
                packets = [packet]
                byteCount = packet.byteCount
                hasReplayableKeyframe = true
                return
            }
            guard hasReplayableKeyframe else { return }
            packets.append(packet)
            byteCount += packet.byteCount
            if packets.count > Self.maximumPacketCount
                || byteCount > Self.maximumByteCount
            {
                packets.removeAll(keepingCapacity: false)
                byteCount = 0
                hasReplayableKeyframe = false
            }
        }
    }

    func takeReplayPackets(generation expectedGeneration: Int) -> [FFmpegPacket] {
        lock.withLock {
            guard generation == expectedGeneration,
                  hasReplayableKeyframe,
                  packets.first?.isKeyframe == true
            else {
                resetLocked(generation: expectedGeneration)
                return []
            }
            let replay = packets
            resetLocked(generation: expectedGeneration)
            return replay
        }
    }

    func reset(generation newGeneration: Int? = nil) {
        lock.withLock { resetLocked(generation: newGeneration) }
    }

    private func resetLocked(generation newGeneration: Int?) {
        generation = newGeneration
        packets.removeAll(keepingCapacity: false)
        byteCount = 0
        hasReplayableKeyframe = false
    }
}

enum PacketQueueItem: @unchecked Sendable {
    case packet(FFmpegPacket)
    case flush(generation: Int)
    case endOfStream(generation: Int)
}

extension PacketQueueItem {
    var boundedQueueCost: BoundedQueueCost {
        switch self {
        case .packet(let packet):
            BoundedQueueCost(
                bytes: packet.byteCount,
                durationMicroseconds: packet.durationMicroseconds
            )
        case .flush, .endOfStream:
            BoundedQueueCost()
        }
    }
}
