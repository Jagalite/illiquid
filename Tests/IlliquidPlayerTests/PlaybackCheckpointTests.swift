import Foundation
import Testing
import IlliquidCore
@testable import IlliquidPlayer

@Suite("Playback checkpoint membership and snapshot semantics")
struct PlaybackCheckpointTests {
    @Test(arguments: [0, 2, 4])
    func selectedBeginningMiddleAndEndRetainFolder(_ index: Int) throws {
        let items = (0..<5).map(item)
        let checkpoint = makeCheckpoint(source: .localFile(items[index].url), playlist: items, index: index)
        let record = try assertMatchesOriginal(checkpoint)
        #expect(record.collectionFolder == checkpoint.folder)
        #expect(record.playlistIndex == index)
        #expect(record.playlistItems == items)
    }

    @Test func missingIndexStillFindsTheSource() throws {
        let items = (0..<5).map(item)
        let checkpoint = makeCheckpoint(source: .localFile(items[4].url), playlist: items, index: nil)
        let record = try assertMatchesOriginal(checkpoint)
        #expect(record.collectionFolder == checkpoint.folder)
        #expect(record.playlistIndex == nil)
    }

    @Test func staleInBoundsIndexDoesNotHideAnotherMatchingItem() throws {
        let items = (0..<5).map(item)
        let checkpoint = makeCheckpoint(source: .localFile(items[3].url), playlist: items, index: 1)
        let record = try assertMatchesOriginal(checkpoint)
        #expect(record.collectionFolder == checkpoint.folder)
        #expect(record.playlistIndex == 1)
    }

    @Test(arguments: [-1, 5, Int.min, Int.max])
    func invalidIndicesFallBackWithoutChangingTheSavedIndex(_ index: Int) throws {
        let items = (0..<5).map(item)
        let checkpoint = makeCheckpoint(source: .localFile(items[4].url), playlist: items, index: index)
        let record = try assertMatchesOriginal(checkpoint)
        #expect(record.collectionFolder == checkpoint.folder)
        #expect(record.playlistIndex == index)
    }

    @Test func anAbsentSourceDropsTheFolderWithoutChangingThePlaylist() throws {
        let items = (0..<3).map(item)
        let folders: [URL?] = [URL(fileURLWithPath: "/Media", isDirectory: true), nil]
        for folder in folders {
            let checkpoint = makeCheckpoint(
                source: .localFile(item(99).url), playlist: items, index: 1, folder: folder
            )
            let record = try assertMatchesOriginal(checkpoint)
            #expect(record.collectionFolder == nil)
            #expect(record.playlistItems == items)
            #expect(record.playlistIndex == 1)
        }
    }

    @Test func membershipDoesNotInventAMissingFolder() throws {
        let items = [item(0)]
        let checkpoint = makeCheckpoint(
            source: .localFile(items[0].url), playlist: items, index: 0, folder: nil
        )
        let record = try assertMatchesOriginal(checkpoint)
        #expect(record.collectionFolder == nil)
    }

    @Test func emptyAndSingletonPlaylistsKeepTheirMembershipPolicy() throws {
        let matching = item(0)
        let empty = makeCheckpoint(source: .localFile(matching.url), playlist: [], index: 0)
        let emptyRecord = try assertMatchesOriginal(empty)
        #expect(emptyRecord.collectionFolder == nil)
        #expect(emptyRecord.playlistIndex == 0)

        for index in [nil, 0, 1] as [Int?] {
            let checkpoint = makeCheckpoint(source: .localFile(matching.url), playlist: [matching], index: index)
            let record = try assertMatchesOriginal(checkpoint)
            #expect(record.collectionFolder == checkpoint.folder)
            #expect(record.playlistIndex == index)
        }
    }

