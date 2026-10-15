import Foundation
import IlliquidCore
import Testing
@testable import IlliquidNativePlayback

@Suite("Caption navigation native adapters", .serialized)
struct CaptionNavigationNativeTests {
    @Test func externalSRTUsesThePlaybackParserWithoutRendering() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("captions.srt")
        try "1\n00:00:01,000 --> 00:00:03,000\nHello, 世界.\n\n2\n00:00:04,500 --> 00:00:05,750\nNext sentence.\n".write(to: url, atomically: true, encoding: .utf8)
        let request = CaptionSourceRequest(mediaURL: root.appendingPathComponent("movie.mkv"),
            subtitleTrack: .init(id: Int64.max, kind: .subtitle, codec: "subrip", isExternal: true,
                externalFilename: url.lastPathComponent), externalURL: url, sourceRevision: 1)
        let index = try await NativeCaptionReader.read(request)
        #expect(index.isComplete)
        #expect(index.cues.map(\.start) == [1, 4.5])
        #expect(index.search("世界").count == 1)
        #expect(index.target(for: 1, subtitleDelay: 0.5) == 4)
    }

    @Test func bitmapAndMissingExternalSourcesAreExplicitlyUnsupported() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let idx = root.appendingPathComponent("captions.idx")
        try Data("not OCR input".utf8).write(to: idx)
        let track = MediaTrack(id: 1, kind: .subtitle, codec: "dvd_subtitle", isExternal: true)
        let request = CaptionSourceRequest(mediaURL: root.appendingPathComponent("movie.mkv"),
            subtitleTrack: track, externalURL: idx, sourceRevision: 1)
        await #expect(throws: CaptionReadError.textTrackRequired) { try await NativeCaptionReader.read(request) }
        let missing = CaptionSourceRequest(mediaURL: request.mediaURL, subtitleTrack: track, sourceRevision: 2)
        await #expect(throws: CaptionReadError.externalFileUnavailable) { try await NativeCaptionReader.read(missing) }
    }

    @Test func embeddedTextCaptionsMatchGeneratedMedia() async throws {
        guard let root = ProcessInfo.processInfo.environment["ILLIQUID_PRODUCT_FIXTURES"] else { return }
        let url = URL(fileURLWithPath: root).appendingPathComponent("captions.mkv")
        // The generated fixture has video stream 0, text subtitle stream 1.
        let request = CaptionSourceRequest(mediaURL: url,
            subtitleTrack: .init(id: 2, kind: .subtitle, codec: "subrip"), sourceRevision: 1)
        let index = try await NativeCaptionReader.read(request)
        #expect(index.isComplete)
        #expect(index.cues.count == 2)
        #expect(index.cues.map(\.start) == [1, 4.5])
        #expect(index.search("世界").count == 1)
    }
}
