import Foundation
import Testing
@testable import IlliquidCore
@testable import IlliquidPlayer

@Suite("Playback checkpoint identity")
struct PlaybackCheckpointTests {
    private let folder = URL(fileURLWithPath: "/Media", isDirectory: true)

    @Test func folderMembershipHandlesEveryPositionAndMissingSources() {
        let items = (0..<4).map { FolderPlaylistItem(url: mediaURL($0)) }
        for index in items.indices {
            let record = checkpoint(source: .localFile(items[index].url), items: items).record()
            #expect(record.collectionFolder == folder)
            #expect(record.source == .localFile(items[index].url))
            #expect(record.playlistItems == items)
        }
        #expect(checkpoint(source: .localFile(mediaURL(99)), items: items)
            .record().collectionFolder == nil)
        #expect(checkpoint(source: .localFile(mediaURL(0)), items: [])
            .record().collectionFolder == nil)
    }

    @Test func absentFolderPreservesThePlaylistAndPlaybackFields() {
        let first = FolderPlaylistItem(
            url: mediaURL(0),
            externalSubtitleURLs: [URL(fileURLWithPath: "/Subtitles/original.srt")],
            dateAdded: Date(timeIntervalSince1970: 123)
        )
        let second = FolderPlaylistItem(url: mediaURL(1))
        let duplicate = FolderPlaylistItem(url: first.url, dateAdded: .distantFuture)
        let before = Date()
        let record = PlaybackCheckpoint(
            source: .localFile(second.url), folder: nil,
            playlist: [first, second, duplicate], index: 1,
            position: 42.5, wasPaused: true,
            unshuffledPlaylistIDs: [second.id, first.id]
        ).record()
        let after = Date()

        #expect(record.collectionFolder == nil)
        #expect(record.playlistItems == [first, second])
        #expect(record.playlistIndex == 1)
        #expect(record.position == 42.5)
        #expect(record.wasPaused)
        #expect(record.unshuffledPlaylistIDs == [second.id, first.id])
        #expect(record.schemaVersion == PlaybackSessionRecord.currentSchemaVersion)
        #expect(record.updatedAt >= before && record.updatedAt <= after)
    }

    @Test func decodedAliasesRetainCanonicalMembership() throws {
        let canonical = URL(fileURLWithPath: "/Media/Caf\u{00E9}.mkv")
        let aliases = [
            URL(fileURLWithPath: "/Media/./Caf\u{00E9}.mkv"),
            URL(fileURLWithPath: "/Media/sub/../Caf\u{00E9}.mkv"),
            URL(fileURLWithPath: "/Media/Cafe\u{0301}.mkv"),
            try #require(URL(string: "file://localhost/Media/Caf%C3%A9.mkv")),
            try #require(URL(string: "Caf%C3%A9.mkv", relativeTo: folder)),
        ]
        for alias in aliases {
            // Decoding bypasses FolderPlaylistItem's normalizing initializer.
            let decoded = try decodedItem(alias)
            let input = [FolderPlaylistItem(url: mediaURL(99)), decoded]
            let record = checkpoint(source: .localFile(canonical), items: input).record()
            #expect(record.collectionFolder == folder)
            #expect(record.playlistItems == input)
            #expect(checkpoint(source: .localFile(alias), items: [try decodedItem(canonical)])
                .record().collectionFolder == folder)
        }
    }

    @Test func unsupportedIdentitiesNeverMatchEachOtherOrLocalPaths() throws {
        let local = URL(fileURLWithPath: "/Media/Film.mkv")
        for raw in [
            "file://server/Media/Film.mkv",
            "file://person@localhost/Media/Film.mkv",
            "file://localhost:123/Media/Film.mkv",
            "https://example.invalid/Media/Film.mkv",
            "Film.mkv",
        ] {
            let unsupported = try #require(URL(string: raw))
            let invalidItem = try decodedItem(unsupported)
            #expect(checkpoint(source: .localFile(unsupported), items: [invalidItem])
                .record().collectionFolder == nil)
            #expect(checkpoint(source: .localFile(unsupported), items: [try decodedItem(local)])
                .record().collectionFolder == nil)
            #expect(checkpoint(source: .localFile(local), items: [invalidItem])
                .record().collectionFolder == nil)
            // An invalid item before a valid match must not terminate the scan.
            #expect(checkpoint(source: .localFile(local), items: [invalidItem, try decodedItem(local)])
                .record().collectionFolder == folder)
        }
    }

    @Test func membershipKeepsTheExistingURLBasedSourceContract() throws {
        let local = mediaURL(0)
        let remote = try #require(URL(string: "https://example.invalid/Film.mkv"))
        // Public enum cases and decoded records can contain mismatched tags.
        // Checkpoint membership has always followed the URL, not the enum tag.
        #expect(checkpoint(source: .remoteStream(local), items: [try decodedItem(local)])
            .record().collectionFolder == folder)
        #expect(checkpoint(source: .localFile(remote), items: [try decodedItem(remote)])
            .record().collectionFolder == nil)
        #expect(checkpoint(source: .remoteStream(remote), items: [try decodedItem(remote)])
            .record().collectionFolder == nil)
    }

    @Test func recordsRetainFirstMetadataAndIndependentSnapshots() throws {
        let first = FolderPlaylistItem(url: mediaURL(0), dateAdded: .distantPast)
        let second = FolderPlaylistItem(url: mediaURL(1))
        let duplicate = FolderPlaylistItem(url: mediaURL(0), dateAdded: .distantFuture)
        var items = [first, second, duplicate]
        let captured = checkpoint(source: .localFile(first.url), items: items)
        var record = captured.record()
        items[0] = FolderPlaylistItem(url: mediaURL(99))
        record.playlistItems.removeAll()
        let again = captured.record()
        #expect(again.playlistItems == [first, second])
        #expect(again.collectionFolder == folder)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(again)
        #expect(try JSONDecoder().decode(PlaybackSessionRecord.self, from: encoded) == again)
    }

    private func mediaURL(_ index: Int) -> URL {
        URL(fileURLWithPath: "/Media/Episode \(index).mkv")
    }

    private func checkpoint(source: MediaSource, items: [FolderPlaylistItem]) -> PlaybackCheckpoint {
        PlaybackCheckpoint(source: source, folder: folder, playlist: items,
                           index: nil, position: 12, wasPaused: false,
                           unshuffledPlaylistIDs: nil)
    }

    private func decodedItem(_ url: URL) throws -> FolderPlaylistItem {
        struct RawItem: Encodable {
            let url: URL
            let externalSubtitleURLs: [URL] = []
        }
        return try JSONDecoder().decode(FolderPlaylistItem.self, from: JSONEncoder().encode(RawItem(url: url)))
    }
}
