import Foundation
import Testing
@testable import IlliquidCore

@Suite("Normalized file URL persistence keys")
struct NormalizedFileURLPersistenceKeyTests {
    @Test("Path-only keys preserve complete normalization bytes across URL construction")
    func corpusMatchesNormalizationByteForByte() {
        let cases = NormalizedFileURLCorpus.make()
        #expect(cases.count >= 1_000 && cases.count <= 10_000)
        #expect(Set(cases.map(\.id)).count == cases.count)
        #expect(cases.contains { $0.url == nil })

        for entry in cases {
            guard let url = entry.url else { continue }
            let expectedBytes = NormalizedFileURL.normalize(url).map { Array($0.path.utf8) }
            let actualBytes = NormalizedFileURL.persistenceKey(for: url).map { Array($0.utf8) }
            // String equality alone accepts canonically equivalent NFC/NFD.
            // Persistence keys also retain their pre-existing byte representation.
            #expect(actualBytes == expectedBytes, "Corpus case \(entry.id): \(entry.input)")
        }
    }

    @Test("Canonical ASCII paths retain independently stated keys")
    func asciiKeys() throws {
        let cases: [(String, String)] = [
            ("file:///Movies/Feature.mkv", "/Movies/Feature.mkv"),
            ("file:/Movies/Feature.mkv", "/Movies/Feature.mkv"),
            ("file://LOCALHOST/Movies/Feature.mkv", "/Movies/Feature.mkv"),
            ("file:///Movies/Season/../Feature.mkv", "/Movies/Feature.mkv"),
            ("file:///Movies/Season/./Feature.mkv", "/Movies/Season/Feature.mkv"),
            ("file:///Volumes/Media%20Share/Feature.mkv", "/Volumes/Media Share/Feature.mkv"),
            ("file:///Movies/a%3Fb%23c%25.mkv", "/Movies/a?b#c%.mkv"),
            ("file:///Movies/Feature.mkv?position=10#chapter", "/Movies/Feature.mkv"),
            ("file:///Movies/", "/Movies"),
            ("file:///", "/"),
            ("file:///~user/Feature.mkv", "/~user/Feature.mkv"),
        ]
        for (input, expected) in cases {
            let url = try #require(URL(string: input))
            let actual = try #require(NormalizedFileURL.persistenceKey(for: url))
            #expect(Array(actual.utf8) == Array(expected.utf8), "Input \(input)")
        }

        let path = "/Movies/a?b#c%.mkv"
        let url = URL(fileURLWithPath: path, isDirectory: false)
        #expect(NormalizedFileURL.persistenceKey(for: url) == path)
    }

    @Test("Authority validation still rejects unsupported file and non-file sources")
    func unsupportedSources() throws {
        let inputs = [
            "file://media-server.example/Movies/Feature.mkv",
            "file://localhost.example/Movies/Feature.mkv",
            "file://127.0.0.1/Movies/Feature.mkv",
            "file://[::1]/Movies/Feature.mkv",
            "file://user@localhost/Movies/Feature.mkv",
            "file://user:secret@localhost/Movies/Feature.mkv",
            "file://localhost:1234/Movies/Feature.mkv",
            "file://localhost:0/Movies/Feature.mkv",
            "file:relative.mkv", "file:", "file://", "file://localhost",
            "https://example.invalid/Feature.mkv",
            "ftp://example.invalid/Feature.mkv",
            "data:text/plain,Feature.mkv",
        ]
        for input in inputs {
            let url = try #require(URL(string: input))
            #expect(NormalizedFileURL.persistenceKey(for: url) == nil, "Input \(input)")
        }

        let localBase = URL(fileURLWithPath: "/Movies/Season/", isDirectory: true)
        let local = try #require(URL(string: "../Feature.mkv", relativeTo: localBase))
        #expect(NormalizedFileURL.persistenceKey(for: local) == "/Movies/Feature.mkv")

        let remoteBase = try #require(URL(string: "file://media-server.example/Movies/"))
        let remote = try #require(URL(string: "Feature.mkv", relativeTo: remoteBase))
        #expect(NormalizedFileURL.persistenceKey(for: remote) == nil)
    }

    @Test("Canonical-equivalent Unicode names retain the same stored bytes and identity")
    func unicodeIdentity() throws {
        let pairs = [
            ("/Movies/Caf\u{00E9}.mkv", "/Movies/Cafe\u{0301}.mkv"),
            ("/Movies/\u{AC00}.mkv", "/Movies/\u{1100}\u{1161}.mkv"),
            ("/Movies/\u{00C5}ngstrom.mkv", "/Movies/A\u{030A}ngstrom.mkv"),
        ]
        for (composed, decomposed) in pairs {
            let first = URL(fileURLWithPath: composed, isDirectory: false)
            let second = URL(fileURLWithPath: decomposed, isDirectory: false)
            let firstKey = try #require(NormalizedFileURL.persistenceKey(for: first))
            let secondKey = try #require(NormalizedFileURL.persistenceKey(for: second))
            #expect(Array(firstKey.utf8) == Array(secondKey.utf8))
            #expect(NormalizedFileURL.representsSameFile(first, second))
            #expect([firstKey: 42][secondKey] == 42)
        }
    }

    @Test("Key lookup stays lexical when a filesystem alias is retargeted")
    func symlinkRetargetingDoesNotChangeKey() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("illiquid-key-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }

        let first = root.appendingPathComponent("first", isDirectory: true)
        let second = root.appendingPathComponent("second", isDirectory: true)
        for directory in [first, second] {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let alias = root.appendingPathComponent("alias", isDirectory: true)
        try manager.createSymbolicLink(at: alias, withDestinationURL: first)
        let source = alias.appendingPathComponent("Feature.mkv", isDirectory: false)
        let firstFile = first.appendingPathComponent("Feature.mkv", isDirectory: false)
        let secondFile = second.appendingPathComponent("Feature.mkv", isDirectory: false)
        try Data().write(to: firstFile)
        try Data().write(to: secondFile)

        let before = try #require(NormalizedFileURL.persistenceKey(for: source))
        #expect(before == source.path)
        #expect(!NormalizedFileURL.representsSameFile(source, firstFile))
        #expect(NormalizedFileURL.resolveFilesystemIdentity(source) == firstFile)

        try manager.removeItem(at: alias)
        try manager.createSymbolicLink(at: alias, withDestinationURL: second)
        let after = try #require(NormalizedFileURL.persistenceKey(for: source))
        #expect(Array(before.utf8) == Array(after.utf8))
        #expect(!NormalizedFileURL.representsSameFile(source, secondFile))
        #expect(NormalizedFileURL.resolveFilesystemIdentity(source) == secondFile)
    }
}
