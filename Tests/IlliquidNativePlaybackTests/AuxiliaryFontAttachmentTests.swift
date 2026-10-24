import CoreGraphics
import Foundation
import Testing
@testable import IlliquidNativePlayback

@Suite("Auxiliary input font ownership", .serialized)
struct AuxiliaryFontAttachmentTests {
    private struct PacketSnapshot: Equatable {
        let streamIndex: Int32
        let presentationTimestamp: Int64
        let decodeTimestamp: Int64
        let duration: Int64
        let timeBase: FFmpegRational
        let generation: Int
        let isCorrupt: Bool
        let isKeyframe: Bool
        let data: Data?

        init(_ packet: FFmpegPacket) {
            streamIndex = packet.streamIndex
            presentationTimestamp = packet.presentationTimestamp
            decodeTimestamp = packet.decodeTimestamp
            duration = packet.duration
            timeBase = packet.timeBase
            generation = packet.generation
            isCorrupt = packet.isCorrupt
            isKeyframe = packet.isKeyframe
            data = packet.data
        }
    }

    private func fixture(_ key: String) throws -> URL {
        let path = try #require(ProcessInfo.processInfo.environment[key])
        try #require(FileManager.default.fileExists(atPath: path), "Required fixture is missing")
        return URL(fileURLWithPath: path)
    }

