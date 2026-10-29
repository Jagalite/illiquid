import Foundation
import Testing
@testable import IlliquidCore

@Suite("Media metadata merge semantics")
struct MediaMetadataMergeTests {
    @Test func emptyOverridesPreserveEveryInheritedFieldAndIdentifierOrder() {
        let older = inheritedHints()
        #expect(MediaMetadataHints().overriding(older) == older)
        #expect(older.catalogIDs == ["tvdb-2", "imdb-tt1", "tvdb-2", "", "-"])
    }

    @Test func attributionStillDeduplicatesAndSortsMultipleSources() {
        let cases: [(old: [String], new: [String], expected: [String])] = [
            ([], [], []), (["NFO"], [], ["NFO"]),
            (["NFO", "NFO"], [], ["NFO"]),
            (["Z", "NFO", ".plexmatch", "Z"], [], [".plexmatch", "NFO", "Z"]),
            ([], ["Z", "NFO", "Z"], ["NFO", "Z"]),
            (["NFO"], [".plexmatch", "NFO"], [".plexmatch", "NFO"]),
        ]
        for testCase in cases {
            var older = inheritedHints()
            older.sources = testCase.old
            var newer = MediaMetadataHints()
            newer.sources = testCase.new
            var expected = older
            expected.sources = testCase.expected
            #expect(newer.overriding(older) == expected)
        }
    }

    @Test func explicitFieldsAndProviderOverridesKeepTheirPrecedence() {
        let older = inheritedHints()
        var newer = MediaMetadataHints()
        newer.content = .episode
        newer.title = "Renamed Series"
        newer.episode = 7
        newer.episodeTitle = "After"
        newer.catalogIDs = ["imdb-tt99", "imdb-tt100"]
        newer.sources = [".plexmatch", "NFO"]
        var expected = older
        expected.title = "Renamed Series"
        expected.episode = 7
        expected.lastEpisode = nil
        expected.episodeTitle = "After"
        expected.catalogIDs = ["tvdb-2", "tvdb-2", "", "-", "imdb-tt99", "imdb-tt100"]
        expected.sources = [".plexmatch", "NFO"]
        #expect(newer.overriding(older) == expected)
    }

    @Test func movieAndSeriesIdentityChangesDiscardAllInheritedMetadata() {
        for movieFirst in [false, true] {
            var older = inheritedHints()
            older.content = movieFirst ? .movie : .episode
            var newer = MediaMetadataHints()
            newer.content = movieFirst ? .episode : .movie
            newer.title = "Different Identity"
            #expect(newer.overriding(older) == newer)
        }
    }

    @Test func applyingEmptyIdentifiersPreservesDuplicatesAndOtherFilenameEvidence() {
        let filename = recognized()
        var hints = MediaMetadataHints()
        hints.sources = ["NFO"]
        #expect(filename.applying(hints) == recognized(sources: ["NFO"]))
        hints.catalogIDs = ["tvdb-9"]
        #expect(filename.applying(hints) == recognized(
            ids: ["imdb-tt1", "", "-", "tvdb-9"], sources: ["NFO"]
        ))
    }

    @Test func applyingIdentityChangesClearsOldIdentifiersBeforeTheFastPath() {
        var movieHints = MediaMetadataHints()
        movieHints.content = .movie
        let movie = recognized().applying(movieHints)
        #expect(movie == RecognizedMediaName(
            kind: .movie, title: "Series", year: 2020, season: nil, episode: nil,
            lastEpisode: nil, airDate: nil, episodeTitle: nil, edition: "Cut",
            catalogIDs: [], variant: "2160p", metadataSources: []
        ))
        var episodeHints = MediaMetadataHints()
        episodeHints.content = .episode
        episodeHints.episode = 9
        let originalMovie = RecognizedMediaName(
            kind: .movie, title: "Movie", year: 2010, season: nil, episode: nil,
            lastEpisode: nil, airDate: nil, episodeTitle: nil, edition: nil,
            catalogIDs: ["imdb-tt123"], variant: nil
        )
        #expect(originalMovie.applying(episodeHints) == RecognizedMediaName(
            kind: .episode, title: "Movie", year: 2010, season: 1, episode: 9,
            lastEpisode: nil, airDate: nil, episodeTitle: nil, edition: nil,
            catalogIDs: [], variant: nil
        ))
    }

    @Test func mergingSharedArraysRetainsValueSemantics() {
        var older = inheritedHints()
        let expected = older
        var merged = MediaMetadataHints().overriding(older)
        merged.catalogIDs.append("tmdb-3")
        merged.sources.append("caller")
        #expect(older == expected)
        let captured = MediaMetadataHints().overriding(older)
        older.catalogIDs.removeAll()
        older.sources.removeAll()
        #expect(captured == expected)
        #expect(merged.catalogIDs == ["tvdb-2", "imdb-tt1", "tvdb-2", "", "-", "tmdb-3"])
        #expect(merged.sources == ["NFO", "caller"])
    }

    @Test func plexMatchEpisodeLookupInheritsSeriesIdentifiersAndAttribution() throws {
        let plex = try #require(PlexMatchHints.parse("""
            title: Series
            year: 2020
            season: 3
            tvdbid: 2
            guid: imdb://tt1
            ep: E04: episode.mkv
            """))
        var expected = MediaMetadataHints()
        expected.content = .episode
        expected.title = "Series"
        expected.year = 2020
        expected.season = 3
        expected.episode = 4
        expected.catalogIDs = ["tvdb-2", "imdb-tt1"]
        expected.sources = [".plexmatch"]
        #expect(plex.hints(for: "episode.mkv") == expected)
        #expect(plex.hints(for: "missing.mkv") == plex.metadata)
    }

    private func inheritedHints() -> MediaMetadataHints {
        var hints = MediaMetadataHints()
        hints.content = .episode
        hints.title = "Series"
        hints.year = 2020
        hints.season = 3
        hints.episode = 4
        hints.lastEpisode = 6
        hints.episodeTitle = "Before"
        hints.catalogIDs = ["tvdb-2", "imdb-tt1", "tvdb-2", "", "-"]
        hints.sources = ["NFO"]
        return hints
    }

    private func recognized(
        ids: [String] = ["tvdb-2", "imdb-tt1", "tvdb-2", "", "-"],
        sources: [String] = ["filename"]
    ) -> RecognizedMediaName {
        .init(kind: .episode, title: "Series", year: 2020, season: 3, episode: 4,
              lastEpisode: 6, airDate: nil, episodeTitle: "Before", edition: "Cut",
              catalogIDs: ids, variant: "2160p", metadataSources: sources)
    }
}
