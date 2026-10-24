import CoreMedia
import Foundation
import Testing
@testable import IlliquidNativePlayback

@Suite("Auxiliary input attachment policy")
struct AuxiliaryAttachmentPolicyTests {
    @Test(.enabled(
        if: ProcessInfo.processInfo.environment["ILLIQUID_AUXILIARY_ATTACHMENT_FIXTURE"] != nil,
        "Generate the mixed audio/video/ASS attachment fixture"
    ), arguments: [false, true])
    func defaultPolicyOwnsExactFontBytesAfterInputCloses(useExecutor: Bool) throws {
        let url = try fixtureURL()
        let info: FFmpegMediaInfo = try {
            if useExecutor {
                let input = try FFmpegInputExecutor(url: url)
                return input.mediaInfo
            }
            let input = try FFmpegDemuxer(url: url)
            return input.mediaInfo
        }()

        // The native input has closed. Primary readers must still own complete
        // font data, in source order, while excluding the non-font attachment.
        #expect(info.attachments.map(\.filename) == ["embedded.TTF", "glyphs.bin"])
        #expect(info.attachments.map(\.mimeType) == ["application/x-truetype-font", "font/otf"])
        #expect(info.attachments.map(\.data) == [
            Data([0x00, 0x01, 0x02, 0xFE, 0xFF]),
            Data([0x46, 0x4F, 0x4E, 0x54, 0x00, 0x80]),
        ])
    }

    @Test(.enabled(
        if: ProcessInfo.processInfo.environment["ILLIQUID_AUXILIARY_ATTACHMENT_FIXTURE"] != nil,
        "Generate the mixed audio/video/ASS attachment fixture"
    ), arguments: [false, true])
    func omittingPayloadsPreservesMetadataHeadersPacketsAndSeeking(useExecutor: Bool) throws {
        let url = try fixtureURL()
        let primary = try Reader(url: url, useExecutor: useExecutor, policy: .supportedFonts)
        let auxiliary = try Reader(url: url, useExecutor: useExecutor, policy: .none)
        let info = primary.info
        #expect(info.videoStreams.count == 1)
        #expect(info.audioStreams.count == 1)
        #expect(info.subtitleStreams.count == 1)
        #expect(info.streams.filter { $0.kind == .attachment }.count == 3)
        #expect(info.attachments.count == 2)
        #expect(auxiliary.info.attachments.isEmpty)
        expectSameMetadata(info, auxiliary.info)

        let subtitle = try #require(info.subtitleStreams.first)
        #expect(subtitle.codecName == "ass")
        let header = try #require(primary.codecPrivateData(subtitle.index))
        #expect(!header.isEmpty)
        #expect(auxiliary.codecPrivateData(subtitle.index) == header)
        for stream in info.streams where stream.kind != .attachment {
            #expect(primary.codecPrivateData(stream.index) == auxiliary.codecPrivateData(stream.index))
        }

        let original = try packets { try primary.readPacket(1) }
        let omitted = try packets { try auxiliary.readPacket(1) }
        #expect(!original.isEmpty)
        #expect(original == omitted)
        let deliveredStreams = Set(original.map(\.streamIndex))
        #expect(deliveredStreams.contains(try #require(info.selectedVideoIndex)))
        #expect(deliveredStreams.contains(try #require(info.selectedAudioIndex)))
        #expect(deliveredStreams.contains(subtitle.index))

        // Exercise both the auxiliary subtitle seek path and restarting packet
        // reads after EOF, with identical generation and timing metadata.
        for (target, exact) in [(info.startTime + 0.5, false), (info.startTime, true)] {
            try primary.seek(target, exact)
            try auxiliary.seek(target, exact)
            let expected = try packets { try primary.readPacket(2) }
            #expect(!expected.isEmpty)
            #expect(expected == (try packets { try auxiliary.readPacket(2) }))
        }
    }

    @Test(.enabled(
        if: ProcessInfo.processInfo.environment["ILLIQUID_AUXILIARY_REAL_FONT_FIXTURE"] != nil,
        "Generate the bundled Noto Sans attachment fixture"
    ))
    @MainActor
    func primaryFontsRenderIdenticallyWithPayloadFreeSubtitleInput() throws {
        let path = try #require(ProcessInfo.processInfo.environment["ILLIQUID_AUXILIARY_REAL_FONT_FIXTURE"])
        try #require(FileManager.default.fileExists(atPath: path), "Required real-font fixture is missing")
        let url = URL(fileURLWithPath: path)
        let primary = try FFmpegInputExecutor(url: url)
        let attachments = primary.mediaInfo.attachments
        #expect(attachments.map(\.filename) == ["NotoSans-Regular.ttf"])
        #expect(attachments.allSatisfy { !$0.data.isEmpty && $0.isSupportedFont })

        let baseline = try FFmpegInputExecutor(url: url)
        let auxiliary = try FFmpegInputExecutor(url: url, attachmentPolicy: .none)
        #expect(baseline.mediaInfo.attachments == attachments)
        #expect(auxiliary.mediaInfo.attachments.isEmpty)
        let expected = try render(input: baseline, primaryAttachments: attachments)
        let actual = try render(input: auxiliary, primaryAttachments: attachments)
        try #require(!expected.isEmpty)
        try #require(actual.count == expected.count)
        #expect(expected.contains { $0.bitmap.contains { $0 != 0 } })
        for (before, after) in zip(expected, actual) {
            #expect(after.bitmap == before.bitmap)
            #expect(after.color == before.color)
            #expect(after.frame == before.frame)
            #expect(after.stride == before.stride)
            #expect(after.bitmapSize == before.bitmapSize)
            #expect(after.isPremultipliedBGRA == before.isPremultipliedBGRA)
        }
    }

    @MainActor
    private func render(
        input: FFmpegInputExecutor,
        primaryAttachments: [FontAttachment]
    ) throws -> [ASSRenderedRegion] {
        let stream = try #require(input.mediaInfo.subtitleStreams.first)
        #expect(stream.codecName == "ass")
        let parameters = try #require(try input.copyCodecParameters(streamIndex: stream.index))
        let createdDecoder = try parameters.withUnsafePointer {
            try SubtitleDecoder(parameters: $0, stream: stream)
        }
        let decoder = try #require(createdDecoder)
        let header = try #require(input.codecPrivateData(streamIndex: stream.index))
        #expect(String(decoding: header, as: UTF8.self).contains("Noto Sans"))
        let size = CGSize(width: 640, height: 360)
        let pipeline = try SubtitlePipeline(
            overlay: SubtitleOverlayView(headless: true), presentsOverlay: false
        )
        let registered = try pipeline.configure(
            codecPrivate: header, codecName: stream.codecName,
            attachments: primaryAttachments, frameSize: size, storageSize: size
        )
        #expect(registered == ["NotoSans-Regular.ttf"])
        var reachedEOF = false
        for _ in 0..<4_096 {
            guard let packet = try input.readPacket(generation: 1) else {
                reachedEOF = true
                break
            }
            guard packet.streamIndex == stream.index else { continue }
            for event in try decoder.decode(packet) {
                #expect(pipeline.process(event: event, timelineOriginSeconds: input.mediaInfo.startTime))
            }
        }
        try #require(reachedEOF, "The short real-font fixture must reach EOF")
        return pipeline.renderedRegions(
            at: CMTime(seconds: 0.5, preferredTimescale: 1_000),
            viewport: CGRect(origin: .zero, size: size), videoSize: size
        )
    }

    private func fixtureURL() throws -> URL {
        let path = try #require(ProcessInfo.processInfo.environment["ILLIQUID_AUXILIARY_ATTACHMENT_FIXTURE"])
        try #require(FileManager.default.fileExists(atPath: path), "Required attachment fixture is missing")
        return URL(fileURLWithPath: path)
    }

    private func expectSameMetadata(_ expected: FFmpegMediaInfo, _ actual: FFmpegMediaInfo) {
        #expect(actual.url == expected.url)
        #expect(actual.containerName == expected.containerName)
        #expect(actual.duration.bitPattern == expected.duration.bitPattern)
        #expect(actual.startTime.bitPattern == expected.startTime.bitPattern)
        #expect(actual.durationStatus == expected.durationStatus)
        #expect(actual.startTimeStatus == expected.startTimeStatus)
        // Synthesized equality covers every stored FFmpegStreamInfo field.
        #expect(actual.streams == expected.streams)
        #expect(actual.chapters.map(\.title) == expected.chapters.map(\.title))
        #expect(actual.chapters.map { $0.start.bitPattern } == expected.chapters.map { $0.start.bitPattern })
        #expect(actual.chapters.map { $0.end.bitPattern } == expected.chapters.map { $0.end.bitPattern })
        #expect(actual.selectedVideoIndex == expected.selectedVideoIndex)
        #expect(actual.selectedAudioIndex == expected.selectedAudioIndex)
        #expect(actual.selectedSubtitleIndex == expected.selectedSubtitleIndex)
        #expect(actual.videoStreams == expected.videoStreams)
        #expect(actual.audioStreams == expected.audioStreams)
        #expect(actual.subtitleStreams == expected.subtitleStreams)
        #expect(actual.streams.map(\.displaySize) == expected.streams.map(\.displaySize))
        #expect(actual.streams.map(\.displayName) == expected.streams.map(\.displayName))
        #expect(actual.streams.map(\.subtitleCapability) == expected.streams.map(\.subtitleCapability))
    }

    private struct Reader {
        let info: FFmpegMediaInfo
        let readPacket: (Int) throws -> FFmpegPacket?
        let seek: (Double, Bool) throws -> Void
        let codecPrivateData: (Int32) -> Data?

        init(url: URL, useExecutor: Bool, policy: FFmpegAttachmentPolicy) throws {
            if useExecutor {
                let input = try FFmpegInputExecutor(url: url, attachmentPolicy: policy)
                info = input.mediaInfo
                readPacket = input.readPacket(generation:)
                seek = input.seek(to:exact:)
                codecPrivateData = input.codecPrivateData(streamIndex:)
            } else {
                let input = try FFmpegDemuxer(url: url, attachmentPolicy: policy)
                info = input.mediaInfo
                readPacket = input.readPacket(generation:)
                seek = input.seek(to:exact:)
                codecPrivateData = input.codecPrivateData(streamIndex:)
            }
        }
    }

    private struct Packet: Equatable {
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

    private func packets(_ read: () throws -> FFmpegPacket?) throws -> [Packet] {
        var result: [Packet] = []
        for _ in 0..<4_096 {
            guard let packet = try read() else { return result }
            result.append(Packet(packet))
        }
        Issue.record("The short regression fixture exceeded 4,096 packets without reaching EOF")
        return result
    }
}
