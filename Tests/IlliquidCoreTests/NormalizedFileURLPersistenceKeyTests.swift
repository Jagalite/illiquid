import Foundation
import Testing
@testable import IlliquidCore

@Suite("Persistence key representation")
struct NormalizedFileURLPersistenceKeyTests {
    private func expectReference(_ url: URL, context: String) {
        let expected = NormalizedFileURL.normalize(url)?.path
        let actual = NormalizedFileURL.persistenceKey(for: url)
        // String equality hides canonically equivalent UTF-8 representations.
        // Persisted keys must retain Foundation's actual output bytes too.
        let expectedBytes = expected.map { Array($0.utf8) }
        let actualBytes = actual.map { Array($0.utf8) }
        #expect(actualBytes == expectedBytes, "\(context): \(url.absoluteString)")
    }

    @Test func preservesKnownLocalKeys() throws {
        let cases: [(input: String, key: String)] = [
            ("file:///Media/Film.mkv", "/Media/Film.mkv"),
            ("file:/Media/Film.mkv", "/Media/Film.mkv"),
            ("file://localhost/Media/Film.mkv", "/Media/Film.mkv"),
            ("file://LOCALHOST/Media/Film.mkv", "/Media/Film.mkv"),
            ("file:///Media/Season/../Film.mkv", "/Media/Film.mkv"),
            ("file:///Media/Film%20%231.mkv", "/Media/Film #1.mkv"),
            ("file:///Volumes/Media%20Share/Film.mkv", "/Volumes/Media Share/Film.mkv"),
            ("file:///", "/"),
        ]
        for item in cases {
            let url = try #require(URL(string: item.input))
            #expect(NormalizedFileURL.persistenceKey(for: url) == item.key)
            expectReference(url, context: item.input)
        }
    }

    @Test func rejectsUnsupportedLocalIdentities() throws {
        let spellings = [
            "https://example.invalid/Media/Film.mkv",
            "http://example.invalid/Media/Film.mkv",
            "ftp://example.invalid/Media/Film.mkv",
            "file://media-server.example/Media/Film.mkv",
            "file://localhost.example/Media/Film.mkv",
            "file://127.0.0.1/Media/Film.mkv",
            "file://[::1]/Media/Film.mkv",
            "file://user@localhost/Media/Film.mkv",
            "file://user:example@localhost/Media/Film.mkv",
            "file://localhost:1234/Media/Film.mkv",
            "file://localhost:0/Media/Film.mkv",
            "file:relative.mkv", "file:", "file://", "file://localhost",
        ]
        for spelling in spellings {
            let url = try #require(URL(string: spelling))
            #expect(NormalizedFileURL.persistenceKey(for: url) == nil)
            expectReference(url, context: spelling)
        }
    }

