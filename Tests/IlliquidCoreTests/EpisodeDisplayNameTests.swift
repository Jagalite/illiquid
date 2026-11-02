import Foundation
import Testing
@testable import IlliquidCore

@Suite("Episode display names")
struct EpisodeDisplayNameTests {
    @Test func labelsUseMinimumWidthAndPreserveEveryRangeEndpoint() {
        let cases: [(season: Int, episode: Int, last: Int?, expected: String)] = [
            (0, 0, nil, "S00E00"),
            (1, 9, nil, "S01E09"),
            (9, 10, nil, "S09E10"),
            (10, 99, nil, "S10E99"),
            (100, 1000, nil, "S100E1000"),
            (9999, 9999, 10000, "S9999E9999–E10000"),
            (2, 18, 19, "S02E18–E19"),
            (0, 0, 0, "S00E00–E00"),
            (1, 9, 9, "S01E09–E09"),
            (1, 9, 1, "S01E09–E01"),
            (1, 9, 0, "S01E09–E00"),
        ]
        for test in cases {
            let media = make(season: test.season, episode: test.episode, lastEpisode: test.last)
            #expect(media.displayName.utf8.elementsEqual(test.expected.utf8))
            #expect(media.displayName.utf8.elementsEqual(legacyDisplayName(media).utf8))
        }
    }

    @Test func absentNumbersDefaultToZero() {
        let cases: [(season: Int?, episode: Int?, last: Int?, expected: String)] = [
            (nil, nil, nil, "S00E00"),
            (nil, 1, nil, "S00E01"),
            (1, nil, nil, "S01E00"),
            (nil, nil, 3, "S00E00–E03"),
            (nil, 1, 0, "S00E01–E00"),
            (1, nil, 100, "S01E00–E100"),
        ]
        for test in cases {
            let media = make(season: test.season, episode: test.episode, lastEpisode: test.last)
            #expect(media.displayName.utf8.elementsEqual(test.expected.utf8))
        }
    }

    @Test func airDatesOverrideAllNumbersAndRangesIncludingEmptyDates() {
        let titles: [String?] = [nil, "", "Finale 👩‍🚀"]
        for date in ["", "2026-10-28", "\u{0065}\u{0301} · 日期", "arbitrary date text"] {
            for episodeTitle in titles {
                let media = make(season: Int.min, episode: Int.max, lastEpisode: -9,
                                 airDate: date, episodeTitle: episodeTitle)
                let expected = date + (episodeTitle.map { " · \($0)" } ?? "")
                #expect(media.displayName.utf8.elementsEqual(expected.utf8))
                #expect(media.displayName.utf8.elementsEqual(legacyDisplayName(media).utf8))
            }
        }
    }

    @Test func episodeTitleSuffixPreservesExactUTF8() {
        let titles: [String?] = [nil, "", "Finale", "Caf\u{00E9}", "Cafe\u{0301}",
                                 "日本語 👩‍🚀", "leading\nline\u{0000}tail", "  spaced  "]
        for title in titles {
            let media = make(title: "", year: 2026, season: 2, episode: 3,
                             lastEpisode: 4, episodeTitle: title)
            let expected = "S02E03–E04" + (title.map { " · \($0)" } ?? "")
            #expect(media.displayName.utf8.elementsEqual(expected.utf8))
            #expect(media.displayName.utf8.elementsEqual(legacyDisplayName(media).utf8))
        }
    }

    @Test func nonEpisodesAlwaysUseSeriesTitle() {
        let years: [Int?] = [nil, 0, 2026, Int.min, Int.max]
        for kind in [RecognizedMediaName.Kind.movie, .extra, .unknown] {
            for title in ["", "Film", "Cafe\u{0301} 🎞"] {
                for year in years {
                    let media = make(kind: kind, title: title, year: year,
                                     season: Int.min, episode: Int.max, lastEpisode: -1,
                                     airDate: "2026-10-28", episodeTitle: "ignored")
                    let expected = title + (year.map { " (\($0))" } ?? "")
                    #expect(media.displayName.utf8.elementsEqual(expected.utf8))
                }
            }
        }
    }

