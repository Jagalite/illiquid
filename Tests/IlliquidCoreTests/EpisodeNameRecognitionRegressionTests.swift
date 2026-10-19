import Foundation
import Testing
import IlliquidCore

@Suite("Media name recognition folder context")
struct EpisodeNameRecognitionRegressionTests {
    @Test func filenameYearPreservesItsTitleAndWinsOverFolderYear() {
        let media = MediaNameRecognition.recognize(relativePath:
            "TV/FileShow (2011)/Season 02/fileSHOW (2020).S02E03.The.Return.mkv")
        #expect(media.kind == .episode)
        #expect(media.title == "fileSHOW")
        #expect(media.year == 2020)
        #expect(media.season == 2)
        #expect(media.episode == 3)
        #expect(media.episodeTitle == "The Return")
    }

    @Test func matchingUnicodeFolderSuppliesYearAndSpelling() {
        let media = MediaNameRecognition.recognize(relativePath:
            "TV/世界 Café (2016)/Season_02/世界.café.S02E03.Home.mkv")
        #expect(media.kind == .episode)
        #expect(media.title == "世界 Café")
        #expect(media.year == 2016)
        #expect(media.episodeTitle == "Home")
    }

    @Test func matchingFolderWithoutYearStillSuppliesSpelling() {
        let media = MediaNameRecognition.recognize(relativePath:
            "TV/Mixed Case/Season 01/mixed.case.S01E04.mkv")
        #expect(media.kind == .episode)
        #expect(media.title == "Mixed Case")
        #expect(media.year == nil)
    }

    @Test func unrelatedFolderCannotSupplyFilenameYear() {
        let media = MediaNameRecognition.recognize(relativePath:
            "TV/Another Show (2001)/Season 01/Actual.Show.S01E04.mkv")
        #expect(media.kind == .episode)
        #expect(media.title == "Actual Show")
        #expect(media.year == nil)
    }

    @Test func bareEpisodeUsesImmediateParentWithYear() {
        let media = MediaNameRecognition.recognize(relativePath:
            "TV/Named Show (2003)/S03E05.mkv")
        #expect(media.kind == .episode)
        #expect(media.title == "Named Show")
        #expect(media.year == 2003)
        #expect(media.season == 3)
        #expect(media.episode == 5)
    }

    @Test(arguments: ["Season 01", "Season_01", "Season-01", "Season.01", "Specials"])
    func bareEpisodeUsesSeasonContextWithoutYear(_ folder: String) {
        let media = MediaNameRecognition.recognize(relativePath:
            "TV/Undated Show/\(folder)/S02E07-E08.Finale.mkv")
        #expect(media.kind == .episode)
        #expect(media.title == "Undated Show")
        #expect(media.year == nil)
        // Explicit filename numbers win even when the folder names another season.
        #expect(media.season == 2)
        #expect(media.episode == 7)
        #expect(media.lastEpisode == 8)
        #expect(media.episodeTitle == "Finale")
    }

    @Test(arguments: [
        "S01E01.mkv",
        "Undated Show/S01E01.mkv",
        "2024/S01E01.mkv",
        "Season 01/S01E01.mkv",
        "Specials/S00E01.mkv",
        "TV/Show (2018)/Nested/S01E01.mkv",
    ])
    func bareMarkersWithoutExplicitFolderEvidenceStayUnclassified(_ path: String) {
        let media = MediaNameRecognition.recognize(relativePath: path)
        #expect(media.kind == .unknown)
        #expect(media.title == ((path as NSString).lastPathComponent as NSString).deletingPathExtension)
        #expect(media.year == nil)
        #expect(media.season == nil)
        #expect(media.episode == nil)
    }

    @Test(arguments: ["\u{200B}", "\u{00AD}", "\u{FEFF}"])
    func ignorableParentNamesPreserveLocalizedEmptyTitleComparison(_ parent: String) {
        let media = MediaNameRecognition.recognize(relativePath: "\(parent)/S01E01.mkv")
        // Foundation's collation of default-ignorable characters can differ by
        // platform. Preserve its existing identity decision in either case.
        let parentMatchesEmptyTitle = "".localizedCaseInsensitiveCompare(parent) == .orderedSame
        #expect(media.kind == (parentMatchesEmptyTitle ? .episode : .unknown))
        #expect(media.title == (parentMatchesEmptyTitle ? parent : "S01E01"))
        #expect(media.year == nil)
        #expect(media.season == (parentMatchesEmptyTitle ? 1 : nil))
        #expect(media.episode == (parentMatchesEmptyTitle ? 1 : nil))
    }

    @Test(arguments: [
        "TV/A Show (2010)/Season 03/3x02 - Second Part.mkv",
        "TV/A Show (2010)/Season 03/a.show.3x02.Second.Part.mkv",
    ])
    func alternateMarkersUseTheSameFolderRules(_ path: String) {
        let media = MediaNameRecognition.recognize(relativePath: path)
        #expect(media.kind == .episode)
        #expect(media.title == "A Show")
        #expect(media.year == 2010)
        #expect(media.season == 3)
        #expect(media.episode == 2)
        #expect(media.lastEpisode == nil)
        #expect(media.episodeTitle == "Second Part")
    }

    @Test func folderFallbackPreservesRangesEditionsIdentifiersAndReleaseMetadata() {
        let media = MediaNameRecognition.recognize(relativePath:
            "TV/Show (2007) {tvdb-1234}/Specials/S00E02-E03 - Finale {edition-Extended} 1080p WEB-DL {imdb-tt0000123}.mkv")
        #expect(media.kind == .episode)
        #expect(media.title == "Show")
        #expect(media.year == 2007)
        #expect(media.season == 0)
        #expect(media.episode == 2)
        #expect(media.lastEpisode == 3)
        #expect(media.airDate == nil)
        #expect(media.episodeTitle == "Finale")
        #expect(media.edition == "Extended")
        #expect(media.catalogIDs == ["imdb-tt0000123", "tvdb-1234"])
        #expect(media.variant == "Extended · 1080p WEB-DL")
        #expect(media.metadataSources.isEmpty)
        #expect(media.displayName == "S00E02–E03 · Finale")
        #expect(media.section == "TV Shows · Show (2007) · Specials")
    }
}
