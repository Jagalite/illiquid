import CFFmpeg
import Foundation
import Testing
@testable import IlliquidNativePlayback

@Suite("PR137 bitmap subtitle acquisition regression corpus")
struct BitmapSubtitleAcquisitionPR137RegressionTests {
    @Test func pgsCompositionStateAndMinimumLengthKeepTheirExistingMeaning() throws {
        for state: UInt8 in [0, 0x40, 0x80, 0xC0] {
            for lowBits: UInt8 in [0, 1, 0x3F] {
                try expectPGS(pgsComposition(state: state | lowBits), expected: state != 0)
            }
        }
        // The state byte alone is insufficient: the existing parser requires
        // a complete segment with at least eleven composition payload bytes.
        for length in 0..<11 {
            var payload = Array(repeating: UInt8(0), count: length)
            if length > 7 { payload[7] = 0x80 }
            try expectPGS(pgsSegment(0x16, payload), expected: false)
        }
        try expectPGS(pgsSegment(0x80, []), expected: false)
        try expectPGS(pgsSegment(0x17, Array(pgsComposition(state: 0x80).dropFirst(3))), expected: false)
    }

    @Test func dvbAcquisitionRequiresTheSelectedCompositionPageAndValidState() throws {
        for page: UInt16 in [0, 1, UInt16.max] {
            for state: UInt8 in [0, 1, 2, 3] {
                for otherBits: UInt8 in [0, 0xF3] {
                    let payload: [UInt8] = [2, state << 2 | otherBits]
                    let bytes = dvbSegment(0x10, payload, pageID: page)
                    let expected = state == 1 || state == 2
                    try expectDVB(bytes, pageID: page, expected: expected)
                    try expectDVB(bytes, pageID: nil, expected: expected)
                    try expectDVB(bytes, pageID: page ^ 1, expected: false)
                }
            }
        }
        try expectDVB(dvbSegment(0x10, [], pageID: 1), pageID: 1, expected: false)
        try expectDVB(dvbSegment(0x10, [4], pageID: 1), pageID: 1, expected: false)
        try expectDVB(dvbSegment(0x11, [2, 4], pageID: 1), pageID: 1, expected: false)
        var badSync = dvbSegment(0x10, [2, 4], pageID: 1)
        badSync[0] = 0
        try expectDVB(badSync, pageID: 1, expected: false)
    }

    @Test func objectPayloadsAreSkippedByLengthIncludingMaximumSizedSegments() throws {
        // Payload bytes resemble headers but must never be parsed as segments.
        let pgsObject = pgsSegment(0x15, Array(repeating: 0x16, count: 65_535))
        let pgsAcquire = pgsComposition(state: 0x80)
        try expectPGS(pgsObject + pgsSegment(0x80, []), expected: false)
        try expectPGS(pgsObject + pgsAcquire, expected: true)
        try expectPGS(pgsComposition(state: 0) + pgsObject, expected: false)
        try expectPGS(pgsSegment(0x15, pgsAcquire), expected: false)

        let dvbObject = dvbSegment(0x13, Array(repeating: 0x0F, count: 65_535), pageID: 1)
        let dvbAcquire = dvbSegment(0x10, [2, 4], pageID: 1)
        try expectDVB(dvbObject + dvbSegment(0x80, [], pageID: 1), pageID: 1, expected: false)
        try expectDVB(dvbObject + dvbAcquire, pageID: 1, expected: true)
        try expectDVB(dvbSegment(0x13, dvbAcquire, pageID: 1), pageID: 1, expected: false)
        // An ancillary page cannot reset a selected page. Scanning must still
        // find a later matching acquisition after the intervening object data.
        let ancillary = dvbSegment(0x10, [2, 8], pageID: 2)
        try expectDVB(ancillary + dvbObject, pageID: 1, expected: false)
        try expectDVB(ancillary + dvbObject + dvbAcquire, pageID: 1, expected: true)
    }

    @Test func everyTruncationBeforeAnAcquisitionIsRejected() throws {
        let pgsFixtures = [
            pgsComposition(state: 0x80),
            pgsSegment(0x15, Array(repeating: 0x16, count: 19)) + pgsComposition(state: 0x40),
        ]
        for bytes in pgsFixtures {
            for count in 0..<bytes.count {
                try expectPGS(Array(bytes.prefix(count)), expected: false)
            }
            try expectPGS(bytes, expected: true)
        }
        let dvbFixtures = [
            dvbSegment(0x10, [2, 4], pageID: 1),
            dvbSegment(0x13, Array(repeating: 0x0F, count: 19), pageID: 1)
                + dvbSegment(0x10, [2, 8], pageID: 1),
        ]
        for bytes in dvbFixtures {
            for count in 0..<bytes.count {
                try expectDVB(Array(bytes.prefix(count)), pageID: 1, expected: false)
            }
            try expectDVB(bytes, pageID: 1, expected: true)
        }
    }

    @Test func earlyAcquisitionStillWinsOverMalformedTrailingBytes() throws {
        let pgsAcquire = pgsComposition(state: 0x80)
        for tail: [UInt8] in [[0x80], [0x80, 0], [0x15, 0, 1], [0x16, 0xFF, 0xFF, 0]] {
            try expectPGS(pgsAcquire + tail, expected: true)
            try expectPGS(pgsComposition(state: 0) + tail, expected: false)
        }
        let dvbAcquire = dvbSegment(0x10, [2, 4], pageID: 1)
        let dvbOrdinary = dvbSegment(0x10, [2, 0], pageID: 1)
        for tail: [UInt8] in [[0x0F], [0x0F, 0x10, 0, 1, 0],
                              [0x0F, 0x13, 0, 1, 0, 1], [0, 0, 0, 0, 0, 0]] {
            try expectDVB(dvbAcquire + tail, pageID: 1, expected: true)
            try expectDVB(dvbOrdinary + tail, pageID: 1, expected: false)
        }
    }

