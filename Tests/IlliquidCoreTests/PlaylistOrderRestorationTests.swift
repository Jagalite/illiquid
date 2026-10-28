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
        #expect(PlaylistMutation.restoringIDs(
            [first, other, duplicate], ids: [other.id, duplicate.id]
        ) == [other.id, first.id])
    }

    @Test func nonFileIdentitiesRetainDistinctQueryStrings() throws {
        let a = FolderPlaylistItem(url: try #require(URL(string: "https://example.invalid/media?id=1")))
        let b = FolderPlaylistItem(url: try #require(URL(string: "https://example.invalid/media?id=2")))
        #expect(PlaylistMutation.restoringOrder([b, a, b], ids: [a.id]) == [a, b])
        #expect(PlaylistMutation.restoringIDs(
            [b, a, b], ids: [a.id]
        ) == [a.id, b.id])
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

    @Test func identityProjectionNormalizesRawDecodedItems() throws {
        // Synthesized Decodable bypasses FolderPlaylistItem's normalizing init.
        let raw = try #require(
            URL(string: "file://LOCALHOST/Media/Season/../Cafe%CC%81.mkv")
        )
        let payload = RawRestorationItemPayload(
            url: raw,
            externalSubtitleURLs: [URL(fileURLWithPath: "/Media/first.srt")],
            dateAdded: Date(timeIntervalSince1970: 1)
        )
        let decoded = try JSONDecoder().decode(
            FolderPlaylistItem.self,
            from: JSONEncoder().encode(payload)
        )
        let duplicate = FolderPlaylistItem(
            url: URL(fileURLWithPath: "/Media/Café.mkv"),
            externalSubtitleURLs: [URL(fileURLWithPath: "/Media/second.srt")],
            dateAdded: Date(timeIntervalSince1970: 2)
        )
        let other = item(7)
        let items = [other, decoded, duplicate]

        #expect(decoded.url.absoluteString == raw.absoluteString)
        #expect(decoded.url.absoluteString.contains("/Season/../"))
        let projected = PlaylistMutation.restoringIDs(
            items,
            ids: ["/Media/Café.mkv", "/Media/Missing.mkv", "/Media/Café.mkv"]
        )
        #expect(projected == ["/Media/Café.mkv", other.id])
        #expect(PlaylistMutation.restoringOrder(
            items, ids: projected
        ) == [decoded, other])
    }

    @Test func identityProjectionReturnsCurrentUnicodeRepresentation() throws {
        let canonicalID = "/Media/Caf\u{00E9}.mkv"
        let savedID = "/Media/Cafe\u{301}.mkv"
        let current = FolderPlaylistItem(url: URL(fileURLWithPath: canonicalID))
        let other = item(8)

        #expect(savedID == canonicalID)
        #expect(Array(savedID.utf8) != Array(canonicalID.utf8))
        // Two items exercise set removal, rather than the singleton shortcut.
        let projected = PlaylistMutation.restoringIDs(
            [other, current], ids: [savedID, canonicalID]
        )
        #expect(projected == [canonicalID, other.id])
        let first = try #require(projected.first)
        #expect(Array(first.utf8) == Array(canonicalID.utf8))
    }

    @Test func checkpointIdentityProjectionPreservesOrderAcrossEdits() throws {
        let a = item(0), b = item(1), c = item(2)
        let d = item(3), e = item(4), f = item(5)
        let originalIDs = [a.id, b.id, c.id]

        // B was removed; D and E were appended while shuffled.
        let firstItems = [c, a, d, e, item(0, revision: 7)]
        var checkpointIDs = PlaylistMutation.restoringIDs(
            firstItems, ids: originalIDs
        )
        #expect(checkpointIDs == [a.id, c.id, d.id, e.id])
        let restoredIDs = try JSONDecoder().decode(
            [FolderPlaylistItem.ID].self,
            from: JSONEncoder().encode(checkpointIDs)
        )
        #expect(restoredIDs == checkpointIDs)
        #expect(PlaylistMutation.restoringIDs(
            firstItems, ids: restoredIDs
        ) == checkpointIDs)
        #expect(PlaylistMutation.restoringOrder(
            firstItems, ids: restoredIDs
        ) == [a, c, d, e])

        // The next checkpoint removes A and appends F.
        let secondItems = [e, d, c, item(2, revision: 9), f]
        checkpointIDs = PlaylistMutation.restoringIDs(
            secondItems, ids: restoredIDs
        )
        #expect(checkpointIDs == [c.id, d.id, e.id, f.id])
        #expect(PlaylistMutation.restoringOrder(
            secondItems, ids: checkpointIDs
        ) == [c, d, e, f])

        let finalItems = [f, c]
        checkpointIDs = PlaylistMutation.restoringIDs(
            finalItems, ids: checkpointIDs
        )
        #expect(checkpointIDs == [c.id, f.id])
        #expect(PlaylistMutation.restoringOrder(
            finalItems, ids: checkpointIDs
        ) == [c, f])
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
                var expectedIDs: [FolderPlaylistItem.ID] = []
                var emitted: Set<Int> = []
                // This oracle works with integer labels, not production ID maps.
                for label in saved.labels + current {
                    guard let firstIndex = current.firstIndex(of: label),
                          emitted.insert(label).inserted else { continue }
                    expected.append(items[firstIndex])
                    expectedIDs.append(identities[label])
                }
                #expect(PlaylistMutation.restoringOrder(items, ids: saved.ids) == expected)
                #expect(PlaylistMutation.restoringIDs(items, ids: saved.ids) == expectedIDs)
                checked += 1
            }
        }
        #expect(checked == 41_261)
    }

    private struct RawRestorationItemPayload: Encodable {
        let url: URL
        let externalSubtitleURLs: [URL]
        let dateAdded: Date?
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
