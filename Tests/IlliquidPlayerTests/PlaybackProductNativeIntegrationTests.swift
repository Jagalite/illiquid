import AppKit
import Foundation
import IlliquidCore
import IlliquidPlayback
import Testing
@testable import IlliquidNativePlayback
@testable import IlliquidPlayer

/// Full product coordinator/core/native graph using generated on-disk media and
/// an owned AppKit window. Hardware removal, actual OS sleep and power draw are
/// separate manual qualification, not inferred from these lifecycle commands.
@MainActor
@Suite("Playback product native integration", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["ILLIQUID_PRODUCT_FIXTURES"] != nil))
struct PlaybackProductNativeIntegrationTests {
    @Test func nativeOpenAtZeroAndRapidScrubbingReturnOnlyTheFinalSettledFrame() async throws {
        try await withNativeProduct { f in
            let file = try f.copyFixture("h264-aac.mp4")
            let first = try await f.player.openMedia(at: file, position: 2, paused: true)
            #expect(abs(first.position - 2) < 0.05)
            #expect(f.runtime.diagnosticSnapshot?.rendererRate == 0)
            #expect(f.runtime.sessionSnapshotForDiagnostics?.isPrerolled == true)
            let before = try #require(f.runtime.sessionSnapshotForDiagnostics?.seekCount)
            for target in [0.2, 6.0, 0.6, 5.2, 0.9, 4.9, 0.1, 6.7] {
                f.player.previewSeek(to: target)
            }
            f.player.seek(to: 1.5)
            #expect(throws: PlaybackAutomationError.noPlayback) { try f.player.currentPlaybackReference() }
            try await f.waitSettled(paused: true)
            let final = try f.player.currentPlaybackReference()
            #expect(abs(final.position - 1.5) < 0.05)
            let native = try #require(f.runtime.sessionSnapshotForDiagnostics)
            #expect(native.seekCount > before)
            #expect(native.seekCount <= before + 9)
            #expect(native.seekTimings?.milliseconds[.prerollCompleted] != nil)
            #expect(native.failure == nil)
            // Renderer readback is recorded separately from core acknowledgement.
            // The owned window lets the Apple renderer expose its current buffer.
            try await f.wait { f.runtime.pausedReadbackDiagnostic().isCurrent }
            let readback = f.runtime.pausedReadbackDiagnostic()
            #expect(!readback.seekInProgress)
            let pts = try #require(readback.displayedPTS)
            #expect(abs(pts - 1.5) <= 1.0 / 30.0 + 0.005)
            print("[product-native] rapid-scrub final-target=1.5 displayed-pts=\(pts) native-seeks=\(native.seekCount - before)")
            let zero = try await f.player.openMedia(at: file, position: 0, paused: true)
            #expect(zero.position == 0)
            #expect(f.player.viewStore.isPauseDesired)
        }
    }

