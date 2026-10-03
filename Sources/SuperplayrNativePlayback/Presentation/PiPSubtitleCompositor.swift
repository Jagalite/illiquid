import AVFoundation
import AppKit
import CoreMedia
import CoreVideo
import Foundation
import Metal
import OSLog
import QuartzCore
import SuperplayrCore

/// Minimal AppKit host used only by the PiP subtitle lifecycle host.
///
/// The view remains attached to a nonactivating, fully offscreen auxiliary
/// panel for the complete PiP session. Keeping the panel ordered in makes the
/// display layer render-active; an ordered-out layer accepts sample buffers
/// but never produces a displayed image for AVKit to mirror. The offscreen
/// panel survives main-window closure without becoming visible playback.
@MainActor
final class PiPSubtitleDisplayLayerHost {
    private final class HostView: NSView {
        let hostedDisplayLayer: AVSampleBufferDisplayLayer

        init(
            displayLayer: AVSampleBufferDisplayLayer,
            size: CGSize,
            scale: CGFloat
        ) {
            hostedDisplayLayer = displayLayer
            super.init(frame: CGRect(origin: .zero, size: size))
            wantsLayer = true
            layer = CALayer()
            layer?.backgroundColor = NSColor.clear.cgColor
            layer?.contentsScale = max(scale, 1)
            layer?.masksToBounds = false
            hostedDisplayLayer.removeFromSuperlayer()
            hostedDisplayLayer.contentsScale = 1
            hostedDisplayLayer.frame = bounds
            layer?.addSublayer(hostedDisplayLayer)
            setAccessibilityElement(false)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            hostedDisplayLayer.frame = bounds
            CATransaction.commit()
        }

        deinit {
            PiPSubtitleDisplayLayerHost.emit("host-view-deinit")
        }
    }

    private let hostView: HostView
    private let panel: NSPanel
    private var isAttached = false

    init?(displayLayer: AVSampleBufferDisplayLayer, parentView: NSView) {
        guard parentView.window != nil else {
            Self.emit("host-attach-failed reason=parent-has-no-window")
            return nil
        }
        let initialSize = Self.validSize(displayLayer.bounds.size)
            ?? CGSize(width: 1, height: 1)
        hostView = HostView(
            displayLayer: displayLayer,
            size: initialSize,
            scale: parentView.window?.backingScaleFactor ?? 1
        )
        panel = NSPanel(
            contentRect: CGRect(
                origin: CGPoint(x: -10_000, y: -10_000),
                size: initialSize
            ),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.animationBehavior = .none
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isExcludedFromWindowsMenu = true
        // Swift/ARC clients must keep this false; AppKit otherwise
        // over-releases the window after `close()`.
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.auxiliary, .ignoresCycle]
        panel.contentView = hostView
        panel.orderFront(nil)
        panel.setFrameOrigin(CGPoint(x: -10_000, y: -10_000))
        isAttached = hostView.window === panel
            && displayLayer.superlayer === hostView.layer
        guard isAttached else {
            panel.contentView = nil
            panel.close()
            Self.emit("host-attach-failed reason=invalid-layer-hierarchy")
            return nil
        }
        Self.emit(
            "host-attached panel=true visible=\(panel.isVisible)"
                + " onscreen=\(panel.isOnActiveSpace && panel.occlusionState.contains(.visible))"
                + " bounds=\(Self.size(displayLayer.bounds.size))"
                + " scale=\(displayLayer.contentsScale)"
        )
    }

    func setSize(_ requestedSize: CGSize) {
        guard isAttached, let size = Self.validSize(requestedSize) else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        panel.setContentSize(size)
        hostView.frame = CGRect(origin: .zero, size: size)
        hostView.hostedDisplayLayer.frame = hostView.bounds
        CATransaction.commit()
    }

    func geometryForTesting() -> (
        panelSize: CGSize,
        viewSize: CGSize,
        layerFrame: CGRect,
        layerBounds: CGRect,
        panelFrame: CGRect,
        panelVisible: Bool
    ) {
        (
            panel.contentView?.bounds.size ?? .zero,
            hostView.bounds.size,
            hostView.hostedDisplayLayer.frame,
            hostView.hostedDisplayLayer.bounds,
            panel.frame,
            panel.isVisible
        )
    }

    func tearDown() {
        guard isAttached else { return }
        isAttached = false
        panel.orderOut(nil)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hostView.hostedDisplayLayer.removeFromSuperlayer()
        CATransaction.commit()
        CATransaction.flush()
        panel.contentView = nil
        panel.close()
        Self.emit(
            "host-detached panel-visible=\(panel.isVisible)"
                + " window=\(hostView.window != nil)"
                + " superlayer=\(hostView.hostedDisplayLayer.superlayer != nil)"
        )
    }

    deinit {
        Self.emit("host-owner-deinit")
    }

    private static func size(_ size: CGSize) -> String {
        "\(Int(size.width.rounded()))x\(Int(size.height.rounded()))"
    }

    private static func validSize(_ size: CGSize) -> CGSize? {
        guard size.width.isFinite,
              size.height.isFinite,
              size.width > 0,
              size.height > 0
        else {
            return nil
        }
        return size
    }

    private nonisolated static func emit(_ message: String) {
        FileHandle.standardError.write(
            Data("[native-pip-subtitles] \(message)\n".utf8)
        )
    }
}

struct PiPSubtitleCompositionMetrics: Equatable, Sendable {
    var receivedFrames = 0
    var composedFrames = 0
    var immediatelyDisplayedFrames = 0
    var subtitleVisibleFrames = 0
    var coalescedFrames = 0
    var unsupportedFrames = 0
    var outputPoolMisses = 0
    var outputPixelBufferAllocations = 0
    var outputPixelBufferReuses = 0
    var enqueueFailures = 0
    var discardedStaleCompositions = 0
    var compositionCPUTimeNanoseconds: UInt64 = 0
    var compositionGPUTimeNanoseconds: UInt64 = 0

    var averageCPUTimeMilliseconds: Double {
        guard composedFrames > 0 else { return 0 }
        return Double(compositionCPUTimeNanoseconds) / Double(composedFrames) / 1_000_000
    }

    var averageGPUTimeMilliseconds: Double {
        guard composedFrames > 0 else { return 0 }
        return Double(compositionGPUTimeNanoseconds) / Double(composedFrames) / 1_000_000
    }
}

struct PiPSubtitleCompositionFence: Equatable, Sendable {
    private(set) var revision: UInt64 = 0

    mutating func invalidate() {
        precondition(revision < UInt64.max, "PiP composition revision exhausted")
        revision += 1
    }

    func accepts(_ candidate: UInt64) -> Bool {
        candidate == revision
    }
}

private enum PiPSubtitleCompositorError: LocalizedError {
    case metalUnavailable
    case textureCacheCreation(CVReturn)
    case pipelineCreation(String)
    case outputPoolCreation(CVReturn)
    case outputPoolExhausted(CVReturn)
    case unsupportedSource(PiPSubtitleCompositionFallbackReason)
    case textureCreation
    case commandEncoding

