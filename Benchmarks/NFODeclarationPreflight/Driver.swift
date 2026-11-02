import Foundation
import IlliquidCore

private struct Fixture {
    let name: String
    let data: Data

    init(_ name: String, _ xml: String) {
        self.name = name
        self.data = Data(xml.utf8)
    }

    init(_ name: String, bytes: [UInt8]) {
        self.name = name
        self.data = Data(bytes)
    }
}

private func workloads() -> [Fixture] {
    let movie = "<movie><title>The Example</title><year>2024</year><uniqueid type=\"imdb\">tt12345</uniqueid></movie>"
    var cases = [
        Fixture("movie-small", movie),
        Fixture("episode-small", "<episodedetails><showtitle>The Series</showtitle><title>Arrival</title><season>2</season><episode>3</episode></episodedetails>"),
        Fixture("show-small", "<?xml version=\"1.0\"?><tvshow><title>The Series</title><year>2024</year></tvshow>"),
        Fixture("unicode-title", "<movie><title>Café 東京 🎬</title><year>2024</year></movie>"),
        Fixture("bang-title", "<movie><title>Hello!</title><year>2024</year></movie>"),
        Fixture("comment", "<movie><!-- ordinary metadata --><title>The Example</title></movie>"),
        Fixture("cdata", "<movie><title><![CDATA[The Example]]></title></movie>"),
        Fixture("doctype-rejected", "<!DOCTYPE movie [<!ENTITY title \"The Example\">]><movie><title>&title;</title></movie>"),
        Fixture("entity-comment-rejected", "<movie><!-- <!eNtItY title \"example\"> --><title>The Example</title></movie>"),
        Fixture("malformed", "<movie><title>Unclosed"),
        Fixture("invalid-utf8", bytes: [0x3C, 0xFF, 0x3E]),
        Fixture("empty", ""),
        Fixture("oversized", String(repeating: "x", count: 128 * 1024 + 1)),
    ]
    for count in [4096, 32768, 120000] {
        cases.append(Fixture("ascii-plot-\(count)",
            "<movie><plot>\(String(repeating: "a", count: count))</plot><title>The Example</title><year>2024</year></movie>"))
    }
    for (name, prefix, suffix) in [
        ("early-bang", "!", ""), ("late-bang", "", "!"),
        ("early-unicode", "é", ""), ("late-unicode", "", "é"),
    ] {
        cases.append(Fixture("\(name)-32768",
            "<movie><plot>\(prefix)\(String(repeating: "a", count: 32768))\(suffix)</plot><title>The Example</title></movie>"))
    }
    return cases
}

private func differentialFixtures() -> [Fixture] {
    var cases = workloads()
    for byte in UInt8.min...127 {
        let value = String(UnicodeScalar(UInt32(byte))!)
        cases.append(Fixture("literal-ascii-\(byte)", "<movie><title>A\(value)B</title></movie>"))
        cases.append(Fixture("ignored-ascii-\(byte)", "<movie><plot>A\(value)B</plot><title>Known</title></movie>"))
    }
    for spelling in ["DOCTYPE", "doctype", "DoCtYpE", "ENTITY", "entity", "eNtItY",
                     "ＤＯＣＴＹＰＥ", "ENTİTY", "DOCT\u{00AD}YPE", "DOCT\u{0301}YPE"] {
        for (index, payload) in [
            "<!-- <!\(spelling) movie> -->",
            "<![CDATA[<!\(spelling) movie>]]>",
            "&lt;!\(spelling) movie&gt;",
            "<! \(spelling) movie>",
        ].enumerated() {
            cases.append(Fixture("declaration-\(spelling)-\(index)", "<movie><plot>\(payload)</plot><title>Known</title></movie>"))
        }
    }
    let fragments = [
        "Known", "Café", "Cafe\u{301}", "東京", "🎬", "Hello!",
        "A &amp; B", "20&#50;4", "<![CDATA[Known]]>", "<!-- note -->Known",
        "<![CDATA[<!DOCTYPE movie>]]>", "<!-- <!ENTITY hidden> -->",
        "&unknown;", "", "<nested>Known</nested>", String(repeating: "x", count: 4097),
    ]
    let roots = ["movie", "tvshow", "episodedetails", "unsupported"]
    var state: UInt64 = 0x7166DB134D36
    func next(_ count: Int) -> Int {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Int((state >> 32) % UInt64(count))
    }
    for index in 0..<512 {
        let root = roots[next(roots.count)]
        let title = fragments[next(fragments.count)]
        let plot = fragments[next(fragments.count)]
        let show = fragments[next(fragments.count)]
        cases.append(Fixture("generated-\(index)",
            "<\(root)><plot>\(plot)</plot><title>\(title)</title><showtitle>\(show)</showtitle><year>2024</year><season>2</season><episode>3</episode><uniqueid type=\"imdb\">tt12345</uniqueid></\(root)>"))
    }
    let prefix = "<movie><title>Boundary</title><plot>"
    let suffix = "</plot></movie>"
    let padding = 128 * 1024 - prefix.utf8.count - suffix.utf8.count
    cases.append(Fixture("byte-boundary", prefix + String(repeating: "x", count: padding) + suffix))
    cases.append(Fixture("byte-boundary-plus-one", prefix + String(repeating: "x", count: padding + 1) + suffix))
    for depth in [30, 31, 32, 33] {
        cases.append(Fixture("depth-\(depth)", "<movie><title>Known</title>" +
            String(repeating: "<extra>", count: depth) + "ignored" +
            String(repeating: "</extra>", count: depth) + "</movie>"))
    }
    let invalidUTF8: [[UInt8]] = [[0xC0, 0xAF], [0xED, 0xA0, 0x80], [0xF4, 0x90, 0x80, 0x80], [0xE2, 0x82]]
    for bytes in invalidUTF8 {
        cases.append(Fixture("invalid-\(cases.count)", bytes: Array("<movie><title>".utf8) + bytes + Array("</title></movie>".utf8)))
    }
    return cases
}

