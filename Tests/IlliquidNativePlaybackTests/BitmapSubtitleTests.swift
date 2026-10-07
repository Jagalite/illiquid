import CFFmpeg
import CoreGraphics
import Foundation
import CoreMedia
import QuartzCore
import Testing
import IlliquidCore
@testable import IlliquidNativePlayback

@Suite("Bitmap subtitle data and lifetime")
struct BitmapSubtitleTests {
    private static let fixtureDirectory = ProcessInfo.processInfo.environment["ILLIQUID_BITMAP_FIXTURE_DIR"].map {
        URL(fileURLWithPath: $0, isDirectory: true)
    }
    private func composition(_ value: UInt8, duration: Double? = nil) -> NativeBitmapSubtitleComposition {
        .init(regions: [.init(pixels: Data([value, 0, 0, 255]), frame: .init(x: 1, y: 2, width: 1, height: 1), isForced: true)],
              canvasSize: .init(width: 100, height: 100), duration: duration, memoryLease: nil)
    }

    @Test func indefiniteFiniteAndClearSetsDoNotResurrectOldCaptions() {
        var timeline = BitmapSubtitleTimeline()
        let inserted0 = timeline.insert(composition(1), at: 1, generation: 0)
        #expect(inserted0)
        #expect(timeline.composition(at: 100)?.value.regions.first?.pixels.first == 1)
        let inserted1 = timeline.insert(composition(2, duration: 2), at: 101, generation: 0)
        #expect(inserted1)
        #expect(timeline.composition(at: 102)?.value.regions.first?.pixels.first == 2)
        #expect(timeline.composition(at: 103) == nil)
        let clear = NativeBitmapSubtitleComposition(regions: [], canvasSize: .init(width: 100, height: 100), duration: nil, memoryLease: nil)
        let inserted2 = timeline.insert(clear, at: 104, generation: 0)
        #expect(inserted2)
        #expect(timeline.composition(at: 105)?.value.regions.isEmpty == true)
        #expect(timeline.composition(at: 0) == nil)
    }

    @Test func pruningRetainsSpanningDisplayAndSeekRejectsLateGeneration() {
        var timeline = BitmapSubtitleTimeline()
        timeline.insert(composition(1), at: 1, generation: 0)
        timeline.insert(composition(2), at: 5, generation: 0)
        timeline.insert(composition(3), at: 200, generation: 0)
        timeline.prune(before: 100)
        #expect(timeline.retainedBytes == 8)
        #expect(timeline.composition(at: 150)?.value.regions.first?.pixels.first == 2)
        timeline.reset(generation: 1)
        #expect(timeline.retainedBytes == 0)
        timeline.insert(composition(9), at: 0, generation: 0)
        #expect(timeline.composition(at: 1) == nil)
        timeline.insert(composition(4), at: 0, generation: 1)
        #expect(timeline.composition(at: 1)?.value.regions.first?.pixels.first == 4)
    }

    @Test func boundedTimelineAcceptsReplacementButRejectsGrowth() {
        var timeline = BitmapSubtitleTimeline(maximumEntries: 2, maximumBytes: 8)
        let inserted3 = timeline.insert(composition(1), at: 1, generation: 0)
        #expect(inserted3)
        let inserted4 = timeline.insert(composition(2), at: 2, generation: 0)
        #expect(inserted4)
        let inserted5 = timeline.insert(composition(3), at: 3, generation: 0)
        #expect(!inserted5)
        let inserted6 = timeline.insert(composition(4), at: 2, generation: 0)
        #expect(inserted6)
        #expect(timeline.retainedBytes == 8)
        let inserted7 = timeline.insert(composition(5), at: .nan, generation: 0)
        #expect(!inserted7)
    }

