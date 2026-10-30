import CFFmpeg
import Foundation
import Testing
@testable import IlliquidNativePlayback

/// These tests use real FFmpeg allocations and the same successful-drain
/// boundary as MediaSession. The injected callbacks exercise ownership and
/// error ordering; they do not instantiate a decoder or qualify playback.
@Suite("Recovery GOP drain lifetime", .serialized)
struct VideoRecoveryPacketLifetimeTests {
    private enum DrainFailure: Error { case failed }

    private final class WeakPacket {
        weak var value: FFmpegPacket?
        init(_ packet: FFmpegPacket) { value = packet }
    }

    @Test func successfulDrainReleasesTheFinalGOPWhileTheBufferRemainsAlive() throws {
        let buffer = VideoRecoveryPacketBuffer()
        let packets = try recordGOP(in: buffer, generation: 3)
        #expect(packets.allSatisfy { $0.value != nil })
        var drains = 0

        buffer.retireAfterSuccessfulDrain(generation: 3) {
            drains += 1
            // Replay must survive until the decoder has finished its work.
            #expect(packets.allSatisfy { $0.value != nil })
        }

        #expect(drains == 1)
        #expect(packets.allSatisfy { $0.value == nil })
        #expect(buffer.takeReplayPackets(generation: 3).isEmpty)
        withExtendedLifetime(buffer) {}
    }

    @Test(arguments: [1_024, 1_024 * 1_024, VideoRecoveryPacketBuffer.maximumByteCount])
    func releasesPayloadsThroughTheInclusiveByteLimit(bytes: Int) throws {
        let buffer = VideoRecoveryPacketBuffer()
        let packet = try recordPacket(in: buffer, bytes: bytes, keyframe: true, generation: 1)
        #expect(packet.value?.byteCount == bytes)

        buffer.retireAfterSuccessfulDrain(generation: 1) {}

        #expect(packet.value == nil)
        withExtendedLifetime(buffer) {}
    }

    @Test func failedDrainPreservesTheCompleteReplay() throws {
        let buffer = VideoRecoveryPacketBuffer()
        let packets = try recordGOP(in: buffer, generation: 4)

        #expect(throws: DrainFailure.self) {
            try buffer.retireAfterSuccessfulDrain(generation: 4) {
                throw DrainFailure.failed
            }
        }

