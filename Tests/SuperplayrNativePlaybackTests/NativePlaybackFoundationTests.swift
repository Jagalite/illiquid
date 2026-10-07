import AppKit
import CFFmpeg
import CoreMedia
import CoreVideo
import Foundation
import Metal
import SuperplayrPlayback
import SuperplayrPlaybackCore
import Testing
@testable import SuperplayrNativePlayback

@Suite("Native Picture in Picture geometry")
struct NativePictureInPictureGeometryTests {
    @Test func matchesSourceLayerBoundsToPictureInPictureViewport() {
        let size = NativePlayerNSView.sourceLayerSize(
            presentationSize: CGSize(width: 1_280, height: 720),
            pictureInPictureViewportSize: CGSize(width: 560, height: 315),
            quarterTurn: false
        )

        #expect(size == CGSize(width: 560, height: 315))
    }

    @Test func preservesQuarterTurnTransformGeometry() {
        let size = NativePlayerNSView.sourceLayerSize(
            presentationSize: CGSize(width: 720, height: 1_280),
            pictureInPictureViewportSize: CGSize(width: 315, height: 560),
            quarterTurn: true
        )

        #expect(size == CGSize(width: 560, height: 315))
    }

    @Test func inactivePictureInPictureUsesThePlayerViewport() {
        let size = NativePlayerNSView.sourceLayerSize(
            presentationSize: CGSize(width: 1_000, height: 600),
            pictureInPictureViewportSize: nil,
            quarterTurn: false
        )

        #expect(size == CGSize(width: 1_000, height: 600))
    }

    @Test @MainActor
    func composedPictureInPictureSuppressesAndRestoresTheMainSurface() {
        let presenter = SampleBufferVideoPresenter()
        let overlay = SubtitleOverlayView()
        let view = NativePlayerNSView(
            videoLayer: presenter.displayLayer,
            subtitleOverlay: overlay,
            rotationDegrees: 0
        )

        view.setMainPresentationSuppressed(true)
        #expect(view.isMainPresentationSuppressed)
        #expect(presenter.displayLayer.isHidden)
        #expect(overlay.alphaValue == 0)

        let replacement = SampleBufferVideoPresenter()
        view.rebindVideoLayer(replacement.displayLayer)
        #expect(replacement.displayLayer.isHidden)

        view.setMainPresentationSuppressed(false)
        #expect(!view.isMainPresentationSuppressed)
        #expect(!replacement.displayLayer.isHidden)
        #expect(overlay.alphaValue == 1)
    }

    @Test @MainActor
    func mouseMovementOnNativeSurfaceDefersToWindowRevealPolicy() throws {
        let presenter = SampleBufferVideoPresenter()
        let view = NativePlayerNSView(
            videoLayer: presenter.displayLayer,
            subtitleOverlay: SubtitleOverlayView(),
            rotationDegrees: 0
        )
        var activityCount = 0
        view.onUserActivity = {
            activityCount += 1
        }
        let event = try #require(NSEvent.mouseEvent(
            with: .mouseMoved,
            location: CGPoint(x: 20, y: 20),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 0,
            pressure: 0
        ))

        view.mouseMoved(with: event)

        #expect(activityCount == 0)
    }
}

