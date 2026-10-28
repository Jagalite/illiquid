import CFFmpeg
import Foundation
import Testing
@testable import IlliquidNativePlayback

@Suite("Bitmap subtitle acquisition borrowing")
struct BitmapSubtitleAcquisitionBorrowTests {
    @Test func stateBitsAndCompositionPagesPreserveExistingAcceptance() throws {
        for value in UInt16(0)...255 {
            let flags = UInt8(value)
            try expect(pgsComposition(state: flags), isPGS: true,
                       pageID: 65_535, expected: flags & 0xC0 != 0)
            let state = (flags >> 2) & 3
            let accepted = state == 1 || state == 2
            let dvb = dvbSegment(0x10, [2, flags], pageID: 0x1234)
            try expect(dvb, isPGS: false, pageID: 0x1234, expected: accepted)
            try expect(dvb, isPGS: false, expected: accepted)
            try expect(dvb, isPGS: false, pageID: 0x1235, expected: false)
        }
        for page: UInt16 in [0, 1, 255, 256, 65_535] {
            try expect(dvbSegment(0x10, [2, 4], pageID: page),
                       isPGS: false, pageID: page, expected: true)
        }
    }

    @Test func everyTruncatedAcquisitionAndUndersizedCompositionRemainsRejected() throws {
        for isPGS in [true, false] {
            let bytes = isPGS ? pgsComposition(state: 0x80) : dvbSegment(0x10, [2, 4])
            for count in 0..<bytes.count {
                try expect(Array(bytes.prefix(count)), isPGS: isPGS, pageID: 1, expected: false)
            }
            try expect(bytes, isPGS: isPGS, pageID: 1, expected: true)
        }
        for length in 0..<11 {
            var payload = [UInt8](repeating: 0, count: length)
            if length > 7 { payload[7] = 0xC0 }
            try expect(pgsSegment(0x16, payload), isPGS: true, expected: false)
        }
        for payload: [UInt8] in [[], [4]] {
            try expect(dvbSegment(0x10, payload), isPGS: false, pageID: 1, expected: false)
        }
        try expect([0x80, 0, 0, 0x16], isPGS: true, expected: false)
        try expect([0x80, 0, 0, 0x16, 0], isPGS: true, expected: false)
        try expect(dvbSegment(0x80, []) + [0x0F, 0x10, 0, 1, 0],
                   isPGS: false, expected: false)
    }

    @Test func largeObjectsAreSkippedAndMalformedTailsDoNotUndoAnEarlierMatch() throws {
        for isPGS in [true, false] {
            let acquisition = isPGS ? pgsComposition(state: 0x80) : dvbSegment(0x10, [2, 4])
            // A header inside a maximum-length object is payload, not a segment.
            let payload = acquisition
                + [UInt8](repeating: 0xFF, count: 65_535 - acquisition.count)
            let object = isPGS ? pgsSegment(0x15, payload) : dvbSegment(0x13, payload)
            try expect(object, isPGS: isPGS, pageID: 1, expected: false)
            try expect(object + acquisition, isPGS: isPGS, pageID: 1, expected: true)
            try expect(acquisition + object, isPGS: isPGS, pageID: 1, expected: true)
            try expect(object + object + object + object,
                       isPGS: isPGS, pageID: 1, expected: false)
            let malformed: [UInt8] = isPGS
                ? [0x15, 0xFF, 0xFF]
                : [0x0F, 0x13, 0, 1, 0xFF, 0xFF]
            try expect(malformed + acquisition, isPGS: isPGS, pageID: 1, expected: false)
            // Acquisition detection intentionally returns at the first match.
            try expect(acquisition + malformed, isPGS: isPGS, pageID: 1, expected: true)
            try expect(acquisition + [0x0F], isPGS: isPGS, pageID: 1, expected: true)
        }
    }

    @Test func codecSelectionSegmentKindsAndAncillaryPagesDoNotCreateFalseAcquisitions() throws {
        let pgs = pgsComposition(state: 0x80)
        let dvb = dvbSegment(0x10, [2, 4])
        try expect(pgs, isPGS: false, expected: false)
        try expect(dvb, isPGS: true, expected: false)
        for kind: UInt8 in [0x14, 0x15, 0x80] {
            try expect(pgsSegment(kind, [5, 0, 2, 208, 16, 0, 1, 0x80, 0, 0, 0]),
                       isPGS: true, expected: false)
        }
        for kind: UInt8 in [0x11, 0x12, 0x13, 0x80] {
            try expect(dvbSegment(kind, [2, 4]), isPGS: false, pageID: 1, expected: false)
        }
        let ancillary = dvbSegment(0x10, [2, 4], pageID: 2)
        let ordinary = dvbSegment(0x10, [2, 0], pageID: 1)
        try expect(ancillary + ordinary, isPGS: false, pageID: 1, expected: false)
        try expect(ancillary + dvb, isPGS: false, pageID: 1, expected: true)
        try expect(ancillary + ordinary, isPGS: false, expected: true)
        try expect([0x01, 0x10, 0, 1, 0, 2, 2, 4] + dvb, isPGS: false, expected: false)
    }

