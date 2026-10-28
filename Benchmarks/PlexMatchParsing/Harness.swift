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
    let text: String
    let paths: [String]
    let mappingPaths: Int

    var episodeDirectives: Int {
        text.split(whereSeparator: \.isNewline).filter {
            let line = $0.trimmingCharacters(in: .whitespaces).lowercased()
            return line.hasPrefix("ep:") || line.hasPrefix("episode:")
        }.count
    }
}

func fixtures() -> [Fixture] {
    let header = "title: Example Series\nyear: 2024\nseason: 7\ntvdbid: 12345\n"
    var result = [
        Fixture(id: "empty", kind: "control", text: "", paths: ["missing.mkv"], mappingPaths: 0),
        Fixture(id: "metadata-only", kind: "control", text: header, paths: ["missing.mkv"], mappingPaths: 0),
    ]
    for count in [1, 24, 256, 2000] {
        let paths = (0..<count).map { "Episode \($0 + 1).mkv" }
        let lines = paths.enumerated().map { "ep: S02E\($0.offset + 1): \($0.element)" }
        result.append(Fixture(id: "mappings-\(count)", kind: "ascii", text: header + lines.joined(separator: "\n"), paths: paths, mappingPaths: count))
    }
    for (id, kind, count) in [
        ("mixed-24", "mixed", 24),
        ("mixed-256", "mixed", 256),
        ("mixed-2000", "mixed", 2000),
        ("mixed-unicode-256", "mixed-unicode", 256),
        ("unicode-token-256", "unicode-token", 256),
        ("unicode-path-256", "unicode-path", 256),
        ("invalid-256", "invalid", 256),
        ("duplicates-256", "duplicates", 256),
    ] {
        var paths: [String] = []
        var lines: [String] = []
        for index in 0..<count {
            let first = index * 2 + 1
            let path = kind == "unicode-path"
                ? "Saison é/日本語 第\(index + 1)話 🐈.mkv"
                : "Episode \(index + 1).mkv"
            paths.append(path)
            let token: String
            switch kind {
            case "unicode-token": token = index.isMultiple(of: 2) ? "ſ02E\(first)-ſ02E\(first + 1)" : "ſP\(first)"
            case "mixed-unicode" where index.isMultiple(of: 3): token = "ſ02E\(first)-ſ02E\(first + 1)"
            case "invalid":
                token = ["S0000E1", "E10000", "S01E2-S02E3", "E1-S01E2", "SP2-E1", "S1E2 ", "sE1", "E1--E2"][index % 8]
            default:
                switch index % 8 {
                case 0: token = "\(first)"
                case 1: token = "e\(first)"
                case 2: token = "Sp\(first)"
                case 3: token = "S02e\(first)"
                case 4: token = "\(first)-\(first + 1)"
                case 5: token = "E\(first)-e\(first + 1)"
                case 6: token = "s02E\(first)-S002E\(first + 1)"
                default: token = "sp\(first)-S0e\(first + 1)"
                }
            }
            if kind == "duplicates" {
                lines.append("ep: S02E1-E2: \(path)")
            }
            lines.append("ep: \(token): \(path)")
            if kind == "duplicates" {
                lines.append("ep: S02E99999: \(path)")
            }
        }
        result.append(Fixture(id: id, kind: kind, text: header + lines.joined(separator: "\n"), paths: paths, mappingPaths: count))
        if kind == "invalid" {
            result.append(Fixture(id: "invalid-only-256", kind: "invalid-control", text: lines.joined(separator: "\n"), paths: paths, mappingPaths: count))
        }
    }
    var nearLimit = header
    var nearLimitPaths: [String] = []
    for index in 1...9999 {
        let path = "Episode \(index).mkv"
        let line = "ep: S02E\(index): \(path)\n"
        guard nearLimit.utf8.count + line.utf8.count < 128 * 1024 else { break }
        nearLimit += line
        nearLimitPaths.append(path)
    }
    nearLimit += "#" + String(repeating: "x", count: 128 * 1024 - nearLimit.utf8.count - 1)
    result.append(Fixture(id: "mappings-limit-128KiB", kind: "ascii-limit", text: nearLimit, paths: nearLimitPaths, mappingPaths: nearLimitPaths.count))
    result.append(Fixture(id: "long-invalid", kind: "control", text: header + "ep: " + String(repeating: "S", count: 4000) + ": file.mkv", paths: ["file.mkv"], mappingPaths: 1))
    result.append(Fixture(id: "oversize", kind: "control", text: String(repeating: "#", count: 128 * 1024 + 1), paths: ["missing.mkv"], mappingPaths: 0))
    return result
}

