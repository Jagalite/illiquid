import Foundation
import URLBaseline
import URLCandidate
#if os(macOS)
import CoreFoundation
#endif

struct Fixture {
    let label: String
    let url: URL
}

func fixtures() -> [Fixture] {
    var cases: [Fixture] = []
    func add(_ label: String, _ value: @autoclosure () -> URL?) {
        if let url = value() { cases.append(Fixture(label: label, url: url)) }
    }
    let components = [
        "tmp", "Media", "Movie.mkv", "", ".", "..", "~", "~user", "Caf\u{E9}", "Cafe\u{301}",
        "\u{212B}", "A\u{30A}", "東京", "🎬", "e\u{301}\u{301}", "a\\b", "a\0b", "\0", "a\nb", "a\tb", ":", ";",
        "100% complete #2?.mkv", "%2F", "%2f", "%2E", "%2e", "%2E%2E", "%2e%2e", "%2E.", ".%2E",
        "%252F", "%252E", "%252E%252E", "%00", "%2500", "%41", "%C3%A9", "%CC%81", "%FF", "%C0%AF",
        "%", "%GG", "%F0%9F%8E%AC", "file:", ".file", "id=6571367.2773272"
    ]
    let paths = ["", "/", "//", "///", "/tmp", "/tmp/", "/tmp//", "/tmp///", "/tmp///movie", "//tmp/movie",
                 "/tmp/../", "/tmp/.//", "/../", "/.file/id=6571367.2773272", "/.file/id=6571367.2773272/",
                 "/.file/id=0.0", "/dev/fd/0", "/Volumes/External Media/Show/../Episode 1.mkv"]
    for (i, path) in paths.enumerated() {
        for isDirectory in [false, true] {
            add("literal-path-\(i)-\(isDirectory)", URL(fileURLWithPath: path, isDirectory: isDirectory))
            // Linux's legacy NSURL bridge traps while constructing an empty
            // path. The Swift URL initializer above still covers empty input;
            // do not turn an unrelated fixture-construction trap into a key test.
            if !path.isEmpty { add("bridged-path-\(i)-\(isDirectory)", NSURL(fileURLWithPath: path, isDirectory: isDirectory) as URL) }
        }
    }
    for byte in 0...31 {
        let control = String(UnicodeScalar(byte)!)
        for suffix in ["", "/", "?query=1#part"] {
            let input = "/tmp/control-" + control + "-movie.mkv" + suffix
            add("control-path-\(byte)-\(suffix)", URL(fileURLWithPath: input, isDirectory: false))
            add("control-url-\(byte)-\(suffix)", URL(string: "file://" + input))
        }
    }
    add("delete-control-path", URL(fileURLWithPath: "/tmp/a\u{7F}b.mkv", isDirectory: false))
    for spelling in [
        "file:///%2Efile/id=6571367.2773272",
        "file:///.%66ile/id=6571367.2773272",
        "file:///%2E%66ile/id=6571367.2773272",
        "file:///%252Efile/id=6571367.2773272",
        "file://localhost/%2Efile/id=6571367.2773272",
    ] {
        add("encoded-reference-\(spelling)", URL(string: spelling))
    }
    let origins = ["file:", "file:/", "file://", "file:///", "FILE:///", "file:////", "file://///",
                   "file://localhost/", "file://LOCALHOST/", "file://LocalHost/", "file://localhost./",
                   "file://archive.example/", "file://127.0.0.1/", "file://[::1]/", "file://user@localhost/",
                   "file://user:example@localhost/", "file://@localhost/", "file://localhost:1234/", "file://localhost:0/",
                   "file://localhost:/", "file://localhost:65536/", "file://%6cocalhost/", "file://localhost%2e/",
                   "https://localhost/", "http://example.invalid/", "ftp://example.invalid/", "", "/", "//"]
    let suffixes = ["", "/", "//", "///", "?copy=1", "#part", "?copy=1#part", "/?copy=1#part", "/../movie.mkv"]
    for (o, origin) in origins.enumerated() {
        for (c, component) in components.enumerated() {
            for (s, suffix) in suffixes.enumerated() {
                let input = origin + "tmp/" + component + suffix
                add("raw-\(o)-\(c)-\(s)", URL(string: input))
                add("bridged-raw-\(o)-\(c)-\(s)", NSURL(string: input) as URL?)
            }
        }
    }
    for (c, component) in components.enumerated() {
        for separator in ["/", "//", "///"] {
            for trailing in ["", "/", "//", "/.", "/.."] {
                let path = "/tmp" + separator + component + trailing
                for isDirectory in [false, true] {
                    add("constructed-\(c)-\(separator.count)-\(trailing)-\(isDirectory)",
                        URL(fileURLWithPath: path, isDirectory: isDirectory))
                }
            }
        }
    }
    let baseStrings = ["file:///tmp/Media/", "file:///tmp/Media", "file://localhost/tmp/Media/",
                       "file://remote.example/tmp/Media/", "file://user@localhost/tmp/Media/",
                       "file://localhost:1234/tmp/Media/", "https://example.invalid/media/",
                       "file:///tmp/%2E%2E/Media/", "file:////tmp/Media/", "/tmp/Media/", "relative/"]
    for (b, string) in baseStrings.enumerated() {
        guard let base = URL(string: string) else { continue }
        for (c, component) in components.enumerated() {
            for prefix in ["", "./", "../", "../../", "/", "//", "///"] {
                for suffix in ["", "/", "//", "?copy=1#part"] {
                    let relative = prefix + component + suffix
                    add("relative-\(b)-\(c)-\(prefix)-\(suffix)", URL(string: relative, relativeTo: base))
                }
            }
        }
    }
    let nestedBase = URL(string: "Nested/../Nested/", relativeTo: URL(fileURLWithPath: "/tmp/Media/", isDirectory: true))!
    let inheritedRemote = URL(string: "Nested/", relativeTo: URL(string: "file://archive.example/Media/")!)!
    let fileBases: [URL?] = [nil] + baseStrings.map { URL(string: $0) } + [nestedBase, inheritedRemote]
    for (b, base) in fileBases.enumerated() {
        for (c, component) in components.enumerated() {
            for prefix in ["", "./", "../", "../../", "/", "//", "///"] {
                for isDirectory in [false, true] {
                    let relative = prefix + component
                    add("file-relative-\(b)-\(c)-\(prefix)-\(isDirectory)",
                        URL(fileURLWithPath: relative, isDirectory: isDirectory, relativeTo: base))
                }
            }
        }
    }
    // Deterministic mixed paths stress double percent decoding, canonical
    // composition, slash compression and absolute-base resolution together.
    var seed: UInt64 = 0xF11E_1028_CAFE_6655
    func next(_ bound: Int) -> Int {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return Int((seed >> 32) % UInt64(bound))
    }
    for iteration in 0..<30_000 {
        let origin = origins[next(origins.count)]
        var input = origin
        for _ in 0..<(next(6) + 1) {
            input += components[next(components.count)]
            input += ["/", "//", "///"][next(3)]
        }
        input += components[next(components.count)] + suffixes[next(suffixes.count)]
        let base = URL(string: baseStrings[next(baseStrings.count)])
        add("mixed-\(iteration)", URL(string: input, relativeTo: iteration.isMultiple(of: 2) ? base : nil))
    }
    return cases
}

