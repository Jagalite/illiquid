import Foundation
import Testing
@testable import IlliquidCore

@Suite("Normalized file persistence keys")
struct NormalizedFileURLPersistenceKeyTests {
    @Test(arguments: [
        "file:///", "file:////", "file://///",
        "file:///%2F", "file:///%2F/", "file:///%2FMedia/A.mkv",
        "file:///Media/A.mkv%2F", "file:///Media/A.mkv%2F/",
        "file:///Media//A.mkv", "file:///Media///A.mkv/",
        "file:///Media/%2E/A.mkv", "file:///Media/%2E%2E/A.mkv",
        "file:///tmp/Z/%2E%2E/A/Same.mkv",
        "file:///tmp/Z/%252E%252E/A/Same.mkv",
        "file:///Media/A%5CB.mkv", "file:///Media/A%255CB.mkv",
        "file:///Media/A%23B%3F.mkv?copy=1#chapter",
        "file:///Media/100%25.mkv", "file:///Media/A%252FB.mkv",
        "file:///Media/A%00B.mkv", "file:///Media/A%09B.mkv",
        "file:///Media/A%0AB.mkv", "file:///Media/A%0DB.mkv",
        "file:///Media/A%7FB.mkv",
        "file:///.file/id=0.0", "file:///%2Efile/id=0.0",
        "file:///%2Efile/id%3D0.0", "file:///%2Efile/id=0.0/child",
    ])
    func encodedComponentsKeepTheOriginalRoundTripBytes(_ spelling: String) throws {
        let url = try #require(URL(string: spelling))
        expectOriginalKey(for: url)
    }

    @Test(arguments: [
        "file:///Media/A.mkv", "file:/Media/A.mkv",
        "file://localhost/Media/A.mkv", "file://LOCALHOST/Media/A.mkv",
        "file:///Media/Season/../A.mkv?copy=1#chapter",
    ])
    func supportedAuthoritiesRetainTheirLocalIdentity(_ spelling: String) throws {
        let url = try #require(URL(string: spelling))
        let key = try #require(NormalizedFileURL.persistenceKey(for: url))
        #expect(Array(key.utf8) == Array("/Media/A.mkv".utf8))
        expectOriginalKey(for: url)
    }

    @Test(arguments: [
        "file://archive.invalid/Media/A.mkv",
        "file://localhost.invalid/Media/A.mkv",
        "file://127.0.0.1/Media/A.mkv", "file://[::1]/Media/A.mkv",
        "file://user@localhost/Media/A.mkv",
        "file://user:password@localhost/Media/A.mkv",
        "file://localhost:0/Media/A.mkv", "file://localhost:1234/Media/A.mkv",
        "file:relative.mkv", "file:", "file://", "file://localhost",
        "https://example.invalid/Media/A.mkv", "ftp://example.invalid/Media/A.mkv",
    ])
    func unsupportedAuthoritiesAndSchemesCannotProduceKeys(_ spelling: String) throws {
        let url = try #require(URL(string: spelling))
        #expect(NormalizedFileURL.persistenceKey(for: url) == nil)
        expectOriginalKey(for: url)
    }

    @Test
    func relativeReferencesValidateTheirAbsoluteBase() throws {
        let localBase = try #require(URL(string: "file://LOCALHOST/Media/Season/"))
        let remoteBase = try #require(URL(string: "file://archive.invalid/Media/Season/"))
        let local = try #require(URL(string: "../A.mkv", relativeTo: localBase))
        let remote = try #require(URL(string: "../A.mkv", relativeTo: remoteBase))
        let key = try #require(NormalizedFileURL.persistenceKey(for: local))
        #expect(Array(key.utf8) == Array("/Media/A.mkv".utf8))
        #expect(NormalizedFileURL.persistenceKey(for: remote) == nil)

        for originalBase in [localBase, remoteBase] {
            var base = originalBase
            for _ in 0..<3 {
                for spelling in [
                    "", ".", "..", "A.mkv", "../A.mkv", "%2E%2E/A.mkv",
                    "%2FMedia/A.mkv", "A%00B.mkv", "A.mkv/", "?query", "#fragment",
                    "//localhost/Media/A.mkv", "//archive.invalid/Media/A.mkv",
                ] {
                    let url = try #require(URL(string: spelling, relativeTo: base))
                    expectOriginalKey(for: url)
                }
                base = try #require(URL(string: "Child/../Nested/", relativeTo: base))
            }
        }
    }