        #expect(packets.allSatisfy { $0.value != nil })
        let replay = buffer.takeReplayPackets(generation: 4)
        #expect(replay.map(\.presentationTimestamp) == [0, 1, 2])
        #expect(replay.first?.isKeyframe == true)
        #expect(zip(replay, packets).allSatisfy { packet, observer in packet === observer.value })
    }

    @Test func cancelledDrainPreservesTheCompleteReplay() throws {
        let buffer = VideoRecoveryPacketBuffer()
        let packets = try recordGOP(in: buffer, generation: 5)

        #expect(throws: CancellationError.self) {
            try buffer.retireAfterSuccessfulDrain(generation: 5) {
                throw CancellationError()
            }
        }

        #expect(packets.allSatisfy { $0.value != nil })
        #expect(buffer.takeReplayPackets(generation: 5).map(\.presentationTimestamp) == [0, 1, 2])
    }

    @Test func staleDrainDoesNotRetireANewerGeneration() throws {
        let buffer = VideoRecoveryPacketBuffer()
        let packets = try recordGOP(in: buffer, generation: 8)
        var drains = 0

        buffer.retireAfterSuccessfulDrain(generation: 7) { drains += 1 }

        #expect(drains == 1)
        #expect(packets.allSatisfy { $0.value != nil })
        #expect(buffer.takeReplayPackets(generation: 8).map(\.presentationTimestamp) == [0, 1, 2])
    }

    @Test func seekDuringDrainPreservesTheNewGOP() throws {
        let buffer = VideoRecoveryPacketBuffer()
        let oldPackets = try recordGOP(in: buffer, generation: 10)
        var nextPackets: [WeakPacket] = []

        try buffer.retireAfterSuccessfulDrain(generation: 10) {
            // This deterministic interleaving also proves the callback is not
            // invoked under the buffer's lock: both operations acquire it.
            buffer.reset(generation: 11)
            nextPackets = try recordGOP(in: buffer, generation: 11)
        }

        #expect(oldPackets.allSatisfy { $0.value == nil })
        #expect(nextPackets.allSatisfy { $0.value != nil })
        let replay = buffer.takeReplayPackets(generation: 11)
        #expect(replay.count == 3)
        #expect(replay.allSatisfy { $0.generation == 11 })
        #expect(replay.map(\.presentationTimestamp) == [0, 1, 2])
    }

    @Test func aSeekAfterRetirementCanBuildANewReplay() throws {
        let buffer = VideoRecoveryPacketBuffer()
        let oldPackets = try recordGOP(in: buffer, generation: 12)
        buffer.retireAfterSuccessfulDrain(generation: 12) {}
        #expect(oldPackets.allSatisfy { $0.value == nil })

        buffer.reset(generation: 13)
        let dependent = try recordPacket(in: buffer, bytes: 32, keyframe: false, generation: 13)
        #expect(dependent.value == nil)
        let nextPackets = try recordGOP(in: buffer, generation: 13)
        #expect(nextPackets.allSatisfy { $0.value != nil })
        #expect(buffer.takeReplayPackets(generation: 13).map(\.presentationTimestamp) == [0, 1, 2])
    }

    @Test func emptyAndRepeatedRetirementStillExecuteTheDrain() {
        let buffer = VideoRecoveryPacketBuffer()
        var drains = 0
        buffer.retireAfterSuccessfulDrain(generation: 1) { drains += 1 }
        buffer.reset(generation: 1)
        buffer.retireAfterSuccessfulDrain(generation: 1) { drains += 1 }
        buffer.retireAfterSuccessfulDrain(generation: 1) { drains += 1 }
        #expect(drains == 3)
        #expect(buffer.takeReplayPackets(generation: 1).isEmpty)
    }

    @Test func retiringPacketsDoesNotInvalidateAnExternalNativeBufferReference() throws {
        let buffer = VideoRecoveryPacketBuffer()
        var external: UnsafeMutablePointer<AVBufferRef>?
        defer { av_buffer_unref(&external) }
        let packet = try recordPacket(
            in: buffer, bytes: 64, keyframe: true, generation: 14,
            borrow: { packet in
                let native = try #require(packet.pointer?.pointee.buf)
                external = try #require(av_buffer_ref(native))
            }
        )

        buffer.retireAfterSuccessfulDrain(generation: 14) {}

        #expect(packet.value == nil)
        let retained = try #require(external)
        #expect(av_buffer_get_ref_count(retained) == 1)
        // av_new_packet includes FFmpeg's required input padding in its
        // backing allocation; the packet's advertised payload is 64 bytes.
        #expect(retained.pointee.size >= 64)
        #expect(retained.pointee.data[0] == 19)
        #expect(retained.pointee.data[63] == 23)
        withExtendedLifetime(buffer) {}
    }

    @Test func anotherPacketOwnerRemainsValidAfterRetirement() throws {
        let buffer = VideoRecoveryPacketBuffer()
        let observer = try recordPacket(in: buffer, bytes: 64, keyframe: true, generation: 15)
        let packet = try #require(observer.value)
        let pointer = try #require(packet.pointer)

        buffer.retireAfterSuccessfulDrain(generation: 15) {}

        #expect(buffer.takeReplayPackets(generation: 15).isEmpty)
        #expect(packet.pointer == pointer)
        #expect(packet.byteCount == 64)
        #expect(packet.data?.first == 19)
        #expect(packet.data?.last == 23)
        #expect(observer.value === packet)
        withExtendedLifetime(packet) {}
    }

    private func recordGOP(
        in buffer: VideoRecoveryPacketBuffer, generation: Int
    ) throws -> [WeakPacket] {
        try (0..<3).map { index in
            try recordPacket(in: buffer, bytes: 1_024 + index,
                             keyframe: index == 0, generation: generation, pts: Int64(index))
        }
    }

    /// Returning only a weak observer prevents the fixture from extending the
    /// packet's lifetime beyond the recovery owner being tested.
    private func recordPacket(
        in buffer: VideoRecoveryPacketBuffer,
        bytes: Int,
        keyframe: Bool,
        generation: Int,
        pts: Int64 = 0,
        borrow: (FFmpegPacket) throws -> Void = { _ in }
    ) throws -> WeakPacket {
        var source = av_packet_alloc()
        let native = try #require(source)
        defer { av_packet_free(&source) }
        try #require(av_new_packet(native, Int32(bytes)) == 0)
        let data = try #require(native.pointee.data)
        data[0] = 19
        data[bytes - 1] = 23
        native.pointee.stream_index = 0
        native.pointee.pts = pts
        native.pointee.dts = pts
        native.pointee.duration = 1
        native.pointee.flags = keyframe ? AV_PKT_FLAG_KEY : 0
        let packet = try FFmpegPacket(taking: &source, timeBase: .init(num: 1, den: 30),
                                      generation: generation)
        try borrow(packet)
        buffer.record(packet)
        return WeakPacket(packet)
    }
}
