import AppKit
import SwiftUI

struct WindowAccessor: NSViewRepresentable {
    let onResolve: @MainActor (NSWindow) -> Void

    func makeNSView(context: Context) -> WindowResolverView {
        WindowResolverView(onResolve: onResolve)
    }

    func updateNSView(_ nsView: WindowResolverView, context: Context) {
        nsView.onResolve = onResolve
        nsView.scheduleResolution()
    }
}

/// SwiftUI may attach a representable after its first deferred update. Observe
/// attachment itself so startup file opens cannot wait forever for configuration.
@MainActor
final class WindowResolverView: NSView {
    var onResolve: @MainActor (NSWindow) -> Void
    private weak var resolvedWindow: NSWindow?
    private weak var closedWindow: NSWindow?
    private var resolutionScheduled = false

    init(onResolve: @escaping @MainActor (NSWindow) -> Void) {
        self.onResolve = onResolve
        super.init(frame: .zero)
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(windowWillClose(_:)),
                           name: NSWindow.willCloseNotification, object: nil)
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didChangeOcclusionStateNotification] {
            center.addObserver(self, selector: #selector(windowVisibilityChanged(_:)),
                               name: name, object: nil)
        }
        scheduleResolution()
    }

    required init?(coder: NSCoder) { nil }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === window else { return }
        closedWindow = closing
        resolvedWindow = nil
    }

    @objc private func windowVisibilityChanged(_ notification: Notification) {
        guard let changed = notification.object as? NSWindow, changed === window else { return }
        scheduleResolution()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { resolvedWindow = nil }
        scheduleResolution()
    }

    func scheduleResolution() {
        guard !resolutionScheduled else { return }
        resolutionScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            resolutionScheduled = false
            guard let window, resolvedWindow !== window else { return }
            // SwiftUI can reopen the same NSWindow with its representable still
            // attached. Resolve it again, but never reconfigure a closed window
            // merely because an unrelated SwiftUI update arrived while hidden.
            guard window !== closedWindow || window.isVisible else { return }
            closedWindow = nil
            resolvedWindow = window
            onResolve(window)
        }
    }
}