    @Test func nativeTracksSpeedAudioDelayAndExternalCaptionsSurviveFileChanges() async throws {
        try await withNativeProduct { f in
            let a = try f.copyFixture("multi-track.mkv")
            let b = try f.copyFixture("h264-aac.mp4")
            let sidecar = try f.copyFixture("captions.srt")
            _ = try await f.player.openMedia(at: a, position: 2, paused: true)
            let audio = try #require(f.player.viewStore.audioTracks.first { $0.languageCode == "jpn" || $0.languageCode == "ja" })
            let subtitle = try #require(f.player.viewStore.subtitleTracks.first { $0.languageCode == "jpn" || $0.languageCode == "ja" })
            f.player.selectAudioTrack(audio)
            f.player.selectSubtitleTrack(subtitle)
            try await f.waitSettled(paused: true)
            #expect(f.player.viewStore.selectedAudioTrack?.id == audio.id)
            #expect(f.player.viewStore.selectedSubtitleTrack?.id == subtitle.id)
            f.player.setPlaybackSpeed(1.5)
            f.player.setAudioDelay(-0.2)
            try await f.wait { abs(f.player.viewStore.audioDelay + 0.2) < 0.001 }
            try await f.waitSettled(paused: true)
            let request = try #require(f.player.captionSourceRequest)
            let captions = try await f.player.readCaptions(for: request)
            #expect(!captions.search("字幕").isEmpty)
            _ = try await f.player.openMedia(at: b, position: 1, paused: true)
            #expect(f.player.viewStore.playbackSpeed == 1)
            #expect(f.player.viewStore.audioDelay == 0)
            #expect(!f.player.jumpToCaption(captions.cues[0].id, in: captions, source: request))
            _ = try await f.player.openMedia(at: a, position: 2, paused: true)
            #expect(f.player.viewStore.selectedAudioTrack?.id == audio.id)
            #expect(f.player.viewStore.selectedSubtitleTrack?.id == subtitle.id)
            #expect(f.player.viewStore.playbackSpeed == 1.5)
            #expect(abs(f.player.viewStore.audioDelay + 0.2) < 0.001)
            f.player.loadExternalSubtitle(sidecar)
            try await f.wait { f.player.captionSourceRequest?.externalURL == sidecar }
            try await f.waitSettled(paused: true)
            let externalRequest = try #require(f.player.captionSourceRequest)
            let external = try await f.player.readCaptions(for: externalRequest)
            #expect(!external.search("世界").isEmpty)
            // Search must reflect loaded subtitle bytes, not silently substitute
            // a later on-disk edit into the active subtitle pipeline.
            try Data("1\n00:00:01,000 --> 00:00:03,000\nEdited text.\n".utf8).write(to: sidecar)
            let stillLoaded = try await f.player.readCaptions(for: externalRequest)
            #expect(!stillLoaded.search("世界").isEmpty)
            f.player.selectSubtitleTrack(nil)
            try await f.waitSettled(paused: true)
            _ = try await f.player.openMedia(at: b, position: 1, paused: true)
            _ = try await f.player.openMedia(at: a, position: 2, paused: true)
            #expect(f.player.viewStore.selectedSubtitleTrack == nil)
            #expect(f.player.captionSourceRequest == nil)
            f.player.resetCurrentMediaSettings()
            try await f.waitSettled(paused: true)
            #expect(f.player.viewStore.playbackSpeed == 1)
            #expect(f.player.viewStore.audioDelay == 0)
            #expect(f.player.mediaSettingsForCurrentFile.isEmpty)
        }
    }

    @Test func nativeMissingFileLocateAndRelaunchRetainVerifiedResumePosition() async throws {
        try await withNativeProduct { f in
            let original = try f.copyFixture("h264-aac.mp4")
            _ = try await f.player.openMedia(at: original, position: 3, paused: true)
            await f.player.shutdown()
            let moved = f.root.appendingPathComponent("renamed.mp4")
            try FileManager.default.moveItem(at: original, to: moved)
            try f.recreatePlayer()
            #expect(f.player.restoreLastSession())
            try await f.wait { f.player.viewStore.recoveryIssue != nil }
            let unavailable = try #require(f.player.viewStore.recoveryIssue)
            #expect(unavailable.kind == .unavailableRestore(isFolder: false))
            #expect(try f.sessions.load()?.source == .localFile(original))
            f.player.locateUnavailableSession(at: moved, expectedIssueID: unavailable.id)
            try await f.wait { f.player.viewStore.currentURL == moved }
            try await f.waitSettled(paused: true)
            #expect(abs(f.player.viewStore.position - 3) < 0.05)
            #expect(f.persistence.playbackPosition(for: original) == 3)
            await f.player.shutdown()
            #expect(try f.sessions.load()?.source == .localFile(moved))
            #expect(try f.sessions.load()?.position == 3)
            try f.recreatePlayer()
            #expect(f.player.restoreLastSession())
            try await f.wait { f.player.viewStore.currentURL == moved }
            try await f.waitSettled(paused: true)
            #expect(abs(f.player.viewStore.position - 3) < 0.05)
        }
    }

