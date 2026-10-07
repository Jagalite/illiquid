import CFFmpeg
import CoreGraphics
import Foundation
import Testing
@testable import IlliquidNativePlayback

@Suite("PGS composition cropping")
struct PGSSubtitleCropTests {
    @Test func cropsPixelsWithoutMovingTheCompositionAndRestoresFullObjects() throws {
        let budget = SubtitleMemoryBudget(limitBytes: 1_024)
        let decoder = try makeDecoder(budget: budget)
        // The authored 3x2 object is [white, clear, white] / [clear, white, clear].
        // Cropping columns 1..2 must yield [clear, white] / [white, clear].
        let first = try decoder.decode(packet(presentation(crop: [1, 0, 2, 2]) + palette + object + end, at: 2))
        let bitmap = try #require(first.first?.bitmapComposition)
        let region = try #require(bitmap.regions.first)
        #expect(region.frame == CGRect(x: 10, y: 20, width: 2, height: 2))
        #expect(region.isForced)
        #expect(region.pixels == pixels([0, 255, 255, 0]))
        #expect(bitmap.byteCount == 16)
        #expect(budget.snapshot.reservedBytes == 16)

        // A palette-only display update retains the current crop metadata.
        let updated = try decoder.decode(packet(palette + end, at: 3))
        #expect(updated.first?.bitmapComposition?.regions.first?.pixels == region.pixels)
        let full = try decoder.decode(packet(presentation(crop: nil, epoch: false) + end, at: 4))
        #expect(full.first?.bitmapComposition?.regions.first?.frame == CGRect(x: 10, y: 20, width: 3, height: 2))
        #expect(full.first?.bitmapComposition?.regions.first?.pixels == pixels([255, 0, 255, 0, 255, 0]))
    }

    @Test func separatePresentationPacketsAndResetKeepTheRightCrop() throws {
        let decoder = try makeDecoder()
        #expect(try decoder.decode(packet(presentation(crop: [1, 1, 1, 1]), at: 2)).isEmpty)
        let first = try decoder.decode(packet(palette + object + end, at: 2))
        #expect(first.first?.bitmapComposition?.regions.first?.pixels == pixels([255]))
        try decoder.flush()
        let full = try decoder.decode(packet(presentation(crop: nil) + palette + object + end, at: 1))
        #expect(full.first?.bitmapComposition?.regions.first?.frame.size == CGSize(width: 3, height: 2))
        let empty = try decoder.decode(packet(presentation(crop: [3, 2, 0, 0], epoch: false) + end, at: 3))
        #expect(empty.first?.bitmapComposition?.regions.isEmpty == true)
    }

