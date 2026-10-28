import CFFmpeg
import Foundation
import Testing
@testable import IlliquidNativePlayback

@Suite("Video recovery packet lifetime", .serialized)
struct VideoRecoveryPacketLifetimeTests {
    enum Bound: CaseIterable, Equatable, Sendable {
        case packets
        case bytes
    }

    @Test func matchingFinishReleasesTheEntireRetainedGOP() throws {
        let buffer = VideoRecoveryPacketBuffer()
        let references = try [
            recordPacket(in: buffer, keyframe: true, generation: 7, timestamp: 100),
            recordPacket(in: buffer, keyframe: false, generation: 7, timestamp: 101),
            recordPacket(in: buffer, keyframe: false, generation: 7, timestamp: 102),
        ]
        #expect(references.map(\.count) == [2, 2, 2])

        buffer.finish(generation: 7)

        // Each packet's native owner is gone; only the independent observer
        // keeps its payload alive. The buffer itself remains alive throughout.
        #expect(references.map(\.count) == [1, 1, 1])
        #expect(buffer.takeReplayPackets(generation: 7).isEmpty)
        withExtendedLifetime(buffer) {}
    }

    @Test func staleFinishPreservesTheCurrentGenerationAndPacketOrder() throws {
        let buffer = VideoRecoveryPacketBuffer()
        let references = try [
            recordPacket(in: buffer, keyframe: true, generation: 8, timestamp: 200),
            recordPacket(in: buffer, keyframe: false, generation: 8, timestamp: 201),
        ]

        buffer.finish(generation: 7)
        buffer.finish(generation: 9)

        #expect(references.map(\.count) == [2, 2])
        var replay = buffer.takeReplayPackets(generation: 8)
        #expect(replay.map(\.generation) == [8, 8])
        #expect(replay.map(\.presentationTimestamp) == [200, 201])
        #expect(replay.map(\.isKeyframe) == [true, false])
        replay.removeAll()
        #expect(references.map(\.count) == [1, 1])
    }

    @Test(arguments: Bound.allCases)
    func finishReleasesAnInclusiveLimitGOP(bound: Bound) throws {
        let buffer = VideoRecoveryPacketBuffer()
        let packetCount = bound == .packets ? VideoRecoveryPacketBuffer.maximumPacketCount : 1
        let packetBytes = bound == .bytes ? VideoRecoveryPacketBuffer.maximumByteCount : 1
        var references: [PayloadReference] = []
        for index in 0..<packetCount {
            references.append(try recordPacket(
                in: buffer,
                bytes: packetBytes,
                keyframe: index == 0,
                generation: 1,
                timestamp: Int64(index)
            ))
        }
        // Equality with each limit must retain a replayable GOP until finish.
        #expect(references.count == packetCount)
        #expect(references.allSatisfy { $0.count == 2 })

        buffer.finish(generation: 1)

        #expect(references.allSatisfy { $0.count == 1 })
        #expect(buffer.takeReplayPackets(generation: 1).isEmpty)
        withExtendedLifetime(buffer) {}
    }

    @Test func finishRejectsDependentTailUntilTheNextKeyframe() throws {
        let buffer = VideoRecoveryPacketBuffer()
        let first = try recordPacket(in: buffer, keyframe: true, generation: 3, timestamp: 10)
        buffer.finish(generation: 3)
        #expect(first.count == 1)

        let ignored = try recordPacket(in: buffer, keyframe: false, generation: 3, timestamp: 11)
        #expect(ignored.count == 1)
        let next = try recordPacket(in: buffer, keyframe: true, generation: 3, timestamp: 20)
        let tail = try recordPacket(in: buffer, keyframe: false, generation: 3, timestamp: 21)
        #expect(next.count == 2)
        #expect(tail.count == 2)

        var replay = buffer.takeReplayPackets(generation: 3)
        #expect(replay.map(\.presentationTimestamp) == [20, 21])
        replay.removeAll()
        #expect(next.count == 1)
        #expect(tail.count == 1)
    }

    @Test func transferredRecoveryReplaySurvivesFinish() throws {
        let buffer = VideoRecoveryPacketBuffer()
        let references = try [
            recordPacket(in: buffer, keyframe: true, generation: 4, timestamp: 30, marker: 71),
            recordPacket(in: buffer, keyframe: false, generation: 4, timestamp: 31, marker: 72),
        ]
        var replay = buffer.takeReplayPackets(generation: 4)
        try #require(replay.count == 2)

        buffer.finish(generation: 4)

        #expect(references.map(\.count) == [2, 2])
        #expect(replay.map(\.presentationTimestamp) == [30, 31])
        #expect(replay.map(\.data) == [Data([71]), Data([72])])
        #expect(buffer.takeReplayPackets(generation: 4).isEmpty)
        replay.removeAll()
        #expect(references.map(\.count) == [1, 1])
    }

