import Foundation
import Testing
import IlliquidCore

@Suite("Media name recognition fast path boundaries")
struct MediaNameRecognitionFastPathTests {
    @Test func untaggedUnicodeTitleKeepsExistingCleanup() {
        let media = MediaNameRecognition.recognize(relativePath:
            "Movies/  Cafe\u{301}._世界  (2001).mkv")
        #expect(media.kind == .movie)
        #expect(media.title == "Cafe\u{301} 世界")
        #expect(media.year == 2001)
        #expect(media.edition == nil)
        #expect(media.catalogIDs.isEmpty)
        #expect(media.variant == nil)
    }

    @Test(arguments: ["旅行 👨‍👩‍👧‍👦", "Cafe\u{301}_vacation", "closing ] and brace }"])
    func untaggedUnknownNamesStayIntact(_ filename: String) {
        let media = MediaNameRecognition.recognize(relativePath: filename + ".mkv")
        #expect(media.kind == .unknown)
        #expect(media.title == filename)
        #expect(media.edition == nil)
        #expect(media.catalogIDs.isEmpty)
    }

    @Test(arguments: ["{\u{301}note}", "[\u{301}note]", "{\u{200D}note}", "[\u{200D}note]"])
    func tagOpenersWithinGraphemeClustersStillMatch(_ tag: String) {
        let movie = MediaNameRecognition.recognize(relativePath: "Film \(tag) (2001).mkv")
        #expect(movie.kind == .movie)
        #expect(movie.title == "Film")
        #expect(movie.year == 2001)

        let extra = MediaNameRecognition.recognize(relativePath: "Film \(tag)-trailer.mkv")
        #expect(extra.kind == .extra)
        #expect(extra.title == "Film")

        let episode = MediaNameRecognition.recognize(relativePath:
            "Show \(tag) - S01E02 - Name \(tag).mkv")
        #expect(episode.kind == .episode)
        #expect(episode.title == "Show")
        #expect(episode.episodeTitle == "Name")
    }

    @Test func filenameCatalogIDsAndEditionKeepTheirSemantics() {
        let media = MediaNameRecognition.recognize(relativePath:
            "Parent {imdb-tt20}/Film {TMDB-10} {imdb-tt20} {edition-Collector} {TVDB-30}.mkv")
        #expect(media.kind == .movie)
        #expect(media.title == "Film")
        #expect(media.year == nil)
        #expect(media.catalogIDs == ["imdb-tt20", "tmdb-10", "tvdb-30"])
        #expect(media.edition == "Collector")
        #expect(media.variant == "Collector")
    }

    @Test func ancestorMetadataIsRetainedForTagFreeNames() {
        let unknown = MediaNameRecognition.recognize(relativePath:
            "Parent {imdb-tt20} {edition-Extended}/unrelated.mkv")
        #expect(unknown.kind == .unknown)
        #expect(unknown.title == "unrelated")
        #expect(unknown.catalogIDs == ["imdb-tt20"])
        #expect(unknown.edition == "Extended")

        let episode = MediaNameRecognition.recognize(relativePath:
            "Show {tvdb-30} {edition-Remaster}/Season 02/S02E03.mkv")
        #expect(episode.kind == .episode)
        #expect(episode.title == "Show")
        #expect(episode.season == 2)
        #expect(episode.episode == 3)
        #expect(episode.catalogIDs == ["tvdb-30"])
        #expect(episode.edition == "Remaster")
    }

    @Test func editionEvidenceCanSpanFilenameAndAncestor() {
        // These malformed components characterize the existing joined-evidence
        // contract. Parsing each component separately would lose the match.
        for (folder, edition) in [
            ("Folder Tail}", "Open/Folder Tail"),
            ("Folder {edition-Closed}", "Open/Folder {edition-Closed")
        ] {
            let media = MediaNameRecognition.recognize(relativePath:
                "\(folder)/Film {edition-Open.mkv")
            #expect(media.edition == edition)
            #expect(media.variant == edition)
        }

        let episode = MediaNameRecognition.recognize(relativePath:
            "Show Tail}/Season 01/S01E01 {edition-Open.mkv")
        #expect(episode.edition == "Open/Show Tail")
        #expect(episode.variant == "Open/Show Tail")
    }

    @Test func lookalikeDelimitersRemainLiteral() {
        let media = MediaNameRecognition.recognize(relativePath:
            "Film ｛edition-Extended｝ ［note］ (2001).mkv")
        #expect(media.kind == .movie)
        #expect(media.title == "Film ｛edition-Extended｝ ［note］")
        #expect(media.year == 2001)
        #expect(media.edition == nil)
        #expect(media.catalogIDs.isEmpty)
    }

    @Test(arguments: ["{open", "[open"])
    func unmatchedOpenersRemainLiteral(_ tag: String) {
        let media = MediaNameRecognition.recognize(relativePath: "Film \(tag) (2001).mkv")
        #expect(media.kind == .movie)
        #expect(media.title == "Film \(tag)")
        #expect(media.year == 2001)
        #expect(media.edition == nil)
        #expect(media.catalogIDs.isEmpty)
    }

    @Test func foundationAndNativeInputStorageHaveEquivalentResults() {
        for path in [
            "Home Videos/旅行 Cafe\u{301} 👩🏽‍🚀 holiday.mp4",
            "Movies/世界 Cafe\u{301} (2001).mkv",
            "Show 👩🏽‍🚀 {tvdb-30}/Season 02/S02E03 - 世界.mkv",
            "世界 Tail}/Film Cafe\u{301} {edition-Open.mkv",
            "Movies/Film [\u{301}note] (2001).mkv"
        ] {
            // Construct Foundation input from UTF-16, independently of Swift's
            // native buffer. Foundation's exact storage class is not a contract.
            let units = Array(path.utf16)
            let bridged = units.withUnsafeBufferPointer {
                NSString(characters: $0.baseAddress!, length: $0.count) as String
            }
            var contiguous = path
            contiguous.makeContiguousUTF8()
            let expected = MediaNameRecognition.recognize(relativePath: contiguous)
            let actual = MediaNameRecognition.recognize(relativePath: bridged)
            #expect(actual == expected)
            #expect(actual.displayName == expected.displayName)
            #expect(actual.seriesTitle == expected.seriesTitle)
            #expect(actual.section == expected.section)
        }
    }
}
