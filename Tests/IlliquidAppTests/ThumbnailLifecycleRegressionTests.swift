import AppKit
import Foundation
import Testing
import IlliquidCore
import IlliquidPlayer
@testable import IlliquidApp

/// Notification wiring tests use an NSWindow with controlled visibility rather
/// than hiding the test runner or depending on a window server's occlusion timing.
@MainActor
private final class ThumbnailVisibilityTestWindow: NSWindow {
    var testApplicationHidden = false
    var testVisible = true
    var testMiniaturized = false
    var testOccluded = false
    override var isVisible: Bool { testVisible }
    override var isMiniaturized: Bool { testMiniaturized }
    override var occlusionState: NSWindow.OcclusionState { testOccluded ? [] : [.visible] }
}

@Suite("Thumbnail lifecycle regressions", .serialized)
@MainActor
struct ThumbnailLifecycleRegressionTests {
    private func window() -> ThumbnailVisibilityTestWindow {
        _ = NSApplication.shared
        let window = ThumbnailVisibilityTestWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    private func eventually(_ predicate: @MainActor () -> Bool) async throws {
        for _ in 0..<350 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(predicate(), "Expected scheduler progress within seven seconds")
    }

    private func withPlayer(_ body: @MainActor (PlaybackController, UserDefaults) async throws -> Void) async throws {
        let suite = "ThumbnailLifecycleRegression-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let player = PlaybackController(persistence: PlaybackPersistenceStore(userDefaults: defaults),
            sessionStore: AtomicPlaybackSessionStore(fileURL: root.appendingPathComponent("session.json")),
            thumbnailCacheDirectory: nil)
        do { try await body(player, defaults) }
        catch { await player.shutdown(); throw error }
        await player.shutdown()
    }

    @Test func visibilityNotificationsCoverMinimizeHideOcclusionAndClose() {
        let window = window()
        defer { window.close() }
        var changes = 0
        let observation = ThumbnailWindowObservation(window: window, applicationHidden: { window.testApplicationHidden }) { changes += 1 }
        defer { observation.stop() }
        let center = NotificationCenter.default
        #expect(observation.isVisible)

        window.testMiniaturized = true
        center.post(name: NSWindow.didMiniaturizeNotification, object: window)
        #expect(!observation.isVisible && changes == 1)
        center.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        #expect(changes == 1) // duplicate notifications must not reset the idle timer
        window.testMiniaturized = false
        center.post(name: NSWindow.didDeminiaturizeNotification, object: window)
        #expect(observation.isVisible && changes == 2)

        window.testApplicationHidden = true
        center.post(name: NSApplication.didHideNotification, object: NSApplication.shared)
        #expect(!observation.isVisible && changes == 3)
        window.testApplicationHidden = false
        center.post(name: NSApplication.didUnhideNotification, object: NSApplication.shared)
        #expect(observation.isVisible && changes == 4)

        window.testOccluded = true
        center.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        #expect(!observation.isVisible && changes == 5)
        window.testOccluded = false
        center.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        #expect(observation.isVisible && changes == 6)
        window.testVisible = false
        center.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        #expect(!observation.isVisible && changes == 7)
        window.testVisible = true
        center.post(name: NSWindow.didBecomeKeyNotification, object: window)
        #expect(observation.isVisible && changes == 8)

        center.post(name: NSWindow.willCloseNotification, object: window)
        #expect(!observation.isVisible && changes == 9)
        center.post(name: NSApplication.didBecomeActiveNotification, object: NSApplication.shared)
        #expect(!observation.isVisible && changes == 9)
        observation.stop()
        // WindowAccessor rebinds even when SwiftUI reuses the same NSWindow.
        let reopened = ThumbnailWindowObservation(window: window, applicationHidden: { false }) {}
        defer { reopened.stop() }
        #expect(reopened.isVisible)
    }

    @Test func stoppedObservationIgnoresLaterNotifications() {
        let window = window()
        defer { window.close() }
        var changes = 0
        let observation = ThumbnailWindowObservation(window: window, applicationHidden: { false }) { changes += 1 }
        observation.stop()
        window.testMiniaturized = true
        NotificationCenter.default.post(name: NSWindow.didMiniaturizeNotification, object: window)
        #expect(changes == 0)
    }

