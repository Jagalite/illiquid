import AppKit
import AVFoundation
import Foundation
import IlliquidCore
import IlliquidPlayback

/// App-owned sample-buffer video surface with a transparent libass overlay.
@MainActor
final class NativePlaybackSurfaceHost: PlaybackSurfaceHost {
    private unowned let backend: NativePlaybackRuntime
    private let nativeView: NativePlayerNSView
    private var isShutdown = false

    var view: NSView { nativeView }
    var videoViewportSize: CGSize {
        nativeView.effectivePresentationBounds.size
    }

    var videoAdjustments: VideoAdjustmentState {
        get { nativeView.videoAdjustments }
        set { nativeView.videoAdjustments = newValue; nativeView.layoutSubtreeIfNeeded() }
    }
    var sourceDisplaySize: CGSize {
        get { nativeView.sourceDisplaySize }
        set { nativeView.sourceDisplaySize = newValue }
    }

    var rotationDegrees: Double {
        get { nativeView.rotationDegrees }
        set {
            nativeView.rotationDegrees = newValue
            nativeView.needsLayout = true
        }
    }

    var isHorizontallyMirrored: Bool {
        get { nativeView.isHorizontallyMirrored }
        set { nativeView.isHorizontallyMirrored = newValue }
    }

    var pictureInPictureViewportSize: CGSize? {
        get { nativeView.pictureInPictureViewportSize }
        set { nativeView.pictureInPictureViewportSize = newValue }
    }

    var onOpenURLs: (([URL], PlaylistOpenMode) -> Void)? {
        get { nativeView.onOpenURLs }
        set { nativeView.onOpenURLs = newValue }
    }

    var onUserActivity: (() -> Void)? {
        get { nativeView.onUserActivity }
        set { nativeView.onUserActivity = newValue }
    }

    var onInteraction: ((PlaybackSurfaceInteraction) -> Void)? {
        get { nativeView.onInteraction }
        set { nativeView.onInteraction = newValue }
    }

    var contextMenuProvider: (() -> NSMenu?)? {
        get { nativeView.contextMenuProvider }
        set { nativeView.contextMenuProvider = newValue }
    }

    init(backend: NativePlaybackRuntime) {
        self.backend = backend
        nativeView = NativePlayerNSView(
            videoLayer: backend.presentation.video.displayLayer,
            subtitleOverlay: backend.subtitles.overlay,
            rotationDegrees: 0
        )
        nativeView.onDisplayCapabilitiesChanged = { [weak backend] capabilities in
            backend?.updateDisplay(capabilities)
        }
        nativeView.onWindowChanged = { [weak backend] in
            backend?.refreshPictureInPictureState()
        }
    }

    func updateDisplay(screen: NSScreen?) {
        guard let screen else { return }
        backend.updateDisplay(NativeDisplayCapabilities(
            name: screen.localizedName,
            backingScale: Double(nativeView.window?.backingScaleFactor ?? screen.backingScaleFactor),
            currentEDRHeadroom: screen.maximumExtendedDynamicRangeColorComponentValue,
            potentialEDRHeadroom: screen.maximumPotentialExtendedDynamicRangeColorComponentValue
        ))
    }

    func setPlaybackPhase(_ phase: PlaybackPhase) {}

    func rebindVideoLayer(_ replacement: AVSampleBufferDisplayLayer) {
        guard !isShutdown else { return }
        nativeView.rebindVideoLayer(replacement)
    }

    func setMainPresentationSuppressed(_ suppressed: Bool) {
        guard !isShutdown else { return }
        nativeView.setMainPresentationSuppressed(suppressed)
    }

    func shutdown() {
        guard !isShutdown else { return }
        isShutdown = true
        nativeView.onDisplayCapabilitiesChanged = nil
        nativeView.onWindowChanged = nil
        nativeView.onOpenURLs = nil
        nativeView.onUserActivity = nil
        nativeView.onInteraction = nil
        nativeView.contextMenuProvider = nil
        nativeView.setMainPresentationSuppressed(false)
    }
}
