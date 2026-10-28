import Foundation
import Testing
@testable import IlliquidCore

@Suite("Normalized file identity compatibility")
struct NormalizedFileIdentityTests {
    private func legacyKey(_ url: URL) -> String? {
        let absolute = url.absoluteURL
        guard absolute.isFileURL, absolute.path.hasPrefix("/"),
              absolute.user == nil, absolute.password == nil, absolute.port == nil else { return nil }
        let host = absolute.host ?? ""
        guard host.isEmpty || host.lowercased() == "localhost" else { return nil }
        let lexical = url.absoluteURL.standardized
        return URL(
            fileURLWithPath: lexical.path.precomposedStringWithCanonicalMapping,
            isDirectory: lexical.hasDirectoryPath
        ).path
    }

    private func bytes(_ value: String?) -> [UInt8]? { value.map { Array($0.utf8) } }

    private func assertLegacyParity(_ url: URL) throws {
        let expected = legacyKey(url)
        let actual = NormalizedFileURL.persistenceKey(for: url)
        try #require(
            bytes(actual) == bytes(expected),
            "Changed UTF-8 key for \(url.absoluteString.debugDescription); old=\(String(reflecting: expected)), new=\(String(reflecting: actual))"
        )
        #expect(bytes(actual) == bytes(NormalizedFileURL.normalize(url)?.path))
    }

    @Test func ordinaryKeysHaveIndependentExpectedBytes() throws {
        let cases: [(String, String?)] = [
            ("file:///Movies/Feature.mkv", "/Movies/Feature.mkv"),
            ("file://LOCALHOST/Movies/Feature.mkv", "/Movies/Feature.mkv"),
            ("file:///Movies/Season/../Feature.mkv", "/Movies/Feature.mkv"),
            ("file:///Movies/Cafe%CC%81%20%231.mkv", "/Movies/Caf\u{00E9} #1.mkv"),
            ("file:///Movies/100%25.mkv", "/Movies/100%.mkv"),
            ("file:///", "/"),
            ("file://media.example/Movies/Feature.mkv", nil),
            ("file://user@localhost/Movies/Feature.mkv", nil),
            ("file://localhost:1234/Movies/Feature.mkv", nil),
            ("https://media.example/Feature.mkv", nil),
            ("file:relative.mkv", nil),
        ]
        for (input, expected) in cases {
            let url = try #require(URL(string: input))
            #expect(bytes(NormalizedFileURL.persistenceKey(for: url)) == bytes(expected))
            try assertLegacyParity(url)
        }
    }

    @Test func encodedAndLiteralPathFormsMatchTheLegacyRoundTrip() throws {
        let prefixes = ["file:///", "file:/", "file://localhost/", "file://LOCALHOST/", "file:////"]
        let components = [
            "", ".", "..", "%2e", "%2E%2E", ".hidden", "a", "a%2Fb", "%2F",
            "%252F", "%25", "%00", "%01", "%09", "%0A", "%0D", "%20", "%5C",
            "%3F", "%23", "%3A", "%7E", "Cafe%CC%81", "Caf%C3%A9",
            "%E1%84%80%E1%85%A1", "%EA%B0%80", "%E5%AD%97%E5%B9%95",
        ]
        for prefix in prefixes {
            for first in components {
                for second in components {
                    for suffix in ["", "/"] {
                        let url = try #require(URL(string: prefix + first + "/" + second + suffix))
                        try assertLegacyParity(url)
                    }
                }
            }
        }
    }

    @Test func decodedSegmentsAndPathParametersKeepTheLegacyInterpretation() throws {
        let cases = [
            "file:///Movies/%2e%2e/Feature.mkv", "file:///Movies/%2E/Feature.mkv",
            "file:///Movies/%2E%2E/Season/%2E%2E/Feature.mkv",
            "file:///Movies%2FSeason%2F..%2FFeature.mkv",
            "file:///Movies/%2F///Feature.mkv//", "file:///%2FMovies/Feature.mkv",
            "file:///Movies/Feature.mkv;version=1",
            "file:///Movies/Feature.mkv%3Bversion=1?query=ignored#fragment",
            "file:///Movies/Feature%00tail.mkv", "file:///Movies/%EF%BB%BFFeature.mkv",
            "file:///Movies/Feature%7F.mkv", "file:///Movies/Feature%FF.mkv",
        ]
        for input in cases {
            if let url = URL(string: input) { try assertLegacyParity(url) }
        }
    }

    @Test func fileURLConstructorsPreserveOddPaths() throws {
        let paths = [
            "/", "//", "///", "//Movies//Feature.mkv", "/Movies//Season///Feature.mkv/",
            "/Movies/./Feature.mkv", "/Movies/../Feature.mkv", "/../Feature.mkv",
            "/Movies/.hidden", "/Movies/%2F.mkv", "/Movies/~/Feature.mkv",
            "/Movies/\u{0}.mkv", "/Movies/\u{1}\t\n\r.mkv", "/Movies/trailing ",
            "/Movies/Cafe\u{0301}.mkv", "/Movies/Caf\u{00E9}.mkv",
            "/Movies/\u{1100}\u{1161}.mkv", "/Movies/가.mkv",
            "/Movies/👩🏽‍🚀 e\u{0301}\u{0327}.mkv", "/.file/id=123.456/",
        ]
        for path in paths {
            for directory in [false, true] {
                try assertLegacyParity(URL(fileURLWithPath: path, isDirectory: directory))
            }
        }
    }

    @Test func relativeReferencesQueriesAndAuthoritiesKeepTheirIdentity() throws {
        let bases = [
            "file:///Movies/Season/", "file:///Movies/Feature.mkv",
            "file://localhost/Movies/", "file://media.example/Movies/",
            "file://user@localhost/Movies/", "https://media.example/Movies/",
        ]
        let references = [
            "", ".", "..", "../Feature.mkv", "Feature.mkv", "./Cafe%CC%81.mkv",
            "%2E%2E/Feature.mkv", "Nested%2FFeature.mkv", "/Movies//Feature.mkv/",
            "//localhost/Movies/Feature.mkv", "//remote.example/Movies/Feature.mkv",
            "?token=a%2Fb", "#chapter", "Feature.mkv?token=a%2Fb#chapter",
        ]
        for baseText in bases {
            let base = try #require(URL(string: baseText))
            for reference in references {
                try assertLegacyParity(try #require(URL(string: reference, relativeTo: base)))
            }
        }
        for authority in ["127.0.0.1", "[::1]", "localhost.example", "user:password@localhost",
                          "localhost:0", "localhost:65535", "LOCALHOST", "local%68ost"] {
            if let url = URL(string: "file://" + authority + "/Movies/Feature.mkv") {
                try assertLegacyParity(url)
            }
        }
    }

    @Test func normalizedAndDecodedPlaylistItemsKeepFirstOccurrenceMetadata() throws {
        let composed = URL(fileURLWithPath: "/Movies/Caf\u{00E9}.mkv", isDirectory: false)
        let decomposed = try #require(URL(string: "file:///Movies/Cafe%CC%81.mkv"))
        let encoded = try JSONEncoder().encode([
            FolderPlaylistItem(url: composed, dateAdded: Date(timeIntervalSince1970: 1)),
            FolderPlaylistItem(url: decomposed, dateAdded: Date(timeIntervalSince1970: 2)),
        ])
        let items = try JSONDecoder().decode([FolderPlaylistItem].self, from: encoded)
        #expect(PlaylistMutation.deduplicated(items) == [items[0]])
        let folder = FolderPlaylist(folderURL: composed.deletingLastPathComponent(), items: items)
        #expect(folder.index(of: decomposed) == 0)
        #expect(NormalizedFileURL.representsSameFile(composed, decomposed))
    }
}
