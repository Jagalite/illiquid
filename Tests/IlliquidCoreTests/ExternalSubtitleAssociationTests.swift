import Foundation
import Testing
@testable import IlliquidCore

@Suite("Nonempty external subtitle associations")
struct ExternalSubtitleAssociationTests {
    @Test func multipleMatchesKeepNaturalOrderAndDuplicateSubtitleEntries() {
        let media = url("Archive.mkv")
        let first = url("Archive.1.srt")
        let second = url("Archive.2.srt")
        let tenth = url("Archive.10.srt")

        let matches = ExternalSubtitleMatcher.associate(
            subtitleURLs: [tenth, second, first, second],
            with: [media],
            isCancelled: { false }
        )

        // Numeric order is independent of the input order, and repeated input
        // subtitle URLs are retained rather than deduplicated during sorting.
        #expect(matches == [media: [first, second, second, tenth]])
    }

    @Test func aMoreSpecificDescendantWinsAfterTiedAncestorCandidates() {
        let firstAncestor = url("Show.mkv")
        let secondAncestor = url("Show.mp4")
        let descendant = url("Show Archive 12.mkv")
        let subtitle = url("Show Archive 12.en.srt")
        let expected: [URL: [URL]] = [
            firstAncestor: [], secondAncestor: [], descendant: [subtitle],
        ]

        // Both ancestor terminals are visited before the descendant terminal
        // regardless of dictionary iteration order. Their tied fuzzy scores
        // must not make the later, strictly better full-title match ambiguous.
        for media in [
            [firstAncestor, secondAncestor, descendant],
            [descendant, secondAncestor, firstAncestor],
        ] {
            #expect(ExternalSubtitleMatcher.associate(
                subtitleURLs: [subtitle], with: media, isCancelled: { false }
            ) == expected)
        }
    }

    @Test func fuzzyPrefixesRequireFourNormalizedCharactersInEitherDirection() {
        let fixtures: [(stem: String, expectedScore: Int?)] = [
            ("Cat", nil),
            ("Café", 5_060),
            ("ＡＢＣ", nil),
            ("ＡＢＣＤ", 5_060),
            ("猫犬鳥", nil),
            ("猫犬鳥魚", 5_060),
            ("A BC", nil),
            ("A BCD", 5_085),
        ]

        for fixture in fixtures {
            let shortMedia = url(fixture.stem + ".mkv")
            let longMedia = url(fixture.stem + ".Extended.mkv")
            let shortSubtitle = url(fixture.stem + ".srt")
            let longSubtitle = url(fixture.stem + ".Extended.srt")

            // CJK characters count once despite their multibyte encoding;
            // diacritic and full-width folding precede the specificity check.
            for (media, subtitle) in [
                (shortMedia, longSubtitle), (longMedia, shortSubtitle),
            ] {
                #expect(ExternalSubtitleMatcher.matchScore(
                    subtitleURL: subtitle, mediaURL: media
                ) == fixture.expectedScore)
                let expected: [URL] = fixture.expectedScore == nil ? [] : [subtitle]
                #expect(ExternalSubtitleMatcher.associate(
                    subtitleURLs: [subtitle], with: [media], isCancelled: { false }
                ) == [media: expected])
            }
        }
    }

    @Test func languageLikeTitleWordsAndReleaseSpecificityRemainDistinct() {
        let shorterTitle = url("The People.mkv")
        let firstRelease = url("The People US.1080p.mkv")
        let secondRelease = url("The People US.2160p.mp4")
        let shorterSubtitle = url("The People.en.srt")
        let ambiguousTitleSubtitle = url("The People US.en.srt")
        let releaseSubtitle = url("The People US.2160p.en.srt")

        #expect(ExternalSubtitleMatcher.associate(
            subtitleURLs: [releaseSubtitle, ambiguousTitleSubtitle, shorterSubtitle],
            with: [shorterTitle, firstRelease, secondRelease],
            isCancelled: { false }
        ) == [
            shorterTitle: [shorterSubtitle],
            firstRelease: [],
            secondRelease: [releaseSubtitle],
        ])

        // With only one full-title release, "US" still contributes to the
        // winning title rather than turning its subtitle into a shorter match.
        #expect(ExternalSubtitleMatcher.associate(
            subtitleURLs: [ambiguousTitleSubtitle],
            with: [shorterTitle, secondRelease],
            isCancelled: { false }
        ) == [shorterTitle: [], secondRelease: [ambiguousTitleSubtitle]])
    }

    @Test func singletonMatchesPreserveEveryOriginalMediaKey() {
        let media = url("Solo.1080p.mkv")
        let unrelated = url("Other.mkv")
        let unsupported = url("notes.txt")
        let extensionless = url("Solo")
        let remoteOne = URL(string: "https://example.invalid/Solo.mkv?edition=1")!
        let remoteTwo = URL(string: "https://example.invalid/Solo.mkv?edition=2")!
        let subtitle = url("Solo.en.srt")
        let remoteSubtitle = URL(string: "https://example.invalid/Solo.fr.srt")!
        let expected: [URL: [URL]] = [
            media: [subtitle], unrelated: [], unsupported: [], extensionless: [],
            remoteOne: [], remoteTwo: [],
        ]

        #expect(ExternalSubtitleMatcher.associate(
            subtitleURLs: [remoteSubtitle, url("Solo.sup"), subtitle],
            with: [remoteTwo, unsupported, media, unrelated, extensionless, remoteOne, media],
            isCancelled: { false }
        ) == expected)
    }

    @Test(arguments: [false, true])
    func cancellationDiscardsMixedEmptySingletonAndSortedResults(_ oneShot: Bool) {
        let multiple = url("Alpha.mkv")
        let singleton = url("Beta.mkv")
        let empty = url("Gamma.mkv")
        let unsupported = url("notes.txt")
        let second = url("Alpha.2.srt")
        let tenth = url("Alpha.10.srt")
        let only = url("Beta.fr.srt")
        let media = [empty, multiple, unsupported, singleton]
        let subtitles = [tenth, only, second]
        let expected: [URL: [URL]] = [
            multiple: [second, tenth], singleton: [only], empty: [], unsupported: [],
        ]
        var checkpointCount = 0
        let complete = ExternalSubtitleMatcher.associate(
            subtitleURLs: subtitles, with: media, isCancelled: {
                checkpointCount += 1
                return false
            }
        )
        #expect(complete == expected)
        #expect(checkpointCount > 0)

        // Include every finalization checkpoint: sorting a multi-entry value
        // while traversing the remaining empty/singleton dictionary entries
        // must still discard the entire result after one cancellation poll.
        for cancelAt in 1...checkpointCount {
            var checkpoint = 0
            let cancelled = ExternalSubtitleMatcher.associate(
                subtitleURLs: subtitles, with: media, isCancelled: {
                    checkpoint += 1
                    return oneShot ? checkpoint == cancelAt : checkpoint >= cancelAt
                }
            )
            #expect(checkpoint == cancelAt)
            #expect(cancelled.isEmpty, "Published partial associations at checkpoint \(cancelAt)")
        }
    }

    private func url(_ filename: String) -> URL {
        URL(fileURLWithPath: "/tmp/SubtitleAssociations", isDirectory: true)
            .appendingPathComponent(filename)
    }
}
