import CFFmpeg
import Foundation

// The observer owns counters only. The AVBuffer's free callback is the sole
// release receipt; no observer keeps a packet or AVBufferRef alive.
private final class AllocationProbe: @unchecked Sendable {
    let payloadBytes: Int
    let storageBytes: Int
    private let lock = NSLock()
    private var releases = 0

    init(payloadBytes: Int, storageBytes: Int) {
        self.payloadBytes = payloadBytes
        self.storageBytes = storageBytes
    }

    func released() { lock.withLock { releases += 1 } }
    var releaseCount: Int { lock.withLock { releases } }
}

private let releaseStorage: @convention(c) (
    UnsafeMutableRawPointer?, UnsafeMutablePointer<UInt8>?
) -> Void = { opaque, bytes in
    av_free(bytes)
    guard let opaque else { return }
    Unmanaged<AllocationProbe>.fromOpaque(opaque).takeRetainedValue().released()
}

private final class WeakPacket {
    weak var value: FFmpegPacket?
    init(_ value: FFmpegPacket) { self.value = value }
}

private struct Snapshot: Encodable, Equatable {
    var allocatedBuffers = 0
    var releasedBuffers = 0
    var liveBuffers = 0
    var livePacketWrappers = 0
    var allocatedPayloadBytes = 0
    var livePayloadBytes = 0
    var liveRequestedStorageBytes = 0
    var invalidReleaseCounts = 0
}

private struct PacketDigest: Encodable, Equatable {
    let pts: Int64
    let dts: Int64
    let duration: Int64
    let generation: Int
    let bytes: Int
    let keyframe: Bool
    let checksum: UInt64
}

private struct CaseReport: Encodable {
    let name: String
    var snapshots: [String: Snapshot]
    var replay: [PacketDigest] = []
    var cloneChecksumBeforeEOF: UInt64? = nil
    var cloneChecksumAfterEOF: UInt64? = nil
}

private func checksum(_ packet: UnsafeMutablePointer<AVPacket>) -> UInt64 {
    var result: UInt64 = 14_695_981_039_346_656_037
    if let data = packet.pointee.data {
        for index in 0..<Int(packet.pointee.size) {
            result = (result ^ UInt64(data[index])) &* 1_099_511_628_211
        }
    }
    return result
}

@inline(never)
private func describe(_ packets: [FFmpegPacket]) -> [PacketDigest] {
    packets.map { packet in
        PacketDigest(pts: packet.presentationTimestamp, dts: packet.decodeTimestamp,
                     duration: packet.duration, generation: packet.generation,
                     bytes: packet.byteCount, keyframe: packet.isKeyframe,
                     checksum: checksum(packet.pointer!))
    }
}

private final class Fixture {
    let buffer = VideoRecoveryPacketBuffer()
    private var probes: [AllocationProbe] = []
    private var owners: [WeakPacket] = []

    private func makePacket(bytes payloadBytes: Int, keyframe: Bool,
                            generation: Int, pts: Int64) throws -> FFmpegPacket {
        let storageBytes = payloadBytes + Int(AV_INPUT_BUFFER_PADDING_SIZE)
        var allocated = av_packet_alloc()
        guard let pointer = allocated else {
            throw FFmpegError(operation: "Allocate measured packet", code: illiquid_averror_nomem())
        }
        defer { av_packet_free(&allocated) }
        guard let memory = av_mallocz(storageBytes) else {
            throw FFmpegError(operation: "Allocate measured storage", code: illiquid_averror_nomem())
        }
        let bytes = memory.assumingMemoryBound(to: UInt8.self)
        // Touch the complete payload; retain FFmpeg's required zero padding.
        bytes.update(repeating: UInt8(truncatingIfNeeded: pts &+ 17), count: payloadBytes)
        let probe = AllocationProbe(payloadBytes: payloadBytes, storageBytes: storageBytes)
        let opaque = Unmanaged.passRetained(probe).toOpaque()
        guard let reference = av_buffer_create(bytes, storageBytes, releaseStorage, opaque, 0) else {
            Unmanaged<AllocationProbe>.fromOpaque(opaque).release()
            av_free(memory)
            throw FFmpegError(operation: "Own measured storage", code: illiquid_averror_nomem())
        }
        pointer.pointee.buf = reference
        pointer.pointee.data = bytes
        pointer.pointee.size = Int32(payloadBytes)
        pointer.pointee.stream_index = 0
        pointer.pointee.pts = pts
        pointer.pointee.dts = pts
        pointer.pointee.duration = 40
        pointer.pointee.flags = keyframe ? Int32(AV_PKT_FLAG_KEY) : 0
        let packet = try FFmpegPacket(taking: &allocated,
                                     timeBase: AVRational(num: 1, den: 1_000),
                                     generation: generation)
        probes.append(probe)
        owners.append(WeakPacket(packet))
        return packet
    }

    // End these helper scopes before measuring: the recovery buffer must be the
    // only owner of each Swift packet unless the case explicitly takes replay.
    @inline(never)
    func record(count: Int, bytes: Int, generation: Int = 7, firstPTS: Int64 = 0) throws {
        for index in 0..<count {
            let packet = try makePacket(bytes: bytes, keyframe: index == 0,
                                        generation: generation, pts: firstPTS + Int64(index) * 40)
            buffer.record(packet)
        }
    }

