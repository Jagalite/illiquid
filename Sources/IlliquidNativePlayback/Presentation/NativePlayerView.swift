import AppKit
import AVFoundation
import IlliquidPlayback
import IlliquidCore
import SwiftUI

struct NativeDisplayCapabilities: Equatable, Sendable {
    let name: String
    let backingScale: Double
    let currentEDRHeadroom: Double
    let potentialEDRHeadroom: Double

    var isExtendedDynamicRangeAvailable: Bool { potentialEDRHeadroom > 1.0 }
}

final class NativePlayerNSView: NSView {
    static let pointerTrackingOptions: NSTrackingArea.Options = [
        .mouseEnteredAndExited,
        .mouseMoved,
        .activeAlways,
        .inVisibleRect,
    ]

    override var acceptsFirstResponder: Bool { true }

    private let videoClipLayer = CALayer()
    var videoAdjustments = VideoAdjustmentState.standard { didSet { needsLayout = true } }
    var sourceDisplaySize = CGSize.zero { didSet { needsLayout = true } }
    private(set) var videoLayer: AVSampleBufferDisplayLayer
    let subtitleOverlay: SubtitleOverlayView
    var rotationDegrees: Double {
        didSet { needsLayout = true }
    }
    var isHorizontallyMirrored = false {
        didSet { needsLayout = true }
    }
    var pictureInPictureViewportSize: CGSize? {
        didSet { needsLayout = true }
    }
    private(set) var isMainPresentationSuppressed = false
    var onDisplayCapabilitiesChanged: ((NativeDisplayCapabilities) -> Void)?
    var onWindowChanged: (() -> Void)?
    var onOpenURLs: (([URL], PlaylistOpenMode) -> Void)?
    var onUserActivity: (() -> Void)?
    var onInteraction: ((PlaybackSurfaceInteraction) -> Void)?
    var isVoiceOverEnabled: () -> Bool = { NSWorkspace.shared.isVoiceOverEnabled }
    var contextMenuProvider: (() -> NSMenu?)?
    private var lastProfiledGeometry: String?
    private var pointerTrackingArea: NSTrackingArea?

