import Foundation
import Testing
@testable import IlliquidCore

@Suite("Playlist order restoration")
struct PlaylistOrderRestorationTests {
    @Test func emptyQueueDoesNotRestoreRemovedEntries() {
        #expect(PlaylistMutation.restoringOrder([], ids: []) == [])
        #expect(PlaylistMutation.restoringOrder([], ids: [item(0).id, item(0).id]) == [])
    }

    @Test func emptyBaseKeepsFirstOccurrencesInCurrentOrder() {
        let first = item(1, revision: 1)
        let duplicate = item(1, revision: 2)
        let second = item(0)
        #expect(PlaylistMutation.restoringOrder(
            [first, second, duplicate], ids: []
        ) == [first, second])
    }

    @Test func savedOrderPrecedesNewEntriesWithoutResurrectingRemovals() {
        let a = item(0), b = item(1), c = item(2), d = item(3), e = item(4)
        #expect(PlaylistMutation.restoringOrder(
            [e, c, d, a], ids: [a.id, b.id, c.id]
        ) == [a, c, e, d])
    }

    @Test func repeatedAndMissingSavedIDsDoNotDuplicateOrReplaceMetadata() {
        let first = item(0, revision: 1)
        let duplicate = item(0, revision: 2)
        let second = item(1)
        #expect(PlaylistMutation.restoringOrder(
            [second, first, duplicate],
            ids: ["/removed", first.id, first.id, "/removed", second.id]
        ) == [first, second])
    }

    @Test func normalizedAliasesKeepTheFirstCompleteItem() {
        let first = FolderPlaylistItem(
            url: URL(fileURLWithPath: "/Media/Season/../Cafe\u{301}.mkv"),
            externalSubtitleURLs: [URL(fileURLWithPath: "/Media/first.srt")],
            dateAdded: Date(timeIntervalSince1970: 1)
        )
        let duplicate = FolderPlaylistItem(
            url: URL(fileURLWithPath: "/Media/Café.mkv"),
            externalSubtitleURLs: [URL(fileURLWithPath: "/Media/second.srt")],
            dateAdded: Date(timeIntervalSince1970: 2)
        )
        let other = item(1)
        #expect(first.id == duplicate.id)
        #expect(PlaylistMutation.restoringOrder(
            [first, other, duplicate], ids: [other.id, duplicate.id]
        ) == [other, first])
    }

    @Test func nonFileIdentitiesRetainDistinctQueryStrings() throws {
        let a = FolderPlaylistItem(url: try #require(URL(string: "https://example.invalid/media?id=1")))
        let b = FolderPlaylistItem(url: try #require(URL(string: "https://example.invalid/media?id=2")))
        #expect(PlaylistMutation.restoringOrder([b, a, b], ids: [a.id]) == [a, b])
    }

    @Test func repeatedShuffleEditsPreservePlaybackIdentityAndNewItemOrder() {
        let a = item(0), b = item(1), c = item(2), d = item(3), e = item(4)
        let originalIDs = [a.id, b.id, c.id]
        // While shuffled: B was removed, D and E were appended, C is playing.
        let restored = PlaylistMutation.restoringOrder([c, a, d, e], ids: originalIDs)
        #expect(restored == [a, c, d, e])
        #expect(PlaylistMutation.indexPreservingCurrentIdentity(
            currentURL: c.url, fallbackIndex: 0, in: restored
        ) == 1)
        #expect(PlaylistMutation.restoringOrder(restored, ids: originalIDs) == restored)
        // A second shuffle must not restore a subsequently removed A.
        #expect(PlaylistMutation.restoringOrder(
            [e, d, c], ids: restored.map(\.id)
        ) == [c, d, e])
    }

    @Test func allSmallQueueAndSavedOrderSequencesMatchAnIndependentModel() {
        let currentSequences = sequences(alphabetSize: 3, maximumLength: 4)
        let savedSequences = sequences(alphabetSize: 4, maximumLength: 4)
        let identities = (0..<4).map { item($0).id }
        let savedCases = savedSequences.map { labels in
            (labels: labels, ids: labels.map { identities[$0] })
        }
        var checked = 0
        for current in currentSequences {
            // Repeated identities deliberately carry different metadata.
            let items = current.enumerated().map { item($0.element, revision: $0.offset) }
            for saved in savedCases {
                var expected: [FolderPlaylistItem] = []
                var emitted: Set<Int> = []
                // This oracle works with integer labels, not production ID maps.
                for label in saved.labels + current {
                    guard let firstIndex = current.firstIndex(of: label),
                          emitted.insert(label).inserted else { continue }
                    expected.append(items[firstIndex])
                }
                #expect(PlaylistMutation.restoringOrder(items, ids: saved.ids) == expected)
                checked += 1
            }
        }
        #expect(checked == 41_261)
    }

    private func item(_ number: Int, revision: Int = 0) -> FolderPlaylistItem {
        FolderPlaylistItem(
            url: URL(fileURLWithPath: "/Media/Episode \(number).mkv"),
            externalSubtitleURLs: [URL(fileURLWithPath: "/Media/\(number)-\(revision).srt")],
            dateAdded: Date(timeIntervalSince1970: Double(revision))
        )
    }

    private func sequences(alphabetSize: Int, maximumLength: Int) -> [[Int]] {
        var result: [[Int]] = [[]]
        var layer: [[Int]] = [[]]
        for _ in 0..<maximumLength {
            layer = layer.flatMap { prefix in (0..<alphabetSize).map { prefix + [$0] } }
            result += layer
        }
        return result
    }
}
