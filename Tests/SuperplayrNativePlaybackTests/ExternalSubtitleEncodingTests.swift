import Foundation
import Testing
import SuperplayrCore
@testable import SuperplayrNativePlayback

@Suite("External subtitle Unicode decoding")
struct ExternalSubtitleEncodingTests {
    private let cue = "1\n00:00:01,000 --> 00:00:02,000\nCafé 日本語\n"

    @Test func unicodeSRTEncodingsProduceTheSameASS() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("srt")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(cue.utf8).write(to: url)
        let reference = try SubtitlePipeline.prepareExternalData(url: url)
        let cases: [([UInt8], String.Encoding)] = [
            ([0xEF, 0xBB, 0xBF], .utf8),
            ([0xFF, 0xFE], .utf16LittleEndian),
            ([0xFE, 0xFF], .utf16BigEndian),
            ([0xFF, 0xFE, 0, 0], .utf32LittleEndian),
            ([0, 0, 0xFE, 0xFF], .utf32BigEndian),
        ]
        for (mark, encoding) in cases {
            let body = try #require(cue.data(using: encoding))
            try (Data(mark) + body).write(to: url)
            #expect(try SubtitlePipeline.prepareExternalData(url: url) == reference)
        }
    }

    @Test func nonUTF8WebVTTAndMalformedUnicodeAreRejected() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let vtt = root.appendingPathComponent("test.vtt")
        try (Data([0xFF, 0xFE]) + Data("WEBVTT\n".utf16.flatMap {
            [UInt8(truncatingIfNeeded: $0), UInt8(truncatingIfNeeded: $0 >> 8)]
        })).write(to: vtt)
        #expect(throws: PresentationError.self) {
            _ = try SubtitlePipeline.prepareExternalData(url: vtt)
        }
        let srt = root.appendingPathComponent("test.srt")
        try Data([0xFF, 0xFE, 0x00]).write(to: srt)
        #expect(throws: PresentationError.self) {
            _ = try SubtitlePipeline.prepareExternalData(url: srt)
        }
    }

    @Test func selectedLegacyEncodingMatchesUnicodeWithoutGuessing() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("srt")
        defer { try? FileManager.default.removeItem(at: url) }
        let cases: [(SubtitleFallbackEncoding, [UInt8], String)] = [
            (.windows1252, [0x43, 0x61, 0x66, 0xE9], "Café"),
            (.windows1251, [0xCF, 0xF0, 0xE8, 0xE2, 0xE5, 0xF2], "Привет"),
            (.shiftJIS, [0x93, 0xFA, 0x96, 0x7B, 0x8C, 0xEA], "日本語"),
        ]
        for (encoding, bytes, text) in cases {
            let header = "1\n00:00:01,000 --> 00:00:02,000\n"
            try Data((header + text + "\n").utf8).write(to: url)
            let reference = try SubtitlePipeline.prepareExternalData(url: url)
            try (Data(header.utf8) + Data(bytes) + Data([10])).write(to: url)
            #expect(throws: PresentationError.self) {
                _ = try SubtitlePipeline.prepareExternalData(url: url)
            }
            #expect(try SubtitlePipeline.prepareExternalData(url: url, fallbackEncoding: encoding) == reference)
            #expect(throws: PresentationError.self) {
                _ = try SubtitlePipeline.prepareExternalData(url: url, maximumBytes: 8, fallbackEncoding: encoding)
            }
        }
    }
}
