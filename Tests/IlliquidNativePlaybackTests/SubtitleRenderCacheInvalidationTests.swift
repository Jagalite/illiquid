import CoreMedia
import Foundation
import Testing
@testable import IlliquidNativePlayback

@Suite("Subtitle render cache invalidation")
struct SubtitleRenderCacheInvalidationTests {
    @Test func nothingCachedNeedsNoInvalidation() {
        #expect(!SubtitlePipeline.eventMayAffectCachedRender(
            startSeconds: 1, cachedMilliseconds: [nil, nil]))
    }

    @Test func eventDemuxedAheadKeepsCachedRegions() {
        #expect(!SubtitlePipeline.eventMayAffectCachedRender(
            startSeconds: 5, cachedMilliseconds: [1_000, 1_200]))
    }

    @Test func eventCoveringOrPrecedingCachedTimeInvalidates() {
        // A paused seek target rendered before its packet arrived.
        #expect(SubtitlePipeline.eventMayAffectCachedRender(
            startSeconds: 1, cachedMilliseconds: [1_000, nil]))
        #expect(SubtitlePipeline.eventMayAffectCachedRender(
            startSeconds: 0.5, cachedMilliseconds: [nil, 1_000]))
        // The later of the main and overlay timestamps decides.
        #expect(SubtitlePipeline.eventMayAffectCachedRender(
            startSeconds: 1.1, cachedMilliseconds: [1_000, 1_200]))
    }

    @Test func eventAtRoundingBoundaryInvalidates() {
        // 1.0004 s renders as 1000 ms; an event starting at 1.0006 s rounds
        // to 1001 ms at the clock but must not be missed.
        #expect(SubtitlePipeline.eventMayAffectCachedRender(
            startSeconds: 1.0006, cachedMilliseconds: [1_000]))
    }

    @Test func outOfRangeStartInvalidatesConservatively() {
        #expect(SubtitlePipeline.eventMayAffectCachedRender(
            startSeconds: 1e300, cachedMilliseconds: [1_000]))
    }

    @MainActor
    private static func pipeline(size: CGSize) throws -> SubtitlePipeline {
        let pipeline = try SubtitlePipeline(
            overlay: SubtitleOverlayView(headless: true), presentsOverlay: false
        )
        _ = try pipeline.configure(codecPrivate: nil, codecName: "subrip", attachments: [],
                                   frameSize: size, storageSize: size)
        return pipeline
    }

    @Test @MainActor func futurePacketDoesNotForceAFullRecopy() throws {
        let size = CGSize(width: 320, height: 180)
        let viewport = CGRect(origin: .zero, size: size)
        let pipeline = try Self.pipeline(size: size)
        pipeline.process(event: .init(assData: Data("0,0,Default,,0,0,0,,Current cue".utf8),
                                     presentationSeconds: 0, durationSeconds: 10, generation: 0))
        func snapshot(_ seconds: Double) -> SubtitlePipeline.PictureInPictureSubtitleSnapshot {
            pipeline.pictureInPictureSubtitleSnapshot(
                at: CMTime(seconds: seconds, preferredTimescale: 1_000),
                viewport: viewport, videoSize: size)
        }
        let first = snapshot(1)
        #expect(first.changed)
        #expect(!first.regions.isEmpty)
        let copies = pipeline.counters().bitmapCopies

        // Demuxed ahead of the clock: must not invalidate the visible cue.
        pipeline.process(event: .init(assData: Data("1,0,Default,,0,0,0,,Future cue".utf8),
                                     presentationSeconds: 50, durationSeconds: 1, generation: 0))
        #expect(!snapshot(1).changed)
        let next = snapshot(1.5)
        #expect(!next.changed)
        #expect(next.regions.count == first.regions.count)
        #expect(pipeline.counters().bitmapCopies == copies)

        // The original cue expires; a stale cache must not keep showing it.
        let gap = snapshot(20)
        #expect(gap.changed)
        #expect(gap.regions.isEmpty)

        // libass still reports the future cue once it becomes visible.
        let later = snapshot(50.5)
        #expect(later.changed)
        #expect(!later.regions.isEmpty)
    }

    @Test @MainActor func packetArrivingAfterPausedRenderStillAppears() throws {
        let size = CGSize(width: 320, height: 180)
        let viewport = CGRect(origin: .zero, size: size)
        let pipeline = try Self.pipeline(size: size)
        func regions() -> [ASSRenderedRegion] {
            pipeline.renderedRegions(at: CMTime(seconds: 1, preferredTimescale: 1_000),
                                     viewport: viewport, videoSize: size)
        }
        #expect(regions().isEmpty)
        pipeline.process(event: .init(assData: Data("0,0,Default,,0,0,0,,Late packet".utf8),
                                     presentationSeconds: 0.5, durationSeconds: 5, generation: 0))
        #expect(!regions().isEmpty)
    }
}
