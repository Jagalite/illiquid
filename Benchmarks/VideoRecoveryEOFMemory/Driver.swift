import CFFmpeg
import CLifetimeProbe
import Foundation

private func require(_ condition: Bool, _ message: String) throws {
    if !condition {
        throw NSError(domain: "VideoRecoveryEOFMemory", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: message])
    }
}

private func snapshot() -> [String: UInt64] {
    let value = recovery_lifetime_snapshot()
    return [
        "live_buffers": value.live_buffers,
        "live_payload_bytes": value.live_payload_bytes,
        "live_buffer_extent_bytes": value.live_buffer_extent_bytes,
        "created_buffers": value.created_buffers,
        "freed_buffers": value.freed_buffers,
    ]
}

private func requireLive(_ buffers: Int, _ payload: Int, _ context: String) throws {
    let value = recovery_lifetime_snapshot()
    try require(value.live_buffers == UInt64(buffers), "\(context): live buffer count")
    try require(value.live_payload_bytes == UInt64(payload), "\(context): live payload")
    try require(value.created_buffers - value.freed_buffers == value.live_buffers,
                "\(context): final callback accounting")
}

// Return only a deliberately held native clone and a value checksum. The
// local FFmpegPacket references have left scope before any ownership snapshot.
@inline(never)
private func populate(
    _ buffer: VideoRecoveryPacketBuffer, count: Int, size: Int,
    generation: Int, holdFirst: Bool
) throws -> (UnsafeMutablePointer<AVPacket>?, UInt64) {
    var held: UnsafeMutablePointer<AVPacket>?
    var fingerprint: UInt64 = 0
    var completed = false
    defer { if !completed { av_packet_free(&held) } }
    for index in 0..<count {
        var raw = recovery_lifetime_packet(Int32(size), UInt32(index), index == 0 ? 1 : 0)
        defer { av_packet_free(&raw) }
        guard let pointer = raw else {
            throw NSError(domain: "Packet allocation", code: 1)
        }
        fingerprint = (fingerprint ^ recovery_lifetime_checksum(pointer)) &* 1_099_511_628_211
        if holdFirst && index == 0 {
            held = av_packet_clone(pointer)
            try require(held != nil, "Clone allocation")
        }
        let packet = try FFmpegPacket(taking: &raw, timeBase: AVRational(num: 1, den: 30),
                                      generation: generation)
        try require(raw == nil, "Taking must transfer the packet header")
        buffer.record(packet)
    }
    completed = true
    return (held, fingerprint)
}

// Baseline intentionally models the existing component EOF operation (no
// release). This is not an execution of MediaSession or a decoder drain.
@inline(never)
private func finishComponent(_ buffer: VideoRecoveryPacketBuffer, generation: Int) {
#if CANDIDATE
    buffer.finish(generation: generation)
#else
    withExtendedLifetime(buffer) {}
#endif
}

@inline(never)
private func checkReplayAndRelease(
    _ buffer: VideoRecoveryPacketBuffer, generation: Int,
    expectedCount: Int, expectedFingerprint: UInt64
) throws -> String {
    let replay = buffer.takeReplayPackets(generation: generation)
    try require(replay.count == expectedCount, "Replay count after component operation")
    var fingerprint: UInt64 = 0
    for (index, packet) in replay.enumerated() {
        try require(packet.generation == generation && packet.streamIndex == 0,
                    "Replay identity")
        try require(packet.presentationTimestamp == Int64(index)
                    && packet.decodeTimestamp == Int64(index)
                    && packet.duration == 1 && packet.isKeyframe == (index == 0),
                    "Replay metadata")
        guard let pointer = packet.pointer else {
            throw NSError(domain: "Missing replay packet", code: 1)
        }
        fingerprint = (fingerprint ^ recovery_lifetime_checksum(pointer)) &* 1_099_511_628_211
    }
    try require(fingerprint == expectedFingerprint, "Replay payload and ordering")
    return String(fingerprint)
}

@main
private enum Driver {
    static func main() throws {
        try require(CommandLine.arguments.count == 2, "Pass one workload name")
        let name = CommandLine.arguments[1]
        let dimensions: (Int, Int)
        switch name {
        case "empty": dimensions = (0, 65_536)
        case "gop", "held_clone", "stale_generation", "reset_control":
            dimensions = (120, 65_536)
        case "byte_bound": dimensions = (1, 32 * 1_024 * 1_024)
        case "packet_bound": dimensions = (512, 4_096)
        default: throw NSError(domain: "Unknown workload: \(name)", code: 1)
        }
        let (count, size) = dimensions
#if CANDIDATE
        let variant = "candidate"
        let releasesAtEOF = true
#else
        let variant = "baseline"
        let releasesAtEOF = false
#endif
        let generation = 7
        let stale = name == "stale_generation"
        let resets = name == "reset_control"
        let holdsClone = name == "held_clone"
        let buffer = VideoRecoveryPacketBuffer()
        try requireLive(0, 0, "Fresh process")
        let before = snapshot()
        let population = try populate(
            buffer, count: count, size: size, generation: generation, holdFirst: holdsClone
        )
        var held = population.0
        let fingerprint = population.1
        defer { av_packet_free(&held) }
        try requireLive(count, count * size, "Loaded")
        let loaded = snapshot()
        let heldChecksum = held.map { String(recovery_lifetime_checksum($0)) }
        if resets {
            buffer.reset(generation: generation)
        } else {
            finishComponent(buffer, generation: stale ? generation - 1 : generation)
        }
        let cacheReleased = resets || (releasesAtEOF && !stale)
        let expectedBuffers = cacheReleased ? (holdsClone ? 1 : 0) : count
        try requireLive(expectedBuffers, expectedBuffers * size, "After component operation")
        let after = snapshot()
        try require(heldChecksum == held.map { String(recovery_lifetime_checksum($0)) },
                    "Held clone payload survived component EOF")
        let expectedReplay = cacheReleased ? 0 : count
        let replayFingerprint = try checkReplayAndRelease(
            buffer, generation: generation, expectedCount: expectedReplay,
            expectedFingerprint: expectedReplay == 0 ? 0 : fingerprint
        )
        buffer.reset()
        try requireLive(holdsClone ? 1 : 0, holdsClone ? size : 0, "After cache cleanup")
        let cleaned = snapshot()
        try require(heldChecksum == held.map { String(recovery_lifetime_checksum($0)) },
                    "Held clone payload survived replay/cache cleanup")
        av_packet_free(&held)
        try requireLive(0, 0, "After final clone release")
        let finished = snapshot()
        try require(finished["created_buffers"] == finished["freed_buffers"],
                    "Every tracked allocation reached its final callback")
        let report: [String: Any] = [
            "schema_version": 1, "workload": name, "variant": variant,
            "operation": resets ? "explicit-reset-control" : "component-EOF",
            "baseline_EOF_is_no_op": true, "stale_generation": stale,
            "packet_count": count, "packet_size": size, "generation": generation,
            "input_fingerprint": String(fingerprint), "replay_count": expectedReplay,
            "replay_fingerprint": replayFingerprint,
            "held_clone_checksum": heldChecksum.map { $0 as Any } ?? NSNull(),
            "before": before, "loaded": loaded, "after_operation": after,
            "after_cache_cleanup": cleaned, "after_final_release": finished,
            "passed": true,
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
