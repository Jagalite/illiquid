import CFFmpeg
import Foundation
import Testing
@testable import IlliquidNativePlayback

@Suite("PGS packet metadata borrowing")
struct PGSSubtitlePacketBorrowTests {
    @Test func packetParsingMatchesDataAcrossSegmentAndCompositionChanges() throws {
        let first = composition([reference(x: 10, y: 20, crop: [1, 2, 3, 4])])
        let second = composition([
            reference(x: 30, y: 40),
            reference(x: 50, y: 60, crop: [0, 1, 2, 3]),
        ])
        // Bitmap payload bytes must be skipped by length, even when they look
        // like presentation segment headers. Exercise the full 16-bit length.
        let object = segment(0x15, Array(repeating: 0x16, count: 65_535))
        let fixtures: [[UInt8]] = [
            [], segment(0x80, []), first, second,
            object, object + first, first + object,
            first + object + second + segment(0x80, []),
            first + composition([]),
        ]
        for bytes in fixtures {
            let owner = try packet(bytes)
            #expect(snapshot(try PGSSubtitlePresentation.update(in: owner))
                == snapshot(try PGSSubtitlePresentation.update(in: Data(bytes))))
        }
        #expect(snapshot(try PGSSubtitlePresentation.update(in: packet(first + object + second)))
            == [[30, 40], [50, 60, 0, 1, 2, 3]])
        #expect(snapshot(try PGSSubtitlePresentation.update(in: packet(first + composition([])))) == [])
    }

    @Test func everyTruncatedCompositionHasTheSameErrorAsTheDataParser() throws {
        let bytes = composition([
            reference(x: 10, y: 20),
            reference(x: 30, y: 40, crop: [1, 2, 3, 4]),
        ])
        for count in 1..<bytes.count {
            let truncated = Array(bytes.prefix(count))
            try expectInvalid(truncated)
        }
        // A complete earlier composition must not mask a malformed tail.
        try expectInvalid(bytes + [0x80])
        try expectInvalid(bytes + [0x80, 0])
        try expectInvalid(bytes + [0x15, 0, 1])
    }

    @Test func invalidGeometryAndObjectCountsKeepTheirExistingRejections() throws {
        let ordinary = reference(x: 10, y: 20)
        let cropped = reference(x: 10, y: 20, crop: [1, 2, 3, 4])
        let fixtures: [[UInt8]] = [
            composition([ordinary], width: 0),
            composition([ordinary], height: 0),
            composition([ordinary], width: 8_193),
            composition([ordinary], height: 8_193),
            composition([ordinary, ordinary, ordinary]),
            composition([reference(x: 1_281, y: 20)]),
            composition([reference(x: 10, y: 721)]),
            segment(0x16, Array(repeating: 0, count: 10)),
            composition([Array(cropped.dropLast())]),
            composition([Array(ordinary.dropLast())]),
        ]
        for bytes in fixtures { try expectInvalid(bytes) }
        // Origins exactly on the canvas edge and zero-sized crop fields are
        // valid metadata; rectangle validation occurs later against the object.
        let boundary = composition([reference(x: 8_192, y: 8_192, crop: [0, 0, 0, 0])],
                                   width: 8_192, height: 8_192)
        #expect(snapshot(try PGSSubtitlePresentation.update(in: packet(boundary)))
            == [[8_192, 8_192, 0, 0, 0, 0]])
    }

    @Test func returnedMetadataSurvivesPacketMutationAndRelease() throws {
        var owner: FFmpegPacket? = try packet(composition([
            reference(x: 10, y: 20, crop: [1, 2, 3, 4]),
            reference(x: 30, y: 40),
        ]))
        weak var released = owner
        let metadata = try parseThenOverwrite(try #require(owner))
        owner = nil
        #expect(released == nil)
        #expect(snapshot(metadata) == [[10, 20, 1, 2, 3, 4], [30, 40]])
    }

    @Test func missingEmptyAndNegativePayloadsAreIgnoredLikePacketData() throws {
        var raw = av_packet_alloc()
        let pointer = try #require(raw)
        defer { av_packet_free(&raw) }
        // A missing buffer is ignored regardless of its advertised size.
        pointer.pointee.size = 12
        let missing = try FFmpegPacket(taking: &raw,
            timeBase: AVRational(num: 1, den: 1_000), generation: 0)
        #expect(missing.data == nil)
        #expect(try PGSSubtitlePresentation.update(in: missing) == nil)

        for count: Int32 in [0, -1] {
            let owner = try packet([0x80, 0, 0])
            let pointer = try #require(owner.pointer)
            pointer.pointee.size = count
            #expect(owner.data == nil)
            #expect(try PGSSubtitlePresentation.update(in: owner) == nil)
        }
    }

    private func parseThenOverwrite(_ packet: FFmpegPacket) throws -> PGSSubtitlePresentation {
        let parsed = try PGSSubtitlePresentation.update(in: packet)
        let result = try #require(parsed)
        let pointer = try #require(packet.pointer)
        let bytes = try #require(pointer.pointee.data)
        bytes.update(repeating: 0, count: Int(pointer.pointee.size))
        return result
    }

    private func expectInvalid(_ bytes: [UInt8]) throws {
        let owner = try packet(bytes)
        for usePacket in [false, true] {
            do {
                _ = try usePacket
                    ? PGSSubtitlePresentation.update(in: owner)
                    : PGSSubtitlePresentation.update(in: Data(bytes))
                Issue.record("Invalid PGS metadata was accepted; packet=\(usePacket)")
            } catch let error as FFmpegError {
                #expect(error.operation == "Read PGS composition geometry")
                #expect(error.code == illiquid_averror_invaliddata())
            }
        }
    }

    private func snapshot(_ value: PGSSubtitlePresentation?) -> [[Int32]]? {
        value?.objects.map { object in
            [object.x, object.y] + (object.crop.map { [$0.x, $0.y, $0.width, $0.height] } ?? [])
        }
    }

    private func word(_ value: UInt16) -> [UInt8] {
        [UInt8(value >> 8), UInt8(value & 255)]
    }

    private func reference(x: UInt16, y: UInt16, crop: [UInt16]? = nil) -> [UInt8] {
        [0, 1, 0, crop == nil ? 0 : 0x80] + word(x) + word(y) + (crop?.flatMap(word) ?? [])
    }

    private func composition(_ references: [[UInt8]], width: UInt16 = 1_280,
                             height: UInt16 = 720) -> [UInt8] {
        segment(0x16, word(width) + word(height) + [0x10, 0, 1, 0x80, 0, 0, UInt8(references.count)]
            + references.flatMap { $0 })
    }

    private func segment(_ kind: UInt8, _ bytes: [UInt8]) -> [UInt8] {
        [kind] + word(UInt16(bytes.count)) + bytes
    }

    private func packet(_ bytes: [UInt8]) throws -> FFmpegPacket {
        var raw = av_packet_alloc()
        let pointer = try #require(raw)
        defer { av_packet_free(&raw) }
        try checkFFmpeg(av_new_packet(pointer, Int32(bytes.count)), operation: "Allocate PGS metadata test packet")
        bytes.withUnsafeBufferPointer { source in
            if let base = source.baseAddress, !source.isEmpty {
                pointer.pointee.data.update(from: base, count: source.count)
            }
        }
        return try FFmpegPacket(taking: &raw,
            timeBase: AVRational(num: 1, den: 1_000), generation: 0)
    }
}