    @Test func everyValueFromZeroThrough9999MatchesOriginalFormatting() {
        for value in 0...9999 {
            let cases = [
                make(season: value, episode: 2),
                make(season: 1, episode: value),
                make(season: 1, episode: 2, lastEpisode: value),
            ]
            for media in cases {
                #expect(media.displayName.utf8.elementsEqual(legacyDisplayName(media).utf8))
            }
        }
    }

    @Test func deterministicPositiveInt32SamplesMatchOriginalFormatting() {
        var state: UInt64 = 0xE915_0DE0_2026_1028
        func next() -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 16) & 0x7fff_ffff)
        }
        for index in 0..<4096 {
            let season = next(), episode = next(), last = next()
            let media = make(season: season, episode: episode,
                             lastEpisode: index.isMultiple(of: 3) ? nil : last,
                             episodeTitle: index.isMultiple(of: 7) ? "Cafe\u{0301}" : nil)
            #expect(media.displayName.utf8.elementsEqual(legacyDisplayName(media).utf8))
        }
        let maximum = Int(Int32.max)
        let media = make(season: maximum, episode: maximum, lastEpisode: maximum)
        #expect(media.displayName == "S2147483647E2147483647–E2147483647")
        #expect(media.displayName.utf8.elementsEqual(legacyDisplayName(media).utf8))
    }

    @Test func negativeAndWiderValuesPreserveLegacyCIntegerConversions() {
        let conversionBoundaries: [Int64] = [
            -4_294_967_297, -4_294_967_296, -4_294_967_295,
            -2_147_483_649, -2_147_483_648, -2_147_483_647,
            -100, -10, -9, -1, 0, 1, 9, 10,
            2_147_483_646, 2_147_483_647, 2_147_483_648, 2_147_483_649,
            4_294_967_295, 4_294_967_296, 4_294_967_297,
        ]
        let values = [Int.min, Int.min + 1, Int.max - 1, Int.max]
            + conversionBoundaries.compactMap { Int(exactly: $0) }
        for value in values {
            let cases = [
                make(season: value, episode: 2),
                make(season: 1, episode: value),
                make(season: 1, episode: 2, lastEpisode: value),
                make(season: value, episode: value, lastEpisode: value),
                make(episode: value, lastEpisode: value, episodeTitle: ""),
            ]
            for media in cases {
                #expect(media.displayName.utf8.elementsEqual(legacyDisplayName(media).utf8))
            }
        }
        for season in values {
            for episode in values {
                let media = make(season: season, episode: episode,
                                 lastEpisode: Int.max, episodeTitle: "尾声")
                #expect(media.displayName.utf8.elementsEqual(legacyDisplayName(media).utf8))
            }
        }
    }

    private func make(kind: RecognizedMediaName.Kind = .episode, title: String = "Show",
                      year: Int? = nil, season: Int? = nil, episode: Int? = nil,
                      lastEpisode: Int? = nil, airDate: String? = nil,
                      episodeTitle: String? = nil) -> RecognizedMediaName {
        .init(kind: kind, title: title, year: year, season: season, episode: episode,
              lastEpisode: lastEpisode, airDate: airDate, episodeTitle: episodeTitle,
              edition: nil, catalogIDs: [], variant: nil)
    }

    /// The complete pre-optimization expression, including C %d conversion.
    private func legacyDisplayName(_ media: RecognizedMediaName) -> String {
        guard media.kind == .episode else { return media.seriesTitle }
        let number = media.airDate ?? String(format: "S%02dE%02d", media.season ?? 0, media.episode ?? 0)
            + (media.lastEpisode.map { String(format: "–E%02d", $0) } ?? "")
        return number + (media.episodeTitle.map { " · \($0)" } ?? "")
    }
}
