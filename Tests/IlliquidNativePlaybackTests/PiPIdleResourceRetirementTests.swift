import CoreMedia
import CoreVideo
import Foundation
import Testing
@testable import IlliquidNativePlayback

@Suite("PiP idle resource retirement", .serialized)
struct PiPIdleResourceRetirementTests {
    @Test @MainActor
    func stopReleasesSubtitleWorkingSetAndItsBudgetReservation() async throws {
        let budget = SubtitleMemoryBudget(limitBytes: 64 * 1_024 * 1_024, ownerLimitsBytes: [:])
        let unrelated = try #require(budget.acquire(owner: .mainStaging, bytes: 4_096))
        defer { withExtendedLifetime(unrelated) {} }
        let pipeline = try bitmapPipeline(color: [0, 0, 255, 255])
        defer { pipeline.terminate() }
        let compositor = try PiPSubtitleCompositor(subtitles: pipeline, memoryBudget: budget)
        defer { compositor.stop() }
        let frame = decodedFrame(try blackBGRA())
        _ = try await compositor.composedPixelBufferForTesting(frame)
        let warm = await compositor.resourceSnapshotForTesting()
        #expect(warm.hasOutputPool)
        #expect(warm.hasOutputPoolObserver)
        #expect(warm.outputBufferIdentityCount > 0)
        #expect(warm.subtitleTextureAllocatedBytes > 0)
        #expect(warm.subtitleVertexAllocatedBytes > 0)
        #expect(warm.stagingBytes > 0)
        #expect(warm.preparedPixelBytes > 0)
        #expect(budget.snapshot.reservationsByOwner[.pictureInPictureStaging] == warm.stagingBytes)

        compositor.stop()
        assertRetired(try await waitForStoppedWorker(compositor))
        #expect(budget.snapshot.reservationsByOwner[.pictureInPictureStaging] == 0)
        #expect(budget.snapshot.reservationsByOwner[.mainStaging] == 4_096)
    }

    @Test @MainActor
    func poolRetirementPreservesHeldOutputAndExactSameTimestampRecomposition() async throws {
        let pipeline = try bitmapPipeline(color: [0, 0, 128, 128])
        defer { pipeline.terminate() }
        let compositor = try PiPSubtitleCompositor(subtitles: pipeline)
        defer { compositor.stop() }
        let frame = decodedFrame(try blackBGRA())
        let heldOutput = try await compositor.composedPixelBufferForTesting(frame)
        let expected = try bgraPixels(heldOutput)
        #expect(Array(expected[(5 * 64 + 5) * 4..<(5 * 64 + 5) * 4 + 4]) == [0, 0, 128, 255])

        compositor.stop()
        assertRetired(try await waitForStoppedWorker(compositor))
        // An external renderer/caller may still own a buffer from the retired
        // pool. Retiring the cache must not invalidate that buffer's pixels.
        #expect(try bgraPixels(heldOutput) == expected)

        // The subtitle pipeline returns unchanged regions at this timestamp.
        // Reentry must rebuild retired uploads despite changed == false.
        let rebuilt = try await compositor.composedPixelBufferForTesting(frame)
        #expect(try bgraPixels(rebuilt) == expected)
        #expect(compositor.metricsSnapshot().subtitleTextureUploads == 2)
        let rebuiltResources = await compositor.resourceSnapshotForTesting()
        #expect(rebuiltResources.hasOutputPool)
        #expect(rebuiltResources.subtitleTextureAllocatedBytes > 0)
        compositor.stop()
        assertRetired(try await waitForStoppedWorker(compositor))
    }