    @Test func paletteConversionPremultipliesAlphaAndHonorsRowStride() {
        var indices: [UInt8] = [0, 1, 99, 2, 3, 99]
        var palette: [UInt32] = [0xFFFF0000, 0x8000FF00, 0x000000FF, 0xFFFFFFFF]
        var output = [UInt8](repeating: 0, count: 16)
        indices.withUnsafeMutableBufferPointer { input in
            palette.withUnsafeMutableBytes { colors in
                var rect = AVSubtitleRect()
                rect.type = SUBTITLE_BITMAP
                rect.w = 2
                rect.h = 2
                rect.nb_colors = 4
                rect.linesize.0 = 3
                rect.data.0 = input.baseAddress
                rect.data.1 = colors.bindMemory(to: UInt8.self).baseAddress
                #expect(illiquid_subtitle_rect_copy_bgra(&rect, &output, output.count) == 0)
                #expect(output == [0, 0, 255, 255, 0, 128, 0, 128, 0, 0, 0, 0, 255, 255, 255, 255])
                rect.nb_colors = 2
                #expect(illiquid_subtitle_rect_copy_bgra(&rect, &output, output.count) < 0)
                rect.nb_colors = 4
                #expect(illiquid_subtitle_rect_copy_bgra(&rect, &output, 15) < 0)
                rect.linesize.0 = 1
                #expect(illiquid_subtitle_rect_copy_bgra(&rect, &output, output.count) < 0)
            }
        }
    }

    @Test func generatedPGSDecodesPalettePlacementForcedFlagAndClear() throws {
        var parameters: UnsafeMutablePointer<AVCodecParameters>? = avcodec_parameters_alloc()
        defer { avcodec_parameters_free(&parameters) }
        _ = try #require(parameters)
        parameters!.pointee.codec_type = AVMEDIA_TYPE_SUBTITLE
        parameters!.pointee.codec_id = AV_CODEC_ID_HDMV_PGS_SUBTITLE
        let stream = FFmpegStreamInfo(index: 0, kind: .subtitle, codecID: Int32(AV_CODEC_ID_HDMV_PGS_SUBTITLE.rawValue),
            codecName: "hdmv_pgs_subtitle", title: nil, language: nil, timeBase: .init(numerator: 1, denominator: 1_000_000),
            duration: nil, disposition: 0, codedSize: nil, pixelAspectRatio: nil, averageFrameRate: nil,
            sampleRate: nil, channelCount: nil, channelLayout: nil, rotationDegrees: 0, isMirrored: false, interlaceMode: .progressive)
        let budget = SubtitleMemoryBudget(limitBytes: 1_024)
        let decoder = try SubtitleDecoder(parameters: parameters!, stream: stream, memoryBudget: budget)
        func segment(_ type: UInt8, _ bytes: [UInt8]) -> [UInt8] {
            [type, UInt8(bytes.count >> 8), UInt8(bytes.count & 255)] + bytes
        }
        let pcs: [UInt8] = [5, 0, 2, 208, 16, 0, 1, 128, 0, 0, 1, 0, 1, 0, 64, 0, 10, 0, 20]
        let palette: [UInt8] = [0, 0, 0, 16, 128, 128, 0, 1, 235, 128, 128, 255, 2, 100, 128, 128, 128]
        let object: [UInt8] = [0, 1, 0, 192, 0, 0, 12, 0, 2, 0, 2, 1, 2, 0, 0, 2, 1, 0, 0]
        let bytes = segment(0x16, pcs) + segment(0x14, palette) + segment(0x15, object) + segment(0x80, [])
        var events = try decoder.decode(packet(bytes, at: 2))
        #expect(events.count == 1)
        #expect(events.first?.presentationSeconds == 2)
        #expect(events.first?.bitmapComposition?.duration == nil)
        #expect(events.first?.bitmapComposition?.canvasSize == CGSize(width: 1_280, height: 720))
        #expect(events.first?.bitmapComposition?.regions.first?.frame == CGRect(x: 10, y: 20, width: 2, height: 2))
        #expect(events.first?.bitmapComposition?.regions.first?.isForced == true)
        #expect(Array(events[0].bitmapComposition!.regions[0].pixels.prefix(4)) == [255, 255, 255, 255])
        #expect(budget.snapshot.reservedBytes == 16)
        events.removeAll()
        #expect(budget.snapshot.reservedBytes == 0)
        let clearPCS: [UInt8] = [5, 0, 2, 208, 16, 0, 2, 0, 0, 0, 0]
        let cleared = try decoder.decode(packet(segment(0x16, clearPCS) + segment(0x80, []), at: 5))
        #expect(cleared.first?.bitmapComposition?.regions.isEmpty == true)
        #expect(cleared.first?.presentationSeconds == 5)
    }

