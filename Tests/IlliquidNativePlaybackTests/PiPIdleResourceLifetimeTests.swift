import CoreMedia
import CoreVideo
import Foundation
import IlliquidCore
import Metal
import Testing
@testable import IlliquidNativePlayback

@Suite("PiP idle output resource lifetime", .serialized)
struct PiPIdleResourceLifetimeTests {
    @Test @MainActor
    func stopRetiresIdleResourcesWithoutInvalidatingCaptionUploads() async throws {
        let pipeline = try bitmapPipeline()
        defer { pipeline.terminate() }
        let compositor = try PiPSubtitleCompositor(subtitles: pipeline)
        defer { compositor.stop() }
        let frame = decodedFrame(try pixelBuffer(hdr: false))
        let first = try await compositor.composedPixelBufferForTesting(frame)
        let expected = try PixelImage(first)
        #expect(Array(expected.planes[0][(5 * 16 + 5) * 4..<(5 * 16 + 5) * 4 + 4]) == [0, 0, 128, 255])
        let before = await compositor.outputResourceSnapshotForTesting()
        #expect(before.hasPool && before.hasPoolObserver)
        let uploads = compositor.metricsSnapshot()
        #expect(uploads.subtitleTextureUploads == 1)

        compositor.stop()
        #expect(await waitUntil {
            let state = await compositor.outputResourceSnapshotForTesting()
            return !state.workerActive && !state.hasPool && !state.hasPoolObserver
        })
        let stopped = await compositor.outputResourceSnapshotForTesting()
        #expect(!stopped.hasPool && !stopped.hasPoolObserver)
        #expect(stopped.poolSize == .zero)
        #expect(stopped.observedBufferCount == 0)
        #expect(stopped.hdrTextureBytes == 0)
        #expect(compositor.subtitlePipelineIdentityForTesting == ObjectIdentifier(pipeline))
        // Keep the old CVPixelBuffer alive: stopping must not invalidate outputs
        // already handed to a renderer or another owner.
        #expect(try PixelImage(first) == expected)
        let second = try await compositor.composedPixelBufferForTesting(frame)
        #expect(try PixelImage(second) == expected)
        #expect(compositor.metricsSnapshot().subtitleTextureUploads == uploads.subtitleTextureUploads)
        #expect(compositor.metricsSnapshot().subtitleVertexBuilds == uploads.subtitleVertexBuilds)
        #expect(compositor.metricsSnapshot().subtitleResourceReuses == uploads.subtitleResourceReuses + 1)
    }

    @Test(arguments: [Int32(16), Int32(18)]) @MainActor
    func stopReleasesHDRWorkingTextureAndRecreatesIdenticalPixels(transfer: Int32) async throws {
        let compositor = try PiPSubtitleCompositor()
        defer { compositor.stop() }
        let frame = decodedFrame(try pixelBuffer(hdr: true), transfer: transfer)
        let first = try await compositor.composedPixelBufferForTesting(frame)
        let expected = try PixelImage(first)
        let texture = await compositor.withOutputResourcesForTesting { _, texture in
            WeakTexture(texture)
        }
        #expect(texture.value != nil)
        let allocated = await compositor.outputResourceSnapshotForTesting()
        #expect(allocated.hdrTextureBytes > 0)

        compositor.stop()
        #expect(await waitUntil {
            let state = await compositor.outputResourceSnapshotForTesting()
            return !state.workerActive && !state.hasPool && !state.hasPoolObserver
        })
        let stopped = await compositor.outputResourceSnapshotForTesting()
        #expect(!stopped.hasPool && !stopped.hasPoolObserver)
        #expect(stopped.hdrTextureBytes == 0)
        #expect(await waitUntil { texture.value == nil })
        #expect(try PixelImage(first) == expected)
        let second = try await compositor.composedPixelBufferForTesting(frame)
        #expect(try PixelImage(second) == expected)
        let restarted = await compositor.outputResourceSnapshotForTesting()
        #expect(restarted.hasPool && restarted.hasPoolObserver)
        #expect(restarted.hdrTextureBytes > 0)
    }

    @Test @MainActor
    func retainedOutputsSurvivePoolRetirementAndNewPoolStillHasTwelveBufferLimit() async throws {
        let compositor = try PiPSubtitleCompositor()
        defer { compositor.stop() }
        let frame = decodedFrame(try pixelBuffer(hdr: false))
        var retained: [CVPixelBuffer] = []
        for _ in 0..<12 {
            retained.append(try await compositor.composedPixelBufferForTesting(frame))
        }
        let expected = try PixelImage(retained[0])
        try await requirePoolExhaustion(compositor, frame: frame)
        compositor.stop()
        #expect(await waitUntil {
            let state = await compositor.outputResourceSnapshotForTesting()
            return !state.workerActive && !state.hasPool && !state.hasPoolObserver
        })
        let stopped = await compositor.outputResourceSnapshotForTesting()
        #expect(!stopped.hasPool && !stopped.hasPoolObserver)

        // The twelve outputs from the retired pool remain externally retained.
        // A fresh pool must admit new work and enforce its own unchanged cap.
        var next: [CVPixelBuffer] = []
        for _ in 0..<12 {
            next.append(try await compositor.composedPixelBufferForTesting(frame))
        }
        try await requirePoolExhaustion(compositor, frame: frame)
        for output in retained + next { #expect(try PixelImage(output) == expected) }
        let current = await compositor.outputResourceSnapshotForTesting()
        #expect(current.observedBufferCount == 12)
        retained.removeAll()
        next.removeAll()
    }

    @Test @MainActor
    func queuedStopDoesNotRetireRestartedSession() async throws {
        let compositor = try PiPSubtitleCompositor()
        defer { compositor.stop() }
        compositor.receive(decodedFrame(try pixelBuffer(hdr: false)))
        let gate = QueueGate()
        defer { gate.open() }
        compositor.enqueueWorkForTesting { gate.block() }
        try #require(await waitUntil { gate.entered })
        let old = Callbacks()
        let restarted = Callbacks()

        compositor.start(onFirstSample: { old.record($0) }, onFailure: { _ in old.failed() })
        compositor.stop()
        compositor.start(onFirstSample: { restarted.record($0) }, onFailure: { _ in restarted.failed() })
        gate.open()

        try #require(await waitUntil { restarted.snapshot.calls == 1 })
        #expect(!gate.timedOut)
        #expect(old.snapshot.calls == 0 && old.snapshot.failures == 0)
        #expect(restarted.snapshot.successes == 1 && restarted.snapshot.failures == 0)
        #expect(compositor.metricsSnapshot().composedFrames == 1)
        #expect(compositor.metricsSnapshot().immediatelyDisplayedFrames == 1)
        let active = await compositor.outputResourceSnapshotForTesting()
        #expect(active.active && active.hasPool && active.hasPoolObserver)
        compositor.stop()
        #expect(await waitUntil {
            let state = await compositor.outputResourceSnapshotForTesting()
            return !state.workerActive && !state.hasPool && !state.hasPoolObserver
        })
    }

    @Test @MainActor
    func stopWaitsForSubmittedGPUWorkThenRetiresAndRestartUsesLatestFrame() async throws {
        let gate = try GPUCompletionGate()
        defer { gate.open() }
        let compositor = try PiPSubtitleCompositor(
            beforeGPUCommitForTesting: { commandBuffer in gate.holdCompletion(commandBuffer) })
        defer { compositor.stop() }
        let old = Callbacks()
        let restarted = Callbacks()
        compositor.receive(decodedFrame(try pixelBuffer(hdr: true), transfer: 16))
        compositor.start(onFirstSample: { old.record($0) }, onFailure: { _ in old.failed() })
        try #require(await waitUntil { gate.entered })
        // Queue synchronization proves compose returned after committing the
        // actual command buffer. The shared event still prevents completion.
        let submitted = await compositor.outputResourceSnapshotForTesting()
        #expect(submitted.active && submitted.workerActive)
        #expect(submitted.hasPool && submitted.hdrTextureBytes > 0)
        compositor.stop()
        let stopping = await compositor.outputResourceSnapshotForTesting()
        #expect(!stopping.active && stopping.workerActive)
        #expect(stopping.hasPool && stopping.hasPoolObserver && stopping.hdrTextureBytes > 0)

        gate.open()
        try #require(await waitUntil {
            let state = await compositor.outputResourceSnapshotForTesting()
            return !state.workerActive && !state.hasPool && state.hdrTextureBytes == 0
        })
        #expect(old.snapshot.calls == 0 && old.snapshot.failures == 0)
        #expect(compositor.metricsSnapshot().discardedStaleCompositions == 1)

        // No new receive(): paused re-entry must use the retained latest frame.
        compositor.start(onFirstSample: { restarted.record($0) }, onFailure: { _ in restarted.failed() })
        try #require(await waitUntil { restarted.snapshot.calls == 1 })
        #expect(restarted.snapshot.successes == 1 && restarted.snapshot.failures == 0)
        #expect(compositor.metricsSnapshot().composedFrames == 1)
        #expect(compositor.metricsSnapshot().immediatelyDisplayedFrames == 1)
        compositor.stop()
        #expect(await waitUntil {
            let state = await compositor.outputResourceSnapshotForTesting()
            return !state.workerActive && !state.hasPool && !state.hasPoolObserver
        })
    }

    @MainActor
    private func requirePoolExhaustion(
        _ compositor: PiPSubtitleCompositor, frame: NativeDecodedVideoFrame
    ) async throws {
        do {
            _ = try await compositor.composedPixelBufferForTesting(frame)
            Issue.record("A thirteenth simultaneously retained output exceeded the pool cap.")
        } catch PiPSubtitleCompositorError.outputPoolExhausted(let status) {
            #expect(status == kCVReturnWouldExceedAllocationThreshold)
        }
    }

    @MainActor
    private func waitUntil(_ predicate: () async -> Bool) async -> Bool {
        for _ in 0..<500 {
            if await predicate() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await predicate()
    }

    @MainActor
    private func bitmapPipeline() throws -> SubtitlePipeline {
        let size = CGSize(width: 16, height: 16)
        let pipeline = try SubtitlePipeline(
            overlay: SubtitleOverlayView(headless: true), presentsOverlay: false)
        _ = try pipeline.configure(codecPrivate: nil, codecName: "hdmv_pgs_subtitle",
            attachments: [], frameSize: size, storageSize: size)
        let composition = NativeBitmapSubtitleComposition(
            regions: [.init(pixels: Data((0..<16).flatMap { _ in [UInt8(0), 0, 128, 128] }),
                frame: CGRect(x: 4, y: 4, width: 4, height: 4), isForced: false)],
            canvasSize: size, duration: 4, memoryLease: nil)
        #expect(pipeline.process(event: .init(assData: Data(), presentationSeconds: 0,
            durationSeconds: 4, generation: 0, bitmapComposition: composition)))
        return pipeline
    }

    private func decodedFrame(_ buffer: CVPixelBuffer, transfer: Int32? = nil) -> NativeDecodedVideoFrame {
        let size = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
        let hdr = transfer != nil
        return NativeDecodedVideoFrame(
            pixelBuffer: buffer, planarOwnershipToken: nil,
            presentationTime: CMTime(seconds: 0.5, preferredTimescale: 1_000),
            duration: CMTime(value: 1, timescale: 30), generation: 0,
            codedSize: size, displaySize: size, pixelAspectRatio: CGSize(width: 1, height: 1),
            rotationDegrees: 0, colorPrimaries: hdr ? 9 : nil,
            transferCharacteristic: transfer, matrixCoefficients: hdr ? 9 : nil,
            isFullRange: !hdr, hasMasteringDisplayMetadata: false,
            hasContentLightMetadata: false, sourceComponentDepth: hdr ? 10 : 8,
            ffmpegPixelFormat: hdr ? "p010le" : "bgra", isHardwareDecoded: false,
            isCopiedHardwarePath: false, isNearZeroCopy: false)
    }

    private func pixelBuffer(hdr: Bool) throws -> CVPixelBuffer {
        let attributes: [CFString: Any] = [
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any],
        ]
        var created: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, 16, 16,
            hdr ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_32BGRA,
            attributes as CFDictionary, &created)
        try #require(status == kCVReturnSuccess)
        let buffer = try #require(created)
        try #require(CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        if hdr {
            for plane in 0..<2 {
                let base = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, plane))
                    .assumingMemoryBound(to: UInt16.self)
                let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) / 2
                for y in 0..<CVPixelBufferGetHeightOfPlane(buffer, plane) {
                    for x in 0..<16 { base[y * stride + x] = UInt16((plane == 0 ? 400 + x : 512) << 6) }
                }
            }
        } else {
            let base = try #require(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            memset(base, 0, stride * 16)
            for y in 0..<16 { for x in 0..<16 { base[y * stride + x * 4 + 3] = 255 } }
        }
        return buffer
    }

    private struct PixelImage: Equatable {
        let width: Int
        let height: Int
        let format: OSType
        let planes: [Data]
        let colorTags: [String?]

        init(_ buffer: CVPixelBuffer) throws {
            width = CVPixelBufferGetWidth(buffer)
            height = CVPixelBufferGetHeight(buffer)
            format = CVPixelBufferGetPixelFormatType(buffer)
            try #require(CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            let count = CVPixelBufferGetPlaneCount(buffer)
            var copied: [Data] = []
            for plane in 0..<max(1, count) {
                let base = try #require(count == 0 ? CVPixelBufferGetBaseAddress(buffer)
                    : CVPixelBufferGetBaseAddressOfPlane(buffer, plane)).assumingMemoryBound(to: UInt8.self)
                let rowStride = count == 0 ? CVPixelBufferGetBytesPerRow(buffer)
                    : CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
                let rows = count == 0 ? height : CVPixelBufferGetHeightOfPlane(buffer, plane)
                let columns = count == 0 ? width : CVPixelBufferGetWidthOfPlane(buffer, plane)
                let bytesPerPixel = count == 0 ? 4 : (plane == 0 ? 2 : 4)
                var data = Data()
                for row in 0..<rows { data.append(base + row * rowStride, count: columns * bytesPerPixel) }
                copied.append(data)
            }
            planes = copied
            colorTags = [kCVImageBufferColorPrimariesKey, kCVImageBufferTransferFunctionKey,
                kCVImageBufferYCbCrMatrixKey].map { CVBufferCopyAttachment(buffer, $0, nil) as? String }
        }
    }

    private final class WeakTexture: @unchecked Sendable {
        weak var value: (any MTLTexture)?
        init(_ value: (any MTLTexture)?) { self.value = value }
    }

    private final class Callbacks: @unchecked Sendable {
        struct Counts { var calls = 0; var successes = 0; var failures = 0 }
        private let lock = NSLock()
        private var counts = Counts()
        var snapshot: Counts { lock.withLock { counts } }
        func record(_ result: Result<Void, Error>) {
            lock.withLock {
                counts.calls += 1
                switch result {
                case .success: counts.successes += 1
                case .failure: counts.failures += 1
                }
            }
        }
        func failed() { lock.withLock { counts.failures += 1 } }
    }

    private final class QueueGate: @unchecked Sendable {
        private let lock = NSLock()
        private let release = DispatchSemaphore(value: 0)
        private var didEnter = false
        private var didTimeOut = false
        var entered: Bool { lock.withLock { didEnter } }
        var timedOut: Bool { lock.withLock { didTimeOut } }
        func block() {
            lock.withLock { didEnter = true }
            if release.wait(timeout: .now() + 10) == .timedOut {
                lock.withLock { didTimeOut = true }
            }
        }
        func open() { release.signal() }
    }

    private final class GPUCompletionGate: @unchecked Sendable {
        private let event: any MTLSharedEvent
        private let lock = NSLock()
        private var didEnter = false
        var entered: Bool { lock.withLock { didEnter } }
        init() throws {
            let device = try #require(MTLCreateSystemDefaultDevice())
            event = try #require(device.makeSharedEvent())
        }
        func holdCompletion(_ commandBuffer: any MTLCommandBuffer) {
            commandBuffer.encodeWaitForEvent(event, value: 1)
            lock.withLock { didEnter = true }
        }
        func open() { event.signaledValue = 1 }
    }
}