    @Test func slicesUseTheirVisibleBoundsRatherThanTheOriginalDataIndices() throws {
        let pgs = pgsComposition(state: 0x80)
        let dvb = dvbSegment(0x10, [2, 4], pageID: 1)
        for (bytes, isPGS) in [(pgs, true), (dvb, false)] {
            let storage = Data([0xFF, 0xFF] + bytes + [0xFF, 0xFF])
            let slice = storage[2..<(2 + bytes.count)]
            #expect(slice.startIndex == 2)
            if isPGS {
                #expect(PGSSubtitlePacket.isAcquisition(slice))
            } else {
                #expect(DVBSubtitlePacket.isAcquisition(slice, compositionPageID: 1))
            }
            // Excluding the final payload byte must not read the valid byte
            // still present immediately beyond the visible slice.
            let truncated = storage[2..<(1 + bytes.count)]
            #expect(isPGS ? !PGSSubtitlePacket.isAcquisition(truncated)
                : !DVBSubtitlePacket.isAcquisition(truncated, compositionPageID: 1))
        }
    }

    @Test func missingEmptyAndNegativePayloadsMatchTheFormerDataPath() throws {
        var raw = av_packet_alloc()
        let pointer = try #require(raw)
        defer { av_packet_free(&raw) }
        pointer.pointee.size = 12
        let missing = try FFmpegPacket(taking: &raw,
            timeBase: AVRational(num: 1, den: 1_000), generation: 0)
        #expect(missing.data == nil)
        #expect(!PGSSubtitlePacket.isAcquisition(missing))
        #expect(!DVBSubtitlePacket.isAcquisition(missing, compositionPageID: nil))

        for count: Int32 in [0, -1] {
            let owner = try packet(pgsComposition(state: 0x80))
            let pointer = try #require(owner.pointer)
            let originalSize = pointer.pointee.size
            defer { pointer.pointee.size = originalSize }
            pointer.pointee.size = count
            #expect(owner.data == nil)
            #expect(!PGSSubtitlePacket.isAcquisition(owner))
            #expect(!DVBSubtitlePacket.isAcquisition(owner, compositionPageID: nil))
        }
    }

    @Test func borrowedChecksPreservePacketBytesAndDoNotExtendOwnership() throws {
        for isPGS in [true, false] {
            let bytes = isPGS ? pgsComposition(state: 0x80) : dvbSegment(0x10, [2, 4], pageID: 1)
            var owner: FFmpegPacket? = try packet(bytes)
            let released = WeakPacketReference(owner)
            let detected = try inspectAndVerifyUnchanged(try #require(owner), bytes: bytes, isPGS: isPGS)
            owner = nil
            #expect(released.value == nil)
            #expect(detected)
        }
    }

    private final class WeakPacketReference {
        weak var value: FFmpegPacket?

        init(_ value: FFmpegPacket?) {
            self.value = value
        }
    }

    private func inspectAndVerifyUnchanged(_ packet: FFmpegPacket, bytes: [UInt8], isPGS: Bool) throws -> Bool {
        let pointer = try #require(packet.pointer)
        let payload = pointer.pointee.data
        let size = pointer.pointee.size
        let detected = (isPGS ? PGSSubtitlePacket.isAcquisition(packet)
            : DVBSubtitlePacket.isAcquisition(packet, compositionPageID: 1))
        #expect(packet.pointer == pointer)
        #expect(pointer.pointee.data == payload)
        #expect(pointer.pointee.size == size)
        #expect(packet.data == Data(bytes))
        return detected
    }

    private func expectPGS(_ bytes: [UInt8], expected: Bool) throws {
        let owner = try packet(bytes)
        #expect(PGSSubtitlePacket.isAcquisition(owner) == expected)
        #expect(PGSSubtitlePacket.isAcquisition(Data(bytes)) == expected)
    }

    private func expectDVB(_ bytes: [UInt8], pageID: UInt16?, expected: Bool) throws {
        let owner = try packet(bytes)
        #expect(DVBSubtitlePacket.isAcquisition(owner, compositionPageID: pageID) == expected)
        #expect(DVBSubtitlePacket.isAcquisition(Data(bytes), compositionPageID: pageID) == expected)
    }

    private func word(_ value: UInt16) -> [UInt8] {
        [UInt8(value >> 8), UInt8(value & 255)]
    }

    private func pgsSegment(_ kind: UInt8, _ bytes: [UInt8]) -> [UInt8] {
        [kind] + word(UInt16(bytes.count)) + bytes
    }

    private func pgsComposition(state: UInt8) -> [UInt8] {
        pgsSegment(0x16, [5, 0, 2, 208, 16, 0, 1, state, 0, 0, 0])
    }

    private func dvbSegment(_ kind: UInt8, _ bytes: [UInt8], pageID: UInt16) -> [UInt8] {
        [0x0F, kind] + word(pageID) + word(UInt16(bytes.count)) + bytes
    }

    private func packet(_ bytes: [UInt8]) throws -> FFmpegPacket {
        var raw = av_packet_alloc()
        let pointer = try #require(raw)
        defer { av_packet_free(&raw) }
        try checkFFmpeg(av_new_packet(pointer, Int32(bytes.count)), operation: "Allocate acquisition test packet")
        bytes.withUnsafeBufferPointer { source in
            if let base = source.baseAddress, !source.isEmpty {
                pointer.pointee.data.update(from: base, count: source.count)
            }
        }
        return try FFmpegPacket(taking: &raw,
            timeBase: AVRational(num: 1, den: 1_000), generation: 0)
    }
}
