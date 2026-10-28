import Foundation
import IlliquidCore
import Testing
@testable import IlliquidPlayer

@Suite("Playback checkpoint identity preparation")
struct PlaybackCheckpointIdentityTests {
    @Test func standalonePlaylistsKeepRecordFieldsWithoutACollectionFolder() {
        let first = item("First", marker: 1)
        let second = item("Second", marker: 2)
        let checkpoint = makeCheckpoint(
            source: .localFile(second.url), playlist: [first, second], index: 1,
            unshuffledIDs: [second.id, first.id]
        )
        let before = Date()
        let record = checkpoint.record()
        let after = Date()

        #expect(record.collectionFolder == nil)
        #expect(record.source == checkpoint.source)
        #expect(record.playlistItems == [first, second])
        #expect(record.playlistIndex == 1)
        #expect(record.position == 73.5)
        #expect(record.wasPaused)
        #expect(record.unshuffledPlaylistIDs == [second.id, first.id])
        #expect(record.schemaVersion == PlaybackSessionRecord.currentSchemaVersion)
        #expect(record.updatedAt >= before)
        #expect(record.updatedAt <= after)
    }

    @Test(arguments: [0, 2, 4])
    func membershipAtAnyPositionRetainsTheOriginalFolder(position: Int) throws {
        let items = (0..<5).map { item("Episode \($0)", marker: $0) }
        // A folder is stored as supplied; membership is not a containment test.
        let folder = try #require(URL(string: "file:///Elsewhere/Season/../"))
        let record = makeCheckpoint(
            source: .localFile(items[position].url), folder: folder,
            playlist: items, index: nil
        ).record()

        #expect(record.collectionFolder?.absoluteString == folder.absoluteString)
        #expect(record.playlistItems == items)
        #expect(record.playlistIndex == nil)
    }

    @Test func emptyAndNonmatchingPlaylistsDiscardTheFolder() {
        let present = item("Present", marker: 1)
        let missing = URL(fileURLWithPath: "/Media/Missing.mkv")
        for items in [[], [present]] {
            let record = makeCheckpoint(
                source: .localFile(missing), folder: URL(fileURLWithPath: "/Media"),
                playlist: items, index: 0
            ).record()
            #expect(record.collectionFolder == nil)
            #expect(record.playlistItems == items)
            // A saved index does not substitute for source membership.
            #expect(record.playlistIndex == 0)
        }
    }

    @Test func duplicatesKeepTheFirstItemsMetadataAndTheSavedIndex() {
        let first = item("Episode", marker: 1)
        let duplicate = item("Episode", marker: 2)
        let other = item("Other", marker: 3)
        let folder = URL(fileURLWithPath: "/Media")
        let record = makeCheckpoint(
            source: .localFile(first.url), folder: folder,
            playlist: [first, other, duplicate], index: 2,
            unshuffledIDs: [other.id, first.id, first.id]
        ).record()

        #expect(record.collectionFolder == folder)
        #expect(record.playlistItems == [first, other])
        #expect(record.playlistItems[0].externalSubtitleURLs == first.externalSubtitleURLs)
        #expect(record.playlistItems[0].dateAdded == first.dateAdded)
        #expect(record.playlistIndex == 2)
        #expect(record.unshuffledPlaylistIDs == [other.id, first.id, first.id])
    }

