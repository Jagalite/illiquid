import AppKit
import Foundation
import SuperplayrCore
import SuperplayrPlayer

/// Owns macOS power and workspace notifications for one playback session.
@MainActor
final class PlaybackSystemCoordinator {
    private unowned let player: PlaybackController
    private var observers: [NSObjectProtocol] = []
    private var activity: NSObjectProtocol?

    init(player: PlaybackController) {
        self.player = player
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        observers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.player.systemWillSleep() }
        })
        observers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.player.systemDidWake() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.player.refreshDisplayPolicy() }
        })
    }

    func update(for phase: PlaybackPhase) {
        let shouldPreventIdleSleep: Bool = switch phase {
        case .loading, .playing, .buffering: true
        case .idle, .preparing, .paused, .stopping, .failed, .shuttingDown: false
        }

        if shouldPreventIdleSleep, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled, .idleDisplaySleepDisabled],
                reason: "Playing media"
            ) as NSObjectProtocol
        } else if !shouldPreventIdleSleep, let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }

    func invalidate() {
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }

    deinit {
        MainActor.assumeIsolated { invalidate() }
    }
}