    @Test func nativePacketCloneSurvivesBufferFinish() throws {
        let buffer = VideoRecoveryPacketBuffer()
        var clone: UnsafeMutablePointer<AVPacket>?
        defer { av_packet_free(&clone) }
        let reference = try recordClonedPacket(in: buffer, clone: &clone)
        #expect(reference.count == 3)

        buffer.finish(generation: 5)

        #expect(reference.count == 2)
        let retained = try #require(clone)
        #expect(retained.pointee.size == 1)
        #expect(retained.pointee.pts == 40)
        #expect(retained.pointee.data[0] == 91)
        av_packet_free(&clone)
        #expect(reference.count == 1)
        withExtendedLifetime(buffer) {}
    }

    @Test func resetAndRepeatedFinishPreserveGenerationAdmission() throws {
        let buffer = VideoRecoveryPacketBuffer()
        buffer.finish(generation: 1)
        let old = try recordPacket(in: buffer, keyframe: true, generation: 1, timestamp: 50)
        buffer.reset(generation: 2)
        #expect(old.count == 1)

        let ignored = try recordPacket(in: buffer, keyframe: false, generation: 2, timestamp: 51)
        #expect(ignored.count == 1)
        let current = try recordPacket(in: buffer, keyframe: true, generation: 2, timestamp: 60)
        buffer.finish(generation: 1)
        #expect(current.count == 2)
        buffer.finish(generation: 2)
        buffer.finish(generation: 2)
        #expect(current.count == 1)

        buffer.reset()
        let fresh = try recordPacket(in: buffer, keyframe: true, generation: 9, timestamp: 70)
        #expect(fresh.count == 2)
        buffer.finish(generation: 2)
        #expect(fresh.count == 2)
        buffer.finish(generation: 9)
        #expect(fresh.count == 1)
        withExtendedLifetime(buffer) {}
    }

    // Returning from this helper ends the temporary Swift packet's lifetime.
    // The caller receives an AVBufferRef observer, never another packet owner.
    @inline(never)
    private func recordPacket(
        in buffer: VideoRecoveryPacketBuffer,
        bytes: Int = 1,
        keyframe: Bool,
        generation: Int,
        timestamp: Int64,
        marker: UInt8 = 17
    ) throws -> PayloadReference {
        let packet = try makePacket(
            bytes: bytes, keyframe: keyframe, generation: generation,
            timestamp: timestamp, marker: marker
        )
        let reference = try PayloadReference(packet)
        buffer.record(packet)
        return reference
    }

    @inline(never)
    private func recordClonedPacket(
        in buffer: VideoRecoveryPacketBuffer,
        clone: inout UnsafeMutablePointer<AVPacket>?
    ) throws -> PayloadReference {
        let packet = try makePacket(
            bytes: 1, keyframe: true, generation: 5, timestamp: 40, marker: 91
        )
        let reference = try PayloadReference(packet)
        clone = try #require(av_packet_clone(packet.pointer))
        buffer.record(packet)
        return reference
    }

    private func makePacket(
        bytes: Int, keyframe: Bool, generation: Int, timestamp: Int64, marker: UInt8
    ) throws -> FFmpegPacket {
        var source = av_packet_alloc()
        let pointer = try #require(source)
        defer { av_packet_free(&source) }
        try #require(bytes > 0)
        let encodedSize = try #require(Int32(exactly: bytes))
        try #require(av_new_packet(pointer, encodedSize) == 0)
        let data = try #require(pointer.pointee.data)
        data[0] = marker
        data[bytes - 1] = marker
        pointer.pointee.flags = keyframe ? AV_PKT_FLAG_KEY : 0
        pointer.pointee.stream_index = 0
        pointer.pointee.pts = timestamp
        pointer.pointee.dts = timestamp - 1
        pointer.pointee.duration = 1
        return try FFmpegPacket(
            taking: &source, timeBase: AVRational(num: 1, den: 1_000),
            generation: generation
        )
    }

    /// Holds one explicit native reference so the count can be inspected after
    /// FFmpegPacket deinitializes. A count of one means the observer alone owns
    /// the payload; this measures released ownership, not process RSS.
    private final class PayloadReference {
        private var reference: UnsafeMutablePointer<AVBufferRef>?

        init(_ packet: FFmpegPacket) throws {
            let buffer = try #require(packet.pointer?.pointee.buf)
            reference = try #require(av_buffer_ref(buffer))
        }

        var count: Int {
            guard let reference else { return 0 }
            return Int(av_buffer_get_ref_count(reference))
        }

        deinit {
            av_buffer_unref(&reference)
        }
    }
}
