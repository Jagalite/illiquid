import CoreMedia
import Foundation
import SuperplayrCore
import SuperplayrPlayback
import Testing
@testable import SuperplayrNativePlayback

@Suite("External VobSub pairs", .serialized)
struct ExternalVobSubTests {
    private var fixture: URL? {
        ProcessInfo.processInfo.environment["SUPERPLAYR_BITMAP_FIXTURE_DIR"].map {
            URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent("generated-vobsub.idx")
        }
    }

    @Test func pairPreparationEnumeratesLanguagesAndRejectsMissingOrChangedCompanion() throws {
        guard let fixture else { return }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let index = folder.appendingPathComponent("captions.idx")
        let binary = folder.appendingPathComponent("captions.sub")
        try FileManager.default.copyItem(at: fixture, to: index)
        #expect(throws: (any Error).self) { try PreparedExternalSubtitle.prepare(url: index, encoding: .unicodeOnly) }
        try FileManager.default.copyItem(at: fixture.deletingPathExtension().appendingPathExtension("sub"), to: binary)
        let prepared = try PreparedExternalSubtitle.prepare(url: index, encoding: .unicodeOnly)
        #expect(prepared.tracks.map(\.languageCode) == ["en", "fr"])
        #expect(Set(prepared.tracks.map(\.id)).count == 2)
        #expect(prepared.source(for: prepared.tracks[1].id) == .externalBitmap(url: index, streamIndex: 1))
        #expect(prepared.source(for: 1) == nil)
        try Data([0]).write(to: binary)
        #expect(throws: (any Error).self) { try prepared.verifyVersions() }
        #expect(MediaFileSupport.isSupportedSubtitleFile(index))
        #expect(!MediaFileSupport.isSupportedSubtitleFile(binary))
    }

    @Test @MainActor func bothLanguagesUseExternalTimelineAcrossVideoOriginAndSeek() async throws {
        guard let fixture, let root = ProcessInfo.processInfo.environment["SUPERPLAYR_NATIVE_FIXTURE_DIR"] else { return }
        let video = URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent("nonzero-start.mkv")
        for stream in [Int32(0), 1] {
            let presentation = try NativePresentationCoordinator()
            presentation.setVolume(0, muted: true)
            let main = try SubtitlePipeline(overlay: SubtitleOverlayView(headless: true), presentsOverlay: false)
            let pip = try SubtitlePipeline(overlay: SubtitleOverlayView(headless: true), presentsOverlay: false)
            let session = try MediaSession(url: video, presentation: presentation, subtitles: main,
                pictureInPictureSubtitles: pip, subtitleSource: .externalBitmap(url: fixture, streamIndex: stream), preferHardware: false)
            defer { session.stop(); _ = session.waitForShutdown(timeout: .now() + 3); main.terminate(); pip.terminate(); presentation.terminate() }
            #expect(session.mediaInfo.startTime != 0)
            #expect(session.activeSubtitleStream?.index == stream)
            session.start(rate: 0)
            #expect(await waitUntil { main.eventCount > 0 })
            let size = CGSize(width: 1_280, height: 720), viewport = CGRect(x: 0, y: 0, width: 1_280, height: 720)
            let early = CMTime(seconds: 0.5, preferredTimescale: 1_000)
            let shown = CMTime(seconds: 2, preferredTimescale: 1_000)
            #expect(main.renderedRegions(at: early, viewport: viewport, videoSize: size).isEmpty)
            #expect(!main.renderedRegions(at: shown, viewport: viewport, videoSize: size).isEmpty)
            for _ in 0..<2 {
                let oldGeneration = session.currentGeneration
                _ = session.seek(to: 2, exact: true, resumeRate: 0)
                #expect(session.currentGeneration > oldGeneration)
                #expect(await waitUntil { !main.renderedRegions(at: shown, viewport: viewport, videoSize: size).isEmpty })
                #expect(await waitUntil { !pip.renderedRegions(at: shown, viewport: viewport, videoSize: size).isEmpty })
            }
            session.stop()
            #expect(session.waitForShutdown(timeout: .now() + 3))
        }
    }

    @Test @MainActor func runtimeSwitchesInstalledLanguagesAndOffWithoutReloadingText() async throws {
        guard let fixture, let root = ProcessInfo.processInfo.environment["SUPERPLAYR_NATIVE_FIXTURE_DIR"] else { return }
        let backend = try NativePlaybackRuntime()
        var selected: Int64?
        var external: [MediaTrack] = []
        backend.eventHandler = { event in
            if case let .tracksChanged(snapshot) = event.payload {
                selected = snapshot.selectedSubtitleID
                external = snapshot.tracks.filter(\.isExternal)
            }
        }
        _ = try backend.makeSurfaceHost()
        backend.setVolume(0)
        let source = MediaSource.localFile(URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent("h264-aac.mp4"))
        try backend.load(PlaybackRuntimeLoadRequest(media: try #require(MediaLoadRequest(source: source, origin: .userSelected)),
            identity: PlayerSessionIdentity(source: source, generation: 1)))
        #expect(await waitUntil { backend.sessionSnapshotForDiagnostics?.isPrerolled == true })
        backend.loadExternalSubtitle(fixture, select: true)
        #expect(await waitUntil { external.count == 2 && selected == Int64.max })
        backend.selectSubtitleTrack(Int64.max - 1)
        #expect(await waitUntil { selected == Int64.max - 1 })
        backend.selectSubtitleTrack(nil)
        #expect(await waitUntil { selected == nil })
        backend.selectSubtitleTrack(Int64.max)
        #expect(await waitUntil { selected == Int64.max })
        backend.stop()
        await backend.shutdown()
    }

    @MainActor private func waitUntil(_ predicate: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return predicate()
    }
}