    @Test func preservesEveryPrintableASCIICharacter() throws {
        for code in 0x20...0x7e {
            let character = String(try #require(UnicodeScalar(code)))
            let path = "/Media/before\(character)after.mkv"
            for isDirectory in [false, true] {
                let url = URL(fileURLWithPath: path, isDirectory: isDirectory)
                expectReference(url, context: "ASCII \(code), directory \(isDirectory)")
            }
        }
    }

    @Test func preservesASCIIPunctuationCombinations() {
        let pieces = [
            "A", "0", " ", ".", "..", "/", "//", "\\", "%", "%2F",
            "%00", ";", ":", "?", "#", "[", "]", "@", "&", "'",
            "(", ")", "+", "=", "-", "_", "~",
        ]
        for (leftIndex, left) in pieces.enumerated() {
            for (rightIndex, right) in pieces.enumerated() {
                let path = "/Media/before\(left)\(right)after.mkv"
                expectReference(URL(fileURLWithPath: path, isDirectory: false),
                                context: "ASCII pair \(leftIndex),\(rightIndex)")
            }
        }
    }

    @Test func preservesPathShapeAndDirectoryHints() throws {
        let paths = [
            "/", "//", "///", "/Media", "/Media/", "/Media//",
            "/Media/./Film.mkv", "/Media/../Film.mkv", "/../../Film.mkv",
            "/Media//Season///Film.mkv", "/Media/.", "/Media/..",
            "/Media/./..", "/Media/../", "/Media/%2F", "/Media/%00",
            "/Media/back\\slash.mkv", "/Media/a;b.mkv",
            "/.file/not-a-reference", "/Media/../.file/not-a-reference",
            "/.file/id-not-a-reference", "/Media/.file/ordinary.mkv",
        ]
        for path in paths {
            for isDirectory in [false, true] {
                expectReference(URL(fileURLWithPath: path, isDirectory: isDirectory),
                                context: "Path \(path), directory \(isDirectory)")
            }
            let url = try #require(URL(string: "file://" + path))
            expectReference(url, context: "URL path \(path)")
        }
        // Do not create /.file/id=... inputs here: Foundation can resolve
        // those as real file references. The production fallback preserves
        // that behavior without making this corpus depend on filesystem IDs.
    }

    @Test func preservesPercentEncodingAndMalformedPathBytes() throws {
        let spellings = [
            "file:///Media/a%2Fb.mkv", "file:///Media/a%2fb.mkv",
            "file:///Media/a%252Fb.mkv", "file:///Media/a%252fb.mkv",
            "file:///Media/a%00b.mkv", "file:///Media/a%2500b.mkv",
            "file:///Media/%2E/Film.mkv", "file:///Media/%2e%2E/Film.mkv",
            "file:///Media/.%2e/Film.mkv", "file:///Media/%2E./Film.mkv",
            "file:///Media/%2e", "file:///Media/%2E%2e",
            "file:///Media/%252E/Film.mkv", "file:///Media/%25%2525.mkv",
            "file:///Media/%20%23%3F%3B%3A%5C.mkv",
            "file:///Media/Film.mkv?query=value#fragment",
            "file:///Media/Film.mkv;parameter",
            "file:///Media/%FF.mkv", "file:///Media/%C3%28.mkv",
            "file:///Media/%ED%A0%80.mkv", "file:///Media/%F0%80%80%80.mkv",
            "file:///%2Efile/not-a-reference",
            "file:///Media/../%2Efile/not-a-reference",
            "FILE:///Media/Film.mkv",
        ]
        for spelling in spellings {
            let url = try #require(URL(string: spelling))
            expectReference(url, context: spelling)
        }
    }

    @Test func preservesEncodedASCIIIncludingControlCharacters() throws {
        for code in 0...127 {
            let hexadecimal = String(code, radix: 16, uppercase: true)
            let escaped = "%" + (hexadecimal.count == 1 ? "0" : "") + hexadecimal
            let spellings = [
                "file:///Media/before\(escaped)after.mkv",
                "file:///Media/before\(escaped).mkv",
                "file:///Media/\(escaped)",
            ]
            for spelling in spellings {
                let url = try #require(URL(string: spelling))
                expectReference(url, context: "Encoded ASCII \(code)")
            }
        }
    }

    @Test func preservesUnicodeRepresentationByteForByte() throws {
        let names = [
            "Caf\u{00e9}", "Cafe\u{0301}",
            "\u{00c5}ngstr\u{00f6}m", "A\u{030a}ngstro\u{0308}m",
            "\u{212b}", "\u{2126}", "\u{212a}",
            "\u{00e9}\u{0323}", "e\u{0323}\u{0301}",
            "\u{ac00}", "\u{1100}\u{1161}",
            "日本語", "العربية", "क\u{093c}", "😀", "\u{1d160}",
            "Film\u{200d}Name", "Film\u{2028}Name", "Film\u{feff}Name",
        ]
        for (index, name) in names.enumerated() {
            let path = "/Media/\(name).mkv"
            for isDirectory in [false, true] {
                expectReference(URL(fileURLWithPath: path, isDirectory: isDirectory),
                                context: "Unicode \(index), directory \(isDirectory)")
            }
            let url = try #require(URL(string: "file://" + path))
            expectReference(url, context: "Unicode URL \(index)")
        }
    }

    @Test func preservesLongPathsAndUnicodeAtBothEnds() {
        let prefix = "/" + String(repeating: "Long directory/", count: 64)
        for path in [
            prefix + "Film.mkv",
            "/Caf\u{00e9}" + prefix + "Film.mkv",
            prefix + "Cafe\u{0301}.mkv",
            prefix + "%2F%00.mkv",
            prefix + "Film\u{0000}Name.mkv",
        ] {
            expectReference(URL(fileURLWithPath: path, isDirectory: false),
                            context: "Long path")
        }
    }

    @Test func resolvesRelativeReferencesAgainstTheirActualBases() throws {
        let bases = [
            "file:///Media/Season/", "file:///Media/Season",
            "file://localhost/Media/Season/",
            "file://LOCALHOST/Media/Season/",
            "file:///Media/Cafe%CC%81/",
            "file://media-server.example/Media/Season/",
            "file://user@localhost/Media/Season/",
            "file://localhost:1234/Media/Season/",
            "https://example.invalid/Media/Season/",
        ]
        let references = [
            "Film.mkv", "./Film.mkv", "../Film.mkv",
            "Child/../Film.mkv", "/Media/Film.mkv",
            ".", "..", "?query=value", "#fragment",
            "%2E%2E/Film.mkv", "Caf%C3%A9.mkv", "Cafe%CC%81.mkv",
        ]
        for baseSpelling in bases {
            let base = try #require(URL(string: baseSpelling))
            for reference in references {
                let url = try #require(URL(string: reference, relativeTo: base))
                expectReference(url, context: "\(reference) relative to \(baseSpelling)")
            }
        }
    }
}
