import Foundation
import Dispatch

// Full production NFOMetadataHints.parse(Data) calls. All input construction,
// receipt serialization and JSON encoding take place outside the timer.
private struct Fixture {
    let name: String
    let data: Data
}

private struct MetadataReceipt: Encodable {
    let content: String?
    let title: String?
    let year: Int?
    let season: Int?
    let episode: Int?
    let lastEpisode: Int?
    let episodeTitle: String?
    let catalogIDs: [String]
    let sources: [String]

    init(_ value: MediaMetadataHints) {
        switch value.content {
        case .some(.movie): content = "movie"
        case .some(.show): content = "show"
        case .some(.episode): content = "episode"
        case .none: content = nil
        }
        title = value.title
        year = value.year
        season = value.season
        episode = value.episode
        lastEpisode = value.lastEpisode
        episodeTitle = value.episodeTitle
        catalogIDs = value.catalogIDs
        sources = value.sources
    }

    private enum CodingKeys: String, CodingKey {
        case content, title, year, season, episode, lastEpisode, episodeTitle, catalogIDs, sources
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        // encode(Optional) preserves explicit JSON nulls for every missing field.
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
}

private struct OutputReceipt: Encodable {
    let caseName: String
    let inputBytes: Int
    let result: MetadataReceipt?

    private enum CodingKeys: String, CodingKey {
        case caseName = "case"
        case inputBytes, result
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(caseName, forKey: .caseName)
        try values.encode(inputBytes, forKey: .inputBytes)
        try values.encode(result, forKey: .result)
    }
}

private struct DifferentialReport: Encodable {
    let schemaVersion = 1
    let mode = "differential"
    let caseCount: Int
    let cases: [OutputReceipt]
}

private struct BenchmarkReport: Encodable {
    let schemaVersion = 1
    let mode = "benchmark"
    let caseName: String
    let iterations: Int
    let warmupIterations: Int
    let elapsedNanoseconds: UInt64
    let checksum: UInt64
    let warmupChecksum: UInt64
    let perIterationChecksum: UInt64
    let receipt: OutputReceipt

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, mode
        case caseName = "case"
        case iterations, warmupIterations, elapsedNanoseconds, checksum
        case warmupChecksum, perIterationChecksum, receipt
    }
}

private enum DriverError: Error {
    case invalidArguments(String)
    case unexpectedResult(String)
}

private func fixture(_ name: String, _ xml: String) -> Fixture {
    Fixture(name: name, data: Data(xml.utf8))
}

private func movie(_ title: String) -> String {
    "<movie><title>" + title + "</title></movie>"
}

private let benchmarkNames = [
    "movie-small", "episode-small", "unicode-small", "ascii-boundary-4096",
    "ascii-fragmented-4096", "unicode-fragmented-4095-bytes", "unicode-fallback-2500",
    "combining-cdata", "ignored-long-plot", "ascii-over-limit-4097",
    "malformed-xml", "doctype-rejected",
]

private func benchmarkFixture(_ name: String) throws -> Fixture {
    switch name {
    case "movie-small":
        return fixture(name, """
            <?xml version="1.0" encoding="UTF-8"?>
            <movie><title>Arrival</title><year>2016</year><uniqueid type="imdb">tt2543164</uniqueid><plot>A linguist works with visitors to understand their language.</plot></movie>
            """)
    case "episode-small":
        return fixture(name, "<episodedetails><title>Diversity Day</title><showtitle>The Office</showtitle><season>1</season><episode>2</episode><uniqueid type=\"tvdb\">123456</uniqueid></episodedetails>")
    case "unicode-small":
        return fixture(name, "<episodedetails><title>今日の話題 — Café</title><showtitle>世界のニュース</showtitle><season>1</season><episode>24</episode></episodedetails>")
    case "ascii-boundary-4096":
        return fixture(name, movie(String(repeating: "A", count: 4096)))
    case "ascii-fragmented-4096":
        return fixture(name, movie(String(repeating: "A&amp;", count: 2048)))
    case "unicode-fragmented-4095-bytes":
        // Each decoded pair has three UTF-8 bytes and two Characters.
        return fixture(name, movie(String(repeating: "é&amp;", count: 1365)))
    case "unicode-fallback-2500":
        return fixture(name, movie(String(repeating: "界", count: 2500)))
    case "combining-cdata":
        return fixture(name, movie(String(repeating: "e<![CDATA[\u{0301}]]>", count: 800)))
    case "ignored-long-plot":
        return fixture(name, "<movie><title>Long plot control</title><plot>"
                       + String(repeating: "P", count: 100_000) + "</plot></movie>")
    case "ascii-over-limit-4097":
        return fixture(name, movie(String(repeating: "A", count: 4097)))
    case "malformed-xml":
        return fixture(name, "<movie><title>Arrival</title><year>2016</movie>")
    case "doctype-rejected":
        return fixture(name, "<!DOCTYPE movie [<!ENTITY title \"Injected\">]><movie><title>&title;</title></movie>")
    default:
        throw DriverError.invalidArguments("Unknown case: \(name). Cases: \(benchmarkNames.joined(separator: ", "))")
    }
}