    @Test func decodedAliasesMatchWithoutReplacingTheirExactRepresentation() throws {
        let rawURL = try #require(URL(string:
            "file://LOCALHOST/Media/Season/../Cafe%CC%81.mkv?source=restore#chapter"))
        let raw = try decodedItem(rawURL, marker: 1)
        let canonical = item("Caf\u{00E9}", marker: 2)
        let folder = URL(fileURLWithPath: "/Media")
        #expect(raw.url.absoluteString == rawURL.absoluteString)

        for sourceURL in [rawURL, canonical.url] {
            let record = makeCheckpoint(
                source: .localFile(sourceURL), folder: folder,
                playlist: [raw, canonical], index: 0
            ).record()
            #expect(record.collectionFolder == folder)
            #expect(record.source.url.absoluteString == sourceURL.absoluteString)
            #expect(record.playlistItems == [raw])
            #expect(record.playlistItems[0].url.absoluteString == rawURL.absoluteString)
            #expect(record.playlistItems[0].externalSubtitleURLs == raw.externalSubtitleURLs)
        }
    }

    @Test func relativeAndEncodedDotSourcesKeepTheirURLSemantics() throws {
        let localBase = try #require(URL(string: "file:///Media/"))
        let remoteBase = try #require(URL(string: "file://archive.invalid/Media/"))
        let localRelative = try #require(URL(string: "Season/../Cafe%CC%81.mkv", relativeTo: localBase))
        let remoteRelative = try #require(URL(string: "Season/../Cafe%CC%81.mkv", relativeTo: remoteBase))
        let encodedDot = try #require(URL(string: "file:///Media/Season/%2E%2E/Caf%C3%A9.mkv"))
        let canonical = item("Caf\u{00E9}", marker: 1)
        let cases: [(url: URL, items: [FolderPlaylistItem], matches: Bool)] = [
            (localRelative, [canonical], true),
            (encodedDot, [try decodedItem(encodedDot, marker: 2)], true),
            (remoteRelative, [try decodedItem(remoteRelative, marker: 3), canonical], false),
        ]
        for testCase in cases {
            let checkpoint = makeCheckpoint(
                source: .localFile(testCase.url), folder: localBase, playlist: testCase.items
            )
            let actual = checkpoint.record()
            var reference = referenceRecord(checkpoint)
            reference.updatedAt = actual.updatedAt
            #expect(actual == reference)
            #expect(actual.collectionFolder == (testCase.matches ? localBase : nil))
            #expect(actual.source.url.relativeString == testCase.url.relativeString)
            #expect(actual.source.url.baseURL?.absoluteString == testCase.url.baseURL?.absoluteString)
            #expect(actual.playlistItems.map { $0.url.absoluteString }
                == testCase.items.map { $0.url.absoluteString })
        }
    }

    @Test(arguments: [
        "https://example.invalid/Media/A.mkv",
        "file://archive.invalid/Media/A.mkv",
        "file://127.0.0.1/Media/A.mkv",
        "file://user@localhost/Media/A.mkv",
        "file://user:example@localhost/Media/A.mkv",
        "file://localhost:1234/Media/A.mkv",
        "file://localhost:0/Media/A.mkv",
        "file:relative.mkv",
    ])
    func unsupportedIdentitiesNeverMatchEachOther(_ spelling: String) throws {
        let url = try #require(URL(string: spelling))
        let unsupported = try decodedItem(url, marker: 1)
        let valid = item("A", marker: 2)
        let folder = URL(fileURLWithPath: "/Media")
        for source in [MediaSource.localFile(url), .remoteStream(url)] {
            let record = makeCheckpoint(
                source: source, folder: folder, playlist: [unsupported, valid], index: 0
            ).record()
            #expect(record.collectionFolder == nil)
            #expect(record.source == source)
            #expect(record.playlistItems == [unsupported, valid])
        }
        // An invalid item must not prevent a later supported source match.
        #expect(makeCheckpoint(
            source: .localFile(valid.url), folder: folder,
            playlist: [unsupported, valid], index: 0
        ).record().collectionFolder == folder)
    }

    @Test func sourceCasesKeepTheExistingURLBasedMembershipContract() throws {
        let local = item("Local", marker: 1)
        let remoteURL = try #require(URL(string: "https://example.invalid/Local.mkv"))
        let remote = try decodedItem(remoteURL, marker: 2)
        let folder = URL(fileURLWithPath: "/Media")

        // Public enum cases can contain mismatched URLs. Checkpoint preparation
        // preserves them; it neither reclassifies nor revalidates load requests.
        let localAsRemote = makeCheckpoint(
            source: .remoteStream(local.url), folder: folder, playlist: [local]
        ).record()
        #expect(localAsRemote.source == .remoteStream(local.url))
        #expect(localAsRemote.collectionFolder == folder)

        let remoteAsLocal = makeCheckpoint(
            source: .localFile(remoteURL), folder: folder, playlist: [remote]
        ).record()
        #expect(remoteAsLocal.source == .localFile(remoteURL))
        #expect(remoteAsLocal.collectionFolder == nil)
    }

    @Test func nonmatchingLocalPathsRemainDistinct() {
        let present = item("A", marker: 1)
        let folder = URL(fileURLWithPath: "/Media")
        for path in ["/Elsewhere/A.mkv", "/Media/a.mkv", "/Media/A.mkv/child"] {
            #expect(makeCheckpoint(
                source: .localFile(URL(fileURLWithPath: path)), folder: folder,
                playlist: [present], index: 0
            ).record().collectionFolder == nil)
        }
    }

    @Test func completeRecordsMatchTheOriginalPipelineAcrossSmallPlaylists() throws {
        let a = item("Caf\u{00E9}", marker: 0)
        let aliasURL = try #require(URL(string: "file://localhost/Media/Season/../Cafe%CC%81.mkv"))
        let alias = try decodedItem(aliasURL, marker: 1)
        let b = item("B", marker: 2)
        let invalidURL = try #require(URL(string: "file://archive.invalid/Media/Caf%C3%A9.mkv"))
        let invalid = try decodedItem(invalidURL, marker: 3)
        let remoteURL = try #require(URL(string: "https://example.invalid/Media/Caf%C3%A9.mkv"))
        let fixtures: [(item: FolderPlaylistItem, identity: Int?)] = [
            (a, 0), (alias, 0), (b, 1), (invalid, nil),
        ]
        let targets: [(source: MediaSource, identity: Int?)] = [
            (.localFile(a.url), 0), (.localFile(aliasURL), 0),
            (.remoteStream(a.url), 0), (.localFile(b.url), 1),
            (.localFile(URL(fileURLWithPath: "/Media/Missing.mkv")), 2),
            (.localFile(invalidURL), nil), (.remoteStream(remoteURL), nil),
        ]
        var queues: [[Int]] = [[]]
        var layer: [[Int]] = [[]]
        for _ in 0..<3 {
            layer = layer.flatMap { prefix in fixtures.indices.map { prefix + [$0] } }
            queues.append(contentsOf: layer)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var comparisons = 0
        for queue in queues {
            let items = queue.map { fixtures[$0].item }
            for target in targets {
                for folder in [nil, URL(fileURLWithPath: "/Media")] as [URL?] {
                    let checkpoint = makeCheckpoint(
                        source: target.source, folder: folder, playlist: items,
                        index: queue.count - 1, unshuffledIDs: items.reversed().map(\.id)
                    )
                    let actual = checkpoint.record()
                    var reference = referenceRecord(checkpoint)
                    // Each constructor reads the clock; all other fields must
                    // match, including the exact encoded URL representations.
                    reference.updatedAt = actual.updatedAt
                    #expect(actual == reference)
                    #expect(try encoder.encode(actual) == encoder.encode(reference))

                    // Fixture labels provide an independent membership oracle.
                    let matches = target.identity.map { targetID in
                        queue.contains { fixtures[$0].identity == targetID }
                    } ?? false
                    #expect(actual.collectionFolder == (matches ? folder : nil))
                    comparisons += 1
                }
            }
        }
        #expect(comparisons == 1_190)
    }

    private func makeCheckpoint(
        source: MediaSource, folder: URL? = nil,
        playlist: [FolderPlaylistItem] = [], index: Int? = nil,
        unshuffledIDs: [FolderPlaylistItem.ID]? = nil
    ) -> PlaybackCheckpoint {
        PlaybackCheckpoint(
            source: source, folder: folder, playlist: playlist, index: index,
            position: 73.5, wasPaused: true, unshuffledPlaylistIDs: unshuffledIDs
        )
    }

    private func item(_ stem: String, marker: Int) -> FolderPlaylistItem {
        FolderPlaylistItem(
            url: URL(fileURLWithPath: "/Media/\(stem).mkv"),
            externalSubtitleURLs: [URL(fileURLWithPath: "/Subtitles/\(marker).srt")],
            dateAdded: Date(timeIntervalSince1970: Double(marker))
        )
    }

    private func decodedItem(_ url: URL, marker: Int) throws -> FolderPlaylistItem {
        struct EncodedItem: Encodable {
            let url: URL
            let externalSubtitleURLs: [URL]
            let dateAdded: Date
        }
        let payload = EncodedItem(
            url: url, externalSubtitleURLs: [URL(fileURLWithPath: "/RawSubtitles/\(marker).srt")],
            dateAdded: Date(timeIntervalSince1970: Double(marker))
        )
        return try JSONDecoder().decode(FolderPlaylistItem.self, from: JSONEncoder().encode(payload))
    }

    private func referenceRecord(_ checkpoint: PlaybackCheckpoint) -> PlaybackSessionRecord {
        let belongsToFolder = checkpoint.source.url.isFileURL && checkpoint.playlist.contains {
            NormalizedFileURL.representsSameFile($0.url, checkpoint.source.url)
        }
        return PlaybackSessionRecord(
            source: checkpoint.source, collectionFolder: belongsToFolder ? checkpoint.folder : nil,
            playlistItems: checkpoint.playlist, playlistIndex: checkpoint.index,
            position: checkpoint.position, wasPaused: checkpoint.wasPaused,
            unshuffledPlaylistIDs: checkpoint.unshuffledPlaylistIDs
        )
    }
}
