import AppKit
import Foundation
import QuartzCore

enum SubtitlePresentationOutcome: Equatable {
    case presentedMetal
    case metalFailure(MetalASSFailureReason)
}

struct SubtitleCompositorDiagnostics: Equatable, Sendable {
    var selectedCompositor: SubtitleCompositionStrategy
    var metalInitializationAttempts = 0
    var metalActivations = 0
    var failureCount = 0
    var lastFailureReason: MetalASSFailureReason?
    var lastFailureRevision: UInt64?
    var lastFailureMediaIdentity: String?
    var failureAfterVisibleMetal = false
    var metalFramesSubmitted = 0
    var metalClearsSubmitted = 0
    var drawableAcquisitionCount = 0
    var drawableAcquisitionFailures = 0
    var commandBufferFailures = 0
    var textureAllocationFailures = 0
    var bufferAllocationFailures = 0
    var commandBuffersSubmitted = 0
    var geometryReconfigurations = 0
    var backingScaleReconfigurations = 0
}

final class SubtitleOverlayView: NSView {
    var onPresentationInvalidated: (() -> Void)?
    let compositionStrategy: SubtitleCompositionStrategy
    private var metalRenderer: MetalASSSubtitleRenderer?
    private(set) var lastPreparedCanvasSize: CGSize?
    private(set) var requiredMetalInitializationFailure: MetalASSFailureReason?
    private var diagnostics: SubtitleCompositorDiagnostics
    private var lastBackingScale: CGFloat?
    private var lastConfiguredBounds: CGSize?
    private var lastRevision: SubtitleFenceRevision?
    private var lastMediaIdentity: String?

    override convenience init(frame frameRect: NSRect) {
        self.init(frame: frameRect, compositionStrategy: .metalR8Atlas)
    }

    convenience init(headless: Bool) {
        self.init(
            frame: .zero,
            compositionStrategy: .metalR8Atlas,
            configuresMetalCompositor: !headless
        )
    }

