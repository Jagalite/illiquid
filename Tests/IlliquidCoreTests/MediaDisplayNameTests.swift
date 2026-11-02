import Foundation
import Testing
@testable import IlliquidCore

@Suite("Media display name formatting")
struct MediaDisplayNameTests {
    @Test func episodeLabelsKeepMinimumWidthAndRangeSyntax() {
        let cases: [(Int?, Int?, Int?, String)] = [
            (nil, nil, nil, "S00E00"),
            (0, 1, nil, "S00E01"),
            (1, 2, nil, "S01E02"),
            (9, 9, 10, "S09E09–E10"),
            (12, 345, 678, "S12E345–E678"),
            (999, 9999, nil, "S999E9999"),
            (-1, -2, -3, "S-1E-2–E-3"),
            (10000, 10001, 10002, "S10000E10001–E10002")
        ]
        for (season, episode, lastEpisode, expected) in cases {
            let media = makeMedia(season: season, episode: episode, lastEpisode: lastEpisode)
            #expect(media.displayName == expected)
        }
    }

    @Test func everyBoundedNumberMatchesTheLegacyFormatter() {
        // Cover every fast-path value in each numeric role, including both
        // sides of the single-digit padding boundary and four-digit episodes.
        for value in 0...9999 {
            let media = makeMedia(season: value, episode: 9999 - value, lastEpisode: value)
            #expect(media.displayName.utf8.elementsEqual(legacyDisplayName(media).utf8))
        }
    }

    @Test func arbitraryHintIntegersKeepSignedCFormatting() {
        let values: [Int?] = [
            nil, Int.min, Int.min + 1,
            -4_294_967_297, -4_294_967_296, -2_147_483_649, -2_147_483_648,
            -10000, -10, -1, 0, 9, 10, 99, 100, 999, 1000, 9999, 10000,
            2_147_483_647, 2_147_483_648, 4_294_967_295, 4_294_967_296,
            4_294_967_297, Int.max - 1, Int.max
        ]
        for season in values {
            for episode in values {
                let media = makeMedia(season: season, episode: episode)
                #expect(media.displayName.utf8.elementsEqual(legacyDisplayName(media).utf8))
            }
        }
        for lastEpisode in values {
            let media = makeMedia(season: 1, episode: 2, lastEpisode: lastEpisode)
            #expect(media.displayName.utf8.elementsEqual(legacyDisplayName(media).utf8))
        }
    }

    @Test func airDatesOverrideTheEntireNumericRange() {
        let dates = ["2024-02-29", "", "日付", "e\u{301}"]
        let titles: [String?] = [nil, "", "Finale", "最終話 · e\u{301} 🎬"]
        for date in dates {
            for title in titles {
                let media = makeMedia(season: Int.min, episode: Int.max,
                                      lastEpisode: 9999, airDate: date, episodeTitle: title)
                let expected = date + (title.map { " · \($0)" } ?? "")
                #expect(media.displayName.utf8.elementsEqual(expected.utf8))
                #expect(media.displayName.utf8.elementsEqual(legacyDisplayName(media).utf8))
            }
        }
    }

    @Test func episodeTitlesKeepTheirExactBytes() {
        let titles: [String?] = [nil, "", "Finale", " Épisode ", "e\u{301}", "最終話 🎬", "line\nbreak"]
        for title in titles {
            let media = makeMedia(season: 1, episode: 2, lastEpisode: 3, episodeTitle: title)
            let expected = "S01E02–E03" + (title.map { " · \($0)" } ?? "")
            #expect(media.displayName.utf8.elementsEqual(expected.utf8))
        }
    }

    @Test func otherMediaKindsKeepTheirSeriesTitles() {
        let kinds: [RecognizedMediaName.Kind] = [.movie, .extra, .unknown]
        let years: [Int?] = [nil, 0, 2026, Int.min, Int.max]
        for kind in kinds {
            for year in years {
                let media = makeMedia(kind: kind, title: "映画 e\u{301}", year: year,
                                      season: 1, episode: 2, lastEpisode: 3,
                                      airDate: "2024-02-29", episodeTitle: "Unused")
                let expected = "映画 e\u{301}" + (year.map { " (\($0))" } ?? "")
                #expect(media.displayName.utf8.elementsEqual(expected.utf8))
                #expect(media.displayName.utf8.elementsEqual(legacyDisplayName(media).utf8))
            }
        }
    }

    @Test func publicMetadataHintsPreserveFormattingForUnboundedIntegers() {
        let recognized = MediaNameRecognition.recognize(relativePath: "Show.S01E02.Finale.mkv")
        for value in [Int.min, -1, 0, 9, 10, 9999, 10000, 2_147_483_648, Int.max] {
            var hints = MediaMetadataHints()
            hints.content = .episode
            hints.season = value
            hints.episode = value
            hints.lastEpisode = value
            hints.episodeTitle = "Finale e\u{301}"
            let media = recognized.applying(hints)
            #expect(media.kind == .episode)
            #expect(media.season == value)
            #expect(media.episode == value)
            #expect(media.lastEpisode == value)
            #expect(media.displayName.utf8.elementsEqual(legacyDisplayName(media).utf8))
        }
    }

    // Freeze the original formatting expression as an independent differential
    // oracle, including its C integer conversion and nil-coalescing precedence.
    private func legacyDisplayName(_ media: RecognizedMediaName) -> String {
        guard media.kind == .episode else {
            return media.title + (media.year.map { " (\($0))" } ?? "")
        }
        let number = media.airDate ?? String(format: "S%02dE%02d", media.season ?? 0, media.episode ?? 0)
            + (media.lastEpisode.map { String(format: "–E%02d", $0) } ?? "")
        return number + (media.episodeTitle.map { " · \($0)" } ?? "")
    }

    private func makeMedia(
        kind: RecognizedMediaName.Kind = .episode,
        title: String = "Show",
        year: Int? = nil,
        season: Int? = nil,
        episode: Int? = nil,
        lastEpisode: Int? = nil,
        airDate: String? = nil,
        episodeTitle: String? = nil
    ) -> RecognizedMediaName {
        RecognizedMediaName(kind: kind, title: title, year: year, season: season,
                            episode: episode, lastEpisode: lastEpisode, airDate: airDate,
                            episodeTitle: episodeTitle, edition: nil, catalogIDs: [], variant: nil)
    }
}
