import Foundation
import Testing
import IlliquidCore

@Suite("Episode name parsing reuse regressions")
struct MediaNameRecognitionPerformanceTests {
    @Test(arguments: [
        "TV/Series (2020)/Season 01/S01E02 - Second.mkv",
        "TV/Series (2020)/S01E02 - Second.mkv",
        "TV/Series (2020)/Season 01/[Release] S01E02 - Second.mkv"
    ])
    func bareEpisodeInheritsExplicitShowYear(_ path: String) {
        let media = MediaNameRecognition.recognize(relativePath: path)
        #expect(media.kind == .episode)
        #expect(media.title == "Series")
        #expect(media.year == 2020)
        #expect(media.season == 1)
        #expect(media.episode == 2)
        #expect(media.episodeTitle == "Second")
    }

    @Test(arguments: [
        "TV/Series/Season 01/S01E02.mkv",
        "TV/Series/Season_01/1x02.mkv"
    ])
    func seasonFolderAllowsShowWithoutYear(_ path: String) {
        let media = MediaNameRecognition.recognize(relativePath: path)
        #expect(media.kind == .episode)
        #expect(media.title == "Series")
        #expect(media.year == nil)
        #expect(media.season == 1)
        #expect(media.episode == 2)
    }

    @Test func specialsUseShowFolder() {
        let media = MediaNameRecognition.recognize(relativePath: "TV/Series/Specials/S00E02.mkv")
        #expect(media.kind == .episode)
        #expect(media.title == "Series")
        #expect(media.year == nil)
        #expect(media.season == 0)
        #expect(media.episode == 2)
        #expect(media.section == "TV Shows · Series · Specials")
    }

    @Test(arguments: [
        "TV/Series/S01E02.mkv",
        "TV/(2020)/S01E02.mkv",
        "TV/[Release]/Season 01/S01E02.mkv",
        "Season 01/S01E02.mkv",
        "Specials/S01E02.mkv",
        "S01E02.mkv"
    ])
    func bareEpisodeWithoutUsableShowEvidenceStaysUnknown(_ path: String) {
        let media = MediaNameRecognition.recognize(relativePath: path)
        #expect(media.kind == .unknown)
        #expect(media.title == "S01E02")
        #expect(media.displayName == "S01E02")
        #expect(media.year == nil)
        #expect(media.season == nil)
        #expect(media.episode == nil)
    }

    @Test func matchingPrefixInheritsFolderSpellingAndYear() {
        let media = MediaNameRecognition.recognize(relativePath:
            "TV/The Show (2020)/Season 01/the.show.S01E02.mkv")
        #expect(media.kind == .episode)
        #expect(media.title == "The Show")
        #expect(media.year == 2020)
    }

    @Test func differentPrefixDoesNotInheritFolderYear() {
        let media = MediaNameRecognition.recognize(relativePath:
            "TV/The Show (2020)/Season 01/Other.Show.S01E02.mkv")
        #expect(media.kind == .episode)
        #expect(media.title == "Other Show")
        #expect(media.year == nil)
    }

    @Test(arguments: [2019, 2020])
    func explicitPrefixYearKeepsFilenameIdentity(_ year: Int) {
        let media = MediaNameRecognition.recognize(relativePath:
            "TV/The Show (2020)/Season 01/the.show.(\(year)).S01E02.mkv")
        #expect(media.kind == .episode)
        #expect(media.title == "the show")
        #expect(media.year == year)
    }

    @Test func unicodePrefixUsesExistingCaseInsensitiveEnrichment() {
        let media = MediaNameRecognition.recognize(relativePath:
            "TV/ÉTOILE 世界 (2020)/Season 01/étoile.世界.S01E02 - Départ.mkv")
        #expect(media.kind == .episode)
        #expect(media.title == "ÉTOILE 世界")
        #expect(media.year == 2020)
        #expect(media.episodeTitle == "Départ")
    }

    @Test func numericShowTitleRemainsDistinctFromItsYear() {
        let media = MediaNameRecognition.recognize(relativePath:
            "TV/2001 A Space Odyssey (1968)/Season 01/S01E02.mkv")
        #expect(media.kind == .episode)
        #expect(media.title == "2001 A Space Odyssey")
        #expect(media.year == 1968)
        let numeric = MediaNameRecognition.recognize(relativePath: "TV/(2020)/Season 01/S01E02.mkv")
        #expect(numeric.kind == .episode)
        #expect(numeric.title == "2020")
        #expect(numeric.year == nil)
    }

    @Test func tagsRangesAndReleaseMetadataSurviveFolderReuse() {
        let media = MediaNameRecognition.recognize(relativePath:
            "TV/Series (2020) {tvdb-123}/Season 01/{edition-Director Cut} S01E02E03 - Finale.1080p.WEB-DL.mkv")
        #expect(media.kind == .episode)
        #expect(media.title == "Series")
        #expect(media.year == 2020)
        #expect(media.season == 1)
        #expect(media.episode == 2)
        #expect(media.lastEpisode == 3)
        #expect(media.airDate == nil)
        #expect(media.episodeTitle == "Finale")
        #expect(media.edition == "Director Cut")
        #expect(media.catalogIDs == ["tvdb-123"])
        #expect(media.variant == "Director Cut · 1080p WEB-DL")
        #expect(media.metadataSources.isEmpty)
        #expect(media.seriesTitle == "Series (2020)")
        #expect(media.displayName == "S01E02–E03 · Finale")
        #expect(media.section == "TV Shows · Series (2020) · Season 1")
    }
}