    init(
        frame frameRect: NSRect,
        compositionStrategy: SubtitleCompositionStrategy,
        configuresMetalCompositor: Bool = true
    ) {
        self.compositionStrategy = compositionStrategy
        diagnostics = SubtitleCompositorDiagnostics(
            selectedCompositor: compositionStrategy
        )
        super.init(frame: frameRect)
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowVisibilityChanged(_:)),
            name: NSWindow.didChangeOcclusionStateNotification, object: nil
        )
        if configuresMetalCompositor {
            configureMetalCompositor()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onPresentationInvalidated?()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        onPresentationInvalidated?()
    }

    @objc private func windowVisibilityChanged(_ notification: Notification) {
        guard let window, notification.object as? NSWindow === window,
              window.occlusionState.contains(.visible) else { return }
        onPresentationInvalidated?()
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    func clear(
        revision: SubtitleFenceRevision? = nil,
        mediaIdentity: String? = nil
    ) {
        guard let metalLayer = layer as? CAMetalLayer,
              let metalRenderer
        else {
            _ = recordFailure(
                requiredMetalInitializationFailure ?? .deviceInitialization,
                revision: revision,
                mediaIdentity: mediaIdentity
            )
            return
        }
        let empty = ASSPreparedSubtitleFrame(
            strategy: compositionStrategy,
            canvasSize: metalBackingPixelSize,
            textureSize: .zero,
            bytesPerRow: 0,
            pixels: Data(),
            quads: [],
            metrics: ASSCompositionMetrics(
                imageCount: 0,
                copiedBytes: 0,
                uploadBytes: 0,
                drawCalls: 1
            )
        )
        switch metalRenderer.draw(empty, in: metalLayer) {
        case .success:
            diagnostics.metalClearsSubmitted += 1
        case let .failure(reason):
            _ = recordFailure(
                reason == .drawableAcquisition
                    ? .requiredClearSubmission
                    : reason,
                revision: revision,
                mediaIdentity: mediaIdentity
            )
            // A failed lifecycle clear must never leave subtitles from the
            // preceding generation visible.
            metalLayer.isHidden = true
        }
    }

    func present(
        _ frame: ASSPreparedSubtitleFrame,
        revision: SubtitleFenceRevision? = nil,
        mediaIdentity: String? = nil
    ) -> SubtitlePresentationOutcome {
        lastPreparedCanvasSize = frame.canvasSize
        lastRevision = revision
        lastMediaIdentity = mediaIdentity
        guard compositionStrategy == frame.strategy || (frame.usesBitmapAtlas && frame.strategy == .metalBGRA),
              let metalLayer = layer as? CAMetalLayer,
              let metalRenderer
        else {
            return recordFailure(
                .unsupportedConfiguration,
                revision: revision,
                mediaIdentity: mediaIdentity
            )
        }
        let result = metalRenderer.draw(
            frame,
            in: metalLayer,
            asynchronousFailure: { [weak self] reason in
                guard let self else { return }
                _ = self.recordFailure(
                    reason,
                    revision: self.lastRevision,
                    mediaIdentity: self.lastMediaIdentity
                )
            }
        )
        switch result {
        case .success:
            metalLayer.isHidden = false
            diagnostics.metalFramesSubmitted += 1
            return .presentedMetal
        case let .failure(reason):
            return recordFailure(
                reason,
                revision: revision,
                mediaIdentity: mediaIdentity
            )
        }
    }

    func recordFailure(
        _ reason: MetalASSFailureReason,
        revision: SubtitleFenceRevision?,
        mediaIdentity: String?
    ) -> SubtitlePresentationOutcome {
        diagnostics.failureCount += 1
        diagnostics.lastFailureReason = reason
        diagnostics.lastFailureRevision = revision?.rawValue
        diagnostics.lastFailureMediaIdentity = mediaIdentity
        diagnostics.failureAfterVisibleMetal =
            diagnostics.failureAfterVisibleMetal
                || diagnostics.metalFramesSubmitted > 0
        switch reason {
        case .drawableAcquisition:
            diagnostics.drawableAcquisitionFailures += 1
        case .commandBufferCreation,
             .commandEncoderCreation,
             .commandBufferExecution:
            diagnostics.commandBufferFailures += 1
        case .textureAllocation:
            diagnostics.textureAllocationFailures += 1
        case .bufferAllocation, .stagingAllocation:
            diagnostics.bufferAllocationFailures += 1
        default:
            break
        }
        emitDiagnostic(
            "failure reason=\(reason.rawValue) "
                + "revision=\(revision?.rawValue.description ?? "unknown") "
                + "media=\(mediaIdentity ?? "unknown")"
        )
        return .metalFailure(reason)
    }

    var metalBackingScale: CGFloat {
        guard let metalLayer = layer as? CAMetalLayer else { return 1 }
        return max(metalLayer.contentsScale, 1)
    }

    var metalMaximumTextureDimension: Int {
        metalRenderer?.maximumTextureDimension2D ?? 8_192
    }

    var metalBackingPixelSize: CGSize {
        guard let metalLayer = layer as? CAMetalLayer else {
            return bounds.size
        }
        return CGSize(
            width: max(metalLayer.drawableSize.width, 1),
            height: max(metalLayer.drawableSize.height, 1)
        )
    }

    func updateDrawableSize(backingScale: CGFloat) {
        guard let metalLayer = layer as? CAMetalLayer else { return }
        let geometryChanged = lastConfiguredBounds != bounds.size || lastBackingScale != backingScale
        if lastConfiguredBounds != bounds.size {
            diagnostics.geometryReconfigurations += 1
            lastConfiguredBounds = bounds.size
        }
        if lastBackingScale != backingScale {
            diagnostics.backingScaleReconfigurations += 1
            lastBackingScale = backingScale
        }
        metalLayer.contentsScale = backingScale
        metalLayer.drawableSize = CGSize(
            width: max(bounds.width * backingScale, 1),
            height: max(bounds.height * backingScale, 1)
        )
        if geometryChanged { onPresentationInvalidated?() }
    }

    func diagnosticsSnapshot() -> SubtitleCompositorDiagnostics {
        var snapshot = diagnostics
        if let metalRenderer {
            snapshot.drawableAcquisitionCount =
                metalRenderer.drawableAcquisitionCount
            snapshot.drawableAcquisitionFailures = max(
                snapshot.drawableAcquisitionFailures,
                metalRenderer.drawableAcquisitionFailures
            )
            snapshot.commandBufferFailures = max(
                snapshot.commandBufferFailures,
                metalRenderer.commandBufferFailures
            )
            snapshot.textureAllocationFailures = max(
                snapshot.textureAllocationFailures,
                metalRenderer.textureAllocationFailures
            )
            snapshot.bufferAllocationFailures = max(
                snapshot.bufferAllocationFailures,
                metalRenderer.bufferAllocationFailures
            )
            snapshot.commandBuffersSubmitted =
                metalRenderer.commandBuffersSubmitted
        }
        return snapshot
    }

    private func configureMetalCompositor() {
        diagnostics.metalInitializationAttempts += 1
        wantsLayer = true
        let metalLayer = CAMetalLayer()
        metalLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer = metalLayer
        do {
            metalRenderer = try MetalASSSubtitleRenderer(layer: metalLayer)
            diagnostics.metalActivations += 1
            emitDiagnostic(
                "selected=\(compositionStrategy.rawValue) activation=success"
            )
        } catch {
            let reason =
                (error as? MetalASSRendererError)?.reason
                ?? .pipelineCreation
            requiredMetalInitializationFailure = reason
            _ = recordFailure(
                reason,
                revision: nil,
                mediaIdentity: nil
            )
            metalLayer.isHidden = true
        }
    }

    private func emitDiagnostic(_ message: String) {
        FileHandle.standardError.write(
            Data("[ass-compositor] \(message)\n".utf8)
        )
    }
}
