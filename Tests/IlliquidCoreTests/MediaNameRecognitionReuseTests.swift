import Foundation
import Testing
@testable import IlliquidCore

@Suite("Media name recognition folder evidence reuse")
struct MediaNameRecognitionReuseTests {
    @Test func emptyPrefixesUseSeasonAndSpecialsFolderEvidence() {
        let cases: [(String, RecognizedMediaName)] = [
            ("Example Show (2020)/Season 1/S01E02.mkv",
             episode(title: "Example Show", year: 2020)),
            ("Example Show/Season_1/S01E02.Name.mkv",
             episode(title: "Example Show", episodeTitle: "Name")),
            ("Example Show (2020)/Specials/S00E03.mkv",
             episode(title: "Example Show", year: 2020, season: 0, number: 3)),
            ("Outer/Example Show/Season-1/S01E02.mkv",
             episode(title: "Example Show")),
        ]
        for (path, expected) in cases {
            #expect(MediaNameRecognition.recognize(relativePath: path) == expected)
        }
    }

    @Test func emptyPrefixesOutsideSeasonFoldersRequireAParentYear() {
        let cases: [(String, RecognizedMediaName)] = [
            ("S01E02.mkv", recognized(.unknown, title: "S01E02")),
            ("Unmarked Show/S01E02.mkv", recognized(.unknown, title: "S01E02")),
            ("Season 1/S01E02.mkv", recognized(.unknown, title: "S01E02")),
            ("Specials/S00E03.mkv", recognized(.unknown, title: "S00E03")),
            ("Example Show (2020)/Nested/S01E02.mkv",
             recognized(.unknown, title: "S01E02")),
            ("Example Show (2020)/S01E02.mkv",
             episode(title: "Example Show", year: 2020)),
            ("Example Show 2020/S01E02.mkv",
             episode(title: "Example Show", year: 2020)),
        ]
        for (path, expected) in cases {
            #expect(MediaNameRecognition.recognize(relativePath: path) == expected)
        }
    }

    @Test func filenameTitlesRemainPrimaryAndMatchingFoldersEnrichYear() {
        let cases: [(String, RecognizedMediaName)] = [
            ("Example Show (2020)/Season 1/Example.Show.S01E02.mkv",
             episode(title: "Example Show", year: 2020)),
            ("example show (2020)/Season 1/EXAMPLE.SHOW.S01E02.mkv",
             episode(title: "example show", year: 2020)),
            ("Different Show (2020)/Season 1/Example.Show.S01E02.mkv",
             episode(title: "Example Show")),
            ("Example Show (2019)/Season 1/Example.Show.(2020).S01E02.mkv",
             episode(title: "Example Show", year: 2020)),
        ]
        for (path, expected) in cases {
            #expect(MediaNameRecognition.recognize(relativePath: path) == expected)
        }
    }

    @Test func tagsEditionsCatalogIDsAndReleaseMetadataRemainIntact() {
        let cases: [(String, RecognizedMediaName)] = [
            ("Example Show (2020) {tvdb-123}/Season 1/S01E02.mkv",
             episode(title: "Example Show", year: 2020, catalogIDs: ["tvdb-123"])),
            ("Example Show {edition-Extended} (2020)/Season 1/S01E02.Name.1080p.mkv",
             episode(title: "Example Show", year: 2020, episodeTitle: "Name",
                     edition: "Extended", variant: "Extended · 1080p")),
            ("Example Show {edition-1999 cut}/S01E02.mkv",
             recognized(.unknown, title: "S01E02", edition: "1999 cut", variant: "1999 cut")),
            ("Example Show {edition-1999 cut}/Season 1/S01E02.mkv",
             episode(title: "Example Show", edition: "1999 cut", variant: "1999 cut")),
        ]
        for (path, expected) in cases {
            #expect(MediaNameRecognition.recognize(relativePath: path) == expected)
        }
    }

    @Test func alternateAndMultipleEpisodeMarkersKeepTheirMeaning() {
        let cases: [(String, RecognizedMediaName)] = [
            ("Example Show (2020)/Season 1/1x02.Name.mkv",
             episode(title: "Example Show", year: 2020, episodeTitle: "Name")),
            ("Example Show (2020)/Season 1/S01E02E04.Name.mkv",
             episode(title: "Example Show", year: 2020, lastEpisode: 4, episodeTitle: "Name")),
            ("Example Show (2020)/Season 1/S01E02E01.mkv",
             episode(title: "Example Show", year: 2020)),
        ]
        for (path, expected) in cases {
            #expect(MediaNameRecognition.recognize(relativePath: path) == expected)
        }
    }

    @Test func episodeMarkersKeepPrecedenceOverDates() {
        let cases: [(String, RecognizedMediaName)] = [
            ("Example Show (2020)/Season 1/S01E02.2024-02-29.mkv",
             episode(title: "Example Show", year: 2020, episodeTitle: "2024-02-29")),
            ("News/News.2024-02-29.mkv",
             recognized(.episode, title: "News", airDate: "2024-02-29")),
            ("News/News.2024-02-30.mkv",
             recognized(.unknown, title: "News.2024-02-30")),
        ]
        for (path, expected) in cases {
            #expect(MediaNameRecognition.recognize(relativePath: path) == expected)
        }
    }

    @Test func extrasKeepPrecedenceOverEpisodeMarkers() {
        #expect(MediaNameRecognition.recognize(
            relativePath: "Example Show (2020)/Season 1/S01E02-trailer.mkv"
        ) == recognized(.extra, title: "S01E02"))
    }

    private func episode(
        title: String,
        year: Int? = nil,
        season: Int = 1,
        number: Int = 2,
        lastEpisode: Int? = nil,
        episodeTitle: String? = nil,
        edition: String? = nil,
        catalogIDs: [String] = [],
        variant: String? = nil
    ) -> RecognizedMediaName {
        recognized(.episode, title: title, year: year, season: season,
                   episode: number, lastEpisode: lastEpisode, episodeTitle: episodeTitle,
                   edition: edition, catalogIDs: catalogIDs, variant: variant)
    }

    // Compare the complete public result, including nil/default fields, so a
    // reused folder value cannot leak unrelated episode or metadata evidence.
    private func recognized(
        _ kind: RecognizedMediaName.Kind,
        title: String,
        year: Int? = nil,
        season: Int? = nil,
        episode: Int? = nil,
        lastEpisode: Int? = nil,
        airDate: String? = nil,
        episodeTitle: String? = nil,
        edition: String? = nil,
        catalogIDs: [String] = [],
        variant: String? = nil
    ) -> RecognizedMediaName {
        RecognizedMediaName(kind: kind, title: title, year: year, season: season,
                            episode: episode, lastEpisode: lastEpisode, airDate: airDate,
                            episodeTitle: episodeTitle, edition: edition,
                            catalogIDs: catalogIDs, variant: variant)
    }
}
