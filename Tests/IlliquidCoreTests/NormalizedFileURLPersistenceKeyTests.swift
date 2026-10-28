import Foundation
import Testing
@testable import IlliquidCore

@Suite("Normalized persistence key reconstruction")
struct NormalizedFileURLPersistenceKeyTests {
    private func bytes(_ value: String?) -> [UInt8]? {
        value.map { Array($0.utf8) }
    }

    private func expectReconstructionParity(_ url: URL, context: String) {
        // String equality accepts canonically equivalent Unicode. Persistent
        // key bytes must also match the previous URL reconstruction exactly.
        let expected = NormalizedFileURL.normalize(url)?.path
        let actual = NormalizedFileURL.persistenceKey(for: url)
        #expect(bytes(actual) == bytes(expected), "\(context)")
    }

    @Test("Ordinary ASCII identities retain their exact canonical paths")
    func explicitASCIIIdentities() throws {
        let cases: [(String, String)] = [
            ("file:///Media/Episode%2001.mkv", "/Media/Episode 01.mkv"),
            ("file:///Media/./Season/../Feature.mkv", "/Media/Feature.mkv"),
            ("file://LOCALHOST/Media/Feature.mkv", "/Media/Feature.mkv"),
            ("file:///Media/Percent%25%20%23%3F.mkv", "/Media/Percent% #?.mkv"),
            ("file:///Media/Feature.mkv?query=yes#chapter", "/Media/Feature.mkv"),
            ("file:///Media/", "/Media"),
            ("file:///", "/"),
        ]
        for (input, expected) in cases {
            let url = try #require(URL(string: input))
            #expect(bytes(NormalizedFileURL.persistenceKey(for: url)) == Array(expected.utf8), "\(input)")
            expectReconstructionParity(url, context: input)
        }
    }

    @Test("Encoded bytes and unusual ASCII paths retain reconstruction behavior")
    func encodedAndUnusualASCIIPaths() throws {
        let paths = [
            "/", "//", "///", "/Media", "/Media/", "/Media//", "/Media///",
            "//Media/Feature.mkv", "/Media//Feature.mkv", "/Media/./Feature.mkv",
            "/Media/Season/../Feature.mkv", "/Media/..", "/Media/.", "/../", "/../../",
            "/Media/%2F.mkv", "/Media/%2f.mkv", "/Media/%252F.mkv",
            "/Media/%2E/Feature.mkv", "/Media/%2E%2E/Feature.mkv",
            "/Media/%00.mkv", "/Media/%00", "/Media/%2500.mkv",
            "/Media/%09tab.mkv", "/Media/%0Aline.mkv", "/Media/%0Dreturn.mkv",
            "/Media/%7Fdelete.mkv", "/Media/%20spaces%20.mkv",
            "/Media/colon:semi;at@.mkv", "/Media/%5Cbackslash.mkv",
            "/Media/hash%23question%3Fpercent%25.mkv",
            "/Media/%FF.mkv", "/Media/%C0%AF.mkv",
        ]
        for authority in ["file://", "file://localhost", "file://LOCALHOST"] {
            for path in paths {
                for tail in ["", "?q=%2F#part", "#fragment"] {
                    let input = authority + path + tail
                    let url = try #require(URL(string: input))
                    expectReconstructionParity(url, context: input)
                }
            }
        }
    }

    @Test("File-path constructors preserve directory hints and literal punctuation")
    func filePathConstructorCorpus() {
        let prefixes = ["/", "/Media/", "/Media//", "//Media/", "/Media/./", "/Media/Season/../"]
        let names = [
            "Episode 01", "100%", "literal%2F", "hash#question?", "colon:semi;at@",
            "back\\slash", "[brackets]", "line\nbreak", "tab\tname", "nul\u{0}name",
            ".", "..", "", "trailing ",
        ]
        for prefix in prefixes {
            for name in names {
                for suffix in ["", ".mkv", "/", "//"] {
                    for isDirectory in [false, true] {
                        let path = prefix + name + suffix
                        let url = URL(fileURLWithPath: path, isDirectory: isDirectory)
                        expectReconstructionParity(url, context: "path=\(path.debugDescription), directory=\(isDirectory)")
                    }
                }
            }
        }
    }

