import AppKit
import Foundation
import Testing
@testable import IlliquidNativePlayback

@Suite("Subtitle GPU resource authority", .serialized)
struct SubtitleGPUResourceAuthorityTests {
    @Test @MainActor
    func candidatePreparationAndTerminationDoNotRetireTheSharedRenderer() throws {
        let overlay = SubtitleOverlayView()
        let committed = try SubtitlePipeline(overlay: overlay)
        defer { committed.terminate() }
        let original = try #require(overlay.resourcePoolSnapshotForTesting)

        // Runtime candidates share the committed pipeline's overlay, then
        // relinquish presentation authority before loading their private source.
        let candidate = try SubtitlePipeline(overlay: overlay)
        candidate.setPresentationAuthorityEnabled(false)
        #expect(overlay.resourcePoolSnapshotForTesting?.sourceGeneration == original.sourceGeneration)

        let size = CGSize(width: 640, height: 360)
        _ = try candidate.configure(
            codecPrivate: nil,
            codecName: "ass",
            attachments: [],
            frameSize: size,
            storageSize: size
        )
        #expect(overlay.resourcePoolSnapshotForTesting?.sourceGeneration == original.sourceGeneration)

        try candidate.installExternal(data: Data(Self.caption.utf8))
        #expect(overlay.resourcePoolSnapshotForTesting?.sourceGeneration == original.sourceGeneration)

        candidate.clear(generation: 7)
        candidate.isEnabled = false
        #expect(overlay.resourcePoolSnapshotForTesting?.sourceGeneration == original.sourceGeneration)

        candidate.terminate()
        #expect(committed.hasPresentationAuthorityForTesting)
        #expect(overlay.resourcePoolSnapshotForTesting?.sourceGeneration == original.sourceGeneration)
    }

    @Test @MainActor
    func activationRetiresOnceAndOrdinaryClearsPreserveSourceReuse() throws {
        let overlay = SubtitleOverlayView()
        let pipeline = try SubtitlePipeline(overlay: overlay)
        defer { pipeline.terminate() }
        let original = try #require(overlay.resourcePoolSnapshotForTesting)
        pipeline.setPresentationAuthorityEnabled(false)

        pipeline.setPresentationAuthorityEnabled(true)
        let activatedGeneration = original.sourceGeneration + 1
        #expect(overlay.resourcePoolSnapshotForTesting?.sourceGeneration == activatedGeneration)

        pipeline.setPresentationAuthorityEnabled(true)
        #expect(overlay.resourcePoolSnapshotForTesting?.sourceGeneration == activatedGeneration)

        // MediaSession.seek uses this call. A seek can immediately supersede the
        // activation's queued clear; resource retirement must already have run.
        pipeline.clear(generation: 1)
        pipeline.clear(generation: 2)
        pipeline.clear()
        #expect(overlay.resourcePoolSnapshotForTesting?.sourceGeneration == activatedGeneration)

        pipeline.isEnabled = false
        pipeline.isEnabled = true
        #expect(overlay.resourcePoolSnapshotForTesting?.sourceGeneration == activatedGeneration)
    }

    @Test @MainActor
    func authorityTransferAndRollbackRetireOnlyTheNewlyActivatedSource() throws {
        let overlay = SubtitleOverlayView()
        let committed = try SubtitlePipeline(overlay: overlay)
        let replacement = try SubtitlePipeline(overlay: overlay)
        defer { committed.terminate() }
        let original = try #require(overlay.resourcePoolSnapshotForTesting)
        replacement.setPresentationAuthorityEnabled(false)
        #expect(overlay.resourcePoolSnapshotForTesting?.sourceGeneration == original.sourceGeneration)

        committed.setPresentationAuthorityEnabled(false)
        #expect(overlay.resourcePoolSnapshotForTesting?.sourceGeneration == original.sourceGeneration)
        replacement.setPresentationAuthorityEnabled(true)
        #expect(overlay.resourcePoolSnapshotForTesting?.sourceGeneration == original.sourceGeneration + 1)

        // A revoked source may still be stopped or invalidated while its
        // replacement owns the overlay.
        committed.clear(generation: 3)
        #expect(overlay.resourcePoolSnapshotForTesting?.sourceGeneration == original.sourceGeneration + 1)

        replacement.setPresentationAuthorityEnabled(false)
        #expect(overlay.resourcePoolSnapshotForTesting?.sourceGeneration == original.sourceGeneration + 1)
        committed.setPresentationAuthorityEnabled(true)
        #expect(overlay.resourcePoolSnapshotForTesting?.sourceGeneration == original.sourceGeneration + 2)

        replacement.clear()
        replacement.terminate()
        committed.setPresentationAuthorityEnabled(true)
        #expect(committed.hasPresentationAuthorityForTesting)
        #expect(overlay.resourcePoolSnapshotForTesting?.sourceGeneration == original.sourceGeneration + 2)
    }

    @Test @MainActor
    func nonpresentingPipelineDoesNotRetireOverlayResourcesOnActivation() throws {
        // Give this nonpresenting pipeline a real renderer so a missing
        // presentsOverlay guard is observable without acquiring a drawable.
        let overlay = SubtitleOverlayView()
        let pipeline = try SubtitlePipeline(
            overlay: overlay,
            presentsOverlay: false,
            memoryOwner: .pictureInPictureLibass
        )
        defer { pipeline.terminate() }
        let original = try #require(overlay.resourcePoolSnapshotForTesting)

        pipeline.setPresentationAuthorityEnabled(false)
        pipeline.setPresentationAuthorityEnabled(true)
        #expect(pipeline.hasPresentationAuthorityForTesting)
        #expect(overlay.resourcePoolSnapshotForTesting?.sourceGeneration == original.sourceGeneration)

        pipeline.clear(generation: 1)
        pipeline.setPresentationAuthorityEnabled(false)
        pipeline.setPresentationAuthorityEnabled(true)
        #expect(overlay.resourcePoolSnapshotForTesting?.sourceGeneration == original.sourceGeneration)
    }

    private static let caption = """
        [Script Info]
        ScriptType: v4.00+
        PlayResX: 640
        PlayResY: 360

        [V4+ Styles]
        Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
        Style: Default,Arial,24,&H00FFFFFF,&H000000FF,&H00101010,&H80000000,0,0,0,0,100,100,0,0,1,1,0,2,10,10,10,1

        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Dialogue: 0,0:00:00.00,0:00:02.00,Default,,0,0,0,,Source authority fixture
        """
}
