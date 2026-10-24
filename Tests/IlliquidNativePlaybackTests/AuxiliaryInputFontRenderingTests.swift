import CoreMedia
import Foundation
import Testing
@testable import IlliquidNativePlayback

@Suite("Auxiliary input font rendering", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["ILLIQUID_AUXILIARY_FONT_RENDER_FIXTURE"] != nil,
                "Generate the video/audio/ASS fixture with the embedded Noto Sans font"))
struct AuxiliaryInputFontRenderingTests {
    private static let canvas = CGSize(width: 640, height: 360)
    private static let expectedFontNames = ["NotoSans-Regular.ttf"]

    @Test @MainActor
    func omittedSubtitleInputPreservesDecodedEventsAndEveryRenderedMask() throws {
        let url = try fixtureURL()
        // Each helper closes its executor before returning. The default input's
        // fonts and both inputs' codec-private/event bytes must remain owned.
        let primary = try decodedSubtitles(url: url)
        let auxiliary = try decodedSubtitles(url: url, fontAttachmentLoading: .omit)
        expectFixtureContract(primary)
        #expect(auxiliary.media.attachments.isEmpty)
        #expect(auxiliary.media.streams == primary.media.streams)
        #expect(auxiliary.stream == primary.stream)
        #expect(auxiliary.codecPrivate == primary.codecPrivate)
        #expect(auxiliary.events.map(EventSnapshot.init) == primary.events.map(EventSnapshot.init))

        let reference = try configuredPipeline(
            decoded: primary, fonts: primary.media.attachments
        )
        defer { reference.terminate() }
        let candidate = try configuredPipeline(
            decoded: auxiliary, fonts: primary.media.attachments
        )
        defer { candidate.terminate() }
        let expected = rendered(reference, at: 1)
        try #require(!expected.isEmpty, "The fixture must display its Noto Sans cue at one second")
        #expect(rendered(candidate, at: 1) == expected)

        let afterEnd = max(primary.media.duration, 3) + 1
        #expect(rendered(reference, at: afterEnd).isEmpty)
        #expect(rendered(candidate, at: afterEnd).isEmpty)
    }

    @Test(arguments: [-1.0, 0.0, 1.0]) @MainActor
    func sessionKeepsPrimaryFontsForMainAndPiPWithIndependentInputs(audioDelay: Double) throws {
        let url = try fixtureURL()
        let primary = try decodedSubtitles(url: url)
        let auxiliary = try decodedSubtitles(url: url, fontAttachmentLoading: .omit)
        expectFixtureContract(primary)
        #expect(auxiliary.media.attachments.isEmpty)

        let presentation = try NativePresentationCoordinator()
        defer { presentation.terminate() }
        let subtitles = try SubtitlePipeline(
            overlay: SubtitleOverlayView(headless: true), presentsOverlay: false
        )
        defer { subtitles.terminate() }
        let pipSubtitles = try SubtitlePipeline(
            overlay: SubtitleOverlayView(headless: true), presentsOverlay: false,
            memoryOwner: .pictureInPictureLibass
        )
        defer { pipSubtitles.terminate() }
        let session = try MediaSession(
            url: url, presentation: presentation, subtitles: subtitles,
            pictureInPictureSubtitles: pipSubtitles,
            audioDelay: audioDelay, selectedSubtitleIndex: primary.stream.index,
            preferHardware: false
        )
        defer {
            session.stop()
            #expect(session.waitForShutdown())
        }
        #expect(session.activeAudioStream != nil)
        #expect(session.activeSubtitleStream == primary.stream)
        #expect(session.audioDelay == audioDelay)
        #expect(session.mediaInfo.attachments == primary.media.attachments)
        #expect(session.registeredAttachmentNames == Self.expectedFontNames)
        #expect(session.pictureInPictureSubtitlePipeline === pipSubtitles)

        // Session construction configures both production pipelines from its
        // primary input. Feed independently decoded subtitle packets without
        // starting playback workers, isolating font ownership from AV timing.
        for event in auxiliary.events {
            #expect(subtitles.process(event: event, timelineOriginSeconds: auxiliary.media.startTime))
            #expect(pipSubtitles.process(event: event, timelineOriginSeconds: auxiliary.media.startTime))
        }
        let reference = try configuredPipeline(
            decoded: primary, fonts: primary.media.attachments
        )
        defer { reference.terminate() }
        let expected = rendered(reference, at: 1)
        try #require(!expected.isEmpty)
        #expect(rendered(subtitles, at: 1) == expected)
        let pip = pipSubtitles.pictureInPictureSubtitleSnapshot(
            at: CMTime(seconds: 1, preferredTimescale: 1_000),
            viewport: CGRect(origin: .zero, size: Self.canvas), videoSize: Self.canvas
        )
        #expect(pip.regions.map(RegionSnapshot.init) == expected)
    }

