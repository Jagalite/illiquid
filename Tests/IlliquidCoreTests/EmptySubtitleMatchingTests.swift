import Foundation
import Testing
@testable import IlliquidCore

@Suite("Empty subtitle inventories")
struct EmptySubtitleMatchingTests {
    @Test func emptyInventoriesReturnAnEmptyDictionary() {
        #expect(ExternalSubtitleMatcher.associate(subtitleURLs: [], with: []).isEmpty)
    }

    @Test func emptySubtitleInventoryPreservesEveryOriginalMediaKey() {
        let media = url("Movie.1080p.mkv")
        let unicode = url("Épisode 世界 🎬.mp4")
        let unsupported = url("notes.txt")
        let remote = URL(string: "https://example.invalid/Movie.mkv")!
        let expected: [URL: [URL]] = [
            media: [], unicode: [], unsupported: [], remote: [],
        ]
        let inputs = [media, unicode, media, unsupported, remote, unicode]

        // The public result includes unsupported input URLs too. Duplicate
        // media inputs collapse to one original URL key, without losing keys.
        #expect(ExternalSubtitleMatcher.associate(
            subtitleURLs: [], with: inputs
        ) == expected)
        #expect(ExternalSubtitleMatcher.associate(
            subtitleURLs: [], with: Array(inputs.reversed())
        ) == expected)
    }

    @Test func matchingSubtitlesAcceptsAnEmptyInventory() {
        #expect(ExternalSubtitleMatcher.matchingSubtitles(
            for: url("Show.S01E02.1080p.mkv"), among: []
        ).isEmpty)
    }

    @Test(arguments: [false, true])
    func cancellationAtEveryEmptyInventoryCheckpointDiscardsAllKeys(_ singleObservation: Bool) {
        let first = url("Movie.mkv")
        let unicode = url("Épisode 世界.mp4")
        let unsupported = url("notes.txt")
        let media = [first, unicode, first, unsupported]
        let expected: [URL: [URL]] = [first: [], unicode: [], unsupported: []]
        var checkpointCount = 0
        let completed = ExternalSubtitleMatcher.associate(
            subtitleURLs: [], with: media, isCancelled: {
                checkpointCount += 1
                return false
            }
        )
        #expect(completed == expected)
        #expect(checkpointCount > 0)

        // Discover the callback count rather than make it an API guarantee.
        // The last iteration cancels at the final observation before return;
        // one-shot cancellation must still discard the populated dictionary.
        for cancelAt in 1...checkpointCount {
            var checkpoint = 0
            let cancelled = ExternalSubtitleMatcher.associate(
                subtitleURLs: [], with: media, isCancelled: {
                    checkpoint += 1
                    return singleObservation ? checkpoint == cancelAt : checkpoint >= cancelAt
                }
            )
            #expect(checkpoint == cancelAt)
            #expect(cancelled.isEmpty, "Returned media keys at cancellation checkpoint \(cancelAt)")
        }
    }

    @Test func cancellationAfterKeyPopulationDiscardsTheEmptyInventoryResult() {
        let media = [url("Movie.mkv"), url("Épisode 世界.mp4"), url("notes.txt")]
        // One initial observation and one before inserting each input key.
        // Cancellation becomes visible immediately after all keys are present.
        let cancelAt = 1 + media.count + 1
        var checkpoint = 0
        let result = ExternalSubtitleMatcher.associate(
            subtitleURLs: [], with: media, isCancelled: {
                checkpoint += 1
                return checkpoint == cancelAt
            }
        )

        #expect(checkpoint == cancelAt)
        #expect(result.isEmpty)
    }

    @Test func emptyInventoryObservesDefaultTaskCancellation() async {
        let media = [url("Movie.mkv")]
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return ExternalSubtitleMatcher.associate(subtitleURLs: [], with: media)
        }
        let result = await task.value
        #expect(result.isEmpty)
    }

    @Test func playlistWithoutSubtitlesPreservesMediaOrderDeduplicationAndDates() {
        let first = url("Episode 1.mkv")
        let second = url("Episode 2.MP4")
        let tenth = url("Episode 10.mkv")
        let firstDate = Date(timeIntervalSince1970: 100)
        let secondDate = Date(timeIntervalSince1970: 200)
        let tenthDate = Date(timeIntervalSince1970: 1_000)
        let expectedDates: [Date?] = [firstDate, secondDate, tenthDate]
        let playlist = FolderPlaylistDiscovery.makePlaylist(
            folderURL: folderURL,
            mediaURLs: [tenth, second, first, second],
            subtitleURLs: [],
            metadataDates: [first: firstDate, second: secondDate, tenth: tenthDate]
        )

        #expect(playlist.folderURL == folderURL)
        #expect(playlist.mediaURLs == [first, second, tenth])
        #expect(playlist.items.map(\.dateAdded) == expectedDates)
        #expect(playlist.items.allSatisfy { $0.externalSubtitleURLs.isEmpty })
    }

    private let folderURL = URL(fileURLWithPath: "/tmp/EmptySubtitleMatching", isDirectory: true)

    private func url(_ filename: String) -> URL {
        folderURL.appendingPathComponent(filename)
    }
}
