import CFFmpeg
import Foundation
import Testing
@testable import IlliquidNativePlayback

@Suite("Bitmap subtitle acquisition packet borrowing")
struct SubtitleAcquisitionPacketBorrowTests {
    @Test func pgsRecognizesCompositionStateFlagsWithoutReinterpretingOtherFields() throws {
        let states: [(UInt8, Bool)] = [
            (0x00, false), (0x3F, false), (0x40, true), (0x7F, true),
            (0x80, true), (0xBF, true), (0xC0, true), (0xFF, true),
        ]
        for (state, expected) in states {
            try expectPGS(pgsComposition(state: state), expected: expected)
        }
        try expectPGS(pgsSegment(0x15, pgsCompositionBody(state: 0x80)), expected: false)
        try expectPGS(pgsSegment(0x16, Array(pgsCompositionBody(state: 0x80).prefix(10))), expected: false)
    }

    @Test func dvbRequiresAnAcquisitionStateForTheSelectedCompositionPage() throws {
        // Version and reserved bits must not change the two-bit page state.
        let states: [(UInt8, Bool)] = [(0xF3, false), (0xF7, true), (0xFB, true), (0xFF, false)]
        for pageID: UInt16 in [0, 1, 65_535] {
            for (flags, expected) in states {
                let bytes = dvbSegment(0x10, [2, flags], pageID: pageID)
                try expectDVB(bytes, pageID: pageID, expected: expected)
                try expectDVB(bytes, pageID: nil, expected: expected)
                try expectDVB(bytes, pageID: pageID ^ 1, expected: false)
            }
        }
        try expectDVB(dvbSegment(0x11, [2, 4]), pageID: nil, expected: false)
        try expectDVB(dvbSegment(0x10, [4]), pageID: nil, expected: false)
    }

    @Test func incompleteHeadersAndBodiesNeverProduceAcquisition() throws {
        let pgs = pgsComposition(state: 0x80)
        let dvb = dvbSegment(0x10, [2, 4])
        for count in 0..<pgs.count {
            try expectPGS(Array(pgs.prefix(count)), expected: false)
        }
        for count in 0..<dvb.count {
            try expectDVB(Array(dvb.prefix(count)), pageID: nil, expected: false)
        }
        var wrongSync = dvb
        wrongSync[0] = 0
        try expectDVB(wrongSync, pageID: nil, expected: false)
        // A truncated segment before the acquisition must stop the scan.
        try expectPGS([0x15, 0xFF, 0xFF] + pgs, expected: false)
        try expectDVB([0x0F, 0x12, 0, 1, 0xFF, 0xFF] + dvb, pageID: nil, expected: false)
    }

    @Test func scansSkipMaximumSizedPayloadsAndRespectSegmentOrder() throws {
        let pgs = pgsComposition(state: 0x80)
        let pgsPayload = pgs + Array(repeating: UInt8(0), count: 65_535 - pgs.count)
        let pgsObject = pgsSegment(0x15, pgsPayload)
        try expectPGS(pgsObject, expected: false)
        try expectPGS(pgsComposition(state: 0) + pgsObject, expected: false)
        try expectPGS(pgsObject + pgs, expected: true)
        try expectPGS(pgs + pgsObject, expected: true)

        let dvb = dvbSegment(0x10, [2, 8])
        let dvbPayload = dvb + Array(repeating: UInt8(0), count: 65_535 - dvb.count)
        let dvbObject = dvbSegment(0x13, dvbPayload)
        try expectDVB(dvbObject, pageID: 1, expected: false)
        try expectDVB(dvbSegment(0x10, [2, 0]) + dvbObject, pageID: 1, expected: false)
        try expectDVB(dvbObject + dvb, pageID: 1, expected: true)
        try expectDVB(dvb + dvbObject, pageID: 1, expected: true)
        let otherPage = dvbSegment(0x10, [2, 4], pageID: 2)
        try expectDVB(otherPage + dvbObject, pageID: 1, expected: false)
        try expectDVB(otherPage + dvbObject + dvb, pageID: 1, expected: true)
    }

    @Test func acquisitionStillReturnsBeforeMalformedTrailingSegments() throws {
        let pgs = pgsComposition(state: 0x40)
        let pgsTails: [[UInt8]] = [[0x16], [0x16, 0], [0x15, 0, 1]]
        for tail in pgsTails {
            try expectPGS(pgs + tail, expected: true)
            try expectPGS(pgsComposition(state: 0) + tail, expected: false)
        }
        let dvb = dvbSegment(0x10, [2, 4])
        let dvbTails: [[UInt8]] = [[0x0F], [0x0F, 0x10, 0, 1, 0], [0, 0x10, 0, 1, 0, 0],
                                 [0x0F, 0x10, 0, 1, 0, 2, 2]]
        for tail in dvbTails {
            try expectDVB(dvb + tail, pageID: 1, expected: true)
            try expectDVB(dvbSegment(0x10, [2, 0]) + tail, pageID: 1, expected: false)
        }
    }

