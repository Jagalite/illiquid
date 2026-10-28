import Foundation

/// Synthetic inputs shared by the regression suite and benchmark preflight.
/// Construction and lexical normalization do not resolve or open these paths.
enum FileIdentityKeyCorpus {
    struct Entry: Sendable {
        let label: String
        let url: URL?
    }

    static func make() -> [Entry] {
        var result: [Entry] = []
        func add(_ label: String, _ url: URL?) {
            result.append(Entry(label: label, url: url))
        }

        let prefixes = [
            "file:", "file:/", "file:///", "file:////", "file://///",
            "file://localhost/", "file://LOCALHOST/", "FILE://localhost/",
            "file://local%68ost/", "file://localhost./",
            "file://media-server.invalid/", "file://127.0.0.1/", "file://[::1]/",
            "file://user:password@localhost/", "file://@localhost/",
            "file://localhost:0/", "file://localhost:1234/", "https://example.invalid/",
        ]
        let paths = [
            "", ".", "..", "Feature.mkv", "Movies/Feature.mkv",
            "Movies//Feature.mkv", "Movies///Feature.mkv",
            "Movies/./Feature.mkv", "Movies/../Feature.mkv",
            "Movies/../../Feature.mkv", "../Feature.mkv",
            "Movies/.../Feature.mkv", "Movies/.hidden.mkv",
            "Movies/%2e/Feature.mkv", "Movies/%2E%2E/Feature.mkv",
            "Movies/.%2e/Feature.mkv", "Movies/%2e./Feature.mkv",
            "Movies/a%2fb.mkv", "Movies/a%2Fb.mkv",
            "Movies/%2F", "Movies/%2F%2F", "Movies/a%5cb.mkv",
            "Movies/a%5Cb.mkv", "Movies/%252F.mkv", "Movies/%255C.mkv",
            "Movies/%00Feature.mkv", "Movies/a%00b.mkv",
            "Movies/Feature.mkv%00", "Movies/%2500.mkv",
            "Movies/a%01b.mkv", "Movies/a%09b%0Ac%0Dd.mkv",
            "Movies/space%20name.mkv", "Movies/a+b.mkv", "Movies/a%25b.mkv",
            "Movies/%3F%23%26%3B%3A%40.mkv",
            "Movies/Caf%C3%A9.mkv", "Movies/Cafe%CC%81.mkv",
            "Movies/%EA%B0%80.mkv", "Movies/%E1%84%80%E1%85%A1.mkv",
            "Movies/%F0%9F%8E%AC.mkv", "Movies/%EF%BC%8F.mkv",
            "Movies/%E2%88%95.mkv", "Movies/%E2%81%84.mkv",
            "Movies/%", "Movies/%0", "Movies/%GG", "Movies/%FF",
            "Movies/%C0%AF", "Movies/%ED%A0%80", "Movies/%F4%90%80%80",
        ]
        let suffixes = [
            "", "/", "//", "?download=1", "#chapter",
            "?download=1#chapter", "?x=%2F%00%25#section",
        ]
        for (p, prefix) in prefixes.enumerated() {
            for (n, path) in paths.enumerated() {
                for (s, suffix) in suffixes.enumerated() {
                    let raw = prefix + path + suffix
                    add("URL.string[\(p),\(n),\(s)] \(String(reflecting: raw))",
                        URL(string: raw))
                    add("NSURL.string[\(p),\(n),\(s)] \(String(reflecting: raw))",
                        NSURL(string: raw).map { $0 as URL })
                }
            }
        }

        let roots = ["/", "//", "///", "/tmp/", "/tmp//", "/tmp/../tmp/", "/Volumes/Media Share/"]
        let names = [
            "Feature.mkv", "folder/Feature.mkv", "./Feature.mkv", "../Feature.mkv",
            ".", "..", "...", "a b#c?d%e.mkv", "a+b.mkv", "a\\b.mkv",
            "%2F.mkv", "%00.mkv", "a\u{0000}b.mkv", "\u{0000}Feature.mkv",
            "Feature.mkv\u{0000}", "\tline\nreturn\r.mkv",
            "Caf\u{00E9}.mkv", "Cafe\u{0301}.mkv", "\u{AC00}.mkv",
            "\u{1100}\u{1161}.mkv", "\u{FF0F}.mkv", "\u{2215}.mkv",
            "\u{2044}.mkv", "👩🏽‍💻.mkv",
        ]
        for (r, root) in roots.enumerated() {
            for (n, name) in names.enumerated() {
                for suffix in ["", "/", "//"] {
                    let path = root + name + suffix
                    for directory in [false, true] {
                        let label = "[\(r),\(n),\(directory)] \(String(reflecting: path))"
                        add("URL.file\(label)", URL(fileURLWithPath: path, isDirectory: directory))
                        add("NSURL.file\(label)", NSURL(fileURLWithPath: path, isDirectory: directory) as URL)
                    }
                }
            }
        }

        let localBase = URL(fileURLWithPath: "/Movies/", isDirectory: true)
        let bases: [(String, URL?)] = [
            ("local-directory", localBase),
            ("local-file", URL(fileURLWithPath: "/Movies/Base.mkv", isDirectory: false)),
            ("localhost", URL(string: "file://LOCALHOST/Movies/")),
            ("remote", URL(string: "file://media-server.invalid/Movies/")),
            ("credentialed", URL(string: "file://user:password@localhost/Movies/")),
            ("https", URL(string: "https://example.invalid/Movies/")),
            ("nested-relative", URL(string: "Season%201/", relativeTo: localBase)),
        ]
        let references = [
            "", ".", "..", "Feature.mkv", "./Feature.mkv", "../Feature.mkv",
            "../../../Feature.mkv", "/Other/Feature.mkv",
            "//localhost/Other/Feature.mkv", "//media-server.invalid/Other/Feature.mkv",
            "a%2Fb.mkv", "a%00b.mkv", "Caf%C3%A9.mkv", "Cafe%CC%81.mkv",
            "?download=1", "#chapter", "?download=1#chapter",
        ]
        for (name, optionalBase) in bases {
            add("base \(name)", optionalBase)
            guard let base = optionalBase else { continue }
            for reference in references {
                add("relative[\(name)] \(String(reflecting: reference))",
                    URL(string: reference, relativeTo: base))
            }
        }
        for reference in [
            "Feature.mkv", "./Feature.mkv", "../Feature.mkv", "../Other//Feature.mkv",
            "Caf\u{00E9}.mkv", "Cafe\u{0301}.mkv", "a%2Fb.mkv", "a#b?c.mkv", "a\u{0000}b.mkv",
        ] {
            for directory in [false, true] {
                add("relative-file[\(directory)] \(String(reflecting: reference))",
                    URL(fileURLWithPath: reference, isDirectory: directory, relativeTo: localBase))
            }
        }
        return result
    }
}
