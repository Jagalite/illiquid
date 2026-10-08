import Foundation
import Darwin
import Testing
import IlliquidCore
import IlliquidPlayer
import AppKit
import SwiftUI
@testable import IlliquidApp

@Suite("Background thumbnail scheduling", .serialized)
@MainActor
struct ThumbnailBackgroundSchedulerTests {
    private func cpuSeconds() -> Double {
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }

    @Test func currentVideoPreparationUsesRealPlaybackAndSharedCache() async throws {
        guard let fixture = ProcessInfo.processInfo.environment["ILLIQUID_PROGRESSIVE_PREVIEW_FIXTURE"] else { return }
        let suite = "CurrentPreviewMedia-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { try? FileManager.default.removeItem(at: root) }
        let player = PlaybackController(persistence: PlaybackPersistenceStore(userDefaults: defaults),
            sessionStore: AtomicPlaybackSessionStore(fileURL: root.appendingPathComponent("session.json")),
            thumbnailCacheDirectory: root.appendingPathComponent("thumbnails"))
        let scheduler = ThumbnailBackgroundScheduler(player: player, defaults: defaults)
        defer { scheduler.shutdown() }
        do {
            player.setMuted(true)
            let url = URL(fileURLWithPath: fixture)
            let host = try player.makeVideoSurfaceHost()
            host.view.frame = CGRect(x: 0, y: 0, width: 960, height: 540)
            host.view.layoutSubtreeIfNeeded()
            player.open(url: url)
            for _ in 0..<500 where player.viewStore.phase != .playing { try await Task.sleep(for: .milliseconds(20)) }
            try #require(player.viewStore.phase == .playing)
            let steadyStart = ProcessInfo.processInfo.systemUptime, steadyCPU = cpuSeconds()
            try await Task.sleep(for: .seconds(2))
            let steadyPercent = (cpuSeconds() - steadyCPU) / (ProcessInfo.processInfo.systemUptime - steadyStart) * 100
            scheduler.preferences.idleSeconds = 1
            let start = ProcessInfo.processInfo.systemUptime, cpu = cpuSeconds()
            scheduler.updatePlayback(current: url, idle: false, windowVisible: true, playing: true)
            try await Task.sleep(for: .seconds(6))
            scheduler.updatePlayback(current: url, idle: false, windowVisible: true, playing: false)
            let preparationPercent = (cpuSeconds() - cpu) / (ProcessInfo.processInfo.systemUptime - start) * 100
            await scheduler.refreshCacheUsage()
            #expect((scheduler.cacheUsage?.images ?? 0) > 0)
            let duration = try #require(player.playbackProgress(for: url)?.duration)
            let lookupStart = ProcessInfo.processInfo.systemUptime
            let target = duration * 0.37
            let cached = await player.cachedTimelineThumbnail(at: target,
                maximumPixelSize: CGSize(width: 368, height: 208), maximumDistance: duration)
            let lookupMS = (ProcessInfo.processInfo.systemUptime - lookupStart) * 1_000
            #expect(cached != nil)
            #expect(player.viewStore.phase == .playing)
            if let output = ProcessInfo.processInfo.environment["ILLIQUID_PROGRESSIVE_PREVIEW_RECEIPT"] {
                let row: [String: Any] = ["fixture": fixture, "steady_cpu_percent_one_core": steadyPercent,
                    "preparation_cpu_percent_one_core": preparationPercent,
                    "resident_images": scheduler.cacheUsage?.images ?? 0, "cache_bytes": scheduler.cacheUsage?.memoryBytes ?? 0,
                    "cached_approximation_available": cached != nil, "cached_lookup_ms": lookupMS,
                    "requested_seconds": target, "represented_seconds": cached?.position as Any? ?? NSNull(),
                    "visible_window": false,
                    "limitations": "Single debug run on shared host; no displayed-drop or system-energy qualification"]
                try JSONSerialization.data(withJSONObject: row, options: [.prettyPrinted, .sortedKeys])
                    .write(to: URL(fileURLWithPath: output))
            }
            await player.shutdown()
        } catch { await player.shutdown(); throw error }
    }

