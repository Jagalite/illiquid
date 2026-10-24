import CFFmpeg
import Foundation
import Testing
@testable import IlliquidNativePlayback

@Suite(
    "Auxiliary reader font attachments",
    .serialized,
    .enabled(
        if: ProcessInfo.processInfo.environment["ILLIQUID_AUXILIARY_FONT_FIXTURE"] != nil,
        "Generate the mixed auxiliary font attachment fixture"
    )
)
struct AuxiliaryFontAttachmentTests {
    private var expectedFonts: [FontAttachment] {
        [
            FontAttachment(
                filename: "embedded.TTF",
                mimeType: "application/x-truetype-font",
                data: Data([0x00, 0x01, 0x02, 0xFE, 0xFF])
            ),
            FontAttachment(
                filename: "glyphs.bin",
                mimeType: "font/otf",
                data: Data([0x46, 0x4F, 0x4E, 0x54, 0x00, 0x80])
            ),
        ]
    }

    @Test
    func defaultInputKeepsIndependentFontOwnershipAfterClose() throws {
        let url = try fixtureURL()
        weak var retired: FFmpegDemuxer?
        let retainedInfo = try {
            let input = try FFmpegDemuxer(url: url)
            retired = input
            #expect(input.mediaInfo.streams.count == 6)
            #expect(input.mediaInfo.streams.filter { $0.kind == .attachment }.count == 3)
            #expect(input.mediaInfo.selectedVideoIndex == 0)
            #expect(input.mediaInfo.selectedAudioIndex == 1)
            #expect(input.mediaInfo.selectedSubtitleIndex == 2)
            return input.mediaInfo
        }()

        #expect(retired == nil)
        #expect(retainedInfo.attachments == expectedFonts)
        let explicit = try FFmpegDemuxer(url: url, includeFontAttachments: true)
        #expect(explicit.mediaInfo.attachments == retainedInfo.attachments)
    }

    @Test
    func omissionPreservesMetadataCodecDataAndPacketsAcrossSeeks() throws {
        let url = try fixtureURL()
        let primary = try FFmpegDemuxer(url: url)
        let auxiliary = try FFmpegDemuxer(url: url, includeFontAttachments: false)
        #expect(primary.mediaInfo.attachments == expectedFonts)
        #expect(auxiliary.mediaInfo.attachments.isEmpty)
        expectSameMetadata(auxiliary.mediaInfo, primary.mediaInfo)
        #expect(primary.mediaInfo.chapters.map(\.title) == ["Opening", "Closing"])

        for stream in primary.mediaInfo.streams {
            let original = try #require(primary.codecParameters(streamIndex: stream.index))
            let omitted = try #require(auxiliary.codecParameters(streamIndex: stream.index))
            #expect(CodecConfiguration(omitted) == CodecConfiguration(original))
            // Omitting the Swift copy does not clear FFmpeg's native extradata,
            // including the supported and unsupported attachment streams.
            #expect(auxiliary.codecPrivateData(streamIndex: stream.index)
                == primary.codecPrivateData(streamIndex: stream.index))
        }

