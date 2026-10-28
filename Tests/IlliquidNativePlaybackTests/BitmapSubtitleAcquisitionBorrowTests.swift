import CFFmpeg
import Foundation
import Testing
@testable import IlliquidNativePlayback

@Suite("Bitmap subtitle acquisition packet borrowing")
struct BitmapSubtitleAcquisitionBorrowTests {
    @Test func pgsAcquisitionAndEpochBitsKeepTheirExistingMeaning() throws {
        for (state, expected): (UInt8, Bool) in [(0, false), (0x40, true), (0x80, true), (0xC0, true)] {
            for lowerBits: UInt8 in [0, 0x3F] {
                try expectPGS(pgsAcquisition(state: state | lowerBits), expected)
            }
        }
        try expectPGS(pgsSegment(0x80, []), false)
        try expectPGS(pgsSegment(0x15, Array(pgsAcquisition().dropFirst(3))), false)
        try expectPGS(pgsSegment(0x16, Array(repeating: 0xFF, count: 10)), false)
    }

    @Test func dvbRequiresTheSelectedPageAndAcquisitionOrModeChangeState() throws {
        for pageID: UInt16 in [0, 1, UInt16.max] {
            for state: UInt8 in [0, 1, 2, 3] {
                // Version and reserved bits must not affect the two state bits.
                for otherBits: UInt8 in [0, 0xF3] {
                    let bytes = dvbSegment(0x10, [2, (state << 2) | otherBits], pageID: pageID)
                    let expected = state == 1 || state == 2
                    try expectDVB(bytes, pageID: pageID, expected)
                    try expectDVB(bytes, pageID: nil, expected)
                    try expectDVB(bytes, pageID: pageID &+ 1, false)
                }
            }
        }
        try expectDVB(dvbSegment(0x11, [2, 4]), pageID: nil, false)
        try expectDVB(dvbSegment(0x10, [4]), pageID: nil, false)
    }

    @Test func everyTruncatedAcquisitionSegmentIsRejected() throws {
        let pgs = pgsAcquisition()
        for count in 0..<pgs.count {
            try expectPGS(Array(pgs.prefix(count)), false)
        }
        let dvb = dvbSegment(0x10, [2, 4])
        for count in 0..<dvb.count {
            try expectDVB(Array(dvb.prefix(count)), pageID: nil, false)
        }
        try expectPGS([0x16, 0xFF, 0xFF] + Array(pgs.dropFirst(3)), false)
        try expectDVB([0x0F, 0x10, 0, 1, 0xFF, 0xFF, 2, 4], pageID: 1, false)
        try expectDVB([0x20] + dvb, pageID: 1, false)
    }

    @Test func largeObjectSegmentsSkipEmbeddedAcquisitionHeaders() throws {
        let pgs = pgsAcquisition()
        let pgsObject = pgsSegment(0x15, pgs + Array(repeating: 0x16, count: 65_535 - pgs.count))
        let pgsObjects = pgsObject + pgsObject + pgsObject
        try expectPGS(pgsObjects, false)
        try expectPGS(pgsObjects + pgs, true)
        try expectPGS(pgs + pgsObjects, true)

        let dvb = dvbSegment(0x10, [2, 8])
        let dvbObject = dvbSegment(0x13, dvb + Array(repeating: 0x0F, count: 65_535 - dvb.count))
        let dvbObjects = dvbObject + dvbObject + dvbObject
        try expectDVB(dvbObjects, pageID: nil, false)
        try expectDVB(dvbObjects + dvb, pageID: 1, true)
        try expectDVB(dvb + dvbObjects, pageID: 1, true)
        try expectDVB(dvbObjects + dvb, pageID: 2, false)
    }