    @Test
    func unicodeSpellingsPreserveTheOriginalPathBytes() throws {
        let paths = [
            "/Media/Caf\u{00E9}.mkv", "/Media/Cafe\u{0301}.mkv",
            "/Media/\u{AC00}.mkv", "/Media/\u{1100}\u{1161}.mkv",
            "/Media/\u{AC01}.mkv", "/Media/\u{1100}\u{1161}\u{11A8}.mkv",
            "/Media/\u{212B}.mkv", "/Media/A\u{030A}.mkv",
            "/Media/a\u{0308}\u{0301}.mkv", "/Media/a\u{0308}\u{0341}.mkv",
            "/Media/\u{0301}leading-combining-mark.mkv",
            "/Media/世界 🎬.mkv", "/Media/👩‍👩‍👧‍👦.mkv",
            "/Media/A\u{2028}B.mkv", "/Media/A\u{2029}B.mkv",
        ]
        for path in paths {
            for isDirectory in [false, true] {
                expectOriginalKey(for: URL(fileURLWithPath: path, isDirectory: isDirectory))
            }
            let encoded = try #require(path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed))
            let url = try #require(URL(string: "file://" + encoded))
            expectOriginalKey(for: url)
            let decoded = try JSONDecoder().decode(URL.self, from: JSONEncoder().encode(url))
            expectOriginalKey(for: decoded)
        }
    }

    @Test
    func filePathInitializersKeepDirectoryAndControlCharacterBehavior() {
        let base = URL(fileURLWithPath: "/Media/Base", isDirectory: true)
        for path in [
            "", ".", "..", "/", "//", "///", "/.", "/..",
            "/Media//A.mkv", "/Media/A.mkv/", "/Media/A\\B.mkv",
            "/Media/A\tB.mkv", "/Media/A\nB.mkv",
            "/Media/A\rB.mkv", "/Media/A#B?.mkv", "/Media/100%.mkv",
            "A.mkv", "../A.mkv", "~", "~/A.mkv", "/~user/A.mkv",
        ] {
            for isDirectory in [false, true] {
                // Explicit flags avoid filesystem type queries in fixture creation.
                expectOriginalKey(for: URL(fileURLWithPath: path, isDirectory: isDirectory))
                expectOriginalKey(for: URL(
                    fileURLWithPath: path, isDirectory: isDirectory, relativeTo: base
                ))
            }
        }
    }

    @Test
    func acceptedPercentByteSpellingsRetainOriginalKeys() {
        // URL parsing can reject malformed UTF-8 differently across Foundation
        // versions. Every URL it does construct must preserve the old key bytes.
        for byte in 0...255 {
            let escaped = String(format: "%%%02X", byte)
            for path in [
                "/" + escaped, "/" + escaped + "/A.mkv",
                "/Media/A" + escaped + "B.mkv", "/Media/A.mkv" + escaped,
            ] {
                if let url = URL(string: "file://" + path) {
                    expectOriginalKey(for: url)
                }
            }
        }
    }

    private func expectOriginalKey(for url: URL) {
        // This is the pre-optimization operation. Do not use item.id or
        // representsSameFile: both delegate to the candidate persistenceKey.
        let expected = NormalizedFileURL.normalize(url)?.path
        let actual = NormalizedFileURL.persistenceKey(for: url)
        // String equality permits canonical Unicode equivalence; persistence
        // must also preserve the exact bytes produced by Foundation's round trip.
        #expect(actual.map { Array($0.utf8) } == expected.map { Array($0.utf8) },
                "URL: \(url.absoluteString)")
    }
}

