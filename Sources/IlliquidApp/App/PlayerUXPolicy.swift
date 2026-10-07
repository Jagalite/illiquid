import AppKit
import SwiftUI

/// Restores the whole window onto the available display with the greatest overlap.
enum PlayerWindowGeometry {
    static func restoredFrame(_ frame: CGRect, screens: [CGRect]) -> CGRect? {
        guard [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite),
              frame.width >= 720, frame.height >= 440, !screens.isEmpty else { return nil }
        let usable = screens.filter { $0.width > 0 && $0.height > 0 }
        guard let screen = usable.max(by: { intersectionArea(frame, $0) < intersectionArea(frame, $1) }) else { return nil }
        let size = CGSize(width: min(frame.width, screen.width), height: min(frame.height, screen.height))
        return CGRect(x: min(max(frame.minX, screen.minX), screen.maxX - size.width),
                      y: min(max(frame.minY, screen.minY), screen.maxY - size.height),
                      width: size.width, height: size.height)
    }

    private static func intersectionArea(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let intersection = a.intersection(b)
        return intersection.isNull ? 0 : intersection.width * intersection.height
    }
}

/// A scrub owns the source revision it started on, even for reloads of one URL.
struct TimelineGestureTransaction {
    let sourceRevision: UInt64
    let origin: TimeInterval
    let duration: TimeInterval
    var lastTarget: TimeInterval?

    mutating func preview(fraction: CGFloat, currentRevision: UInt64) -> TimeInterval? {
        guard currentRevision == sourceRevision, fraction.isFinite, duration.isFinite, duration > 0 else { return nil }
        let target = min(max(Double(fraction), 0), 1) * duration
        lastTarget = target
        return target
    }

    func finish(currentRevision: UInt64, cancelled: Bool) -> TimeInterval? {
        guard currentRevision == sourceRevision, lastTarget != nil else { return nil }
        return cancelled ? origin : lastTarget
    }
}

private struct PlaybackFocusVisibility: ViewModifier {
    let model: AppModel
    @FocusState private var focused: Bool
    @State private var owner = UUID().uuidString

    func body(content: Content) -> some View {
        content.focused($focused)
            .onChange(of: focused) { _, active in model.setPlaybackFocus(active, owner: owner) }
            .onDisappear { model.setPlaybackFocus(false, owner: owner) }
    }
}

extension View {
    func playbackFocusVisibility(_ model: AppModel) -> some View {
        modifier(PlaybackFocusVisibility(model: model))
    }
}

/// A dismissal click belongs to this popover, never to transport underneath it.
struct PopoverDismissalBoundary: NSViewRepresentable {
    let dismiss: () -> Void
    func makeNSView(context: Context) -> BoundaryView {
        let view = BoundaryView()
        view.dismiss = dismiss
        return view
    }
    func updateNSView(_ view: BoundaryView, context: Context) { view.dismiss = dismiss }
    static func dismantleNSView(_ view: BoundaryView, coordinator: ()) { view.removeMonitor() }

    final class BoundaryView: NSView {
        var dismiss: (() -> Void)?
        private var monitor: Any?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitor()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) { [weak self] event in
                guard let self, let window else { return event }
                let escape = event.type == .keyDown && event.keyCode == 53
                if escape || (event.type != .keyDown && event.window !== window) {
                    removeMonitor()
                    dismiss?()
                    return nil
                }
                return event
            }
        }
        func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
        deinit { MainActor.assumeIsolated { removeMonitor() } }
    }
}