@Suite("Native damaged-stream hardening policies")
struct NativeDamagedStreamHardeningPolicyTests {
    @Test func demuxRetryBudgetSeparatesCorruptionFromOtherErrors() {
        var policy = FFmpegDemuxReadRetryPolicy()
        for _ in 0..<FFmpegDemuxReadRetryPolicy.maximumConsecutiveOtherErrors {
            #expect(policy.decision(for: -5, elapsedNoProgressSeconds: 0.01) == .retry)
        }
        #expect(policy.decision(for: -5, elapsedNoProgressSeconds: 0.01) == .fail)

        var corruptPolicy = FFmpegDemuxReadRetryPolicy()
        for _ in 0..<FFmpegDemuxReadRetryPolicy.maximumConsecutiveInvalidDataReads {
            #expect(corruptPolicy.decision(
                for: superplayr_averror_invaliddata(),
                elapsedNoProgressSeconds: 0.01
            ) == .retry)
        }
        #expect(corruptPolicy.decision(
            for: superplayr_averror_invaliddata(),
            elapsedNoProgressSeconds: 0.01
        ) == .fail)
    }

    @Test func demuxRetryBudgetNeverRetriesInterruptionOrExpiredProgress() {
        var interrupted = FFmpegDemuxReadRetryPolicy()
        #expect(interrupted.decision(
            for: superplayr_averror_exit(),
            elapsedNoProgressSeconds: 0
        ) == .fail)

        var expired = FFmpegDemuxReadRetryPolicy()
        #expect(expired.decision(
            for: superplayr_averror_eagain(),
            elapsedNoProgressSeconds: FFmpegDemuxReadRetryPolicy.maximumNoProgressSeconds
        ) == .fail)
    }

    @Test func audioSanitizationZerosInvalidSamplesOnly() {
        var samples: [Float] = [0.25, .nan, .infinity, -.infinity, .leastNonzeroMagnitude, -0.5]
        var data = samples.withUnsafeBytes { Data($0) }

        let result = sanitizeInterleavedFloatPCM(&data)
        samples = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }

        #expect(result.replacedNonFiniteSamples == 3)
        #expect(result.replacedSubnormalSamples == 1)
        #expect(samples == [0.25, 0, 0, 0, 0, -0.5])
    }

    @Test func softwareDecodeProgressResetsOnSuccessfulFrame() {
        var budget = SoftwareVideoDecodeProgressBudget()
        for _ in 0..<(SoftwareVideoDecodeProgressBudget.maximumConsecutiveErrors - 1) {
            let exhausted = budget.recordError()
            #expect(!exhausted)
        }
        budget.recordFrame()
        #expect(budget.consecutiveErrors == 0)
        for _ in 0..<SoftwareVideoDecodeProgressBudget.maximumConsecutiveErrors {
            _ = budget.recordError()
        }
        #expect(budget.consecutiveErrors
            == SoftwareVideoDecodeProgressBudget.maximumConsecutiveErrors)
    }

    @Test func timestampValidatorDropsSmallBackwardPTSAndSegmentsLargeJumps() {
        var validator = VideoTimestampValidator()
        let duration = CMTime(value: 1, timescale: 30)
        #expect(validator.validate(CMTime(seconds: 1, preferredTimescale: 600),
                                   duration: duration)
            == .accept(CMTime(seconds: 1, preferredTimescale: 600),
                       beginsDiscontinuity: false))
        #expect(validator.validate(CMTime(seconds: 0.8, preferredTimescale: 600),
                                   duration: duration) == .drop)
        #expect(validator.validate(CMTime(seconds: 8, preferredTimescale: 600),
                                   duration: duration)
            == .accept(CMTime(seconds: 8, preferredTimescale: 600),
                       beginsDiscontinuity: true))
    }

    @Test func h264DecoderAdvertisesVideoToolboxConfiguration() throws {
        var parameters: UnsafeMutablePointer<AVCodecParameters>? = avcodec_parameters_alloc()
        let owned = try #require(parameters)
        defer { avcodec_parameters_free(&parameters) }
        owned.pointee.codec_type = AVMEDIA_TYPE_VIDEO
        owned.pointee.codec_id = AV_CODEC_ID_H264
        #expect(superplayr_decoder_supports_videotoolbox(owned) != 0)
    }

    @Test func unknownDecoderDoesNotAdvertiseVideoToolboxConfiguration() throws {
        var parameters: UnsafeMutablePointer<AVCodecParameters>? = avcodec_parameters_alloc()
        let owned = try #require(parameters)
        defer { avcodec_parameters_free(&parameters) }
        owned.pointee.codec_type = AVMEDIA_TYPE_VIDEO
        owned.pointee.codec_id = AV_CODEC_ID_NONE
        #expect(superplayr_decoder_supports_videotoolbox(owned) == 0)
    }

    @Test func audioPresentationRecoveryFlushesThenReplacesRenderer() throws {
        let presentation = try NativePresentationCoordinator()
        defer { presentation.terminate() }
        let original = ObjectIdentifier(presentation.audio.renderer)

        let flushFence = try presentation.recoverAudioPresentation(rebuildGraph: false)
        #expect(ObjectIdentifier(presentation.audio.renderer) == original)

        let rebuildFence = try presentation.recoverAudioPresentation(rebuildGraph: true)
        #expect(rebuildFence > flushFence)
        #expect(ObjectIdentifier(presentation.audio.renderer) != original)
    }
}

@Suite("Native player click routing")
@MainActor
struct NativePlayerClickRoutingTests {
    private final class KeyWindow: NSWindow {
        var keyForTesting = true
        override var isKeyWindow: Bool { keyForTesting }
    }

    private func makeSurface() -> (NativePlayerNSView, KeyWindow) {
        let presenter = SampleBufferVideoPresenter()
        let view = NativePlayerNSView(videoLayer: presenter.displayLayer,
            subtitleOverlay: SubtitleOverlayView(), rotationDegrees: 0)
        let window = KeyWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        return (view, window)
    }

    private func event(_ type: NSEvent.EventType, window: NSWindow,
                       count: Int = 1, x: CGFloat = 20) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: CGPoint(x: x, y: 20),
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: count, pressure: 0))
    }

    private func click(_ view: NativePlayerNSView, window: NSWindow,
                       count: Int = 1, x: CGFloat = 20) throws {
        view.mouseDown(with: try event(.leftMouseDown, window: window, count: count, x: x))
        view.mouseUp(with: try event(.leftMouseUp, window: window, count: count, x: x))
    }

    private func waitForSingleClick() async throws {
        try await Task.sleep(for: .seconds(NSEvent.doubleClickInterval + 0.1))
    }

    @Test func singleClickWaitsForDoubleClickInterval() async throws {
        let (view, window) = makeSurface()
        defer { window.close() }
        var interactions: [PlaybackSurfaceInteraction] = []
        view.onInteraction = { interactions.append($0) }
        try click(view, window: window)
        #expect(interactions.isEmpty)
        try await waitForSingleClick()
        #expect(interactions == [.primaryClick])
    }

    @Test(arguments: [CGFloat(20), 200, 380])
    func doubleClickCancelsSingleClick(x: CGFloat) async throws {
        let (view, window) = makeSurface()
        defer { window.close() }
        var interactions: [PlaybackSurfaceInteraction] = []
        view.onInteraction = { interactions.append($0) }
        try click(view, window: window, x: x)
        try click(view, window: window, count: 2, x: x)
        let expected: PlaybackSurfaceInteraction = x == 20 ? .doubleClickSeek(-5)
            : x == 380 ? .doubleClickSeek(5) : .doubleClick
        #expect(interactions == [expected])
        try await waitForSingleClick()
        #expect(interactions == [expected])
    }

    @Test(arguments: [CGFloat(20), 200, 380])
    func continuedTapsSeekWithoutRepeatedFullscreenToggles(x: CGFloat) throws {
        let (view, window) = makeSurface()
        defer { window.close() }
        var interactions: [PlaybackSurfaceInteraction] = []
        view.onInteraction = { interactions.append($0) }
        for count in 1...4 {
            try click(view, window: window, count: count, x: x)
        }
        if x == 200 {
            #expect(interactions == [.doubleClick])
        } else {
            let seek: PlaybackSurfaceInteraction = .doubleClickSeek(x == 20 ? -5 : 5)
            #expect(interactions == [seek, seek, seek])
        }
    }

    @Test func rejectedPressesDoNotSeek() throws {
        let (view, window) = makeSurface()
        defer { window.close() }
        var interactions: [PlaybackSurfaceInteraction] = []
        view.onInteraction = { interactions.append($0) }
        view.mouseUp(with: try event(.leftMouseUp, window: window, count: 2))
        view.mouseDown(with: try event(.leftMouseDown, window: window, count: 2))
        view.mouseDragged(with: try event(.leftMouseDragged, window: window, count: 2, x: 40))
        view.mouseUp(with: try event(.leftMouseUp, window: window, count: 2))
        try click(view, window: window, count: 2, x: -1)
        window.keyForTesting = false
        try click(view, window: window, count: 2)
        #expect(interactions.isEmpty)
    }

    @Test func detachingSurfaceCancelsPendingSingleClick() async throws {
        let (view, window) = makeSurface()
        defer { window.close() }
        var interactions: [PlaybackSurfaceInteraction] = []
        view.onInteraction = { interactions.append($0) }
        try click(view, window: window)
        window.contentView = nil
        window.contentView = view
        try await waitForSingleClick()
        #expect(interactions.isEmpty)
    }
}

