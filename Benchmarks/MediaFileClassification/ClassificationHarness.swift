import Foundation
import IlliquidCore
#if os(Linux)
import Glibc
#else
import Darwin
#endif

struct Fixture {
    let id: String
    let kind: String
    let urls: [URL]
    let mode: String
}

func makeURLs(count: Int, style: String) -> [URL] {
    let ordinary = ["mkv", "mp4", "srt", "jpg", "mkv", "vtt", "png", "mov", "ass", "mp3"]
    let unsupported = ["jpg", "png", "txt", "nfo", "plexmatch", "json", "zip", "sub", "sup", ""]
    let unicode = ["mKv", "MKV", "İDX", "ıdx", "ſrt", "ｍｋｖ", "s\u{0307}rt", "sr\u{0301}t", "mkv💧", "srt\u{200b}"]
    return (0..<count).map { index in
        let ext: String
        switch style {
        case "uppercase": ext = ordinary[index % ordinary.count].uppercased()
        case "mixedcase":
            let value = ordinary[index % ordinary.count]
            ext = index % 3 == 0 ? value.uppercased() : index % 3 == 1 ? value : String(value.prefix(1)).uppercased() + value.dropFirst()
        case "unicode": ext = unicode[index % unicode.count]
        case "unicode-mixed": ext = index % 4 == 0 ? unicode[(index / 4) % unicode.count] : ordinary[index % ordinary.count]
        case "unsupported": ext = unsupported[index % unsupported.count]
        case "no-extension": ext = ""
        case "long-lowercase": ext = String(repeating: "a", count: 128)
        case "long-uppercase-tail": ext = String(repeating: "a", count: 127) + "A"
        case "long-uppercase": ext = String(repeating: "A", count: 128)
        case "subtitle": ext = ["ass", "idx", "srt", "ssa", "vtt"][index % 5]
        default: ext = ordinary[index % ordinary.count]
        }
        let filename = "Example Series S\(index / 24 + 1)E\(index % 24 + 1) - Episode \(index)" + (ext.isEmpty ? "" : "." + ext)
        if style == "remote" {
            return URL(string: "https://example.invalid/Media/\(index).\(ordinary[index % ordinary.count])")!
        }
        let parent: String
        if style == "unicode-path" || index % 7 == 3 {
            parent = "/Volumes/メディア/Épisodes préférés/日本語シリーズ/シーズン\(index / 24 + 1)/"
        } else {
            parent = "/Volumes/Media/Television/Example Series/Season \(index / 24 + 1)/"
        }
        return URL(fileURLWithPath: parent + filename, isDirectory: false)
    }
}

func fixtures() -> [Fixture] {
    var result: [Fixture] = []
    for count in [1, 24, 1000, 10000] {
        for style in ["lowercase", "mixedcase"] {
            result.append(Fixture(id: "\(style)-\(count)-paired", kind: style, urls: makeURLs(count: count, style: style), mode: "paired"))
        }
    }
    for style in ["uppercase", "unicode", "unicode-mixed", "unicode-path", "unsupported", "no-extension", "subtitle", "remote", "long-lowercase", "long-uppercase", "long-uppercase-tail"] {
        result.append(Fixture(id: "\(style)-1000-paired", kind: style, urls: makeURLs(count: 1000, style: style), mode: "paired"))
    }
    result.append(Fixture(id: "lowercase-1000-shortcircuit", kind: "caller-control", urls: makeURLs(count: 1000, style: "lowercase"), mode: "shortcircuit"))
    result.append(Fixture(id: "mixedcase-1000-shortcircuit", kind: "caller-control", urls: makeURLs(count: 1000, style: "mixedcase"), mode: "shortcircuit"))
    result.append(Fixture(id: "lowercase-1000-mediaonly", kind: "caller-control", urls: makeURLs(count: 1000, style: "lowercase"), mode: "mediaonly"))
    return result
}

struct Receipt: Codable {
    let input: String
    let pathExtension: String
    let isFileURL: Bool
    let media: Bool
    let subtitle: Bool
}