    private func expectSameMetadata(_ lhs: FFmpegMediaInfo, _ rhs: FFmpegMediaInfo) {
        #expect(lhs.url == rhs.url)
        #expect(lhs.containerName == rhs.containerName)
        #expect(lhs.duration.bitPattern == rhs.duration.bitPattern)
        #expect(lhs.startTime.bitPattern == rhs.startTime.bitPattern)
        #expect(lhs.durationStatus == rhs.durationStatus)
        #expect(lhs.startTimeStatus == rhs.startTimeStatus)
        #expect(lhs.streams == rhs.streams)
        #expect(lhs.chapters.elementsEqual(rhs.chapters) {
            $0.title == $1.title
                && $0.start.bitPattern == $1.start.bitPattern
                && $0.end.bitPattern == $1.end.bitPattern
        })
        #expect(lhs.selectedVideoIndex == rhs.selectedVideoIndex)
        #expect(lhs.selectedAudioIndex == rhs.selectedAudioIndex)
        #expect(lhs.selectedSubtitleIndex == rhs.selectedSubtitleIndex)
    }

    private func packets(_ read: () throws -> FFmpegPacket?) throws -> [PacketSnapshot] {
        var result: [PacketSnapshot] = []
        while let packet = try read() {
            try #require(result.count < 256, "The small fixture did not reach EOF within its packet bound")
            result.append(PacketSnapshot(packet))
        }
        try #require(!result.isEmpty)
        return result
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ILLIQUID_ATTACHMENT_ADMISSION_FIXTURE"] != nil,
                   "Generate the mixed Matroska attachment fixture"))
    func defaultInputStillOwnsFontBytesAfterDemuxerDestruction() throws {
        let url = try fixture("ILLIQUID_ATTACHMENT_ADMISSION_FIXTURE")
        let primaryInfo = try { try FFmpegDemuxer(url: url).mediaInfo }()
        let explicitInfo = try {
            try FFmpegDemuxer(url: url, includeFontAttachments: true).mediaInfo
        }()
        expectSameMetadata(primaryInfo, explicitInfo)
        #expect(primaryInfo.attachments == explicitInfo.attachments)
        #expect(primaryInfo.streams.filter { $0.kind == .attachment }.count == 3)
        #expect(primaryInfo.attachments.map(\.filename) == ["embedded.TTF", "glyphs.bin"])
        #expect(primaryInfo.attachments.map(\.mimeType) == ["application/x-truetype-font", "font/otf"])
        // Both demuxers and their AVFormatContext payloads are gone. The primary
        // media info must still own all accepted bytes in source order.
        #expect(primaryInfo.attachments.map(\.data) == [
            Data([0x00, 0x01, 0x02, 0xFE, 0xFF]),
            Data([0x46, 0x4F, 0x4E, 0x54, 0x00, 0x80]),
        ])
        #expect(try FontAttachmentValidator.validated(primaryInfo.attachments) == primaryInfo.attachments)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ILLIQUID_ATTACHMENT_ADMISSION_FIXTURE"] != nil,
                   "Generate the mixed Matroska attachment fixture"))
    func auxiliaryDemuxerPreservesMetadataCodecDataAndPackets() throws {
        let url = try fixture("ILLIQUID_ATTACHMENT_ADMISSION_FIXTURE")
        let primary = try FFmpegDemuxer(url: url)
        let auxiliary = try FFmpegDemuxer(url: url, includeFontAttachments: false)
        #expect(auxiliary.mediaInfo.attachments.isEmpty)
        expectSameMetadata(primary.mediaInfo, auxiliary.mediaInfo)
        for stream in primary.mediaInfo.streams {
            #expect(primary.codecPrivateData(streamIndex: stream.index)
                == auxiliary.codecPrivateData(streamIndex: stream.index))
        }
        #expect(try packets { try primary.readPacket(generation: 7) }
            == packets { try auxiliary.readPacket(generation: 7) })
        try primary.seek(to: 0, exact: true)
        try auxiliary.seek(to: 0, exact: true)
        #expect(try packets { try primary.readPacket(generation: 8) }
            == packets { try auxiliary.readPacket(generation: 8) })
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ILLIQUID_ATTACHMENT_ADMISSION_FIXTURE"] != nil,
                   "Generate the mixed Matroska attachment fixture"))
    func auxiliaryExecutorForwardsPolicyWithoutChangingInputBehavior() throws {
        let url = try fixture("ILLIQUID_ATTACHMENT_ADMISSION_FIXTURE")
        let primary = try FFmpegInputExecutor(url: url)
        let auxiliary = try FFmpegInputExecutor(url: url, includeFontAttachments: false)
        #expect(!primary.mediaInfo.attachments.isEmpty)
        #expect(auxiliary.mediaInfo.attachments.isEmpty)
        expectSameMetadata(primary.mediaInfo, auxiliary.mediaInfo)
        for stream in primary.mediaInfo.streams {
            #expect(primary.codecPrivateData(streamIndex: stream.index)
                == auxiliary.codecPrivateData(streamIndex: stream.index))
        }
        #expect(try packets { try primary.readPacket(generation: 9) }
            == packets { try auxiliary.readPacket(generation: 9) })
        try primary.seek(to: 0, exact: true)
        try auxiliary.seek(to: 0, exact: true)
        #expect(try packets { try primary.readPacket(generation: 10) }
            == packets { try auxiliary.readPacket(generation: 10) })
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ILLIQUID_AUXILIARY_FONT_VIDEO_FIXTURE"] != nil,
                   "Generate the video, audio, ASS, and real-font fixture"))
    func metadataThumbnailAndFrameStepReadersStillWork() async throws {
        let url = try fixture("ILLIQUID_AUXILIARY_FONT_VIDEO_FIXTURE")
        let primary = try FFmpegDemuxer(url: url)
        try #require(!primary.mediaInfo.attachments.isEmpty)
        let duration = await NativeThumbnailMetadataReader().duration(of: url)
        #expect(duration == primary.mediaInfo.duration)

        let stepReader = NativeFrameStepReader()
        let next = try #require(try await stepReader.target(url: url, position: 0.25, direction: 1))
        let previous = try #require(try await stepReader.target(url: url, position: 0.25, direction: -1))
        #expect(next > 0.25)
        #expect(previous < 0.25)
        #expect(previous >= 0)

        let cache = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: cache) }
        let generator = NativeTimelineThumbnailGenerator(cacheDirectory: cache)
        let image = await generator.thumbnail(
            for: url, at: 0.5, maximumPixelSize: CGSize(width: 64, height: 64))
        await generator.flushPendingCacheWrites()
        await generator.cancelWork()
        let thumbnail = try #require(image)
        #expect((1...64).contains(thumbnail.width))
        #expect((1...64).contains(thumbnail.height))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ILLIQUID_AUXILIARY_FONT_VIDEO_FIXTURE"] != nil,
                   "Generate the video, audio, ASS, and real-font fixture"))
    func primaryFontsRenderIdenticallyWithAuxiliarySubtitlePackets() throws {
        let url = try fixture("ILLIQUID_AUXILIARY_FONT_VIDEO_FIXTURE")
        let primary = try FFmpegDemuxer(url: url)
        let auxiliary = try FFmpegDemuxer(url: url, includeFontAttachments: false)
        let fonts = try FontAttachmentValidator.validated(primary.mediaInfo.attachments)
        try #require(!fonts.isEmpty)
        #expect(auxiliary.mediaInfo.attachments.isEmpty)

        func render(_ input: FFmpegDemuxer) throws -> [ASSRenderedRegion] {
            let stream = try #require(input.mediaInfo.subtitleStreams.first { $0.codecName == "ass" })
            let parameters = try #require(input.codecParameters(streamIndex: stream.index))
            let codecPrivate = try #require(input.codecPrivateData(streamIndex: stream.index))
            let decoder = try SubtitleDecoder(parameters: parameters, stream: stream)
            let context = try LibassContext()
            #expect(context.configure(frameSize: CGSize(width: 320, height: 180),
                                      storageSize: CGSize(width: 320, height: 180)))
            for font in fonts { #expect(context.register(font)) }
            #expect(context.registeredFonts == fonts.map(\.filename))
            context.processCodecPrivate(codecPrivate)
            var packetCount = 0
            while let packet = try input.readPacket(generation: 1) {
                try #require(packetCount < 256)
                packetCount += 1
                if packet.streamIndex == stream.index {
                    for event in try decoder.decode(packet) {
                        context.processChunk(event.assData,
                            start: event.presentationSeconds - input.mediaInfo.startTime,
                            duration: event.durationSeconds)
                    }
                }
            }
            let result = context.render(at: 0.5)
            let regions = try #require(result.regions)
            try #require(!regions.isEmpty)
            #expect(regions.allSatisfy { !$0.bitmap.isEmpty })
            return regions
        }

        let expected = try render(primary)
        let actual = try render(auxiliary)
        #expect(actual.count == expected.count)
        for (lhs, rhs) in zip(expected, actual) {
            #expect(lhs.bitmap == rhs.bitmap)
            #expect(lhs.color == rhs.color)
            #expect(lhs.frame == rhs.frame)
            #expect(lhs.stride == rhs.stride)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ILLIQUID_AUXILIARY_FONT_VIDEO_FIXTURE"] != nil,
                   "Generate the video, audio, ASS, and real-font fixture"))
    @MainActor
    func sessionWithAuxiliaryAudioAndSubtitlesRegistersPrimaryFonts() throws {
        let url = try fixture("ILLIQUID_AUXILIARY_FONT_VIDEO_FIXTURE")
        let info = try FFmpegDemuxer(url: url).mediaInfo
        let audioIndex = try #require(info.selectedAudioIndex)
        let subtitleIndex = try #require(info.subtitleStreams.first { $0.codecName == "ass" }?.index)
        let presentation = try NativePresentationCoordinator()
        let subtitles = try SubtitlePipeline(overlay: SubtitleOverlayView())
        let session = try MediaSession(
            url: url, presentation: presentation, subtitles: subtitles,
            selectedAudioIndex: audioIndex, audioDelay: 0.125,
            selectedSubtitleIndex: subtitleIndex, preferHardware: false)
        defer { session.stop() }
        #expect(!info.attachments.isEmpty)
        #expect(session.mediaInfo.attachments == info.attachments)
        #expect(session.registeredAttachmentNames == info.attachments.map(\.filename))
    }
}