@Suite("Native subtitle render policy")
struct NativeSubtitleRenderPolicyTests {
    @Test func rendersOnlyForAnEnabledActiveSubtitleSource() {
        #expect(!NativeSubtitleRenderPolicy.shouldRender(
            isEnabled: true,
            hasEmbeddedSubtitle: false,
            hasExternalSubtitle: false
        ))
        #expect(!NativeSubtitleRenderPolicy.shouldRender(
            isEnabled: false,
            hasEmbeddedSubtitle: true,
            hasExternalSubtitle: false
        ))
        #expect(NativeSubtitleRenderPolicy.shouldRender(
            isEnabled: true,
            hasEmbeddedSubtitle: true,
            hasExternalSubtitle: false
        ))
        #expect(NativeSubtitleRenderPolicy.shouldRender(
            isEnabled: true,
            hasEmbeddedSubtitle: false,
            hasExternalSubtitle: true
        ))
    }

    @Test func subtitlePacketArrivalInvalidatesTheCurrentPresentationTime() {
        #expect(!NativeSubtitleRenderPolicy.hasNewSubtitlePacket(current: 0, previous: 0))
        #expect(!NativeSubtitleRenderPolicy.hasNewSubtitlePacket(current: 8, previous: 8))
        #expect(!NativeSubtitleRenderPolicy.hasNewSubtitlePacket(current: 8, previous: 9))
        #expect(NativeSubtitleRenderPolicy.hasNewSubtitlePacket(current: 9, previous: 8))
    }

}

@Suite("Native playback foundations")
struct NativePlaybackFoundationTests {
    @Test @MainActor
    func packagedMetalLibraryContainsEveryProductionShader() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let library = try NativeMetalShaderLibrary.load(device: device)

