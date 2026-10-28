import Foundation
import Testing
@testable import IlliquidCore

@Suite("Shuffled checkpoint identity order")
struct PlaylistCheckpointIdentityTests {
    @Test func emptyAndSingletonPlaylistsKeepTheirExactIdentities() {
        let only = item(0)
        expectOrder([], ids: [], expected: [])
        expectOrder([], ids: Array(repeating: only.id, count: 4_096), expected: [])
        expectOrder([only], ids: [], expected: [only.id])
        expectOrder([only], ids: ["/removed", only.id, only.id], expected: [only.id])
        expectOrder([only], ids: ["/removed"], expected: [only.id])
    }

    @Test func emptySavedOrderKeepsFirstCurrentOccurrences() {
        let a = item(0), b = item(1), c = item(2)
        let current = [c, a, item(2, revision: 1), b, item(0, revision: 2)]
        expectOrder(current, ids: [], expected: [c.id, a.id, b.id])
        expectOrder(current, ids: ["/removed"], expected: [c.id, a.id, b.id])
    }

    @Test func savedSurvivorsPrecedeNewItemsWithoutRevivingRemovals() {
        let a = item(0), b = item(1), c = item(2), d = item(3), e = item(4)
        expectOrder(
            [e, c, d, a, item(2, revision: 1), item(0, revision: 2)],
            ids: ["/removed", a.id, b.id, c.id, c.id, "/removed", a.id],
            expected: [a.id, c.id, e.id, d.id]
        )
        let checkpointIDs = PlaylistMutation.restoringIdentityOrder(
            [e, c, d, a], ids: [a.id, b.id, c.id]
        )
        // The next shuffled edit removes A and adds F; a checkpoint must not
        // reintroduce A or disturb the surviving saved order.
        let f = item(5), editedC = item(2, revision: 3)
        let nextCurrent = [f, d, e, editedC, c]
        expectOrder(nextCurrent, ids: checkpointIDs, expected: [c.id, e.id, d.id, f.id])
        let nextIDs = PlaylistMutation.restoringIdentityOrder(nextCurrent, ids: checkpointIDs)
        #expect(PlaylistMutation.restoringOrder(nextCurrent, ids: nextIDs) == [editedC, e, d, f])
    }

    @Test func canonicallyEqualSavedStringsPreserveCurrentUTF8Bytes() {
        let current = FolderPlaylistItem(url: URL(fileURLWithPath: "/Media/Café/épisode.mkv"))
        let decomposed = "/Media/Cafe\u{301}/e\u{301}pisode.mkv"
        let canonical = current.id
        let other = item(1)
        #expect(canonical == decomposed)
        #expect(Array(canonical.utf8) != Array(decomposed.utf8))

        for saved in [
            [decomposed],
            [decomposed, canonical, decomposed],
            ["/removed", decomposed, other.id],
        ] {
            expectOrder([other, current, current], ids: saved, expected: [canonical, other.id])
        }
    }

    @Test func decodedLocalAliasesUseTheFirstItemsNormalizedIdentity() throws {
        let base = try #require(URL(string: "file:///Media/"))
        let aliases = try [
            "file:///Media/Season/../Cafe%CC%81.mkv",
            "file://localhost/Media/Caf%C3%A9.mkv",
            "file://LOCALHOST/Media/Cafe%CC%81.mkv",
        ].map { try #require(URL(string: $0)) } + [
            try #require(URL(string: "Season/../Cafe%CC%81.mkv", relativeTo: base)),
        ]
        let decoded = try aliases.enumerated().map {
            try decodedItem($0.element, revision: $0.offset)
        }
        #expect(decoded[0].url.absoluteString.contains("/Season/../"))
        let other = item(1)
        let expected = "/Media/Café.mkv"
        expectOrder(decoded + [other], ids: [], expected: [expected, other.id])
        expectOrder(
            [other] + decoded,
            ids: ["/Media/Cafe\u{301}.mkv", other.id, expected],
            expected: [expected, other.id]
        )
    }

