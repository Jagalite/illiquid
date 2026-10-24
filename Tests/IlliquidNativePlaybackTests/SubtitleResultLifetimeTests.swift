import CFFmpeg
import CoreGraphics
import Foundation
import Testing
@testable import IlliquidNativePlayback

@Suite("Subtitle decoder scratch-output lifetime")
struct SubtitleResultLifetimeTests {
    @Test func bitmapEventsOutliveNativeOutputUpdatesFlushAndDecoderDestruction() throws {
        var decoder: SubtitleDecoder? = try makeDecoder()
        weak var retiredDecoder = decoder
        let first = try #require(try decoder?.decode(packet(fullPGS, at: 2)).first)
        let bitmap = try #require(first.bitmapComposition)
        let region = try #require(bitmap.regions.first)
        #expect(decoder?.hasRetainedDecodedOutput == false)
        #expect(first.assData.isEmpty)
        #expect(first.presentationSeconds == 2)
        #expect(first.durationSeconds == Double(UInt32.max) / 1_000)
        #expect(first.generation == 7)
        #expect(bitmap.canvasSize == CGSize(width: 1_280, height: 720))
        #expect(bitmap.duration == nil)
        #expect(region.frame == CGRect(x: 10, y: 20, width: 3, height: 2))
        #expect(region.isForced)
        #expect(region.pixels == expectedPGSPixels)

        // Stateful PGS objects and palette live in AVCodecContext, independently
        // of the temporary AVSubtitle rectangles returned for each display set.
        let updated = try #require(try decoder?.decode(packet(palette + end, at: 3)).first)
        #expect(updated.bitmapComposition?.regions.first?.pixels == expectedPGSPixels)
        #expect(decoder?.hasRetainedDecodedOutput == false)
        let cleared = try #require(try decoder?.decode(packet(clearPGS, at: 4)).first)
        #expect(cleared.presentationSeconds == 4)
        #expect(cleared.bitmapComposition?.regions.isEmpty == true)
        #expect(decoder?.hasRetainedDecodedOutput == false)

        try decoder?.flush()
        #expect(decoder?.hasRetainedDecodedOutput == false)
        let restored = try #require(try decoder?.decode(packet(fullPGS, at: 1)).first)
        #expect(restored.bitmapComposition?.regions.first?.pixels == expectedPGSPixels)
        #expect(decoder?.hasRetainedDecodedOutput == false)
        decoder = nil
        #expect(retiredDecoder == nil)
        #expect(region.pixels == expectedPGSPixels)
        #expect(first.presentationSeconds == 2)
        #expect(updated.presentationSeconds == 3)
        #expect(restored.presentationSeconds == 1)
    }

    @Test func incompleteDisplaySetsKeepCodecHistoryWithoutRetainingOutput() throws {
        let decoder = try makeDecoder()
        #expect(!decoder.hasRetainedDecodedOutput)
        #expect(try decoder.decode(packet(presentation(), at: 2)).isEmpty)
        #expect(!decoder.hasRetainedDecodedOutput)
        let completed = try decoder.decode(packet(palette + object + end, at: 2))
        #expect(completed.first?.bitmapComposition?.regions.first?.pixels == expectedPGSPixels)
        #expect(!decoder.hasRetainedDecodedOutput)
        #expect(try decoder.decode(packet(palette, at: 3)).isEmpty)
        #expect(!decoder.hasRetainedDecodedOutput)
        let updated = try decoder.decode(packet(end, at: 3))
        #expect(updated.first?.bitmapComposition?.regions.first?.pixels == expectedPGSPixels)
        #expect(!decoder.hasRetainedDecodedOutput)
    }

    @Test func textEventsOwnTheirBytesAcrossNativeOutputReuseFlushAndDestruction() throws {
        var decoder: SubtitleDecoder? = try makeDecoder(codec: AV_CODEC_ID_SUBRIP, name: "subrip")
        weak var retiredDecoder = decoder
        let first = try #require(try decoder?.decode(packet(Array("First caption".utf8), at: 2)).first)
        #expect(decoder?.hasRetainedDecodedOutput == false)
        #expect(first.assData == Data("0,0,Default,,0,0,0,,First caption".utf8))
        #expect(first.presentationSeconds == 2)
        #expect(first.durationSeconds == 2)
        #expect(first.generation == 7)
        #expect(first.bitmapComposition == nil)
        let second = try #require(try decoder?.decode(packet(Array("Second caption".utf8), at: 4)).first)
        #expect(decoder?.hasRetainedDecodedOutput == false)
        #expect(second.assData == Data("1,0,Default,,0,0,0,,Second caption".utf8))
        try decoder?.flush()
        let replayed = try #require(try decoder?.decode(packet(Array("Third caption".utf8), at: 1)).first)
        #expect(decoder?.hasRetainedDecodedOutput == false)
        // The native shim deliberately preserves ReadOrder across text flushes.
        #expect(replayed.assData == Data("2,0,Default,,0,0,0,,Third caption".utf8))
        decoder = nil
        #expect(retiredDecoder == nil)
        #expect(first.assData == Data("0,0,Default,,0,0,0,,First caption".utf8))
        #expect(second.assData == Data("1,0,Default,,0,0,0,,Second caption".utf8))
        #expect(replayed.assData == Data("2,0,Default,,0,0,0,,Third caption".utf8))
    }

