import Foundation
import Testing
import IlliquidCore

@Suite("NFO text limit regressions")
struct NFOTextLimitPerformanceTests {
    @Test func ordinaryTextEntitiesAndCDATARetainMovieHints() throws {
        let xml = """
            <movie><title>  A &amp; B <![CDATA[<Friends>]]>  </title>
            <year>20&#50;4</year><uniqueid type="imdb">tt<![CDATA[12345]]></uniqueid></movie>
            """
        let hints = try #require(parse(xml))
        #expect(hints.content == .movie)
        #expect(hints.title == "A & B <Friends>")
        #expect(hints.year == 2024)
        #expect(hints.catalogIDs == ["imdb-tt12345"])
        #expect(hints.sources == ["NFO"])
    }

    @Test(arguments: [4095, 4096, 4097])
    func asciiBoundarySpansTextEntityAndCDATACallbacks(_ count: Int) throws {
        let prefix = String(repeating: "a", count: count - 2)
        let xml = "<movie><title>\(prefix)&amp;<![CDATA[z]]></title></movie>"
        if count <= 4096 {
            let hints = try #require(parse(xml))
            #expect(hints.title == prefix + "&z")
            #expect(hints.title?.count == count)
        } else {
            #expect(parse(xml) == nil)
        }
    }

    @Test(arguments: ["é", "界", "🎬"], [1024, 2048, 4096, 4097])
    func multibyteTitlesKeepTheCharacterLimit(_ unit: String, _ count: Int) throws {
        let title = String(repeating: unit, count: count)
        #expect(title.count == count)
        // The corpus includes titles below, at, and above 4096 UTF-8 bytes.
        // A title of 4096 multibyte characters must remain valid.
        for payload in [title, "<![CDATA[\(title)]]>"] {
            let xml = "<movie><title>\(payload)</title></movie>"
            #expect(xml.utf8.count < 128 * 1024)
            if count <= 4096 {
                let hints = try #require(parse(xml))
                #expect(hints.title == title)
            } else {
                #expect(parse(xml) == nil)
            }
        }
    }

    @Test(arguments: ["<![CDATA[\u{0301}]]>", "&#x301;"])
    func combiningMarksAreRecountedAfterJoiningFragments(_ combiningFragment: String) throws {
        let prefix = String(repeating: "x", count: 4094)
        let expected = prefix + "e\u{0301}z"
        #expect(expected.count == 4096)
        #expect(expected.utf8.count > 4096)
        let xml = "<movie><title>\(prefix)e\(combiningFragment)<![CDATA[z]]></title></movie>"
        let hints = try #require(parse(xml))
        #expect(hints.title == expected)
        // Adding each callback's Character count permanently would overcount
        // the accent that joined the preceding e before the final z arrived.
        #expect(hints.title?.count == 4096)
    }

    @Test func splitGraphemePreservesTheExistingPerCallbackBoundary() throws {
        let prefix = String(repeating: "x", count: 4095)
        let expected = prefix + "e\u{0301}"
        #expect(expected.count == 4096)
        let grouped = "<movie><title>\(prefix)<![CDATA[e\u{0301}]]></title></movie>"
        #expect(try #require(parse(grouped)).title == expected)

        // The old check counts each incoming fragment before concatenation.
        // At 4096 existing characters, a standalone combining-mark callback
        // exceeds that limit even though concatenation would merge a grapheme.
        let split = "<movie><title>\(prefix)e<![CDATA[\u{0301}]]></title></movie>"
        #expect(parse(split) == nil)
    }

    @Test(arguments: ["movie", "tvshow", "episodedetails"])
    func textBudgetAndCapturedFieldsRemainScopedToEachRoot(_ root: String) throws {
        let title = String(repeating: "é", count: 4096)
        let xml = """
            <\(root)><title><![CDATA[\(title)]]></title><showtitle>Series &amp; One</showtitle>
            <year>2024</year><season>2</season><episode>3</episode>
            <uniqueid type="imdb">tt12345</uniqueid></\(root)>
            """
        let hints = try #require(parse(xml))
        if root == "episodedetails" {
            #expect(hints.content == .episode)
            #expect(hints.title == "Series & One")
            #expect(hints.episodeTitle == title)
            #expect(hints.year == nil)
            #expect(hints.season == 2)
            #expect(hints.episode == 3)
            #expect(hints.catalogIDs.isEmpty)
        } else {
            #expect(hints.content == (root == "movie" ? .movie : .show))
            #expect(hints.title == title)
            #expect(hints.episodeTitle == nil)
            #expect(hints.year == 2024)
            #expect(hints.season == nil)
            #expect(hints.episode == nil)
            #expect(hints.catalogIDs == ["imdb-tt12345"])
        }
        #expect(hints.sources == ["NFO"])
    }

    @Test func longIgnoredPlotDoesNotConsumeTheTextBudget() throws {
        let identity = "<title>Known Title</title><year>2024</year>"
        let expected = try #require(parse("<movie>\(identity)</movie>"))
        let plot = String(repeating: "🎬", count: 8192)
        let xml = "<movie><plot><![CDATA[\(plot)]]></plot>\(identity)</movie>"
        #expect(xml.utf8.count < 128 * 1024)
        #expect(parse(xml) == expected)
        #expect(parse("<movie><plot><![CDATA[\(plot)]]></plot></movie>") == nil)
    }

    private func parse(_ xml: String) -> MediaMetadataHints? {
        NFOMetadataHints.parse(Data(xml.utf8))
    }
}
