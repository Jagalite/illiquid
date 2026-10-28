import Foundation
import IlliquidCore
import Testing
@testable import IlliquidPlayer

@Suite("Playback checkpoint folder membership")
struct PlaybackCheckpointTests {
    private let folder = URL(fileURLWithPath: "/Media", isDirectory: true)

    private func item(_ name: String) -> FolderPlaylistItem {
        FolderPlaylistItem(
            url: URL(fileURLWithPath: "/Media/\(name).mkv"),
            externalSubtitleURLs: [URL(fileURLWithPath: "/Media/\(name).en.srt")],
            dateAdded: Date(timeIntervalSince1970: 1_234)
        )
    }

    private func checkpoint(
        _ source: MediaSource, _ items: [FolderPlaylistItem], _ index: Int?,
        folder: URL? = URL(fileURLWithPath: "/Media", isDirectory: true),
        position: TimeInterval = 42.5, paused: Bool = true,
        ids: [FolderPlaylistItem.ID]? = ["saved-last", "saved-first"]
    ) -> PlaybackCheckpoint {
        PlaybackCheckpoint(
            source: source, folder: folder, playlist: items, index: index,
            position: position, wasPaused: paused, unshuffledPlaylistIDs: ids
        )
    }

    @discardableResult
    private func recordMatchingOriginal(_ checkpoint: PlaybackCheckpoint) -> PlaybackSessionRecord {
        let belongs = checkpoint.source.url.isFileURL && checkpoint.playlist.contains {
            NormalizedFileURL.representsSameFile($0.url, checkpoint.source.url)
        }
        let expected = PlaybackSessionRecord(
            source: checkpoint.source, collectionFolder: belongs ? checkpoint.folder : nil,
            playlistItems: checkpoint.playlist, playlistIndex: checkpoint.index,
            position: checkpoint.position, wasPaused: checkpoint.wasPaused,
            unshuffledPlaylistIDs: checkpoint.unshuffledPlaylistIDs,
            updatedAt: Date(timeIntervalSince1970: 5_678)
        )
        var actual = checkpoint.record()
        actual.updatedAt = expected.updatedAt
        #expect(actual == expected)
        return actual
    }

    @Test(arguments: [0, 1, 2])
    func indexedMemberRetainsFolder(index: Int) {
        let items = [item("a"), item("b"), item("c")]
        let result = recordMatchingOriginal(checkpoint(.localFile(items[index].url), items, index))
        #expect(result.collectionFolder == folder)
    }

    @Test(arguments: [nil, 0, 1, -1, 3, Int.min, Int.max] as [Int?])
    func staleMissingAndOutOfBoundsHintsStillFindMember(index: Int?) {
        let items = [item("a"), item("b"), item("c")]
        let result = recordMatchingOriginal(checkpoint(.localFile(items[2].url), items, index))
        #expect(result.collectionFolder == folder)
        #expect(result.playlistIndex == index)
    }

    @Test func missingFolderOrMembershipDoesNotInventAssociation() {
        let member = item("a")
        let withoutFolder = checkpoint(.localFile(member.url), [member], 0, folder: nil)
        #expect(recordMatchingOriginal(withoutFolder).collectionFolder == nil)
        for items in [[], [member]] {
            for index in [nil, 0, Int.min, Int.max] as [Int?] {
                let absent = checkpoint(.localFile(item("absent").url), items, index)
                #expect(recordMatchingOriginal(absent).collectionFolder == nil)
            }
        }
    }

    @Test func duplicateAtHintRetainsFirstMetadataAndOriginalIndex() {
        let first = item("a")
        let duplicate = FolderPlaylistItem(
            url: first.url, externalSubtitleURLs: [],
            dateAdded: Date(timeIntervalSince1970: 9_999)
        )
        let last = item("b")
        let result = recordMatchingOriginal(
            checkpoint(.localFile(first.url), [first, duplicate, last], 1)
        )
        #expect(result.collectionFolder == folder)
        #expect(result.playlistItems == [first, last])
        #expect(result.playlistIndex == 1)
    }

    @Test(arguments: [
        "file:///Media/sub/../Caf%C3%A9.mkv",
        "file:///Media/Cafe%CC%81.mkv",
        "file:///Media/sub/../Cafe%CC%81.mkv",
        "file://localhost/Media/Caf%C3%A9.mkv",
    ])
    func decodedLexicalAndUnicodeAliasesMatch(raw: String) throws {
        let url = try #require(URL(string: raw))
        let data = try JSONSerialization.data(withJSONObject: [
            "url": url.absoluteString, "externalSubtitleURLs": [String](),
        ] as [String: Any])
        let decoded = try JSONDecoder().decode(FolderPlaylistItem.self, from: data)
        #expect(decoded.url.absoluteString == url.absoluteString)
        let source = MediaSource.localFile(URL(fileURLWithPath: "/Media/Caf\u{00E9}.mkv"))
        for index in [0, 1, nil] as [Int?] {
            let result = recordMatchingOriginal(checkpoint(source, [item("other"), decoded], index))
            #expect(result.collectionFolder == folder)
            #expect(result.playlistItems.last?.url.absoluteString == url.absoluteString)
        }
    }

    @Test(arguments: [
        "file://server/Media/a.mkv",
        "file://user@localhost/Media/a.mkv",
        "file://localhost:80/Media/a.mkv",
    ])
    func unsupportedAuthoritiesCannotMatchEvenAtHint(raw: String) throws {
        let url = try #require(URL(string: raw))
        let unsupported = FolderPlaylistItem(url: url)
        let local = item("a")
        for source in [MediaSource.localFile(url), .localFile(local.url)] {
            let result = recordMatchingOriginal(checkpoint(source, [unsupported], 0))
            #expect(result.collectionFolder == nil)
        }
        let fallback = checkpoint(.localFile(local.url), [unsupported, local], 0)
        #expect(recordMatchingOriginal(fallback).collectionFolder == folder)
    }

    @Test func sourceCaseDoesNotReplaceExistingURLBasedMembershipRules() throws {
        let local = item("a")
        let remote = FolderPlaylistItem(url: try #require(URL(string: "https://example.com/a.mkv")))
        let unusualFile = checkpoint(.remoteStream(local.url), [local], 0)
        #expect(recordMatchingOriginal(unusualFile).collectionFolder == folder)
        for source in [MediaSource.localFile(remote.url), .remoteStream(remote.url)] {
            let unusualRemote = checkpoint(source, [remote], 0)
            #expect(recordMatchingOriginal(unusualRemote).collectionFolder == nil)
        }
    }

    @Test(arguments: [-1, 0, 42.5, Double.nan, .infinity, -.infinity], [false, true])
    func recordMetadataAndPositionSanitizationRemainUnchanged(position: Double, paused: Bool) {
        let items = [item("a"), item("b")]
        let savedOrder = [items[1].id, items[0].id, "removed", items[1].id]
        for ids in [nil, savedOrder] as [[FolderPlaylistItem.ID]?] {
            let result = recordMatchingOriginal(checkpoint(
                .localFile(items[1].url), items, 1, position: position, paused: paused, ids: ids
            ))
            #expect(result.position == (position.isFinite ? max(0, position) : 0))
            #expect(result.unshuffledPlaylistIDs == ids)
        }
    }
}