    init(
        videoLayer: AVSampleBufferDisplayLayer,
        subtitleOverlay: SubtitleOverlayView,
        rotationDegrees: Double
    ) {
        self.videoLayer = videoLayer
        self.subtitleOverlay = subtitleOverlay
        self.rotationDegrees = rotationDegrees
        super.init(frame: .zero)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true
        videoClipLayer.masksToBounds = true
        layer?.addSublayer(videoClipLayer)
        videoClipLayer.addSublayer(videoLayer)
        addSubview(subtitleOverlay)
        registerForDraggedTypes([.fileURL])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Video")
        setAccessibilityHelp("Double-click the left or right third to seek backward or forward 5 seconds. Double-click the center to toggle fullscreen. Show the menu for more playback actions.")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        let presentationBounds = effectivePresentationBounds
        let normalizedRotation = rotationDegrees.truncatingRemainder(dividingBy: 360)
        let quarterTurn = abs(abs(normalizedRotation.truncatingRemainder(dividingBy: 180)) - 90) < 1
        videoLayer.contentsScale = pictureInPictureViewportSize == nil
            ? (window?.backingScaleFactor ?? 2)
            : 1
        let geometry = VideoPresentationGeometry(sourceSize: sourceDisplaySize,
            bounds: presentationBounds, adjustments: videoAdjustments)
        let usesGeometry = pictureInPictureViewportSize == nil && sourceDisplaySize.width > 0
        let imageRect = usesGeometry ? geometry.imageRect : presentationBounds
        let clipRect = usesGeometry ? geometry.clipRect : presentationBounds
        let sourceLayerSize = Self.sourceLayerSize(
            presentationSize: imageRect.size,
            pictureInPictureViewportSize: pictureInPictureViewportSize,
            quarterTurn: quarterTurn
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoClipLayer.frame = clipRect
        videoLayer.videoGravity = usesGeometry ? .resize : .resizeAspect
        videoLayer.bounds = CGRect(
            origin: .zero,
            size: sourceLayerSize
        )
        videoLayer.position = CGPoint(
            x: imageRect.midX - clipRect.minX,
            y: imageRect.midY - clipRect.minY
        )
        var transform = CGAffineTransform(
            rotationAngle: CGFloat(normalizedRotation * .pi / 180)
        )
        if isHorizontallyMirrored {
            transform = transform.scaledBy(x: -1, y: 1)
        }
        videoLayer.setAffineTransform(transform)
        CATransaction.commit()
        subtitleOverlay.frame = clipRect
        subtitleOverlay.updateDrawableSize(
            backingScale: window?.backingScaleFactor ?? 2
        )
        if ProcessInfo.processInfo.environment["ILLIQUID_ASS_PROFILE"] == "1" {
            let windowFrame = window?.frame ?? .zero
            let contentBounds = window?.contentView?.bounds ?? .zero
            let contentBackingBounds = window?.contentView?.convertToBacking(
                contentBounds
            ) ?? .zero
            let contentLayout = window?.contentLayoutRect ?? .zero
            let screenFrame = window?.screen?.frame ?? .zero
            let geometry = [
                "view-bounds=\(Self.sizeDescription(bounds.size))",
                "view-frame=\(Self.sizeDescription(frame.size))",
                "view-visible=\(Self.sizeDescription(visibleRect.size))",
                "window-frame=\(Self.sizeDescription(windowFrame.size))",
                "content-bounds=\(Self.sizeDescription(contentBounds.size))",
                "content-backing=\(Self.sizeDescription(contentBackingBounds.size))",
                "content-layout=\(Self.sizeDescription(contentLayout.size))",
                "screen-frame=\(Self.sizeDescription(screenFrame.size))",
                "backing-scale=\(window?.backingScaleFactor ?? 0)",
                "video-bounds=\(Self.sizeDescription(videoLayer.bounds.size))",
                "overlay-bounds=\(Self.sizeDescription(subtitleOverlay.bounds.size))",
                "metal-drawable=\(Self.sizeDescription(subtitleOverlay.metalBackingPixelSize))",
            ].joined(separator: " ")
            if geometry != lastProfiledGeometry {
                lastProfiledGeometry = geometry
                FileHandle.standardError.write(Data(
                    "[ass-profile-surface] \(geometry)\n".utf8
                ))
            }
        }
    }

    private static func sizeDescription(_ size: CGSize) -> String {
        "\(Int(size.width.rounded()))x\(Int(size.height.rounded()))"
    }

    var effectivePresentationBounds: CGRect {
        Self.resolvePresentationBounds(
            viewBounds: bounds,
            visibleRect: visibleRect,
            isAttachedToWindow: window != nil
        )
    }

    static func resolvePresentationBounds(
        viewBounds: CGRect,
        visibleRect: CGRect,
        isAttachedToWindow: Bool
    ) -> CGRect {
        guard isAttachedToWindow,
              visibleRect.origin.x.isFinite,
              visibleRect.origin.y.isFinite,
              visibleRect.width.isFinite,
              visibleRect.height.isFinite,
              visibleRect.width > 0,
              visibleRect.height > 0
        else {
            return viewBounds
        }

        let clippedVisibleRect = viewBounds.intersection(visibleRect)
        guard !clippedVisibleRect.isNull, !clippedVisibleRect.isEmpty else {
            return viewBounds
        }
        return clippedVisibleRect
    }

    nonisolated static func sourceLayerSize(
        presentationSize: CGSize,
        pictureInPictureViewportSize: CGSize?,
        quarterTurn: Bool
    ) -> CGSize {
        let unrotatedSize: CGSize
        if let viewportSize = pictureInPictureViewportSize,
           viewportSize.width.isFinite,
           viewportSize.height.isFinite,
           viewportSize.width > 0,
           viewportSize.height > 0
        {
            // macOS 26's sample-buffer PiP host mirrors source pixels at 1:1
            // with a contents scale of 1. Match the actual PiP viewport and
            // use the same scale while PiP is active so the whole frame fits.
            unrotatedSize = viewportSize
        } else {
            unrotatedSize = presentationSize
        }

        guard quarterTurn else { return unrotatedSize }
        return CGSize(width: unrotatedSize.height, height: unrotatedSize.width)
    }

    func rebindVideoLayer(_ replacement: AVSampleBufferDisplayLayer) {
        guard replacement !== videoLayer else { return }
        videoLayer.removeFromSuperlayer()
        videoLayer = replacement
        videoClipLayer.insertSublayer(replacement, at: 0)
        updateMainPresentationVisibility()
        updateDisplayConfiguration()
        needsLayout = true
    }

    func setMainPresentationSuppressed(_ suppressed: Bool) {
        guard isMainPresentationSuppressed != suppressed else { return }
        isMainPresentationSuppressed = suppressed
        updateMainPresentationVisibility()
    }

    private func updateMainPresentationVisibility() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoLayer.isHidden = isMainPresentationSuppressed
        CATransaction.commit()
        // Keep the subtitle pipeline rendering independently while PiP owns
        // the visible presentation. Alpha avoids competing with the
        // pipeline's own track Off/On `isHidden` state.
        subtitleOverlay.alphaValue = isMainPresentationSuppressed ? 0 : 1
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        pendingSurfaceClick?.cancel()
        pendingSurfaceClick = nil
        surfacePressOrigin = nil
        updateDisplayConfiguration()
        DispatchQueue.main.async { [weak self] in
            self?.onWindowChanged?()
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDisplayConfiguration()
        subtitleOverlay.needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTrackingArea {
            removeTrackingArea(pointerTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: Self.pointerTrackingOptions,
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        pointerTrackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        onInteraction?(.pointerEntered)
        super.mouseEntered(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        onInteraction?(.pointerMoved(event.locationInWindow))
        super.mouseMoved(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        onInteraction?(.pointerExited(event.locationInWindow))
        super.mouseExited(with: event)
    }

    private var surfacePressOrigin: NSPoint?
    private var pendingSurfaceClick: Task<Void, Never>?
    override func mouseDown(with event: NSEvent) {
        pendingSurfaceClick?.cancel()
        pendingSurfaceClick = nil
        window?.makeFirstResponder(self)
        surfacePressOrigin = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        if let origin = surfacePressOrigin,
           hypot(event.locationInWindow.x - origin.x, event.locationInWindow.y - origin.y) > 4 {
            surfacePressOrigin = nil
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer { surfacePressOrigin = nil }
        guard let origin = surfacePressOrigin,
              hypot(event.locationInWindow.x - origin.x, event.locationInWindow.y - origin.y) <= 4,
              bounds.contains(convert(event.locationInWindow, from: nil)), window?.isKeyWindow == true else { return }
        let location = convert(event.locationInWindow, from: nil)
        if event.clickCount >= 2 {
            let fraction = (location.x - bounds.minX) / bounds.width
            if fraction < 1.0 / 3.0 {
                onInteraction?(.doubleClickSeek(-5))
            } else if fraction > 2.0 / 3.0 {
                onInteraction?(.doubleClickSeek(5))
            } else if event.clickCount == 2 {
                onInteraction?(.doubleClick)
            }
        } else if event.clickCount == 1 {
            // Wait for a possible second tap so seeking does not first toggle
            // the controls. Match the user's macOS double-click speed setting.
            pendingSurfaceClick = Task { @MainActor [weak self, weak clickWindow = window] in
                do {
                    try await Task.sleep(for: .seconds(NSEvent.doubleClickInterval))
                } catch {
                    return
                }
                guard let self, let clickWindow,
                      self.window === clickWindow, clickWindow.isKeyWindow,
                      clickWindow.firstResponder === self,
                      clickWindow.attachedSheet == nil else { return }
                self.pendingSurfaceClick = nil
                self.onInteraction?(.primaryClick)
            }
        }
    }

    override func keyDown(with event: NSEvent) {
        pendingSurfaceClick?.cancel()
        pendingSurfaceClick = nil
        guard !isVoiceOverEnabled() else {
            super.keyDown(with: event)
            return
        }
        var modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        modifiers.subtract([.capsLock, .function, .numericPad])
        if event.keyCode == 49, modifiers.isEmpty, !event.isARepeat {
            onInteraction?(.togglePause)
            return
        }
        if event.keyCode == 123, modifiers.isEmpty {
            onInteraction?(.seekRelative(-5))
            return
        }
        if event.keyCode == 124, modifiers.isEmpty {
            onInteraction?(.seekRelative(5))
            return
        }
        if event.keyCode == 123, modifiers == .shift {
            onInteraction?(.seekRelative(-1))
            return
        }
        if event.keyCode == 124, modifiers == .shift {
            onInteraction?(.seekRelative(1))
            return
        }
        super.keyDown(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        pendingSurfaceClick?.cancel()
        pendingSurfaceClick = nil
        onUserActivity?()
        super.rightMouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        contextMenuProvider?()
    }

    override func otherMouseDown(with event: NSEvent) {
        pendingSurfaceClick?.cancel()
        pendingSurfaceClick = nil
        onUserActivity?()
        onInteraction?(.auxiliaryButton(event.buttonNumber))
    }

    override func scrollWheel(with event: NSEvent) {
        pendingSurfaceClick?.cancel()
        pendingSurfaceClick = nil
        onUserActivity?()
        onInteraction?(.scroll(PlaybackSurfaceScroll(
            deltaX: event.scrollingDeltaX,
            deltaY: event.scrollingDeltaY,
            isPrecise: event.hasPreciseScrollingDeltas,
            phase: Self.scrollPhase(for: event)
        )))
    }

    override func accessibilityPerformShowMenu() -> Bool {
        guard let menu = contextMenuProvider?() else { return false }
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: bounds.midX, y: bounds.midY),
            in: self
        )
        return true
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggedFileURLs(from: sender).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = draggedFileURLs(from: sender)
        guard !urls.isEmpty else { return false }
        let mode: PlaylistOpenMode = NSEvent.modifierFlags.contains(.option)
            ? .append
            : .replace
        onOpenURLs?(urls, mode)
        return true
    }

    private func updateDisplayConfiguration() {
        let scale = window?.backingScaleFactor ?? 2
        videoLayer.contentsScale = pictureInPictureViewportSize == nil ? scale : 1
        videoLayer.preferredDynamicRange = .automatic
        subtitleOverlay.updateDrawableSize(backingScale: scale)
        guard let screen = window?.screen else { return }
        let capabilities = NativeDisplayCapabilities(
            name: screen.localizedName,
            backingScale: scale,
            currentEDRHeadroom: screen.maximumExtendedDynamicRangeColorComponentValue,
            potentialEDRHeadroom: screen.maximumPotentialExtendedDynamicRangeColorComponentValue
        )
        DispatchQueue.main.async { [weak self] in
            self?.onDisplayCapabilitiesChanged?(capabilities)
        }
    }

    private func draggedFileURLs(from sender: NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
        ]
        return (sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: options
        ) as? [URL]) ?? []
    }

    private static func scrollPhase(for event: NSEvent) -> PlaybackSurfaceScrollPhase {
        if event.momentumPhase != [] {
            if event.momentumPhase.contains(.cancelled) { return .cancelled }
            return event.momentumPhase.contains(.ended) ? .momentumEnded : .momentum
        }
        if event.phase.contains(.began) { return .began }
        if event.phase.contains(.ended) { return .ended }
        if event.phase.contains(.cancelled) { return .cancelled }
        if event.phase.contains(.changed) { return .changed }
        return .discrete
    }
}

struct NativePlayerView: NSViewRepresentable {
    let videoLayer: AVSampleBufferDisplayLayer
    let subtitleOverlay: SubtitleOverlayView
    let rotationDegrees: Double
    let onDisplayCapabilitiesChanged: (NativeDisplayCapabilities) -> Void

    func makeNSView(context: Context) -> NativePlayerNSView {
        let view = NativePlayerNSView(
            videoLayer: videoLayer,
            subtitleOverlay: subtitleOverlay,
            rotationDegrees: rotationDegrees
        )
        view.onDisplayCapabilitiesChanged = onDisplayCapabilitiesChanged
        return view
    }

    func updateNSView(_ nsView: NativePlayerNSView, context: Context) {
        nsView.rotationDegrees = rotationDegrees
        nsView.onDisplayCapabilitiesChanged = onDisplayCapabilitiesChanged
        nsView.needsLayout = true
    }
}