@main
struct Differential {
    static func main() throws {
        let cases = fixtures()
        var mismatchCount = 0
        var rejected = 0
        var checked = 0
        var nativeReferenceCases = 0
        var examples: [[String: Any]] = []
        func check(_ item: Fixture) {
            let index = checked
            checked += 1
            let baseline = URLBaseline.NormalizedFileURL.persistenceKey(for: item.url)
            let candidate = URLCandidate.NormalizedFileURL.persistenceKey(for: item.url)
            if baseline == nil { rejected += 1 }
            let equal: Bool
            switch (baseline, candidate) {
            case (nil, nil): equal = true
            case let (lhs?, rhs?): equal = lhs.utf8.elementsEqual(rhs.utf8)
            default: equal = false
            }
            if !equal {
                mismatchCount += 1
                if examples.count < 80 {
                    examples.append([
                        "index": index, "label": item.label,
                        "url": item.url.absoluteString,
                        "path": item.url.path,
                        "lexicalPath": item.url.absoluteURL.standardized.path,
                        "directory": item.url.absoluteURL.standardized.hasDirectoryPath,
                        "baseline": baseline as Any? ?? NSNull(),
                        "candidate": candidate as Any? ?? NSNull(),
                    ])
                }
            }
        }
        for item in cases { check(item) }
        #if os(macOS)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("IlliquidURLReferences-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for directory in [false, true] {
            let original = root.appendingPathComponent(directory ? "Original folder" : "Original.mkv", isDirectory: directory)
            let renamed = root.appendingPathComponent(directory ? "Renamed Caf\u{E9} folder" : "Renamed Cafe\u{301}.mkv", isDirectory: directory)
            if directory {
                try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
            } else {
                try Data("fixture".utf8).write(to: original)
            }
            // Preserve the actual file-reference spelling as well as the
            // NSURL API's bridged value: Swift URL bridging can eagerly
            // convert a reference URL into its current path URL.
            guard let objcReference = (original as NSURL).fileReferenceURL(),
                  let cfReference = CFURLCreateFileReferenceURL(kCFAllocatorDefault, original as CFURL, nil),
                  let rawReferenceString = CFURLGetString(cfReference) else {
                throw NSError(domain: "IlliquidURLKeyResearch", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Could not create a native file reference fixture"])
            }
            precondition(CFURLIsFileReferenceURL(cfReference))
            let referenceSpelling = rawReferenceString as String
            func compareReferences(_ phase: String) throws {
                guard let rawReference = URL(string: referenceSpelling) else {
                    throw NSError(domain: "IlliquidURLKeyResearch", code: 2)
                }
                check(Fixture(label: "native-reference-\(directory)-\(phase)-raw", url: rawReference))
                check(Fixture(label: "native-reference-\(directory)-\(phase)-objc", url: objcReference))
                nativeReferenceCases += 2
            }
            try compareReferences("before-rename")
            try FileManager.default.moveItem(at: original, to: renamed)
            try compareReferences("after-rename")
        }
        #endif
        let output: [String: Any] = ["cases": checked, "rejected": rejected,
                                     "nativeReferenceCases": nativeReferenceCases,
                                     "mismatches": mismatchCount, "examples": examples]
        let data = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys, .prettyPrinted])
        print(String(decoding: data, as: UTF8.self))
        if mismatchCount != 0 { exit(1) }
    }
}
