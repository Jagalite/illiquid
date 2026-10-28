import Foundation

/// Shared by the package regressions and the separately compiled component driver.
/// Cases retain constructor failures so a platform cannot silently shrink coverage.
struct NormalizedFileURLCase {
    let id: String
    let construction: String
    let input: String
    let base: String?
    let url: URL?
}

enum NormalizedFileURLCorpus {
    static func make() -> [NormalizedFileURLCase] {
        var result: [NormalizedFileURLCase] = []

        func append(_ construction: String, input: String, base: String?, url: URL?) {
            result.append(.init(
                id: "\(result.count):\(construction)",
                construction: construction,
                input: input,
                base: base,
                url: url
            ))
        }

        func strings(_ input: String, relativeTo base: URL? = nil, label: String? = nil) {
            append(
                "URL(string:relativeTo:)",
                input: input, base: label,
                url: URL(string: input, relativeTo: base)
            )
            if base == nil {
                append(
                    "URL(string:encodingInvalidCharacters:false)",
                    input: input, base: label,
                    url: URL(string: input, encodingInvalidCharacters: false)
                )
            }
            append(
                "NSURL(string:relativeTo:)",
                input: input, base: label,
                url: NSURL(string: input, relativeTo: base).map { $0 as URL }
            )
        }

        func filePaths(_ input: String, relativeTo base: URL? = nil, label: String? = nil) {
            for isDirectory in [false, true] {
                append(
                    "URL(fileURLWithPath:isDirectory:\(isDirectory):relativeTo:)",
                    input: input, base: label,
                    url: URL(fileURLWithPath: input, isDirectory: isDirectory, relativeTo: base)
                )
                append(
                    "NSURL(fileURLWithPath:isDirectory:\(isDirectory):relativeTo:)",
                    input: input, base: label,
                    url: NSURL(fileURLWithPath: input, isDirectory: isDirectory, relativeTo: base) as URL
                )
            }
        }

        // URL spellings deliberately include raw characters, encoded separators,
        // double encoding and canonical-equivalent Unicode representations.
        let urlComponents = [
            "Feature.mkv", "space name.mkv", "space%20name.mkv",
            "literal%25.mkv", ".", "..", "~", "~user",
            "%2e", "%2E%2e", "a%2Fb.mkv", "a%2fb.mkv", "a%252Fb.mkv",
            "a%00b.mkv", "a%2500b.mkv", "a%23b.mkv", "a%3Fb.mkv",
            "a+b;mkv", "a:b@c&d=e.mkv", "a\\b.mkv",
            "Caf\u{00E9}.mkv", "Cafe\u{0301}.mkv",
            "Caf%C3%A9.mkv", "Cafe%CC%81.mkv", "世界.mkv", "🎬.mkv",
        ]
        for prefix in ["file://", "file://localhost", "file://LOCALHOST", "file:"] {
            for directory in ["/Movies/", "/Movies/Season/../"] {
                for component in urlComponents {
                    for suffix in ["", "?ignored=%2F#chapter"] {
                        strings(prefix + directory + component + suffix)
                    }
                }
            }
        }

        // Explicit file-path construction encodes ?, # and % as filename bytes,
        // unlike the same characters supplied as URL components.
        let pathComponents = [
            "Feature.mkv", "space name.mkv", "a?b#c%.mkv", "a%2Fb.mkv",
            "a+b;mkv", "a:b@c&d=e.mkv", "a\\b.mkv", ".", "..", "~", "~user",
            "Caf\u{00E9}.mkv", "Cafe\u{0301}.mkv",
            "\u{212B}ngstrom.mkv", "A\u{030A}ngstrom.mkv",
            "\u{AC00}.mkv", "\u{1100}\u{1161}.mkv",
            "\u{2126}.mkv", "\u{F900}.mkv", "世界.mkv", "🎬.mkv",
            "line\nbreak.mkv", "tab\tname.mkv",
        ]
        for directory in ["/Movies/", "/Movies/Season/../", "/Movies//"] {
            for component in pathComponents {
                filePaths(directory + component)
                filePaths(directory + component + "///")
            }
        }

        // Retain slash spelling and root-boundary edge cases explicitly.
        let specialStrings = [
            "", "file:", "file://", "file://localhost", "file:relative.mkv", "file:~",
            "file:/", "file:///", "file:////", "file://///", "file://localhost/",
            "file:///.", "file:///..", "file:///../", "file:///../../",
            "file:///a/.", "file:///a/..", "file:///a/../..",
            "file:///a//b///", "file:////a///b/", "file:///a/%2e/b",
            "file:///a/%2E%2E/b", "file:///%2F", "file:///%2f",
            "file:///%252F", "file:///%00", "file:///%2500",
            "file:///a.mkv?x=1", "file:///a.mkv#chapter",
            "file:///a%3Fb%23c%25.mkv", "file:///~", "file:///~user",
            "FILE:///Movies/Feature.mkv", "file:///Movies/a\tb.mkv",
            "file:///Movies/a\nb.mkv", "file:///Movies/a\u{0}b.mkv",
            "file:///Movies/a%zz.mkv", "file:///Movies/a%.mkv",
            "file:///Movies/%FF.mkv", "file:///Movies/%C0%AF.mkv",
            "http://[", "http://[invalid]/", "://",
            "https://example.invalid/Feature.mkv", "data:text/plain,Feature.mkv",
            "ftp://example.invalid/Feature.mkv",
            "file://media-server.example/Movies/Feature.mkv",
            "file://localhost.example/Movies/Feature.mkv",
            "file://localhost./Movies/Feature.mkv",
            "file://127.0.0.1/Movies/Feature.mkv",
            "file://[::1]/Movies/Feature.mkv",
            "file://user@localhost/Movies/Feature.mkv",
            "file://user:secret@localhost/Movies/Feature.mkv",
            "file://localhost:1234/Movies/Feature.mkv",
            "file://localhost:0/Movies/Feature.mkv",
            "file://@localhost/Movies/Feature.mkv",
            "file://localhost:/Movies/Feature.mkv",
        ]
        for input in specialStrings { strings(input) }
        for path in ["/", "//", "///", "/.", "/..", "/a//b", "/a/../b", "/~", "/~user"] {
            filePaths(path)
        }

        // The synthetic zero IDs require no created file-reference URL or
        // privileged fixture. Standardization/decoding can expose this namespace
        // only after the original URL constructor has examined its spelling.
        for input in [
            "file:///.file/id=0.0",
            "file:///%2Efile/id=0.0",
            "file:///.file/%69d=0.0",
            "file:///.file/id%3D0.0",
            "file:///safe/../.file/id=0.0",
            "file:////.file/id=0.0",
            "file:///.file/id=0.0/child",
            "file:///.file/id=not-a-reference",
        ] {
            strings(input)
        }

        let relativeInputs = [
            "", "Feature.mkv", "./Feature.mkv", "../Feature.mkv", "../../",
            "/", "/Movies/Feature.mkv", "//localhost/Movies/Feature.mkv",
            "//media-server.example/Movies/Feature.mkv",
            "~", "~user/Feature.mkv", "a%2Fb.mkv", "a%252Fb.mkv",
            "a%00b.mkv", "a%23b%3Fc.mkv", "a?query#fragment",
            "?query", "#fragment", "Caf\u{00E9}.mkv", "Cafe\u{0301}.mkv",
            "file:relative.mkv", "https://example.invalid/Feature.mkv",
        ]
        let baseSpellings = [
            "file:///Movies/Season/",
            "file:///Movies/Season/Feature.mkv",
            "file://LOCALHOST/Movies/Season/",
            "file:///Movies/a%3Fb%23c%25/",
            "file:///Movies/Caf%C3%A9/",
            "file://media-server.example/Movies/",
            "file://user:secret@localhost/Movies/",
            "file://localhost:1234/Movies/",
            "https://example.invalid/Movies/",
        ]
        for spelling in baseSpellings {
            let base = URL(string: spelling)
            for input in relativeInputs {
                // A missing base remains an explicit failed construction record.
                if let base {
                    strings(input, relativeTo: base, label: spelling)
                } else {
                    append("unavailable-base", input: input, base: spelling, url: nil)
                }
            }
        }

        // Empty/relative file paths always have an explicit base so the corpus
        // does not depend on the working directory or the current user's home.
        let pathBases = [
            "/Movies/Season/", "/Movies/a?b#c%/", "/Movies/Caf\u{00E9}/",
        ]
        let relativePaths = [
            "", ".", "..", "Feature.mkv", "./Feature.mkv", "../Feature.mkv",
            "a?b#c%.mkv", "a%2Fb.mkv", "a//b///",
            "Caf\u{00E9}.mkv", "Cafe\u{0301}.mkv",
        ]
        for path in pathBases {
            let base = URL(fileURLWithPath: path, isDirectory: true)
            for input in relativePaths {
                filePaths(input, relativeTo: base, label: path)
            }
        }

        // File-path constructors can treat embedded and trailing controls
        // differently from URL-string parsing. Retain both spellings.
        let controlSpellings = [
            ("\u{0}", "%00"), ("\u{1}", "%01"), ("\t", "%09"),
            ("\n", "%0A"), ("\r", "%0D"), ("\u{1F}", "%1F"),
            ("\u{7F}", "%7F"),
        ]
        for (literal, encoded) in controlSpellings {
            filePaths("/Movies/a" + literal + "b.mkv")
            filePaths("/Movies/Feature.mkv" + literal)
            strings("file:///Movies/a" + encoded + "b.mkv")
            strings("file:///Movies/Feature.mkv" + encoded)
        }
        filePaths("/Movies/Feature.mkv\u{0}\u{0}")
        for input in [
            "file:///Movies/%2E%2E/Season/%2E%2E/Feature.mkv",
            "file:///Movies%2FSeason%2F..%2FFeature.mkv",
            "file:///Movies/%2F///Feature.mkv//",
            "file:///%2FMovies/Feature.mkv",
            "file:///Movies/.hidden/Feature.mkv",
            "file:///Movies/%2Ehidden/Feature.mkv",
            "file:///Movies/Feature.mkv;version=1",
            "file:///Movies/Feature.mkv%3Bversion=1?query=ignored#fragment",
        ] {
            strings(input)
        }

        return result
    }
}
