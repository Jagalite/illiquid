import AppKit
import SwiftUI

@MainActor
enum PlayerWindowControls {
    private static let restoreFrames = NSMapTable<NSWindow, NSValue>.weakToStrongObjects()

    static func toggleDesktopFill(_ window: NSWindow) {
        guard !window.styleMask.contains(.fullScreen), let screen = window.screen else { return }
        let desktop = expansionFrame(in: screen.visibleFrame, for: window)
        let animate = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let frame = window.frame
        let fillsDesktop = abs(frame.minX - desktop.minX) < 1
            && abs(frame.minY - desktop.minY) < 1
            && abs(frame.width - desktop.width) < 1
            && abs(frame.height - desktop.height) < 1
        if fillsDesktop, let restore = restoreFrames.object(forKey: window) {
            restoreFrames.removeObject(forKey: window)
            window.setFrame(expansionFrame(in: restore.rectValue, for: window), display: true, animate: animate)
        } else {
            restoreFrames.setObject(NSValue(rect: frame), forKey: window)
            // Choose the largest permitted frame explicitly, rather than
            // relying on AppKit's content-dependent standard zoom size.
            window.setFrame(desktop, display: true, animate: animate)
        }
    }

    static func expansionFrame(in availableFrame: NSRect, for window: NSWindow) -> NSRect {
        let aspect = window.contentAspectRatio
        guard aspect.width.isFinite, aspect.height.isFinite,
              aspect.width > 0, aspect.height > 0 else { return availableFrame }
        let content = window.contentRect(forFrameRect: availableFrame)
        let scale = min(content.width / aspect.width, content.height / aspect.height)
        let size = window.frameRect(forContentRect: NSRect(
            origin: .zero,
            size: NSSize(width: aspect.width * scale, height: aspect.height * scale)
        )).size
        return NSRect(x: availableFrame.midX - size.width / 2,
                      y: availableFrame.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    /// Route passive title-bar space, including hosted text and its padding,
    /// without taking clicks from tabs or the native traffic lights.
    static func handleTitlebarDoubleClick(
        _ event: NSEvent,
        in window: NSWindow,
        accessory: NSView?
    ) -> Bool {
        guard event.type == .leftMouseDown, event.clickCount == 2,
              event.window === window,
              !window.styleMask.contains(.fullScreen),
              let titlebar = window.standardWindowButton(.zoomButton)?.superview,
              titlebar.convert(titlebar.bounds, to: nil).contains(event.locationInWindow)
        else { return false }

        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            if let button = window.standardWindowButton(type),
               button.convert(button.bounds, to: nil).contains(event.locationInWindow) {
                return false
            }
        }
        if let accessory, containsInteractiveRegion(accessory, at: event.locationInWindow) {
            return false
        }
        toggleDesktopFill(window)
        return true
    }

    private static func containsInteractiveRegion(_ view: NSView, at point: NSPoint) -> Bool {
        guard !view.isHidden else { return false }
        if view is TitlebarInteractiveRegionView,
           view.convert(view.bounds, to: nil).contains(point) { return true }
        return view.subviews.contains { containsInteractiveRegion($0, at: point) }
    }

    static func configure(_ window: NSWindow) {
        // These flags are mutually exclusive. SwiftUI may have initially
        // configured the window as non-fullscreen before it attaches here.
        var behavior = window.collectionBehavior
        behavior.subtract([.fullScreenNone, .fullScreenAuxiliary])
        behavior.insert(.fullScreenPrimary)
        window.collectionBehavior = behavior
    }
}

/// Geometry only: SwiftUI controls above this view still receive every click.
struct TitlebarInteractiveRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> TitlebarInteractiveRegionView {
        TitlebarInteractiveRegionView()
    }
    func updateNSView(_ view: TitlebarInteractiveRegionView, context: Context) {}
}

final class TitlebarInteractiveRegionView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