    @Test func minimizeAloneCancelsAndRestoreAloneResumesScheduling() async throws {
        try await withPlayer { player, defaults in
            let window = window()
            defer { window.close() }
            var calls = 0
            var cancellations = 0
            let scheduler = ThumbnailBackgroundScheduler(player: player, defaults: defaults,
                readDuration: { _ in 120 }, generate: { _, _ in
                    calls += 1
                    do { try await Task.sleep(for: .seconds(30)) }
                    catch { cancellations += 1 }
                    return !Task.isCancelled
                })
            defer { scheduler.shutdown() }
            scheduler.preferences.idleSeconds = 1
            scheduler.observeVisibility(of: window)
            scheduler.updatePlayback(current: URL(fileURLWithPath: "/media/current.mkv"),
                idle: false, windowVisible: true, playing: true)
            try await eventually { calls == 1 }
            window.testMiniaturized = true
            NotificationCenter.default.post(name: NSWindow.didMiniaturizeNotification, object: window)
            try await eventually { cancellations == 1 }
            try await Task.sleep(for: .milliseconds(1200))
            #expect(calls == 1)
            // No playback update or manual scheduling refresh between these events.
            window.testMiniaturized = false
            NotificationCenter.default.post(name: NSWindow.didDeminiaturizeNotification, object: window)
            try await eventually { calls == 2 }
            #expect(player.viewStore.phase == .idle) // scheduler never opens/stops media
        }
    }

    @Test func hiddenWorkRequiresExplicitOptInAndIdlePlayback() async throws {
        try await withPlayer { player, defaults in
            let window = window()
            window.testOccluded = true
            defer { window.close() }
            var calls = 0
            let scheduler = ThumbnailBackgroundScheduler(player: player, defaults: defaults,
                readDuration: { _ in 120 }, generate: { _, _ in calls += 1; return true })
            defer { scheduler.shutdown() }
            var settings = ThumbnailPreferences()
            settings.idleSeconds = 1
            settings.samplesPerVideo = 1
            settings.preparesCurrentVideo = false
            settings.generatesInBackground = true
            scheduler.preferences = settings
            scheduler.observeVisibility(of: window)
            scheduler.updatePlayback(current: URL(fileURLWithPath: "/media/current.mkv"), idle: true, windowVisible: true)
            try await Task.sleep(for: .milliseconds(1200))
            #expect(calls == 0)
            scheduler.preferences.generatesWithWindowClosed = true
            try await eventually { calls > 0 }
            scheduler.preferences.preparesCurrentVideo = true
            scheduler.updatePlayback(current: URL(fileURLWithPath: "/media/current.mkv"),
                idle: false, windowVisible: true, playing: true)
            let before = calls
            try await Task.sleep(for: .milliseconds(1200))
            #expect(calls == before) // includes hidden playback in PiP; no forced pause
        }
    }

    @Test(arguments: [false, true], [false, true])
    func slowLeaderCannotRestartAheadOfLaterFiles(automaticCurrent: Bool, slowProbe: Bool) async throws {
        try await withPlayer { player, defaults in
            let slow = URL(fileURLWithPath: "/media/a-slow.mkv")
            let later = URL(fileURLWithPath: "/media/b-later.mkv")
            let beyondOriginalBatch = URL(fileURLWithPath: "/media/c-later.mkv")
            var probes: [URL] = []
            var generated: [URL] = []
            var cancelled = false
            let scheduler = ThumbnailBackgroundScheduler(player: player, defaults: defaults,
                readDuration: { url in
                    probes.append(url)
                    if url == slow && slowProbe {
                        do { try await Task.sleep(for: .seconds(30)) }
                        catch { cancelled = true }
                        return nil
                    }
                    return 120
                }, generate: { url, _ in
                    if url == slow && !slowProbe {
                        do { try await Task.sleep(for: .seconds(30)) }
                        catch { cancelled = true }
                        return false
                    }
                    generated.append(url)
                    return true
                })
            defer { scheduler.shutdown() }
            var settings = ThumbnailPreferences()
            settings.preparesCurrentVideo = automaticCurrent
            settings.generatesInBackground = true
            settings.idleSeconds = 1
            settings.workSeconds = 1
            settings.videosPerPass = 2
            settings.samplesPerVideo = 1
            scheduler.preferences = settings
            scheduler.navigate(folder: slow.deletingLastPathComponent(), discovered: [slow, later, beyondOriginalBatch])
            scheduler.updatePlayback(current: slow, idle: true, windowVisible: true)
            try await eventually { generated.contains(later) && generated.contains(beyondOriginalBatch) }
            #expect(cancelled)
            #expect(Array(probes.prefix(3)) == [slow, later, beyondOriginalBatch])
            #expect(player.viewStore.currentURL == nil)
        }
    }
}