func receipt(_ url: URL) -> Receipt {
    Receipt(input: url.absoluteString, pathExtension: url.pathExtension, isFileURL: url.isFileURL,
            media: MediaFileSupport.isSupportedMediaFile(url), subtitle: MediaFileSupport.isSupportedSubtitleFile(url))
}

func verificationURLs() -> [URL] {
    var extensions: Set<String> = []
    let supported = Array(MediaFileSupport.videoFileExtensions.union(MediaFileSupport.subtitleFileExtensions)).sorted()
    for ext in supported {
        let letters = Array(ext.utf8)
        for mask in 0..<(1 << letters.count) {
            let bytes = letters.enumerated().map { index, byte in
                (mask & (1 << index)) != 0 && byte >= 97 && byte <= 122 ? byte - 32 : byte
            }
            extensions.insert(String(decoding: bytes, as: UTF8.self))
        }
        for addition in (1...31).map({ String(UnicodeScalar($0)!) }) + ["\u{7f}", "K", "ſ", "İ", "ı", "Ｍ", "ｍ", "é", "e\u{301}", "\u{0301}", "\u{200b}", "\u{feff}", "\u{85}", "💧", " ", "\t", "\r", "\n", "\0", ".", "/", "\\", "%", "#", "?"] {
            let scalars = Array(ext.unicodeScalars)
            for offset in 0...scalars.count {
                extensions.insert(String(String.UnicodeScalarView(scalars[..<offset])) + addition + String(String.UnicodeScalarView(scalars[offset...])))
            }
        }
    }
    let alphabet = Array("amkvsrt01_".utf8)
    var prefix: [UInt8] = []
    func enumerate(_ remaining: Int) {
        extensions.insert(String(decoding: prefix, as: UTF8.self))
        guard remaining > 0 else { return }
        for byte in alphabet {
            prefix.append(byte)
            enumerate(remaining - 1)
            prefix.removeLast()
        }
    }
    enumerate(4)
    extensions.formUnion(["mKv", "MKV", "ſrt", "İDX", "ıdx", "ｍｋｖ", "ＭＫＶ", "", "mKv", "M2Ts"])
    for length in [64, 1024, 4096] {
        extensions.insert(String(repeating: "a", count: length))
        extensions.insert(String(repeating: "A", count: length))
        extensions.insert(String(repeating: "a", count: length - 1) + "A")
        extensions.insert(String(repeating: "é", count: length))
    }
    var urls = extensions.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }.enumerated().map { index, ext in
        URL(fileURLWithPath: "/Volumes/Media/Show/Example \(index)." + ext, isDirectory: false)
    }
    // Swift Set equality folds canonical equivalents. Add these representations
    // outside the set so Kelvin-sign spellings cannot disappear behind ASCII K.
    for ext in ["mKv", "MKV", "mKv", "MKV", "s\u{0307}rt", "ṡrt", "e\u{301}", "é"] {
        urls.append(URL(fileURLWithPath: "/tmp/Unicode." + ext, isDirectory: false))
    }
    for source in [
        "file:///tmp/movie.mkv", "file:///tmp/MOVIE.MKV", "file:///tmp/.mkv", "file:///tmp/movie.mkv/",
        "file://localhost/tmp/movie.mkv", "file://remote.invalid/tmp/movie.mkv", "file://user:pass@localhost:23/tmp/movie.mkv",
        "file:///tmp/movie.m%6bv", "file:///tmp/movie.mk%76", "file:///tmp/movie.mkv?x=.txt", "file:///tmp/movie.mkv#fragment.txt",
        "file:///tmp/a/../movie.mkv", "https://example.invalid/movie.mkv", "http://example.invalid/movie.SRT",
        "ftp://example.invalid/movie.mkv", "data:video/mp4;base64,AAAA", "file:///", "file:///tmp/no_extension", "file:///tmp/.hidden", "file:///tmp/movie."
    ] { if let url = URL(string: source) { urls.append(url) } }
    for name in ["Movie.mkv", "Subtitle.SRT", "mKv.mKv", ".mkv", "path.with.dots/Movie.mkv"] {
        urls.append(URL(string: name, relativeTo: URL(fileURLWithPath: "/tmp/base/", isDirectory: true))!)
        urls.append(URL(string: name, relativeTo: URL(string: "https://example.invalid/base/")!)!)
    }
    return urls
}