        for functionName in [
            "ass_vertex",
            "ass_r8_fragment",
            "ass_r8_premultiplied_fragment",
            "ass_bgra_fragment",
            "pip_video_vertex",
            "pip_bgra_fragment",
            "pip_nv12_fragment",
            "pip_subtitle_vertex",
            "pip_subtitle_fragment",
            "pip_bitmap_subtitle_fragment",
        ] {
            #expect(library.makeFunction(name: functionName) != nil)
        }
    }

    @Test @MainActor
    func headlessSubtitleOverlayDoesNotInitializeMetal() {
        let overlay = SubtitleOverlayView(headless: true)

        #expect(overlay.diagnosticsSnapshot().metalInitializationAttempts == 0)
        #expect(overlay.layer == nil)
    }

    @Test @MainActor
    func surfaceCreationLeavesPictureInPictureSubtitleInfrastructureDeferred() async throws {
        let runtime = try NativePlaybackRuntime()

        #expect(!runtime.hasPreparedPictureInPictureSubtitleInfrastructureForTesting)
        _ = try runtime.makeSurfaceHost()
        #expect(!runtime.hasPreparedPictureInPictureSubtitleInfrastructureForTesting)

        await runtime.shutdown()
    }

    @Test func cancellationBeforeOpenAdmissionRemainsVisibleToNativeInput() {
        let cancellation = FFmpegInputCancellationSignal()
        cancellation.requestCancellation()

        #expect(throws: FFmpegInputExecutorError.operationCancelled) {
            try FFmpegInputExecutor(
                url: URL(fileURLWithPath: "/nonexistent/cancelled-before-open"),
                cancellationSignal: cancellation
            )
        }
    }

    @Test func formatCompletionRequiresTheExactRevisionAndShutdownCancelsWaiters() {
        let barrier = NativeFormatReconfigurationBarrier()
        let revision = MediaFormatRevisionID(rawValue: 7)
        let waiter = barrier.begin(.video, revision: revision)

        barrier.complete(
            .video,
            revision: MediaFormatRevisionID(rawValue: 8)
        )
        #expect(waiter.wait(timeout: .now()) == .timedOut)

        barrier.complete(.video, revision: revision)
        #expect(waiter.wait(timeout: .now()) == .success)

        let shutdownWaiter = barrier.begin(
            .audio,
            revision: MediaFormatRevisionID(rawValue: 9)
        )
        barrier.cancelAll()
        #expect(shutdownWaiter.wait(timeout: .now()) == .success)
    }

    @Test func rendererClockAdvanceIsGenerationScopedAndRequiresMovement() {
        var ledger = RendererClockAdvanceLedger(baselineSeconds: 4)
        ledger.observe(mediaTimeSeconds: 4, uptimeSeconds: 10)
        ledger.observe(mediaTimeSeconds: 4.0005, uptimeSeconds: 11)
        #expect(ledger.firstAdvanceUptimeSeconds == nil)
        ledger.observe(mediaTimeSeconds: 4.002, uptimeSeconds: 12)
        #expect(ledger.firstAdvanceUptimeSeconds == 12)
        #expect(ledger.maximumSeconds == 4.002)

        let replacement = RendererClockAdvanceLedger(baselineSeconds: 0)
        #expect(replacement.firstAdvanceUptimeSeconds == nil)
        #expect(replacement.maximumSeconds == 0)
    }

    @Test func softwareBGRAOutputPoolBoundsAndReusesAllocations() throws {
        let pool = try SoftwareBGRAOutputPool(
            width: 64,
            height: 64,
            maximumBufferCount: 2,
            waitTimeoutMilliseconds: 0
        )
        var first: CVPixelBuffer? = try pool.makePixelBuffer()
        let second = try pool.makePixelBuffer()
        #expect(first != nil)
        #expect(throws: SoftwarePixelBufferPoolError.exhausted) {
            try pool.makePixelBuffer()
        }
        #expect(pool.exhaustionWaitCount == 1)

        first = nil
        let recycled = try pool.makePixelBuffer()
        #expect(CVPixelBufferGetWidth(recycled) == 64)
        #expect(CVPixelBufferGetHeight(recycled) == 64)
        #expect(CVPixelBufferGetPixelFormatType(recycled) == kCVPixelFormatType_32BGRA)
        withExtendedLifetime(second) {}
    }

    @Test func softwareBGRAOutputPoolCheckoutHonorsCancellation() throws {
        let pool = try SoftwareBGRAOutputPool(
            width: 64,
            height: 64,
            maximumBufferCount: 1
        )
        let held = try pool.makePixelBuffer()
        #expect(throws: SoftwarePixelBufferPoolError.cancelled) {
            try pool.makePixelBuffer(while: { false })
        }
        withExtendedLifetime(held) {}
    }

    @Test func videoFrameCapacityGateReservesBeforeSurfaceCheckout() {
        let gate = VideoFrameCapacityGate(capacity: 2)
        var first = gate.acquire(while: { true })
        var second = gate.acquire(while: { true })
        #expect(first != nil)
        #expect(second != nil)
        #expect(gate.snapshot == VideoFrameCapacitySnapshot(
            capacity: 2,
            inUse: 2,
            peakInUse: 2,
            waitingAcquisitions: 0
        ))

        first = nil
        #expect(gate.snapshot.inUse == 1)
        let replacement = gate.acquire(while: { true })
        #expect(replacement != nil)
        #expect(gate.snapshot.inUse == 2)
        withExtendedLifetime(replacement) {}

        gate.close()
        second = nil
        #expect(gate.acquire(while: { true }) == nil)
    }

    @Test func videoFrameCapacityGateCloseCancelsBlockedAcquisition() {
        let gate = VideoFrameCapacityGate(capacity: 1)
        var held = gate.acquire(while: { true })
        #expect(held != nil)
        let started = DispatchSemaphore(value: 0)
        let cancelled = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            started.signal()
            if gate.acquire(while: { true }) == nil {
                cancelled.signal()
            }
        }
        #expect(started.wait(timeout: .now() + 1) == .success)
        let waitDeadline = Date().addingTimeInterval(1)
        while gate.snapshot.waitingAcquisitions == 0, Date() < waitDeadline {
            Thread.sleep(forTimeInterval: 0.001)
        }
        #expect(gate.snapshot.waitingAcquisitions == 1)

        gate.close()
        #expect(cancelled.wait(timeout: .now() + 1) == .success)
        held = nil
        #expect(gate.snapshot.inUse == 0)
    }

    @Test func rationalToCMTimePreservesTimestamp() {
        let time = MediaTime.cmTime(
            90_000,
            timeBase: FFmpegRational(numerator: 1, denominator: 90_000)
        )
        #expect(time == CMTime(seconds: 1, preferredTimescale: 90_000))
    }

    @Test func timestampRoundTripUsesRequestedTimeBase() {
        let timeBase = FFmpegRational(numerator: 1, denominator: 1_000)
        let time = CMTime(value: 12_345, timescale: 1_000)
        #expect(MediaTime.timestamp(time, timeBase: timeBase) == 12_345)
    }

    @Test func boundedQueueAppliesFIFOAndBounds() async {
        let queue = BoundedQueue<Int>(capacity: 2)
        #expect(queue.push(1))
        #expect(queue.push(2))
        #expect(queue.count == 2)
        if case let .value(value) = queue.pop() {
            #expect(value == 1)
        } else {
            Issue.record("Queue closed unexpectedly")
        }
        #expect(queue.count == 1)
        queue.close()
    }

    @Test func boundedQueueBackpressuresProducerUntilCapacityIsAvailable() async {
        let queue = BoundedQueue<Int>(capacity: 1)
        #expect(queue.push(1))
        let blockedProducer = Task.detached { queue.push(2) }
        try? await Task.sleep(for: .milliseconds(30))
        #expect(queue.count == 1)
        if case let .value(value) = queue.pop() { #expect(value == 1) }
        #expect(await blockedProducer.value)
        if case let .value(value) = queue.pop() { #expect(value == 2) }
        queue.close()
    }

    @Test func boundedQueueAppliesByteAndDurationGrants() async {
        struct Work: Sendable {
            let bytes: Int
            let duration: Int64
        }
        let queue = BoundedQueue<Work>(
            capacity: 10,
            byteCapacity: 5,
            durationCapacityMicroseconds: 10,
            cost: { BoundedQueueCost(bytes: $0.bytes, durationMicroseconds: $0.duration) }
        )
        #expect(queue.push(Work(bytes: 4, duration: 8)))
        let blocked = Task.detached { queue.push(Work(bytes: 2, duration: 4)) }
        try? await Task.sleep(for: .milliseconds(30))
        #expect(queue.budgetSnapshot == BoundedQueueBudgetSnapshot(
            items: 1,
            bytes: 4,
            durationMicroseconds: 8
        ))
        _ = queue.pop()
        #expect(await blocked.value)
        #expect(queue.budgetSnapshot.bytes == 2)
        #expect(queue.budgetSnapshot.durationMicroseconds == 4)
        queue.close()
    }

    @Test func queueInvalidationPreemptsAProducerBlockedOnDataCapacity() async {
        let queue = BoundedQueue<Int>(capacity: 1)
        #expect(queue.push(1))
        let blocked = Task.detached { queue.push(2) }
        #expect(queue.waitForBlockedProducer(timeout: 1))
        let contention = queue.contentionSnapshot
        #expect(contention.waitingProducers == 1)
        #expect(contention.peakWaitingProducers == 1)
        #expect(contention.producerWaits >= 1)
        queue.removeAll()
        #expect(await blocked.value == false)
        #expect(queue.contentionSnapshot.producerWaitSeconds >= 0)
        #expect(queue.count == 0)
        #expect(queue.push(3))
        if case let .value(value) = queue.pop() { #expect(value == 3) }
        queue.close()
    }

    @Test func nonblockingQueuePushReportsCapacityWithoutSleeping() {
        let queue = BoundedQueue<Int>(capacity: 1)
        #expect(queue.tryPush(1) == .pushed)
        #expect(queue.tryPush(2) == .wouldBlock)
        if case let .value(value) = queue.pop() { #expect(value == 1) }
        #expect(queue.tryPush(2) == .pushed)
        queue.close()
        #expect(queue.tryPush(3) == .closed)
    }

    @Test func interleavingRouterFeedsAudioAroundFullVideoWithoutReordering() {
        enum Stream: Hashable, Sendable { case video, audio }
        let video = BoundedQueue<Int>(capacity: 1)
        let audio = BoundedQueue<Int>(capacity: 1)
        let router = BoundedInterleavingRouter(
            destinations: [Stream.video: video, .audio: audio],
            maximumPendingItems: 2,
            maximumPendingBytes: 1_024,
            maximumPendingDurationMicroseconds: 1_000_000,
            cost: { _ in BoundedQueueCost(bytes: 1, durationMicroseconds: 1) }
        )

        #expect(video.push(1))
        #expect(router.route(2, to: .video) == .pushed)
        #expect(router.route(10, to: .audio) == .pushed)
        #expect(router.route(3, to: .video) == .pushed)
        #expect(!router.canAcceptAnotherElement)
        #expect(router.route(4, to: .video) == .wouldBlock)
        #expect(router.snapshot.pendingItems == 2)
        #expect(router.snapshot.deferredItems == 2)

        if case let .value(value) = audio.pop() { #expect(value == 10) }
        if case let .value(value) = video.pop() { #expect(value == 1) }
        #expect(router.drain() == .pushed)
        if case let .value(value) = video.pop() { #expect(value == 2) }
        #expect(router.drain() == .pushed)
        if case let .value(value) = video.pop() { #expect(value == 3) }
        #expect(router.isEmpty)
        video.close()
        audio.close()
    }

    @Test func inputCancellationTargetsOnlyTheActiveEffect() {
        let state = FFmpegInterruptState()
        let active = FFmpegInputEffectToken(rawValue: 4)
        let unrelated = FFmpegInputEffectToken(rawValue: 5)
        state.begin(active)
        #expect(state.cancel(unrelated) == .targetNotActive)
        #expect(!state.shouldInterrupt())
        #expect(state.cancel(active) == .interruptRequested)
        #expect(state.shouldInterrupt())
        state.end(active)
        #expect(!state.shouldInterrupt())
    }

    @Test func inputCancellationRemainsStickyUntilTheNextReadBegins() {
        let state = FFmpegInterruptState()
        let nextRead = FFmpegInputEffectToken(rawValue: 8)

        #expect(state.cancelActive() == .targetNotActive)
        state.begin(nextRead)

        #expect(state.shouldInterrupt())
        state.end(nextRead)
        #expect(!state.shouldInterrupt())
    }

    @Test func acceptedSeekClearsDeferredReadCancellation() {
        let state = FFmpegInterruptState()
        let nextRead = FFmpegInputEffectToken(rawValue: 9)

        _ = state.cancelActive()
        state.clearDeferredReadCancellation()
        state.begin(nextRead)

        #expect(!state.shouldInterrupt())
        state.end(nextRead)
    }

    @Test func inputQuarantineIsStrictlyBoundedByWorkersAndBytes() {
        let quarantine = FFmpegInputQuarantineBudget(
            maximumWorkers: 2,
            maximumRetainedBytes: 100
        )
        #expect(quarantine.admit(workerID: 1, retainedBytes: 40))
        #expect(quarantine.admit(workerID: 2, retainedBytes: 60))
        #expect(!quarantine.admit(workerID: 3, retainedBytes: 1))
        #expect(quarantine.snapshot == FFmpegInputQuarantineSnapshot(
            workers: 2,
            retainedBytes: 100
        ))
        quarantine.release(workerID: 1)
        #expect(quarantine.admit(workerID: 3, retainedBytes: 40))
    }

    @Test func blockingInputWaitIsBoundedAndRequestsExactCancellation() {
        let completion = DispatchSemaphore(value: 0)
        var cancellationRequests = 0
        let started = Date()

        let disposition = FFmpegBlockingDeadlineWaiter.wait(
            for: completion,
            timeout: 0.01,
            cancellationGrace: 0.01
        ) {
            cancellationRequests += 1
        }

        #expect(disposition == .quarantined)
        #expect(cancellationRequests == 1)
        #expect(Date().timeIntervalSince(started) < 0.5)
    }

    @Test func exactSeekTrimsAudioAtTheFirstSampleOnOrAfterTarget() throws {
        let values = (0..<20).map(Float.init)
        let data = values.withUnsafeBytes { Data($0) }
        let frame = NativeDecodedAudioFrame(
            interleavedFloatPCM: data,
            presentationTime: .zero,
            duration: CMTime(value: 10, timescale: 10),
            generation: 2,
            sampleRate: 10,
            channelCount: 2,
            sampleCount: 10,
            sourceSampleRate: 10,
            sourceChannelCount: 2,
            sourceChannelLayout: "stereo",
            downmixOccurred: false,
            conversionOccurred: false
        )
        let trimmed = try #require(frame.trimmingSamples(before: 0.35))
        #expect(trimmed.presentationTime == CMTime(value: 4, timescale: 10))
        #expect(trimmed.sampleCount == 6)
        let retained = trimmed.interleavedFloatPCM.withUnsafeBytes {
            Array($0.bindMemory(to: Float.self))
        }
        #expect(retained.first == 8)
        #expect(retained.count == 12)
    }

    @Test func resampledAudioBuffersUseAContinuousOutputClock() {
        var timeline = ResampledAudioTimeline()
        let sourceTimes = [0.000, 0.023, 0.046, 0.070]
        let outputSampleCounts = [1_098, 1_115, 1_114, 1_115]
        var expectedOutputTime: CMTime?

        for (sourceSeconds, outputSampleCount) in zip(
            sourceTimes,
            outputSampleCounts
        ) {
            let outputTime = timeline.presentationTime(
                sourceTime: CMTime(
                    seconds: sourceSeconds,
                    preferredTimescale: 1_000
                ),
                sourceSampleCount: 1_024,
                sourceSampleRate: 44_100,
                outputSampleCount: outputSampleCount,
                outputSampleRate: 48_000
            )
            if let expectedOutputTime {
                #expect(CMTimeCompare(outputTime, expectedOutputTime) == 0)
            }
            expectedOutputTime = CMTimeAdd(
                outputTime,
                CMTime(value: Int64(outputSampleCount), timescale: 48_000)
            )
        }
    }

    @Test func resampledAudioClockPreservesRealGapsAndResets() {
        var timeline = ResampledAudioTimeline()
        _ = timeline.presentationTime(
            sourceTime: .zero,
            sourceSampleCount: 1_024,
            sourceSampleRate: 44_100,
            outputSampleCount: 1_098,
            outputSampleRate: 48_000
        )
        let discontinuous = timeline.presentationTime(
            sourceTime: CMTime(seconds: 0.100, preferredTimescale: 1_000),
            sourceSampleCount: 1_024,
            sourceSampleRate: 44_100,
            outputSampleCount: 1_115,
            outputSampleRate: 48_000
        )
        #expect(discontinuous == CMTime(value: 100, timescale: 1_000))

        timeline.reset()
        let afterReset = timeline.presentationTime(
            sourceTime: CMTime(seconds: 5, preferredTimescale: 1_000),
            sourceSampleCount: 1_024,
            sourceSampleRate: 44_100,
            outputSampleCount: 1_115,
            outputSampleRate: 48_000
        )
        #expect(afterReset == CMTime(value: 5_000, timescale: 1_000))
    }

    @Test func queuedHorizonsNeverProducePresentationDriftCorrection() {
        var snapshot = MediaSessionSnapshot()
        snapshot.videoPTS = 100
        snapshot.audioPTS = 100.75
        snapshot.videoPacketDepth = 96
        snapshot.audioPacketDepth = 128
        snapshot.softwareDecodeErrorsDropped = 7
        snapshot.softwareCorruptFramesDropped = 2
        snapshot.lastRecoveryFailure = PlaybackFailure(
            domain: .videoDecode,
            stage: .receiveFrame,
            stableCode: "videoDecodeFailed",
            nativeCode: -5,
            recoverability: .fallbackAvailable,
            hardwareWasConfigured: true,
            hardwareOutputWasObserved: false
        )

        let payloads = nativePeriodicMetricsPayloads(snapshot: snapshot)

        #expect(payloads.count == 3)
        #expect(payloads.allSatisfy { payload in
            if case .diagnostic = payload { return true }
            return false
        })
        if case let .diagnostic(message) = payloads.first {
            #expect(message.contains("venqueue=100.0"))
            #expect(message.contains("aenqueue=100.75"))
            #expect(message.contains("software-pool-distinct-seen=0"))
            #expect(message.contains("software-decode-errors-dropped=7"))
            #expect(message.contains("software-corrupt-frames-dropped=2"))
            #expect(message.contains(
                "software-old-generation-retained-upper=unmeasured"
            ))
            #expect(message.contains("recovery-domain=videoDecode"))
            #expect(message.contains("recovery-stage=receiveFrame"))
            #expect(message.contains("recovery-code=videoDecodeFailed"))
            #expect(message.contains("recovery-native-code=-5"))
            #expect(message.contains("recovery-disposition=fallbackAvailable"))
            #expect(message.contains("recovery-hardware-configured=yes"))
            #expect(message.contains("recovery-hardware-output=no"))
        } else {
            Issue.record("Periodic queue metrics must remain diagnostic-only")
        }
        if case let .diagnostic(message) = payloads[1] {
            #expect(message.contains("renderer-accepted=unmeasured"))
            #expect(message.contains("first-visible=unmeasured"))
            #expect(message.contains("dropped=unmeasured"))
        } else {
            Issue.record("Presentation evidence must remain diagnostic-only")
        }
    }

    @Test func pixelBufferExhaustionIsNotClassifiedAsDecoderFallback() {
        let stream = FFmpegStreamInfo(
            index: 3,
            kind: .video,
            codecID: 0,
            codecName: "av1",
            title: nil,
            language: nil,
            timeBase: FFmpegRational(numerator: 1, denominator: 1_000),
            duration: nil,
            disposition: 0,
            codedSize: CGSize(width: 1_920, height: 1_080),
            pixelAspectRatio: CGSize(width: 1, height: 1),
            averageFrameRate: 24,
            sampleRate: nil,
            channelCount: nil,
            channelLayout: nil,
            rotationDegrees: 0,
            isMirrored: false,
            interlaceMode: .progressive
        )

        let failure = NativeRecoveryController().videoFailure(
            error: SoftwarePixelBufferPoolError.exhausted,
            stream: stream,
            hardwareWasConfigured: true,
            hardwareOutputWasObserved: false
        )

        #expect(failure.domain == .resource)
        #expect(failure.stage == .convert)
        #expect(failure.stableCode == "softwarePixelBufferPoolExhausted")
        #expect(failure.nativeCode == nil)
        #expect(failure.recoverability == .fatal)
        #expect(failure.hardwareWasConfigured)
    }

    @Test func hardwareDecodeFailureCarriesConsecutiveCount() {
        let stream = FFmpegStreamInfo(
            index: 3,
            kind: .video,
            codecID: 0,
            codecName: "hevc",
            title: nil,
            language: nil,
            timeBase: FFmpegRational(numerator: 1, denominator: 1_000),
            duration: nil,
            disposition: 0,
            codedSize: CGSize(width: 1_920, height: 1_080),
            pixelAspectRatio: CGSize(width: 1, height: 1),
            averageFrameRate: 24,
            sampleRate: nil,
            channelCount: nil,
            channelLayout: nil,
            rotationDegrees: 0,
            isMirrored: false,
            interlaceMode: .progressive
        )

        let failure = NativeRecoveryController().videoFailure(
            error: FFmpegError(operation: "Decode video frame", code: -12_948),
            stream: stream,
            hardwareWasConfigured: true,
            hardwareOutputWasObserved: true,
            consecutiveCount: 2
        )

        #expect(failure.recoverability == .fallbackAvailable)
        #expect(failure.consecutiveCount == 2)
    }

    @Test func observationMetricsSeparateSourcesCoalescingAndUrgentDelay() {
        var metrics = RuntimeObservationMetricsLedger()
        metrics.recordRequest(
            RuntimeObservationRequest(source: .videoEnqueue, urgency: .routine),
            at: 100,
            scheduled: true
        )
        metrics.recordRequest(
            RuntimeObservationRequest(source: .rendererFailure, urgency: .urgent),
            at: 120,
            scheduled: false
        )
        metrics.recordDelivery(at: 150, isFollowUp: false)
        metrics.recordDelivery(at: 170, isFollowUp: true)

        let snapshot = metrics.snapshot
        #expect(snapshot.totalRequests == 2)
        #expect(snapshot.requestsBySource[.videoEnqueue] == 1)
        #expect(snapshot.requestsBySource[.rendererFailure] == 1)
        #expect(snapshot.scheduledDeliveries == 1)
        #expect(snapshot.coalescedRequests == 1)
        #expect(snapshot.deliveredObservations == 2)
        #expect(snapshot.followUpDeliveries == 1)
        #expect(snapshot.maximumDelayNanoseconds == 50)
        #expect(snapshot.maximumUrgentDelayNanoseconds == 30)
    }

    @Test func periodicMetricsExposeObservationSourceCounts() {
        var observation = RuntimeObservationMetricsSnapshot()
        observation.requestsBySource[.videoEnqueue] = 4
        observation.requestsBySource[.preroll] = 1
        observation.scheduledDeliveries = 2
        observation.coalescedRequests = 3
        observation.deliveredObservations = 2
        observation.maximumUrgentDelayNanoseconds = 2_500_000

        let payloads = nativePeriodicMetricsPayloads(
            snapshot: MediaSessionSnapshot(),
            observation: observation
        )
        guard case let .diagnostic(message) = payloads[2] else {
            Issue.record("Observation metrics must remain diagnostic-only")
            return
        }
        #expect(message.contains("requests=5"))
        #expect(message.contains("coalesced=3"))
        #expect(message.contains("max-urgent-delay-ms=2.500"))
        #expect(message.contains("videoEnqueue=4"))
        #expect(message.contains("preroll=1"))
    }

    @Test func generationRejectsStaleOutput() {
        let generation = PlaybackGeneration()
        let initial = generation.current
        let next = generation.advance()
        #expect(!generation.accepts(initial))
        #expect(generation.accepts(next))
    }

    @Test func synchronizationMetricsTrackWorstDifferenceAndDrift() {
        var metrics = AVSyncStabilityMetrics()
        metrics.record(audioPTS: 1.02, videoPTS: 1.00)
        metrics.record(audioPTS: 2.04, videoPTS: 2.00)
        metrics.record(audioPTS: 3.01, videoPTS: 3.00)
        #expect(metrics.sampleCount == 3)
        #expect(abs(metrics.maximumAbsoluteDifference - 0.04) < 0.000_1)
        #expect(abs(metrics.drift - -0.01) < 0.000_1)
        #expect(ProcessResidentMemory.bytes().map { $0 > 0 } == true)
    }

    @Test func synchronizationMetricsExcludePrerollAndFinalDrainFromSteadyDrift() {
        var metrics = AVSyncStabilityMetrics()
        for sample in 0..<1_000 {
            let difference: Double
            if sample < 100 {
                difference = 1
            } else if sample >= 900 {
                difference = -1
            } else {
                difference = 0.05
            }
            metrics.record(audioPTS: Double(sample + 1) + difference, videoPTS: Double(sample + 1))
        }
        #expect(abs(metrics.drift + 2) < 0.000_1)
        #expect(abs(metrics.steadyStateDrift(
            windowSampleCount: 100,
            edgeExclusionSampleCount: 100
        )) < 0.000_1)
    }

    @Test func displayCapabilitiesIdentifySDRAndEDRDisplays() {
        let sdr = NativeDisplayCapabilities(
            name: "SDR",
            backingScale: 2,
            currentEDRHeadroom: 1,
            potentialEDRHeadroom: 1
        )
        let edr = NativeDisplayCapabilities(
            name: "EDR",
            backingScale: 2,
            currentEDRHeadroom: 1.6,
            potentialEDRHeadroom: 4
        )
        #expect(!sdr.isExtendedDynamicRangeAvailable)
        #expect(edr.isExtendedDynamicRangeAvailable)
    }

    @Test func latestSeekReplacesPendingSeek() {
        let coordinator = SeekCoordinator()
        coordinator.submit(SeekRequest(
            target: CMTime(seconds: 10, preferredTimescale: 600),
            exact: false,
            generation: 1,
            resumeRate: 1
        ))
        coordinator.submit(SeekRequest(
            target: CMTime(seconds: 20, preferredTimescale: 600),
            exact: true,
            generation: 2,
            resumeRate: 0
        ))
        for barrier in [
            SeekInvalidationBarrier.inputReadCancellation,
            .packetAndFrameQueues,
            .presentationFence,
            .subtitleVisibleClear,
            .subtitleSourceInvalidation,
        ] {
            coordinator.acknowledge(barrier, generation: 2)
        }
        let request = coordinator.takePending()
        #expect(request?.generation == 2)
        #expect(coordinator.phase == .seeking(
            generation: 2,
            target: CMTime(seconds: 20, preferredTimescale: 600)
        ))
        if let request {
            coordinator.markPrerolling(request)
            #expect(coordinator.phase == .prerolling(
                generation: 2,
                target: request.target
            ))
            coordinator.finish(generation: 2)
            #expect(coordinator.phase == .idle)
        }
    }

    @Test func completedOlderSeekCannotOverwriteNewPendingPhase() {
        let coordinator = SeekCoordinator()
        let older = SeekRequest(
            target: CMTime(seconds: 5, preferredTimescale: 600),
            exact: false,
            generation: 1,
            resumeRate: 1
        )
        let newer = SeekRequest(
            target: CMTime(seconds: 15, preferredTimescale: 600),
            exact: true,
            generation: 2,
            resumeRate: 0
        )
        coordinator.submit(older)
        for barrier in [
            SeekInvalidationBarrier.inputReadCancellation,
            .packetAndFrameQueues,
            .presentationFence,
            .subtitleVisibleClear,
            .subtitleSourceInvalidation,
        ] {
            coordinator.acknowledge(barrier, generation: older.generation)
        }
        _ = coordinator.takePending()
        coordinator.submit(newer)
        coordinator.markPrerolling(older)
        #expect(coordinator.phase == .invalidating(
            generation: newer.generation,
            target: newer.target,
            pending: Set([
                .inputReadCancellation, .packetAndFrameQueues, .presentationFence,
                .subtitleVisibleClear, .subtitleSourceInvalidation,
            ])
        ))
        for barrier in [
            SeekInvalidationBarrier.inputReadCancellation,
            .packetAndFrameQueues,
            .presentationFence,
            .subtitleVisibleClear,
            .subtitleSourceInvalidation,
        ] {
            coordinator.acknowledge(barrier, generation: newer.generation)
        }
        #expect(coordinator.takePending() == newer)
    }

    @Test func viewportAspectFitsLetterboxAndPillarbox() {
        let wide = VideoViewport.aspectFit(
            displaySize: CGSize(width: 1_920, height: 1_080),
            in: CGRect(x: 0, y: 0, width: 1_000, height: 1_000)
        )
        #expect(abs(wide.width - 1_000) < 0.001)
        #expect(abs(wide.height - 562.5) < 0.001)

        let tall = VideoViewport.aspectFit(
            displaySize: CGSize(width: 1_080, height: 1_920),
            in: CGRect(x: 0, y: 0, width: 1_000, height: 1_000)
        )
        #expect(abs(tall.height - 1_000) < 0.001)
        #expect(abs(tall.width - 562.5) < 0.001)
    }

    @Test func subtitleCoordinatesMapIntoViewport() {
        let point = SubtitleGeometry.scale(
            point: CGPoint(x: 960, y: 540),
            storageSize: CGSize(width: 1_920, height: 1_080),
            viewport: CGRect(x: 100, y: 50, width: 960, height: 540)
        )
        #expect(point.x == 580)
        #expect(point.y == 320)
    }

    @Test func externalSubtitleReaderStopsAtItsConfiguredByteLimit() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("ass")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(repeating: 65, count: 9).write(to: url)

        #expect(throws: PresentationError.self) {
            _ = try SubtitlePipeline.prepareExternalData(
                url: url,
                maximumBytes: 8
            )
        }
    }

    @Test func fontAttachmentDetectionUsesExtensionAndMime() {
        #expect(FontAttachment(
            filename: "Title Font.ttf",
            mimeType: nil,
            data: Data()
        ).isSupportedFont)
        #expect(FontAttachment(
            filename: "font.bin",
            mimeType: "application/vnd.ms-opentype",
            data: Data()
        ).isSupportedFont)
        #expect(!FontAttachment(
            filename: "cover.jpg",
            mimeType: "image/jpeg",
            data: Data()
        ).isSupportedFont)
    }

    @Test func fontAttachmentValidationRejectsAggregateBytesBeforeRegistration() {
        let fonts = [
            FontAttachment(
                filename: "one.ttf",
                mimeType: nil,
                data: Data(repeating: 1, count: 6)
            ),
            FontAttachment(
                filename: "two.otf",
                mimeType: nil,
                data: Data(repeating: 2, count: 6)
            ),
        ]

        #expect(throws: PresentationError.self) {
            _ = try FontAttachmentValidator.validated(
                fonts,
                limits: FontAttachmentLimits(
                    maximumCount: 2,
                    maximumBytesPerFont: 8,
                    maximumTotalBytes: 10
                )
            )
        }
    }
}