    @Test func scanningDoesNotMutateOrRetainPacketOwnership() throws {
        for bytes in [pgsComposition(state: 0x80), dvbSegment(0x10, [2, 4])] {
            var owner: FFmpegPacket? = try packet(bytes)
            weak let released = owner
            let decisions = try inspectThenOverwrite(try #require(owner), expectedBytes: bytes)
            owner = nil
            #expect(released == nil)
            #expect(decisions.pgs != decisions.dvb)
        }
    }

    @Test func missingEmptyAndNegativePayloadsMatchTheOldPacketDataPath() throws {
        var raw = av_packet_alloc()
        let pointer = try #require(raw)
        defer { av_packet_free(&raw) }
        pointer.pointee.size = 14
        let missing = try FFmpegPacket(taking: &raw,
            timeBase: AVRational(num: 1, den: 1_000), generation: 7)
        #expect(missing.data == nil)
        #expect(!PGSSubtitlePacket.isAcquisition(missing))
        #expect(!DVBSubtitlePacket.isAcquisition(missing, compositionPageID: nil))
        for count: Int32 in [0, -1] {
            let owner = try packet(pgsComposition(state: 0x80))
            let pointer = try #require(owner.pointer)
            pointer.pointee.size = count
            #expect(owner.data == nil)
            #expect(!PGSSubtitlePacket.isAcquisition(owner))
            #expect(!DVBSubtitlePacket.isAcquisition(owner, compositionPageID: nil))
        }
    }

    private func expectPGS(_ bytes: [UInt8], expected: Bool) throws {
        let owner = try packet(bytes)
        #expect(PGSSubtitlePacket.isAcquisition(owner) == expected)
        #expect(PGSSubtitlePacket.isAcquisition(Data(bytes)) == expected)
        // Data slices need not begin at index zero.
        let padded = Data([0, 0] + bytes + [0])
        #expect(PGSSubtitlePacket.isAcquisition(padded[2..<(2 + bytes.count)]) == expected)
    }

    private func expectDVB(_ bytes: [UInt8], pageID: UInt16?, expected: Bool) throws {
        let owner = try packet(bytes)
        #expect(DVBSubtitlePacket.isAcquisition(owner, compositionPageID: pageID) == expected)
        #expect(DVBSubtitlePacket.isAcquisition(Data(bytes), compositionPageID: pageID) == expected)
        let padded = Data([0, 0] + bytes + [0])
        #expect(DVBSubtitlePacket.isAcquisition(padded[2..<(2 + bytes.count)], compositionPageID: pageID) == expected)
    }

    private func inspectThenOverwrite(_ packet: FFmpegPacket, expectedBytes: [UInt8]) throws -> (pgs: Bool, dvb: Bool) {
        let pointer = try #require(packet.pointer)
        let bytes = try #require(pointer.pointee.data)
        let buffer = try #require(pointer.pointee.buf)
        let references = av_buffer_get_ref_count(buffer)
        let pgs = PGSSubtitlePacket.isAcquisition(packet)
        let dvb = DVBSubtitlePacket.isAcquisition(packet, compositionPageID: 1)
        #expect(packet.pointer == pointer)
        #expect(pointer.pointee.data == bytes)
        #expect(pointer.pointee.buf == buffer)
        #expect(pointer.pointee.size == Int32(expectedBytes.count))
        #expect(av_buffer_get_ref_count(buffer) == references)
        #expect(packet.data == Data(expectedBytes))
        #expect(packet.presentationTimestamp == 2_000 && packet.decodeTimestamp == 1_000)
        #expect(packet.duration == 500 && packet.streamIndex == 3 && packet.generation == 7)
        bytes.update(repeating: 0, count: Int(pointer.pointee.size))
        #expect(!PGSSubtitlePacket.isAcquisition(packet))
        #expect(!DVBSubtitlePacket.isAcquisition(packet, compositionPageID: 1))
        return (pgs, dvb)
    }

    private func pgsCompositionBody(state: UInt8) -> [UInt8] {
        [5, 0, 2, 208, 16, 0, 1, state, 0, 0, 0]
    }

    private func pgsComposition(state: UInt8) -> [UInt8] {
        pgsSegment(0x16, pgsCompositionBody(state: state))
    }

    private func pgsSegment(_ kind: UInt8, _ bytes: [UInt8]) -> [UInt8] {
        [kind, UInt8(bytes.count >> 8), UInt8(bytes.count & 255)] + bytes
    }

    private func dvbSegment(_ kind: UInt8, _ bytes: [UInt8], pageID: UInt16 = 1) -> [UInt8] {
        [0x0F, kind, UInt8(pageID >> 8), UInt8(pageID & 255), UInt8(bytes.count >> 8), UInt8(bytes.count & 255)] + bytes
    }

    private func packet(_ bytes: [UInt8]) throws -> FFmpegPacket {
        var raw = av_packet_alloc()
        let pointer = try #require(raw)
        defer { av_packet_free(&raw) }
        try checkFFmpeg(av_new_packet(pointer, Int32(bytes.count)), operation: "Allocate subtitle acquisition test packet")
        bytes.withUnsafeBufferPointer { source in
            if let base = source.baseAddress, !source.isEmpty {
                pointer.pointee.data.update(from: base, count: source.count)
            }
        }
        pointer.pointee.pts = 2_000
        pointer.pointee.dts = 1_000
        pointer.pointee.duration = 500
        pointer.pointee.stream_index = 3
        return try FFmpegPacket(taking: &raw,
            timeBase: AVRational(num: 1, den: 1_000), generation: 7)
    }
}
