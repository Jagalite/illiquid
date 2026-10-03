import Foundation
import Testing
@testable import SuperplayrCore

@Suite("Core utilities")
struct UtilitiesTests {
    @Test("Natural ordering sorts numbers by value")
    func naturalOrderingSortsNumbersByValue() {
        let folder = URL(fileURLWithPath: "/tmp/Shows", isDirectory: true)
        let urls = [
            folder.appendingPathComponent("Episode 10.mkv"),
            folder.appendingPathComponent("Episode 2.mkv"),
            folder.appendingPathComponent("Episode 1.mkv"),
        ]

        #expect(
            NaturalFilenameOrdering.sort(urls).map(\.lastPathComponent)
                == ["Episode 1.mkv", "Episode 2.mkv", "Episode 10.mkv"]
        )
    }

    @Test("Media and subtitle extension checks are case insensitive")
    func mediaAndSubtitleExtensionChecksAreCaseInsensitive() throws {
        #expect(MediaFileSupport.isSupportedMediaFile(URL(fileURLWithPath: "/tmp/Movie.MKV")))
        #expect(MediaFileSupport.isSupportedMediaFile(URL(fileURLWithPath: "/tmp/Movie.mp4")))
        #expect(MediaFileSupport.isSupportedSubtitleFile(URL(fileURLWithPath: "/tmp/Movie.SRT")))
        #expect(MediaFileSupport.isSupportedSubtitleFile(URL(fileURLWithPath: "/tmp/Movie.Ass")))
        #expect(MediaFileSupport.isSupportedSubtitleFile(URL(fileURLWithPath: "/tmp/Movie.SSA")))
        #expect(MediaFileSupport.isSupportedSubtitleFile(URL(fileURLWithPath: "/tmp/Movie.vtt")))
        #expect(!MediaFileSupport.isSupportedMediaFile(URL(fileURLWithPath: "/tmp/readme.txt")))
        #expect(!MediaFileSupport.isSupportedSubtitleFile(URL(fileURLWithPath: "/tmp/Movie.sup")))
        let remoteURL = try #require(URL(string: "https://example.com/movie.mp4"))
        #expect(!MediaFileSupport.isSupportedMediaFile(remoteURL))
    }

    @Test("Normalized file identity standardizes path segments")
    func normalizedFileIdentityStandardizesPathSegments() throws {
        let composed = URL(fileURLWithPath: "/tmp/Caf\u{00E9}/../Media/Episode.mkv")
        let decomposed = URL(fileURLWithPath: "/tmp/Media/E\u{0070}isode.mkv")
        let direct = URL(fileURLWithPath: "/tmp/Media/Episode.mkv")

        #expect(NormalizedFileURL.representsSameFile(composed, direct))
        #expect(NormalizedFileURL.representsSameFile(decomposed, direct))
        let remoteURL = try #require(URL(string: "https://example.com/video.mp4"))
        #expect(NormalizedFileURL.normalize(remoteURL) == nil)
    }
    @Test func lexicalKeysDoNotResolveAliasesAndPreparationObservesRetargeting() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first", isDirectory: true)
        let second = root.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        try Data().write(to: first.appendingPathComponent("unavailable.mkv"))
        try Data().write(to: second.appendingPathComponent("unavailable.mkv"))
        let alias = root.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: first)
        let raw = alias.appendingPathComponent("unavailable.mkv")
        #expect(NormalizedFileURL.normalize(raw)?.path == raw.path)
        #expect(!NormalizedFileURL.representsSameFile(raw, first.appendingPathComponent("unavailable.mkv")))
        #expect(NormalizedFileURL.resolveFilesystemIdentity(raw) == first.appendingPathComponent("unavailable.mkv"))
        try FileManager.default.removeItem(at: alias)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: second)
        #expect(NormalizedFileURL.resolveFilesystemIdentity(raw) == second.appendingPathComponent("unavailable.mkv"))
        #expect(NormalizedFileURL.persistenceKey(for: raw) == raw.path)
    }

}