// Consume scalars and collection counts without adding a title-length scan to
// the operation being researched. Every field and its exact String value is
// checked separately in complete untimed receipts.
@inline(never)
private func consume(_ value: MediaMetadataHints?) -> UInt64 {
    guard let value else { return 1 }
    var checksum: UInt64 = 7
    checksum &+= UInt64(value.catalogIDs.count) &* 31
    checksum &+= UInt64(value.sources.count) &* 37
    checksum &+= UInt64(value.year ?? 0)
    checksum &+= UInt64(value.season ?? 0) &* 41
    checksum &+= UInt64(value.episode ?? 0) &* 43
    checksum &+= UInt64(value.lastEpisode ?? 0) &* 47
    if value.title != nil { checksum &+= 53 }
    if value.episodeTitle != nil { checksum &+= 59 }
    return checksum
}

@inline(never)
private func parseOnce(_ input: Data) -> UInt64 {
    let value = NFOMetadataHints.parse(input)
    return consume(value)
}

private func runIterations(_ input: Data, iterations: Int) -> UInt64 {
    var checksum: UInt64 = 0
    for _ in 0..<iterations { checksum &+= parseOnce(input) }
    return checksum
}

private func evaluate(_ input: Fixture) -> (receipt: OutputReceipt, signature: UInt64) {
    let value = NFOMetadataHints.parse(input.data)
    return (
        OutputReceipt(caseName: input.name, inputBytes: input.data.count,
                      result: value.map(MetadataReceipt.init)),
        consume(value)
    )
}

private func documentWithByteCount(_ count: Int) -> String {
    let prefix = "<movie><title>Document byte boundary</title><plot>"
    let suffix = "</plot></movie>"
    return prefix + String(repeating: "P", count: count - prefix.utf8.count - suffix.utf8.count) + suffix
}