    @Test func decodedLexicalAndUnicodeAliasesStillMatch() throws {
        let raw = try #require(URL(string:
            "file://LOCALHOST/Media/Season/../Cafe%CC%81%202.mkv?edition=raw#chapter"))
        let decoded = try rawItem(url: raw)
        let canonical = URL(fileURLWithPath: "/Media/Caf\u{00E9} 2.mkv")
        #expect(decoded.url.absoluteString == raw.absoluteString)
        #expect(decoded.url.absoluteString != FolderPlaylistItem(url: raw).url.absoluteString)
        for index in [nil, 0, 1] as [Int?] {
            let checkpoint = makeCheckpoint(
                source: .localFile(canonical), playlist: [item(0), decoded], index: index
            )
            let record = try assertMatchesOriginal(checkpoint)
            #expect(record.collectionFolder == checkpoint.folder)
            #expect(record.playlistItems[1] == decoded)
        }
    }

    @Test func duplicateIdentitiesKeepFirstMetadataOrderAndCapturedIndex() throws {
        let alias = try #require(URL(string: "file://localhost/Media/Season/../Episode%201.mkv"))
        let first = try rawItem(
            url: alias,
            subtitles: [URL(fileURLWithPath: "/Media/first.srt")],
            dateAdded: Date(timeIntervalSince1970: 100)
        )
        let later = FolderPlaylistItem(
            url: item(1).url,
            externalSubtitleURLs: [URL(fileURLWithPath: "/Media/later.srt")],
            dateAdded: Date(timeIntervalSince1970: 200)
        )
        let other = item(2)
        let ids = [other.id, first.id, first.id]
        let checkpoint = makeCheckpoint(
            source: .localFile(later.url), playlist: [first, other, later, other],
            index: 2, ids: ids
        )
        let record = try assertMatchesOriginal(checkpoint)
        #expect(record.collectionFolder == checkpoint.folder)
        #expect(record.playlistItems == [first, other])
        // Membership lookup must not repair this index after deduplication.
        #expect(record.playlistIndex == 2)
        #expect(record.unshuffledPlaylistIDs == ids)
    }

    @Test(arguments: [
        "file://archive.example/Media/Episode%201.mkv",
        "file://localhost.example/Media/Episode%201.mkv",
        "file://127.0.0.1/Media/Episode%201.mkv",
        "file://[::1]/Media/Episode%201.mkv",
        "file://user@localhost/Media/Episode%201.mkv",
        "file://user:password@localhost/Media/Episode%201.mkv",
        "file://localhost:1234/Media/Episode%201.mkv",
        "file:relative.mkv", "file:", "file://", "file://localhost",
    ])
    func unsupportedIdenticalFileURLsNeverEstablishMembership(_ input: String) throws {
        let url = try #require(URL(string: input))
        let stored = try rawItem(url: url)
        #expect(NormalizedFileURL.persistenceKey(for: url) == nil)
        for index in [nil, 0] as [Int?] {
            let checkpoint = makeCheckpoint(source: .localFile(url), playlist: [stored], index: index)
            let record = try assertMatchesOriginal(checkpoint)
            #expect(record.collectionFolder == nil)
            #expect(record.playlistItems == [stored])
        }
    }

    @Test func anInvalidSelectedItemCannotMatchALocalSourceOrHideAValidMatch() throws {
        let local = item(1)
        let remoteAuthority = try #require(URL(string: "file://archive.example/Media/Episode%201.mkv"))
        let invalid = try rawItem(url: remoteAuthority)
        for items in [[invalid], [invalid, local]] {
            let checkpoint = makeCheckpoint(source: .localFile(local.url), playlist: items, index: 0)
            let record = try assertMatchesOriginal(checkpoint)
            #expect(record.collectionFolder == (items.count == 2 ? checkpoint.folder : nil))
        }
    }

    @Test func remoteStreamsNeverClaimACollectionFolder() throws {
        let url = try #require(URL(string: "https://example.invalid/Media/Episode%201.mkv?token=sample"))
        let stored = try rawItem(url: url)
        for index in [nil, 0] as [Int?] {
            let checkpoint = makeCheckpoint(source: .remoteStream(url), playlist: [stored], index: index)
            let record = try assertMatchesOriginal(checkpoint)
            #expect(record.collectionFolder == nil)
            #expect(record.source == .remoteStream(url))
        }
    }

    @Test func malformedEnumCasesRetainTheOriginalURLBasedPolicy() throws {
        let local = item(1)
        // Validation belongs to the load boundary. Checkpoint membership has
        // always used URL semantics, even for directly constructed bad labels.
        let mislabeledLocal = makeCheckpoint(source: .remoteStream(local.url), playlist: [local], index: 0)
        let localRecord = try assertMatchesOriginal(mislabeledLocal)
        #expect(localRecord.collectionFolder == mislabeledLocal.folder)
        #expect(localRecord.source == .remoteStream(local.url))

        let remote = try #require(URL(string: "https://example.invalid/Media/Episode%201.mkv"))
        let mislabeledRemote = makeCheckpoint(
            source: .localFile(remote), playlist: [try rawItem(url: remote)], index: 0
        )
        let remoteRecord = try assertMatchesOriginal(mislabeledRemote)
        #expect(remoteRecord.collectionFolder == nil)
        #expect(remoteRecord.source == .localFile(remote))
    }

    @Test func relativeQueriesValidateTheInheritedAuthority() throws {
        let localBase = URL(fileURLWithPath: "/Media/Season", isDirectory: true)
        let remoteBase = try #require(URL(string: "file://archive.example/Media/Season/"))
        let local = try #require(URL(string: "../Episode%201.mkv", relativeTo: localBase))
        let remote = try #require(URL(string: "../Episode%201.mkv", relativeTo: remoteBase))
        for query in [local, remote] {
            let checkpoint = makeCheckpoint(source: .localFile(query), playlist: [item(1)], index: 0)
            let record = try assertMatchesOriginal(checkpoint)
            #expect(record.collectionFolder == (query == local ? checkpoint.folder : nil))
        }
    }

    @Test(arguments: [Double.nan, Double.infinity, -Double.infinity, -8, -0.0, 0, 42.5])
    func positionSanitizationIsUnchanged(_ position: Double) throws {
        let checkpoint = makeCheckpoint(source: .localFile(item(1).url), playlist: [item(1)], index: 0,
                                        position: position)
        let record = try assertMatchesOriginal(checkpoint)
        #expect(record.position == (position.isFinite ? max(0, position) : 0))
    }

    @Test func checkpointAndReturnedRecordsKeepIndependentSnapshotValues() throws {
        var items = (0..<3).map(item)
        let original = items
        var ids = items.reversed().map(\.id)
        let originalIDs = ids
        let checkpoint = makeCheckpoint(
            source: .localFile(items[1].url), playlist: items, index: 1,
            position: 91.25, wasPaused: false, ids: ids
        )
        items[0] = item(99)
        ids.removeLast()
        var record = try assertMatchesOriginal(checkpoint)
        #expect(record.playlistItems == original)
        #expect(record.unshuffledPlaylistIDs == originalIDs)
        #expect(record.source == checkpoint.source)
        #expect(record.position == 91.25)
        #expect(record.wasPaused == false)
        #expect(record.schemaVersion == PlaybackSessionRecord.currentSchemaVersion)

        record.playlistItems.removeLast()
        record.unshuffledPlaylistIDs?.removeLast()
        #expect(checkpoint.playlist == original)
        #expect(checkpoint.unshuffledPlaylistIDs == originalIDs)
        #expect(items[0] == item(99))
    }

    @Test func deterministicPermutationsMatchCompleteOriginalRecordsAndBytes() throws {
        let alias = try #require(URL(string: "file://LOCALHOST/Media/Season/../Episode%201.mkv"))
        let unicode = try #require(URL(string: "file:///Media/Cafe%CC%81.mkv"))
        let remote = try #require(URL(string: "https://example.invalid/Media/Episode%201.mkv"))
        let invalid = try #require(URL(string: "file://user@localhost/Media/Episode%201.mkv"))
        let raw = try [alias, unicode, invalid, item(2).url, alias].map { try rawItem(url: $0) }
        let initialized = [item(1), item(2), FolderPlaylistItem(url: unicode)]
        let lists: [[FolderPlaylistItem]] = [[], initialized, raw, raw + initialized]
        let queries = [item(1).url, alias, item(2).url, URL(fileURLWithPath: "/Media/episode 1.mkv"),
                       URL(fileURLWithPath: "/Media/Caf\u{00E9}.mkv"), item(99).url, remote, invalid]
        var cases = 0
        for items in lists {
            let indices: [Int?] = [nil, -1, 0, 1, 2, items.count - 1, items.count]
            for query in queries {
                for index in indices {
                    let source: MediaSource = cases.isMultiple(of: 3) ? .remoteStream(query) : .localFile(query)
                    let checkpoint = makeCheckpoint(
                        source: source, playlist: items, index: index,
                        folder: cases.isMultiple(of: 5) ? nil : URL(fileURLWithPath: "/Media", isDirectory: true),
                        position: cases.isMultiple(of: 7) ? .nan : 17.25,
                        wasPaused: cases.isMultiple(of: 2),
                        ids: cases.isMultiple(of: 4) ? nil : [item(2).id, item(1).id, item(1).id]
                    )
                    try assertMatchesOriginal(checkpoint)
                    cases += 1
                }
            }
        }
        #expect(cases == 224)
    }

    private func item(_ number: Int) -> FolderPlaylistItem {
        FolderPlaylistItem(
            url: URL(fileURLWithPath: "/Media/Episode \(number).mkv"),
            externalSubtitleURLs: [URL(fileURLWithPath: "/Media/subtitle-\(number).srt")],
            dateAdded: Date(timeIntervalSince1970: Double(number))
        )
    }

    private func rawItem(
        url: URL,
        subtitles: [URL] = [],
        dateAdded: Date? = nil
    ) throws -> FolderPlaylistItem {
        struct StoredItem: Encodable {
            let url: URL
            let externalSubtitleURLs: [URL]
            let dateAdded: Date?
        }
        let stored = StoredItem(url: url, externalSubtitleURLs: subtitles, dateAdded: dateAdded)
        return try JSONDecoder().decode(FolderPlaylistItem.self, from: JSONEncoder().encode(stored))
    }

    private func makeCheckpoint(
        source: MediaSource,
        playlist: [FolderPlaylistItem],
        index: Int?,
        folder: URL? = URL(fileURLWithPath: "/Media", isDirectory: true),
        position: TimeInterval = 42.5,
        wasPaused: Bool = true,
        ids: [FolderPlaylistItem.ID]? = nil
    ) -> PlaybackCheckpoint {
        PlaybackCheckpoint(source: source, folder: folder, playlist: playlist, index: index,
                           position: position, wasPaused: wasPaused, unshuffledPlaylistIDs: ids)
    }

    @discardableResult
    private func assertMatchesOriginal(_ checkpoint: PlaybackCheckpoint) throws -> PlaybackSessionRecord {
        let fixedDate = Date(timeIntervalSince1970: 1_234_567)
        var actual = checkpoint.record()
        actual.updatedAt = fixedDate
        // Keep the original full membership predicate as the differential
        // oracle; it has no selected-index shortcut or cached identity.
        let belongsToFolder = checkpoint.source.url.isFileURL && checkpoint.playlist.contains {
            NormalizedFileURL.representsSameFile($0.url, checkpoint.source.url)
        }
        let expected = PlaybackSessionRecord(
            source: checkpoint.source,
            collectionFolder: belongsToFolder ? checkpoint.folder : nil,
            playlistItems: checkpoint.playlist,
            playlistIndex: checkpoint.index,
            position: checkpoint.position,
            wasPaused: checkpoint.wasPaused,
            unshuffledPlaylistIDs: checkpoint.unshuffledPlaylistIDs,
            updatedAt: fixedDate
        )
        #expect(actual == expected)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        #expect(try encoder.encode(actual) == encoder.encode(expected))
        return actual
    }
}
