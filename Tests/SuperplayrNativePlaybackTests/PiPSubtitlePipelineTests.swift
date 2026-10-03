import AppKit
import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Testing
@testable import SuperplayrNativePlayback

private final class LockedMismatchCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.withLock { value += 1 }
    }

    var snapshot: Int {
        lock.withLock { value }
    }
}

@Suite("Production PiP independent subtitle pipelines", .serialized)
struct PiPSubtitlePipelineTests {
    @Test @MainActor func bitmapSubtitleUsesPremultipliedColorAndClearsInPiP() async throws {
        let size = CGSize(width: 8, height: 8)
        let pipeline = try SubtitlePipeline(overlay: SubtitleOverlayView(headless: true), presentsOverlay: false)
        _ = try pipeline.configure(codecPrivate: nil, codecName: "hdmv_pgs_subtitle", attachments: [], frameSize: size, storageSize: size)
        let pixels = Data([0, 0, 128, 128, 0, 0, 128, 128, 0, 0, 128, 128, 0, 0, 128, 128])
        let composition = NativeBitmapSubtitleComposition(
            regions: [.init(pixels: pixels, frame: .init(x: 1, y: 1, width: 2, height: 2), isForced: true)],
            canvasSize: .init(width: 4, height: 4), duration: 1, memoryLease: nil)
        pipeline.process(event: .init(assData: Data(), presentationSeconds: 1, durationSeconds: 1,
                                      generation: 0, bitmapComposition: composition))
        let compositor = try PiPSubtitleCompositor(subtitles: pipeline)
        let source = try blackPixelBuffer(size: size)
        let shown = try await compositor.composedPixelBufferForTesting(decodedFrame(pixelBuffer: source, size: size, seconds: 1.5))
        CVPixelBufferLockBaseAddress(shown, .readOnly)
        let base = try #require(CVPixelBufferGetBaseAddress(shown)).assumingMemoryBound(to: UInt8.self)
        let offset = 3 * CVPixelBufferGetBytesPerRow(shown) + 3 * 4
        #expect(Array(UnsafeBufferPointer(start: base + offset, count: 4)) == [0, 0, 128, 255])
        CVPixelBufferUnlockBaseAddress(shown, .readOnly)
        let cleared = try await compositor.composedPixelBufferForTesting(decodedFrame(pixelBuffer: source, size: size, seconds: 2.5))
        #expect(nonblackPixelCount(cleared) == 0)
    }

    private static let twoCueASS = """
        [Script Info]
        ScriptType: v4.00+
        PlayResX: 1280
        PlayResY: 720
        ScaledBorderAndShadow: yes

        [V4+ Styles]
        Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
        Style: Default,Arial,48,&H00FFFFFF,&H000000FF,&H00101010,&H80000000,0,0,0,0,100,100,0,0,1,3,1,2,60,60,45,1

        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Dialogue: 0,0:00:00.00,0:00:01.50,Default,,0,0,0,,FIRST CUE
        Dialogue: 0,0:00:02.00,0:00:04.00,Default,,0,0,0,,SECOND CUE IS LONGER
        """

    @Test
    func applicationSubtitleBudgetAccountsForAllOwnersAndReleasesLeases() {
        let mebibyte = 1_024 * 1_024
        let budget = SubtitleMemoryBudget(
            limitBytes: 80 * mebibyte,
            ownerLimitsBytes: [:]
        )
        var main = budget.acquire(owner: .mainLibass, bytes: 32 * mebibyte)
        var pip = budget.acquire(
            owner: .pictureInPictureLibass,
            bytes: 16 * mebibyte
        )
        var staging = budget.acquire(
            owner: .pictureInPictureStaging,
            bytes: 24 * mebibyte
        )

        #expect(main != nil)
        #expect(pip != nil)
        #expect(staging != nil)
        #expect(budget.snapshot.reservedBytes == 72 * mebibyte)
        #expect(!staging!.resize(to: 40 * mebibyte))
        #expect(budget.snapshot.rejectedAcquisitions == 1)

        staging = nil
        pip = nil
        main = nil
        #expect(budget.snapshot.reservedBytes == 0)
    }

