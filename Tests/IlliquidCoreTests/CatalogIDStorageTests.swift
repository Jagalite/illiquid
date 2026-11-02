import Foundation
import Testing
@testable import IlliquidCore

@Suite("Catalog ID merge storage")
struct CatalogIDStorageTests {
    @Test func emptyIncomingIDsPreserveInheritedValuesWithoutSkippingOtherFields() {
        let ids = ["tmdb-9", "imdb-tt12", "tmdb-9", "", "---", "e\u{301}-1"]
        var previous = hints(.episode, ids: ids)
        previous.title = "Inherited"
        previous.year = 2019
        previous.season = 2
        previous.episode = 3
        previous.lastEpisode = 5
        previous.episodeTitle = "Earlier episode"
        previous.sources = ["series", "series"]

        var incoming = hints(nil, ids: [])
        incoming.title = "Replacement"
        incoming.episode = 7
        incoming.sources = ["file", "series"]

        var expected = previous
        expected.title = "Replacement"
        expected.episode = 7
        expected.lastEpisode = nil
        expected.sources = ["file", "series"]
        let merged = incoming.overriding(previous)
        #expect(merged == expected)
        expectExactIDs(merged.catalogIDs, ids)

        let applied = recognized(.episode, ids: ids).applying(incoming)
        expectExactIDs(applied.catalogIDs, ids)
        #expect(applied.title == "Replacement")
        #expect(applied.episode == 7)
        #expect(applied.lastEpisode == nil)
        #expect(applied.metadataSources == incoming.sources)
    }

    @Test func emptyPreviousIDsPreserveIncomingOrderDuplicatesAndSpelling() {
        let ids = ["tvdb-20", "tmdb-2", "tvdb-21", "", "---", "e\u{301}-1"]
        let incoming = hints(.episode, ids: ids)
        expectExactIDs(incoming.overriding(hints(.show, ids: [])).catalogIDs, ids)
        expectExactIDs(recognized(.episode, ids: []).applying(incoming).catalogIDs, ids)
        #expect(hints(nil, ids: []).overriding(hints(nil, ids: [])).catalogIDs.isEmpty)
        #expect(recognized(.episode, ids: []).applying(hints(nil, ids: [])).catalogIDs.isEmpty)
    }

    @Test func replacementsKeepOtherProvidersAndAllIncomingDuplicatesInOrder() {
        let previous = ["imdb-tt10", "tmdb-1", "tvdb-2", "imdb-tt11", "tmdb-3", "tvdb-2"]
        let incoming = ["tmdb-20", "tmdb-21", "imdb-tt30", "tmdb-20"]
        let expected = ["tvdb-2", "tvdb-2", "tmdb-20", "tmdb-21", "imdb-tt30", "tmdb-20"]
        expectExactIDs(
            hints(nil, ids: incoming).overriding(hints(nil, ids: previous)).catalogIDs,
            expected
        )
        expectExactIDs(
            recognized(.episode, ids: previous).applying(hints(nil, ids: incoming)).catalogIDs,
            expected
        )
    }

    @Test func publicIDValuesKeepExistingDelimiterCaseAndUnicodeSemantics() {
        // The public array can contain values not admitted by the sidecar parser.
        // Empty components are skipped; provider comparison stays case-sensitive
        // and uses Swift's canonically equivalent String equality.
        let previous = [
            "", "---", "-tmdb-1", "tmdb-2", "TMDB-3",
            "e\u{301}-1", "\u{e9}-2", "tvdb-5", "customvalue", "x--old",
        ]
        let incoming = ["--tmdb--new", "\u{e9}-3", "---", "TMDB-4", "x--new", "customvalue"]
        let expected = ["", "---", "tvdb-5"] + incoming
        expectExactIDs(
            hints(nil, ids: incoming).overriding(hints(nil, ids: previous)).catalogIDs,
            expected
        )
        expectExactIDs(
            recognized(.episode, ids: previous).applying(hints(nil, ids: incoming)).catalogIDs,
            expected
        )

        // A malformed replacement has no provider and must not erase inherited IDs.
        let malformed = ["", "-", "---"]
        expectExactIDs(
            hints(nil, ids: malformed).overriding(hints(nil, ids: previous)).catalogIDs,
            previous + malformed
        )
        expectExactIDs(
            recognized(.episode, ids: previous).applying(hints(nil, ids: malformed)).catalogIDs,
            previous + malformed
        )
    }

    @Test func overridingDiscardsIDsAcrossMovieAndSeriesIdentityChanges() {
        for previousContent in [MediaMetadataHints.Content.movie, .show, .episode] {
            for incomingContent in [MediaMetadataHints.Content.movie, .show, .episode] {
                let changesIdentity = (previousContent == .movie) != (incomingContent == .movie)
                for replacement in [[], ["imdb-tt2"]] as [[String]] {
                    var previous = hints(previousContent, ids: ["tvdb-1"])
                    previous.year = 2019
                    let incoming = hints(incomingContent, ids: replacement)
                    let result = incoming.overriding(previous)
                    let expected = changesIdentity ? replacement : ["tvdb-1"] + replacement
                    expectExactIDs(result.catalogIDs, expected)
                    #expect(result.year == (changesIdentity ? nil : 2019))
                }
            }
        }
    }

