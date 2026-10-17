import CFFmpeg
import Foundation

private final class Releases: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func hit() { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}
private let released: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<UInt8>?) -> Void = { opaque, data in
    if let opaque { Unmanaged<Releases>.fromOpaque(opaque).takeUnretainedValue().hit() }
    av_free(data)
}
private func make(_ size: Int, key: Bool = false, generation: Int = 1) throws -> FFmpegPacket {
    var source = av_packet_alloc()
    guard let p = source else { throw FFmpegError(operation: "allocate fixture", code: -12) }
    defer { av_packet_free(&source) }
    guard av_new_packet(p, Int32(size)) == 0 else { throw FFmpegError(operation: "payload fixture", code: -12) }
    if size > 0 { p.pointee.data[0] = 19; p.pointee.data[size - 1] = 23 }
    p.pointee.flags = key ? 1 : 0
    p.pointee.stream_index = 2
    p.pointee.pts = 90_000
    p.pointee.dts = 87_000
    p.pointee.duration = 3_000
    #if BASELINE
    return try FFmpegPacket(moving: p, timeBase: AVRational(num: 1, den: 90_000), generation: generation)
    #else
    return try FFmpegPacket(taking: &source, timeBase: AVRational(num: 1, den: 90_000), generation: generation)
    #endif
}
@main struct PacketOwnershipProbe {
    static func main() throws {
        precondition(avcodec_version() == ((61 << 16) | (19 << 8) | 101), "qualify different SDK before running the local shim")
        var checks = 0
        func check(_ value: Bool, _ message: String) { checks += 1; precondition(value, message) }
        let oversized = try make(VideoRecoveryPacketBuffer.maximumByteCount + 1, key: true)
        let oldBuffer = VideoRecoveryPacketBuffer()
        oldBuffer.record(oversized)
        let oversizedReplay = oldBuffer.takeReplayPackets(generation: 1).count
        #if BASELINE
        check(oversizedReplay == 1, "baseline defect no longer reproduced")
        #else
        check(oversizedReplay == 0, "oversized keyframe retained")
        #endif
        for i in 0..<1000 {
            var source = av_packet_alloc()
            let p = source!
            defer { av_packet_free(&source) }
            check(av_new_packet(p, 31) == 0, "payload allocation")
            for j in 0..<31 { p.pointee.data[j] = UInt8((i + j) % 256) }
            let side = av_packet_new_side_data(p, 13, 4)!
            for j in 0..<4 { side[j] = UInt8(j) }
            p.pointee.pts = Int64(i); p.pointee.dts = Int64(i) - 3
            p.pointee.duration = 7; p.pointee.stream_index = 4; p.pointee.flags = 3
            let payloadPointer = p.pointee.data
            #if BASELINE
            let packet = try FFmpegPacket(moving: p, timeBase: AVRational(num: 1, den: 1000), generation: i)
            check(source != nil && source!.pointee.data == nil, "moving emptied scratch")
            #else
            let packet = try FFmpegPacket(taking: &source, timeBase: AVRational(num: 1, den: 1000), generation: i)
            check(source == nil && packet.pointer == p, "header transfer")
            #endif
            check(packet.pointer!.pointee.data == payloadPointer, "payload was copied")
            check(packet.data == Data((0..<31).map { UInt8((i + $0) % 256) }), "payload changed")
            check(packet.generation == i && packet.streamIndex == 4 && packet.duration == 7, "identity changed")
            check(packet.presentationTimestamp == Int64(i) && packet.decodeTimestamp == Int64(i) - 3, "PTS/DTS changed")
            check(packet.isCorrupt && packet.isKeyframe, "flags changed")
            var count = 0
            let bytes = av_packet_get_side_data(packet.pointer, 13, &count)
            check(count == 4 && bytes != nil && Data(bytes: bytes!, count: count) == Data([0,1,2,3]), "side data changed")
        }
        // FFmpeg's AVBuffer callback proves release semantics, not merely ARC death.
        let counter = Releases()
        var source = av_packet_alloc()
        let raw = av_malloc(1)!.assumingMemoryBound(to: UInt8.self); raw[0] = 73
        let buffer = av_buffer_create(raw, 1, released, Unmanaged.passUnretained(counter).toOpaque(), 0)!
        source!.pointee.buf = buffer; source!.pointee.data = raw; source!.pointee.size = 1
        var external = av_buffer_ref(buffer)
        #if BASELINE
        var packet: FFmpegPacket? = try FFmpegPacket(moving: source!, timeBase: AVRational(num: 1, den: 1), generation: 0)
        #else
        var packet: FFmpegPacket? = try FFmpegPacket(taking: &source, timeBase: AVRational(num: 1, den: 1), generation: 0)
        #endif
        check(packet?.data == Data([73]), "release fixture bytes")
        packet = nil
        check(counter.count == 0 && raw[0] == 73, "freed external reference too early")
        av_packet_free(&source)
        av_buffer_unref(&external)
        check(counter.count == 1, "buffer not released exactly once")
        #if !BASELINE
        var absent: UnsafeMutablePointer<AVPacket>?
        do {
            _ = try FFmpegPacket(taking: &absent, timeBase: AVRational(num: 1, den: 1), generation: 0)
            preconditionFailure("accepted missing pointer")
        } catch { check(absent == nil, "nil source changed") }
        // Preserve the old scratch-moving API for other native callers.
        var scratch = av_packet_alloc()
        check(av_new_packet(scratch, 5) == 0, "scratch fixture")
        let moved = try FFmpegPacket(moving: scratch!, timeBase: AVRational(num: 1, den: 1), generation: 0)
        check(scratch != nil && scratch!.pointee.data == nil && moved.byteCount == 5, "moving compatibility")
        av_packet_free(&scratch)
        let recovery = VideoRecoveryPacketBuffer()
        let atLimit = try make(VideoRecoveryPacketBuffer.maximumByteCount, key: true)
        recovery.record(atLimit)
        check(recovery.takeReplayPackets(generation: 1).count == 1, "inclusive byte boundary")
        recovery.record(atLimit); recovery.record(try make(1))
        check(recovery.takeReplayPackets(generation: 1).isEmpty, "GOP byte overflow")
        recovery.record(try make(1, key: true))
        for _ in 1..<VideoRecoveryPacketBuffer.maximumPacketCount { recovery.record(try make(1)) }
        check(recovery.takeReplayPackets(generation: 1).count == 512, "inclusive item boundary")
        recovery.record(try make(1, key: true))
        for _ in 1...VideoRecoveryPacketBuffer.maximumPacketCount { recovery.record(try make(1)) }
        check(recovery.takeReplayPackets(generation: 1).isEmpty, "GOP item overflow")
        recovery.record(try make(1, key: true)); recovery.record(oversized); recovery.record(try make(1))
        check(recovery.takeReplayPackets(generation: 1).isEmpty, "old GOP escaped rejected keyframe")
        recovery.record(oversized); recovery.record(try make(3, key: true)); recovery.record(try make(2))
        check(recovery.takeReplayPackets(generation: 1).count == 2, "next bounded GOP did not recover")
        recovery.record(try make(1, key: true)); recovery.record(try make(1, generation: 2))
        check(recovery.takeReplayPackets(generation: 2).isEmpty, "cross-generation replay")
        #endif
        print("{\"checks\":\(checks),\"oversized_replay_count\":\(oversizedReplay),\"buffer_release_count\":\(counter.count)}")
    }
}
