import Foundation
import Testing
import IlliquidCore

@Suite("NFO metadata field selection")
struct NFOMetadataFieldSelectionTests {
    private func parse(_ xml: String) -> MediaMetadataHints? {
        NFOMetadataHints.parse(Data(xml.utf8))
    }

    @Test(arguments: ["plot", "outline", "tagline", "CUSTOM"], ["movie", "tvshow", "episodedetails"])
    func longIgnoredFieldsPreserveHints(_ field: String, _ root: String) throws {
        let identity = "<title>Amélie &amp; Friends</title><year>2001</year><season>2</season><episode>3</episode>"
        let expected = try #require(parse("<\(root)>\(identity)</\(root)>"))
        for count in [4096, 4097, 65_536] {
            let text = String(repeating: "a", count: count)
            for payload in [text, "<![CDATA[\(text)]]>"] {
                let result = parse("<\(root)><\(field)>\(payload)</\(field)>\(identity)</\(root)>")
                #expect(result == expected, "Ignored \(field), \(count) characters, root \(root)")
            }
        }
    }

    @Test(arguments: [0, 1, 2])
    func ignoredFieldsDoNotResetAdjacentValues(_ position: Int) throws {
        let expected = try #require(parse("<movie><title>Correct Movie</title><year>2020</year></movie>"))
        var fields = ["<title>Correct Movie</title>", "<year>2020</year>"]
        fields.insert("<plot>\(String(repeating: "ignored", count: 1000))</plot>", at: position)
        #expect(parse("<movie>\(fields.joined())</movie>") == expected)
    }

    @Test func contextuallyUnusedFieldsDoNotInvalidateHints() throws {
        let text = String(repeating: "x", count: 5000)
        for root in ["movie", "tvshow"] {
            let expected = try #require(parse("<\(root)><title>Correct Title</title></\(root)>"))
            #expect(parse("<\(root)><showtitle>\(text)</showtitle><title>Correct Title</title></\(root)>") == expected)
        }
        let expected = try #require(parse("<episodedetails><title>Pilot</title><episode>1</episode></episodedetails>"))
        #expect(parse("<episodedetails><title>Pilot</title><year>\(text)</year><episode>1</episode></episodedetails>") == expected)
    }

    @Test(arguments: ["title", "showtitle", "year", "season", "episode", "uniqueid"])
    func consumedFieldsKeepTheirTextLimit(_ field: String) {
        let root = field == "showtitle" ? "episodedetails" : "movie"
        let attribute = field == "uniqueid" ? " type='imdb'" : ""
        for count in [4096, 4097] {
            // Split the value across character-data and CDATA callbacks. A limit
            // on each callback alone would incorrectly accept the 4097 case.
            let first = String(repeating: "a", count: 2048)
            let second = String(repeating: "b", count: count - 2048)
            let xml = "<\(root)><title>Known Title</title><\(field)\(attribute)>\(first)<![CDATA[\(second)]]></\(field)></\(root)>"
            #expect((parse(xml) != nil) == (count == 4096))
        }
    }

    @Test func unicodeAndEntityTextKeepTheirExistingLimit() throws {
        let unicode = String(repeating: "é", count: 4096)
        let result = try #require(parse("<movie><title>\(unicode)</title></movie>"))
        #expect(result.title == unicode)
        #expect(parse("<movie><title>\(unicode)é</title></movie>") == nil)
        let escaped = String(repeating: "&amp;", count: 4096)
        #expect(parse("<movie><title>\(escaped)</title></movie>")?.title?.count == 4096)
        #expect(parse("<movie><title>\(escaped)&amp;</title></movie>") == nil)
    }

    @Test func wholeDocumentSizeLimitStillAppliesToIgnoredFields() throws {
        let prefix = "<movie><title>Bounded Movie</title><plot>"
        let suffix = "</plot></movie>"
        let capacity = 128 * 1024 - prefix.utf8.count - suffix.utf8.count
        let exact = prefix + String(repeating: "x", count: capacity) + suffix
        #expect(exact.utf8.count == 128 * 1024)
        #expect(try #require(parse(exact)).title == "Bounded Movie")
        #expect(parse(prefix + String(repeating: "x", count: capacity + 1) + suffix) == nil)
    }