    @Test func unsupportedAndRemoteURLsKeepAbsoluteStringIdentities() throws {
        let spellings = [
            "https://example.invalid/Media/A.mkv?id=1",
            "https://example.invalid/Media/A.mkv?id=2",
            "https://example.invalid/Media/A.mkv?id=1#chapter",
            "file://media-server.example/Media/A.mkv",
            "file://127.0.0.1/Media/A.mkv",
            "file://user@localhost/Media/A.mkv",
            "file://user:example@localhost/Media/A.mkv",
            "file://localhost:1234/Media/A.mkv",
            "file://localhost:0/Media/A.mkv",
            "file:relative.mkv",
        ]
        let urls = try spellings.map { try #require(URL(string: $0)) }
        for (url, spelling) in zip(urls, spellings) {
            #expect(NormalizedFileURL.persistenceKey(for: url) == nil)
            #expect(url.absoluteString == spelling)
        }
        let items = try urls.enumerated().map {
            try decodedItem($0.element, revision: $0.offset)
        }
        let local = FolderPlaylistItem(url: URL(fileURLWithPath: "/Media/A.mkv"))
        let current = Array(items.reversed()) + [items[0], items[3], local]
        let expected = [spellings[0], spellings[3]]
            + spellings.reversed().filter { $0 != spellings[0] && $0 != spellings[3] }
            + ["/Media/A.mkv"]
        expectOrder(
            current,
            ids: [spellings[0], "/removed", spellings[3], spellings[0]],
            expected: expected
        )
        expectOrder(
            current, ids: [],
            expected: Array(spellings.reversed()) + ["/Media/A.mkv"]
        )
    }

    @Test func largeShuffledQueueRestoresSurvivorsAndAppendsNewEntries() {
        let count = 2_048
        let original = (0..<count).map { item($0) }
        // 73 is coprime to 2,048, so this visits every original entry once.
        let shuffledLabels = (0..<count).map { ($0 * 73) % count }.filter { $0 % 11 != 0 }
        var current: [FolderPlaylistItem] = []
        for (offset, label) in shuffledLabels.enumerated() {
            current.append(original[label])
            if offset % 17 == 0 { current.append(item(label, revision: 1)) }
        }
        let added = (count..<(count + 64)).reversed().map { item($0) }
        current.append(contentsOf: added)
        let saved = original.enumerated().flatMap { index, entry in
            index % 13 == 0 ? [entry.id, entry.id] : [entry.id]
        }
        let expected = (0..<count).filter { $0 % 11 != 0 }.map { "/Media/Episode \($0).mkv" }
            + added.map(\.id)
        expectOrder(current, ids: saved, expected: expected)
    }

    @Test func smallSequencesMatchFrozenImplementationAndAuthoredIdentityLabels() throws {
        let alias = try #require(URL(string: "file://LOCALHOST/Media/Season/../Cafe%CC%81.mkv"))
        let remote = try #require(URL(string: "https://example.invalid/Media/B.mkv?copy=1"))
        let fixtures = [
            FolderPlaylistItem(url: URL(fileURLWithPath: "/Media/Café.mkv")),
            try decodedItem(alias, revision: 1),
            FolderPlaylistItem(url: URL(fileURLWithPath: "/Media/B.mkv")),
            FolderPlaylistItem(url: remote),
        ]
        let labels = [0, 0, 1, 2]
        let expectedIDs = [
            "/Media/Café.mkv", "/Media/B.mkv",
            "https://example.invalid/Media/B.mkv?copy=1",
        ]
        let savedIDs = [
            "/Media/Café.mkv", "/Media/Cafe\u{301}.mkv", "/Media/B.mkv",
            "https://example.invalid/Media/B.mkv?copy=1", "/removed",
        ]
        let savedLabels = [0, 0, 1, 2, 3]
        let currentSequences = sequences(alphabetSize: 4, maximumLength: 3)
        let savedSequences = sequences(alphabetSize: 5, maximumLength: 2)
        var checked = 0
        for sequence in currentSequences {
            let current = sequence.map { fixtures[$0] }
            let currentLabels = sequence.map { labels[$0] }
            for saved in savedSequences {
                var emitted: Set<Int> = []
                var expected: [String] = []
                for label in saved.map({ savedLabels[$0] }) + currentLabels {
                    guard currentLabels.contains(label), emitted.insert(label).inserted else { continue }
                    expected.append(expectedIDs[label])
                }
                expectOrder(current, ids: saved.map { savedIDs[$0] }, expected: expected)
                checked += 1
            }
        }
        #expect(checked == 2_635)
    }

    private func expectOrder(
        _ items: [FolderPlaylistItem], ids: [String], expected: [String]
    ) {
        let actual = PlaylistMutation.restoringIdentityOrder(items, ids: ids)
        let frozen = legacyRestoringOrder(items, ids: ids).map(\.id)
        // String equality hides canonical spelling changes in persisted IDs.
        #expect(actual.map { Array($0.utf8) } == expected.map { Array($0.utf8) })
        #expect(actual.map { Array($0.utf8) } == frozen.map { Array($0.utf8) })
    }

    private func item(_ number: Int, revision: Int = 0) -> FolderPlaylistItem {
        FolderPlaylistItem(
            url: URL(fileURLWithPath: "/Media/Episode \(number).mkv"),
            externalSubtitleURLs: [URL(fileURLWithPath: "/Media/\(number)-\(revision).srt")],
            dateAdded: Date(timeIntervalSince1970: Double(revision))
        )
    }

    private struct RawItemPayload: Encodable {
        let url: URL
        let externalSubtitleURLs: [URL]
        let dateAdded: Date?
    }

    private func decodedItem(_ url: URL, revision: Int) throws -> FolderPlaylistItem {
        let payload = RawItemPayload(
            url: url, externalSubtitleURLs: [URL(fileURLWithPath: "/Media/\(revision).srt")],
            dateAdded: Date(timeIntervalSince1970: Double(revision))
        )
        return try JSONDecoder().decode(FolderPlaylistItem.self, from: JSONEncoder().encode(payload))
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

    // Frozen from PlaylistMutation at ea2ff568. Keep the item-based operation
    // independent of the identity helper so both cannot drift together.
    private func legacyRestoringOrder(
        _ items: [FolderPlaylistItem],
        ids: [FolderPlaylistItem.ID]
    ) -> [FolderPlaylistItem] {
        guard !items.isEmpty else { return [] }
        guard !ids.isEmpty else { return legacyDeduplicated(items) }
        var byID: [FolderPlaylistItem.ID: FolderPlaylistItem] = [:]
        var currentOrder: [FolderPlaylistItem.ID] = []
        for item in items {
            let id = item.id
            guard byID[id] == nil else { continue }
            byID[id] = item
            currentOrder.append(id)
        }
        var restored: [FolderPlaylistItem] = []
        restored.reserveCapacity(byID.count)
        for id in ids {
            if let item = byID.removeValue(forKey: id) { restored.append(item) }
        }
        for id in currentOrder {
            if let item = byID.removeValue(forKey: id) { restored.append(item) }
        }
        return restored
    }

    private func legacyDeduplicated(_ items: [FolderPlaylistItem]) -> [FolderPlaylistItem] {
        guard !items.isEmpty else { return [] }
        guard items.count > 1 else { return legacyUniqueResult(items) }
        var seen: Set<FolderPlaylistItem.ID> = []
        for index in items.indices {
            if !seen.insert(items[index].id).inserted {
                var result = Array(items[..<index])
                for item in items[(index + 1)...] where seen.insert(item.id).inserted {
                    result.append(item)
                }
                return result
            }
        }
        return legacyUniqueResult(items)
    }

    private func legacyUniqueResult(_ items: [FolderPlaylistItem]) -> [FolderPlaylistItem] {
        let capacity = items.capacity
        guard capacity > 64, items.count < capacity / 2 else { return items }
        var compact: [FolderPlaylistItem] = []
        compact.reserveCapacity(items.count)
        compact.append(contentsOf: items)
        return compact
    }
}
