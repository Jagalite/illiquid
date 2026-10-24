import Foundation
import Testing
@testable import IlliquidCore

@Suite("External subtitle qualifier storage")
struct ExternalSubtitleQualifierStorageTests {
    @Test func longQualifierChainsKeepReleaseSpecificRawNames() {
        // These are URL values, not filesystem entries. A long suffix makes
        // retaining the complete raw name distinct from retaining its prefix.
        let release = Array(repeating: ["2160p", "WEB", "DL", "x265", "HEVC", "AAC", "10bit"],
                            count: 24).flatMap { $0 }
        let tokens = ["Feature"] + release
        let stem = tokens.joined(separator: ".")
        let media = url(stem + ".mkv")
        let alternate = url((["Feature", "720p"] + release.dropFirst()).joined(separator: ".") + ".mp4")
        let exact = url(stem + ".en.forced.srt")
        let generic = url("Feature.eng.srt")

        #expect(ExternalSubtitleMatcher.matchScore(subtitleURL: exact, mediaURL: media)
            == 10_000 + tokens.reduce(0) { $0 + $1.count })
        #expect(ExternalSubtitleMatcher.matchScore(subtitleURL: generic, mediaURL: media) == 10_007)
        #expect(ExternalSubtitleMatcher.associate(
            subtitleURLs: [generic, exact], with: [alternate, media]
        ) == [media: [exact], alternate: []])
    }

    @Test func languageWordInTitleSurvivesLongMediaQualifierChains() {
        let suffix = String(repeating: ".1080p.x265.AAC", count: 16)
        let full = url("The.Last.of.Us" + suffix + ".mkv")
        let shorter = url("The.Last.of" + suffix + ".mkv")
        let subtitle = url("THE.LAST.OF.US.eng.forced.srt")

        #expect(ExternalSubtitleMatcher.matchScore(subtitleURL: subtitle, mediaURL: full) == 10_011)
        #expect(ExternalSubtitleMatcher.matchScore(subtitleURL: subtitle, mediaURL: shorter) == 10_009)
        #expect(ExternalSubtitleMatcher.associate(
            subtitleURLs: [subtitle], with: [shorter, full]
        ) == [full: [subtitle], shorter: []])
    }

    @Test(arguments: [
        ("1080p.720p.HEVC.mkv", "1080p.en.forced.srt", 10_005),
        ("en.mkv", "en.eng.forced.srt", 10_002),
        ("HEVC.mkv", "HEVC.srt", 10_004),
    ])
    func allQualifierStemsKeepTheirFirstToken(media: String, subtitle: String, score: Int) {
        let mediaURL = url(media)
        let subtitleURL = url(subtitle)
        #expect(ExternalSubtitleMatcher.matchScore(subtitleURL: subtitleURL, mediaURL: mediaURL) == score)
        #expect(ExternalSubtitleMatcher.associate(
            subtitleURLs: [subtitleURL], with: [mediaURL]
        ) == [mediaURL: [subtitleURL]])
    }

    @Test func namesWithoutQualifiersKeepExactScoresAndPrefixAmbiguity() {
        let first = url("Chronicle.Part.One.mkv")
        let second = url("Chronicle.Part.Two.mp4")
        let firstSubtitle = url("Chronicle.Part.One.srt")
        let secondSubtitle = url("Chronicle.Part.Two.ass")
        let ambiguous = url("Chronicle.Part.srt")

        #expect(ExternalSubtitleMatcher.matchScore(subtitleURL: firstSubtitle, mediaURL: first) == 10_016)
        #expect(ExternalSubtitleMatcher.matchScore(subtitleURL: ambiguous, mediaURL: first) == 5_175)
        #expect(ExternalSubtitleMatcher.matchScore(subtitleURL: ambiguous, mediaURL: second) == 5_175)
        #expect(ExternalSubtitleMatcher.associate(
            subtitleURLs: [ambiguous, secondSubtitle, firstSubtitle], with: [second, first]
        ) == [first: [firstSubtitle], second: [secondSubtitle]])
    }

    @Test func cancellationDuringQualifiedIndexingAndAfterAMatchDiscardsAllAssociations() {
        let suffix = String(repeating: ".1080p.WEB.DL.x265", count: 8)
        let media = (1...3).map { url("Chapter.\($0)" + suffix + ".mkv") }
        let subtitles = [url("Chapter.1.en.srt"), url("Chapter.srt")]
        #expect(ExternalSubtitleMatcher.associate(
            subtitleURLs: subtitles, with: media
        )[media[0]] == [subtitles[0]])

        // First stop in the media-index loop. The second stop follows the first
        // exact match: two trie tokens, one terminal node, and one score check.
        for cancelAt in [media.count + 3, 2 * media.count + 7] {
            var polls = 0
            let result = ExternalSubtitleMatcher.associate(
                subtitleURLs: subtitles, with: media, isCancelled: {
                    polls += 1
                    return polls == cancelAt
                }
            )
            #expect(polls == cancelAt)
            #expect(result.isEmpty)
        }
    }

    private func url(_ filename: String) -> URL {
        URL(fileURLWithPath: "/tmp/SubtitleQualifierStorage", isDirectory: true)
            .appendingPathComponent(filename)
    }
}