    @Test func supersededCompletionCannotMarkNewSourcePrepared() async throws {
        let suite = "PreviewSourceRace-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { try? FileManager.default.removeItem(at: root) }
        let player = PlaybackController(persistence: PlaybackPersistenceStore(userDefaults: defaults),
            sessionStore: AtomicPlaybackSessionStore(fileURL: root.appendingPathComponent("session.json")), thumbnailCacheDirectory: nil)
        let old = URL(fileURLWithPath: "/media/old.mkv")
        let new = URL(fileURLWithPath: "/media/new.mkv")
        var completion: CheckedContinuation<Bool, Never>?
        var requests: [(URL, Double)] = []
        let scheduler = ThumbnailBackgroundScheduler(player: player, defaults: defaults,
            readDuration: { _ in 1_440 }, generate: { url, time in
                requests.append((url, time))
                if url == old { return await withCheckedContinuation { completion = $0 } }
                return true
            })
        defer { completion?.resume(returning: false); scheduler.shutdown() }
        scheduler.preferences.idleSeconds = 1
        scheduler.updatePlayback(current: old, idle: false, windowVisible: true, playing: true)
        for _ in 0..<150 where completion == nil { try await Task.sleep(for: .milliseconds(20)) }
        try #require(completion != nil)
        scheduler.updatePlayback(current: new, idle: false, windowVisible: true, playing: true)
        let pending = completion; completion = nil; pending?.resume(returning: true)
        for _ in 0..<150 where !requests.contains(where: { $0.0 == new }) { try await Task.sleep(for: .milliseconds(20)) }
        let first = try #require(requests.first(where: { $0.0 == new }))
        #expect(first.1 == ThumbnailPolicy.storyboard(duration: 1_440).first)
    }