    @Test func nestingLimitStillAppliesToIgnoredFields() {
        for nestedCount in [31, 32] {
            let nested = String(repeating: "<ignored>", count: nestedCount)
                + "unused" + String(repeating: "</ignored>", count: nestedCount)
            let xml = "<movie><title>Correct Movie</title>\(nested)</movie>"
            // The document root occupies the first of the 32 permitted levels.
            #expect((parse(xml) != nil) == (nestedCount == 31))
        }
    }

    @Test func ignoredFieldsDoNotSupplyIdentificationOrNestedValues() throws {
        let long = String(repeating: "x", count: 6000)
        #expect(parse("<movie><plot>\(long)</plot></movie>") == nil)
        let xml = "<movie><title>Correct Movie</title><actor>\(long)<title>Wrong Title</title><year>1999</year>\(long)</actor><year>2020</year></movie>"
        let result = try #require(parse(xml))
        #expect(result.title == "Correct Movie")
        #expect(result.year == 2020)
    }

    @Test func ignoredFieldsDoNotBypassXMLValidation() {
        let long = String(repeating: "x", count: 5000)
        for xml in [
            "<movie><title>Movie</title><plot>\(long)</wrong></movie>",
            "<movie><title>Movie</title><plot>\(long)&undefined;</plot></movie>",
            "<!DOCTYPE movie><movie><title>Movie</title><plot>\(long)</plot></movie>",
            "<!DOCTYPE movie [<!ENTITY x 'value'>]><movie><title>Movie</title><plot>&x;</plot></movie>",
            "<unexpected><title>Movie</title><plot>\(long)</plot></unexpected>"
        ] {
            #expect(parse(xml) == nil)
        }
    }

    @Test func deterministicIgnoredFieldCorpusPreservesIdentity() throws {
        let identity = "<title>Known &amp; Stable</title><year>2020</year><uniqueid type='imdb'>tt12345</uniqueid>"
        let expected = try #require(parse("<movie>\(identity)</movie>"))
        for index in 0..<64 {
            let count = [0, 4095, 4096, 4097, 8192, 16_384, 32_768, 65_000][index % 8]
            let unit = index % 2 == 0 ? "x" : "é"
            let content = String(repeating: unit, count: count)
            let payload = index % 3 == 0 ? "<![CDATA[\(content)]]>" : content
            let ignored = "<custom\(index)>\(payload)<title>Nested title</title></custom\(index)>"
            let fields = index % 2 == 0 ? ignored + identity : identity + ignored
            let xml = "<movie>\(fields)</movie>"
            #expect(xml.utf8.count <= 128 * 1024)
            #expect(parse(xml) == expected, "Corpus case \(index)")
        }
    }

    @Test func fileSidecarLoadsAndCachesMetadataWithLongPlot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nfo-fields-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let xml = "<movie><title>Sidecar Movie</title><plot>\(String(repeating: "x", count: 65_536))</plot><year>2020</year></movie>"
        try Data(xml.utf8).write(to: root.appendingPathComponent("opaque.nfo"))
        let reader = MediaSidecarReader()
        let file = root.appendingPathComponent("opaque.mkv")
        let first = try reader.recognize(file, within: root)
        #expect(first.kind == .movie)
        #expect(first.title == "Sidecar Movie")
        #expect(first.year == 2020)
        #expect(first.metadataSources == ["NFO"])
        let second = try reader.recognize(file, within: root)
        #expect(second == first)
        #expect(reader.filesRead == 1)
    }

    @Test func seriesAndEpisodeSidecarsRetainPrecedenceWithLongPlots() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nfo-fields-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let plot = "<plot><![CDATA[\(String(repeating: "x", count: 5000))]]></plot>"
        try Data("<tvshow><title>Sidecar Series</title>\(plot)<year>2010</year></tvshow>".utf8)
            .write(to: root.appendingPathComponent("tvshow.nfo"))
        try Data("<episodedetails><title>The Pilot</title>\(plot)<season>2</season><episode>3</episode></episodedetails>".utf8)
            .write(to: root.appendingPathComponent("S01E01.nfo"))
        let result = try MediaSidecarReader().recognize(root.appendingPathComponent("S01E01.mkv"), within: root)
        #expect(result.kind == .episode)
        #expect(result.title == "Sidecar Series")
        #expect(result.year == 2010)
        #expect(result.season == 2)
        #expect(result.episode == 3)
        #expect(result.episodeTitle == "The Pilot")
    }
}