    @Test @MainActor
    func stoppingUHDHDRCompositionReleasesItsLargeWorkingTexture() async throws {
        let width = 3_840
        let height = 2_160
        let compositor = try PiPSubtitleCompositor()
        defer { compositor.stop() }
        let source = try blackP010(width: width, height: height)
        let frame = decodedFrame(source, hdr: true)
        let output = try await compositor.composedPixelBufferForTesting(frame)
        #expect(CVPixelBufferGetPixelFormatType(output) == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
        let warm = await compositor.resourceSnapshotForTesting()
        // No silent fallback/skip: this case must exercise the real rgba16Float
        // HDR intermediate, not merely an SDR buffer with HDR metadata.
        #expect(warm.hdrTextureAllocatedBytes >= width * height * 8)
        #expect(warm.hasOutputPool)

        compositor.stop()
        assertRetired(try await waitForStoppedWorker(compositor))
        #expect(CVPixelBufferGetWidth(output) == width)
        #expect(CVPixelBufferGetHeight(output) == height)
    }

    @Test @MainActor
    func pausedReentryRebuildsTheSameCaptionAndDisplaysImmediately() async throws {
        let pipeline = try bitmapPipeline(color: [0, 255, 0, 255])
        defer { pipeline.terminate() }
        let compositor = try PiPSubtitleCompositor(subtitles: pipeline)
        defer { compositor.stop() }
        let callbacks = CallbackCounts()
        compositor.receive(decodedFrame(try blackBGRA()))
        start(compositor, callbacks: callbacks)
        _ = try await waitForPresentedFrame(compositor)
        #expect(compositor.metricsSnapshot().subtitleVisibleFrames == 1)
        #expect(compositor.metricsSnapshot().immediatelyDisplayedFrames == 1)

        compositor.stop()
        assertRetired(try await waitForStoppedWorker(compositor))
        #expect(compositor.latestEligibility != nil)

        // No new receive(): the retained paused frame is the only input.
        start(compositor, callbacks: callbacks)
        let reopened = try await waitForPresentedFrame(compositor)
        #expect(reopened.hasOutputPool)
        #expect(reopened.subtitleTextureAllocatedBytes > 0)
        let metrics = compositor.metricsSnapshot()
        #expect(metrics.subtitleVisibleFrames == 1)
        #expect(metrics.immediatelyDisplayedFrames == 1)
        #expect(metrics.subtitleTextureUploads == 1)
        #expect(callbacks.snapshot.successes == 2)
        #expect(callbacks.snapshot.failures == 0)
        compositor.stop()
        assertRetired(try await waitForStoppedWorker(compositor))
    }

    @Test @MainActor
    func rapidStopRestartKeepsTheFinalSessionLiveThenRetiresIt() async throws {
        let pipeline = try bitmapPipeline(color: [255, 0, 0, 255])
        defer { pipeline.terminate() }
        let compositor = try PiPSubtitleCompositor(subtitles: pipeline)
        defer { compositor.stop() }
        let callbacks = CallbackCounts()
        compositor.receive(decodedFrame(try blackBGRA()))
        start(compositor, callbacks: callbacks)
        _ = try await waitForPresentedFrame(compositor)

        // Deliberately do not drain the queue between a stop and its restart.
        // Old cleanup/completion tasks must not erase the final active session.
        for _ in 0..<3 {
            for _ in 0..<8 {
                compositor.stop()
                start(compositor, callbacks: callbacks)
            }
            let current = try await waitForPresentedFrame(compositor)
            #expect(current.isActive)
            #expect(current.hasOutputPool)
            #expect(current.hasOutputPoolObserver)
            #expect(current.subtitleTextureAllocatedBytes > 0)
            #expect(compositor.metricsSnapshot().subtitleVisibleFrames > 0)
        }
        #expect(callbacks.snapshot.failures == 0)
        compositor.stop()
        assertRetired(try await waitForStoppedWorker(compositor))
    }

