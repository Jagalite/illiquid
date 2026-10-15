import AppKit
import IlliquidCore

/// Owns only thumbnail eligibility. It never pauses playback, exits PiP, or
/// clears cached previews. Application activation is deliberately not a gate.
@MainActor
final class ThumbnailWindowObservation: NSObject {
    private weak var window: NSWindow?
    private let applicationHidden: @MainActor () -> Bool
    private let didChange: @MainActor () -> Void
    private var closed = false
    private(set) var isVisible: Bool

    init(window: NSWindow,
         applicationHidden: @escaping @MainActor () -> Bool = { NSApp.isHidden },
         didChange: @escaping @MainActor () -> Void) {
        self.window = window
        self.applicationHidden = applicationHidden
        self.didChange = didChange
        isVisible = Self.visibility(window, applicationHidden: applicationHidden())
        super.init()
        let center = NotificationCenter.default
        for name in [NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
                     NSWindow.didChangeOcclusionStateNotification, NSWindow.didBecomeKeyNotification] {
            center.addObserver(self, selector: #selector(visibilityChanged(_:)), name: name, object: window)
        }
        center.addObserver(self, selector: #selector(windowWillClose(_:)),
                           name: NSWindow.willCloseNotification, object: window)
        for name in [NSApplication.didHideNotification, NSApplication.didUnhideNotification,
                     NSApplication.didBecomeActiveNotification] {
            center.addObserver(self, selector: #selector(visibilityChanged(_:)), name: name, object: nil)
        }
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    func stop() { NotificationCenter.default.removeObserver(self) }

    @objc private func windowWillClose(_ notification: Notification) {
        closed = true
        refresh()
    }

    @objc private func visibilityChanged(_ notification: Notification) { refresh() }

    private func refresh() {
        let visible = !closed && Self.visibility(window, applicationHidden: applicationHidden())
        guard visible != isVisible else { return }
        isVisible = visible
        didChange()
    }

    private static func visibility(_ window: NSWindow?, applicationHidden: Bool) -> Bool {
        ThumbnailVisibilityPolicy.isVisible(hasWindow: window != nil,
            isApplicationHidden: applicationHidden, isWindowVisible: window?.isVisible == true,
            isMiniaturized: window?.isMiniaturized == true,
            isOccluded: window?.occlusionState.contains(.visible) != true)
    }
}
