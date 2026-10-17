import Foundation
import Testing
@testable import IlliquidCore

@Suite("Local media source validation")
struct LocalMediaSourceValidationTests {
    static let unsupportedFileURLs = [
        "file://media-server.example/Movies/Feature.mkv",
        "file://localhost.example/Movies/Feature.mkv",
        "file://127.0.0.1/Movies/Feature.mkv",
        "file://[::1]/Movies/Feature.mkv",
        "file://user@localhost/Movies/Feature.mkv",
        "file://user:secret@localhost/Movies/Feature.mkv",
        "file://localhost:1234/Movies/Feature.mkv",
        "file://localhost:0/Movies/Feature.mkv",
        "file:relative.mkv",
        "file:",
        "file://",
        "file://localhost",
    ]

    @Test("Unsupported file URLs cannot become local identities", arguments: unsupportedFileURLs)
    func rejectsUnsupportedFileIdentity(_ input: String) throws {
        let url = try #require(URL(string: input))
        #expect(NormalizedFileURL.normalize(url) == nil)
        #expect(NormalizedFileURL.persistenceKey(for: url) == nil)
        #expect(NormalizedFileURL.resolveFilesystemIdentity(url) == nil)
        #expect(MediaSource(url: url) == nil)
    }

    @Test("Direct enum construction cannot bypass file URL validation", arguments: unsupportedFileURLs)
    func rejectsUnsupportedDirectSource(_ input: String) throws {
        let url = try #require(URL(string: input))
        let source = MediaSource.localFile(url)
        #expect(MediaLoadRequest(source: source, origin: .userSelected) == nil)
        #expect(MediaLoadRequest(source: source, origin: .restoredSession) == nil)
    }

    @Test("Remote authorities cannot collide with local files or other hosts")
    func fileAuthoritiesDoNotShareIdentity() throws {
        let local = URL(fileURLWithPath: "/Movies/Feature.mkv")
        let first = try #require(URL(string: "file://one.example/Movies/Feature.mkv"))
        let second = try #require(URL(string: "file://two.example/Movies/Feature.mkv"))
        #expect(!NormalizedFileURL.representsSameFile(first, local))
        #expect(!NormalizedFileURL.representsSameFile(local, first))
        #expect(!NormalizedFileURL.representsSameFile(first, second))
        #expect(!MediaSource.localFile(first).representsSameResource(as: .localFile(local)))
    }

    @Test("Local paths, localhost and mounted volumes remain supported", arguments: [
        "file:///Movies/Feature.mkv",
        "file:/Movies/Feature.mkv",
        "file://localhost/Movies/Feature.mkv",
        "file://LOCALHOST/Movies/Feature.mkv",
        "file:///Volumes/Media%20Share/Feature.mkv",
        "file:///Movies/Caf%C3%A9%20%231.mkv",
        "file:///Movies/Season/../Feature.mkv",
        "file:///",
    ])
    func preservesSupportedLocalSources(_ input: String) throws {
        let url = try #require(URL(string: input))
        let normalized = try #require(NormalizedFileURL.normalize(url))
        #expect(normalized.path == url.absoluteURL.standardized.path.precomposedStringWithCanonicalMapping)
        #expect(normalized.hasDirectoryPath == url.absoluteURL.standardized.hasDirectoryPath)
        #expect(NormalizedFileURL.persistenceKey(for: url) == normalized.path)
        let source = try #require(MediaSource(url: url))
        #expect(source == .localFile(url))
        #expect(MediaLoadRequest(source: source, origin: .userSelected)?.source == source)
        #expect(MediaLoadRequest(source: source, origin: .restoredSession)?.source == source)
    }

    @Test("Localhost and empty authorities retain the same local identity")
    func localhostIdentityIsPreserved() throws {
        let local = URL(fileURLWithPath: "/Movies/Feature.mkv")
        let localhost = try #require(URL(string: "file://LOCALHOST/Movies/Feature.mkv"))
        #expect(NormalizedFileURL.representsSameFile(local, localhost))
    }