    @Test func firstAcquisitionWinsBeforeMalformedTrailingBytes() throws {
        let pgs = pgsAcquisition()
        for tail in [[UInt8(0x15)], [0x15, 0], [0x15, 0xFF, 0xFF]] {
            try expectPGS(pgs + tail, true)
            try expectPGS(pgsAcquisition(state: 0) + tail, false)
        }
        try expectPGS([0x15, 0xFF, 0xFF] + pgs, false)

        let dvb = dvbSegment(0x10, [2, 4])
        for tail in [[UInt8(0xFF)], [0x0F, 0x10], [0x0F, 0x10, 0, 1, 0xFF, 0xFF]] {
            try expectDVB(dvb + tail, pageID: 1, true)
            try expectDVB(dvb + tail, pageID: 2, false)
        }
        try expectDVB([0x0F, 0x13, 0, 1, 0xFF, 0xFF] + dvb, pageID: 1, false)
        try expectDVB(dvbSegment(0x10, [2, 4], pageID: 2) + dvb, pageID: 1, true)
    }

    @Test func missingEmptyAndNonpositivePayloadsAreRejected() throws {
        for size: Int32 in [0, 17, -1, Int32.min] {
            var allocation = av_packet_alloc()
            let raw = try #require(allocation)
            defer { av_packet_free(&allocation) }
            #expect(raw.pointee.data == nil)
            raw.pointee.size = size
            let owner = try FFmpegPacket(taking: &allocation,
                timeBase: AVRational(num: 1, den: 1_000), generation: 0)
            #expect(owner.data == nil)
            #expect(!PGSSubtitlePacket.isAcquisition(owner))
            #expect(!DVBSubtitlePacket.isAcquisition(owner, compositionPageID: nil))
        }
        for bytes in [pgsAcquisition(), dvbSegment(0x10, [2, 4])] {
            for size: Int32 in [0, -1, Int32.min] {
                let owner = try packet(bytes)
                let raw = try #require(owner.pointer)
                let originalSize = raw.pointee.size
                defer { raw.pointee.size = originalSize }
                raw.pointee.size = size
                #expect(owner.data == nil)
                #expect(!PGSSubtitlePacket.isAcquisition(owner))
                #expect(!DVBSubtitlePacket.isAcquisition(owner, compositionPageID: 1))
            }
        }
    }

