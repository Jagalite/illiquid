import Foundation
import Testing
import SuperplayrCore
import SuperplayrPlayer
import AppKit
import SwiftUI
@testable import SuperplayrApp

@Suite("Background thumbnail scheduling", .serialized)
@MainActor
struct ThumbnailBackgroundSchedulerTests {
    @Test func nativeIdlePassPreparesDiscoveredVideosWithoutStartingPlayback() async throws {
        guard let raw = ProcessInfo.processInfo.environment["ILLIQUID_THUMBNAIL_IDLE_FIXTURES"] else { return }
        let folder = URL(fileURLWithPath: raw, isDirectory: true)
        let suite = "ThumbnailIdle-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { try? FileManager.default.removeItem(at: root) }
        let player = PlaybackController(persistence: PlaybackPersistenceStore(userDefaults: defaults),
            sessionStore: AtomicPlaybackSessionStore(fileURL: root.appendingPathComponent("session.json")),
            thumbnailCacheDirectory: root.appendingPathComponent("thumbnails"))
        let scheduler = ThumbnailBackgroundScheduler(player: player, defaults: defaults)
        defer { scheduler.shutdown() }
        var settings = ThumbnailPreferences()
        settings.generatesInBackground = true; settings.idleSeconds = 1
        settings.videosPerPass = 2; settings.samplesPerVideo = 3
        scheduler.preferences = settings
        scheduler.updatePlayback(current: nil, idle: true, windowVisible: true)
        scheduler.navigate(folder: folder, discovered: ["h264-aac.mp4", "hevc-10bit-aac.mkv"].map { folder.appendingPathComponent($0) })
        for _ in 0..<500 where !scheduler.status.hasPrefix("Prepared") {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(scheduler.status == "Prepared 6 previews across 2 videos.")
        #expect(player.viewStore.phase == .idle && player.viewStore.currentURL == nil)
        scheduler.shutdown()
        await player.shutdown()
    }

    @Test func renderSettingsControls() async throws {
        guard let output = ProcessInfo.processInfo.environment["ILLIQUID_THUMBNAIL_SETTINGS_IMAGE"] else { return }
        let suite = "ThumbnailSettings-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { try? FileManager.default.removeItem(at: root) }
        let player = PlaybackController(persistence: PlaybackPersistenceStore(userDefaults: defaults),
            sessionStore: AtomicPlaybackSessionStore(fileURL: root.appendingPathComponent("session.json")), thumbnailCacheDirectory: nil)
        let scheduler = ThumbnailBackgroundScheduler(player: player, defaults: defaults)
        defer { scheduler.shutdown() }
        scheduler.preferences.generatesInBackground = true
        let view = NSHostingView(rootView: ThumbnailSettingsCard(scheduler: scheduler).padding(24)
            .frame(width: 680).background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 1000),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.close() }
        view.frame = NSRect(origin: .zero, size: view.fittingSize)
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: output))
        await player.shutdown()
    }

    @Test func navigationReplacesPendingWorkAndPlaybackCancelsAnActivePass() async throws {
        let suite = "ThumbnailScheduler-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { try? FileManager.default.removeItem(at: root) }
        let player = PlaybackController(persistence: PlaybackPersistenceStore(userDefaults: defaults),
            sessionStore: AtomicPlaybackSessionStore(fileURL: root.appendingPathComponent("session.json")),
            thumbnailCacheDirectory: nil)
        var calls: [URL] = []
        var cancelled = false, released = false
        let scheduler = ThumbnailBackgroundScheduler(player: player, defaults: defaults,
            readDuration: { _ in 120 }, generate: { url, _ in
                calls.append(url)
                do { try await Task.sleep(for: .seconds(10)) } catch { cancelled = true }
                return !Task.isCancelled
            }, releaseResources: { released = true })
        defer { scheduler.shutdown() }
        let old = root.appendingPathComponent("old/video.mkv"), new = root.appendingPathComponent("new/video.mkv")
        var settings = ThumbnailPreferences(); settings.generatesInBackground = true; settings.idleSeconds = 1
        scheduler.preferences = settings
        scheduler.updatePlayback(current: nil, idle: true, windowVisible: true)
        scheduler.navigate(folder: old.deletingLastPathComponent(), discovered: [old])
        scheduler.navigate(folder: new.deletingLastPathComponent(), discovered: [new])
        for _ in 0..<150 where calls.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        #expect(calls == [new])
        scheduler.updatePlayback(current: new, idle: false, windowVisible: true)
        for _ in 0..<50 where !cancelled { try await Task.sleep(for: .milliseconds(10)) }
        #expect(cancelled)
        for _ in 0..<50 where !released { try await Task.sleep(for: .milliseconds(10)) }
        #expect(released)
        #expect(calls == [new])
        await player.shutdown()
    }

    @Test func closedWindowRequiresOptInAndBudgetCancelsWork() async throws {
        let suite = "ThumbnailScheduler-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { try? FileManager.default.removeItem(at: root) }
        let player = PlaybackController(persistence: PlaybackPersistenceStore(userDefaults: defaults),
            sessionStore: AtomicPlaybackSessionStore(fileURL: root.appendingPathComponent("session.json")),
            thumbnailCacheDirectory: nil)
        var calls = 0, cancelled = false
        let scheduler = ThumbnailBackgroundScheduler(player: player, defaults: defaults,
            readDuration: { _ in 120 }, generate: { _, _ in
                calls += 1
                do { try await Task.sleep(for: .seconds(10)) } catch { cancelled = true }
                return false
            })
        defer { scheduler.shutdown() }
        var settings = ThumbnailPreferences(); settings.generatesInBackground = true
        settings.idleSeconds = 1; settings.workSeconds = 1
        scheduler.preferences = settings
        let video = root.appendingPathComponent("video.mkv")
        scheduler.updatePlayback(current: video, idle: true, windowVisible: false)
        try await Task.sleep(for: .milliseconds(1100))
        #expect(calls == 0)
        settings.generatesWithWindowClosed = true; scheduler.preferences = settings
        for _ in 0..<200 where !cancelled { try await Task.sleep(for: .milliseconds(20)) }
        #expect(calls == 1 && cancelled)
        #expect(scheduler.status == "Background work budget reached.")
        let restored = try JSONDecoder().decode(ThumbnailPreferences.self,
            from: #require(defaults.data(forKey: ThumbnailBackgroundScheduler.preferencesKey)))
        #expect(restored == settings)
        await player.shutdown()
    }

    @Test func removingVisibleRowsBeyondDiscoveryLimitCancelsTheirWork() async throws {
        let suite = "ThumbnailScheduler-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { try? FileManager.default.removeItem(at: root) }
        let player = PlaybackController(persistence: PlaybackPersistenceStore(userDefaults: defaults),
            sessionStore: AtomicPlaybackSessionStore(fileURL: root.appendingPathComponent("session.json")),
            thumbnailCacheDirectory: nil)
        var started = false, cancelled = false
        let scheduler = ThumbnailBackgroundScheduler(player: player, defaults: defaults,
            readDuration: { _ in 120 }, generate: { _, _ in
                started = true
                do { try await Task.sleep(for: .seconds(10)) } catch { cancelled = true }
                return false
            })
        defer { scheduler.shutdown() }
        var settings = ThumbnailPreferences(); settings.generatesInBackground = true; settings.idleSeconds = 1
        scheduler.preferences = settings
        scheduler.updatePlayback(current: nil, idle: true, windowVisible: true)
        let rows = (0...2048).map { root.appendingPathComponent("\($0).mkv") }
        scheduler.navigate(folder: nil, discovered: rows)
        scheduler.setVisible(rows[2048], visible: true)
        for _ in 0..<150 where !started { try await Task.sleep(for: .milliseconds(20)) }
        #expect(started)
        // The bounded discovery prefix is unchanged; only viewport membership changed.
        scheduler.navigate(folder: nil, discovered: Array(rows.prefix(2048)))
        for _ in 0..<50 where !cancelled { try await Task.sleep(for: .milliseconds(10)) }
        #expect(cancelled)
        await player.shutdown()
    }
}