    @Test func bitmapBudgetRejectionReleasesNativeOutputAndAllowsRecovery() throws {
        let budget = SubtitleMemoryBudget(limitBytes: 24, ownerLimitsBytes: [:])
        let blocker = try #require(budget.acquire(owner: .bitmapEvents, bytes: 24))
        let decoder = try makeDecoder(budget: budget)
        #expect(throws: PresentationError.self) {
            try decoder.decode(packet(fullPGS, at: 2))
        }
        #expect(!decoder.hasRetainedDecodedOutput)
        #expect(budget.snapshot.reservedBytes == 24)
        #expect(blocker.resize(to: 0))

        var events = try decoder.decode(packet(palette + end, at: 3))
        #expect(!decoder.hasRetainedDecodedOutput)
        #expect(events.first?.bitmapComposition?.regions.first?.pixels == expectedPGSPixels)
        #expect(budget.snapshot.reservedBytes == 24)
        events.removeAll()
        #expect(budget.snapshot.reservedBytes == 0)
    }

    @Test func cropConversionRejectionReleasesNativeOutputAndAllowsRecovery() throws {
        let decoder = try makeDecoder()
        // Valid packet metadata reaches native decoding, then the crop exceeds
        // the decoded 3x2 object. Swift conversion throws after output exists.
        let invalid = presentation(crop: [3, 0, 1, 1]) + palette + object + end
        #expect(throws: FFmpegError.self) {
            try decoder.decode(packet(invalid, at: 2))
        }
        #expect(!decoder.hasRetainedDecodedOutput)
        let recovered = try decoder.decode(packet(presentation(epoch: false) + end, at: 3))
        #expect(recovered.first?.bitmapComposition?.regions.first?.pixels == expectedPGSPixels)
        #expect(!decoder.hasRetainedDecodedOutput)
    }

    @Test func metadataParsingFailureLeavesNoNativeOutputAndPreservesEarlierEvents() throws {
        let decoder = try makeDecoder()
        let first = try #require(try decoder.decode(packet(fullPGS, at: 2)).first)
        #expect(throws: FFmpegError.self) {
            try decoder.decode(packet([0x16, 0, 11, 0], at: 3))
        }
        #expect(!decoder.hasRetainedDecodedOutput)
        #expect(first.bitmapComposition?.regions.first?.pixels == expectedPGSPixels)
        let updated = try decoder.decode(packet(palette + end, at: 4))
        #expect(updated.first?.bitmapComposition?.regions.first?.pixels == expectedPGSPixels)
        #expect(!decoder.hasRetainedDecodedOutput)
    }

    @Test func dvbOutputAndNativeDecodeFailureLeaveOwnedEventsIntact() throws {
        let decoder = try makeDecoder(codec: AV_CODEC_ID_DVB_SUBTITLE, name: "dvb_subtitle")
        let first = try #require(try decoder.decode(packet(fullDVB, at: 2)).first)
        #expect(!decoder.hasRetainedDecodedOutput)
        #expect(first.presentationSeconds == 2)
        #expect(first.durationSeconds == 2)
        #expect(first.generation == 7)
        #expect(first.bitmapComposition?.duration == 2)
        #expect(first.bitmapComposition?.canvasSize == CGSize(width: 1_280, height: 720))
        #expect(first.bitmapComposition?.regions.first?.frame == CGRect(x: 10, y: 20, width: 2, height: 2))
        #expect(first.bitmapComposition?.regions.first?.pixels == Data(repeating: 255, count: 16))

        // DVB reaches FFmpeg directly; this fails its native segment framing.
        do {
            _ = try decoder.decode(packet([0, 0, 0, 0, 0, 0, 0], at: 3))
            Issue.record("Malformed DVB packet was accepted")
        } catch let error as FFmpegError {
            #expect(error.operation == "Decode dvb_subtitle subtitle packet")
            #expect(error.code == illiquid_averror_invaliddata())
        }
        #expect(!decoder.hasRetainedDecodedOutput)
        let clear = try decoder.decode(packet(dvbSegment(0x10, [2, 0x10]) + dvbSegment(0x80, []), at: 4))
        #expect(clear.first?.bitmapComposition?.regions.isEmpty == true)
        #expect(!decoder.hasRetainedDecodedOutput)
        try decoder.flush()
        #expect(!decoder.hasRetainedDecodedOutput)
        #expect(first.bitmapComposition?.regions.first?.pixels == Data(repeating: 255, count: 16))
    }

    private func makeDecoder(
        codec: AVCodecID = AV_CODEC_ID_HDMV_PGS_SUBTITLE,
        name: String = "hdmv_pgs_subtitle",
        budget: SubtitleMemoryBudget? = nil
    ) throws -> SubtitleDecoder {
        var parameters = avcodec_parameters_alloc()
        let pointer = try #require(parameters)
        defer { avcodec_parameters_free(&parameters) }
        pointer.pointee.codec_type = AVMEDIA_TYPE_SUBTITLE
        pointer.pointee.codec_id = codec
        if codec == AV_CODEC_ID_DVB_SUBTITLE {
            let extra = try #require(av_mallocz(4 + Int(AV_INPUT_BUFFER_PADDING_SIZE)))
                .assumingMemoryBound(to: UInt8.self)
            extra[1] = 1 // Composition page 1; ancillary page 2.
            extra[3] = 2
            pointer.pointee.extradata = extra
            pointer.pointee.extradata_size = 4
        }
        let stream = FFmpegStreamInfo(
            index: 0, kind: .subtitle, codecID: Int32(codec.rawValue), codecName: name,
            title: nil, language: nil, timeBase: .init(numerator: 1, denominator: 1_000_000),
            duration: nil, disposition: 0, codedSize: nil, pixelAspectRatio: nil, averageFrameRate: nil,
            sampleRate: nil, channelCount: nil, channelLayout: nil, rotationDegrees: 0,
            isMirrored: false, interlaceMode: .progressive
        )
        return try SubtitleDecoder(parameters: pointer, stream: stream, memoryBudget: budget)
    }

    private var expectedPGSPixels: Data { Data([UInt8(255), 0, 255, 0, 255, 0].flatMap { [$0, $0, $0, $0] }) }
    private var fullPGS: [UInt8] { presentation() + palette + object + end }
    private var clearPGS: [UInt8] { segment(0x16, [5, 0, 2, 208, 16, 0, 2, 0, 0, 0, 0]) + end }
    private var palette: [UInt8] { segment(0x14, [0, 0, 0, 16, 128, 128, 0, 1, 235, 128, 128, 255]) }
    private var object: [UInt8] {
        segment(0x15, [0, 1, 0, 192, 0, 0, 17, 0, 3, 0, 2, 1, 0, 1, 1, 0, 0, 0, 1, 1, 0, 1, 0, 0])
    }
    private var end: [UInt8] { segment(0x80, []) }

    private func presentation(crop: [UInt16]? = nil, epoch: Bool = true) -> [UInt8] {
        var bytes: [UInt8] = [5, 0, 2, 208, 16, 0, 1, epoch ? 128 : 0, 0, 0, 1,
                              0, 1, 0, crop == nil ? 0x40 : 0xC0, 0, 10, 0, 20]
        if let crop {
            for value in crop { bytes += [UInt8(value >> 8), UInt8(value & 255)] }
        }
        return segment(0x16, bytes)
    }

    private var fullDVB: [UInt8] {
        let definition = dvbSegment(0x14, [0, 4, 255, 2, 207])
        let page = dvbSegment(0x10, [2, 4, 1, 0, 0, 10, 0, 20])
        let region = dvbSegment(0x11, [1, 8, 0, 2, 0, 2, 12, 0, 1, 0, 0, 1, 0, 0, 0, 0])
        let palette = dvbSegment(0x12, [0, 0, 1, 0x21, 235, 128, 128, 0])
        let object = dvbSegment(0x13, [0, 1, 0, 0, 6, 0, 6, 0x12, 1, 1, 0, 0, 0xF0,
                                      0x12, 1, 1, 0, 0, 0xF0])
        return definition + page + region + palette + object + dvbSegment(0x80, [])
    }

    private func segment(_ kind: UInt8, _ bytes: [UInt8]) -> [UInt8] {
        [kind, UInt8(bytes.count >> 8), UInt8(bytes.count & 255)] + bytes
    }

    private func dvbSegment(_ kind: UInt8, _ bytes: [UInt8]) -> [UInt8] {
        [0x0F, kind, 0, 1, UInt8(bytes.count >> 8), UInt8(bytes.count & 255)] + bytes
    }

    private func packet(_ bytes: [UInt8], at seconds: Int64) throws -> FFmpegPacket {
        var raw = av_packet_alloc()
        let pointer = try #require(raw)
        defer { av_packet_free(&raw) }
        try checkFFmpeg(av_new_packet(pointer, Int32(bytes.count)), operation: "Allocate subtitle lifetime test packet")
        bytes.withUnsafeBufferPointer { source in
            if let base = source.baseAddress, !source.isEmpty {
                pointer.pointee.data.update(from: base, count: source.count)
            }
        }
        pointer.pointee.pts = seconds * 1_000_000
        pointer.pointee.dts = pointer.pointee.pts
        pointer.pointee.duration = 2_000_000
        return try FFmpegPacket(taking: &raw, timeBase: .init(num: 1, den: 1_000_000), generation: 7)
    }
}
