import CoreMedia
import Foundation
import Testing
@testable import IlliquidNativePlayback

@Suite("Auxiliary font payload playback integration", .enabled(
    if: ProcessInfo.processInfo.environment["ILLIQUID_AUXILIARY_FONT_PLAYBACK_FIXTURE"] != nil,
    "Generate the Noto Sans video/audio/ASS fixture"
))
struct AuxiliaryFontPlaybackTests {
    @Test @MainActor
    func independentReadersPreserveMainAndPiPSubtitleRendering() throws {
        let path = try #require(
            ProcessInfo.processInfo.environment["ILLIQUID_AUXILIARY_FONT_PLAYBACK_FIXTURE"])
        let url = URL(fileURLWithPath: path)
        let source = try FFmpegDemuxer(url: url)
        let stream = try #require(source.mediaInfo.subtitleStreams.first)
        #expect(stream.codecName == "ass")
        #expect(!source.mediaInfo.videoStreams.isEmpty)
        #expect(!source.mediaInfo.audioStreams.isEmpty)
        #expect(source.mediaInfo.attachments.map(\.filename) == ["NotoSans-Regular.ttf"])
        #expect(source.mediaInfo.attachments.allSatisfy { !$0.data.isEmpty })

        let main = try SubtitlePipeline(overlay: SubtitleOverlayView(), presentsOverlay: false)
        let pip = try SubtitlePipeline(
            overlay: SubtitleOverlayView(), presentsOverlay: false,
            memoryOwner: .pictureInPictureLibass)
        let presentation = try NativePresentationCoordinator()
        defer { presentation.terminate() }
        let session = try MediaSession(
            url: url, presentation: presentation, subtitles: main,
            pictureInPictureSubtitles: pip, audioDelay: 0.25,
            selectedSubtitleIndex: stream.index, preferHardware: false)
        defer { session.stop() }
        #expect(session.activeSubtitleStream?.index == stream.index)
        #expect(session.activeAudioStream != nil)
        #expect(session.audioDelay == 0.25)
        #expect(session.mediaInfo.attachments == source.mediaInfo.attachments)
        #expect(session.registeredAttachmentNames == ["NotoSans-Regular.ttf"])

        // Session construction configures both real libass contexts from the
        // primary input. Independently decode the same packets without loading
        // another Swift font inventory and compare complete rendered payloads.
        let input = try FFmpegInputExecutor(url: url, loadFontAttachments: false)
        #expect(input.mediaInfo.attachments.isEmpty)
        #expect(input.mediaInfo.streams == source.mediaInfo.streams)
        let parameters = try #require(input.copyCodecParameters(streamIndex: stream.index))
        let decoder = try #require(parameters.withUnsafePointer {
            try SubtitleDecoder(parameters: $0, stream: stream)
        })
        let size = try #require(source.mediaInfo.videoStreams.first?.codedSize)
        let reference = try SubtitlePipeline(overlay: SubtitleOverlayView(), presentsOverlay: false)
        let registered = try reference.configure(
            codecPrivate: source.codecPrivateData(streamIndex: stream.index),
            codecName: stream.codecName, attachments: source.mediaInfo.attachments,
            frameSize: size, storageSize: size)
        #expect(registered == session.registeredAttachmentNames)
        var eventCount = 0
        var reachedEOF = false
        for _ in 0..<1_000 {
            guard let packet = try input.readPacket(generation: 0) else {
                reachedEOF = true
                break
            }
            guard packet.streamIndex == stream.index else { continue }
            for event in try decoder.decode(packet) {
                eventCount += 1
                for pipeline in [main, pip, reference] {
                    #expect(pipeline.process(event: event,
                        timelineOriginSeconds: source.mediaInfo.startTime))
                }
            }
        }
        #expect(reachedEOF)
        #expect(eventCount > 0)
        let time = CMTime(seconds: 1.2, preferredTimescale: 1_000)
        let viewport = CGRect(origin: .zero, size: size)
        let expected = reference.renderedRegions(at: time, viewport: viewport, videoSize: size)
        #expect(!expected.isEmpty)
        for pipeline in [main, pip] {
            let actual = pipeline.renderedRegions(at: time, viewport: viewport, videoSize: size)
            #expect(actual.count == expected.count)
            for (lhs, rhs) in zip(actual, expected) {
                #expect(lhs.bitmap == rhs.bitmap)
                #expect(lhs.frame == rhs.frame)
                #expect(lhs.color == rhs.color)
                #expect(lhs.stride == rhs.stride)
                #expect(lhs.bitmapSize == rhs.bitmapSize)
                #expect(lhs.isPremultipliedBGRA == rhs.isPremultipliedBGRA)
            }
        }
    }
}