    @Test func automaticCurrentCoverageSurvivesHoverAndStopsForRecovery() async throws {
        let suite = "CurrentPreviews-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { try? FileManager.default.removeItem(at: root) }
        let player = PlaybackController(persistence: PlaybackPersistenceStore(userDefaults: defaults),
            sessionStore: AtomicPlaybackSessionStore(fileURL: root.appendingPathComponent("session.json")), thumbnailCacheDirectory: nil)
        let current = URL(fileURLWithPath: "/media/current.mkv")
        var generated: [(URL, Double)] = []
        let scheduler = ThumbnailBackgroundScheduler(player: player, defaults: defaults,
            readDuration: { _ in 7_200 }, generate: { url, time in generated.append((url, time)); return true })
        defer { scheduler.shutdown() }
        scheduler.preferences.idleSeconds = 1
        scheduler.updatePlayback(current: current, idle: false, windowVisible: true, playing: true)
        scheduler.navigate(folder: nil, discovered: [URL(fileURLWithPath: "/media/other.mkv")])
        for index in 0..<15 {
            scheduler.interaction(current, position: Double(index * 100))
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(!generated.isEmpty)
        #expect(generated.allSatisfy { $0.0 == current })
        #expect(!scheduler.preferences.generatesInBackground)
        scheduler.updatePlayback(current: current, idle: false, windowVisible: true, playing: false)
        let count = generated.count
        try await Task.sleep(for: .milliseconds(700))
        #expect(generated.count == count)
        scheduler.shutdown(); await player.shutdown()
    }

    @Test func currentVideoPreparationSharesIdleBudgetWithLibraryWork() async throws {
        let suite = "ThumbnailIdleFairness-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { try? FileManager.default.removeItem(at: root) }
        let player = PlaybackController(persistence: PlaybackPersistenceStore(userDefaults: defaults),
            sessionStore: AtomicPlaybackSessionStore(fileURL: root.appendingPathComponent("session.json")),
            thumbnailCacheDirectory: nil)
        let current = URL(fileURLWithPath: "/media/current.mkv")
        let other = URL(fileURLWithPath: "/media/other.mkv")
        var generated: [URL] = []
        let scheduler = ThumbnailBackgroundScheduler(player: player, defaults: defaults,
            readDuration: { _ in 7_200 },
            generate: { url, _ in generated.append(url); return true })
        defer { scheduler.shutdown() }
        var settings = ThumbnailPreferences()
        settings.generatesInBackground = true
        settings.idleSeconds = 1
        settings.workSeconds = 3
        settings.samplesPerVideo = 1
        scheduler.preferences = settings
        scheduler.navigate(folder: other.deletingLastPathComponent(), discovered: [other])
        scheduler.updatePlayback(current: current, idle: true, windowVisible: true)
        for _ in 0..<200 where !generated.contains(other) {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(generated.first == current)
        #expect(generated.contains(other))
        scheduler.shutdown()
        await player.shutdown()
    }

    @Test func memoryPressureCancelsBackgroundWorkUntilNormalAndExclusionsPreventProbes() async throws {
        let suite = "ThumbnailPressure-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { try? FileManager.default.removeItem(at: root) }
        let player = PlaybackController(persistence: PlaybackPersistenceStore(userDefaults: defaults),
            sessionStore: AtomicPlaybackSessionStore(fileURL: root.appendingPathComponent("session.json")),
            thumbnailCacheDirectory: nil)
        var probes: [URL] = [], generated: [URL] = []
        let scheduler = ThumbnailBackgroundScheduler(player: player, defaults: defaults,
            readDuration: { probes.append($0); return 30 },
            generate: { url, _ in generated.append(url); return true })
        defer { scheduler.shutdown() }
        let allowed = URL(fileURLWithPath: "/media/local/video.mkv")
        let excluded = URL(fileURLWithPath: "/media/offline/video.mkv")
        var preferences = ThumbnailPreferences()
        preferences.preparesCurrentVideo = false
        preferences.generatesInBackground = true; preferences.idleSeconds = 1; preferences.samplesPerVideo = 1
        preferences.excludedFolderPaths = ["/media/offline"]
        scheduler.preferences = preferences
        scheduler.updatePlayback(current: allowed, idle: true, windowVisible: true)
        scheduler.navigate(folder: nil, discovered: [allowed, excluded])
        scheduler.setVisible(excluded, visible: true)
        await scheduler.handleMemoryPressure(constrained: true, critical: true)
        try await Task.sleep(for: .milliseconds(1100))
        #expect(probes.isEmpty && generated.isEmpty)
        #expect(scheduler.status.contains("memory is limited"))
        await scheduler.handleMemoryPressure(constrained: false, critical: false)
        for _ in 0..<150 where generated.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        #expect(probes == [allowed] && generated == [allowed])
        scheduler.shutdown()
        await player.shutdown()
    }
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
        settings.preparesCurrentVideo = false
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
        scheduler.preferences.excludedFolderPaths = ["/Volumes/Archive/Slow Media"]
        await scheduler.refreshCacheUsage()
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
        var settings = ThumbnailPreferences(); settings.preparesCurrentVideo = false; settings.generatesInBackground = true; settings.idleSeconds = 1
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
        var settings = ThumbnailPreferences(); settings.preparesCurrentVideo = false; settings.generatesInBackground = true
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

    @Test(arguments: [false, true]) func removingVisibleRowsBeyondDiscoveryLimitCancelsTheirWork(projected: Bool) async throws {
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
        var settings = ThumbnailPreferences(); settings.preparesCurrentVideo = false; settings.generatesInBackground = true; settings.idleSeconds = 1
        scheduler.preferences = settings
        scheduler.updatePlayback(current: nil, idle: true, windowVisible: true)
        let rows = (0...2048).map { root.appendingPathComponent("\($0).mkv") }
        scheduler.navigate(folder: nil, discovered: projected ? Array(rows.prefix(2048)) : rows,
            validPaths: projected ? Set(rows.map(\.path)) : nil)
        scheduler.setVisible(rows[2048], visible: true)
        for _ in 0..<150 where !started { try await Task.sleep(for: .milliseconds(20)) }
        #expect(started)
        // The bounded discovery prefix is unchanged; only viewport membership changed.
        scheduler.navigate(folder: nil, discovered: Array(rows.prefix(2048)),
            validPaths: projected ? Set(rows.prefix(2048).map(\.path)) : nil)
        for _ in 0..<50 where !cancelled { try await Task.sleep(for: .milliseconds(10)) }
        #expect(cancelled)
        await player.shutdown()
    }
}
