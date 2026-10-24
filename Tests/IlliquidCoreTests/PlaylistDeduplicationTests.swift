import Foundation
import Testing
@testable import IlliquidCore

@Suite("Playlist deduplication")
struct PlaylistDeduplicationTests {
    @Test func emptySingletonAndUniquePlaylistsKeepTheirOrderAndMetadata() {
        let unique = [item("Episode 10", marker: 10), item("Episode 2", marker: 2),
                      item("Episode 1", marker: 1)]
        for input in [[], [unique[0]], unique] {
            let result = PlaylistMutation.deduplicated(input)
            #expect(result == input)
            #expect(PlaylistMutation.deduplicated(result) == input)
        }
    }

    @Test(arguments: [1, 2, 4, 7, 8])
    func firstDuplicateAtDifferentPositionsDoesNotLoseFollowingItems(position: Int) {
        let unique = (0..<8).map { item("Episode \($0)", marker: $0) }
        let replacement = item("Episode 0", marker: 100)
        var input = unique
        input.insert(replacement, at: position)

        #expect(PlaylistMutation.deduplicated(input) == unique)
        #expect(input[position] == replacement)
    }

    @Test func adjacentAndSeparatedDuplicatesKeepTheFirstCompleteItem() {
        let first = item("First", marker: 1)
        let second = item("Second", marker: 2)
        let third = item("Third", marker: 3)
        let laterFirst = item("First", marker: 4)
        let laterSecond = item("Second", marker: 5)
        let input = [first, laterFirst, second, laterSecond, laterFirst, third, second]

        #expect(PlaylistMutation.deduplicated(input) == [first, second, third])
        #expect(PlaylistMutation.deduplicated(Array(repeating: first, count: 64)) == [first])
    }

    @Test func normalizedIdentitiesPreserveTheFirstDecodedRepresentation() throws {
        // Codable can supply URLs without going through the normalizing item
        // initializer. Identity must still use the existing normalization rule.
        let raw = try decodedItem(
            "file://LOCALHOST/Media/Season/../Cafe%CC%81.mkv?source=restore#chapter",
            marker: 1
        )
        let canonical = item("Caf\u{00E9}", marker: 2)
        let other = item("Other", marker: 3)
        #expect(raw.id == canonical.id)
        #expect(raw.url.absoluteString != canonical.url.absoluteString)

        let rawFirst = PlaylistMutation.deduplicated([raw, other, canonical])
        #expect(rawFirst == [raw, other])
        #expect(rawFirst[0].url.absoluteString == raw.url.absoluteString)
        #expect(rawFirst[0].externalSubtitleURLs == raw.externalSubtitleURLs)
        #expect(rawFirst[0].dateAdded == raw.dateAdded)
        #expect(PlaylistMutation.deduplicated([canonical, raw, other]) == [canonical, other])
    }

    @Test func unsupportedLocalAuthoritiesAndRemoteURLsKeepTheirFallbackIdentity() throws {
        let local = item("Movie", marker: 1)
        let remote = try decodedItem("https://example.invalid/Media/Movie.mkv", marker: 2)
        let sameRemote = try decodedItem("https://example.invalid/Media/Movie.mkv", marker: 3)
        let differentRemote = try decodedItem("https://other.invalid/Media/Movie.mkv", marker: 4)
        let nonlocalFile = try decodedItem("file://archive.invalid/Media/Movie.mkv", marker: 5)
        let input = [local, remote, differentRemote, nonlocalFile, sameRemote, local]

        #expect(PlaylistMutation.deduplicated(input) == [local, remote, differentRemote, nonlocalFile])
    }

    @Test(arguments: [false, true])
    func resultsAndExistingSnapshotsRemainIndependentAfterMutation(hasDuplicate: Bool) {
        let first = item("First", marker: 1)
        let second = item("Second", marker: 2)
        var input = hasDuplicate ? [first, second, first] : [first, second]
        let snapshot = input
        var result = PlaylistMutation.deduplicated(input)
        let deduplicatedSnapshot = result

        result[0] = item("Replacement", marker: 3)
        result.append(item("Added", marker: 4))
        #expect(input == snapshot)
        #expect(deduplicatedSnapshot == [first, second])

        input.removeAll()
        #expect(snapshot == (hasDuplicate ? [first, second, first] : [first, second]))
        #expect(deduplicatedSnapshot == [first, second])
        #expect(result.map(\.url.lastPathComponent) == ["Replacement.mkv", "Second.mkv", "Added.mkv"])
    }

    @Test(arguments: [0, 1, 32])
    func heavilyReducedPlaylistsKeepSurvivingMetadataAndIndependentSnapshots(survivors: Int) {
        var input = (0..<256).map { item("Episode \($0)", marker: $0) }
        let originalSnapshot = input
        input.removeSubrange(survivors..<input.count)
        let reducedSnapshot = input
        var result = PlaylistMutation.deduplicated(input)

        #expect(result == Array(originalSnapshot.prefix(survivors)))
        #expect(result == reducedSnapshot)
        result.append(item("New episode", marker: 999))
        input.removeAll(keepingCapacity: true)
        #expect(reducedSnapshot == Array(originalSnapshot.prefix(survivors)))
        #expect(originalSnapshot.count == 256)
        #expect(result.count == survivors + 1)
        #expect(result.last == item("New episode", marker: 999))
    }

    @Test func mixedIdentityInputsMatchStableFirstOccurrenceSemantics() throws {
        let corpus = [
            item("Episode 1", marker: 1),
            item("Episode 2", marker: 2),
            item("Episode 1", marker: 3),
            try decodedItem("file://localhost/Media/Season/../Episode%202.mkv", marker: 4),
            item("Caf\u{00E9}", marker: 5),
            try decodedItem("file:///Media/Cafe%CC%81.mkv", marker: 6),
            try decodedItem("https://example.invalid/Media/Episode%201.mkv", marker: 7),
            try decodedItem("file://archive.invalid/Media/Episode%201.mkv", marker: 8),
        ]
        var state: UInt64 = 0x706C_6179_6C69_7374
        for count in 0..<64 {
            let input = (0..<count).map { _ in
                state = state &* 6_364_136_223_846_793_005 &+ 1
                return corpus[Int((state >> 32) % UInt64(corpus.count))]
            }
            let identities = input.map(\.id)
            // An independent, intentionally simple first-position oracle avoids
            // sharing the implementation's set and allocation transitions.
            let expected = input.indices.compactMap { index in
                identities.firstIndex(of: identities[index]) == index ? input[index] : nil
            }
            #expect(PlaylistMutation.deduplicated(input) == expected)
            #expect(PlaylistMutation.deduplicated(expected) == expected)
        }
    }

    private func item(_ stem: String, marker: Int) -> FolderPlaylistItem {
        FolderPlaylistItem(
            url: URL(fileURLWithPath: "/Media/\(stem).mkv"),
            externalSubtitleURLs: [URL(fileURLWithPath: "/Subtitles/\(marker).srt")],
            dateAdded: Date(timeIntervalSince1970: Double(marker))
        )
    }

    private func decodedItem(_ spelling: String, marker: Int) throws -> FolderPlaylistItem {
        let url = try #require(URL(string: spelling))
        let data = try JSONSerialization.data(withJSONObject: [
            "url": url.absoluteString,
            "externalSubtitleURLs": ["file:///Subtitles/\(marker).srt"],
            "dateAdded": Double(marker),
        ])
        return try JSONDecoder().decode(FolderPlaylistItem.self, from: data)
    }
}
