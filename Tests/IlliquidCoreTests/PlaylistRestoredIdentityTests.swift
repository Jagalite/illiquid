import Foundation
import Testing
@testable import IlliquidCore

@Suite("Playlist restored identities")
struct PlaylistRestoredIdentityTests {
    @Test func emptyAndSingletonQueuesNeverResurrectSavedEntries() {
        expectIDs([], ids: [], expected: [])
        expectIDs([], ids: [identity(0), identity(0), "/removed"], expected: [])
        let only = item(0)
        expectIDs([only], ids: [], expected: [identity(0)])
        expectIDs([only], ids: ["/removed"], expected: [identity(0)])
        expectIDs(
            [only, item(0, revision: 1)],
            ids: [identity(0), identity(0), "/removed"],
            expected: [identity(0)]
        )
    }

    @Test func emptySavedOrderKeepsFirstOccurrencesInCurrentOrder() {
        expectIDs(
            [item(2), item(0), item(2, revision: 1), item(1), item(0, revision: 2)],
            ids: [],
            expected: [identity(2), identity(0), identity(1)]
        )
    }

    @Test func savedOrderDropsMissingAndRepeatedIDsThenAppendsNewEntries() {
        // B disappeared; E then D arrived while shuffled. Repeated current
        // identities carry different metadata without changing their order.
        let current = [
            item(4), item(2), item(3), item(0),
            item(0, revision: 9), item(4, revision: 10),
        ]
        expectIDs(
            current,
            ids: ["/removed", identity(0), identity(1),
                  identity(0), identity(2), identity(1)],
            expected: [identity(0), identity(2), identity(4), identity(3)]
        )
        expectIDs(
            current, ids: ["/removed", identity(1), "/removed"],
            expected: [identity(4), identity(2), identity(3), identity(0)]
        )
    }

    @Test func savedIDsAreAlreadyKeysAndAreNotRenormalizedAsURLs() {
        expectIDs(
            [item(1), item(0)],
            ids: [
                "file:///Media/Episode%200.mkv",
                "/Media/Season/../Episode 0.mkv",
                "/Media/episode 0.mkv",
            ],
            expected: [identity(1), identity(0)]
        )
    }

    @Test func successiveShuffleEditsRetainNewItemOrderWithoutRestoringRemovals() {
        let original = [identity(0), identity(1), identity(2)]
        let firstCurrent = [item(2), item(0), item(3), item(4)]
        let first = evaluate(firstCurrent, ids: original)
        expectIDs(
            firstCurrent, ids: original,
            expected: [identity(0), identity(2), identity(3), identity(4)]
        )
        let secondCurrent = [item(4), item(3), item(2)]
        let second = evaluate(secondCurrent, ids: first)
        expectIDs(
            secondCurrent, ids: first,
            expected: [identity(2), identity(3), identity(4)]
        )
        expectIDs(
            [item(4), item(2), item(3)], ids: second,
            expected: [identity(2), identity(3), identity(4)]
        )
    }

    @Test func decodedLocalAliasesUseNormalizedCurrentIdentities() throws {
        // Decodable bypasses FolderPlaylistItem's normalizing initializer.
        let raw = try decodedItem(
            "file://LOCALHOST/Media/Season/../Cafe%CC%81.mkv?copy=restored#chapter",
            revision: 1
        )
        let canonicalID = URL(fileURLWithPath: "/Media/Caf\u{00E9}.mkv").path
        let canonical = FolderPlaylistItem(
            url: URL(fileURLWithPath: canonicalID),
            externalSubtitleURLs: [URL(fileURLWithPath: "/Subtitles/later.srt")],
            dateAdded: Date(timeIntervalSince1970: 2)
        )
        #expect(raw.url.absoluteString.contains("/Season/../"))
        #expect(raw.url.absoluteString != canonical.url.absoluteString)
        #expect(Array(raw.id.utf8) == Array(canonicalID.utf8))
        #expect(Array(canonical.id.utf8) == Array(canonicalID.utf8))
        expectIDs(
            [item(7), raw, canonical], ids: [canonicalID, canonicalID],
            expected: [canonicalID, identity(7)]
        )
        expectIDs(
            [canonical, item(7), raw], ids: [],
            expected: [canonicalID, identity(7)]
        )
    }

    @Test func canonicallyEqualSavedSpellingDoesNotReplaceCurrentIdentityBytes() {
        let currentURL = URL(fileURLWithPath: "/Media/Caf\u{00E9}.mkv")
        let currentID = currentURL.path
        let composed = currentID.precomposedStringWithCanonicalMapping
        let decomposed = currentID.decomposedStringWithCanonicalMapping
        let savedID = Array(currentID.utf8) == Array(composed.utf8) ? decomposed : composed
        let current = FolderPlaylistItem(url: currentURL)
        // String equality alone misses returning the saved spelling.
        #expect(savedID == currentID)
        #expect(Array(savedID.utf8) != Array(currentID.utf8))
        #expect(Array(current.id.utf8) == Array(currentID.utf8))
        expectIDs(
            [item(7), current, current], ids: [savedID, currentID, savedID],
            expected: [currentID, identity(7)]
        )
        expectIDs([current], ids: [savedID], expected: [currentID])
    }