    var errorDescription: String? {
        switch self {
        case .metalUnavailable:
            "Metal is unavailable."
        case let .textureCacheCreation(status):
            "Metal texture-cache creation failed (\(status))."
        case let .pipelineCreation(message):
            "Metal pipeline creation failed: \(message)"
        case let .outputPoolCreation(status):
            "PiP output-pool creation failed (\(status))."
        case let .outputPoolExhausted(status):
            "PiP output-pool checkout failed (\(status))."
        case let .unsupportedSource(reason):
            reason.diagnosticDescription
        case .textureCreation:
            "A PiP Metal texture could not be created."
        case .commandEncoding:
            "The PiP Metal command could not be encoded."
        }
    }
}

/// Production path for burning the current libass output into a
/// PiP-only SDR frame. The normal sample-buffer presenter still receives the
/// original decoded frame. This compositor retains only the latest pending
/// frame and performs no work until `start` is called.
final class PiPSubtitleCompositor: @unchecked Sendable {
    private static let logger = Logger(
        subsystem: "com.superplayr.pip-subtitles",
        category: "compositor"
    )

    private struct SubtitleVertex {
        var position: SIMD2<Float>
        var textureCoordinate: SIMD2<Float>
        var color: SIMD4<Float>
    }

    private final class MetalFrameResources: @unchecked Sendable {
        let outputPixelBuffer: CVPixelBuffer
        let retainedCVTextures: [CVMetalTexture]

        init(
            outputPixelBuffer: CVPixelBuffer,
            retainedCVTextures: [CVMetalTexture]
        ) {
            self.outputPixelBuffer = outputPixelBuffer
            self.retainedCVTextures = retainedCVTextures
        }
    }

    private final class CompositionResultBox: @unchecked Sendable {
        let result: Result<(CVPixelBuffer, UInt64), Error>

        init(_ result: Result<(CVPixelBuffer, UInt64), Error>) {
            self.result = result
        }
    }

    private final class PixelBufferBox: @unchecked Sendable {
        let pixelBuffer: CVPixelBuffer

        init(_ pixelBuffer: CVPixelBuffer) {
            self.pixelBuffer = pixelBuffer
        }
    }

    private enum CompositionFailureMetric {
        case unsupported
        case enqueue
    }

    private enum CompositionFailureDelivery {
        case stale
        case firstSample((@Sendable (Result<Void, Error>) -> Void)?)
        case runtime((@Sendable (Error) -> Void)?)
    }

    let presenter = SampleBufferVideoPresenter()
    var displayLayer: AVSampleBufferDisplayLayer { presenter.displayLayer }
    var renderer: AVSampleBufferVideoRenderer { presenter.renderer }

    private let device: any MTLDevice
    private let commandQueue: any MTLCommandQueue
    private let textureCache: CVMetalTextureCache
    private let bgraPipeline: any MTLRenderPipelineState
    private let nv12Pipeline: any MTLRenderPipelineState
    private let subtitlePipeline: any MTLRenderPipelineState
    private let bitmapSubtitlePipeline: any MTLRenderPipelineState
    private struct TenBitPipelines {
        let video: any MTLRenderPipelineState
        let text: any MTLRenderPipelineState
        let bitmap: any MTLRenderPipelineState
    }
    private let tenBitPipelines: TenBitPipelines?
    private struct HDRPipelines {
        let video: any MTLRenderPipelineState
        let text: any MTLRenderPipelineState
        let bitmap: any MTLRenderPipelineState
        let luma: any MTLRenderPipelineState
        let chroma: any MTLRenderPipelineState
    }
    private let hdrPipelines: HDRPipelines?
    private var hdrLinearTexture: (any MTLTexture)?
    private let sampler: any MTLSamplerState
    private let subtitlePacker: ASSSubtitleFramePacker
    private let workQueue = DispatchQueue(
        label: "com.superplayr.pip-subtitles",
        qos: .userInteractive
    )
    private let stateLock = NSLock()

    private var active = false
    private var workerActive = false
    private var videoAdjustments = VideoAdjustmentState.standard
    private var latestFrame: NativeDecodedVideoFrame?
    private var pendingFrame: NativeDecodedVideoFrame?
    private var pendingFrameDisplaysImmediately = false
    private var firstSampleHandler: (@Sendable (Result<Void, Error>) -> Void)?
    private var runtimeFailureHandler: (@Sendable (Error) -> Void)?
    private var deliveredFirstSample = false
    private var metrics = PiPSubtitleCompositionMetrics()
    private var outputPool: CVPixelBufferPool?
    private var outputPoolObserver: NSObjectProtocol?
    private var outputPoolSize = CGSize.zero
    private var outputPoolPixelFormat: OSType = kCVPixelFormatType_32BGRA
    private var observedOutputBuffers: Set<UInt> = []
    private var preparedSubtitleFrame: ASSPreparedSubtitleFrame?
    private var subtitleTexture: (any MTLTexture)?
    private var subtitleVertexBuffer: (any MTLBuffer)?
    private var subtitleVertexCapacity = 0
    private var lastSourceSize = CGSize.zero
    private var lastEnqueuedGeneration: Int?
    private var compositionFence = PiPSubtitleCompositionFence()
    private var boundSubtitlePipeline: SubtitlePipeline?
    private var subtitlePipelineRevision: UInt64 = 0
    // Work-queue confined. The revision prevents a new pipeline from reusing
    // a prepared frame produced by the preceding source.
    private var preparedSubtitlePipelineRevision: UInt64?

    init(
        subtitles: SubtitlePipeline? = nil,
        memoryBudget: SubtitleMemoryBudget? = nil
    ) throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue()
        else {
            throw PiPSubtitleCompositorError.metalUnavailable
        }
        var cache: CVMetalTextureCache?
        let cacheStatus = CVMetalTextureCacheCreate(
            kCFAllocatorDefault,
            nil,
            device,
            nil,
            &cache
        )
        guard cacheStatus == kCVReturnSuccess, let cache else {
            throw PiPSubtitleCompositorError.textureCacheCreation(cacheStatus)
        }

        boundSubtitlePipeline = subtitles
        subtitlePacker = ASSSubtitleFramePacker(
            memoryBudget: memoryBudget,
            memoryOwner: .pictureInPictureStaging
        )
        self.device = device
        self.commandQueue = commandQueue
        textureCache = cache