    @Test
    func subtitleBudgetPreflightsAggregateAndOwnerCapacityWithoutRejecting() {
        let mebibyte = 1_024 * 1_024
        let budget = SubtitleMemoryBudget(
            limitBytes: 128 * mebibyte,
            ownerLimitsBytes: [
                .mainLibass: 64 * mebibyte,
                .pictureInPictureLibass: 32 * mebibyte,
            ]
        )
        let main = budget.acquire(owner: .mainLibass, bytes: 32 * mebibyte)
        let pip = budget.acquire(
            owner: .pictureInPictureLibass,
            bytes: 16 * mebibyte
        )

        #expect(main != nil)
        #expect(pip != nil)
        #expect(budget.canAcquire([
            (.mainLibass, 32 * mebibyte),
            (.pictureInPictureLibass, 16 * mebibyte),
        ]))
        let candidateMain = budget.acquire(
            owner: .mainLibass,
            bytes: 32 * mebibyte
        )
        let candidatePiP = budget.acquire(
            owner: .pictureInPictureLibass,
            bytes: 16 * mebibyte
        )
        #expect(candidateMain != nil)
        #expect(candidatePiP != nil)
        #expect(!budget.canAcquire([
            (.mainLibass, 32 * mebibyte),
            (.pictureInPictureLibass, 16 * mebibyte),
        ]))
        #expect(budget.snapshot.rejectedAcquisitions == 0)
    }

    @MainActor
    private func waitUntil(
        timeout: Duration = .seconds(3),
        _ predicate: () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return predicate()
    }

    private func blackPixelBuffer(size: CGSize) throws -> CVPixelBuffer {
        let width = Int(size.width)
        let height = Int(size.height)
        let attributes: [CFString: Any] = [
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:],
        ]
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw PresentationError("Could not create test pixel buffer")
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw PresentationError("Test pixel buffer has no base address")
        }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        memset(baseAddress, 0, bytesPerRow * height)
        let bytes = baseAddress.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width {
                bytes[y * bytesPerRow + x * 4 + 3] = 255
            }
        }
        return pixelBuffer
    }

    private func blackNV12PixelBuffer(
        size: CGSize,
        fullRange: Bool
    ) throws -> CVPixelBuffer {
        let width = Int(size.width)
        let height = Int(size.height)
        let attributes: [CFString: Any] = [
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:],
        ]
        var pixelBuffer: CVPixelBuffer?
        let pixelFormat = fullRange
            ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            pixelFormat,
            attributes as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw PresentationError("Could not create test NV12 pixel buffer")
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        for plane in 0..<CVPixelBufferGetPlaneCount(pixelBuffer) {
            guard let address = CVPixelBufferGetBaseAddressOfPlane(
                pixelBuffer,
                plane
            ) else {
                throw PresentationError("Test NV12 plane has no base address")
            }
            let byteCount =
                CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane)
                    * CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)
            memset(address, plane == 0 && !fullRange ? 16 : 0, byteCount)
            if plane == 1 {
                memset(address, 128, byteCount)
            }
        }
        return pixelBuffer
    }

    private func decodedFrame(
        pixelBuffer: CVPixelBuffer,
        size: CGSize,
        seconds: Double,
        displaySize: CGSize? = nil,
        pixelAspectRatio: CGSize = CGSize(width: 1, height: 1),
        transferCharacteristic: Int32? = nil,
        hasMasteringDisplayMetadata: Bool = false,
        hasContentLightMetadata: Bool = false,
        sourceComponentDepth: Int = 8,
        ffmpegPixelFormat: String = "bgra",
        matrix: Int32? = nil,
        rotation: Double = 0,
        mirrored: Bool = false,
        cleanAperture: CGRect? = nil
    ) -> NativeDecodedVideoFrame {
        NativeDecodedVideoFrame(
            pixelBuffer: pixelBuffer,
            planarOwnershipToken: nil,
            presentationTime: CMTime(seconds: seconds, preferredTimescale: 1_000),
            duration: CMTime(value: 1, timescale: 30),
            generation: 0,
            codedSize: size,
            displaySize: displaySize ?? size,
            pixelAspectRatio: pixelAspectRatio,
            rotationDegrees: rotation,
            colorPrimaries: transferCharacteristic == 16 || transferCharacteristic == 18 ? 9 : nil,
            transferCharacteristic: transferCharacteristic,
            matrixCoefficients: matrix,
            isFullRange: true,
            hasMasteringDisplayMetadata: hasMasteringDisplayMetadata,
            hasContentLightMetadata: hasContentLightMetadata,
            sourceComponentDepth: sourceComponentDepth,
            ffmpegPixelFormat: ffmpegPixelFormat,
            isHardwareDecoded: false,
            isCopiedHardwarePath: false,
            isNearZeroCopy: false,
            cleanAperture: cleanAperture,
            isHorizontallyMirrored: mirrored
        )
    }

    private func nonblackPixelCount(_ pixelBuffer: CVPixelBuffer) -> Int {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return 0
        }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let bytes = baseAddress.assumingMemoryBound(to: UInt8.self)
        var count = 0
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bytesPerRow + x * 4
                if bytes[offset] > 8
                    || bytes[offset + 1] > 8
                    || bytes[offset + 2] > 8
                {
                    count += 1
                }
            }
        }
        return count
    }

    @Test @MainActor
    func independentContextsRenderMainAndPiPSimultaneouslyAcrossSeekAndCueChange()
        async throws
    {
        let size = CGSize(width: 1280, height: 720)
        let viewport = CGRect(origin: .zero, size: size)
        let mainOverlay = SubtitleOverlayView(frame: viewport)
        mainOverlay.updateDrawableSize(backingScale: 1)
        let main = try SubtitlePipeline(
            overlay: mainOverlay,
            deduplicatesPackets: true
        )
        let pip = try SubtitlePipeline(
            overlay: SubtitleOverlayView(),
            presentsOverlay: false,
            deduplicatesPackets: true
        )

        #expect(main.libassContextIdentityForTesting() != pip.libassContextIdentityForTesting())

        let data = Data(Self.twoCueASS.utf8)
        try main.installExternal(data: data)
        try pip.installExternal(data: data)

        main.render(
            at: CMTime(seconds: 0.5, preferredTimescale: 1_000),
            viewport: viewport,
            videoSize: size
        )
        let firstPiP = pip.pictureInPictureSubtitleSnapshot(
            at: CMTime(seconds: 0.5, preferredTimescale: 1_000),
            viewport: viewport,
            videoSize: size
        )
        for _ in 0..<100 where main.counters().overlayCommits == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(main.counters().overlayCommits == 1)
        #expect(!firstPiP.regions.isEmpty)

        main.clear()
        pip.clear()
        main.render(
            at: CMTime(seconds: 2.5, preferredTimescale: 1_000),
            viewport: viewport,
            videoSize: size
        )
        let secondPiP = pip.pictureInPictureSubtitleSnapshot(
            at: CMTime(seconds: 2.5, preferredTimescale: 1_000),
            viewport: viewport,
            videoSize: size
        )
        for _ in 0..<100 where main.counters().overlayCommits < 2 {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(main.counters().overlayCommits == 2)
        #expect(!secondPiP.regions.isEmpty)
        #expect(firstPiP.regions.map(\.frame) != secondPiP.regions.map(\.frame))
        #expect(main.counters().metalFailures == 0)
        #expect(pip.counters().metalFailures == 0)

        let mismatchCount = LockedMismatchCounter()
        DispatchQueue.concurrentPerform(iterations: 40) { iteration in
            let seconds = iteration.isMultiple(of: 2) ? 0.5 : 2.5
            let time = CMTime(seconds: seconds, preferredTimescale: 1_000)
            let mainRegions = main.renderedRegions(
                at: time,
                viewport: viewport,
                videoSize: size
            )
            let pipRegions = pip.pictureInPictureSubtitleSnapshot(
                at: time,
                viewport: viewport,
                videoSize: size
            ).regions
            if mainRegions.map(\.frame) != pipRegions.map(\.frame)
                || mainRegions.map(\.bitmap) != pipRegions.map(\.bitmap)
            {
                mismatchCount.increment()
            }
        }

        #expect(mismatchCount.snapshot == 0)
        #expect(main.counters().libassFrames > 0)
        #expect(pip.counters().libassFrames > 0)
    }

    @Test @MainActor
    func disablingSubtitlesHidesOnlyTheMainOverlayUntilReenabled() async throws {
        let mainOverlay = SubtitleOverlayView(
            frame: CGRect(x: 0, y: 0, width: 640, height: 360)
        )
        let main = try SubtitlePipeline(overlay: mainOverlay)
        let pipOverlay = SubtitleOverlayView()
        let pip = try SubtitlePipeline(
            overlay: pipOverlay,
            presentsOverlay: false
        )

        main.isEnabled = false
        pip.isEnabled = false
        #expect(await waitUntil { mainOverlay.isHidden })
        #expect(!pipOverlay.isHidden)

        main.isEnabled = true
        pip.isEnabled = true
        #expect(await waitUntil { !mainOverlay.isHidden })
        #expect(!pipOverlay.isHidden)
        main.terminate()
        pip.terminate()
    }

    @Test @MainActor
    func nonauthoritativeCandidateCanPrepareWithoutRenderingOrClearing() throws {
        let candidate = try SubtitlePipeline(
            overlay: SubtitleOverlayView(),
            presentsOverlay: false
        )
        candidate.setPresentationAuthorityEnabled(false)
        try candidate.installExternal(data: Data(Self.twoCueASS.utf8))

        let suppressed = candidate.pictureInPictureSubtitleSnapshot(
            at: CMTime(seconds: 0.5, preferredTimescale: 1_000),
            viewport: CGRect(x: 0, y: 0, width: 640, height: 360),
            videoSize: CGSize(width: 640, height: 360)
        )
        #expect(!candidate.hasPresentationAuthorityForTesting)
        #expect(suppressed.regions.isEmpty)
        #expect(candidate.counters().libassFrames == 0)
        #expect(candidate.fenceSnapshotForTesting().pendingVisibleClear != nil)

        candidate.setPresentationAuthorityEnabled(true)
        let active = candidate.pictureInPictureSubtitleSnapshot(
            at: CMTime(seconds: 0.5, preferredTimescale: 1_000),
            viewport: CGRect(x: 0, y: 0, width: 640, height: 360),
            videoSize: CGSize(width: 640, height: 360)
        )
        #expect(candidate.hasPresentationAuthorityForTesting)
        #expect(!active.regions.isEmpty)
        #expect(candidate.fenceSnapshotForTesting().pendingVisibleClear == nil)
        candidate.terminate()
    }

    @Test @MainActor
    func compositorWritesBothIndependentSubtitleCuesIntoOutputPixels() async throws {
        let size = CGSize(width: 640, height: 360)
        let pipeline = try SubtitlePipeline(
            overlay: SubtitleOverlayView(),
            presentsOverlay: false
        )
        try pipeline.installExternal(data: Data(Self.twoCueASS.utf8))
        let compositor = try PiPSubtitleCompositor(subtitles: pipeline)
        let source = try blackPixelBuffer(size: size)

        let first = try await compositor.composedPixelBufferForTesting(
            decodedFrame(pixelBuffer: source, size: size, seconds: 0.5)
        )
        let second = try await compositor.composedPixelBufferForTesting(
            decodedFrame(pixelBuffer: source, size: size, seconds: 2.5)
        )
        let firstNonblack = nonblackPixelCount(first)
        let secondNonblack = nonblackPixelCount(second)

        #expect(firstNonblack > 100)
        #expect(secondNonblack > firstNonblack)
        #expect(pipeline.counters().libassFrames == 2)
        #expect(pipeline.counters().metalFailures == 0)
        pipeline.terminate()
    }

    @Test @MainActor
    func pausedSameFrameReentryImmediatelyRestoresTheCompositedSubtitleFrame()
        async throws
    {
        let size = CGSize(width: 640, height: 360)
        let pipeline = try SubtitlePipeline(
            overlay: SubtitleOverlayView(),
            presentsOverlay: false
        )
        try pipeline.installExternal(data: Data(Self.twoCueASS.utf8))
        let compositor = try PiPSubtitleCompositor(subtitles: pipeline)
        let source = try blackPixelBuffer(size: size)
        let pausedFrame = decodedFrame(
            pixelBuffer: source,
            size: size,
            seconds: 0.5
        )

        compositor.receive(pausedFrame)
        compositor.start(onFirstSample: { _ in }, onFailure: { _ in })
        #expect(await waitUntil {
            compositor.metricsSnapshot().composedFrames == 1
        })
        #expect(compositor.metricsSnapshot().immediatelyDisplayedFrames == 1)
        #expect(compositor.metricsSnapshot().subtitleVisibleFrames == 1)

        compositor.stop()
        try await Task.sleep(for: .milliseconds(100))

        compositor.start(onFirstSample: { _ in }, onFailure: { _ in })
        #expect(await waitUntil {
            compositor.metricsSnapshot().composedFrames == 1
        })
        #expect(compositor.metricsSnapshot().immediatelyDisplayedFrames == 1)
        #expect(compositor.metricsSnapshot().subtitleVisibleFrames == 1)

        compositor.stop()
        pipeline.terminate()
    }

    @Test @MainActor
    func exhaustedAggregatePiPStagingBudgetFallsBackToVideoOnly() async throws {
        let budget = SubtitleMemoryBudget(
            limitBytes: 16 * 1_024 * 1_024,
            ownerLimitsBytes: [:]
        )
        let size = CGSize(width: 640, height: 360)
        let pipeline = try SubtitlePipeline(
            overlay: SubtitleOverlayView(),
            presentsOverlay: false,
            memoryBudget: budget,
            memoryOwner: .pictureInPictureLibass
        )
        try pipeline.installExternal(data: Data(Self.twoCueASS.utf8))
        let compositor = try PiPSubtitleCompositor(
            subtitles: pipeline,
            memoryBudget: budget
        )
        let source = try blackPixelBuffer(size: size)

        let output = try await compositor.composedPixelBufferForTesting(
            decodedFrame(pixelBuffer: source, size: size, seconds: 0.5)
        )

        #expect(nonblackPixelCount(output) == 0)
        #expect(budget.snapshot.rejectedAcquisitions > 0)
        pipeline.terminate()
    }

    @Test @MainActor
    func compositorRebindInvalidatesPreparedSubtitlesFromThePreviousPipeline()
        async throws
    {
        let size = CGSize(width: 640, height: 360)
        let first = try SubtitlePipeline(
            overlay: SubtitleOverlayView(),
            presentsOverlay: false
        )
        let replacement = try SubtitlePipeline(
            overlay: SubtitleOverlayView(),
            presentsOverlay: false
        )
        try first.installExternal(data: Data(Self.twoCueASS.utf8))
        let compositor = try PiPSubtitleCompositor(subtitles: first)
        let source = try blackPixelBuffer(size: size)
        let frame = decodedFrame(pixelBuffer: source, size: size, seconds: 0.5)

        let composedFirst = try await compositor.composedPixelBufferForTesting(frame)
        #expect(nonblackPixelCount(composedFirst) > 100)

        compositor.setSubtitlePipeline(replacement)
        #expect(
            compositor.subtitlePipelineIdentityForTesting
                == ObjectIdentifier(replacement)
        )
        let composedReplacement = try await compositor.composedPixelBufferForTesting(
            frame
        )
        #expect(nonblackPixelCount(composedReplacement) == 0)

        compositor.setSubtitlePipeline(nil)
        #expect(compositor.subtitlePipelineIdentityForTesting == nil)
        let composedWithoutSubtitles = try await compositor.composedPixelBufferForTesting(
            frame
        )
        #expect(nonblackPixelCount(composedWithoutSubtitles) == 0)
        first.terminate()
        replacement.terminate()
    }

    @Test @MainActor
    func compositorFillsThePiPViewportWithoutEdgeSlivers() throws {
        let pipeline = try SubtitlePipeline(
            overlay: SubtitleOverlayView(),
            presentsOverlay: false
        )
        let compositor = try PiPSubtitleCompositor(subtitles: pipeline)

        #expect(compositor.displayLayer.videoGravity == .resizeAspectFill)
        pipeline.terminate()
    }

    @Test @MainActor
    func composedPiPFanoutPreservesTheMainRendererDemandSource() throws {
        let size = CGSize(width: 640, height: 360)
        let presentation = try NativePresentationCoordinator()
        let sinkFrames = LockedMismatchCounter()
        presentation.setPictureInPictureFrameSink { _ in
            sinkFrames.increment()
        }
        let frame = decodedFrame(
            pixelBuffer: try blackPixelBuffer(size: size),
            size: size,
            seconds: 0.5
        )

        #expect(try presentation.enqueueVideo(
            frame,
            fence: presentation.currentFence
        ))
        let admitted = presentation.rendererPresentationMetrics(
            demuxEOF: false
        )
        #expect(sinkFrames.snapshot == 1)
        #expect(admitted.videoSubmissionAttempts == 1)
        #expect(admitted.videoEnqueueReturnedWithoutImmediateFailure == 1)
        presentation.terminate()
    }

    @Test @MainActor
    func returnedPoolBufferResumesPausedCaptionWithoutVideoOnlyFallback() async throws {
        let size = CGSize(width: 640, height: 360)
        let pipeline = try SubtitlePipeline(overlay: SubtitleOverlayView(), presentsOverlay: false)
        try pipeline.installExternal(data: Data(Self.twoCueASS.utf8))
        let compositor = try PiPSubtitleCompositor(subtitles: pipeline)
        let frame = decodedFrame(pixelBuffer: try blackPixelBuffer(size: size), size: size, seconds: 0.5)
        var retained: [CVPixelBuffer] = []
        for _ in 0..<12 {
            retained.append(try await compositor.composedPixelBufferForTesting(frame))
        }
        let failures = LockedMismatchCounter()
        compositor.receive(frame)
        compositor.start(onFirstSample: { result in
            if case .failure = result { failures.increment() }
        }, onFailure: { _ in failures.increment() })
        #expect(await waitUntil { compositor.metricsSnapshot().outputPoolMisses > 0 })
        #expect(compositor.metricsSnapshot().composedFrames == 0)
        #expect(failures.snapshot == 0)
        retained.removeAll()
        // No new input frame or timer: the pool's notification must wake it.
        #expect(await waitUntil { compositor.metricsSnapshot().composedFrames == 1 })
        #expect(compositor.metricsSnapshot().subtitleVisibleFrames > 0)
        #expect(failures.snapshot == 0)
        compositor.stop()
        pipeline.terminate()
    }

    @Test
    func compositionFenceRejectsResultsFromBeforeInvalidation() {
        var fence = PiPSubtitleCompositionFence()
        let staleRevision = fence.revision
        #expect(fence.accepts(staleRevision))

        fence.invalidate()

        #expect(!fence.accepts(staleRevision))
        #expect(fence.accepts(fence.revision))
    }

    @Test
    func presentationFlushInvalidatesPendingPiPComposition() throws {
        let presentation = try NativePresentationCoordinator()
        let invalidations = LockedMismatchCounter()
        presentation.setPictureInPictureFrameSink(
            { _ in },
            onInvalidation: {
                invalidations.increment()
            }
        )

        presentation.flush(at: .zero)

        #expect(invalidations.snapshot == 1)
        presentation.terminate()
    }

    @Test @MainActor
    func compositorAppliesCropRotationAndMirrorToColoredPixels() async throws {
        let size = CGSize(width: 64, height: 32)
        let pipeline = try SubtitlePipeline(overlay: SubtitleOverlayView(), presentsOverlay: false)
        defer { pipeline.terminate() }
        let compositor = try PiPSubtitleCompositor(subtitles: pipeline)
        let source = try blackPixelBuffer(size: size)
        CVPixelBufferLockBaseAddress(source, [])
        let base = try #require(CVPixelBufferGetBaseAddress(source)).assumingMemoryBound(to: UInt8.self)
        for y in 0..<32 {
            for x in 0..<64 {
                let offset = y * CVPixelBufferGetBytesPerRow(source) + x * 4
                base[offset + (x < 32 ? 2 : 0)] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(source, [])
        let cases: [(Double, Bool, CGRect?, CGSize, [(Int, Int, Int)])] = [
            (0, true, nil, size, [(8, 16, 0), (56, 16, 2)]),
            (90, false, nil, CGSize(width: 32, height: 64), [(16, 8, 0), (16, 56, 2)]),
            (0, false, CGRect(x: 0, y: 0, width: 24, height: 32),
             CGSize(width: 24, height: 32), [(4, 16, 2), (20, 16, 2)]),
        ]
        for (rotation, mirrored, crop, display, samples) in cases {
            let output = try await compositor.composedPixelBufferForTesting(decodedFrame(
                pixelBuffer: source, size: size, seconds: 0, displaySize: display,
                rotation: rotation, mirrored: mirrored, cleanAperture: crop
            ))
            #expect(CVPixelBufferGetWidth(output) == Int(display.width))
            #expect(CVPixelBufferGetHeight(output) == Int(display.height))
            CVPixelBufferLockBaseAddress(output, .readOnly)
            let pixels = try #require(CVPixelBufferGetBaseAddress(output)).assumingMemoryBound(to: UInt8.self)
            for (x, y, channel) in samples {
                let offset = y * CVPixelBufferGetBytesPerRow(output) + x * 4
                #expect(pixels[offset + channel] >= 254)
                #expect(pixels[offset + (channel == 0 ? 2 : 0)] <= 1)
            }
            CVPixelBufferUnlockBaseAddress(output, .readOnly)
        }
    }

    @Test @MainActor
    func compositorInterpretsColoredNV12UsingSourceMatrixAndRange() async throws {
        let size = CGSize(width: 64, height: 64)
        let pipeline = try SubtitlePipeline(overlay: SubtitleOverlayView(), presentsOverlay: false)
        defer { pipeline.terminate() }
        let compositor = try PiPSubtitleCompositor(subtitles: pipeline)
        let cases: [(Int32, Double, Double)] = [(1, 0.2126, 0.0722), (6, 0.299, 0.114), (9, 0.2627, 0.0593)]
        for (matrix, kr, kb) in cases {
            for full in [false, true] {
                let source = try blackNV12PixelBuffer(size: size, fullRange: full)
                CVPixelBufferLockBaseAddress(source, [])
                let yPlane = try #require(CVPixelBufferGetBaseAddressOfPlane(source, 0))
                memset(yPlane, 100, CVPixelBufferGetBytesPerRowOfPlane(source, 0) * 64)
                let uv = try #require(CVPixelBufferGetBaseAddressOfPlane(source, 1))
                    .assumingMemoryBound(to: UInt8.self)
                for row in 0..<32 {
                    for column in stride(from: 0, to: 64, by: 2) {
                        let offset = row * CVPixelBufferGetBytesPerRowOfPlane(source, 1) + column
                        uv[offset] = 90
                        uv[offset + 1] = 200
                    }
                }
                CVPixelBufferUnlockBaseAddress(source, [])
                CVBufferSetAttachment(source, kCVImageBufferColorPrimariesKey,
                                      kCVImageBufferColorPrimaries_SMPTE_C, .shouldPropagate)
                let output = try await compositor.composedPixelBufferForTesting(decodedFrame(
                    pixelBuffer: source, size: size, seconds: 0, matrix: matrix
                ))
                let y = full ? 100.0 / 255 : (100.0 - 16) / 219
                let cb = (90.0 - 128) / (full ? 255 : 224)
                let cr = (200.0 - 128) / (full ? 255 : 224)
                let expected = [y + 2 * (1 - kr) * cr,
                                y - 2 * kb * (1 - kb) / (1 - kr - kb) * cb
                                    - 2 * kr * (1 - kr) / (1 - kr - kb) * cr,
                                y + 2 * (1 - kb) * cb].map { Int(($0 * 255).rounded()) }
                CVPixelBufferLockBaseAddress(output, .readOnly)
                let pixel = try #require(CVPixelBufferGetBaseAddress(output)).assumingMemoryBound(to: UInt8.self)
                let actual = [Int(pixel[2]), Int(pixel[1]), Int(pixel[0])]
                CVPixelBufferUnlockBaseAddress(output, .readOnly)
                for channel in 0..<3 { #expect(abs(actual[channel] - expected[channel]) <= 1) }
                #expect(CVBufferCopyAttachment(output, kCVImageBufferColorPrimariesKey, nil) as? String
                        == kCVImageBufferColorPrimaries_SMPTE_C as String)
                #expect(CVBufferCopyAttachment(output, kCVImageBufferYCbCrMatrixKey, nil) == nil)
            }
        }
    }

    private func p010PixelBuffer(size: CGSize, fullRange: Bool, black: Bool = false) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any],
        ]
        let status = CVPixelBufferCreate(kCFAllocatorDefault, Int(size.width), Int(size.height),
            fullRange ? kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
                : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            attributes as CFDictionary, &buffer)
        #expect(status == kCVReturnSuccess)
        let result = try #require(buffer)
        CVPixelBufferLockBaseAddress(result, [])
        defer { CVPixelBufferUnlockBaseAddress(result, []) }
        for plane in 0..<2 {
            let base = try #require(CVPixelBufferGetBaseAddressOfPlane(result, plane))
                .assumingMemoryBound(to: UInt16.self)
            let stride = CVPixelBufferGetBytesPerRowOfPlane(result, plane) / 2
            for y in 0..<CVPixelBufferGetHeightOfPlane(result, plane) {
                for x in 0..<Int(size.width) {
                    let code = plane == 0 ? (black ? (fullRange ? 0 : 64) : 400 + x)
                        : (black ? 512 : (x % 2 == 0 ? 450 : 600))
                    base[y * stride + x] = UInt16(code << 6)
                }
            }
        }
        CVBufferSetAttachment(result, kCVImageBufferColorPrimariesKey,
                              kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(result, kCVImageBufferTransferFunctionKey,
                              kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        return result
    }

    private func packedTenBitRGB(_ buffer: CVPixelBuffer, x: Int, y: Int) throws -> [Int] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = try #require(CVPixelBufferGetBaseAddress(buffer))
            .advanced(by: y * CVPixelBufferGetBytesPerRow(buffer)).assumingMemoryBound(to: UInt32.self)
        let pixel = UInt32(littleEndian: base[x])
        #expect(pixel >> 30 == 3)
        return [Int((pixel >> 20) & 1023), Int((pixel >> 10) & 1023), Int(pixel & 1023)]
    }

    @Test @MainActor
    func p010CompositionPreservesLowBitsMatrixRangeAndPoolTransitions() async throws {
        let size = CGSize(width: 32, height: 8)
        let pipeline = try SubtitlePipeline(overlay: SubtitleOverlayView(headless: true), presentsOverlay: false)
        defer { pipeline.terminate() }
        let compositor = try PiPSubtitleCompositor(subtitles: pipeline)
        let bgra = try blackPixelBuffer(size: size)
        for (matrix, kr, kb): (Int32, Double, Double) in [(1, 0.2126, 0.0722), (6, 0.299, 0.114), (9, 0.2627, 0.0593)] {
            for full in [false, true] {
                let eight = try await compositor.composedPixelBufferForTesting(decodedFrame(pixelBuffer: bgra, size: size, seconds: 0))
                #expect(CVPixelBufferGetPixelFormatType(eight) == kCVPixelFormatType_32BGRA)
                let source = try p010PixelBuffer(size: size, fullRange: full)
                let output = try await compositor.composedPixelBufferForTesting(decodedFrame(
                    pixelBuffer: source, size: size, seconds: 0, transferCharacteristic: 1,
                    sourceComponentDepth: 10, ffmpegPixelFormat: "p010le", matrix: matrix))
                #expect(CVPixelBufferGetPixelFormatType(output) == kCVPixelFormatType_ARGB2101010LEPacked)
                var reds = Set<Int>()
                for x in 0..<32 {
                    let y = full ? Double(400 + x) / 1023 : Double(400 + x - 64) / 876
                    let cb = (450.0 - 512) / (full ? 1023 : 896)
                    let cr = (600.0 - 512) / (full ? 1023 : 896)
                    let expected = [y + 2 * (1 - kr) * cr,
                        y - 2 * kb * (1 - kb) / (1 - kr - kb) * cb
                            - 2 * kr * (1 - kr) / (1 - kr - kb) * cr,
                        y + 2 * (1 - kb) * cb].map { Int(($0 * 1023).rounded()) }
                    let actual = try packedTenBitRGB(output, x: x, y: 4)
                    for channel in 0..<3 { #expect(abs(actual[channel] - expected[channel]) <= 2) }
                    reds.insert(actual[0])
                }
                // An eight-bit intermediate collapses these 32 adjacent codes to about nine.
                #expect(reds.count == 32)
                #expect(CVBufferCopyAttachment(output, kCVImageBufferColorPrimariesKey, nil) as? String
                        == kCVImageBufferColorPrimaries_ITU_R_709_2 as String)
                #expect(CVBufferCopyAttachment(output, kCVImageBufferTransferFunctionKey, nil) as? String
                        == kCVImageBufferTransferFunction_ITU_R_709_2 as String)
                #expect(CVBufferCopyAttachment(output, kCVImageBufferYCbCrMatrixKey, nil) == nil)
            }
        }
        let eightAgain = try await compositor.composedPixelBufferForTesting(decodedFrame(pixelBuffer: bgra, size: size, seconds: 0))
        #expect(CVPixelBufferGetPixelFormatType(eightAgain) == kCVPixelFormatType_32BGRA)
    }

    @Test @MainActor
    func p010BitmapCompositionBlendsAndExpiresAtTenBits() async throws {
        let size = CGSize(width: 8, height: 8)
        let pipeline = try SubtitlePipeline(overlay: SubtitleOverlayView(headless: true), presentsOverlay: false)
        defer { pipeline.terminate() }
        _ = try pipeline.configure(codecPrivate: nil, codecName: "hdmv_pgs_subtitle", attachments: [], frameSize: size, storageSize: size)
        let composition = NativeBitmapSubtitleComposition(
            regions: [.init(pixels: Data([0, 0, 128, 128]), frame: .init(x: 1, y: 1, width: 1, height: 1), isForced: false)],
            canvasSize: .init(width: 4, height: 4), duration: 1, memoryLease: nil)
        pipeline.process(event: .init(assData: Data(), presentationSeconds: 1, durationSeconds: 1,
                                     generation: 0, bitmapComposition: composition))
        let compositor = try PiPSubtitleCompositor(subtitles: pipeline)
        let source = try p010PixelBuffer(size: size, fullRange: false, black: true)
        for (seconds, red) in [(1.5, 514), (2.5, 0)] {
            let output = try await compositor.composedPixelBufferForTesting(decodedFrame(
                pixelBuffer: source, size: size, seconds: seconds, sourceComponentDepth: 10, matrix: 1))
            let actual = try packedTenBitRGB(output, x: 2, y: 2)
            #expect(abs(actual[0] - red) <= 1)
            #expect(actual[1] == 0 && actual[2] == 0)
        }
    }

    private func countBrightTenBitPixels(_ buffer: CVPixelBuffer) throws -> Int {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = try #require(CVPixelBufferGetBaseAddress(buffer))
        var count = 0
        for y in 0..<CVPixelBufferGetHeight(buffer) {
            let row = base.advanced(by: y * CVPixelBufferGetBytesPerRow(buffer)).assumingMemoryBound(to: UInt32.self)
            for x in 0..<CVPixelBufferGetWidth(buffer) {
                if (UInt32(littleEndian: row[x]) >> 20) & 1023 > 500 { count += 1 }
            }
        }
        return count
    }

    @Test(arguments: [Int32(1), 16, 18]) @MainActor
    func p010TextCompositionIsAcceptedByAppleRenderer(transfer: Int32) async throws {
        let size = CGSize(width: 640, height: 360)
        let pipeline = try SubtitlePipeline(overlay: SubtitleOverlayView(headless: true), presentsOverlay: false)
        defer { pipeline.terminate() }
        try pipeline.installExternal(data: Data(Self.twoCueASS.utf8))
        let compositor = try PiPSubtitleCompositor(subtitles: pipeline)
        let source = try p010PixelBuffer(size: size, fullRange: false, black: true)
        let output = try await compositor.composedPixelBufferForTesting(decodedFrame(
            pixelBuffer: source, size: size, seconds: 0.5, transferCharacteristic: transfer, sourceComponentDepth: 10, matrix: 1))
        let bright = transfer == 1 ? try countBrightTenBitPixels(output) : try countBrightP010Pixels(output)
        #expect(bright > 100)
        let presenter = SampleBufferVideoPresenter()
        let view = NSView(frame: .init(origin: .zero, size: size))
        view.wantsLayer = true
        presenter.displayLayer.frame = view.bounds
        view.layer?.addSublayer(presenter.displayLayer)
        let window = NSWindow(contentRect: view.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.contentView = view
        window.orderFrontRegardless()
        defer {
            window.orderOut(nil)
            presenter.displayLayer.removeFromSuperlayer()
            window.contentView = nil
            window.close()
        }
        try presenter.enqueue(decodedFrame(pixelBuffer: output, size: size, seconds: 0,
                                            transferCharacteristic: transfer, sourceComponentDepth: 10), displayImmediately: true)
        let deadline = Date().addingTimeInterval(3)
        var displayed = presenter.renderer.displayedPixelBuffer()
        while displayed == nil, Date() < deadline, presenter.failureDescription == nil {
            try await Task.sleep(for: .milliseconds(10))
            displayed = presenter.renderer.displayedPixelBuffer()
        }
        #expect(presenter.failureDescription == nil)
        #expect(presenter.renderer.status == .rendering)
        let rendered = try #require(displayed)
        let renderedFormat = CVPixelBufferGetPixelFormatType(rendered)
        // This host returns an eight-bit BGRA displayed buffer for packed RGB.
        // Renderer acceptance is not evidence of ten-bit displayed precision.
        print("[pip-ten-bit-renderer] submitted=\(CVPixelBufferGetPixelFormatType(output)) displayed=\(renderedFormat)")
        if transfer != 1 {
            #expect(renderedFormat == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
            #expect(try countBrightP010Pixels(rendered) > 100)
        } else if renderedFormat == kCVPixelFormatType_32BGRA {
            #expect(nonblackPixelCount(rendered) > 100)
        } else {
            #expect(renderedFormat == kCVPixelFormatType_ARGB2101010LEPacked)
            #expect(try countBrightTenBitPixels(rendered) > 100)
        }
        #expect(CVPixelBufferGetWidth(rendered) == 640 && CVPixelBufferGetHeight(rendered) == 360)
    }

    private func countBrightP010Pixels(_ buffer: CVPixelBuffer) throws -> Int {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, 0))
        var count = 0
        for y in 0..<CVPixelBufferGetHeight(buffer) {
            let row = base.advanced(by: y * CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)).assumingMemoryBound(to: UInt16.self)
            for x in 0..<CVPixelBufferGetWidth(buffer) where row[x] >> 6 > 400 { count += 1 }
        }
        return count
    }

    private func hdrCode(nits: Double, transfer: Int32, full: Bool) -> UInt16 {
        let encoded: Double
        if transfer == 16 {
            let p = pow(nits / 10_000, 2610.0 / 16384)
            encoded = pow((3424.0 / 4096 + (2413.0 / 128) * p) / (1 + (2392.0 / 128) * p), 2523.0 / 32)
        } else {
            let scene = pow(nits / 1_000, 1 / 1.2)
            encoded = scene <= 1 / 12.0 ? sqrt(3 * scene) : 0.17883277 * log(12 * scene - 0.28466892) + 0.55991073
        }
        return UInt16((encoded * (full ? 1023 : 876) + (full ? 0 : 64)).rounded())
    }

    private func setP010Luma(_ buffer: CVPixelBuffer, code: UInt16) throws {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, 0))
        for y in 0..<CVPixelBufferGetHeight(buffer) {
            let row = base.advanced(by: y * CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)).assumingMemoryBound(to: UInt16.self)
            for x in 0..<CVPixelBufferGetWidth(buffer) { row[x] = code << 6 }
        }
    }

    private func p010Code(_ buffer: CVPixelBuffer, plane: Int = 0, x: Int, y: Int) throws -> Int {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let row = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, plane))
            .advanced(by: y * CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)).assumingMemoryBound(to: UInt16.self)
        #expect(row[x] & 63 == 0)
        return Int(row[x] >> 6)
    }

    @Test @MainActor func hdrPQAndHLGCompositionRoundTripTenBitCodesAndTags() async throws {
        let size = CGSize(width: 32, height: 8)
        let pipeline = try SubtitlePipeline(overlay: SubtitleOverlayView(headless: true), presentsOverlay: false)
        defer { pipeline.terminate() }
        let compositor = try PiPSubtitleCompositor(subtitles: pipeline)
        for transfer: Int32 in [16, 18] {
            for full in [false, true] {
                let source = try p010PixelBuffer(size: size, fullRange: full, black: true)
                for code in full ? [0, 1, 64, 300, 500, 750, 1023] : [64, 65, 128, 300, 500, 750, 940] {
                    try setP010Luma(source, code: UInt16(code))
                    let output = try await compositor.composedPixelBufferForTesting(decodedFrame(pixelBuffer: source,
                        size: size, seconds: 0, transferCharacteristic: transfer, sourceComponentDepth: 10, matrix: 9))
                    #expect(CVPixelBufferGetPixelFormatType(output) == CVPixelBufferGetPixelFormatType(source))
                    #expect(abs(try p010Code(output, x: 10, y: 4) - code) <= 2)
                    #expect(abs(try p010Code(output, plane: 1, x: 10, y: 2) - 512) <= 1)
                    #expect(CVBufferCopyAttachment(output, kCVImageBufferTransferFunctionKey, nil) as? String
                        == (transfer == 16 ? kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
                            : kCVImageBufferTransferFunction_ITU_R_2100_HLG) as String)
                    #expect(CVBufferCopyAttachment(output, kCVImageBufferYCbCrMatrixKey, nil) as? String
                        == kCVImageBufferYCbCrMatrix_ITU_R_2020 as String)
                }
            }
        }
    }

    @Test @MainActor func hdrBitmapGraphicsWhiteAndAlphaUseLinearLuminance() async throws {
        let size = CGSize(width: 8, height: 8)
        let pipeline = try SubtitlePipeline(overlay: SubtitleOverlayView(headless: true), presentsOverlay: false)
        defer { pipeline.terminate() }
        _ = try pipeline.configure(codecPrivate: nil, codecName: "dvd_subtitle", attachments: [], frameSize: size, storageSize: size)
        let composition = NativeBitmapSubtitleComposition(regions: [
            .init(pixels: Data(repeating: 255, count: 16), frame: CGRect(x: 0, y: 0, width: 2, height: 2), isForced: false),
            .init(pixels: Data(repeating: 128, count: 16), frame: CGRect(x: 4, y: 0, width: 2, height: 2), isForced: false)],
            canvasSize: size, duration: 1, memoryLease: nil)
        pipeline.process(event: .init(assData: Data(), presentationSeconds: 0, durationSeconds: 1, generation: 0,
                                     bitmapComposition: composition))
        let compositor = try PiPSubtitleCompositor(subtitles: pipeline)
        for transfer: Int32 in [16, 18] {
            for full in [false, true] {
                let source = try p010PixelBuffer(size: size, fullRange: full, black: true)
                for seconds in [0.5, 1.5] {
                    let output = try await compositor.composedPixelBufferForTesting(decodedFrame(pixelBuffer: source,
                        size: size, seconds: seconds, transferCharacteristic: transfer, sourceComponentDepth: 10, matrix: 9))
                    let white = seconds < 1 ? hdrCode(nits: 203, transfer: transfer, full: full) : (full ? 0 : 64)
                    let half = seconds < 1 ? hdrCode(nits: 203 * 128 / 255, transfer: transfer, full: full) : (full ? 0 : 64)
                    #expect(abs(try p010Code(output, x: 0, y: 0) - Int(white)) <= 2)
                    #expect(abs(try p010Code(output, x: 4, y: 0) - Int(half)) <= 2)
                }
            }
        }
    }

    @Test @MainActor
    func compositorNormalizesAnamorphicFramesToSquarePixelDisplaySize() async throws {
        let codedSize = CGSize(width: 720, height: 576)
        let displaySize = CGSize(width: 768, height: 576)
        let pipeline = try SubtitlePipeline(
            overlay: SubtitleOverlayView(),
            presentsOverlay: false
        )
        try pipeline.installExternal(data: Data(Self.twoCueASS.utf8))
        let compositor = try PiPSubtitleCompositor(subtitles: pipeline)
        let source = try blackPixelBuffer(size: codedSize)

        let composed = try await compositor.composedPixelBufferForTesting(
            decodedFrame(
                pixelBuffer: source,
                size: codedSize,
                seconds: 0.5,
                displaySize: displaySize,
                pixelAspectRatio: CGSize(width: 16, height: 15)
            )
        )

        #expect(CVPixelBufferGetWidth(composed) == 768)
        #expect(CVPixelBufferGetHeight(composed) == 576)
        #expect(nonblackPixelCount(composed) > 100)
        pipeline.terminate()
    }

    @Test @MainActor
    func compositorAcceptsSDRVideoRangeAndFullRangeNV12() async throws {
        let size = CGSize(width: 640, height: 360)
        let pipeline = try SubtitlePipeline(
            overlay: SubtitleOverlayView(),
            presentsOverlay: false
        )
        try pipeline.installExternal(data: Data(Self.twoCueASS.utf8))
        let compositor = try PiPSubtitleCompositor(subtitles: pipeline)

        for fullRange in [false, true] {
            let source = try blackNV12PixelBuffer(
                size: size,
                fullRange: fullRange
            )
            let frame = decodedFrame(
                pixelBuffer: source,
                size: size,
                seconds: 0.5
            )
            let composed = try await compositor.composedPixelBufferForTesting(
                frame
            )
            #expect(CVPixelBufferGetPixelFormatType(composed)
                == kCVPixelFormatType_32BGRA)
            #expect(CVPixelBufferGetWidth(composed) == Int(size.width))
            #expect(CVPixelBufferGetHeight(composed) == Int(size.height))
            #expect(nonblackPixelCount(composed) > 100)
        }
        pipeline.terminate()
    }

    @Test @MainActor
    func compositorEligibilityTracksLatestFrameAndRejectsUnqualifiedVideo()
        throws
    {
        let size = CGSize(width: 640, height: 360)
        let pipeline = try SubtitlePipeline(
            overlay: SubtitleOverlayView(),
            presentsOverlay: false
        )
        let compositor = try PiPSubtitleCompositor(subtitles: pipeline)
        let source = try blackPixelBuffer(size: size)

        compositor.receive(decodedFrame(
            pixelBuffer: source,
            size: size,
            seconds: 0.5
        ))
        #expect(compositor.latestEligibility == .supported(.bgra))

        compositor.receive(decodedFrame(
            pixelBuffer: source,
            size: size,
            seconds: 0.5,
            sourceComponentDepth: 10,
            ffmpegPixelFormat: "yuv420p10le"
        ))
        #expect(compositor.latestEligibility == .supported(.bgra))

        compositor.receive(decodedFrame(
            pixelBuffer: source,
            size: size,
            seconds: 0.5,
            transferCharacteristic: 16
        ))
        #expect(
            compositor.latestEligibility
                == .videoOnly(.hdrTransferCharacteristic(16))
        )
        pipeline.terminate()
    }

    @Test @MainActor
    func mediaSessionMirrorsEmbeddedPacketsAndSeekInvalidationToBothPipelines()
        async throws
    {
        guard let fixturePath = ProcessInfo.processInfo.environment[
            "SUPERPLAYR_PIP_FOLLOWUP_FIXTURE"
        ] ?? ProcessInfo.processInfo.environment["SUPERPLAYR_NATIVE_FIXTURE_DIR"].map({
            URL(fileURLWithPath: $0).appendingPathComponent("long-caption.mkv").path
        }) else {
            return
        }

        let size = CGSize(width: 1280, height: 720)
        let viewport = CGRect(origin: .zero, size: size)
        let presentation = try NativePresentationCoordinator()
        let mainOverlay = SubtitleOverlayView(frame: viewport)
        mainOverlay.updateDrawableSize(backingScale: 1)
        let main = try SubtitlePipeline(
            overlay: mainOverlay,
            deduplicatesPackets: true
        )
        let pip = try SubtitlePipeline(
            overlay: SubtitleOverlayView(),
            presentsOverlay: false,
            deduplicatesPackets: true
        )
        let session = try MediaSession(
            url: URL(fileURLWithPath: fixturePath),
            presentation: presentation,
            subtitles: main,
            pictureInPictureSubtitles: pip
        )

        session.start(rate: 0)
        #expect(await waitUntil {
            main.eventCount > 0 && pip.eventCount == main.eventCount
        })

        main.render(
            at: CMTime(seconds: 1, preferredTimescale: 1_000),
            viewport: viewport,
            videoSize: size
        )
        let initialPiP = pip.pictureInPictureSubtitleSnapshot(
            at: CMTime(seconds: 1, preferredTimescale: 1_000),
            viewport: viewport,
            videoSize: size
        )
        #expect(await waitUntil { main.counters().overlayCommits > 0 })
        #expect(!initialPiP.regions.isEmpty)
        let initialMainFrames = main.counters().libassFrames
        let initialPiPFrames = pip.counters().libassFrames

        session.seek(to: 75, exact: true, resumeRate: 0)
        try await Task.sleep(for: .milliseconds(600))
        main.render(
            at: CMTime(seconds: 75, preferredTimescale: 1_000),
            viewport: viewport,
            videoSize: size
        )
        let soughtPiP = pip.pictureInPictureSubtitleSnapshot(
            at: CMTime(seconds: 75, preferredTimescale: 1_000),
            viewport: viewport,
            videoSize: size
        )

        #expect(await waitUntil {
            main.counters().libassFrames > initialMainFrames
        })
        #expect(pip.counters().libassFrames > initialPiPFrames)
        #expect(!soughtPiP.regions.isEmpty)
        #expect(main.eventCount == pip.eventCount)
        #expect(session.snapshot().rendererFailure == nil)

        session.seek(to: 1, exact: true, resumeRate: 0)
        #expect(await waitUntil {
            let snapshot = pip.pictureInPictureSubtitleSnapshot(
                at: CMTime(seconds: 1, preferredTimescale: 1_000),
                viewport: viewport, videoSize: size)
            return !snapshot.regions.isEmpty
                && session.snapshot().generation >= 2
        })

        session.stop()
        #expect(session.waitForShutdown(timeout: .now() + 3))
        main.terminate()
        pip.terminate()
        presentation.terminate()
    }

    @Test @MainActor
    func hiddenHostKeepsViewAndDisplayLayerGeometryInSync() throws {
        try autoreleasepool {
            let initialSize = CGSize(width: 640, height: 360)
            let resizedSize = CGSize(width: 480, height: 360)
            let parent = NSView(frame: CGRect(origin: .zero, size: initialSize))
            let parentWindow = NSWindow(
                contentRect: CGRect(origin: .zero, size: initialSize),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            parentWindow.animationBehavior = .none
            parentWindow.isReleasedWhenClosed = false
            parentWindow.contentView = parent
            let displayLayer = AVSampleBufferDisplayLayer()
            displayLayer.bounds = CGRect(origin: .zero, size: initialSize)

            let host = try #require(
                PiPSubtitleDisplayLayerHost(
                    displayLayer: displayLayer,
                    parentView: parent
                )
            )
            var geometry = host.geometryForTesting()
            #expect(geometry.panelSize == initialSize)
            #expect(geometry.viewSize == initialSize)
            #expect(geometry.layerFrame == CGRect(origin: .zero, size: initialSize))
            #expect(geometry.layerBounds.size == initialSize)
            #expect(geometry.panelVisible)
            #expect(!NSScreen.screens.contains { $0.frame.intersects(geometry.panelFrame) })

            host.setSize(resizedSize)
            geometry = host.geometryForTesting()
            #expect(geometry.panelSize == resizedSize)
            #expect(geometry.viewSize == resizedSize)
            #expect(geometry.layerFrame == CGRect(origin: .zero, size: resizedSize))
            #expect(geometry.layerBounds.size == resizedSize)
            #expect(geometry.panelVisible)
            #expect(!NSScreen.screens.contains { $0.frame.intersects(geometry.panelFrame) })

            host.tearDown()
            #expect(displayLayer.superlayer == nil)
            parentWindow.orderOut(nil)
            parentWindow.contentView = nil
        }
    }
}
