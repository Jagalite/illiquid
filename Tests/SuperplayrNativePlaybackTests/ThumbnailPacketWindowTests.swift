import CFFmpeg
import Foundation
import Testing
@testable import SuperplayrNativePlayback

@Suite("Experimental thumbnail packet window")
struct ThumbnailPacketWindowTests {
    private func packet(_ seconds: Int64, bytes: Int32 = 4, keyframe: Bool = false, corrupt: Bool = false) throws -> FFmpegPacket {
        var raw = av_packet_alloc()
        defer { av_packet_free(&raw) }
        let p = try #require(raw)
        try checkFFmpeg(av_new_packet(p, bytes), operation: "Test packet")
        p.pointee.pts = seconds; p.pointee.dts = seconds
        p.pointee.flags = (keyframe ? AV_PKT_FLAG_KEY : 0) | (corrupt ? AV_PKT_FLAG_CORRUPT : 0)
        return try FFmpegPacket(moving: p, timeBase: AVRational(num: 1, den: 1), generation: 1)
    }

    @Test func requiresIndexedKeyframeAndFallsBackOutsideCoverage() throws {
        let window = ThumbnailPacketWindow(maximumBytes: 100)
        window.append(try packet(0)); #expect(window.packets.isEmpty)
        let first = try packet(1, keyframe: true)
        window.append(first); window.append(try packet(2)); window.append(try packet(3))
        #expect(!window.beginReplay(keyframeSeconds: nil, targetSeconds: 2))
        #expect(!window.beginReplay(keyframeSeconds: 0, targetSeconds: 2))
        #expect(!window.beginReplay(keyframeSeconds: 1, targetSeconds: 4))
        #expect(!window.beginReplay(keyframeSeconds: 1, targetSeconds: 0))
        #expect(window.beginReplay(keyframeSeconds: 1, targetSeconds: 2))
        #expect(window.next() === first)
        #expect(window.next()?.presentationSeconds == 2)
        #expect(window.next()?.presentationSeconds == 3)
        #expect(window.next() == nil)
    }

    @Test func byteAndCountOverflowNeverReplayPartialGOP() throws {
        for window in [ThumbnailPacketWindow(maximumBytes: 8), ThumbnailPacketWindow(maximumBytes: 100, maximumPackets: 2)] {
            window.append(try packet(0, keyframe: true)); window.append(try packet(1))
            window.append(try packet(2)); #expect(window.bytes == 0)
            window.append(try packet(3)); #expect(window.packets.isEmpty)
            window.append(try packet(4, keyframe: true)); #expect(window.packets.count == 1)
            window.append(try packet(5, corrupt: true)); #expect(window.packets.isEmpty)
        }
        let tiny = ThumbnailPacketWindow(maximumBytes: 1)
        tiny.append(try packet(0, keyframe: true)); #expect(tiny.bytes == 0)
    }

    @Test func prefetchReplaysBeforeReturningToDemuxFrontierAndResetInvalidatesIt() throws {
        let window = ThumbnailPacketWindow(maximumBytes: 100)
        window.append(try packet(0, keyframe: true))
        let revision = window.revision, index = window.packets.count
        #expect(!window.replayPrefetched(from: -1, revision: revision))
        window.append(try packet(1)); window.append(try packet(2))
        #expect(window.replayPrefetched(from: index, revision: revision))
        #expect(!window.isAtDemuxFrontier)
        #expect(window.next()?.presentationSeconds == 1)
        #expect(window.next()?.presentationSeconds == 2)
        #expect(window.isAtDemuxFrontier)
        window.reset()
        #expect(!window.replayPrefetched(from: index, revision: revision))
        #expect(!window.beginReplay(keyframeSeconds: 0, targetSeconds: 1))
    }
}