struct Verification: Codable {
    let schemaVersion: Int
    let caseCount: Int
    let cases: [Receipt]
    let fixtureChecksums: [String: UInt64]
}

@inline(never)
func consume(_ fixture: Fixture) -> UInt64 {
    var checksum: UInt64 = 0
    for (index, url) in fixture.urls.enumerated() {
        let media = MediaFileSupport.isSupportedMediaFile(url)
        let subtitle: Bool
        switch fixture.mode {
        case "shortcircuit": subtitle = !media && MediaFileSupport.isSupportedSubtitleFile(url)
        case "mediaonly": subtitle = false
        default: subtitle = MediaFileSupport.isSupportedSubtitleFile(url)
        }
        checksum &+= UInt64(index + 1) &* (media ? 7 : 1) &+ (subtitle ? 13 : 0)
    }
    return checksum
}

func verify() throws {
    let cases = verificationURLs().map(receipt)
    let checksums = Dictionary(uniqueKeysWithValues: fixtures().map { ($0.id, consume($0)) })
    try output(Verification(schemaVersion: 1, caseCount: cases.count, cases: cases, fixtureChecksums: checksums))
}

func nanoseconds(_ clock: clockid_t) -> UInt64 {
    var value = timespec()
    precondition(clock_gettime(clock, &value) == 0)
    return UInt64(value.tv_sec) * 1_000_000_000 + UInt64(value.tv_nsec)
}

struct Scenario: Codable {
    let id: String
    let files: Int
    let kind: String
    let mode: String
}

struct Observation: Codable {
    let id: String
    let files: Int
    let mode: String
    let iterations: Int
    let wallNs: UInt64
    let cpuNs: UInt64
    let checksum: UInt64
}

func benchmark(_ id: String, iterations: Int) throws {
    guard let fixture = fixtures().first(where: { $0.id == id }), iterations > 0 else { fatalError("unknown fixture or invalid iteration count") }
    let expected = consume(fixture)
    for _ in 0..<8 { precondition(consume(fixture) == expected) }
    var checksum: UInt64 = 0
    let wallStart = nanoseconds(CLOCK_MONOTONIC)
    let cpuStart = nanoseconds(CLOCK_PROCESS_CPUTIME_ID)
    for _ in 0..<iterations {
        #if os(macOS)
        checksum &+= autoreleasepool { consume(fixture) }
        #else
        checksum &+= consume(fixture)
        #endif
    }
    let cpuNs = nanoseconds(CLOCK_PROCESS_CPUTIME_ID) - cpuStart
    let wallNs = nanoseconds(CLOCK_MONOTONIC) - wallStart
    precondition(checksum == expected &* UInt64(iterations))
    try output(Observation(id: fixture.id, files: fixture.urls.count, mode: fixture.mode, iterations: iterations, wallNs: wallNs, cpuNs: cpuNs, checksum: checksum))
}

func output<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    FileHandle.standardOutput.write(try encoder.encode(value))
    FileHandle.standardOutput.write(Data([10]))
}

@main
enum ClassificationBenchmark {
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count > 1 else { fatalError("usage: scenarios | verify | bench <id> <iterations>") }
        switch args[1] {
        case "scenarios": try output(fixtures().map { Scenario(id: $0.id, files: $0.urls.count, kind: $0.kind, mode: $0.mode) })
        case "verify": try verify()
        case "bench":
            guard args.count == 4, let iterations = Int(args[3]) else { fatalError("bench requires id and iterations") }
            try benchmark(args[2], iterations: iterations)
        default: fatalError("unknown command")
        }
    }
}