    @Test func rejectsOutOfBoundsAndTruncatedCropsBeforeCopyingPixels() throws {
        let invalidCrops: [[UInt16]] = [[3, 0, 1, 1], [0, 2, 1, 1], [0, 0, 4, 2]]
        for crop in invalidCrops {
            let decoder = try makeDecoder()
            #expect(throws: FFmpegError.self) {
                try decoder.decode(packet(presentation(crop: crop) + palette + object + end, at: 2))
            }
        }
        let bytes = presentation(crop: [1, 0, 2, 2])
        for count in 1..<bytes.count {
            #expect(throws: FFmpegError.self) {
                try PGSSubtitlePresentation.update(in: Data(bytes.prefix(count)))
            }
        }
        let shortCrop = segment(0x16, Array(bytes.dropFirst(3).dropLast()))
        #expect(throws: FFmpegError.self) { try PGSSubtitlePresentation.update(in: Data(shortCrop)) }
    }

    @Test func twoReferencesToOneObjectKeepIndependentCropsPositionsAndFlags() throws {
        let decoder = try makeDecoder()
        var composition = Array(presentation(crop: [1, 0, 1, 1]).dropFirst(3))
        composition[10] = 2
        composition += [0, 1, 0, 0x80, 0, 40, 0, 50, 0, 0, 0, 0, 0, 1, 0, 1]
        let result = try decoder.decode(packet(segment(0x16, composition) + palette + object + end, at: 2))
        let regions = try #require(result.first?.bitmapComposition?.regions)
        #expect(regions.count == 2)
        guard regions.count == 2 else { return }
        #expect(regions[0].frame == CGRect(x: 10, y: 20, width: 1, height: 1))
        #expect(regions[0].pixels == pixels([0]))
        #expect(regions[0].isForced)
        #expect(regions[1].frame == CGRect(x: 40, y: 50, width: 1, height: 1))
        #expect(regions[1].pixels == pixels([255]))
        #expect(!regions[1].isForced)
    }

    private func makeDecoder(budget: SubtitleMemoryBudget? = nil) throws -> SubtitleDecoder {
        var parameters = avcodec_parameters_alloc()
        let pointer = try #require(parameters)
        defer { avcodec_parameters_free(&parameters) }
        pointer.pointee.codec_type = AVMEDIA_TYPE_SUBTITLE
        pointer.pointee.codec_id = AV_CODEC_ID_HDMV_PGS_SUBTITLE
        let stream = FFmpegStreamInfo(index: 0, kind: .subtitle, codecID: Int32(AV_CODEC_ID_HDMV_PGS_SUBTITLE.rawValue),
            codecName: "hdmv_pgs_subtitle", title: nil, language: nil, timeBase: .init(numerator: 1, denominator: 1_000_000),
            duration: nil, disposition: 0, codedSize: nil, pixelAspectRatio: nil, averageFrameRate: nil,
            sampleRate: nil, channelCount: nil, channelLayout: nil, rotationDegrees: 0, isMirrored: false, interlaceMode: .progressive)
        return try SubtitleDecoder(parameters: pointer, stream: stream, memoryBudget: budget)
    }

    private func presentation(crop: [UInt16]?, epoch: Bool = true) -> [UInt8] {
        var bytes: [UInt8] = [5, 0, 2, 208, 16, 0, 1, epoch ? 128 : 0, 0, 0, 1,
                              0, 1, 0, crop == nil ? 0x40 : 0xC0, 0, 10, 0, 20]
        if let crop { for value in crop { bytes += [UInt8(value >> 8), UInt8(value & 255)] } }
        return segment(0x16, bytes)
    }

    private var palette: [UInt8] { segment(0x14, [0, 0, 0, 16, 128, 128, 0, 1, 235, 128, 128, 255]) }
    private var object: [UInt8] {
        segment(0x15, [0, 1, 0, 192, 0, 0, 17, 0, 3, 0, 2, 1, 0, 1, 1, 0, 0, 0, 1, 1, 0, 1, 0, 0])
    }
    private var end: [UInt8] { segment(0x80, []) }
    private func pixels(_ alpha: [UInt8]) -> Data { Data(alpha.flatMap { [$0, $0, $0, $0] }) }
    private func segment(_ kind: UInt8, _ bytes: [UInt8]) -> [UInt8] {
        [kind, UInt8(bytes.count >> 8), UInt8(bytes.count & 255)] + bytes
    }
    private func packet(_ bytes: [UInt8], at seconds: Int64) throws -> FFmpegPacket {
        var raw = av_packet_alloc()
        let pointer = try #require(raw)
        defer { av_packet_free(&raw) }
        try checkFFmpeg(av_new_packet(pointer, Int32(bytes.count)), operation: "Allocate authored PGS packet")
        bytes.withUnsafeBufferPointer { source in pointer.pointee.data.update(from: source.baseAddress!, count: source.count) }
        pointer.pointee.pts = seconds * 1_000_000
        pointer.pointee.dts = pointer.pointee.pts
        return try FFmpegPacket(moving: pointer, timeBase: .init(num: 1, den: 1_000_000), generation: 0)
    }
}