    @Test("Relative references inherit and validate their absolute base")
    func validatesInheritedAuthority() throws {
        let localBase = URL(fileURLWithPath: "/Movies/", isDirectory: true)
        let local = try #require(URL(string: "Feature.mkv", relativeTo: localBase))
        #expect(NormalizedFileURL.persistenceKey(for: local) == "/Movies/Feature.mkv")
        #expect(MediaSource(url: local) != nil)
        let remoteBase = try #require(URL(string: "file://media-server.example/Movies/"))
        let remote = try #require(URL(string: "Feature.mkv", relativeTo: remoteBase))
        #expect(NormalizedFileURL.normalize(remote) == nil)
        #expect(NormalizedFileURL.resolveFilesystemIdentity(remote) == nil)
        #expect(MediaSource(url: remote) == nil)
    }

    @Test("Mislabeled persisted URLs cannot authorize local restoration", arguments: [
        "https://media.example/Feature.mp4",
        "http://media.example/Feature.mp4",
        "ftp://media.example/Feature.mp4",
        "file://media-server.example/Movies/Feature.mkv",
        "file:relative.mkv",
    ])
    func rejectsMalformedDecodedSource(_ input: String) throws {
        // Use the unchanged Codable representation, as stored in a session's
        // source field. Decoding is compatible; authorization rejects the value.
        let url = try #require(URL(string: input))
        let data = try JSONEncoder().encode(MediaSource.localFile(url))
        let decoded = try JSONDecoder().decode(MediaSource.self, from: data)
        #expect(decoded == .localFile(url))
        #expect(MediaLoadRequest(source: decoded, origin: .restoredSession) == nil)
        #expect(MediaLoadRequest(source: decoded, origin: .userSelected) == nil)
    }

    @Test("Stream labels cannot authorize local or unsupported schemes", arguments: [
        "file:///Movies/Feature.mkv",
        "ftp://media.example/Feature.mp4",
        "data:text/plain,not-media",
    ])
    func rejectsMislabeledStream(_ input: String) throws {
        let url = try #require(URL(string: input))
        let source = MediaSource.remoteStream(url)
        #expect(MediaLoadRequest(source: source, origin: .userSelected) == nil)
        #expect(MediaLoadRequest(source: source, origin: .restoredSession) == nil)
    }

    @Test("Explicit HTTP and HTTPS playback remains supported", arguments: [
        "https://media.example/Feature.mp4?token=abc#chapter",
        "http://media.example/Feature.mp4",
        "HTTPS://media.example/Feature.mp4",
    ])
    func remotePlaybackStillRequiresExplicitOpen(_ input: String) throws {
        let url = try #require(URL(string: input))
        let source = try #require(MediaSource(url: url))
        #expect(source == .remoteStream(url))
        #expect(MediaLoadRequest(source: source, origin: .userSelected)?.source.url == url)
        #expect(MediaLoadRequest(source: source, origin: .restoredSession) == nil)
        #expect(NormalizedFileURL.normalize(url) == nil)
    }

    @Test("Existing source payloads keep their encoding and restore behavior")
    func validSourceCodingRoundTrips() throws {
        let data = Data(#"{"localFile":{"_0":"file:///Movies/Feature.mkv"}}"#.utf8)
        let source = try JSONDecoder().decode(MediaSource.self, from: data)
        #expect(source == .localFile(URL(fileURLWithPath: "/Movies/Feature.mkv")))
        let encoded = try JSONEncoder().encode(source)
        let decoded = try JSONDecoder().decode(MediaSource.self, from: encoded)
        #expect(decoded == source)
        #expect(MediaLoadRequest(source: decoded, origin: .restoredSession) != nil)
    }

    @Test("Lexical validation does not resolve symlinks; preparation still does")
    func filesystemResolutionRemainsExplicit() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("Feature.mkv")
        try Data().write(to: target)
        let alias = root.appendingPathComponent("Alias.mkv")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
        #expect(NormalizedFileURL.normalize(alias)?.path == alias.path)
        #expect(!NormalizedFileURL.representsSameFile(alias, target))
        #expect(MediaLoadRequest(source: .localFile(alias), origin: .restoredSession)?.source.url == alias)
        #expect(NormalizedFileURL.resolveFilesystemIdentity(alias) == target)
    }
}
