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
    private var resolutionScheduled = false

    init(onResolve: @escaping @MainActor (NSWindow) -> Void) {
        self.onResolve = onResolve
        super.init(frame: .zero)
        scheduleResolution()
    }

    required init?(coder: NSCoder) { nil }

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
            resolvedWindow = window
            onResolve(window)
        }
    }
}