    @Test func missingEmptyAndNegativePayloadsMatchTheExistingPacketDataGuard() throws {
        var raw = av_packet_alloc()
        let pointer = try #require(raw)
        defer { av_packet_free(&raw) }
        pointer.pointee.size = 12
        let missing = try FFmpegPacket(
            taking: &raw, timeBase: AVRational(num: 1, den: 1_000), generation: 0
        )
        #expect(missing.data == nil)
        for isPGS in [true, false] {
            #expect(!missing.isSubtitleAcquisition(isPGS: isPGS, compositionPageID: nil))
        }
        for count: Int32 in [0, -1] {
            for isPGS in [true, false] {
                let bytes = isPGS ? pgsComposition(state: 0x80) : dvbSegment(0x10, [2, 4])
                let owner = try packet(bytes)
                let pointer = try #require(owner.pointer)
                pointer.pointee.size = count
                #expect(owner.data == nil)
                #expect(!owner.isSubtitleAcquisition(isPGS: isPGS, compositionPageID: 1))
            }
        }
    }

    @Test func resultSurvivesMutationAndDoesNotRetainItsPacket() throws {
        for isPGS in [true, false] {
            let acquisition = isPGS ? pgsComposition(state: 0x80) : dvbSegment(0x10, [2, 4])
            // Exercise both tiny Data storage and a large borrowed payload.
            for padded in [false, true] {
                let tail = padded
                    ? (isPGS
                        ? pgsSegment(0x15, [UInt8](repeating: 0, count: 4_096))
                        : dvbSegment(0x13, [UInt8](repeating: 0, count: 4_096)))
                    : []
                var owner: FFmpegPacket? = try packet(acquisition + tail)
                weak var released = owner
                let decisions = try parseThenOverwrite(try #require(owner), isPGS: isPGS)
                owner = nil
                #expect(released == nil)
                #expect(decisions.before)
                #expect(!decisions.after)
            }
        }
    }

    private func expect(
        _ bytes: [UInt8], isPGS: Bool, pageID: UInt16? = nil, expected: Bool
    ) throws {
        let data = Data(bytes)
        let reference = isPGS
            ? PGSSubtitlePacket.isAcquisition(data)
            : DVBSubtitlePacket.isAcquisition(data, compositionPageID: pageID)
        let owner = try packet(bytes)
        let pointer = try #require(owner.pointer)
        let originalData = pointer.pointee.data
        let originalSize = pointer.pointee.size
        let actual = owner.isSubtitleAcquisition(isPGS: isPGS, compositionPageID: pageID)
        #expect(reference == expected)
        #expect(actual == expected)
        #expect(owner.pointer == pointer)
        #expect(pointer.pointee.data == originalData)
        #expect(pointer.pointee.size == originalSize)
        if !bytes.isEmpty { #expect(owner.data == data) }
    }

    private func parseThenOverwrite(
        _ packet: FFmpegPacket, isPGS: Bool
    ) throws -> (before: Bool, after: Bool) {
        let before = packet.isSubtitleAcquisition(isPGS: isPGS, compositionPageID: 1)
        let pointer = try #require(packet.pointer)
        let bytes = try #require(pointer.pointee.data)
        bytes.update(repeating: 0, count: Int(pointer.pointee.size))
        let after = packet.isSubtitleAcquisition(isPGS: isPGS, compositionPageID: 1)
        return (before, after)
    }

    private func word(_ value: UInt16) -> [UInt8] {
        [UInt8(value >> 8), UInt8(value & 255)]
    }

    private func pgsSegment(_ kind: UInt8, _ payload: [UInt8]) -> [UInt8] {
        [kind] + word(UInt16(payload.count)) + payload
    }

    private func pgsComposition(state: UInt8) -> [UInt8] {
        pgsSegment(0x16, [5, 0, 2, 208, 16, 0, 1, state, 0, 0, 0])
    }

    private func dvbSegment(
        _ kind: UInt8, _ payload: [UInt8], pageID: UInt16 = 1
    ) -> [UInt8] {
        [0x0F, kind] + word(pageID) + word(UInt16(payload.count)) + payload
    }

    private func packet(_ bytes: [UInt8]) throws -> FFmpegPacket {
        var raw = av_packet_alloc()
        let pointer = try #require(raw)
        defer { av_packet_free(&raw) }
        try checkFFmpeg(av_new_packet(pointer, Int32(bytes.count)),
                       operation: "Allocate bitmap acquisition test packet")
        bytes.withUnsafeBufferPointer { source in
            if let base = source.baseAddress, !source.isEmpty {
                pointer.pointee.data.update(from: base, count: source.count)
            }
        }
        return try FFmpegPacket(
            taking: &raw, timeBase: AVRational(num: 1, den: 1_000), generation: 0
        )
    }
}
