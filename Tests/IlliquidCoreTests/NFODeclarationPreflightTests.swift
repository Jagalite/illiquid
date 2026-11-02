import Foundation
import Testing
import IlliquidCore

@Suite("NFO declaration preflight")
struct NFODeclarationPreflightTests {
    private func parse(_ xml: String) -> MediaMetadataHints? {
        NFOMetadataHints.parse(Data(xml.utf8))
    }

    @Test func asciiDocumentsPreserveRootSpecificMetadata() throws {
        let movie = try #require(parse("""
            <?xml version="1.0" encoding="UTF-8"?>
            <movie><title>A &amp; B &#33;</title><year>2020</year>
            <uniqueid type="imdb">tt12345</uniqueid></movie>
            """))
        #expect(movie.content == .movie)
        #expect(movie.title == "A & B !")
        #expect(movie.year == 2020)
        #expect(movie.catalogIDs == ["imdb-tt12345"])
        #expect(movie.sources == ["NFO"])

        let show = try #require(parse("""
            <tvshow><title>Show &#65;</title><year>2010</year>
            <season>5</season><episode>99</episode></tvshow>
            """))
        #expect(show.content == .show)
        #expect(show.title == "Show A")
        #expect(show.year == 2010)
        #expect(show.season == nil)
        #expect(show.episode == nil)

        let episode = try #require(parse("""
            <episodedetails><title>Pilot</title><showtitle>Show &#65;</showtitle>
            <season>2</season><episode>3</episode><year>2024</year></episodedetails>
            """))
        #expect(episode.content == .episode)
        #expect(episode.title == "Show A")
        #expect(episode.episodeTitle == "Pilot")
        #expect(episode.season == 2)
        #expect(episode.episode == 3)
        #expect(episode.year == nil)
        #expect(episode.sources == ["NFO"])
    }

    @Test(arguments: [
        "<title>Kept!</title>",
        "<!-- ordinary! comment --><title>Kept!</title>",
        "<title><![CDATA[Kept!]]></title>",
        "<title>Kept!</title><plot><![CDATA[harmless <tag> !]]></plot>",
        "<title>Kept!</title><!-- ordinary! comment -->",
    ])
    func benignExclamationsCommentsAndCDATAPreserveHints(_ fields: String) throws {
        let hints = try #require(parse("<movie>\(fields)<year>2020</year></movie>"))
        #expect(hints.content == .movie)
        #expect(hints.title == "Kept!")
        #expect(hints.year == 2020)
        #expect(hints.sources == ["NFO"])
    }

    @Test func characterReferencesRemainTextRatherThanDeclarations() throws {
        let hints = try #require(parse("""
            <movie><title>Caf&#xE9; &amp; &#33; &lt;!DOCTYPE &lt;!ENTITY</title></movie>
            """))
        #expect(hints.title == "Café & ! <!DOCTYPE <!ENTITY")
    }

    @Test(arguments: ["<!DOCTYPE", "<!dOcTyPe", "<!ENTITY", "<!eNtItY"])
    func declarationMarkersRemainForbiddenInIgnoredContent(_ marker: String) {
        let padding = String(repeating: "x", count: 65_536)
        let documents = [
            "\(marker) movie><movie><title>Kept</title></movie>",
            "<movie><!-- \(marker) ignored> --><title>Kept</title></movie>",
            "<movie><title>Kept</title><plot><![CDATA[\(marker) ignored>]]></plot></movie>",
            "<movie><title>Kept</title><plot>\(padding)</plot><!-- \(marker) ignored> --></movie>",
        ]
        // Preserve rejection of raw markers anywhere, including ignored content.
        for xml in documents { #expect(parse(xml) == nil) }
    }

    @Test func internalEntityDeclarationsRemainRejected() {
        let xml = """
            <!DOCTYPE movie [<!ENTITY expansion "Expanded title">]>
            <movie><title>&expansion;</title></movie>
            """
        #expect(parse(xml) == nil)
    }

    @Test(arguments: ["Café", "Cafe\u{301}", "世界", "İstanbul", "🎞️"])
    func unicodeTitlesRemainSupported(_ title: String) throws {
        let hints = try #require(parse("<movie><title>\(title)</title><year>2020</year></movie>"))
        #expect(hints.title == title)
        #expect(hints.year == 2020)
        #expect(hints.sources == ["NFO"])
    }

    @Test func invalidUTF8RemainsRejected() {
        let sequences: [[UInt8]] = [[0xff], [0xc3, 0x28], [0xed, 0xa0, 0x80]]
        for invalid in sequences {
            var data = Data("<movie><title>".utf8)
            data.append(contentsOf: invalid)
            data.append(contentsOf: "</title></movie>".utf8)
            #expect(NFOMetadataHints.parse(data) == nil)
        }
    }

    @Test(arguments: [
        "", "<movie/>",
        "<unsupported><title>Kept</title></unsupported>",
        "<movie><title>Kept</movie>",
        "<movie><title>&undefined;</title></movie>",
        "<movie><title>Kept</title></movie><movie/>",
        "<movie><plot>Ignored without identification</plot></movie>",
        "<movie><title>Kept</title><plot>\u{0}</plot></movie>",
    ])
    func malformedOrUnidentifiedDocumentsRemainRejected(_ xml: String) {
        #expect(parse(xml) == nil)
    }

    @Test(arguments: ["", "<!-- ordinary! comment -->"])
    func documentByteLimitRemainsExact(_ comment: String) throws {
        let prefix = "<movie>\(comment)<title>Bounded</title><plot>"
        let suffix = "</plot></movie>"
        let room = 128 * 1024 - prefix.utf8.count - suffix.utf8.count
        let exact = prefix + String(repeating: "x", count: room) + suffix
        #expect(exact.utf8.count == 128 * 1024)
        #expect(try #require(parse(exact)).title == "Bounded")

        let oversized = prefix + String(repeating: "x", count: room + 1) + suffix
        #expect(oversized.utf8.count == 128 * 1024 + 1)
        #expect(parse(oversized) == nil)
    }

    @Test(arguments: [31, 32])
    func ignoredElementsStillRespectNestingLimit(_ nestedCount: Int) {
        let nested = String(repeating: "<ignored>", count: nestedCount)
            + "unused" + String(repeating: "</ignored>", count: nestedCount)
        let hints = parse("<movie><title>Kept</title>\(nested)</movie>")
        if nestedCount == 31 {
            #expect(hints?.title == "Kept")
        } else {
            #expect(hints == nil)
        }
    }
}