    @Test("Unicode keys preserve platform filesystem-normalization bytes")
    func unicodeReconstructionBytes() throws {
        let names = [
            "Caf\u{00E9}", "Cafe\u{0301}", "\u{00C5}ngstrom", "A\u{030A}ngstrom",
            "\u{212B}ngstrom", "\u{2126}mega", "\u{212A}elvin", "\u{F900}",
            "\u{AC00}", "\u{1100}\u{1161}", "東京", "العربية", "שָׁלוֹם",
            "👩🏽‍🚀", "e\u{0301}\u{0327}", "a\u{0344}", "ＡＢＣ",
        ]
        for name in names {
            for suffix in [".mkv", "/", "//", "%2F.mkv", "\u{0}.mkv"] {
                let path = "/Media/" + name + suffix
                for isDirectory in [false, true] {
                    let url = URL(fileURLWithPath: path, isDirectory: isDirectory)
                    expectReconstructionParity(url, context: "Unicode path=\(path.debugDescription), directory=\(isDirectory)")
                }
            }
            // A URL-string input need not have gone through Darwin's file-path
            // constructor. Exercise composed/decomposed inputs independently.
            var components = URLComponents()
            components.scheme = "file"
            components.host = "localhost"
            components.path = "/Media/" + name + ".mkv"
            let url = try #require(components.url)
            expectReconstructionParity(url, context: "components=\(name)")
        }
    }

    @Test("Relative references validate the resolved authority and retain path bytes")
    func relativeReferences() throws {
        let bases = [
            "file:///Media/", "file://localhost/Media/", "file:///Media/Season/../",
            "file:///Media/Caf%C3%A9/", "file:///Media/hash%23question%3F/",
            "file://server.example/Media/", "file://user@localhost/Media/",
            "file://localhost:1234/Media/", "https://example.invalid/Media/",
        ]
        let references = [
            "Episode%2001.mkv", "../Feature.mkv", "./Feature.mkv", "/Other/Feature.mkv",
            "Caf%C3%A9.mkv", "Cafe%CC%81.mkv", "%2F.mkv", "%00.mkv",
            "//localhost/Media/Feature.mkv", "//server.example/Media/Feature.mkv",
            "?q=yes", "#fragment",
        ]
        for base in bases {
            let baseURL = try #require(URL(string: base))
            for reference in references {
                let url = try #require(URL(string: reference, relativeTo: baseURL))
                expectReconstructionParity(url, context: "base=\(base), reference=\(reference)")
            }
        }
    }

    @Test("Invalid local authorities and unsupported schemes remain rejected")
    func invalidIdentities() throws {
        let inputs = [
            "file://server.example/Media/Feature.mkv", "file://localhost.example/Media/Feature.mkv",
            "file://127.0.0.1/Media/Feature.mkv", "file://[::1]/Media/Feature.mkv",
            "file://user@localhost/Media/Feature.mkv", "file://user:secret@localhost/Media/Feature.mkv",
            "file://localhost:1234/Media/Feature.mkv", "file://localhost:0/Media/Feature.mkv",
            "file:relative.mkv", "file:", "file://", "file://localhost",
            "https://example.invalid/Feature.mkv", "ftp://example.invalid/Feature.mkv",
        ]
        for input in inputs {
            let url = try #require(URL(string: input))
            #expect(NormalizedFileURL.persistenceKey(for: url) == nil, "\(input)")
            expectReconstructionParity(url, context: input)
        }
    }

    @Test("Paths exposed as Darwin file references retain constructor behavior")
    func fileReferenceShapedPaths() throws {
        let inputs = [
            "file:///.file/id=0.0", "file:///.file/id=0.0/",
            "file:///temporary/../.file/id=0.0",
            "file://localhost/temporary/../.file/id=0.0",
            "file:///%2Efile/id=0.0", "file:///.file/%69d=0.0",
            "file:///.file/id%3D0.0", "file:////.file/id=0.0",
        ]
        for input in inputs {
            let url = try #require(URL(string: input))
            expectReconstructionParity(url, context: input)
        }
    }
}
