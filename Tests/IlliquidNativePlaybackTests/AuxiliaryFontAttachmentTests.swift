import CFFmpeg
import Foundation
import Testing
@testable import IlliquidNativePlayback

@Suite("Auxiliary font attachment loading", .enabled(
    if: ProcessInfo.processInfo.environment["ILLIQUID_ATTACHMENT_ADMISSION_FIXTURE"] != nil,
    "Generate the mixed Matroska attachment fixture"
))
struct AuxiliaryFontAttachmentTests {
    @Test
    func demuxerOmitsOnlyOwnedFontCopies() throws {
        let url = try fixtureURL()
        let primary = try FFmpegDemuxer(url: url)
        let explicit = try FFmpegDemuxer(url: url, loadFontAttachments: true)
        let auxiliary = try FFmpegDemuxer(url: url, loadFontAttachments: false)

        expectFixtureFonts(primary.mediaInfo.attachments)
        #expect(explicit.mediaInfo.attachments == primary.mediaInfo.attachments)
        #expect(auxiliary.mediaInfo.attachments.isEmpty)
        expectSameMetadata(primary.mediaInfo, explicit.mediaInfo)
        expectSameMetadata(primary.mediaInfo, auxiliary.mediaInfo)
        #expect(auxiliary.mediaInfo.streams.filter { $0.kind == .attachment }.count == 3)

        // Opting out affects only the Swift font inventory. Native attachment
        // extradata, including the rejected generic attachment, remains intact.
        for stream in primary.mediaInfo.streams {
            let expected = try #require(primary.codecParameters(streamIndex: stream.index))
            let actual = try #require(auxiliary.codecParameters(streamIndex: stream.index))
            #expect(actual.pointee.codec_type == expected.pointee.codec_type)
            #expect(actual.pointee.codec_id == expected.pointee.codec_id)
            #expect(actual.pointee.extradata_size == expected.pointee.extradata_size)
            #expect(auxiliary.codecPrivateData(streamIndex: stream.index)
                == primary.codecPrivateData(streamIndex: stream.index))
        }
    }

    @Test
    func executorForwardsPolicyAndPreservesOwnedCodecParameters() throws {
        let url = try fixtureURL()
        let primary = try FFmpegInputExecutor(url: url)
        let explicit = try FFmpegInputExecutor(url: url, loadFontAttachments: true)
        expectFixtureFonts(primary.mediaInfo.attachments)
        #expect(explicit.mediaInfo.attachments == primary.mediaInfo.attachments)
        expectSameMetadata(primary.mediaInfo, explicit.mediaInfo)
        weak var retiredInput: FFmpegInputExecutor?
        let copied = try { () -> [(OwnedCodecParameters, Data?)] in
            let input = try FFmpegInputExecutor(url: url, loadFontAttachments: false)
            retiredInput = input
            #expect(input.mediaInfo.attachments.isEmpty)
            expectSameMetadata(primary.mediaInfo, input.mediaInfo)
            return try primary.mediaInfo.streams.map { stream in
                let parameters = try #require(try input.copyCodecParameters(streamIndex: stream.index))
                let expected = primary.codecPrivateData(streamIndex: stream.index)
                #expect(input.codecPrivateData(streamIndex: stream.index) == expected)
                return (parameters, expected)
            }
        }()
        #expect(retiredInput == nil)
        for (parameters, expected) in copied {
            let bytes = try #require(parameters.withUnsafePointer { pointer -> Data? in
                guard let data = pointer.pointee.extradata,
                      pointer.pointee.extradata_size > 0 else { return nil }
                return Data(bytes: data, count: Int(pointer.pointee.extradata_size))
            })
            #expect(bytes == expected)
        }
        expectFixtureFonts(primary.mediaInfo.attachments)
    }

    @Test
    func packetContentsAndSeekResultsDoNotDependOnFontLoading() throws {
        let url = try fixtureURL()
        let primary = try FFmpegInputExecutor(url: url)
        let auxiliary = try FFmpegInputExecutor(url: url, loadFontAttachments: false)
        let firstRead = try packets(from: primary, generation: 7)
        #expect(!firstRead.isEmpty)
        #expect(try packets(from: auxiliary, generation: 7) == firstRead)

        try primary.seek(to: 0, exact: true)
        try auxiliary.seek(to: 0, exact: true)
        let afterSeek = try packets(from: primary, generation: 8)
        #expect(!afterSeek.isEmpty)
        #expect(try packets(from: auxiliary, generation: 8) == afterSeek)
        #expect(auxiliary.mediaInfo.attachments.isEmpty)
        expectFixtureFonts(primary.mediaInfo.attachments)
    }

    private func fixtureURL() throws -> URL {
        let path = try #require(
            ProcessInfo.processInfo.environment["ILLIQUID_ATTACHMENT_ADMISSION_FIXTURE"])
        #expect(FileManager.default.fileExists(atPath: path))
        return URL(fileURLWithPath: path)
    }

    private func expectFixtureFonts(_ fonts: [FontAttachment]) {
        #expect(fonts.map(\.filename) == ["embedded.TTF", "glyphs.bin"])
        #expect(fonts.map(\.mimeType) == ["application/x-truetype-font", "font/otf"])
        #expect(fonts.map(\.data) == [
            Data([0x00, 0x01, 0x02, 0xFE, 0xFF]),
            Data([0x46, 0x4F, 0x4E, 0x54, 0x00, 0x80]),
        ])
    }

    private func expectSameMetadata(_ expected: FFmpegMediaInfo, _ actual: FFmpegMediaInfo) {
        #expect(actual.url == expected.url)
        #expect(actual.containerName == expected.containerName)
        #expect(actual.duration.bitPattern == expected.duration.bitPattern)
        #expect(actual.startTime.bitPattern == expected.startTime.bitPattern)
        #expect(actual.durationStatus == expected.durationStatus)
        #expect(actual.startTimeStatus == expected.startTimeStatus)
        #expect(actual.streams == expected.streams)
        #expect(actual.chapters.count == expected.chapters.count)
        for (lhs, rhs) in zip(actual.chapters, expected.chapters) {
            #expect(lhs.title == rhs.title)
            #expect(lhs.start.bitPattern == rhs.start.bitPattern)
            #expect(lhs.end.bitPattern == rhs.end.bitPattern)
        }
        #expect(actual.selectedVideoIndex == expected.selectedVideoIndex)
        #expect(actual.selectedAudioIndex == expected.selectedAudioIndex)
        #expect(actual.selectedSubtitleIndex == expected.selectedSubtitleIndex)
    }

    private struct PacketSnapshot: Equatable {
        let streamIndex: Int32
        let presentationTimestamp: Int64
        let decodeTimestamp: Int64
        let duration: Int64
        let timeBase: FFmpegRational
        let generation: Int
        let isCorrupt: Bool
        let isKeyframe: Bool
        let bytes: Data?

        init(_ packet: FFmpegPacket) {
            streamIndex = packet.streamIndex
            presentationTimestamp = packet.presentationTimestamp
            decodeTimestamp = packet.decodeTimestamp
            duration = packet.duration
            timeBase = packet.timeBase
            generation = packet.generation
            isCorrupt = packet.isCorrupt
            isKeyframe = packet.isKeyframe
            bytes = packet.data
        }
    }

    private func packets(from input: FFmpegInputExecutor, generation: Int) throws -> [PacketSnapshot] {
        var snapshots: [PacketSnapshot] = []
        // The controlled 0.25-second fixture reaches EOF well within this bound.
        for _ in 0..<1_000 {
            guard let packet = try input.readPacket(generation: generation) else { return snapshots }
            snapshots.append(PacketSnapshot(packet))
        }
        throw PresentationError("Attachment fixture did not reach EOF within its packet bound")
    }
}