        let original = try packets { try primary.readPacket(generation: 1) }
        let omitted = try packets { try auxiliary.readPacket(generation: 1) }
        #expect(omitted == original)
        #expect(Set(original.map(\.streamIndex)) == Set([Int32(0), 1, 2]))
        for (generation, target) in [(2, 1.0), (3, 0.0)] {
            try primary.seek(to: target, exact: true)
            try auxiliary.seek(to: target, exact: true)
            let original = try packets { try primary.readPacket(generation: generation) }
            let omitted = try packets { try auxiliary.readPacket(generation: generation) }
            #expect(!original.isEmpty)
            #expect(omitted == original)
        }
        #expect(auxiliary.mediaInfo.attachments.isEmpty)
    }

    @Test @MainActor
    func executorForwardsOmissionWithoutChangingCodecCopiesOrReads() throws {
        let url = try fixtureURL()
        let primary = try FFmpegInputExecutor(url: url)
        let auxiliary = try FFmpegInputExecutor(url: url, includeFontAttachments: false)
        #expect(!primary.openWasPerformedOnMainThread)
        #expect(!auxiliary.openWasPerformedOnMainThread)
        #expect(primary.mediaInfo.attachments == expectedFonts)
        #expect(auxiliary.mediaInfo.attachments.isEmpty)
        expectSameMetadata(auxiliary.mediaInfo, primary.mediaInfo)

        for stream in primary.mediaInfo.streams {
            let original = try #require(try primary.copyCodecParameters(streamIndex: stream.index))
            let omitted = try #require(try auxiliary.copyCodecParameters(streamIndex: stream.index))
            let originalConfiguration = original.withUnsafePointer { CodecConfiguration($0) }
            let omittedConfiguration = omitted.withUnsafePointer { CodecConfiguration($0) }
            #expect(originalConfiguration != nil)
            #expect(omittedConfiguration == originalConfiguration)
            #expect(auxiliary.codecPrivateData(streamIndex: stream.index)
                == primary.codecPrivateData(streamIndex: stream.index))
        }
        let original = try packets { try primary.readPacket(generation: 4) }
        let omitted = try packets { try auxiliary.readPacket(generation: 4) }
        #expect(!original.isEmpty)
        #expect(omitted == original)
        try primary.seek(to: 1, exact: true)
        try auxiliary.seek(to: 1, exact: true)
        let originalAfterSeek = try packets { try primary.readPacket(generation: 5) }
        let omittedAfterSeek = try packets { try auxiliary.readPacket(generation: 5) }
        #expect(!originalAfterSeek.isEmpty)
        #expect(omittedAfterSeek == originalAfterSeek)
    }

    @Test @MainActor
    func sessionRegistersPrimaryFontsWhileOpeningAuxiliaryInputs() throws {
        let presentation = try NativePresentationCoordinator()
        let subtitles = try SubtitlePipeline(overlay: SubtitleOverlayView(), presentsOverlay: false)
        let pictureInPicture = try SubtitlePipeline(
            overlay: SubtitleOverlayView(),
            presentsOverlay: false,
            memoryOwner: .pictureInPictureLibass
        )
        // A nonzero delay plus an embedded subtitle opens both auxiliary input
        // executors. Only the primary media info supplies fonts to the pipelines.
        let session = try MediaSession(
            url: fixtureURL(),
            presentation: presentation,
            subtitles: subtitles,
            pictureInPictureSubtitles: pictureInPicture,
            audioDelay: 0.1,
            selectedSubtitleIndex: 2,
            preferHardware: false
        )
        #expect(session.mediaInfo.attachments == expectedFonts)
        #expect(session.registeredAttachmentNames == expectedFonts.map(\.filename))
        #expect(session.activeAudioStream?.index == 1)
        #expect(session.activeSubtitleStream?.index == 2)
        #expect(session.audioDelay == 0.1)
        #expect(session.pictureInPictureSubtitlePipeline === pictureInPicture)
        // Deterministic font-labeled fixture bytes exercise admission and
        // ownership; this construction test does not assert font rendering.
    }

    private func fixtureURL() throws -> URL {
        let path = try #require(ProcessInfo.processInfo.environment["ILLIQUID_AUXILIARY_FONT_FIXTURE"])
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        try #require(values.isRegularFile == true && (values.fileSize ?? 0) > 0)
        return url
    }

    private func expectSameMetadata(_ actual: FFmpegMediaInfo, _ expected: FFmpegMediaInfo) {
        #expect(actual.url == expected.url)
        #expect(actual.containerName == expected.containerName)
        #expect(actual.duration.bitPattern == expected.duration.bitPattern)
        #expect(actual.startTime.bitPattern == expected.startTime.bitPattern)
        #expect(actual.durationStatus == expected.durationStatus)
        #expect(actual.startTimeStatus == expected.startTimeStatus)
        #expect(actual.streams == expected.streams)
        #expect(actual.chapters.count == expected.chapters.count)
        for (actual, expected) in zip(actual.chapters, expected.chapters) {
            #expect(actual.title == expected.title)
            #expect(actual.start.bitPattern == expected.start.bitPattern)
            #expect(actual.end.bitPattern == expected.end.bitPattern)
        }
        #expect(actual.selectedVideoIndex == expected.selectedVideoIndex)
        #expect(actual.selectedAudioIndex == expected.selectedAudioIndex)
        #expect(actual.selectedSubtitleIndex == expected.selectedSubtitleIndex)
        #expect(actual.videoStreams == expected.videoStreams)
        #expect(actual.audioStreams == expected.audioStreams)
        #expect(actual.subtitleStreams == expected.subtitleStreams)
    }

    private struct CodecConfiguration: Equatable {
        let mediaType: Int32
        let codecID: Int32
        let codecTag: UInt32
        let format: Int32
        let bitRate: Int64
        let width: Int32
        let height: Int32
        let aspect: FFmpegRational
        let sampleRate: Int32
        let channels: Int32
        let privateData: Data?

        init(_ pointer: UnsafePointer<AVCodecParameters>) {
            let value = pointer.pointee
            mediaType = Int32(truncatingIfNeeded: value.codec_type.rawValue)
            codecID = Int32(truncatingIfNeeded: value.codec_id.rawValue)
            codecTag = value.codec_tag
            format = value.format
            bitRate = value.bit_rate
            width = value.width
            height = value.height
            aspect = FFmpegRational(value.sample_aspect_ratio)
            sampleRate = value.sample_rate
            channels = value.ch_layout.nb_channels
            privateData = if let bytes = value.extradata, value.extradata_size > 0 {
                Data(bytes: bytes, count: Int(value.extradata_size))
            } else { nil }
        }
    }

    private struct Packet: Equatable {
        let streamIndex: Int32
        let presentationTimestamp: Int64
        let decodeTimestamp: Int64
        let duration: Int64
        let timeBase: FFmpegRational
        let generation: Int
        let flags: Int32?
        let data: Data?

        init(_ packet: FFmpegPacket) {
            streamIndex = packet.streamIndex
            presentationTimestamp = packet.presentationTimestamp
            decodeTimestamp = packet.decodeTimestamp
            duration = packet.duration
            timeBase = packet.timeBase
            generation = packet.generation
            flags = packet.pointer?.pointee.flags
            data = packet.data
        }
    }

    private func packets(_ read: () throws -> FFmpegPacket?) throws -> [Packet] {
        var result: [Packet] = []
        for _ in 0..<1_024 {
            guard let packet = try read() else { return result }
            result.append(Packet(packet))
        }
        throw PresentationError("Auxiliary attachment fixture exceeded its bounded packet count")
    }
}