struct HintReceipt: Codable {
    let content: String?
    let title: String?
    let year: Int?
    let season: Int?
    let episode: Int?
    let lastEpisode: Int?
    let episodeTitle: String?
    let catalogIDs: [String]
    let sources: [String]

    private enum CodingKeys: String, CodingKey {
        case content, title, year, season, episode, lastEpisode, episodeTitle, catalogIDs, sources
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(content, forKey: .content)
        try values.encode(title, forKey: .title)
        try values.encode(year, forKey: .year)
        try values.encode(season, forKey: .season)
        try values.encode(episode, forKey: .episode)
        try values.encode(lastEpisode, forKey: .lastEpisode)
        try values.encode(episodeTitle, forKey: .episodeTitle)
        try values.encode(catalogIDs, forKey: .catalogIDs)
        try values.encode(sources, forKey: .sources)
    }

    init(_ hints: MediaMetadataHints) {
        switch hints.content {
        case .movie: content = "movie"
        case .show: content = "show"
        case .episode: content = "episode"
        case nil: content = nil
        }
        title = hints.title
        year = hints.year
        season = hints.season
        episode = hints.episode
        lastEpisode = hints.lastEpisode
        episodeTitle = hints.episodeTitle
        catalogIDs = hints.catalogIDs
        sources = hints.sources
    }
}

struct TokenReceipt: Codable {
    let token: String
    let direct: HintReceipt?
    let inherited: HintReceipt
    let duplicate: HintReceipt
}

struct LookupReceipt: Codable {
    let path: String
    let inherits: Bool
    let defaultSeason: Int?
    let hint: HintReceipt?
}

struct DocumentReceipt: Codable {
    let id: String
    let metadata: HintReceipt?
    let lookups: [LookupReceipt]
}

struct Verification: Codable {
    let schemaVersion: Int
    let tokenCount: Int
    let tokens: [TokenReceipt]
    let documents: [DocumentReceipt]
}

func tokenCorpus() -> [String] {
    var values: Set<String> = []
    // Exhaustive strings through five characters over a compact grammar alphabet.
    let alphabet: [UInt8] = Array("SsPEe-01".utf8)
    var prefix: [UInt8] = []
    func enumerate(_ remaining: Int) {
        values.insert(String(decoding: prefix, as: UTF8.self))
        guard remaining > 0 else { return }
        for byte in alphabet {
            prefix.append(byte)
            enumerate(remaining - 1)
            prefix.removeLast()
        }
    }
    enumerate(5)
    let numbers = ["0", "1", "2", "9", "00", "01", "99", "000", "001", "999", "0000", "0001", "9999", "00000", "10000"]
    let starts = ["", "E", "e", "SP", "Sp", "sP", "sp", "S0E", "s00e", "S1E", "S01e", "s999E", "S0000E", "ſ01E", "ſP"]
    let ends = ["", "E", "e", "S0E", "s00e", "S1E", "s01E", "S2E", "S999E", "S0000E", "ſ01E"]
    for start in starts {
        for first in numbers {
            values.insert(start + first)
            for end in ends {
                for last in numbers { values.insert(start + first + "-" + end + last) }
            }
        }
    }
    let seeds = ["1", "E01", "SP01", "S01E02", "S01E02-E04", "S01E02-S01E04", "SP01-S0E02", "ſ01E02", "ſP01"]
    let insertions = [" ", "\t", "\0", "\u{b}", "\u{c}", ":", "+", "_", ".", "/", "\\", "\u{a0}", "\u{0301}", "\u{0307}", "\u{200b}", "\u{feff}", "Ｓ", "Ｅ", "Ｐ", "ſ", "１", "١", "𝟙", "१", "১", "۱", "๑", "១", "💧"]
    for seed in seeds {
        let scalars = Array(seed.unicodeScalars)
        for index in 0...scalars.count {
            for insertion in insertions {
                values.insert(String(String.UnicodeScalarView(scalars[..<index])) + insertion + String(String.UnicodeScalarView(scalars[index...])))
            }
        }
        for terminator in ["\n", "\r", "\r\n", "\u{b}", "\u{c}", "\u{85}", "\u{2028}", "\u{2029}", "\n\n"] {
            values.insert(seed + terminator)
            values.insert(terminator + seed)
        }
    }
    for length in [18, 19, 20, 21, 22, 64, 4090, 4096, 4097] {
        values.insert(String(repeating: "S", count: length))
        values.insert(String(repeating: "0", count: length))
    }
    // Deterministic literal ordering, independent of Set hash seed and locale.
    return values.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
}