    @Test func nativeHiddenWindowAndLifecycleCommandsPreservePlaybackIntent() async throws {
        try await withNativeProduct { f in
            let file = try f.copyFixture("multi-track.mkv")
            _ = try await f.player.openMedia(at: file, position: 1, paused: false)
            f.window.orderOut(nil)
            let start = f.player.viewStore.position
            try await f.wait { f.player.viewStore.position > start + 0.1 }
            #expect(f.player.viewStore.currentURL == file)
            #expect(f.runtime.sessionSnapshotForDiagnostics?.failure == nil)
            f.player.pause()
            try await f.waitSettled(paused: true)
            let paused = f.player.viewStore.position
            f.player.systemWillSleep()
            f.player.systemDidWake()
            f.window.orderFrontRegardless()
            try await f.waitSettled(paused: true)
            #expect(f.player.viewStore.isPauseDesired)
            #expect(abs(f.player.viewStore.position - paused) < 0.1)
            #expect(f.runtime.diagnosticSnapshot?.rendererRate == 0)
            print("[product-native] hidden-clock-advanced=yes lifecycle-command-restored-paused=yes")
        }
    }
}

@MainActor
private func withNativeProduct(_ body: @MainActor (NativeProductFixture) async throws -> Void) async throws {
    let fixture = try NativeProductFixture()
    do { try await body(fixture) }
    catch {
        print("[product-native] failure public=\(fixture.player.viewStore.phase) error=\(String(describing: fixture.player.viewStore.recoveryIssue)) native=\(String(describing: fixture.runtime.diagnosticSnapshot))")
        await fixture.player.shutdown()
        fixture.close()
        throw error
    }
    await fixture.player.shutdown()
    fixture.close()
}

@MainActor
private final class NativeProductFixture {
    let root: URL
    let persistence: PlaybackPersistenceStore
    let sessions: AtomicPlaybackSessionStore
    let window: NSWindow
    private let defaults: UserDefaults
    private let domain = "IlliquidNativeProduct-\(UUID().uuidString)"
    private(set) var runtime: NativePlaybackRuntime
    private(set) var player: PlaybackCoordinator

    init() throws {
        _ = NSApplication.shared
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defaults = try #require(UserDefaults(suiteName: domain))
        persistence = PlaybackPersistenceStore(userDefaults: defaults, namespace: "NativeProduct")
        persistence.setMuted(true)
        sessions = AtomicPlaybackSessionStore(fileURL: root.appendingPathComponent("session.json"))
        runtime = try NativePlaybackRuntime()
        player = PlaybackCoordinator(persistence: persistence, sessionStore: sessions, runtime: runtime,
            thumbnailCacheDirectory: root.appendingPathComponent("thumbnails"), automationTimeout: 12)
        window = NSWindow(contentRect: .init(x: 0, y: 0, width: 640, height: 360),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Illiquid product qualification"
        try attach()
    }

    func recreatePlayer() throws {
        window.contentView = nil
        runtime = try NativePlaybackRuntime()
        player = PlaybackCoordinator(persistence: persistence, sessionStore: sessions, runtime: runtime,
            thumbnailCacheDirectory: root.appendingPathComponent("thumbnails"), automationTimeout: 12)
        try attach()
    }

    private func attach() throws {
        let host = try player.makeVideoSurfaceHost()
        host.view.frame = .init(x: 0, y: 0, width: 640, height: 360)
        window.contentView = host.view
        window.orderFrontRegardless()
        host.view.layoutSubtreeIfNeeded()
    }

    func copyFixture(_ name: String) throws -> URL {
        let directory = try #require(ProcessInfo.processInfo.environment["ILLIQUID_PRODUCT_FIXTURES"])
        let from = URL(fileURLWithPath: directory).appendingPathComponent(name)
        let to = root.appendingPathComponent(name)
        try FileManager.default.copyItem(at: from, to: to)
        return to
    }

    func waitSettled(paused: Bool) async throws {
        try await wait {
            (try? self.player.currentPlaybackReference()) != nil
                && self.player.viewStore.phase == (paused ? .paused : .playing)
        }
    }

    func wait(_ predicate: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(12)
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw NativeProductTimeout() }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func close() {
        window.orderOut(nil)
        window.contentView = nil
        window.close()
        defaults.removePersistentDomain(forName: domain)
        try? FileManager.default.removeItem(at: root)
    }
}

private struct NativeProductTimeout: Error {}