    @Test func packetAndSlicedDataInputsAgreeAcrossASeededCorpus() throws {
        var random: UInt64 = 0xC01D_5EED_7A11_2026
        func nextByte() -> UInt8 {
            random = random &* 6_364_136_223_846_793_005 &+ 1
            return UInt8(truncatingIfNeeded: random >> 24)
        }
        var corpus: [[UInt8]] = []
        for _ in 0..<192 {
            let count = Int(nextByte())
            corpus.append((0..<count).map { _ in nextByte() })
        }
        for original in [pgsAcquisition(), dvbSegment(0x10, [2, 4])] {
            for index in original.indices {
                var mutation = original
                mutation[index] ^= nextByte() | 1
                corpus.append(mutation)
            }
        }
        for bytes in corpus {
            let owner = try packet(bytes)
            let data = Data(bytes)
            let slice = Data([9, 8, 7] + bytes).dropFirst(3)
            #expect(PGSSubtitlePacket.isAcquisition(owner) == PGSSubtitlePacket.isAcquisition(data))
            #expect(PGSSubtitlePacket.isAcquisition(slice) == PGSSubtitlePacket.isAcquisition(data))
            for pageID: UInt16? in [nil, 0, 1, UInt16.max] {
                #expect(DVBSubtitlePacket.isAcquisition(owner, compositionPageID: pageID)
                    == DVBSubtitlePacket.isAcquisition(data, compositionPageID: pageID))
                #expect(DVBSubtitlePacket.isAcquisition(slice, compositionPageID: pageID)
                    == DVBSubtitlePacket.isAcquisition(data, compositionPageID: pageID))
            }
        }
    }

    @Test func classificationDoesNotMutateOrRetainItsPacket() throws {
        for (bytes, expected) in [(pgsAcquisition(), [true, false, false]),
                                  (dvbSegment(0x10, [2, 4]), [false, true, true])] {
            var owner: FFmpegPacket? = try packet(bytes)
            weak var released = owner
            let result = try classifyWithoutMutation(try #require(owner))
            owner = nil
            #expect(released == nil)
            #expect(result == expected)
        }
    }

    private func classifyWithoutMutation(_ owner: FFmpegPacket) throws -> [Bool] {
        let raw = try #require(owner.pointer)
        let originalPointer = try #require(raw.pointee.data)
        let originalSize = raw.pointee.size
        let originalBytes = Data(bytes: originalPointer, count: Int(originalSize))
        let originalPTS = raw.pointee.pts
        let originalDTS = raw.pointee.dts
        let originalFlags = raw.pointee.flags
        let result = [PGSSubtitlePacket.isAcquisition(owner),
                      DVBSubtitlePacket.isAcquisition(owner, compositionPageID: 1),
                      DVBSubtitlePacket.isAcquisition(owner, compositionPageID: nil)]
        #expect(owner.pointer == raw)
        #expect(raw.pointee.data == originalPointer)
        #expect(raw.pointee.size == originalSize)
        #expect(Data(bytes: originalPointer, count: Int(originalSize)) == originalBytes)
        #expect(raw.pointee.pts == originalPTS)
        #expect(raw.pointee.dts == originalDTS)
        #expect(raw.pointee.flags == originalFlags)
        // Results are values, independent of the packet's subsequent contents.
        originalPointer.update(repeating: 0, count: Int(originalSize))
        #expect(!PGSSubtitlePacket.isAcquisition(owner))
        #expect(!DVBSubtitlePacket.isAcquisition(owner, compositionPageID: nil))
        return result
    }

    private func expectPGS(_ bytes: [UInt8], _ expected: Bool) throws {
        #expect(PGSSubtitlePacket.isAcquisition(Data(bytes)) == expected)
        let owner = try packet(bytes)
        #expect(PGSSubtitlePacket.isAcquisition(owner) == expected)
    }

    private func expectDVB(_ bytes: [UInt8], pageID: UInt16?, _ expected: Bool) throws {
        #expect(DVBSubtitlePacket.isAcquisition(Data(bytes), compositionPageID: pageID) == expected)
        let owner = try packet(bytes)
        #expect(DVBSubtitlePacket.isAcquisition(owner, compositionPageID: pageID) == expected)
    }

    private func pgsAcquisition(state: UInt8 = 0x80) -> [UInt8] {
        pgsSegment(0x16, [5, 0, 2, 208, 0x10, 0, 1, state, 0, 0, 0])
    }

    private func pgsSegment(_ kind: UInt8, _ payload: [UInt8]) -> [UInt8] {
        precondition(payload.count <= 65_535)
        return [kind, UInt8(payload.count >> 8), UInt8(payload.count & 255)] + payload
    }

    private func dvbSegment(_ kind: UInt8, _ payload: [UInt8], pageID: UInt16 = 1) -> [UInt8] {
        precondition(payload.count <= 65_535)
        return [0x0F, kind, UInt8(pageID >> 8), UInt8(pageID & 255),
                UInt8(payload.count >> 8), UInt8(payload.count & 255)] + payload
    }

    private func packet(_ bytes: [UInt8]) throws -> FFmpegPacket {
        var allocation = av_packet_alloc()
        let raw = try #require(allocation)
        defer { av_packet_free(&allocation) }
        try checkFFmpeg(av_new_packet(raw, Int32(bytes.count)), operation: "Allocate acquisition test packet")
        bytes.withUnsafeBufferPointer { source in
            if let base = source.baseAddress, !source.isEmpty {
                raw.pointee.data.update(from: base, count: source.count)
            }
        }
        raw.pointee.pts = 123
        raw.pointee.dts = 100
        raw.pointee.flags = AV_PKT_FLAG_KEY
        return try FFmpegPacket(taking: &allocation,
            timeBase: AVRational(num: 1, den: 1_000), generation: 7)
    }
}