func verify() throws {
    let tokens = tokenCorpus().map { token -> TokenReceipt in
        let direct = PlexMatchHints.parse("ep: \(token): file.mkv")?.hints(for: "file.mkv")
        let inherited = PlexMatchHints.parse("title: Série\nseason: 7\nep: \(token): file.mkv")!.hints(for: "file.mkv", defaultSeason: 9)
        let duplicate = PlexMatchHints.parse("title: Série\nep: S02E03-E05: file.mkv\nep: \(token): file.mkv")!.hints(for: "file.mkv")
        return TokenReceipt(token: token, direct: direct.map(HintReceipt.init), inherited: HintReceipt(inherited), duplicate: HintReceipt(duplicate))
    }
    var documents = fixtures()
    documents.append(Fixture(id: "scope-unicode-duplicates", kind: "validation", text: "\u{feff}title: 東京\r\nseason: 0\nEP: S00E00-E01: Résumé.mkv\nepisode: S02E3: Re\u{301}sume\u{301}.mkv\nep: E3-E5: nested/file.mkv\nep: S2E4-S3E5: nested/file.mkv\nguid: tvdb://123\n", paths: ["Résumé.mkv", "Re\u{301}sume\u{301}.mkv", "nested/file.mkv", "file.mkv", "missing.mkv"], mappingPaths: 4))
    let receipts = documents.map { fixture -> DocumentReceipt in
        let parsed = PlexMatchHints.parse(fixture.text)
        var lookups: [LookupReceipt] = []
        for path in fixture.paths + ["missing.mkv"] {
            for inherits in [false, true] {
                for defaultSeason: Int? in [nil, 0, 9] {
                    let hint = parsed?.hints(for: path, inheritsDescendantMappings: inherits, defaultSeason: defaultSeason)
                    lookups.append(LookupReceipt(path: path, inherits: inherits, defaultSeason: defaultSeason, hint: hint.map(HintReceipt.init)))
                }
            }
        }
        return DocumentReceipt(id: fixture.id, metadata: parsed.map { HintReceipt($0.metadata) }, lookups: lookups)
    }
    try output(Verification(schemaVersion: 1, tokenCount: tokens.count, tokens: tokens, documents: receipts))
}

func nanoseconds(_ clock: clockid_t) -> UInt64 {
    var value = timespec()
    precondition(clock_gettime(clock, &value) == 0)
    return UInt64(value.tv_sec) * 1_000_000_000 + UInt64(value.tv_nsec)
}

@inline(never)
func consume(_ fixture: Fixture) -> UInt64 {
    guard let parsed = PlexMatchHints.parse(fixture.text) else { return 17 }
    let hint = parsed.hints(for: fixture.paths.last ?? "missing.mkv")
    return UInt64(hint.season ?? 1001) &* 1_000_003
        &+ UInt64(hint.episode ?? 10001) &* 1_009
        &+ UInt64(hint.lastEpisode ?? 10001) &* 17
        &+ UInt64(hint.title?.utf8.count ?? 0)
        &+ UInt64(hint.catalogIDs.count) &* 31
        &+ UInt64(hint.sources.count) &* 131
}

struct Scenario: Codable {
    let id: String
    let inputBytes: Int
    let mappingPaths: Int
    let episodeDirectives: Int
    let kind: String
}

struct Observation: Codable {
    let id: String
    let inputBytes: Int
    let mappingPaths: Int
    let episodeDirectives: Int
    let iterations: Int
    let wallNs: UInt64
    let cpuNs: UInt64
    let checksum: UInt64
}

func benchmark(_ id: String, iterations: Int) throws {
    guard let fixture = fixtures().first(where: { $0.id == id }), iterations > 0 else {
        fatalError("unknown fixture or invalid iteration count")
    }
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
    try output(Observation(id: fixture.id, inputBytes: fixture.text.utf8.count, mappingPaths: fixture.mappingPaths, episodeDirectives: fixture.episodeDirectives, iterations: iterations, wallNs: wallNs, cpuNs: cpuNs, checksum: checksum))
}

func output<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    FileHandle.standardOutput.write(try encoder.encode(value))
    FileHandle.standardOutput.write(Data([10]))
}

@main
enum PlexMatchParsingBenchmark {
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count > 1 else { fatalError("usage: scenarios | verify | bench <id> <iterations>") }
        switch args[1] {
        case "scenarios": try output(fixtures().map { Scenario(id: $0.id, inputBytes: $0.text.utf8.count, mappingPaths: $0.mappingPaths, episodeDirectives: $0.episodeDirectives, kind: $0.kind) })
        case "verify": try verify()
        case "bench":
            guard args.count == 4, let iterations = Int(args[3]) else { fatalError("bench requires id and iterations") }
            try benchmark(args[2], iterations: iterations)
        default: fatalError("unknown command")
        }
    }
}
