import CFFmpeg
import Foundation
import Testing
@testable import IlliquidNativePlayback

@Suite("Demux packet ownership and recovery limits")
struct PacketOwnershipTests {
    @Test func takingPreservesHeaderPayloadPropertiesAndSideData() throws {
        var source = av_packet_alloc()
        let original = try #require(source)
        defer { av_packet_free(&source) }
        #expect(av_new_packet(original, 4) == 0)
        let bytes = try #require(original.pointee.data)
        for i in 0..<4 { bytes[i] = UInt8(i + 10) }
        original.pointee.pts = 90_000
        original.pointee.dts = 87_000
        original.pointee.duration = 3_000
        original.pointee.stream_index = 2
        original.pointee.flags = AV_PKT_FLAG_KEY | AV_PKT_FLAG_CORRUPT
        let extra = try #require(av_packet_new_side_data(original, AV_PKT_DATA_STRINGS_METADATA, 4))
        for i in 0..<4 { extra[i] = UInt8(i + 20) }
        let packet = try FFmpegPacket(taking: &source, timeBase: AVRational(num: 1, den: 90_000), generation: 7)
        #expect(source == nil)
        #expect(packet.pointer == original)
        #expect(packet.pointer?.pointee.data == bytes)
        #expect(packet.data == Data([10, 11, 12, 13]))
        #expect(packet.generation == 7 && packet.streamIndex == 2)
        #expect(packet.presentationTimestamp == 90_000 && packet.decodeTimestamp == 87_000)
        #expect(packet.duration == 3_000 && packet.isKeyframe && packet.isCorrupt)
        var size = 0
        let saved = try #require(av_packet_get_side_data(packet.pointer, AV_PKT_DATA_STRINGS_METADATA, &size))
        #expect(size == 4 && Data(bytes: saved, count: size) == Data([20, 21, 22, 23]))
    }

    @Test func movingStillEmptiesReusableScratchAndCloneOutlivesOwner() throws {
        var scratch = av_packet_alloc()
        let source = try #require(scratch)
        defer { av_packet_free(&scratch) }
        #expect(av_new_packet(source, 1) == 0)
        source.pointee.data[0] = 91
        var owner: FFmpegPacket? = try FFmpegPacket(moving: source, timeBase: AVRational(num: 1, den: 1), generation: 1)
        #expect(scratch != nil && scratch?.pointee.data == nil)
        var clone = av_packet_clone(owner?.pointer)
        let retained = try #require(clone)
        defer { av_packet_free(&clone) }
        owner = nil
        #expect(retained.pointee.size == 1 && retained.pointee.data[0] == 91)
    }

    @Test func takingMissingPointerThrowsWithoutChangingIt() throws {
        var source: UnsafeMutablePointer<AVPacket>?
        #expect(throws: FFmpegError.self) {
            _ = try FFmpegPacket(taking: &source, timeBase: AVRational(num: 1, den: 1), generation: 1)
        }
        #expect(source == nil)
    }

    @Test func oversizedKeyframeInvalidatesOldReplayAndRejectsItsTail() throws {
        let buffer = VideoRecoveryPacketBuffer()
        buffer.record(try makePacket(bytes: 1, keyframe: true))
        buffer.record(try makePacket(bytes: VideoRecoveryPacketBuffer.maximumByteCount + 1, keyframe: true))
        buffer.record(try makePacket(bytes: 1, keyframe: false))
        #expect(buffer.takeReplayPackets(generation: 1).isEmpty)
        buffer.record(try makePacket(bytes: 1, keyframe: true))
        buffer.record(try makePacket(bytes: 1, keyframe: false))
        #expect(buffer.takeReplayPackets(generation: 1).count == 2)
    }

    @Test func recoveryByteBoundaryIsInclusive() throws {
        let buffer = VideoRecoveryPacketBuffer()
        let full = try makePacket(bytes: VideoRecoveryPacketBuffer.maximumByteCount, keyframe: true)
        buffer.record(full)
        #expect(buffer.takeReplayPackets(generation: 1).count == 1)
        buffer.record(full)
        buffer.record(try makePacket(bytes: 1, keyframe: false))
        #expect(buffer.takeReplayPackets(generation: 1).isEmpty)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ILLIQUID_PACKET_OWNERSHIP_FIXTURE"] != nil))
    func demuxedPacketsRemainImmutableAcrossFurtherReadsAndSeek() throws {
        let path = try #require(ProcessInfo.processInfo.environment["ILLIQUID_PACKET_OWNERSHIP_FIXTURE"])
        let demuxer = try FFmpegDemuxer(url: URL(fileURLWithPath: path))
        var retained: [FFmpegPacket] = []
        for _ in 0..<64 {
            if let packet = try demuxer.readPacket(generation: 1) { retained.append(packet) }
        }
        #expect(!retained.isEmpty)
        let data = retained.map(\.data)
        let pts = retained.map(\.presentationTimestamp)
        let dts = retained.map(\.decodeTimestamp)
        let addresses = Set(retained.compactMap { $0.pointer.map { UInt(bitPattern: $0) } })
        #expect(addresses.count == retained.count)
        for _ in 0..<512 { _ = try demuxer.readPacket(generation: 1) }
        try demuxer.seek(to: 0, exact: true)
        let packetAfterSeek = try demuxer.readPacket(generation: 2)
        let afterSeek = try #require(packetAfterSeek)
        #expect(afterSeek.generation == 2)
        #expect(retained.map(\.data) == data)
        #expect(retained.map(\.presentationTimestamp) == pts)
        #expect(retained.map(\.decodeTimestamp) == dts)
        #expect(retained.allSatisfy { $0.generation == 1 })
    }

    private func makePacket(bytes: Int, keyframe: Bool) throws -> FFmpegPacket {
        var source = av_packet_alloc()
        let pointer = try #require(source)
        defer { av_packet_free(&source) }
        #expect(av_new_packet(pointer, Int32(bytes)) == 0)
        pointer.pointee.flags = keyframe ? AV_PKT_FLAG_KEY : 0
        return try FFmpegPacket(taking: &source, timeBase: AVRational(num: 1, den: 1), generation: 1)
    }
}