    private func fixtureURL() throws -> URL {
        let path = try #require(
            ProcessInfo.processInfo.environment["ILLIQUID_AUXILIARY_FONT_RENDER_FIXTURE"]
        )
        try #require(FileManager.default.fileExists(atPath: path))
        return URL(fileURLWithPath: path)
    }

    private func expectFixtureContract(_ decoded: DecodedSubtitles) {
        #expect(decoded.media.videoStreams.count == 1)
        #expect(decoded.media.audioStreams.count == 1)
        #expect(decoded.media.subtitleStreams.count == 1)
        #expect(decoded.stream.codecName == "ass")
        #expect(decoded.media.attachments.map(\.filename) == Self.expectedFontNames)
        #expect(decoded.media.attachments.allSatisfy { !$0.data.isEmpty })
        #expect(decoded.codecPrivate.map { String(decoding: $0, as: UTF8.self).contains("Noto Sans") } == true)
        #expect(!decoded.events.isEmpty)
        #expect(decoded.events.allSatisfy { $0.bitmapComposition == nil && !$0.assData.isEmpty })
    }

    private struct DecodedSubtitles {
        let media: FFmpegMediaInfo
        let stream: FFmpegStreamInfo
        let codecPrivate: Data?
        let events: [NativeDecodedSubtitleEvent]
    }

    private func decodedSubtitles(
        url: URL, fontAttachmentLoading: FontAttachmentLoading? = nil
    ) throws -> DecodedSubtitles {
        let input: FFmpegInputExecutor
        if let fontAttachmentLoading {
            input = try FFmpegInputExecutor(url: url, fontAttachmentLoading: fontAttachmentLoading)
        } else {
            input = try FFmpegInputExecutor(url: url)
        }
        let stream = try #require(input.mediaInfo.subtitleStreams.first)
        let parameters = try #require(try input.copyCodecParameters(streamIndex: stream.index))
        let decoder = try #require(try parameters.withUnsafePointer {
            try SubtitleDecoder(parameters: $0, stream: stream)
        })
        var events: [NativeDecodedSubtitleEvent] = []
        for _ in 0..<4_096 {
            guard let packet = try input.readPacket(generation: 0) else {
                return DecodedSubtitles(
                    media: input.mediaInfo, stream: stream,
                    codecPrivate: input.codecPrivateData(streamIndex: stream.index), events: events
                )
            }
            if packet.streamIndex == stream.index {
                events.append(contentsOf: try decoder.decode(packet))
            }
        }
        throw PresentationError("The short font-rendering fixture did not reach EOF within 4,096 packets")
    }

    @MainActor
    private func configuredPipeline(
        decoded: DecodedSubtitles, fonts: [FontAttachment]
    ) throws -> SubtitlePipeline {
        let pipeline = try SubtitlePipeline(
            overlay: SubtitleOverlayView(headless: true), presentsOverlay: false
        )
        let registered = try pipeline.configure(
            codecPrivate: decoded.codecPrivate, codecName: decoded.stream.codecName,
            attachments: fonts, frameSize: Self.canvas, storageSize: Self.canvas
        )
        #expect(registered == Self.expectedFontNames)
        for event in decoded.events {
            #expect(pipeline.process(event: event, timelineOriginSeconds: decoded.media.startTime))
        }
        return pipeline
    }

    private func rendered(_ pipeline: SubtitlePipeline, at seconds: Double) -> [RegionSnapshot] {
        pipeline.renderedRegions(
            at: CMTime(seconds: seconds, preferredTimescale: 1_000),
            viewport: CGRect(origin: .zero, size: Self.canvas), videoSize: Self.canvas
        ).map(RegionSnapshot.init)
    }

    private struct EventSnapshot: Equatable {
        let data: Data
        let startBits: UInt64
        let durationBits: UInt64
        let generation: Int
        let hasBitmap: Bool

        init(_ event: NativeDecodedSubtitleEvent) {
            data = event.assData
            startBits = event.presentationSeconds.bitPattern
            durationBits = event.durationSeconds.bitPattern
            generation = event.generation
            hasBitmap = event.bitmapComposition != nil
        }
    }

    private struct RegionSnapshot: Equatable {
        let bitmap: Data
        let color: UInt32
        let frame: CGRect
        let stride: Int
        let bitmapSize: CGSize?
        let isPremultipliedBGRA: Bool

        init(_ region: ASSRenderedRegion) {
            bitmap = region.bitmap
            color = region.color
            frame = region.frame
            stride = region.stride
            bitmapSize = region.bitmapSize
            isPremultipliedBGRA = region.isPremultipliedBGRA
        }
    }
}