    @Test @MainActor
    func pipelineRebindWhileStoppedStillRetiresResourcesAndUsesNewPixels() async throws {
        let first = try bitmapPipeline(color: [0, 0, 255, 255])
        let replacement = try bitmapPipeline(color: [0, 255, 0, 255])
        defer { first.terminate(); replacement.terminate() }
        let compositor = try PiPSubtitleCompositor(subtitles: first)
        defer { compositor.stop() }
        let frame = decodedFrame(try blackBGRA())
        let red = try bgraPixels(try await compositor.composedPixelBufferForTesting(frame))

        compositor.stop()
        // Rebinding changes the composition revision even though PiP remains
        // stopped. That must not suppress idle-resource retirement.
        compositor.setSubtitlePipeline(replacement)
        assertRetired(try await waitForStoppedWorker(compositor))
        #expect(compositor.subtitlePipelineIdentityForTesting == ObjectIdentifier(replacement))
        let green = try bgraPixels(try await compositor.composedPixelBufferForTesting(frame))
        #expect(green != red)
        #expect(Array(green[(5 * 64 + 5) * 4..<(5 * 64 + 5) * 4 + 4]) == [0, 255, 0, 255])
        compositor.stop()
        assertRetired(try await waitForStoppedWorker(compositor))
    }

    @Test @MainActor
    func repeatedStopIsSafeBeforeAndAfterAllocatingResources() async throws {
        let compositor = try PiPSubtitleCompositor()
        defer { compositor.stop() }
        for _ in 0..<3 { compositor.stop() }
        assertRetired(try await waitForStoppedWorker(compositor))

        _ = try await compositor.composedPixelBufferForTesting(decodedFrame(try blackBGRA()))
        #expect(await compositor.resourceSnapshotForTesting().hasOutputPool)
        for _ in 0..<3 { compositor.stop() }
        assertRetired(try await waitForStoppedWorker(compositor))
        compositor.stop()
        assertRetired(try await waitForStoppedWorker(compositor))
    }

    private func assertRetired(_ snapshot: PiPSubtitleResourceSnapshot) {
        #expect(!snapshot.isActive)
        #expect(!snapshot.workerActive)
        #expect(!snapshot.hasOutputPool)
        #expect(!snapshot.hasOutputPoolObserver)
        #expect(snapshot.outputBufferIdentityCount == 0)
        #expect(snapshot.hdrTextureAllocatedBytes == 0)
        #expect(snapshot.subtitleTextureAllocatedBytes == 0)
        #expect(snapshot.subtitleVertexAllocatedBytes == 0)
        #expect(snapshot.stagingBytes == 0)
        #expect(snapshot.preparedPixelBytes == 0)
        // deviceAllocatedBytes also includes framework caches and resources
        // retained by callers; it is intentionally not a correctness oracle.
    }

    private enum WaitFailure: Error { case stoppedWorkerTimeout, presentedFrameTimeout }

    private func waitForStoppedWorker(_ compositor: PiPSubtitleCompositor) async throws -> PiPSubtitleResourceSnapshot {
        let deadline = Date().addingTimeInterval(5)
        repeat {
            let snapshot = await compositor.resourceSnapshotForTesting()
            if !snapshot.isActive, !snapshot.workerActive { return snapshot }
            try await Task.sleep(for: .milliseconds(10))
        } while Date() < deadline
        throw WaitFailure.stoppedWorkerTimeout
    }

    private func waitForPresentedFrame(_ compositor: PiPSubtitleCompositor) async throws -> PiPSubtitleResourceSnapshot {
        let deadline = Date().addingTimeInterval(5)
        repeat {
            let snapshot = await compositor.resourceSnapshotForTesting()
            if snapshot.isActive, !snapshot.workerActive,
               compositor.metricsSnapshot().composedFrames > 0 { return snapshot }
            try await Task.sleep(for: .milliseconds(10))
        } while Date() < deadline
        throw WaitFailure.presentedFrameTimeout
    }

    private final class CallbackCounts: @unchecked Sendable {
        private let lock = NSLock()
        private var successes = 0
        private var failures = 0
        func succeeded() { lock.withLock { successes += 1 } }
        func failed() { lock.withLock { failures += 1 } }
        var snapshot: (successes: Int, failures: Int) { lock.withLock { (successes, failures) } }
    }

