import Foundation
import Testing
@testable import IlliquidNativePlayback

@Suite("Font attachment admission")
struct FontAttachmentAdmissionTests {
    @Test(arguments: [
        ("Title Font.ttf", nil),
        ("嵌入字体.OTF", nil),
        ("collection.TtC", "application/octet-stream"),
        ("nested/path/font.ttf", "image/jpeg"),
        ("font.bin", "application/x-truetype-font"),
        ("font.bin", "APPLICATION/VND.MS-OPENTYPE"),
        ("font.bin", "font/woff2"),
        ("", "application/x-font-opentype"),
        // Preserve the existing permissive substring check, even for a MIME
        // value that is not a standard font media type.
        ("unknown.bin", "application/not-a-font-format"),
    ] as [(String, String?)])
    func supportedMetadataIsAdmitted(filename: String, mimeType: String?) {
        #expect(FontAttachment.isSupportedFont(filename: filename, mimeType: mimeType))
        #expect(FontAttachment(filename: filename, mimeType: mimeType, data: Data()).isSupportedFont)
    }

    @Test(arguments: [
        ("report.pdf", "application/pdf"),
        ("metadata.xml", "application/xml"),
        ("cover.jpg", "image/jpeg"),
        ("cover.png", "application/octet-stream"),
        ("font.ttf.bin", nil),
        ("font.woff", nil),
        ("", nil),
        ("unknown", ""),
        ("attachment-4", "application/octet-stream"),
    ] as [(String, String?)])
    func unsupportedMetadataIsRejected(filename: String, mimeType: String?) {
        #expect(!FontAttachment.isSupportedFont(filename: filename, mimeType: mimeType))
        #expect(!FontAttachment(filename: filename, mimeType: mimeType, data: Data([1, 2, 3])).isSupportedFont)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ILLIQUID_ATTACHMENT_ADMISSION_FIXTURE"] != nil,
                   "Generate the mixed Matroska attachment fixture"))
    func demuxingPreservesStreamsAndCopiesOnlySupportedFontPayloads() throws {
        let path = try #require(ProcessInfo.processInfo.environment["ILLIQUID_ATTACHMENT_ADMISSION_FIXTURE"])
        #expect(FileManager.default.fileExists(atPath: path))
        let info = try {
            let demuxer = try FFmpegDemuxer(url: URL(fileURLWithPath: path))
            let readPacket = try demuxer.readPacket(generation: 1)
            let packet = try #require(readPacket)
            #expect(packet.streamIndex == demuxer.mediaInfo.selectedAudioIndex)
            return demuxer.mediaInfo
        }()

        #expect(info.audioStreams.count == 1)
        #expect(info.streams.filter { $0.kind == .attachment }.count == 3)
        #expect(info.attachments.map(\.filename) == ["embedded.TTF", "glyphs.bin"])
        #expect(info.attachments.map(\.mimeType) == ["application/x-truetype-font", "font/otf"])
        // The demuxer and its FFmpeg-owned payloads have been released. Accepted
        // attachments must still own unchanged bytes, in source order.
        #expect(info.attachments.map(\.data) == [
            Data([0x00, 0x01, 0x02, 0xFE, 0xFF]),
            Data([0x46, 0x4F, 0x4E, 0x54, 0x00, 0x80]),
        ])
    }
}