    @Test @MainActor func bitmapAtlasScalesSourcePixelsWithoutTreatingThemAsGlyphMasks() throws {
        let pixels = Data(repeating: 128, count: 16)
        let composition = NativeBitmapSubtitleComposition(
            regions: [.init(pixels: pixels, frame: .init(x: 1, y: 1, width: 2, height: 2), isForced: false)],
            canvasSize: .init(width: 4, height: 4), duration: nil, memoryLease: nil)
        let regions = composition.renderedRegions(in: .init(x: 0, y: 0, width: 8, height: 8))
        let frame = try #require(ASSSubtitleFramePacker().prepare(regions: regions,
            canvasSize: .init(width: 8, height: 8), strategy: .metalR8Atlas))
        #expect(frame.strategy == .metalBGRA)
        #expect(frame.quads.first?.source.size == CGSize(width: 2, height: 2))
        #expect(frame.quads.first?.destination == CGRect(x: 2, y: 2, width: 4, height: 4))
        #expect(frame.metrics.copiedBytes == 16)
        let renderer = try MetalASSSubtitleRenderer(layer: CAMetalLayer())
        let rendered = try #require(renderer.renderOffscreen(frame))
        let center = (3 * 8 + 3) * 4
        #expect(Array(rendered[center..<center + 4]) == [128, 128, 128, 128])
        #expect(Array(rendered.prefix(4)) == [0, 0, 0, 0])
    }

    @Test @MainActor func bitmapPipelineExpiryAndGenerationChangesDoNotCallLibass() throws {
        let pipeline = try SubtitlePipeline(overlay: SubtitleOverlayView(headless: true), presentsOverlay: false)
        let size = CGSize(width: 100, height: 100)
        let viewport = CGRect(origin: .zero, size: size)
        _ = try pipeline.configure(codecPrivate: nil, codecName: "hdmv_pgs_subtitle", attachments: [], frameSize: size, storageSize: size)
        let event = NativeDecodedSubtitleEvent(assData: Data(), presentationSeconds: 1, durationSeconds: 2,
                                               generation: 0, bitmapComposition: composition(128, duration: 2))
        #expect(pipeline.process(event: event))
        #expect(pipeline.renderedRegions(at: .zero, viewport: viewport, videoSize: size).isEmpty)
        #expect(pipeline.renderedRegions(at: CMTime(seconds: 2, preferredTimescale: 1_000), viewport: viewport, videoSize: size).count == 1)
        #expect(pipeline.renderedRegions(at: CMTime(seconds: 3, preferredTimescale: 1_000), viewport: viewport, videoSize: size).isEmpty)
        pipeline.clear(generation: 1)
        #expect(pipeline.process(event: event))
        #expect(pipeline.renderedRegions(at: CMTime(seconds: 2, preferredTimescale: 1_000), viewport: viewport, videoSize: size).isEmpty)
        #expect(pipeline.counters().libassFrames == 0)
    }

    @Test(.enabled(if: fixtureDirectory != nil, "Generate fixtures with Scripts/generate-bitmap-subtitle-fixtures.py"),
          arguments: ["generated-pgs.mkv", "generated-dvd.mkv", "generated-dvb.mkv"])
    func generatedContainersRestoreSpanningCaptionsAndClearAtSeekTargets(name: String) throws {
        let directory = try #require(Self.fixtureDirectory)
        let input = try FFmpegDemuxer(url: directory.appendingPathComponent(name))
        let stream = try #require(input.mediaInfo.subtitleStreams.first)
        let parameters = try #require(input.codecParameters(streamIndex: stream.index))
        let decoder = try SubtitleDecoder(parameters: parameters, stream: stream)
        for (target, shouldShow) in [(8.0, true), (16.0, false), (21.0, true), (8.0, true)] {
            try decoder.flush()
            var timeline = BitmapSubtitleTimeline()
            let packets = try input.activeSubtitlePackets(streamIndex: stream.index, at: target, generation: 0)
            for packet in packets {
                for event in try decoder.decode(packet) {
                    let composition = try #require(event.bitmapComposition)
                    timeline.insert(composition, at: event.presentationSeconds, generation: 0)
                }
            }
            #expect((timeline.composition(at: target)?.value.regions.isEmpty == false) == shouldShow)
        }
    }

    @Test @MainActor func forcedBitmapFilterChangesCachedPresentationAtTheSameTime() throws {
        let pipeline = try SubtitlePipeline(overlay: SubtitleOverlayView(headless: true), presentsOverlay: false)
        let size = CGSize(width: 100, height: 100)
        let viewport = CGRect(origin: .zero, size: size)
        _ = try pipeline.configure(codecPrivate: nil, codecName: "hdmv_pgs_subtitle", attachments: [], frameSize: size, storageSize: size)
        let forced = composition(1).regions[0]
        let full = NativeBitmapSubtitleRegion(pixels: Data([2, 0, 0, 255]), frame: forced.frame, isForced: false)
        let mixed = NativeBitmapSubtitleComposition(regions: [forced, full], canvasSize: size, duration: nil, memoryLease: nil)
        #expect(pipeline.process(event: .init(assData: Data(), presentationSeconds: 0, durationSeconds: 0,
                                             generation: 0, bitmapComposition: mixed)))
        #expect(pipeline.renderedRegions(at: .zero, viewport: viewport, videoSize: size).count == 2)
        pipeline.forcesBitmapEventsOnly = true
        let filtered = pipeline.renderedRegions(at: .zero, viewport: viewport, videoSize: size)
        #expect(filtered.count == 1)
        #expect(filtered.first?.bitmap.first == 1)
        pipeline.forcesBitmapEventsOnly = false
        #expect(pipeline.renderedRegions(at: .zero, viewport: viewport, videoSize: size).count == 2)
    }

    @Test(.enabled(if: fixtureDirectory != nil, "Generate fixtures with Scripts/generate-bitmap-subtitle-fixtures.py"),
          arguments: [false, true])
    @MainActor func bitmapForcedPolicyDistinguishesAutomaticAndExplicitSelection(explicit: Bool) throws {
        let directory = try #require(Self.fixtureDirectory)
        let presentation = try NativePresentationCoordinator()
        defer { presentation.terminate() }
        let main = try SubtitlePipeline(overlay: SubtitleOverlayView(headless: true), presentsOverlay: false)
        let pip = try SubtitlePipeline(overlay: SubtitleOverlayView(headless: true), presentsOverlay: false)
        let url = directory.appendingPathComponent("generated-pgs.mkv")
        let input = try FFmpegDemuxer(url: url)
        let stream = try #require(input.mediaInfo.subtitleStreams.first)
        let source: NativeSubtitleSource = explicit ? .embedded(streamIndex: stream.index) : .automaticEmbedded
        let session = try MediaSession(url: url, presentation: presentation, subtitles: main,
            pictureInPictureSubtitles: pip, trackSelectionPreferences: .init(subtitles: .forcedOnly),
            subtitleSource: source, preferHardware: false)
        defer { session.stop() }
        #expect(main.forcesBitmapEventsOnly == !explicit)
        #expect(pip.forcesBitmapEventsOnly == !explicit)
    }

    @Test func acquisitionParsingRejectsTruncatedSegmentsAndRecognizesEpochs() {
        #expect(!PGSSubtitlePacket.isAcquisition(Data([0x16, 0, 11, 0])))
        #expect(!PGSSubtitlePacket.isAcquisition(Data([0x80, 0, 0])))
        #expect(PGSSubtitlePacket.isAcquisition(Data([0x16, 0, 11, 5, 0, 2, 208, 16, 0, 1, 128, 0, 0, 0])))
    }

    @Test(.enabled(if: fixtureDirectory != nil, "Generate fixtures with Scripts/generate-bitmap-subtitle-fixtures.py"),
          arguments: ["generated-pgs.mkv", "generated-dvd.mkv", "generated-dvb.mkv"])
    @MainActor func nativeSessionDeliversBitmapCaptionsAcrossPausedSeeks(name: String) async throws {
        let directory = try #require(Self.fixtureDirectory)
        let presentation = try NativePresentationCoordinator()
        defer { presentation.terminate() }
        let main = try SubtitlePipeline(overlay: SubtitleOverlayView(headless: true), presentsOverlay: false)
        let pip = try SubtitlePipeline(overlay: SubtitleOverlayView(headless: true), presentsOverlay: false)
        let session = try MediaSession(url: directory.appendingPathComponent(name), presentation: presentation,
                                       subtitles: main, pictureInPictureSubtitles: pip, preferHardware: false)
        defer { session.stop() }
        #expect(session.activeSubtitleStream?.subtitleCapability == .bitmap)
        session.start(rate: 0)
        for _ in 0..<300 where main.eventCount == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(main.eventCount > 0)
        let size = CGSize(width: 1_280, height: 720)
        let viewport = CGRect(origin: .zero, size: size)
        for target in [8.0, 21.0, 8.0] {
            let previous = main.eventCount
            _ = session.seek(to: target, exact: true, resumeRate: 0)
            for _ in 0..<300 where main.eventCount == previous { try await Task.sleep(for: .milliseconds(10)) }
            let time = CMTime(seconds: target, preferredTimescale: 1_000)
            #expect(!main.renderedRegions(at: time, viewport: viewport, videoSize: size).isEmpty)
            for _ in 0..<100 where pip.renderedRegions(at: time, viewport: viewport, videoSize: size).isEmpty {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(!pip.renderedRegions(at: time, viewport: viewport, videoSize: size).isEmpty)
        }
        session.stop()
        let stopped = await Task.detached { session.waitForShutdown() }.value
        #expect(stopped)
    }

    @Test(arguments: [UInt8(0), UInt8(128)])
    func authoredDVBPagePreservesPalettePlacementTimeoutAndClear(transparency: UInt8) throws {
        var parameters = avcodec_parameters_alloc()
        let pointer = try #require(parameters)
        defer { avcodec_parameters_free(&parameters) }
        pointer.pointee.codec_type = AVMEDIA_TYPE_SUBTITLE
        pointer.pointee.codec_id = AV_CODEC_ID_DVB_SUBTITLE
        let extra = try #require(av_mallocz(4 + Int(AV_INPUT_BUFFER_PADDING_SIZE)))
            .assumingMemoryBound(to: UInt8.self)
        extra[1] = 1 // Composition page 1; ancillary page 2.
        extra[3] = 2
        pointer.pointee.extradata = extra
        pointer.pointee.extradata_size = 4
        let stream = FFmpegStreamInfo(index: 0, kind: .subtitle, codecID: Int32(AV_CODEC_ID_DVB_SUBTITLE.rawValue),
            codecName: "dvb_subtitle", title: nil, language: nil, timeBase: .init(numerator: 1, denominator: 1_000_000),
            duration: nil, disposition: 0, codedSize: nil, pixelAspectRatio: nil, averageFrameRate: nil,
            sampleRate: nil, channelCount: nil, channelLayout: nil, rotationDegrees: 0, isMirrored: false, interlaceMode: .progressive)
        let budget = SubtitleMemoryBudget(limitBytes: 1_024)
        let decoder = try SubtitleDecoder(parameters: pointer, stream: stream, memoryBudget: budget)
        let definition = dvbSegment(0x14, [0, 4, 255, 2, 207])
        let page = dvbSegment(0x10, [2, 4, 1, 0, 0, 10, 0, 20])
        // An object supplies one row for each field, using palette index 1.
        let region = dvbSegment(0x11, [1, 8, 0, 2, 0, 2, 12, 0, 1, 0, 0, 1, 0, 0, 0, 0])
        let object = dvbSegment(0x13, [0, 1, 0, 0, 6, 0, 6, 0x12, 1, 1, 0, 0, 0xF0, 0x12, 1, 1, 0, 0, 0xF0])
        let palette = dvbSegment(0x12, [0, 0, 1, 0x21, 235, 128, 128, transparency])
        let end = dvbSegment(0x80, [])
        let events = try decoder.decode(packet(definition + page + region + palette + object + end, at: 2))
        let event = try #require(events.first)
        let bitmap = try #require(event.bitmapComposition)
        #expect(event.presentationSeconds == 2)
        #expect(bitmap.duration == 2)
        #expect(bitmap.canvasSize == CGSize(width: 1_280, height: 720))
        #expect(bitmap.regions.first?.frame == CGRect(x: 10, y: 20, width: 2, height: 2))
        #expect(bitmap.regions.first?.isForced == false)
        #expect(bitmap.regions.first?.pixels == Data(repeating: 255 - transparency, count: 16))
        #expect(budget.snapshot.reservedBytes == 16)
        var timeline = BitmapSubtitleTimeline()
        timeline.insert(bitmap, at: event.presentationSeconds, generation: 0)
        #expect(timeline.composition(at: 3.99) != nil)
        #expect(timeline.composition(at: 4) == nil)
        let unrelated = dvbSegment(0x10, [2, 0x10], pageID: 3) + dvbSegment(0x80, [], pageID: 3)
        #expect(try decoder.decode(packet(unrelated, at: 3)).isEmpty)
        let clear = try decoder.decode(packet(dvbSegment(0x10, [2, 0x10]) + end, at: 3))
        let cleared = try #require(clear.first?.bitmapComposition)
        #expect(cleared.regions.isEmpty)
        timeline.insert(cleared, at: 3, generation: 0)
        #expect(timeline.composition(at: 3.5)?.value.regions.isEmpty == true)
        try decoder.flush()
        // The clear page used version 1. Reusing that version for a seek's new
        // page must not leave the old empty display list cached in FFmpeg.
        let repeatedVersion = dvbSegment(0x10, [2, 0x14, 1, 0, 0, 10, 0, 20])
        let restored = try decoder.decode(packet(definition + repeatedVersion + region + palette + object + end, at: 1))
        #expect(restored.first?.bitmapComposition?.regions.count == 1)
    }

    @Test func dvbAcquisitionRequiresCompleteMatchingPageAndValidState() {
        for state in [UInt8(0), 1, 2, 3] {
            let bytes = dvbSegment(0x10, [2, state << 2])
            #expect(DVBSubtitlePacket.isAcquisition(Data(bytes), compositionPageID: 1) == (state == 1 || state == 2))
            #expect(!DVBSubtitlePacket.isAcquisition(Data(bytes), compositionPageID: 2))
            for count in 0..<bytes.count {
                #expect(!DVBSubtitlePacket.isAcquisition(Data(bytes.prefix(count)), compositionPageID: nil))
            }
        }
        #expect(!DVBSubtitlePacket.isAcquisition(Data(dvbSegment(0x11, [2, 4])), compositionPageID: nil))
    }

    private func dvbSegment(_ kind: UInt8, _ bytes: [UInt8], pageID: UInt16 = 1) -> [UInt8] {
        [0x0F, kind, UInt8(pageID >> 8), UInt8(pageID & 255), UInt8(bytes.count >> 8), UInt8(bytes.count & 255)] + bytes
    }

    private func packet(_ bytes: [UInt8], at seconds: Int64) throws -> FFmpegPacket {
        var raw: UnsafeMutablePointer<AVPacket>? = av_packet_alloc()
        defer { av_packet_free(&raw) }
        _ = try #require(raw)
        try checkFFmpeg(av_new_packet(raw, Int32(bytes.count)), operation: "Allocate generated subtitle packet")
        bytes.withUnsafeBytes { source in raw!.pointee.data.update(from: source.bindMemory(to: UInt8.self).baseAddress!, count: bytes.count) }
        raw!.pointee.pts = seconds * 1_000_000
        raw!.pointee.dts = raw!.pointee.pts
        return try FFmpegPacket(moving: raw!, timeBase: .init(num: 1, den: 1_000_000), generation: 0)
    }
}