        do {
            let library = try NativeMetalShaderLibrary.load(device: device)
            guard let videoVertex = library.makeFunction(name: "pip_video_vertex"),
                  let bgraFragment = library.makeFunction(name: "pip_bgra_fragment"),
                  let nv12Fragment = library.makeFunction(name: "pip_nv12_fragment"),
                  let subtitleVertex = library.makeFunction(name: "pip_subtitle_vertex"),
                  let subtitleFragment = library.makeFunction(name: "pip_subtitle_fragment"),
                  let bitmapSubtitleFragment = library.makeFunction(name: "pip_bitmap_subtitle_fragment")
            else {
                throw PiPSubtitleCompositorError.pipelineCreation(
                    "required shader function is unavailable"
                )
            }
            bgraPipeline = try Self.makePipeline(
                device: device,
                vertex: videoVertex,
                fragment: bgraFragment,
                blending: false
            )
            nv12Pipeline = try Self.makePipeline(
                device: device,
                vertex: videoVertex,
                fragment: nv12Fragment,
                blending: false
            )
            subtitlePipeline = try Self.makePipeline(
                device: device,
                vertex: subtitleVertex,
                fragment: subtitleFragment,
                blending: true
            )
            bitmapSubtitlePipeline = try Self.makePipeline(
                device: device, vertex: subtitleVertex, fragment: bitmapSubtitleFragment,
                blending: true, premultiplied: true
            )
            // Failure of the optional ten-bit target must not disable ordinary
            // SDR composition on a device that supports only the existing path.
            tenBitPipelines = try? TenBitPipelines(
                video: Self.makePipeline(device: device, vertex: videoVertex, fragment: nv12Fragment,
                                         blending: false, pixelFormat: .bgr10a2Unorm),
                text: Self.makePipeline(device: device, vertex: subtitleVertex, fragment: subtitleFragment,
                                        blending: true, pixelFormat: .bgr10a2Unorm),
                bitmap: Self.makePipeline(device: device, vertex: subtitleVertex, fragment: bitmapSubtitleFragment,
                                          blending: true, premultiplied: true, pixelFormat: .bgr10a2Unorm)
            )
            if let hdrVideo = library.makeFunction(name: "pip_hdr_video_fragment"),
               let hdrText = library.makeFunction(name: "pip_hdr_text_fragment"),
               let hdrBitmap = library.makeFunction(name: "pip_hdr_bitmap_fragment"),
               let hdrLuma = library.makeFunction(name: "pip_hdr_luma_fragment"),
               let hdrChroma = library.makeFunction(name: "pip_hdr_chroma_fragment") {
                hdrPipelines = try? HDRPipelines(
                    video: Self.makePipeline(device: device, vertex: videoVertex, fragment: hdrVideo, blending: false, pixelFormat: .rgba16Float),
                    text: Self.makePipeline(device: device, vertex: subtitleVertex, fragment: hdrText, blending: true, pixelFormat: .rgba16Float),
                    bitmap: Self.makePipeline(device: device, vertex: subtitleVertex, fragment: hdrBitmap, blending: true, premultiplied: true, pixelFormat: .rgba16Float),
                    luma: Self.makePipeline(device: device, vertex: videoVertex, fragment: hdrLuma, blending: false, pixelFormat: .r16Unorm),
                    chroma: Self.makePipeline(device: device, vertex: videoVertex, fragment: hdrChroma, blending: false, pixelFormat: .rg16Unorm))
            } else { hdrPipelines = nil }
        } catch {
            throw PiPSubtitleCompositorError.pipelineCreation(
                error.localizedDescription
            )
        }

        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor) else {
            throw PiPSubtitleCompositorError.pipelineCreation(
                "sampler creation returned nil"
            )
        }
        self.sampler = sampler
        // AVKit's rounded PiP viewport can differ from the media aspect by a
        // fraction of a point. Fill only this already-composited PiP layer so
        // that rounding cannot expose thin background slivers at either edge.
        presenter.displayLayer.videoGravity = .resizeAspectFill
        presenter.displayLayer.contentsScale = 1
    }

    var isActive: Bool {
        stateLock.withLock { active }
    }

    var latestEligibility: PiPSubtitleCompositionEligibility? {
        stateLock.withLock {
            latestFrame.map(PiPSubtitleCompositionPolicy.eligibility(for:))
        }
    }

    func setSubtitlePipeline(_ pipeline: SubtitlePipeline?) {
        let shouldStartWorker: Bool? = stateLock.withLock {
            guard boundSubtitlePipeline !== pipeline else { return nil }
            boundSubtitlePipeline = pipeline
            subtitlePipelineRevision &+= 1
            compositionFence.invalidate()
            pendingFrameDisplaysImmediately = true
            if active, let latestFrame {
                if pendingFrame != nil {
                    metrics.coalescedFrames += 1
                }
                pendingFrame = latestFrame
                if !workerActive {
                    workerActive = true
                    return true
                }
            }
            return false
        }
        guard let shouldStartWorker else { return }
        workQueue.async { [weak self] in
            guard let self else { return }
            preparedSubtitleFrame = nil
            preparedSubtitlePipelineRevision = nil
            subtitleTexture = nil
            subtitleVertexBuffer = nil
            subtitleVertexCapacity = 0
            subtitlePacker.retireSource()
            if shouldStartWorker {
                consumePendingFrame()
            }
        }
    }

    var subtitlePipelineIdentityForTesting: ObjectIdentifier? {
        stateLock.withLock { boundSubtitlePipeline.map(ObjectIdentifier.init) }
    }

    func receive(_ frame: NativeDecodedVideoFrame) {
        var shouldStartWorker = false
        stateLock.withLock {
            metrics.receivedFrames += 1
            latestFrame = frame
            guard active else { return }
            if pendingFrame != nil {
                metrics.coalescedFrames += 1
            }
            pendingFrame = frame
            if !workerActive {
                workerActive = true
                shouldStartWorker = true
            }
        }
        if shouldStartWorker {
            workQueue.async { [weak self] in
                self?.consumePendingFrame()
            }
        }
    }

    func setVideoAdjustments(_ adjustments: VideoAdjustmentState) {
        stateLock.withLock { videoAdjustments = adjustments; subtitlePipelineRevision &+= 1 }
        refreshLatestFrame()
    }

    func refreshLatestFrame() {
        var shouldStartWorker = false
        stateLock.withLock {
            compositionFence.invalidate()
            guard active, let latestFrame else { return }
            if pendingFrame != nil {
                metrics.coalescedFrames += 1
            }
            pendingFrame = latestFrame
            pendingFrameDisplaysImmediately = true
            if !workerActive {
                workerActive = true
                shouldStartWorker = true
            }
        }
        if shouldStartWorker {
            workQueue.async { [weak self] in
                self?.consumePendingFrame()
            }
        }
    }

    func start(
        onFirstSample: @escaping @Sendable (Result<Void, Error>) -> Void,
        onFailure: @escaping @Sendable (Error) -> Void
    ) {
        emitLifecycle("start-request")
        var shouldStartWorker = false
        stateLock.withLock {
            active = true
            metrics = PiPSubtitleCompositionMetrics()
            firstSampleHandler = onFirstSample
            runtimeFailureHandler = onFailure
            deliveredFirstSample = false
            pendingFrame = latestFrame
            // A preceding PiP session flushes the displayed image. Re-entry
            // while paused can reuse the exact same decoded generation, so
            // the first cached frame must be presented independently of the
            // synchronizer clock instead of waiting for a future frame.
            pendingFrameDisplaysImmediately = pendingFrame != nil
            lastEnqueuedGeneration = nil
            if pendingFrame != nil, !workerActive {
                workerActive = true
                shouldStartWorker = true
            }
        }
        if shouldStartWorker {
            workQueue.async { [weak self] in
                self?.consumePendingFrame()
            }
        }
    }

    func stop() {
        emitLifecycle("stop-request")
        stateLock.withLock {
            compositionFence.invalidate()
            active = false
            pendingFrame = nil
            pendingFrameDisplaysImmediately = false
            firstSampleHandler = nil
            runtimeFailureHandler = nil
            deliveredFirstSample = false
        }
        workQueue.async { [weak self] in
            guard let self else { return }
            presenter.flush(removeDisplayedImage: true)
            emitMetrics()
        }
    }

    func invalidatePendingFrames() {
        stateLock.withLock {
            compositionFence.invalidate()
            latestFrame = nil
            pendingFrame = nil
            pendingFrameDisplaysImmediately = false
            lastEnqueuedGeneration = nil
        }
    }

    @discardableResult
    func setViewportSize(_ viewportSize: CGSize?) -> CGSize? {
        let fallback = stateLock.withLock { lastSourceSize }
        let size = viewportSize.flatMap { candidate -> CGSize? in
            guard candidate.width.isFinite,
                  candidate.height.isFinite,
                  candidate.width > 0,
                  candidate.height > 0
            else {
                return nil
            }
            return candidate
        } ?? fallback
        guard size.width > 0, size.height > 0 else { return nil }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        presenter.displayLayer.contentsScale = 1
        presenter.displayLayer.bounds = CGRect(origin: .zero, size: size)
        CATransaction.commit()
        return size
    }

    func metricsSnapshot() -> PiPSubtitleCompositionMetrics {
        stateLock.withLock { metrics }
    }

    func composedPixelBufferForTesting(
        _ frame: NativeDecodedVideoFrame
    ) async throws -> CVPixelBuffer {
        let box: PixelBufferBox = try await withCheckedThrowingContinuation { continuation in
            workQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(
                        throwing: PiPSubtitleCompositorError.commandEncoding
                    )
                    return
                }
                do {
                    try compose(frame) { result in
                        continuation.resume(with: result.map {
                            PixelBufferBox($0.0)
                        })
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        return box.pixelBuffer
    }

    private func consumePendingFrame() {
        let work: (
            frame: NativeDecodedVideoFrame,
            displayImmediately: Bool,
            revision: UInt64
        )? =
            stateLock.withLock {
            guard active else {
                workerActive = false
                return nil
            }
            let frame = pendingFrame
            pendingFrame = nil
            let displayImmediately = pendingFrameDisplaysImmediately
            pendingFrameDisplaysImmediately = false
            if frame == nil {
                workerActive = false
            }
            return frame.map { ($0, displayImmediately, compositionFence.revision) }
        }
        guard let work else { return }

        do {
            try compose(work.frame) { [weak self] result in
                guard let self else { return }
                let resultBox = CompositionResultBox(result)
                workQueue.async {
                    self.finishComposition(
                        frame: work.frame,
                        forceDisplayImmediately: work.displayImmediately,
                        revision: work.revision,
                        result: resultBox.result
                    )
                }
            }
        } catch PiPSubtitleCompositorError.outputPoolExhausted(kCVReturnWouldExceedAllocationThreshold) {
            // Renderer-held buffers are backpressure, not a format failure.
            // Keep one pending frame and resume on Core Video's notification.
            stateLock.withLock {
                if active, compositionFence.accepts(work.revision), pendingFrame == nil {
                    pendingFrame = work.frame
                    pendingFrameDisplaysImmediately = work.displayImmediately
                }
                workerActive = false
            }
        } catch {
            reportCompositionFailure(
                error,
                revision: work.revision,
                metric: .unsupported
            )
            workQueue.async { [weak self] in
                self?.consumePendingFrame()
            }
        }
    }

    private func finishComposition(
        frame: NativeDecodedVideoFrame,
        forceDisplayImmediately: Bool,
        revision: UInt64,
        result: Result<(CVPixelBuffer, UInt64), Error>
    ) {
        switch result {
        case let .success((pixelBuffer, gpuNanoseconds)):
            let outputSize = CGSize(
                width: CVPixelBufferGetWidth(pixelBuffer),
                height: CVPixelBufferGetHeight(pixelBuffer)
            )
            let outputFrame = NativeDecodedVideoFrame(
                pixelBuffer: pixelBuffer,
                planarOwnershipToken: nil,
                presentationTime: frame.presentationTime,
                duration: frame.duration,
                generation: frame.generation,
                codedSize: outputSize,
                displaySize: outputSize,
                pixelAspectRatio: CGSize(width: 1, height: 1),
                rotationDegrees: 0,
                colorPrimaries: frame.colorPrimaries,
                transferCharacteristic: frame.transferCharacteristic,
                matrixCoefficients: CVPixelBufferIsPlanar(pixelBuffer) ? frame.matrixCoefficients : nil,
                isFullRange: CVPixelBufferIsPlanar(pixelBuffer)
                    ? CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange : true,
                hasMasteringDisplayMetadata: false,
                hasContentLightMetadata: false,
                sourceComponentDepth: CVPixelBufferIsPlanar(pixelBuffer) || CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_ARGB2101010LEPacked ? 10 : 8,
                ffmpegPixelFormat: CVPixelBufferIsPlanar(pixelBuffer) ? "pip-composited-hdr-p010" : CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_ARGB2101010LEPacked
                    ? "pip-composited-bgr10a2" : "pip-composited-bgra",
                isHardwareDecoded: false,
                isCopiedHardwarePath: true,
                isNearZeroCopy: false
            )
            do {
                let accepted = try stateLock.withLock { () throws -> Bool in
                    guard active, compositionFence.accepts(revision) else {
                        metrics.discardedStaleCompositions += 1
                        return false
                    }
                    let changed = lastEnqueuedGeneration != frame.generation
                        || forceDisplayImmediately
                    lastEnqueuedGeneration = frame.generation
                    try presenter.enqueue(
                        outputFrame,
                        displayImmediately: changed
                    )
                    metrics.composedFrames += 1
                    metrics.immediatelyDisplayedFrames += changed ? 1 : 0
                    metrics.compositionGPUTimeNanoseconds &+= gpuNanoseconds
                    return true
                }
                guard accepted else {
                    consumePendingFrame()
                    return
                }
                finishFirstSample(.success(()))
            } catch {
                reportCompositionFailure(
                    error,
                    revision: revision,
                    metric: .enqueue
                )
            }
        case let .failure(error):
            reportCompositionFailure(
                error,
                revision: revision,
                metric: .enqueue
            )
        }
        consumePendingFrame()
    }

    private func finishFirstSample(_ result: Result<Void, Error>) {
        let handler: (@Sendable (Result<Void, Error>) -> Void)? = stateLock.withLock {
            guard !deliveredFirstSample else { return nil }
            deliveredFirstSample = true
            let handler = firstSampleHandler
            firstSampleHandler = nil
            return handler
        }
        if handler != nil {
            switch result {
            case .success:
                emitLifecycle("first-sample")
            case let .failure(error):
                emitLifecycle("first-sample-failed error=\(error.localizedDescription)")
            }
        }
        handler?(result)
    }

    private func reportCompositionFailure(
        _ error: Error,
        revision: UInt64,
        metric: CompositionFailureMetric
    ) {
        let delivery: CompositionFailureDelivery = stateLock.withLock {
            guard active, compositionFence.accepts(revision) else {
                metrics.discardedStaleCompositions += 1
                return .stale
            }
            switch metric {
            case .unsupported:
                metrics.unsupportedFrames += 1
            case .enqueue:
                metrics.enqueueFailures += 1
            }
            if deliveredFirstSample {
                let handler = runtimeFailureHandler
                runtimeFailureHandler = nil
                return .runtime(handler)
            }
            deliveredFirstSample = true
            runtimeFailureHandler = nil
            let handler = firstSampleHandler
            firstSampleHandler = nil
            return .firstSample(handler)
        }

        switch delivery {
        case .stale:
            break
        case let .firstSample(handler):
            if handler != nil {
                emitLifecycle(
                    "first-sample-failed error=\(error.localizedDescription)"
                )
            }
            handler?(.failure(error))
        case let .runtime(handler):
            handler?(error)
        }
    }

    private func compose(
        _ frame: NativeDecodedVideoFrame,
        completion: @escaping @Sendable (
            Result<(CVPixelBuffer, UInt64), Error>
        ) -> Void
    ) throws {
        let cpuStart = DispatchTime.now().uptimeNanoseconds
        let sourceWidth = CVPixelBufferGetWidth(frame.pixelBuffer)
        let sourceHeight = CVPixelBufferGetHeight(frame.pixelBuffer)
        guard sourceWidth > 0, sourceHeight > 0 else {
            throw PiPSubtitleCompositorError.textureCreation
        }
        let displaySize = Self.validDisplaySize(
            frame.displaySize,
            fallback: CGSize(width: sourceWidth, height: sourceHeight)
        )
        var adjustments = stateLock.withLock { videoAdjustments }
        // System PiP owns its window aspect. Encode the selected crop/aspect
        // into the frame; Fit/Fill remains the main-window sizing preference.
        adjustments.scaleMode = .fit
        let aspect = VideoPresentationGeometry.ratio(adjustments.aspectRatio) ?? displaySize.width / displaySize.height
        var outputSize = CGSize(width: displaySize.height * aspect, height: displaySize.height)
        if let crop = VideoPresentationGeometry.ratio(adjustments.crop) {
            if crop < aspect { outputSize.width = outputSize.height * crop }
            else { outputSize.height = outputSize.width / crop }
        }
        let scale = min(1, 8192 / max(outputSize.width, outputSize.height),
            sqrt(33_554_432 / max(outputSize.width * outputSize.height, 1)))
        let width = max(2, Int(outputSize.width * scale) / 2 * 2)
        let height = max(2, Int(outputSize.height * scale) / 2 * 2)
        let geometry = VideoPresentationGeometry(sourceSize: displaySize,
            bounds: CGRect(x: 0, y: 0, width: width, height: height), adjustments: adjustments)
        stateLock.withLock {
            lastSourceSize = CGSize(width: width, height: height)
        }
        if presenter.displayLayer.bounds.isEmpty {
            setViewportSize(nil)
        }

        let compositionMode: PiPSubtitleCompositionMode
        switch PiPSubtitleCompositionPolicy.eligibility(for: frame) {
        case let .supported(mode): compositionMode = mode
        case let .videoOnly(reason): throw PiPSubtitleCompositorError.unsupportedSource(reason)
        }
        let tenBit = compositionMode.usesTenBitOutput
        let hdr = compositionMode.isHDR
        if (hdr && hdrPipelines == nil) || (tenBit && !hdr && tenBitPipelines == nil) {
            throw PiPSubtitleCompositorError.pipelineCreation("The required high-precision composition target is unavailable")
        }
        // One reusable HDR intermediate, at most 64 MiB (includes UHD 4K).
        guard !hdr || width * height <= 8_388_608 else {
            throw PiPSubtitleCompositorError.pipelineCreation("HDR PiP composition exceeds its 64 MiB working-texture limit")
        }
        let outputFormat = hdr ? CVPixelBufferGetPixelFormatType(frame.pixelBuffer)
            : tenBit ? kCVPixelFormatType_ARGB2101010LEPacked : kCVPixelFormatType_32BGRA
        let output = try checkoutOutputPixelBuffer(width: width, height: height, pixelFormat: outputFormat)
        applySDRColorAttachments(from: frame.pixelBuffer, to: output)
        if hdr {
            // Signal tags describe the actual generated pixels. Source static
            // luminance statistics are not copied onto the composited image.
            CVBufferSetAttachment(output, kCVImageBufferTransferFunctionKey,
                frame.transferCharacteristic == 18 ? kCVImageBufferTransferFunction_ITU_R_2100_HLG
                    : kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ, .shouldPropagate)
            CVBufferSetAttachment(output, kCVImageBufferColorPrimariesKey,
                frame.colorPrimaries == 1 ? kCVImageBufferColorPrimaries_ITU_R_709_2
                    : kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
            let matrix = frame.matrixCoefficients == 9 ? kCVImageBufferYCbCrMatrix_ITU_R_2020
                : frame.matrixCoefficients == 5 || frame.matrixCoefficients == 6
                    ? kCVImageBufferYCbCrMatrix_ITU_R_601_4 : kCVImageBufferYCbCrMatrix_ITU_R_709_2
            CVBufferSetAttachment(output, kCVImageBufferYCbCrMatrixKey, matrix, .shouldPropagate)
        }
        let outputCVTexture = try makeCVTexture(pixelBuffer: output,
            pixelFormat: hdr ? .r16Unorm : tenBit ? .bgr10a2Unorm : .bgra8Unorm,
            width: width, height: height, plane: 0)
        let outputTexture: any MTLTexture
        if hdr {
            if hdrLinearTexture?.width != width || hdrLinearTexture?.height != height {
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
                    width: width, height: height, mipmapped: false)
                descriptor.usage = [.renderTarget, .shaderRead]
                descriptor.storageMode = .private
                hdrLinearTexture = device.makeTexture(descriptor: descriptor)
            }
            guard let linear = hdrLinearTexture else { throw PiPSubtitleCompositorError.textureCreation }
            outputTexture = linear
        } else {
            hdrLinearTexture = nil
            guard let texture = CVMetalTextureGetTexture(outputCVTexture) else { throw PiPSubtitleCompositorError.textureCreation }
            outputTexture = texture
        }

        let sourceTextures: [CVMetalTexture]
        let videoPipeline: any MTLRenderPipelineState
        switch compositionMode {
        case .bgra:
            sourceTextures = [try makeCVTexture(
                pixelBuffer: frame.pixelBuffer,
                pixelFormat: .bgra8Unorm,
                width: sourceWidth,
                height: sourceHeight,
                plane: 0
            )]
            videoPipeline = bgraPipeline
        case .nv12VideoRange, .nv12FullRange, .p010VideoRange, .p010FullRange, .hdrP010VideoRange, .hdrP010FullRange:
            sourceTextures = [
                try makeCVTexture(
                    pixelBuffer: frame.pixelBuffer,
                    pixelFormat: tenBit ? .r16Unorm : .r8Unorm,
                    width: sourceWidth,
                    height: sourceHeight,
                    plane: 0
                ),
                try makeCVTexture(
                    pixelBuffer: frame.pixelBuffer,
                    pixelFormat: tenBit ? .rg16Unorm : .rg8Unorm,
                    width: CVPixelBufferGetWidthOfPlane(frame.pixelBuffer, 1),
                    height: CVPixelBufferGetHeightOfPlane(frame.pixelBuffer, 1),
                    plane: 1
                ),
            ]
            videoPipeline = hdr ? hdrPipelines!.video : tenBit ? tenBitPipelines!.video : nv12Pipeline
        }

        let subtitleBinding = stateLock.withLock {
            (
                pipeline: boundSubtitlePipeline,
                revision: subtitlePipelineRevision
            )
        }
        if preparedSubtitlePipelineRevision != subtitleBinding.revision {
            preparedSubtitleFrame = nil
            preparedSubtitlePipelineRevision = subtitleBinding.revision
            subtitlePacker.retireSource()
        }
        if let subtitles = subtitleBinding.pipeline {
            let subtitleSnapshot = subtitles.pictureInPictureSubtitleSnapshot(
                at: frame.presentationTime,
                viewport: geometry.imageRect,
                videoSize: displaySize
            )
            if subtitleSnapshot.changed || preparedSubtitleFrame == nil {
                preparedSubtitleFrame = subtitlePacker.prepare(
                    regions: subtitleSnapshot.regions,
                    canvasSize: CGSize(width: width, height: height),
                    strategy: .metalR8Atlas
                )
            }
        } else {
            preparedSubtitleFrame = nil
        }
        let preparedSubtitleFrame = preparedSubtitleFrame
        if preparedSubtitleFrame?.quads.isEmpty == false {
            stateLock.withLock {
                metrics.subtitleVisibleFrames += 1
            }
        }

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw PiPSubtitleCompositorError.commandEncoding
        }
        let videoPass = MTLRenderPassDescriptor()
        videoPass.colorAttachments[0].texture = outputTexture
        videoPass.colorAttachments[0].loadAction = .clear
        videoPass.colorAttachments[0].storeAction = .store
        videoPass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        guard let videoEncoder = commandBuffer.makeRenderCommandEncoder(
            descriptor: videoPass
        ) else {
            throw PiPSubtitleCompositorError.commandEncoding
        }
        videoEncoder.setRenderPipelineState(videoPipeline)
        let coordinates = PiPVideoMapping.textureCoordinates(
            codedSize: CGSize(width: sourceWidth, height: sourceHeight),
            cleanAperture: frame.cleanAperture,
            rotationDegrees: frame.rotationDegrees,
            mirrored: frame.isHorizontallyMirrored,
            displayCrop: CGRect(x: -geometry.imageRect.minX / geometry.imageRect.width,
                y: -geometry.imageRect.minY / geometry.imageRect.height,
                width: Double(width) / geometry.imageRect.width,
                height: Double(height) / geometry.imageRect.height)
        )
        coordinates.withUnsafeBytes { bytes in
            videoEncoder.setVertexBytes(bytes.baseAddress!, length: bytes.count, index: 0)
        }
        for (index, cvTexture) in sourceTextures.enumerated() {
            guard let texture = CVMetalTextureGetTexture(cvTexture) else {
                videoEncoder.endEncoding()
                throw PiPSubtitleCompositorError.textureCreation
            }
            videoEncoder.setFragmentTexture(texture, index: index)
        }
        videoEncoder.setFragmentSamplerState(sampler, index: 0)
        var sourceEncoding: UInt32 =
            (compositionMode.isFullRange ? 1 : 0) | (tenBit ? 2 : 0)
        videoEncoder.setFragmentBytes(
            &sourceEncoding,
            length: MemoryLayout<UInt32>.size,
            index: 0
        )
        var coefficients = PiPVideoMapping.colorCoefficients(matrix: frame.matrixCoefficients)
        videoEncoder.setFragmentBytes(
            &coefficients, length: MemoryLayout<SIMD4<Float>>.stride, index: 1
        )
        var transfer = UInt32(clamping: frame.transferCharacteristic ?? 16)
        var primaries = UInt32(clamping: frame.colorPrimaries ?? 9)
        if hdr {
            videoEncoder.setFragmentBytes(&transfer, length: 4, index: 2)
            videoEncoder.setFragmentBytes(&primaries, length: 4, index: 3)
        }
        videoEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        videoEncoder.endEncoding()

        if let preparedSubtitleFrame,
           !preparedSubtitleFrame.quads.isEmpty
        {
            try encodeSubtitles(
                preparedSubtitleFrame,
                target: outputTexture,
                commandBuffer: commandBuffer,
                hdrPrimaries: hdr ? primaries : nil
            )
        }
        var outputTextures = [outputCVTexture]
        if hdr, let hdrPipelines {
            let chroma = try makeCVTexture(pixelBuffer: output, pixelFormat: .rg16Unorm,
                width: CVPixelBufferGetWidthOfPlane(output, 1), height: CVPixelBufferGetHeightOfPlane(output, 1), plane: 1)
            outputTextures.append(chroma)
            let identity = PiPVideoMapping.textureCoordinates(codedSize: CGSize(width: width, height: height),
                cleanAperture: nil, rotationDegrees: 0, mirrored: false)
            for (texture, pipeline) in zip(outputTextures, [hdrPipelines.luma, hdrPipelines.chroma]) {
                let pass = MTLRenderPassDescriptor()
                pass.colorAttachments[0].texture = CVMetalTextureGetTexture(texture)
                pass.colorAttachments[0].loadAction = .dontCare
                pass.colorAttachments[0].storeAction = .store
                guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
                    throw PiPSubtitleCompositorError.commandEncoding
                }
                encoder.setRenderPipelineState(pipeline)
                identity.withUnsafeBytes { encoder.setVertexBytes($0.baseAddress!, length: $0.count, index: 0) }
                encoder.setFragmentTexture(outputTexture, index: 0)
                encoder.setFragmentBytes(&sourceEncoding, length: 4, index: 0)
                encoder.setFragmentBytes(&coefficients, length: MemoryLayout<SIMD4<Float>>.stride, index: 1)
                encoder.setFragmentBytes(&transfer, length: 4, index: 2)
                encoder.setFragmentBytes(&primaries, length: 4, index: 3)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
                encoder.endEncoding()
            }
        }

        let resources = MetalFrameResources(
            outputPixelBuffer: output,
            retainedCVTextures: sourceTextures + outputTextures
        )
        let cpuNanoseconds = DispatchTime.now().uptimeNanoseconds - cpuStart
        stateLock.withLock {
            metrics.compositionCPUTimeNanoseconds &+= cpuNanoseconds
        }
        commandBuffer.addCompletedHandler { commandBuffer in
            // Metal's callback runs on an external queue. Rejoin the resource
            // owner's queue before reading the retained resources or completing
            // the frame, with an explicit synchronization boundary.
            self.workQueue.async {
                _ = resources.retainedCVTextures
                guard commandBuffer.status != .error else {
                    completion(.failure(
                        commandBuffer.error
                            ?? PiPSubtitleCompositorError.commandEncoding
                    ))
                    return
                }
                let gpuDuration = commandBuffer.gpuEndTime - commandBuffer.gpuStartTime
                let gpuNanoseconds: UInt64 = if gpuDuration.isFinite, gpuDuration > 0 {
                    UInt64(gpuDuration * 1_000_000_000)
                } else {
                    0
                }
                completion(.success((resources.outputPixelBuffer, gpuNanoseconds)))
            }
        }
        commandBuffer.commit()
    }

    private func encodeSubtitles(
        _ frame: ASSPreparedSubtitleFrame,
        target: any MTLTexture,
        commandBuffer: any MTLCommandBuffer,
        hdrPrimaries: UInt32? = nil
    ) throws {
        let textureWidth = Int(frame.textureSize.width)
        let textureHeight = Int(frame.textureSize.height)
        guard textureWidth > 0, textureHeight > 0 else { return }
        let pixelFormat: MTLPixelFormat = frame.strategy == .metalBGRA ? .bgra8Unorm : .r8Unorm
        if subtitleTexture == nil
            || subtitleTexture!.width < textureWidth
            || subtitleTexture!.height < textureHeight
            || subtitleTexture!.pixelFormat != pixelFormat
        {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: pixelFormat,
                width: textureWidth,
                height: textureHeight,
                mipmapped: false
            )
            descriptor.usage = [.shaderRead]
            descriptor.storageMode = .shared
            subtitleTexture = device.makeTexture(descriptor: descriptor)
        }
        guard let subtitleTexture else {
            throw PiPSubtitleCompositorError.textureCreation
        }
        frame.pixels.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            subtitleTexture.replace(
                region: MTLRegionMake2D(0, 0, textureWidth, textureHeight),
                mipmapLevel: 0,
                withBytes: baseAddress,
                bytesPerRow: frame.bytesPerRow
            )
        }

        let vertices = subtitleVertices(frame, texture: subtitleTexture)
        let requiredBytes = vertices.count * MemoryLayout<SubtitleVertex>.stride
        if subtitleVertexBuffer == nil || subtitleVertexCapacity < requiredBytes {
            subtitleVertexCapacity = max(requiredBytes, max(subtitleVertexCapacity * 2, 4_096))
            subtitleVertexBuffer = device.makeBuffer(
                length: subtitleVertexCapacity,
                options: .storageModeShared
            )
        }
        guard let subtitleVertexBuffer else {
            throw PiPSubtitleCompositorError.commandEncoding
        }
        vertices.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            subtitleVertexBuffer.contents().copyMemory(
                from: baseAddress,
                byteCount: requiredBytes
            )
        }

        let subtitlePass = MTLRenderPassDescriptor()
        subtitlePass.colorAttachments[0].texture = target
        subtitlePass.colorAttachments[0].loadAction = .load
        subtitlePass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(
            descriptor: subtitlePass
        ) else {
            throw PiPSubtitleCompositorError.commandEncoding
        }
        var viewport = SIMD2<Float>(
            Float(max(frame.canvasSize.width, 1)),
            Float(max(frame.canvasSize.height, 1))
        )
        if var primaries = hdrPrimaries, let hdrPipelines {
            encoder.setRenderPipelineState(frame.strategy == .metalBGRA ? hdrPipelines.bitmap : hdrPipelines.text)
            encoder.setFragmentBytes(&primaries, length: 4, index: 3)
        } else if target.pixelFormat == .bgr10a2Unorm, let tenBitPipelines {
            encoder.setRenderPipelineState(frame.strategy == .metalBGRA ? tenBitPipelines.bitmap : tenBitPipelines.text)
        } else {
            encoder.setRenderPipelineState(frame.strategy == .metalBGRA ? bitmapSubtitlePipeline : subtitlePipeline)
        }
        encoder.setVertexBuffer(subtitleVertexBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(
            &viewport,
            length: MemoryLayout<SIMD2<Float>>.size,
            index: 1
        )
        encoder.setFragmentTexture(subtitleTexture, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.drawPrimitives(
            type: .triangle,
            vertexStart: 0,
            vertexCount: vertices.count
        )
        encoder.endEncoding()
    }

    private func subtitleVertices(
        _ frame: ASSPreparedSubtitleFrame,
        texture: any MTLTexture
    ) -> [SubtitleVertex] {
        var vertices: [SubtitleVertex] = []
        vertices.reserveCapacity(frame.quads.count * 6)
        for quad in frame.quads {
            let alpha = Float(255 - UInt8(quad.color & 0xff)) / 255
            let color = SIMD4<Float>(
                Float((quad.color >> 24) & 0xff) / 255,
                Float((quad.color >> 16) & 0xff) / 255,
                Float((quad.color >> 8) & 0xff) / 255,
                alpha
            )
            let x0 = Float(quad.destination.minX)
            let y0 = Float(quad.destination.minY)
            let x1 = Float(quad.destination.maxX)
            let y1 = Float(quad.destination.maxY)
            let u0 = Float(quad.source.minX) / Float(texture.width)
            let v0 = Float(quad.source.minY) / Float(texture.height)
            let u1 = Float(quad.source.maxX) / Float(texture.width)
            let v1 = Float(quad.source.maxY) / Float(texture.height)
            let topLeft = SubtitleVertex(
                position: SIMD2(x0, y0),
                textureCoordinate: SIMD2(u0, v0),
                color: color
            )
            let bottomLeft = SubtitleVertex(
                position: SIMD2(x0, y1),
                textureCoordinate: SIMD2(u0, v1),
                color: color
            )
            let topRight = SubtitleVertex(
                position: SIMD2(x1, y0),
                textureCoordinate: SIMD2(u1, v0),
                color: color
            )
            let bottomRight = SubtitleVertex(
                position: SIMD2(x1, y1),
                textureCoordinate: SIMD2(u1, v1),
                color: color
            )
            vertices += [topLeft, bottomLeft, topRight, topRight, bottomLeft, bottomRight]
        }
        return vertices
    }

    private func checkoutOutputPixelBuffer(
        width: Int,
        height: Int,
        pixelFormat: OSType = kCVPixelFormatType_32BGRA
    ) throws -> CVPixelBuffer {
        if outputPool == nil
            || outputPoolSize != CGSize(width: width, height: height)
            || outputPoolPixelFormat != pixelFormat
        {
            let attributes: [CFString: Any] = [
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferPixelFormatTypeKey: pixelFormat,
                kCVPixelBufferMetalCompatibilityKey: true,
                kCVPixelBufferIOSurfacePropertiesKey: [:],
            ]
            var createdPool: CVPixelBufferPool?
            let status = CVPixelBufferPoolCreate(
                kCFAllocatorDefault,
                nil,
                attributes as CFDictionary,
                &createdPool
            )
            guard status == kCVReturnSuccess, let createdPool else {
                throw PiPSubtitleCompositorError.outputPoolCreation(status)
            }
            if let outputPoolObserver {
                NotificationCenter.default.removeObserver(outputPoolObserver)
            }
            outputPool = createdPool
            outputPoolObserver = NotificationCenter.default.addObserver(
                forName: NSNotification.Name(kCVPixelBufferPoolFreeBufferNotification as String),
                object: createdPool,
                queue: nil
            ) { [weak self] _ in
                self?.workQueue.async { [weak self] in
                    guard let self else { return }
                    let shouldResume = stateLock.withLock {
                        guard active, !workerActive, pendingFrame != nil else { return false }
                        workerActive = true
                        return true
                    }
                    if shouldResume { consumePendingFrame() }
                }
            }
            outputPoolSize = CGSize(width: width, height: height)
            outputPoolPixelFormat = pixelFormat
            observedOutputBuffers = []
        }
        guard let outputPool else {
            throw PiPSubtitleCompositorError.outputPoolCreation(
                kCVReturnInvalidArgument
            )
        }
        let allocationAttributes = [
            kCVPixelBufferPoolAllocationThresholdKey: 12,
        ] as CFDictionary
        var output: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
            kCFAllocatorDefault,
            outputPool,
            allocationAttributes,
            &output
        )
        guard status == kCVReturnSuccess, let output else {
            stateLock.withLock {
                metrics.outputPoolMisses += 1
            }
            throw PiPSubtitleCompositorError.outputPoolExhausted(status)
        }
        let identity = UInt(bitPattern: Unmanaged.passUnretained(output).toOpaque())
        stateLock.withLock {
            if observedOutputBuffers.insert(identity).inserted {
                metrics.outputPixelBufferAllocations += 1
            } else {
                metrics.outputPixelBufferReuses += 1
            }
        }
        return output
    }

    deinit {
        if let outputPoolObserver { NotificationCenter.default.removeObserver(outputPoolObserver) }
    }

    private func makeCVTexture(
        pixelBuffer: CVPixelBuffer,
        pixelFormat: MTLPixelFormat,
        width: Int,
        height: Int,
        plane: Int
    ) throws -> CVMetalTexture {
        var texture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            pixelFormat,
            width,
            height,
            plane,
            &texture
        )
        guard status == kCVReturnSuccess, let texture else {
            throw PiPSubtitleCompositorError.textureCreation
        }
        return texture
    }

    private func applySDRColorAttachments(from source: CVPixelBuffer, to pixelBuffer: CVPixelBuffer) {
        CVBufferSetAttachment(
            pixelBuffer,
            kCVImageBufferColorPrimariesKey,
            CVBufferCopyAttachment(source, kCVImageBufferColorPrimariesKey, nil)
                ?? kCVImageBufferColorPrimaries_ITU_R_709_2,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            pixelBuffer,
            kCVImageBufferTransferFunctionKey,
            CVBufferCopyAttachment(source, kCVImageBufferTransferFunctionKey, nil)
                ?? kCVImageBufferTransferFunction_ITU_R_709_2,
            .shouldPropagate
        )
        // Pixels are now full-range RGB. Do not tag them as source YCbCr.
        CVBufferRemoveAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey)
    }

    private static func validDisplaySize(
        _ candidate: CGSize,
        fallback: CGSize
    ) -> CGSize {
        guard candidate.width.isFinite,
              candidate.height.isFinite,
              candidate.width > 0,
              candidate.height > 0,
              candidate.width <= 16_384,
              candidate.height <= 16_384
        else {
            return fallback
        }
        return candidate
    }

    private func emitMetrics() {
        let snapshot = metricsSnapshot()
        let message = [
            "[native-pip-subtitles]",
            "received=\(snapshot.receivedFrames)",
            "composed=\(snapshot.composedFrames)",
            "immediate=\(snapshot.immediatelyDisplayedFrames)",
            "visible=\(snapshot.subtitleVisibleFrames)",
            "coalesced=\(snapshot.coalescedFrames)",
            "unsupported=\(snapshot.unsupportedFrames)",
            "pool-allocations=\(snapshot.outputPixelBufferAllocations)",
            "pool-reuses=\(snapshot.outputPixelBufferReuses)",
            "pool-misses=\(snapshot.outputPoolMisses)",
            "enqueue-failures=\(snapshot.enqueueFailures)",
            "stale-compositions=\(snapshot.discardedStaleCompositions)",
            String(format: "cpu-ms-per-frame=%.4f", snapshot.averageCPUTimeMilliseconds),
            String(format: "gpu-ms-per-frame=%.4f", snapshot.averageGPUTimeMilliseconds),
        ].joined(separator: " ")
        FileHandle.standardError.write(Data("\(message)\n".utf8))
        Self.logger.notice("\(message, privacy: .public)")
    }

    private func emitLifecycle(_ event: String) {
        FileHandle.standardError.write(
            Data("[native-pip-subtitles] \(event)\n".utf8)
        )
    }

    private static func makePipeline(
        device: any MTLDevice,
        vertex: any MTLFunction,
        fragment: any MTLFunction,
        blending: Bool,
        premultiplied: Bool = false,
        pixelFormat: MTLPixelFormat = .bgra8Unorm
    ) throws -> any MTLRenderPipelineState {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
        descriptor.colorAttachments[0].isBlendingEnabled = blending
        if blending {
            descriptor.colorAttachments[0].sourceRGBBlendFactor = premultiplied ? .one : .sourceAlpha
            descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
            descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        }
        return try device.makeRenderPipelineState(descriptor: descriptor)
    }

}
