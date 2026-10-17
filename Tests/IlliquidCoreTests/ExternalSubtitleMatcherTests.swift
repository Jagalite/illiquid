import Foundation
import Testing
@testable import IlliquidCore

@Suite("External subtitle matching")
struct ExternalSubtitleMatcherTests {
    @Test func emptySubtitleInventoryRetainsOriginalMediaKeys() throws {
        let media = url("Épisode 1.mkv")
        let unsupported = url("Notes.txt")
        let remote = try #require(URL(string: "https://example.com/Episode.mkv"))
        let remoteFile = try #require(URL(string: "file://media.example/Episode.mkv"))
        let lexicalAlias = try #require(URL(string: "file:///tmp/Shows/Season/../Episode.mkv"))
        let expected: [URL: [URL]] = [
            media: [], unsupported: [], remote: [], remoteFile: [], lexicalAlias: [],
        ]

        #expect(ExternalSubtitleMatcher.associate(
            subtitleURLs: [],
            with: [media, unsupported, media, remote, remoteFile, lexicalAlias]
        ) == expected)
        #expect(ExternalSubtitleMatcher.matchingSubtitles(for: media, among: []).isEmpty)
    }

    @Test func emptyMediaAndSubtitleInventoriesReturnNoAssociations() {
        #expect(ExternalSubtitleMatcher.associate(subtitleURLs: [], with: []).isEmpty)
    }

    @Test(arguments: [false, true])
    func cancellationAtEveryEmptySubtitleCheckpointDiscardsMediaKeys(_ singleObservation: Bool) throws {
        let media = url("Movie.mkv")
        let unsupported = url("Notes.txt")
        let remote = try #require(URL(string: "https://example.com/Movie.mkv"))
        let inventories: [[URL]] = [[], [media, unsupported, media, remote]]

        for inventory in inventories {
            var checkpointCount = 0
            let complete = ExternalSubtitleMatcher.associate(
                subtitleURLs: [], with: inventory, isCancelled: {
                    checkpointCount += 1
                    return false
                }
            )
            #expect(Set(complete.keys) == Set(inventory))
            #expect(complete.values.allSatisfy(\.isEmpty))
            // Include cancellation before population, during every input item,
            // and immediately before the completed dictionary is returned.
            #expect(checkpointCount >= inventory.count + 2)

            for cancelAt in 1...checkpointCount {
                var checkpoint = 0
                let cancelled = ExternalSubtitleMatcher.associate(
                    subtitleURLs: [], with: inventory, isCancelled: {
                        checkpoint += 1
                        return singleObservation ? checkpoint == cancelAt : checkpoint >= cancelAt
                    }
                )
                #expect(checkpoint == cancelAt)
                #expect(cancelled.isEmpty, "Returned media keys at empty-subtitle checkpoint \(cancelAt)")
            }
        }
    }

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

    @Test func indexedMatchingAgreesWithExhaustiveScoringAcrossAllSubsets() {
        // Unlike the all-two-container fixture above, these 256 inventories
        // include unique winners, equal-score ties, and completely unrelated names.
        let inventory = [
            url("Show.mkv"), url("Show Episode 1.1080p.mkv"),
            url("Show Episode 1.2160p.mp4"), url("Show Episode 10.mkv"),
            url("Show.en.mkv"), url("The Last of.mkv"),
            url("The Last of Us.1080p.mkv"), url("épisode I.mkv"),
        ]
        let subtitles = [
            "Show.srt", "Show.en.forced.ass", "Show Episode 1.en.srt",
            "Show Episode 1.2160p.en.srt", "Show Episode 10.ssa",
            "Show.en.vtt", "The Last of Us.en.srt", "The Last of.srt",
            "EPISODE.I.en.srt", "Unrelated.idx", "Show Episode.srt", "Show.txt",
        ].map(url)
        var uniqueWinners = 0
        var ambiguousMatches = 0
        var unmatched = 0

        for mask in 0..<(1 << inventory.count) {
            let media = inventory.enumerated().compactMap { index, video in
                mask & (1 << index) == 0 ? nil : video
            }
            var expected = Dictionary(uniqueKeysWithValues: media.map { ($0, [URL]()) })
            for subtitle in subtitles {
                let scores = media.compactMap { video in
                    ExternalSubtitleMatcher.matchScore(subtitleURL: subtitle, mediaURL: video)
                        .map { (video, $0) }
                }
                guard let best = scores.map(\.1).max() else {
                    unmatched += 1
                    continue
                }
                let winners = scores.filter { $0.1 == best }
                if winners.count == 1 {
                    uniqueWinners += 1
                    expected[winners[0].0, default: []].append(subtitle)
                } else {
                    ambiguousMatches += 1
                }
            }
            expected = expected.mapValues { NaturalFilenameOrdering.sort($0) }
            #expect(ExternalSubtitleMatcher.associate(
                subtitleURLs: subtitles, with: media
            ) == expected, "Inventory mask \(mask)")
            #expect(ExternalSubtitleMatcher.associate(
                subtitleURLs: Array(subtitles.reversed()), with: Array(media.reversed())
            ) == expected, "Reversed inventory mask \(mask)")
        }

        // Keep the reference comparison non-vacuous when this corpus changes.
        #expect(uniqueWinners > 0)
        #expect(ambiguousMatches > 0)
        #expect(unmatched > 0)
    }

    @Test func releaseSpecificSubtitlesDisambiguateOtherwiseEqualEncodes() {
        let media = [url("Movie.1080p.mkv"), url("Movie.2160p.mp4")]
        let generic = url("Movie.en.srt")
        let specific = url("Movie.2160p.en.srt")
        let matches = ExternalSubtitleMatcher.associate(
            subtitleURLs: [generic, specific], with: media
        )
        #expect(matches[media[0]] == [])
        #expect(matches[media[1]] == [specific])
    }

    @Test(arguments: ["ass", "idx", "srt", "ssa", "vtt"])
    func allSupportedFormatsPreserveUnicodeTitleSpecificity(_ fileExtension: String) {
        let media = [url("Épisode.mkv"), url("Épisode I.1080p.mkv")]
        let subtitle = url("EPISODE.I.en.forced." + fileExtension.uppercased())
        let matches = ExternalSubtitleMatcher.associate(subtitleURLs: [subtitle], with: media)
        #expect(matches[media[0]] == [])
        #expect(matches[media[1]] == [subtitle])
    }

    @Test func duplicateMediaAndUnrelatedInputsDoNotCreateAmbiguity() {
        let media = url("Movie.mkv")
        let subtitle = url("Movie.en.srt")
        let ignored = url("Movie.txt")
        let unrelated = (1...128).map { url("Unrelated \($0).mkv") }
        let matches = ExternalSubtitleMatcher.associate(
            subtitleURLs: [ignored, subtitle], with: [media, media, ignored] + unrelated
        )
        #expect(matches[media] == [subtitle])
        #expect(matches[ignored] == [])
        #expect(unrelated.allSatisfy { matches[$0] == [] })
    }

    @Test func cancelledMatchingDoesNotReturnPartialAssociations() {
        #expect(ExternalSubtitleMatcher.associate(
            subtitleURLs: [url("Show.srt")], with: [url("Show.mkv")], isCancelled: { true }
        ).isEmpty)
    }

    @Test(arguments: [false, true])
    func cancellationAtEveryCheckpointDiscardsEarlierMatches(_ singleObservation: Bool) {
        // The first subtitle has a unique winner. The last lookup traverses a
        // whole subtree, where cancellation must not be mistaken for no matches.
        let media = [url("Alpha.mkv"), url("Show Episode 1.mkv"), url("Show Episode 2.mkv")]
        let subtitles = [url("Alpha.en.srt"), url("Show.srt")]
        var checkpointCount = 0
        let complete = ExternalSubtitleMatcher.associate(
            subtitleURLs: subtitles, with: media, isCancelled: {
                checkpointCount += 1
                return false
            }
        )
        #expect(complete[media[0]] == [subtitles[0]])
        #expect(complete[media[1]] == [])
        #expect(complete[media[2]] == [])
        #expect(checkpointCount > 0)

        for cancelAt in 1...checkpointCount {
            var checkpoint = 0
            let cancelled = ExternalSubtitleMatcher.associate(
                subtitleURLs: subtitles, with: media, isCancelled: {
                    checkpoint += 1
                    return singleObservation ? checkpoint == cancelAt : checkpoint >= cancelAt
                }
            )
            #expect(checkpoint == cancelAt)
            #expect(cancelled.isEmpty, "Returned partial associations at checkpoint \(cancelAt)")
        }
    }

    @Test func defaultCancellationPredicateObservesTheCurrentTask() async {
        let media = [url("Movie.mkv")]
        let subtitles = [url("Movie.en.srt")]
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return ExternalSubtitleMatcher.associate(subtitleURLs: subtitles, with: media)
        }
        let matches = await task.value
        #expect(matches.isEmpty)
    }

    @Test func cancellationWithOnlyUnsupportedFilesReturnsNoAssociations() {
        #expect(ExternalSubtitleMatcher.associate(
            subtitleURLs: [url("Movie.txt")], with: [url("Movie.pdf")], isCancelled: { true }
        ).isEmpty)
    }

    private let folderURL = URL(fileURLWithPath: "/tmp/Shows", isDirectory: true)

    @Test(arguments: [".srt", ".en.srt", ".en.forced.ass", ".en.sdh.vtt"])
    func titleWordsAreNotMistakenForSubtitleSuffixes(_ suffix: String) {
        let shorter = url("The Last of.mkv")
        let full = url("The Last of Us.mkv")
        let subtitle = url("The Last of Us" + suffix)
        for media in [[shorter, full], [full, shorter]] {
            let matches = ExternalSubtitleMatcher.associate(subtitleURLs: [subtitle], with: media)
            #expect(matches[shorter] == [])
            #expect(matches[full] == [subtitle])
        }
    }

    @Test(arguments: ["1080p", "1080i", "HEVC", "1080p.WEB-DL.x265"])
    func releaseSuffixDoesNotReduceTitleSpecificity(_ release: String) {
        let shorter = url("The Last of.mkv")
        let full = url("The Last of Us." + release + ".mkv")
        let subtitle = url("THE.LAST.OF.US.eng.srt")
        let matches = ExternalSubtitleMatcher.associate(subtitleURLs: [subtitle], with: [shorter, full])
        #expect(matches[shorter] == [])
        #expect(matches[full] == [subtitle])
    }

    @Test(arguments: ["I", "P"])
    func standaloneLettersRemainPartOfTheMediaTitle(_ letter: String) {
        let shorter = url("Chapter.mkv")
        let full = url("Chapter " + letter + ".mkv")
        let shorterSubtitle = url("Chapter.srt")
        let fullSubtitle = url("Chapter " + letter + ".en.srt")
        let matches = ExternalSubtitleMatcher.associate(
            subtitleURLs: [shorterSubtitle, fullSubtitle], with: [shorter, full]
        )
        #expect(matches[shorter] == [shorterSubtitle])
        #expect(matches[full] == [fullSubtitle])
        #expect(ExternalSubtitleMatcher.matchingSubtitles(
            for: full, among: [url("Chapter II.en.srt")]
        ).isEmpty)
    }

    @Test func identicalStemsInDifferentContainersRemainAmbiguous() {
        let media = [url("The Last of Us.mkv"), url("The Last of Us.mp4")]
        let matches = ExternalSubtitleMatcher.associate(
            subtitleURLs: [url("The Last of Us.en.srt")], with: media
        )
        #expect(media.allSatisfy { matches[$0] == [] })
    }

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
