import Foundation
import Testing
@testable import IlliquidCore

@Suite("Playlist session record semantics")
struct PlaylistSessionRecordTests {
    @Test func uniquePlaylistSnapshotsRemainIndependent() {
        let original = (0..<16).map(item)
        var input = original
        var record = makeRecord(input)
        let checkpoint = record

        record.playlistItems.removeLast()
        input[0] = item(99)
        #expect(checkpoint.playlistItems == original)
        #expect(record.playlistItems == Array(original.dropLast()))
        #expect(input[0] == item(99))
        #expect(checkpoint.playlistIndex == 1)
        #expect(checkpoint.position == 42.5)
    }

    @Test func checkpointDeduplicationKeepsFirstMetadataAndSavedOrder() {
        let first = item(10)
        let second = item(2)
        let conflicting = FolderPlaylistItem(
            url: first.url,
            externalSubtitleURLs: [URL(fileURLWithPath: "/Subtitles/later.srt")],
            dateAdded: .distantFuture
        )
        let record = makeRecord([first, second, conflicting, second])

        #expect(record.playlistItems == [first, second])
        #expect(record.playlistIndex == 1)
        #expect(record.unshuffledPlaylistIDs == [second.id, first.id])
    }

    @Test func decodingDuplicateSavedItemsPreservesTheFirstCompleteItem() throws {
        let first = item(10)
        let second = item(2)
        var stored = makeRecord([first, second])
        // Model persisted input that has not passed the current initializer:
        // decoding must still apply the same deduplication contract.
        stored.playlistItems.append(FolderPlaylistItem(url: first.url, dateAdded: .distantFuture))
        stored.playlistItems.append(second)
        let restored = try JSONDecoder().decode(
            PlaybackSessionRecord.self, from: JSONEncoder().encode(stored)
        )

        #expect(restored.playlistItems == [first, second])
        #expect(restored.playlistIndex == stored.playlistIndex)
        #expect(restored.unshuffledPlaylistIDs == stored.unshuffledPlaylistIDs)
        #expect(restored.source == stored.source)
        #expect(restored.updatedAt == stored.updatedAt)
    }

    @Test func uniquePlaylistEncodingRemainsStableAfterRoundTrip() throws {
        let record = makeRecord((0..<32).map(item))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(record)
        let restored = try JSONDecoder().decode(PlaybackSessionRecord.self, from: bytes)

        #expect(restored == record)
        #expect(try encoder.encode(restored) == bytes)
    }

    private func item(_ index: Int) -> FolderPlaylistItem {
        FolderPlaylistItem(
            url: URL(fileURLWithPath: "/Media/Episode \(index).mkv"),
            externalSubtitleURLs: [URL(fileURLWithPath: "/Subtitles/\(index).srt")],
            dateAdded: Date(timeIntervalSince1970: Double(index))
        )
    }

    private func makeRecord(_ items: [FolderPlaylistItem]) -> PlaybackSessionRecord {
        PlaybackSessionRecord(
            source: .localFile(URL(fileURLWithPath: "/Media/Episode 2.mkv")),
            playlistItems: items,
            playlistIndex: 1,
            position: 42.5,
            wasPaused: true,
            unshuffledPlaylistIDs: [item(2).id, item(10).id],
            updatedAt: Date(timeIntervalSince1970: 1_234)
        )
    }
}
