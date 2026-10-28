import Foundation
import Testing
@testable import IlliquidCore

@Suite("File persistence key byte compatibility")
struct FileIdentityByteQualificationTests {
    // normalize is deliberately unchanged by the optimization. Compare bytes:
    // String equality alone would accept different Unicode representations.
    private func expectOriginalBytes(_ url: URL) {
        let expected = NormalizedFileURL.normalize(url)?.path.mapBytes
        let actual = NormalizedFileURL.persistenceKey(for: url)?.mapBytes
        #expect(actual == expected, "URL: \(url.absoluteString)")
    }

    @Test func pathConstructorsPreserveSpecialFormsAndUnicode() {
        let paths = [
            "/", "//", "///", "/tmp", "/tmp/", "/tmp//", "/tmp///",
            "//tmp/Film.mkv", "/tmp//Season///Film.mkv",
            "/tmp/./Film.mkv", "/tmp/Season/../Film.mkv",
            "/tmp/../../Film.mkv", "/tmp/..", "/tmp/../",
            "/tmp/~", "/tmp/~/Film.mkv", "/tmp/100% complete.mkv",
            "/tmp/%2F%2E%25.mkv", "/tmp/Film #1?.mkv",
            "/tmp/a:b;c=d&e+f.mkv", "/tmp/back\\slash.mkv",
            "/tmp/\tfilm\n.mkv",
            "/tmp/Caf\u{00E9}.mkv", "/tmp/Cafe\u{0301}.mkv",
            "/tmp/A\u{030A}land/\u{65E5}\u{672C}\u{8A9E}.mkv",
            "/tmp/\u{1F3AC}\u{FE0F}/\u{AC00}.mkv",
            "/tmp/\u{1100}\u{1161}/\u{212A}.mkv",
            "/.file/id=1.2", "/.file/id=1.2/",
            "/.file/id=not-a-real-reference",
            "/tmp/../.file/id=not-a-real-reference",
            "/tmp/.file/id=ordinary-filename",
        ]
        for path in paths {
            for directory in [false, true] {
                expectOriginalBytes(URL(fileURLWithPath: path, isDirectory: directory))
                expectOriginalBytes(NSURL(fileURLWithPath: path, isDirectory: directory) as URL)
            }
        }
    }

    @Test func everyAsciiByteAndItsPercentEncodingPreserveKeyBytes() throws {
        for value in 0..<128 {
            let scalar = try #require(UnicodeScalar(value))
            let text = String(scalar)
            // NUL is not a valid filesystem path component. Exercise it via
            // percent-encoded URL strings below, avoiding invalid NSURL objects.
            if value != 0 {
                for directory in [false, true] {
                    expectOriginalBytes(URL(fileURLWithPath: "/tmp/A\(text)Z.mkv", isDirectory: directory))
                    expectOriginalBytes(NSURL(fileURLWithPath: "/tmp/A\(text)Z.mkv", isDirectory: directory) as URL)
                }
            }
            let hex = String(value, radix: 16, uppercase: true)
            let escape = "%" + (hex.count == 1 ? "0" : "") + hex
            for encoded in [
                "file:///tmp/A\(escape)Z.mkv",
                "file:///tmp/A%25\(hex)Z.mkv",
                "file://LOCALHOST/tmp/A\(escape)Z.mkv/",
            ] {
                expectOriginalBytes(try #require(URL(string: encoded)))
                if let bridged = NSURL(string: encoded) { expectOriginalBytes(bridged as URL) }
            }
        }
    }

    @Test func relativeReferencesAndAuthoritiesKeepTheOriginalContract() throws {
        let bases = try [
            "file:///Movies/Season/",
            "file:///Movies/Season.mkv",
            "file://LOCALHOST/Movies/Season/",
            "file:////Movies//Season/",
            "file://archive.example.invalid/Movies/Season/",
            "file://user:password@localhost/Movies/Season/",
            "https://example.invalid/Movies/Season/",
        ].map { try #require(URL(string: $0)) }
        let references = [
            "", ".", "..", "../", "../../", "../../../",
            "Episode.mkv", "./Episode.mkv", "../Episode.mkv",
            "Season/../Episode%202.mkv", "/Movies/./Episode.mkv",
            "?edition=1", "#chapter", "Episode.mkv?edition=1#chapter",
            "A%2FB.mkv", "A%252FB.mkv", "%2E/%2E%2E/Episode.mkv",
            "Cafe%CC%81.mkv", "Caf%C3%A9.mkv",
            "/.file/id=not-a-real-reference",
            "/%2Efile/id%3Dnot-a-real-reference",
        ]
        for base in bases {
            for reference in references {
                // Foundation versions differ on accepting an empty relative
                // reference. Compare every URL that can actually be constructed.
                if let url = URL(string: reference, relativeTo: base) {
                    expectOriginalBytes(url)
                } else {
                    #expect(reference.isEmpty)
                }
                if let bridged = NSURL(string: reference, relativeTo: base) {
                    expectOriginalBytes(bridged as URL)
                }
            }
        }
        for raw in [
            "file://media.example.invalid/Movies/Film.mkv",
            "file://localhost.example/Movies/Film.mkv",
            "file://127.0.0.1/Movies/Film.mkv",
            "file://[::1]/Movies/Film.mkv",
            "file://user@localhost/Movies/Film.mkv",
            "file://user:password@localhost/Movies/Film.mkv",
            "file://localhost:0/Movies/Film.mkv",
            "file://localhost:1234/Movies/Film.mkv",
            "file:relative.mkv", "file:", "file://", "file://localhost",
            "https://example.invalid/Film.mkv", "ftp://example.invalid/Film.mkv",
        ] {
            let url = try #require(URL(string: raw))
            #expect(NormalizedFileURL.persistenceKey(for: url) == nil)
            expectOriginalBytes(url)
        }
    }

    @Test func deterministicPathCombinationsMatchByBytes() throws {
        let prefixes = ["file:///", "file:/", "file://localhost/", "file://LOCALHOST/", "file:////"]
        let segments = [
            "Movies", "Movies/Season/..", "Movies//Season",
            "Movies/./Season", "Movies/../Movies", "Movies/../../Movies",
            "Movies/%2E/Season", "Movies/%2E%2E/Movies",
            "Media%20Share", "100%25", "A%2FB", "A%252FB",
            "Caf%C3%A9", "Cafe%CC%81", "%E6%97%A5%E6%9C%AC",
        ]
        let filenames = [
            "Episode.mkv", "Episode%202.mkv", "A%23B%3F.mkv",
            "A%00B.mkv", "A%5CB.mkv", "%7E.mkv", ".", "..", "",
        ]
        let suffixes = ["", "/", "//", "?copy=1#chapter"]
        for prefix in prefixes {
            for segment in segments {
                for filename in filenames {
                    for suffix in suffixes {
                        let raw = prefix + segment + "/" + filename + suffix
                        expectOriginalBytes(try #require(URL(string: raw)))
                        if let bridged = NSURL(string: raw) { expectOriginalBytes(bridged as URL) }
                    }
                }
            }
        }
    }
}

private extension String {
    var mapBytes: [UInt8] { Array(utf8) }
}
