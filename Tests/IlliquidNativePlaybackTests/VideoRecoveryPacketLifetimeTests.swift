import CFFmpeg
import Foundation
import Testing
@testable import IlliquidNativePlayback

@Suite("Compressed video recovery packet lifetime")
struct VideoRecoveryPacketLifetimeTests {
    @Test func matchingDrainReleasesPacketOwnersAndTheirNativePayloads() throws {
        let buffer = VideoRecoveryPacketBuffer()
        let keyframe = try recordPacket(in: buffer, bytes: 4_096, keyframe: true, generation: 7)
        let tail = try recordPacket(in: buffer, bytes: 2_048, keyframe: false, generation: 7)
        #expect(keyframe.owner.packet != nil && tail.owner.packet != nil)
        #expect(keyframe.probe.releaseCount == 0 && tail.probe.releaseCount == 0)

        buffer.releaseAfterDrain(generation: 7)

        #expect(keyframe.owner.packet == nil && tail.owner.packet == nil)
        #expect(keyframe.probe.releaseCount == 1 && tail.probe.releaseCount == 1)
        #expect(buffer.takeReplayPackets(generation: 7).isEmpty)
    }

    @Test func repeatedDrainCompletionAndResetReleaseEachPayloadOnlyOnce() throws {
        let buffer = VideoRecoveryPacketBuffer()
        let tracked = try recordPacket(in: buffer, keyframe: true, generation: 3)

        buffer.releaseAfterDrain(generation: 3)
        buffer.releaseAfterDrain(generation: 3)
        buffer.releaseAfterDrain(generation: 2)
        buffer.reset()

        #expect(tracked.owner.packet == nil)
        #expect(tracked.probe.releaseCount == 1)
    }

    @Test func staleDrainAfterSeekPreservesTheNewGenerationsReplay() throws {
        let buffer = VideoRecoveryPacketBuffer()
        let old = try recordPacket(in: buffer, keyframe: true, generation: 1)
        buffer.reset(generation: 2)
        #expect(old.owner.packet == nil && old.probe.releaseCount == 1)
        let current = try recordPacket(in: buffer, keyframe: true, generation: 2, timestamp: 100)
        let tail = try recordPacket(in: buffer, keyframe: false, generation: 2, timestamp: 140)

        buffer.releaseAfterDrain(generation: 1)

        #expect(current.owner.packet != nil && tail.owner.packet != nil)
        #expect(current.probe.releaseCount == 0 && tail.probe.releaseCount == 0)
        var replay = buffer.takeReplayPackets(generation: 2)
        #expect(replay.map(\.generation) == [2, 2])
        #expect(replay.map(\.presentationTimestamp) == [100, 140])
        #expect(replay.first?.isKeyframe == true)
        replay.removeAll()
        #expect(current.probe.releaseCount == 1 && tail.probe.releaseCount == 1)
    }

    @Test func clonedNativePacketOutlivesTheReleasedRecoveryOwner() throws {
        let buffer = VideoRecoveryPacketBuffer()
        var clone: UnsafeMutablePointer<AVPacket>?
        defer { av_packet_free(&clone) }
        let probe: RecoveryPacketReleaseProbe
        weak var owner: FFmpegPacket?
        do {
            let fixture = try makePacket(bytes: 1_024, keyframe: true, generation: 4, timestamp: 320)
            probe = fixture.probe
            owner = fixture.packet
            clone = av_packet_clone(fixture.packet.pointer)
            let retained = try #require(clone)
            #expect(av_buffer_get_ref_count(retained.pointee.buf) == 2)
            buffer.record(fixture.packet)
        }

        buffer.releaseAfterDrain(generation: 4)

        #expect(owner == nil)
        #expect(probe.releaseCount == 0)
        let retained = try #require(clone)
        #expect(av_buffer_get_ref_count(retained.pointee.buf) == 1)
        #expect(retained.pointee.size == 1_024)
        #expect(retained.pointee.pts == 320 && retained.pointee.dts == 300)
        #expect(retained.pointee.data[0] == 17 && retained.pointee.data[1_023] == 231)
        av_packet_free(&clone)
        #expect(probe.releaseCount == 1)
    }

    @Test func aDrainedBufferCanRetainAndReleaseANewGenerationsGOP() throws {
        let buffer = VideoRecoveryPacketBuffer()
        let first = try recordPacket(in: buffer, keyframe: true, generation: 10)
        buffer.releaseAfterDrain(generation: 10)
        #expect(first.owner.packet == nil && first.probe.releaseCount == 1)

        let current = try recordPacket(in: buffer, keyframe: true, generation: 11)
        let tail = try recordPacket(in: buffer, keyframe: false, generation: 11)
        buffer.releaseAfterDrain(generation: 10)
        #expect(current.owner.packet != nil && tail.owner.packet != nil)
        #expect(current.probe.releaseCount == 0 && tail.probe.releaseCount == 0)
        buffer.releaseAfterDrain(generation: 11)
        #expect(current.owner.packet == nil && tail.owner.packet == nil)
        #expect(current.probe.releaseCount == 1 && tail.probe.releaseCount == 1)
    }