    @inline(never)
    func recordAndClone() throws -> UnsafeMutablePointer<AVPacket> {
        let packet = try makePacket(bytes: 65_536, keyframe: true, generation: 7, pts: 0)
        guard let clone = av_packet_clone(packet.pointer) else {
            throw FFmpegError(operation: "Clone measured packet", code: illiquid_averror_nomem())
        }
        buffer.record(packet)
        return clone
    }

    func snapshot() -> Snapshot {
        var result = Snapshot()
        result.livePacketWrappers = owners.reduce(0) { $0 + ($1.value == nil ? 0 : 1) }
        for probe in probes {
            let releases = probe.releaseCount
            result.allocatedBuffers += 1
            result.allocatedPayloadBytes += probe.payloadBytes
            result.releasedBuffers += releases
            if releases == 0 {
                result.liveBuffers += 1
                result.livePayloadBytes += probe.payloadBytes
                result.liveRequestedStorageBytes += probe.storageBytes
            }
            if releases != 0 && releases != 1 { result.invalidReleaseCounts += 1 }
        }
        return result
    }
}

private func finalGOP(name: String, count: Int, replace: Bool = false) throws -> CaseReport {
    let fixture = Fixture()
    if replace { try fixture.record(count: 3, bytes: 1_024, firstPTS: -120) }
    try fixture.record(count: count, bytes: 65_536)
    var report = CaseReport(name: name, snapshots: ["recorded": fixture.snapshot()])
    completeSuccessfulDrain(fixture.buffer, active: 7)
    report.snapshots["afterEOF"] = fixture.snapshot()
    completeSuccessfulDrain(fixture.buffer, active: 7)
    report.snapshots["afterRepeatedEOF"] = fixture.snapshot()
    fixture.buffer.reset()
    report.snapshots["afterReset"] = fixture.snapshot()
    return report
}

private func independentlyOwnedClone() throws -> CaseReport {
    let fixture = Fixture()
    var clone: UnsafeMutablePointer<AVPacket>? = try fixture.recordAndClone()
    defer { av_packet_free(&clone) }
    var report = CaseReport(name: "external_clone", snapshots: ["recorded": fixture.snapshot()])
    report.cloneChecksumBeforeEOF = checksum(clone!)
    completeSuccessfulDrain(fixture.buffer, active: 7)
    report.snapshots["afterEOF"] = fixture.snapshot()
    report.cloneChecksumAfterEOF = checksum(clone!)
    av_packet_free(&clone)
    report.snapshots["afterCloneRelease"] = fixture.snapshot()
    fixture.buffer.reset()
    report.snapshots["afterReset"] = fixture.snapshot()
    return report
}

private func staleGeneration() throws -> CaseReport {
    let fixture = Fixture()
    try fixture.record(count: 4, bytes: 65_536, generation: 8)
    var report = CaseReport(name: "stale_generation", snapshots: ["recorded": fixture.snapshot()])
    completeSuccessfulDrain(fixture.buffer, active: 7)
    report.snapshots["afterStaleEOF"] = fixture.snapshot()
    var replay = fixture.buffer.takeReplayPackets(generation: 8)
    report.replay = describe(replay)
    report.snapshots["afterTake"] = fixture.snapshot()
    fixture.buffer.reset()
    report.snapshots["afterResetWhileReplayHeld"] = fixture.snapshot()
    replay.removeAll(keepingCapacity: false)
    report.snapshots["afterReplayRelease"] = fixture.snapshot()
    return report
}

private func preEOFRecovery() throws -> CaseReport {
    let fixture = Fixture()
    try fixture.record(count: 8, bytes: 4_096)
    var report = CaseReport(name: "pre_eof_recovery", snapshots: ["recorded": fixture.snapshot()])
    var replay = fixture.buffer.takeReplayPackets(generation: 7)
    report.replay = describe(replay)
    report.snapshots["afterTake"] = fixture.snapshot()
    completeSuccessfulDrain(fixture.buffer, active: 7)
    report.snapshots["afterEOFWhileReplayHeld"] = fixture.snapshot()
    fixture.buffer.reset()
    report.snapshots["afterResetWhileReplayHeld"] = fixture.snapshot()
    replay.removeAll(keepingCapacity: false)
    report.snapshots["afterReplayRelease"] = fixture.snapshot()
    return report
}

private struct Report: Encodable {
    let schemaVersion = 1
    let avcodecVersion: UInt32
    let avutilVersion: UInt32
    let inputPaddingBytes: Int
    let cases: [CaseReport]
}

@main
private enum Driver {
    static func main() throws {
        let report = Report(avcodecVersion: avcodec_version(), avutilVersion: avutil_version(),
                            inputPaddingBytes: Int(AV_INPUT_BUFFER_PADDING_SIZE), cases: [
            try finalGOP(name: "empty", count: 0),
            try finalGOP(name: "single_64k", count: 1),
            try finalGOP(name: "gop_120", count: 120),
            try finalGOP(name: "limit_512", count: 512),
            try finalGOP(name: "replaced_gop", count: 5, replace: true),
            try independentlyOwnedClone(),
            try staleGeneration(),
            try preEOFRecovery(),
        ])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        print(String(decoding: try encoder.encode(report), as: UTF8.self))
    }
}
