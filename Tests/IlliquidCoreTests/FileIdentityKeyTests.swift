import Foundation
import Testing
@testable import IlliquidCore

private func keyBytes(_ value: String?) -> [UInt8]? {
    value.map { Array($0.utf8) }
}

@Suite("File identity key compatibility")
struct FileIdentityKeyTests {
    @Test("Keys preserve the original URL reconstruction behavior byte for byte")
    func differentialCorpus() {
        var constructed = 0
        for entry in FileIdentityKeyCorpus.make() {
            // Malformed URL construction may differ between Foundation versions.
            // Compare the two implementations for every successfully constructed URL.
            guard let url = entry.url else { continue }
            constructed += 1
            #expect(
                keyBytes(NormalizedFileURL.persistenceKey(for: url))
                    == keyBytes(NormalizedFileURL.normalize(url)?.path),
                "Input: \(entry.label); absolute URL: \(url.absoluteString)"
            )
        }
        #expect(constructed > 1_000)
    }

    @Test("Known local identities have independently specified keys")
    func knownKeys() throws {
        let cases: [(String, String)] = [
            ("file:///", "/"),
            ("file:/Movies/Feature.mkv", "/Movies/Feature.mkv"),
            ("file:///Movies/Feature.mkv", "/Movies/Feature.mkv"),
            ("file://localhost/Movies/Feature.mkv", "/Movies/Feature.mkv"),
            ("file://LOCALHOST/Movies/Feature.mkv", "/Movies/Feature.mkv"),
            ("file:///Movies/Season/../Feature.mkv", "/Movies/Feature.mkv"),
            ("file:///Movies/Feature.mkv?download=1#chapter", "/Movies/Feature.mkv"),
            ("file:///Movies/Feature%20%231%3F100%25.mkv", "/Movies/Feature #1?100%.mkv"),
            ("file:///Movies/%252F.mkv", "/Movies/%2F.mkv"),
            ("file:///Movies/Caf%C3%A9.mkv", "/Movies/Caf\u{00E9}.mkv"),
            ("file:///Movies/Cafe%CC%81.mkv", "/Movies/Caf\u{00E9}.mkv"),
            ("file:///Movies/%EA%B0%80.mkv", "/Movies/\u{AC00}.mkv"),
            ("file:///Movies/%E1%84%80%E1%85%A1.mkv", "/Movies/\u{AC00}.mkv"),
        ]
        for (input, expected) in cases {
            let url = try #require(URL(string: input))
            #expect(keyBytes(NormalizedFileURL.persistenceKey(for: url)) == keyBytes(expected),
                    "Input: \(input)")
        }
    }

    @Test("Filesystem paths preserve literal filename punctuation")
    func literalFilenameCharacters() {
        for path in [
            "/Movies/a%2Fb.mkv", "/Movies/a%00b.mkv",
            "/Movies/a#b?c%d.mkv", "/Movies/a\\b.mkv",
        ] {
            let url = URL(fileURLWithPath: path, isDirectory: false)
            #expect(keyBytes(NormalizedFileURL.persistenceKey(for: url)) == keyBytes(path))
        }
        let literal = URL(fileURLWithPath: "/Movies/a%2Fb.mkv", isDirectory: false)
        let nested = URL(fileURLWithPath: "/Movies/a/b.mkv", isDirectory: false)
        #expect(!NormalizedFileURL.representsSameFile(literal, nested))
    }

    @Test("Directory hints preserve path identity")
    func directoryHints() {
        for path in ["/", "/Movies", "/Movies/Feature.mkv"] {
            let file = URL(fileURLWithPath: path, isDirectory: false)
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            #expect(keyBytes(NormalizedFileURL.persistenceKey(for: file))
                    == keyBytes(NormalizedFileURL.persistenceKey(for: directory)))
        }
    }

    @Test("Nested relative references resolve their local base")
    func relativeReferences() throws {
        let base = try #require(URL(string: "file://LOCALHOST/Movies/"))
        let nested = try #require(URL(string: "Season%201/", relativeTo: base))
        let local = try #require(URL(string: "../Feature.mkv", relativeTo: nested))
        #expect(NormalizedFileURL.persistenceKey(for: local) == "/Movies/Feature.mkv")
        let remoteBase = try #require(URL(string: "file://media-server.invalid/Movies/"))
        let remote = try #require(URL(string: "Feature.mkv", relativeTo: remoteBase))
        #expect(NormalizedFileURL.persistenceKey(for: remote) == nil)
    }
}