    @Test func replayTransferredBeforeDrainKeepsOwningItsPackets() throws {
        let buffer = VideoRecoveryPacketBuffer()
        let keyframe = try recordPacket(in: buffer, keyframe: true, generation: 8)
        let tail = try recordPacket(in: buffer, keyframe: false, generation: 8)
        var replay = buffer.takeReplayPackets(generation: 8)
        #expect(replay.count == 2)

        buffer.releaseAfterDrain(generation: 8)

        #expect(keyframe.owner.packet != nil && tail.owner.packet != nil)
        #expect(keyframe.probe.releaseCount == 0 && tail.probe.releaseCount == 0)
        #expect(replay.allSatisfy { $0.pointer?.pointee.data[0] == 17 })
        replay.removeAll()
        #expect(keyframe.owner.packet == nil && tail.owner.packet == nil)
        #expect(keyframe.probe.releaseCount == 1 && tail.probe.releaseCount == 1)
    }

    /// Returning only weak owners and release probes ensures the recovery buffer
    /// is the sole Swift/native packet owner when the tests observe completion.
    private func recordPacket(
        in buffer: VideoRecoveryPacketBuffer,
        bytes: Int = 64,
        keyframe: Bool,
        generation: Int,
        timestamp: Int64 = 0
    ) throws -> (owner: WeakRecoveryPacket, probe: RecoveryPacketReleaseProbe) {
        let fixture = try makePacket(bytes: bytes, keyframe: keyframe,
                                     generation: generation, timestamp: timestamp)
        buffer.record(fixture.packet)
        return (WeakRecoveryPacket(fixture.packet), fixture.probe)
    }

    private func makePacket(
        bytes: Int,
        keyframe: Bool,
        generation: Int,
        timestamp: Int64
    ) throws -> (packet: FFmpegPacket, probe: RecoveryPacketReleaseProbe) {
        var source = av_packet_alloc()
        guard let packet = source else {
            throw FFmpegError(operation: "Allocate recovery packet fixture", code: illiquid_averror_nomem())
        }
        defer { av_packet_free(&source) }
        let storageBytes = bytes + Int(AV_INPUT_BUFFER_PADDING_SIZE)
        guard let storage = av_mallocz(storageBytes) else {
            throw FFmpegError(operation: "Allocate recovery packet payload", code: illiquid_averror_nomem())
        }
        let payload = storage.assumingMemoryBound(to: UInt8.self)
        payload[0] = 17
        payload[bytes - 1] = 231
        let probe = RecoveryPacketReleaseProbe()
        let opaque = Unmanaged.passRetained(probe).toOpaque()
        guard let reference = av_buffer_create(
            payload, storageBytes, recoveryPacketFixtureFree, opaque, 0
        ) else {
            Unmanaged<RecoveryPacketReleaseProbe>.fromOpaque(opaque).release()
            av_free(storage)
            throw FFmpegError(operation: "Own recovery packet payload", code: illiquid_averror_nomem())
        }
        packet.pointee.buf = reference
        packet.pointee.data = payload
        packet.pointee.size = Int32(bytes)
        packet.pointee.pts = timestamp
        packet.pointee.dts = timestamp - 20
        packet.pointee.duration = 40
        packet.pointee.stream_index = 0
        packet.pointee.flags = keyframe ? Int32(AV_PKT_FLAG_KEY) : 0
        return (try FFmpegPacket(taking: &source, timeBase: AVRational(num: 1, den: 1_000),
                                 generation: generation), probe)
    }
}

private final class WeakRecoveryPacket {
    weak var packet: FFmpegPacket?
    init(_ packet: FFmpegPacket) { self.packet = packet }
}

/// Counts the real AVBuffer free callback without retaining its packet or bytes.
private final class RecoveryPacketReleaseProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var releases = 0

    var releaseCount: Int { lock.withLock { releases } }
    func recordRelease() { lock.withLock { releases += 1 } }
}

private let recoveryPacketFixtureFree:
    @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<UInt8>?) -> Void = {
        opaque, bytes in
        av_free(bytes)
        guard let opaque else { return }
        Unmanaged<RecoveryPacketReleaseProbe>.fromOpaque(opaque).takeRetainedValue().recordRelease()
    }