    @Test func applyingDiscardsIDsAcrossMovieAndEpisodeIdentityChanges() {
        for replacement in [[], ["imdb-tt2"]] as [[String]] {
            var episode = hints(.episode, ids: replacement)
            episode.episode = 8
            let fromMovie = recognized(.movie, ids: ["tmdb-1"]).applying(episode)
            #expect(fromMovie.kind == .episode)
            expectExactIDs(fromMovie.catalogIDs, replacement)

            let fromEpisode = recognized(.episode, ids: ["tvdb-1"])
                .applying(hints(.movie, ids: replacement))
            #expect(fromEpisode.kind == .movie)
            #expect(fromEpisode.episode == nil)
            expectExactIDs(fromEpisode.catalogIDs, replacement)

            let fromUnknown = recognized(.unknown, ids: ["tvdb-1"])
                .applying(hints(.movie, ids: replacement))
            #expect(fromUnknown.kind == .movie)
            expectExactIDs(fromUnknown.catalogIDs, replacement)
        }
    }

    @Test func extrasAndUnidentifiedShowHintsKeepTheirExistingGates() {
        var show = hints(.show, ids: ["tvdb-99"])
        show.title = "Series"
        show.sources = [".plexmatch"]
        for kind in [RecognizedMediaName.Kind.unknown, .movie] {
            let original = recognized(kind, ids: ["tmdb-1"])
            #expect(original.applying(show) == original)
        }

        let extra = recognized(.extra, ids: ["tmdb-1"])
        var episode = show
        episode.content = .episode
        episode.episode = 4
        for incoming in [show, episode, hints(.movie, ids: []), hints(nil, ids: ["imdb-tt2"])] {
            #expect(extra.applying(incoming) == extra)
        }

        let unknown = recognized(.unknown, ids: ["tvdb-1"])
        let stillUnknown = unknown.applying(hints(nil, ids: []))
        #expect(stillUnknown.kind == .unknown)
        expectExactIDs(stillUnknown.catalogIDs, ["tvdb-1"])
    }

    @Test func inheritedAndSuppliedArraysRemainIndependentAfterCallerMutation() {
        for inherit in [true, false] {
            let original = ["tvdb-1", "imdb-tt2", "tvdb-1"]
            var previous = hints(.episode, ids: inherit ? original : [])
            var incoming = hints(nil, ids: inherit ? [] : original)
            var merged = incoming.overriding(previous)
            let held = merged
            let applied = recognized(.episode, ids: previous.catalogIDs).applying(incoming)

            previous.catalogIDs.append("tmdb-3")
            incoming.catalogIDs.append("imdb-tt4")
            merged.catalogIDs[0] = "changed"
            merged.catalogIDs.removeLast()
            var exported = applied.catalogIDs
            exported[1] = "changed"
            exported.append("tmdb-5")

            expectExactIDs(held.catalogIDs, original)
            expectExactIDs(applied.catalogIDs, original)
            expectExactIDs(previous.catalogIDs, (inherit ? original : []) + ["tmdb-3"])
            expectExactIDs(incoming.catalogIDs, (inherit ? [] : original) + ["imdb-tt4"])
            #expect(merged.catalogIDs != held.catalogIDs)
            #expect(exported != applied.catalogIDs)
        }
    }

    @Test func plexMatchMappingAndRecognitionPreserveSeriesCatalogIDs() throws {
        let parsed = try #require(PlexMatchHints.parse("""
            title: Series
            year: 2019
            season: 3
            tvdbid: 42
            guid: imdb://tt123
            tvdbid: 43
            ep: E04-E05: Episode.S02E03.mkv
            """))
        let ids = ["tvdb-42", "imdb-tt123", "tvdb-43"]
        var mapped = parsed.hints(for: "Episode.S02E03.mkv", defaultSeason: 8)
        #expect(mapped.content == .episode)
        #expect(mapped.season == 3)
        #expect(mapped.episode == 4)
        #expect(mapped.lastEpisode == 5)
        expectExactIDs(mapped.catalogIDs, ids)

        let filename = MediaNameRecognition.recognize(relativePath: "Episode.S02E03.mkv")
        #expect(filename.kind == .episode)
        #expect(filename.catalogIDs.isEmpty)
        let applied = filename.applying(mapped)
        #expect(applied.title == "Series")
        #expect(applied.year == 2019)
        #expect(applied.season == 3)
        #expect(applied.episode == 4)
        #expect(applied.lastEpisode == 5)
        #expect(applied.metadataSources == [".plexmatch"])
        expectExactIDs(applied.catalogIDs, ids)

        mapped.catalogIDs[0] = "tvdb-999"
        expectExactIDs(parsed.metadata.catalogIDs, ids)
        expectExactIDs(parsed.hints(for: "Episode.S02E03.mkv").catalogIDs, ids)
        expectExactIDs(applied.catalogIDs, ids)
    }

    private func hints(
        _ content: MediaMetadataHints.Content?, ids: [String]
    ) -> MediaMetadataHints {
        var result = MediaMetadataHints()
        result.content = content
        result.catalogIDs = ids
        return result
    }

    private func recognized(_ kind: RecognizedMediaName.Kind, ids: [String]) -> RecognizedMediaName {
        .init(
            kind: kind, title: "Original", year: 2018,
            season: kind == .episode ? 2 : nil,
            episode: kind == .episode ? 3 : nil,
            lastEpisode: kind == .episode ? 5 : nil,
            airDate: nil, episodeTitle: nil, edition: "Extended",
            catalogIDs: ids, variant: "1080p"
        )
    }

    private func expectExactIDs(_ actual: [String], _ expected: [String]) {
        // String equality alone would miss changed normalization/spelling.
        #expect(actual.map { Array($0.utf8) } == expected.map { Array($0.utf8) })
    }
}

