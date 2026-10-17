#if os(macOS)
import Foundation
import Testing
import IlliquidCore

@Suite("PlexMatch filesystem mapping regressions")
struct PlexMatchReaderRegressionTests {
    @Test(arguments: PlexMatchHintsRegressionTests.invalidUnicodeTokens)
    func malformedMappingDoesNotChangeRecognizedFilename(_ token: String) throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let name = "Show - S04E06E08.mkv"
        try write("title: Show\nep: \(token): \(name)", at: root.appendingPathComponent(".plexmatch"))
        let recognized = try MediaSidecarReader().recognize(root.appendingPathComponent(name), within: root)
        #expect(recognized.kind == .episode)
        #expect(recognized.season == 4)
        #expect(recognized.episode == 6)
        #expect(recognized.lastEpisode == 8)
    }

    @Test(arguments: PlexMatchHintsRegressionTests.invalidUnicodeTokens)
    func malformedChildMappingDoesNotReplaceValidAncestorMapping(_ token: String) throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let child = root.appendingPathComponent("Season 4")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try write("title: Show\nep: S04E06-E08: Season 4/opaque.mkv", at: root.appendingPathComponent(".plexmatch"))
        try write("ep: \(token): opaque.mkv", at: child.appendingPathComponent(".plexmatch"))
        let recognized = try MediaSidecarReader().recognize(child.appendingPathComponent("opaque.mkv"), within: root)
        #expect(recognized.kind == .episode)
        #expect(recognized.season == 4)
        #expect(recognized.episode == 6)
        #expect(recognized.lastEpisode == 8)
    }

    @Test func invalidOnlyAncestorDoesNotCreateASeriesMappingBoundary() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let series = root.appendingPathComponent("Series")
        let season = series.appendingPathComponent("Season 2")
        try FileManager.default.createDirectory(at: season, withIntermediateDirectories: true)
        try write("ep: E０２: ignored.mkv", at: root.appendingPathComponent(".plexmatch"))
        try write("title: Show\nep: 4: Season 2/opaque.mkv", at: series.appendingPathComponent(".plexmatch"))
        let recognized = try MediaSidecarReader().recognize(season.appendingPathComponent("opaque.mkv"), within: root)
        #expect(recognized.kind == .episode)
        #expect(recognized.title == "Show")
        #expect(recognized.season == 2)
        #expect(recognized.episode == 4)
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("plexmatch-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func write(_ text: String, at url: URL) throws {
        try Data(text.utf8).write(to: url)
    }
}
#endif