private func jsonValue<T>(_ value: T?) -> Any {
    value.map { $0 as Any } ?? NSNull()
}

private func receipt(_ hints: MediaMetadataHints?) -> Any {
    guard let hints else { return NSNull() }
    let content: String?
    switch hints.content {
    case .movie: content = "movie"
    case .show: content = "show"
    case .episode: content = "episode"
    case nil: content = nil
    }
    return [
        "content": jsonValue(content), "title": jsonValue(hints.title),
        "year": jsonValue(hints.year), "season": jsonValue(hints.season),
        "episode": jsonValue(hints.episode), "lastEpisode": jsonValue(hints.lastEpisode),
        "episodeTitle": jsonValue(hints.episodeTitle),
        "catalogIDs": hints.catalogIDs, "sources": hints.sources,
    ] as [String: Any]
}

@inline(never)
private func consume(_ hints: MediaMetadataHints?) -> UInt64 {
    guard let hints else { return 1 }
    return UInt64(2 + (hints.title?.utf8.count ?? 0) + (hints.episodeTitle?.utf8.count ?? 0)
        + (hints.year ?? 0) + (hints.season ?? 0) + (hints.episode ?? 0)
        + (hints.lastEpisode ?? 0) + hints.catalogIDs.reduce(0) { $0 + $1.utf8.count }
        + hints.sources.reduce(0) { $0 + $1.utf8.count })
}

private func emit(_ value: Any) throws {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))
}

@main
private enum Driver {
    static func main() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let mode = args.first else { fatalError("expected --list, --differential or workload iterations") }
        if mode == "--list" {
            try emit(workloads().map { ["name": $0.name, "bytes": $0.data.count] as [String: Any] })
        } else if mode == "--differential" {
            let cases = differentialFixtures()
            try emit(["count": cases.count, "cases": cases.map {
                ["name": $0.name, "bytes": $0.data.count, "result": receipt(NFOMetadataHints.parse($0.data))] as [String: Any]
            }])
        } else {
            guard args.count == 2, let iterations = Int(args[1]), iterations > 0,
                  let fixture = workloads().first(where: { $0.name == mode })
            else { fatalError("invalid workload or iteration count") }
            let expected = NFOMetadataHints.parse(fixture.data)
            for _ in 0..<3 { precondition(NFOMetadataHints.parse(fixture.data) == expected) }
            var checksum: UInt64 = 0
            let start = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<iterations {
                checksum &+= consume(NFOMetadataHints.parse(fixture.data))
            }
            let elapsed = DispatchTime.now().uptimeNanoseconds - start
            precondition(checksum == consume(expected) &* UInt64(iterations))
            try emit(["name": mode, "bytes": fixture.data.count, "iterations": iterations,
                      "elapsed_ns": elapsed, "ns_per_parse": Double(elapsed) / Double(iterations),
                      "checksum": checksum, "result": receipt(expected)] as [String: Any])
        }
    }
}
