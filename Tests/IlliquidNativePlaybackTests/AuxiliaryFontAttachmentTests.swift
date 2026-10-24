import CFFmpeg
import CoreGraphics
import Foundation
import Testing
@testable import IlliquidNativePlayback

@Suite("Auxiliary input font attachments", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["ILLIQUID_AUXILIARY_FONT_FIXTURE"] != nil,
                "Generate the mixed auxiliary-input Matroska fixture"))
struct AuxiliaryFontAttachmentTests {
    private static let expectedFonts = [
        FontAttachment(filename: "embedded.TTF", mimeType: "application/x-truetype-font",
                       data: Data([0x00, 0x01, 0x02, 0xFE, 0xFF])),
        FontAttachment(filename: "glyphs.bin", mimeType: "font/otf",
                       data: Data([0x46, 0x4F, 0x4E, 0x54, 0x00, 0x80])),
    ]

    @Test(arguments: [false, true])
    func defaultFontBytesOutliveDemuxerAndExecutor(throughExecutor: Bool) throws {
        let url = try fixture()
        let info: FFmpegMediaInfo
        if throughExecutor {
            var input: FFmpegInputExecutor? = try FFmpegInputExecutor(url: url)
            weak var releasedInput = input
            info = try #require(input?.mediaInfo)
            #expect(input?.openWasPerformedOnMainThread == false)
            input = nil
            #expect(releasedInput == nil)
        } else {
            var demuxer: FFmpegDemuxer? = try FFmpegDemuxer(url: url)
            weak var releasedDemuxer = demuxer
            info = try #require(demuxer?.mediaInfo)
            demuxer = nil
            #expect(releasedDemuxer == nil)
        }

        // The native contexts are gone. Default callers still receive owned,
        // exact payloads in source order; unsupported attachments stay excluded.
        #expect(info.attachments == Self.expectedFonts)
        #expect(info.streams.filter { $0.kind == .attachment }.count == 3)
        #expect(info.videoStreams.map(\.codecName) == ["ffv1"])
        #expect(info.audioStreams.map(\.codecName) == ["flac"])
        #expect(info.subtitleStreams.map(\.codecName) == ["ass"])
    }

    @Test func demuxerOptOutPreservesMetadataCodecPrivateBytesAndPackets() throws {
        let url = try fixture()
        let primary = try FFmpegDemuxer(url: url)
        let auxiliary = try FFmpegDemuxer(url: url, includeFontAttachments: false)
        #expect(primary.mediaInfo.attachments == Self.expectedFonts)
        #expect(auxiliary.mediaInfo.attachments.isEmpty)
        expectSameMetadata(primary.mediaInfo, auxiliary.mediaInfo)
        for stream in primary.mediaInfo.streams {
            #expect(primary.codecPrivateData(streamIndex: stream.index)
                    == auxiliary.codecPrivateData(streamIndex: stream.index))
        }
        let subtitle = try #require(primary.mediaInfo.subtitleStreams.first)
        #expect(auxiliary.codecPrivateData(streamIndex: subtitle.index)?.isEmpty == false)
        let fontStream = try #require(primary.mediaInfo.streams.last)
        #expect(auxiliary.codecPrivateData(streamIndex: fontStream.index) == Self.expectedFonts.last?.data)

