import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var terminationIsComplete = false
    private var delayedQuitTask: Task<Void, Never>?
    private var quittingPanel: NSPanel?
    private var terminationIsInProgress = false
    private var activatesStandaloneLaunch = false
    private let shutdown: @MainActor () async -> String?
    private let presentSaveFailure: @MainActor (String) -> Void

    // SwiftUI creates the delegate through NSObject's zero-argument initializer.
    // Default arguments on the injectable Swift initializer do not implement it.
    override convenience init() {
        self.init(shutdown: { await AppModel.shutdownShared() })
    }

    init(
        shutdown: @escaping @MainActor () async -> String?,
        presentSaveFailure: @escaping @MainActor (String) -> Void = AppDelegate.showSaveFailure
    ) {
        self.shutdown = shutdown
        self.presentSaveFailure = presentSaveFailure
        super.init()
    }

    private static func showSaveFailure(_ details: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Playback progress could not be saved"
        alert.informativeText = "Your latest playback position may not be available next time you open Illiquid.\n\n\(details)"
        alert.addButton(withTitle: "Quit")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // A SwiftPM executable has no app bundle to give it a regular launch
        // policy. Without this it can display a window but cannot become the
        // active application, so native cursors and window controls misbehave.
        let application = NSApplication.shared
        if application.activationPolicy() == .prohibited {
            activatesStandaloneLaunch = application.setActivationPolicy(.regular)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard activatesStandaloneLaunch else { return }
        NSApplication.shared.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !AppModel.keepsPlayingInPictureInPicture
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        AppModel.handleStartupOpenURLs(urls)
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        Task { await AppModel.loadShared()?.reopenPlayerWindow() }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminationIsComplete {
            return .terminateNow
        }
        guard !terminationIsInProgress else {
            return .terminateLater
        }

        terminationIsInProgress = true
        delayedQuitTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            guard let self, !terminationIsComplete else { return }
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 130),
                styleMask: [.titled], backing: .buffered, defer: false)
            panel.title = "Quitting Illiquid"
            let label = NSTextField(wrappingLabelWithString: "Finishing playback and saving progress…\n\nIf macOS reports the app as unresponsive, Force Quit is available in the Apple menu. Unsaved progress may be lost.")
            label.frame = NSRect(x: 20, y: 15, width: 380, height: 95)
            panel.contentView?.addSubview(label)
            panel.center()
            panel.makeKeyAndOrderFront(nil)
            quittingPanel = panel
        }
        Task {
            await finishTermination {
                sender.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }

    func finishTermination(reply: () -> Void) async {
        let failure = await shutdown()
        delayedQuitTask?.cancel()
        delayedQuitTask = nil
        quittingPanel?.close()
        quittingPanel = nil
        if let failure {
            // Playback is already stopped. Keep the termination reply pending
            // until the user has acknowledged the failed final save.
            presentSaveFailure(failure)
        }
        terminationIsComplete = true
        reply()
    }
}