    @Test(arguments: [
        "file://archive.example/Media/Episode%200.mkv",
        "file://localhost.example/Media/Episode%200.mkv",
        "file://127.0.0.1/Media/Episode%200.mkv",
        "file://user@localhost/Media/Episode%200.mkv",
        "file://user:example@localhost/Media/Episode%200.mkv",
        "file://localhost:1234/Media/Episode%200.mkv",
        "file:relative.mkv",
        "file:",
        "file://",
        "file://localhost",
    ])
    func decodedUnsupportedLocalURLsKeepTheirAbsoluteStringFallback(
        _ spelling: String
    ) throws {
        let first = try decodedItem(spelling, revision: 1)
        let duplicate = try decodedItem(spelling, revision: 2)
        let fallback = first.url.absoluteString
        #expect(NormalizedFileURL.persistenceKey(for: first.url) == nil)
        #expect(Array(first.id.utf8) == Array(fallback.utf8))
        #expect(first.id != identity(0))
        expectIDs(
            [item(0), first, duplicate],
            ids: [fallback, fallback, identity(0)],
            expected: [fallback, identity(0)]
        )
        expectIDs(
            [first, item(0), duplicate], ids: [],
            expected: [fallback, identity(0)]
        )
    }

    @Test func remoteQueriesAndFragmentsRemainDistinctFromEachOtherAndLocalPaths() throws {
        let firstID = "https://example.invalid/Media/Episode%200.mkv?edition=1"
        let secondID = "https://example.invalid/Media/Episode%200.mkv?edition=2"
        let fragmentID = "https://example.invalid/Media/Episode%200.mkv?edition=1#scene"
        let first = try decodedItem(firstID, revision: 1)
        let second = try decodedItem(secondID, revision: 2)
        let fragment = try decodedItem(fragmentID, revision: 3)
        let duplicate = try decodedItem(firstID, revision: 4)
        expectIDs(
            [first, fragment, item(0), second, duplicate],
            ids: [secondID, firstID, secondID,
                  "https://example.invalid/Media/Missing.mkv"],
            expected: [secondID, firstID, fragmentID, identity(0)]
        )
        expectIDs(
            [fragment, second, first, duplicate], ids: [],
            expected: [fragmentID, secondID, firstID]
        )
    }

    @Test func allSmallQueuesAndSavedOrdersMatchIndependentIdentityLabels() {
        let currentSequences = sequences(alphabetSize: 3, maximumLength: 4)
        let savedSequences = sequences(alphabetSize: 4, maximumLength: 4)
        let identities = (0..<4).map { identity($0) }
        let savedCases = savedSequences.map { labels in
            (labels: labels, ids: labels.map { identities[$0] })
        }
        var checked = 0
        for current in currentSequences {
            let items = current.enumerated().map {
                item($0.element, revision: $0.offset)
            }
            for saved in savedCases {
                // Integer labels supply an independent ordering/identity oracle.
                var expectedLabels: [Int] = []
                for label in saved.labels + current {
                    if current.contains(label), !expectedLabels.contains(label) {
                        expectedLabels.append(label)
                    }
                }
                expectIDs(
                    items, ids: saved.ids,
                    expected: expectedLabels.map { identities[$0] }
                )
                checked += 1
            }
        }
        #expect(currentSequences.count == 121)
        #expect(savedSequences.count == 341)
        #expect(checked == 41_261)
    }

    private func evaluate(
        _ items: [FolderPlaylistItem],
        ids: [FolderPlaylistItem.ID]
    ) -> [FolderPlaylistItem.ID] {
        #if CHECKPOINT_BASELINE
        return PlaylistMutation.restoringOrder(items, ids: ids).map(\.id)
        #else
        return PlaylistMutation.restoringIDs(items, ids: ids)
        #endif
    }

    private func expectIDs(
        _ items: [FolderPlaylistItem],
        ids: [FolderPlaylistItem.ID],
        expected: [FolderPlaylistItem.ID]
    ) {
        let actual = evaluate(items, ids: ids)
        #expect(utf8(actual) == utf8(expected))
        #if !CHECKPOINT_BASELINE
        let original = PlaylistMutation.restoringOrder(items, ids: ids).map(\.id)
        #expect(utf8(actual) == utf8(original))
        #endif
    }

    private func utf8(_ identities: [FolderPlaylistItem.ID]) -> [[UInt8]] {
        identities.map { Array($0.utf8) }
    }

    private func identity(_ number: Int) -> String {
        "/Media/Episode \(number).mkv"
    }

    private func item(_ number: Int, revision: Int = 0) -> FolderPlaylistItem {
        FolderPlaylistItem(
            url: URL(fileURLWithPath: identity(number)),
            externalSubtitleURLs: [
                URL(fileURLWithPath: "/Subtitles/\(number)-\(revision).srt"),
            ],
            dateAdded: Date(timeIntervalSince1970: Double(revision))
        )
    }

    private struct StoredItem: Encodable {
        let url: URL
        let externalSubtitleURLs: [URL]
        let dateAdded: Date
    }

    private func decodedItem(
        _ spelling: String,
        revision: Int
    ) throws -> FolderPlaylistItem {
        let stored = StoredItem(
            url: try #require(URL(string: spelling)),
            externalSubtitleURLs: [
                URL(fileURLWithPath: "/Subtitles/raw-\(revision).srt"),
            ],
            dateAdded: Date(timeIntervalSince1970: Double(revision))
        )
        return try JSONDecoder().decode(
            FolderPlaylistItem.self, from: JSONEncoder().encode(stored)
        )
    }

    private func sequences(alphabetSize: Int, maximumLength: Int) -> [[Int]] {
        var result: [[Int]] = [[]]
        var layer: [[Int]] = [[]]
        for _ in 0..<maximumLength {
            layer = layer.flatMap { prefix in
                (0..<alphabetSize).map { prefix + [$0] }
            }
            result.append(contentsOf: layer)
        }
        return result
    }
}