        let packets = try readAllPackets { try primary.readPacket(generation: 7) }
        #expect(try readAllPackets { try auxiliary.readPacket(generation: 7) } == packets)
        expectMediaPackets(packets, info: primary.mediaInfo)
        try primary.seek(to: 0, exact: true)
        try auxiliary.seek(to: 0, exact: true)
        let replay = try readAllPackets { try primary.readPacket(generation: 8) }
        #expect(!replay.isEmpty)
        #expect(try readAllPackets { try auxiliary.readPacket(generation: 8) } == replay)
    }

    @Test func executorForwardsOptOutWithoutChangingPrimaryOrOtherReaders() throws {
        let url = try fixture()
        let primary = try FFmpegInputExecutor(url: url)
        // Keep all readers alive together, as subtitle, delayed-audio and
        // thumbnail readers can coexist with the primary playback input.
        let auxiliaries = try (0..<3).map { _ in
            try FFmpegInputExecutor(url: url, includeFontAttachments: false)
        }
        let packets = try readAllPackets { try primary.readPacket(generation: 9) }
        expectMediaPackets(packets, info: primary.mediaInfo)
        for auxiliary in auxiliaries {
            #expect(auxiliary.mediaInfo.attachments.isEmpty)
            #expect(!auxiliary.openWasPerformedOnMainThread)
            expectSameMetadata(primary.mediaInfo, auxiliary.mediaInfo)
            for stream in primary.mediaInfo.streams {
                #expect(primary.codecPrivateData(streamIndex: stream.index)
                        == auxiliary.codecPrivateData(streamIndex: stream.index))
            }
            #expect(try readAllPackets { try auxiliary.readPacket(generation: 9) } == packets)
        }
        #expect(primary.mediaInfo.attachments == Self.expectedFonts)
    }

    @Test @MainActor
    func playbackSessionStillRegistersPrimaryFontsWithIndependentSubtitleAndAudioInputs() throws {
        let presentation = try NativePresentationCoordinator()
        defer { presentation.terminate() }
        let main = try SubtitlePipeline(overlay: SubtitleOverlayView(headless: true), presentsOverlay: false)
        defer { main.terminate() }
        let pip = try SubtitlePipeline(overlay: SubtitleOverlayView(headless: true), presentsOverlay: false)
        defer { pip.terminate() }
        let session = try MediaSession(
            url: fixture(), presentation: presentation, subtitles: main,
            pictureInPictureSubtitles: pip, audioDelay: 0.25,
            selectedSubtitleIndex: 2, preferHardware: false)
        defer {
            session.stop()
            #expect(session.waitForShutdown(timeout: .now() + 3))
        }

        #expect(session.mediaInfo.attachments == Self.expectedFonts)
        #expect(session.registeredAttachmentNames == Self.expectedFonts.map(\.filename))
        #expect(session.activeSubtitleStream?.codecName == "ass")
        #expect(session.activeSubtitleStream?.index == 2)
        #expect(session.audioDelay == 0.25)
        // The tiny deterministic font payloads qualify ownership and pipeline
        // registration, not glyph rendering or font-file validity.
    }

    @Test func metadataFrameStepAndThumbnailConsumersWorkWithFontAttachments() async throws {
        let url = try fixture()
        let probedDuration = await NativeThumbnailMetadataReader().duration(of: url)
        let duration = try #require(probedDuration)
        #expect(duration > 0)
        let steppedTime = try await NativeFrameStepReader().target(url: url, position: 0, direction: 1)
        let next = try #require(steppedTime)
        // The generated fixture has two FFV1 frames at four frames per second.
        #expect(abs(next - 0.25) < 0.000001)
        #expect(next < duration)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("illiquid-auxiliary-fonts-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // This is an output regression, so lazy Core Image setup need not share
        // the worker's bounded decode deadline on a busy native test runner.
        await NativeTimelineThumbnailGenerator.prepareImageRendererForQualification()
        let generator = NativeTimelineThumbnailGenerator(cacheDirectory: directory)
        let thumbnail = await generator.thumbnail(for: url, at: 0,
            maximumPixelSize: CGSize(width: 32, height: 24))
        await generator.cancelWork()
        await generator.releaseIdleResources()
        await generator.flushPendingCacheWrites()
        let image = try #require(thumbnail)
        #expect(image.width == 32)
        #expect(image.height == 24)
        #expect(image.dataProvider?.data != nil)
    }

    private func fixture() throws -> URL {
        let path = try #require(ProcessInfo.processInfo.environment["ILLIQUID_AUXILIARY_FONT_FIXTURE"])
        try #require(FileManager.default.fileExists(atPath: path), "Configured fixture must exist")
        return URL(fileURLWithPath: path)
    }

    private func expectSameMetadata(_ primary: FFmpegMediaInfo, _ auxiliary: FFmpegMediaInfo) {
        #expect(auxiliary.url == primary.url)
        #expect(auxiliary.containerName == primary.containerName)
        #expect(auxiliary.duration == primary.duration)
        #expect(auxiliary.startTime == primary.startTime)
        #expect(auxiliary.durationStatus == primary.durationStatus)
        #expect(auxiliary.startTimeStatus == primary.startTimeStatus)
        #expect(auxiliary.streams == primary.streams)
        #expect(auxiliary.chapters.map(\.title) == primary.chapters.map(\.title))
        #expect(auxiliary.chapters.map(\.start) == primary.chapters.map(\.start))
        #expect(auxiliary.chapters.map(\.end) == primary.chapters.map(\.end))
        #expect(auxiliary.selectedVideoIndex == primary.selectedVideoIndex)
        #expect(auxiliary.selectedAudioIndex == primary.selectedAudioIndex)
        #expect(auxiliary.selectedSubtitleIndex == primary.selectedSubtitleIndex)
    }

    private func expectMediaPackets(_ packets: [PacketSnapshot], info: FFmpegMediaInfo) {
        #expect(!packets.isEmpty)
        for stream in info.streams where [.video, .audio, .subtitle].contains(stream.kind) {
            #expect(packets.contains { $0.streamIndex == stream.index && !($0.data?.isEmpty ?? true) })
        }
    }

    private func readAllPackets(_ read: () throws -> FFmpegPacket?) throws -> [PacketSnapshot] {
        var result: [PacketSnapshot] = []
        while let packet = try read() {
            try #require(result.count < 4_096, "The short fixture must reach EOF within the packet bound")
            result.append(try PacketSnapshot(packet))
        }
        return result
    }

    private struct PacketSnapshot: Equatable {
        struct SideData: Equatable {
            let kind: Int
            let data: Data
        }

        let streamIndex: Int32
        let presentationTimestamp: Int64
        let decodeTimestamp: Int64
        let duration: Int64
        let timeBase: FFmpegRational
        let generation: Int
        let flags: Int32
        let position: Int64
        let data: Data?
        let sideData: [SideData]

        init(_ packet: FFmpegPacket) throws {
            let raw = try #require(packet.pointer)
            streamIndex = packet.streamIndex
            presentationTimestamp = packet.presentationTimestamp
            decodeTimestamp = packet.decodeTimestamp
            duration = packet.duration
            timeBase = packet.timeBase
            generation = packet.generation
            flags = raw.pointee.flags
            position = raw.pointee.pos
            data = packet.data
            var copied: [SideData] = []
            if raw.pointee.side_data_elems > 0 {
                let entries = try #require(raw.pointee.side_data)
                for index in 0..<Int(raw.pointee.side_data_elems) {
                    let entry = entries[index]
                    let bytes = try #require(entry.data)
                    copied.append(SideData(kind: Int(entry.type.rawValue),
                                           data: Data(bytes: bytes, count: Int(entry.size))))
                }
            }
            sideData = copied
        }
    }
}
