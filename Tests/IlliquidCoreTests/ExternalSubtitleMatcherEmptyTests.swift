import Foundation
import Testing
@testable import IlliquidCore

@Suite("External subtitle matching with an empty subtitle inventory")
struct ExternalSubtitleMatcherEmptyTests {
    @Test func emptyInputsReturnAnEmptyDictionary() {
        #expect(ExternalSubtitleMatcher.associate(
            subtitleURLs: [], with: [], isCancelled: { false }
        ).isEmpty)
    }

    @Test func emptyInventoryPreservesEveryOriginalMediaKey() throws {
        let movie = url("Movie.mkv")
        let unicode = url("Épisode 東京.mp4")
        let unsupportedFile = url("notes.txt")
        let extensionless = url("README")
        let remoteOne = try #require(URL(
            string: "https://example.invalid/Movie.mkv?edition=one"
        ))
        let remoteTwo = try #require(URL(
            string: "https://example.invalid/Movie.mkv?edition=two"
        ))
        let media = [
            movie, unicode, unsupportedFile, extensionless, remoteOne, remoteTwo,
        ]
        let expected: [URL: [URL]] = [
            movie: [],
            unicode: [],
            unsupportedFile: [],
            extensionless: [],
            remoteOne: [],
            remoteTwo: [],
        ]

        #expect(ExternalSubtitleMatcher.associate(
            subtitleURLs: [], with: media, isCancelled: { false }
        ) == expected)
    }

    @Test func duplicateMediaKeysKeepOneEmptyValue() {
        let first = url("Episode 1.mkv")
        let second = url("Episode 2.mkv")
        let expected: [URL: [URL]] = [first: [], second: []]

        #expect(ExternalSubtitleMatcher.associate(
            subtitleURLs: [],
            with: [first, first, second, first, second],
            isCancelled: { false }
        ) == expected)
    }

    @Test func cancellationBeforeInsertionReturnsNoKeys() {
        var checkpoints = 0
        let matches = ExternalSubtitleMatcher.associate(
            subtitleURLs: [],
            with: [url("Movie.mkv"), url("notes.txt")],
            isCancelled: {
                checkpoints += 1
                return true
            }
        )

        #expect(checkpoints == 1)
        #expect(matches.isEmpty)
    }

    @Test func cancellationDuringInsertionDiscardsEarlierKeys() {
        let first = url("Episode 1.mkv")
        let media = [first, first, url("Episode 2.mkv"), url("notes.txt")]

        // The initial poll is followed by one poll per original input entry,
        // including duplicate keys. Cancellation must discard any earlier keys.
        for cancelAt in 2...(media.count + 1) {
            var checkpoints = 0
            let matches = ExternalSubtitleMatcher.associate(
                subtitleURLs: [], with: media, isCancelled: {
                    checkpoints += 1
                    return checkpoints == cancelAt
                }
            )

            #expect(checkpoints == cancelAt)
            #expect(
                matches.isEmpty,
                "Published keys after insertion checkpoint \(cancelAt)"
            )
        }
    }

    @Test func cancellationAtTheEmptyReturnBoundaryDiscardsAllKeys() {
        let first = url("Episode 1.mkv")
        let inventories: [[URL]] = [
            [],
            [first],
            [first, first, url("notes.txt")],
        ]

        for media in inventories {
            // One initial poll and one poll per input entry precede the new
            // return boundary. The next poll must still observe cancellation.
            // The baseline may encounter it during subsequent indexing/sorting.
            let cancelAt = media.count + 2
            var checkpoints = 0
            let matches = ExternalSubtitleMatcher.associate(
                subtitleURLs: [], with: media, isCancelled: {
                    checkpoints += 1
                    return checkpoints == cancelAt
                }
            )

            #expect(checkpoints == cancelAt)
            #expect(
                matches.isEmpty,
                "Published completed keys after cancellation at the return boundary"
            )
        }
    }

    @Test(arguments: [false, true])
    func cancellationAtEveryObservedEmptyCheckpointDiscardsKeys(
        _ singleObservation: Bool
    ) {
        let first = url("Episode 1.mkv")
        let inventories: [[URL]] = [
            [],
            [first],
            [first, first, url("Épisode 東京.mp4"), url("notes.txt")],
        ]

        for media in inventories {
            var checkpointCount = 0
            let complete = ExternalSubtitleMatcher.associate(
                subtitleURLs: [], with: media, isCancelled: {
                    checkpointCount += 1
                    return false
                }
            )
            #expect(Set(complete.keys) == Set(media))
            #expect(complete.values.allSatisfy { $0.isEmpty })
            #expect(checkpointCount > 0)

            // Polling during eliminated work is not part of the output
            // contract. Sweep each implementation's actual checkpoints.
            for cancelAt in 1...checkpointCount {
                var checkpoint = 0
                let cancelled = ExternalSubtitleMatcher.associate(
                    subtitleURLs: [], with: media, isCancelled: {
                        checkpoint += 1
                        return singleObservation
                            ? checkpoint == cancelAt
                            : checkpoint >= cancelAt
                    }
                )

                #expect(checkpoint == cancelAt)
                #expect(
                    cancelled.isEmpty,
                    "Returned keys after observing cancellation at checkpoint \(cancelAt)"
                )
            }
        }
    }

    @Test func nonemptySubtitleInventoryStillMatchesAndSorts() {
        let episodeTwo = url("Episode 2.mkv")
        let episodeTen = url("Episode 10.mkv")
        let unsupported = url("notes.txt")
        let english = url("Episode 2.en.srt")
        let french = url("Episode 2.fr.srt")
        let episodeTenSubtitle = url("Episode 10.en.srt")
        let ambiguous = url("Episode.srt")
        let expected: [URL: [URL]] = [
            episodeTwo: [english, french],
            episodeTen: [episodeTenSubtitle],
            unsupported: [],
        ]

        #expect(ExternalSubtitleMatcher.associate(
            subtitleURLs: [
                french, episodeTenSubtitle, ambiguous, english, unsupported,
            ],
            with: [episodeTen, episodeTwo, unsupported],
            isCancelled: { false }
        ) == expected)
    }

    private func url(_ filename: String) -> URL {
        URL(fileURLWithPath: "/tmp/EmptySubtitleMatcher", isDirectory: true)
            .appendingPathComponent(filename)
    }
}
