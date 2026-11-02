import CFFmpeg
import Foundation
import Testing
@testable import IlliquidNativePlayback

/// Adapted from PR175: real FFmpeg allocations and TEST-LOCAL drain sequencing.
/// These callbacks do not exercise a production drain hook or MediaSession.
/// Actual session orchestration is covered by the EOF/session suites and the
/// extracted production-loop harness imported from PR202.
@Suite("Recovery GOP drain lifetime", .serialized)
struct VideoRecoveryGOPSequencingTests {
    private enum DrainFailure: Error { case failed }

    // Test-only orchestration. Failure/cancellation skips retirement; the
    // production releaseAfterDrain method itself enforces the generation guard.
    private func sequenceDrain(
        _ buffer: VideoRecoveryPacketBuffer, generation: Int,
        _ drain: () throws -> Void
    ) rethrows {
        try drain()
        buffer.releaseAfterDrain(generation: generation)
    }


    private final class WeakPacket {
        weak var value: FFmpegPacket?
        init(_ packet: FFmpegPacket) { value = packet }
    }

    @Test func successfulDrainReleasesTheFinalGOPWhileTheBufferRemainsAlive() throws {
        let buffer = VideoRecoveryPacketBuffer()
        let packets = try recordGOP(in: buffer, generation: 3)
        #expect(packets.allSatisfy { $0.value != nil })
        var drains = 0

        sequenceDrain(buffer, generation: 3) {
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

        sequenceDrain(buffer, generation: 1) {}

        #expect(packet.value == nil)
        withExtendedLifetime(buffer) {}
    }

    @Test func failedDrainPreservesTheCompleteReplay() throws {
        let buffer = VideoRecoveryPacketBuffer()
        let packets = try recordGOP(in: buffer, generation: 4)

        #expect(throws: DrainFailure.self) {
            try sequenceDrain(buffer, generation: 4) {
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
            try sequenceDrain(buffer, generation: 5) {
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

        sequenceDrain(buffer, generation: 7) { drains += 1 }

        #expect(drains == 1)
        #expect(packets.allSatisfy { $0.value != nil })
        #expect(buffer.takeReplayPackets(generation: 8).map(\.presentationTimestamp) == [0, 1, 2])
    }

    @Test func seekDuringDrainPreservesTheNewGOP() throws {
        let buffer = VideoRecoveryPacketBuffer()
        let oldPackets = try recordGOP(in: buffer, generation: 10)
        var nextPackets: [WeakPacket] = []

        try sequenceDrain(buffer, generation: 10) {
            // Deterministically model a seek between drain and retirement.
            // The callback here belongs only to this test helper.
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
        sequenceDrain(buffer, generation: 12) {}
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
        sequenceDrain(buffer, generation: 1) { drains += 1 }
        buffer.reset(generation: 1)
        sequenceDrain(buffer, generation: 1) { drains += 1 }
        sequenceDrain(buffer, generation: 1) { drains += 1 }
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
                let reference: UnsafeMutablePointer<AVBufferRef>? = av_buffer_ref(native)
                external = try #require(reference)
            }
        )

        sequenceDrain(buffer, generation: 14) {}

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

        sequenceDrain(buffer, generation: 15) {}

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