    private func start(_ compositor: PiPSubtitleCompositor, callbacks: CallbackCounts) {
        compositor.start(onFirstSample: { result in
            if case .success = result { callbacks.succeeded() }
            else { callbacks.failed() }
        }, onFailure: { _ in callbacks.failed() })
    }

    @MainActor
    private func bitmapPipeline(color: [UInt8]) throws -> SubtitlePipeline {
        let size = CGSize(width: 64, height: 32)
        let pipeline = try SubtitlePipeline(overlay: SubtitleOverlayView(headless: true), presentsOverlay: false)
        _ = try pipeline.configure(codecPrivate: nil, codecName: "hdmv_pgs_subtitle",
            attachments: [], frameSize: size, storageSize: size)
        let rect = CGRect(x: 4, y: 4, width: 8, height: 4)
        let pixels = Data((0..<32).flatMap { _ in color })
        let composition = NativeBitmapSubtitleComposition(
            regions: [.init(pixels: pixels, frame: rect, isForced: false)],
            canvasSize: size, duration: 4, memoryLease: nil)
        try #require(pipeline.process(event: .init(assData: Data(), presentationSeconds: 0,
            durationSeconds: 4, generation: 0, bitmapComposition: composition)))
        return pipeline
    }

    private func decodedFrame(_ source: CVPixelBuffer, hdr: Bool = false) -> NativeDecodedVideoFrame {
        let size = CGSize(width: CVPixelBufferGetWidth(source), height: CVPixelBufferGetHeight(source))
        return NativeDecodedVideoFrame(pixelBuffer: source, planarOwnershipToken: nil,
            presentationTime: CMTime(value: 1, timescale: 2), duration: CMTime(value: 1, timescale: 30), generation: 0,
            codedSize: size, displaySize: size, pixelAspectRatio: CGSize(width: 1, height: 1), rotationDegrees: 0,
            colorPrimaries: hdr ? 9 : nil, transferCharacteristic: hdr ? 16 : nil,
            matrixCoefficients: hdr ? 9 : nil, isFullRange: !hdr,
            hasMasteringDisplayMetadata: false, hasContentLightMetadata: false,
            sourceComponentDepth: hdr ? 10 : 8, ffmpegPixelFormat: hdr ? "p010le" : "bgra",
            isHardwareDecoded: false, isCopiedHardwarePath: false, isNearZeroCopy: false)
    }

    private func blackBGRA() throws -> CVPixelBuffer {
        let buffer = try pixelBuffer(width: 64, height: 32, format: kCVPixelFormatType_32BGRA)
        try #require(CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = try #require(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        memset(base, 0, rowBytes * 32)
        for y in 0..<32 {
            for x in 0..<64 { base[y * rowBytes + x * 4 + 3] = 255 }
        }
        return buffer
    }

    private func blackP010(width: Int, height: Int) throws -> CVPixelBuffer {
        let buffer = try pixelBuffer(width: width, height: height, format: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
        try #require(CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        for plane in 0..<2 {
            let base = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, plane)).assumingMemoryBound(to: UInt16.self)
            let count = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) / 2 * CVPixelBufferGetHeightOfPlane(buffer, plane)
            base.initialize(repeating: UInt16((plane == 0 ? 64 : 512) << 6), count: count)
        }
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
        return buffer
    }

    private func pixelBuffer(width: Int, height: Int, format: OSType) throws -> CVPixelBuffer {
        let attributes: [CFString: Any] = [kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:]]
        var buffer: CVPixelBuffer?
        try #require(CVPixelBufferCreate(kCFAllocatorDefault, width, height, format,
            attributes as CFDictionary, &buffer) == kCVReturnSuccess)
        return try #require(buffer)
    }

    private func bgraPixels(_ buffer: CVPixelBuffer) throws -> [UInt8] {
        try #require(CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA)
        try #require(CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = try #require(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(width * height * 4)
        for row in 0..<height {
            bytes.append(contentsOf: UnsafeBufferPointer(start: base + row * rowBytes, count: width * 4))
        }
        return bytes
    }
}