private func differentialFixtures() throws -> [Fixture] {
    var result = try benchmarkNames.map(benchmarkFixture)
    let lengths = [0, 1, 2, 4094, 4095, 4096, 4097, 4098]
    for length in lengths {
        let plain = String(repeating: "A", count: length)
        let bodies: [(String, String)] = [
            ("ascii", plain),
            ("unicode", String(repeating: "界", count: length)),
            ("combining-text", String(repeating: "e\u{0301}", count: length)),
            ("entity-fragments", String(repeating: "&amp;", count: length)),
            ("cdata-fragments", String(repeating: "<![CDATA[A]]>", count: length)),
            // The old limit counts the existing String and incoming chunk
            // separately. Appending can merge graphemes across that boundary.
            ("combining-tail", String(repeating: "e", count: length) + "<![CDATA[\u{0301}]]>"),
            ("crlf-boundary", plain + "&#13;<![CDATA[\n]]>"),
            ("regional-boundary", plain + "🇨<![CDATA[🇦]]>"),
            ("zwj-boundary", plain + "👩<![CDATA[\u{200d}]]>💻"),
        ]
        for (style, body) in bodies {
            result.append(fixture("limit-\(style)-\(length)", movie(body)))
        }
    }

    for length in [4095, 4096, 4097] {
        let ascii = String(repeating: "A", count: length)
        let digits = String(repeating: "9", count: length)
        result.append(fixture("show-title-\(length)", "<tvshow><title>" + ascii + "</title></tvshow>"))
        result.append(fixture("episode-title-\(length)", "<episodedetails><title>" + ascii + "</title></episodedetails>"))
        result.append(fixture("showtitle-\(length)", "<episodedetails><showtitle>" + ascii + "</showtitle></episodedetails>"))
        result.append(fixture("year-\(length)", "<movie><title>Known</title><year>" + digits + "</year></movie>"))
        result.append(fixture("season-\(length)", "<episodedetails><title>Known</title><season>" + digits + "</season></episodedetails>"))
        result.append(fixture("episode-\(length)", "<episodedetails><title>Known</title><episode>" + digits + "</episode></episodedetails>"))
        result.append(fixture("uniqueid-\(length)", "<movie><title>Known</title><uniqueid type=\"tmdb\">" + digits + "</uniqueid></movie>"))
    }

    let longIgnored = String(repeating: "Ignored", count: 2000)
    result += [
        fixture("empty-document", ""),
        fixture("empty-root", "<movie/>"),
        fixture("unsupported-root", "<metadata><title>Known</title></metadata>"),
        fixture("empty-title", movie("")),
        fixture("whitespace-title", movie(" \n\t ")),
        fixture("title-trimming", movie("  A &amp; B \n")),
        fixture("bom-document", "\u{feff}" + movie("BOM title")),
        fixture("all-movie-fields", "<movie><title>Known</title><year>2004</year><uniqueid type=\"imdb\">TT123</uniqueid><uniqueid type=\"tmdb\">456</uniqueid></movie>"),
        fixture("all-episode-fields", "<episodedetails><title>Episode title</title><showtitle>Series title</showtitle><season>0</season><episode>12</episode><uniqueid type=\"tvdb\">789</uniqueid></episodedetails>"),
        fixture("ignored-episode-year", "<episodedetails><title>Known</title><year>" + longIgnored + "</year></episodedetails>"),
        fixture("ignored-show-counts", "<tvshow><title>Known</title><season>" + longIgnored + "</season><episode>" + longIgnored + "</episode></tvshow>"),
        fixture("ignored-movie-showtitle", "<movie><title>Known</title><showtitle>" + longIgnored + "</showtitle></movie>"),
        fixture("nested-ignored-title", "<movie><title>Before<nested>" + longIgnored + "</nested>After</title></movie>"),
        fixture("nested-identification-field", "<movie><actor><title>Ignored</title></actor><title>Known</title></movie>"),
        fixture("truncated-after-value", "<movie><title>Known</title>"),
        fixture("trailing-garbage", movie("Known") + "garbage"),
        fixture("unknown-entity", movie("&missing;")),
        fixture("declaration-in-comment", "<!-- <!DOCTYPE movie> -->" + movie("Known")),
        fixture("entity-declaration-in-cdata", movie("<![CDATA[<!ENTITY value>]]>")),
        fixture("mixed-case-doctype", "<!DoCtYpE movie>" + movie("Known")),
        fixture("cdata-and-text-order", "<movie><title>Before<![CDATA[ & Middle ]]>&amp; After</title></movie>"),
        fixture("multiple-title-values", "<movie><title>First</title><title>Second</title></movie>"),
        fixture("unicode-title-and-ids", "<tvshow><title>世界のニュース — Café</title><year>2024</year><uniqueid type=\"TVDB\">1234</uniqueid></tvshow>"),
    ]
    for count in [128 * 1024 - 1, 128 * 1024, 128 * 1024 + 1] {
        result.append(fixture("document-bytes-\(count)", documentWithByteCount(count)))
    }
    for depth in [30, 31, 32] {
        result.append(fixture("nested-depth-\(depth + 1)", "<movie><title>Known</title>"
                              + String(repeating: "<ignored>", count: depth)
                              + String(repeating: "</ignored>", count: depth) + "</movie>"))
    }
    result.append(Fixture(name: "invalid-utf8", data: Data([0xff, 0xfe, 0x3c, 0x3e])))
    return result
}

private func emit<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    FileHandle.standardOutput.write(try encoder.encode(value))
    FileHandle.standardOutput.write(Data([10]))
}

@main
private enum Driver {
    static func main() throws {
        let arguments = CommandLine.arguments
        if arguments.count == 2, arguments[1] == "differential" {
            let receipts = try differentialFixtures().map { evaluate($0).receipt }
            try emit(DifferentialReport(caseCount: receipts.count, cases: receipts))
            return
        }
        guard arguments.count == 4, arguments[1] == "benchmark",
              let iterations = Int(arguments[3]), iterations > 0 else {
            throw DriverError.invalidArguments("Usage: Driver differential | Driver benchmark CASE ITERATIONS")
        }
        let input = try benchmarkFixture(arguments[2])
        let warmupIterations = 3
        let warmupChecksum = runIterations(input.data, iterations: warmupIterations)
        let start = DispatchTime.now().uptimeNanoseconds
        let checksum = runIterations(input.data, iterations: iterations)
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        // This separate parse and complete receipt are outside the measured loop.
        // The parser and returned model are released inside each timed call.
        let output = evaluate(input)
        guard checksum == output.signature &* UInt64(iterations),
              warmupChecksum == output.signature &* UInt64(warmupIterations) else {
            throw DriverError.unexpectedResult("Parse result changed between iterations: \(input.name)")
        }
        try emit(BenchmarkReport(caseName: input.name, iterations: iterations,
                                 warmupIterations: warmupIterations, elapsedNanoseconds: elapsed,
                                 checksum: checksum, warmupChecksum: warmupChecksum,
                                 perIterationChecksum: output.signature, receipt: output.receipt))
    }
}
