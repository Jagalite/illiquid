import Foundation
import Testing
@testable import SuperplayrCore

@Suite("External subtitle matching")
struct ExternalSubtitleMatcherTests {
    @Test func indexedMatchingPreservesExhaustiveScoresAndAmbiguity() {
        let stems = ["Show", "Show Episode 1", "Show Episode 10", "Show.en",
                     "Show.1080p", "Show.bluray", "Another Show", "EN", "", "épisode"]
        let media = stems.flatMap { stem in [url(stem + ".mkv"), url(stem + ".mp4")] }
        let subtitles = stems.flatMap { stem in
            [url(stem + ".srt"), url(stem + ".en.forced.ass"), url(stem + ".Episode.srt")]
        }
        var expected = Dictionary(uniqueKeysWithValues: media.map { ($0, [URL]()) })
        for subtitle in subtitles {
            let scores = media.compactMap { video in
                ExternalSubtitleMatcher.matchScore(subtitleURL: subtitle, mediaURL: video)
                    .map { (video, $0) }
            }
            guard let best = scores.map(\.1).max() else { continue }
            let winners = scores.filter { $0.1 == best }
            if winners.count == 1 { expected[winners[0].0, default: []].append(subtitle) }
        }
        expected = expected.mapValues { NaturalFilenameOrdering.sort($0) }
        #expect(ExternalSubtitleMatcher.associate(subtitleURLs: subtitles, with: media) == expected)
    }

    @Test func cancelledMatchingDoesNotReturnPartialAssociations() {
        #expect(ExternalSubtitleMatcher.associate(
            subtitleURLs: [url("Show.srt")], with: [url("Show.mkv")], isCancelled: { true }
        ).isEmpty)
    }

    private let folderURL = URL(fileURLWithPath: "/tmp/Shows", isDirectory: true)

    @Test("Matches exact, language, forced, and quality-suffixed names")
    func matchesExactLanguageForcedAndQualitySuffixedNames() {
        let mediaURL = url("Show.S01E02.1080p.mkv")
        let subtitles = [
            url("Show.S01E02.en.srt"),
            url("Show.S01E02.forced.ass"),
            url("Show.S01E02.srt"),
            url("Another.Show.S01E02.srt"),
        ]

        #expect(
            Set(ExternalSubtitleMatcher.matchingSubtitles(for: mediaURL, among: subtitles))
                == Set(subtitles.prefix(3))
        )
    }

    @Test("Episode one subtitle does not match episode ten")
    func episodeOneSubtitleDoesNotMatchEpisodeTen() {
        let episodeOne = url("Episode 1.mkv")
        let episodeTen = url("Episode 10.mkv")
        let subtitle = url("Episode 1.en.srt")

        let matches = ExternalSubtitleMatcher.associate(
            subtitleURLs: [subtitle],
            with: [episodeOne, episodeTen]
        )

        #expect(matches[episodeOne] == [subtitle])
        #expect(matches[episodeTen] == [])
    }

    @Test("Ambiguous generic subtitle is not assigned to every episode")
    func ambiguousGenericSubtitleIsNotAssignedToEveryEpisode() {
        let episodeOne = url("Show Episode 1.mkv")
        let episodeTwo = url("Show Episode 2.mkv")
        let genericSubtitle = url("Show.srt")
        let episodeTwoSubtitle = url("Show Episode 2.en.srt")

        let matches = ExternalSubtitleMatcher.associate(
            subtitleURLs: [genericSubtitle, episodeTwoSubtitle],
            with: [episodeOne, episodeTwo]
        )

        #expect(matches[episodeOne] == [])
        #expect(matches[episodeTwo] == [episodeTwoSubtitle])
    }

    @Test("Matches WebVTT and ignores unsupported bitmap subtitle formats")
    func matchesWebVTTAndIgnoresUnsupportedBitmapSubtitleFormats() {
        let mediaURL = url("Movie.mkv")
        #expect(
            ExternalSubtitleMatcher.matchingSubtitles(for: mediaURL, among: [url("Movie.vtt")])
                == [url("Movie.vtt")]
        )
        #expect(
            ExternalSubtitleMatcher.matchingSubtitles(for: mediaURL, among: [url("Movie.sup")])
                == []
        )
    }

    private func url(_ filename: String) -> URL {
        folderURL.appendingPathComponent(filename)
    }
}
