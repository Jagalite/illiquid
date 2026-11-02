import Foundation
import IlliquidCore
import Testing
@testable import IlliquidPlayer

@Suite("Playback checkpoint records")
struct PlaybackCheckpointMembershipTests {
    private let folder = URL(fileURLWithPath: "/Media", isDirectory: true)

    @Test(arguments: [0, 1, 2, 3])
    func membershipHandlesFirstMiddleLastAndMissingSources(target: Int) {
        let items = (0..<3).map { item("Episode \($0)", marker: $0) }
        let checkpoint = makeCheckpoint(
            source: .localFile(item("Episode \(target)", marker: target).url),
            playlist: items, index: target < items.count ? target : 0
        )
        expectRecord(checkpoint, collectionFolder: target < items.count ? folder : nil)
    }

    @Test(arguments: [nil, -1, 0, 3, Int.min, Int.max] as [Int?])
    func absentStaleAndInvalidIndicesStillFindTheSource(index: Int?) {
        let items = (0..<3).map { item("Episode \($0)", marker: $0) }
        let checkpoint = makeCheckpoint(
            source: .localFile(items[1].url), playlist: items, index: index
        )
        expectRecord(checkpoint, collectionFolder: folder)
    }

    @Test func noFolderAndEmptyPlaylistsKeepAllOtherRecordFields() {
        let current = item("Movie", marker: 1)
        expectRecord(makeCheckpoint(source: .localFile(current.url),
            playlist: [current], index: 0, folder: nil), collectionFolder: nil)
        expectRecord(makeCheckpoint(source: .localFile(current.url),
            playlist: [], index: 0), collectionFolder: nil)
    }

    @Test(arguments: [0, 2])
    func decodedAliasesAndDuplicatesPreserveTheFirstCompleteItem(index: Int) throws {
        let raw = try decodedItem(
            "file://LOCALHOST/Media/Season/../Cafe%CC%81.mkv?source=restore#chapter",
            marker: 1
        )
        let canonical = item("Caf\u{00E9}", marker: 2)
        let other = item("Other", marker: 3)
        let savedFolder = try #require(URL(string: "file://LOCALHOST/Media/Season/../?restore=1#folder"))
        // Exercise both Unicode spellings as the target, without normalizing
        // decoded playlist items or trusting the duplicate's captured index.
        for url in [raw.url, canonical.url] {
            let checkpoint = makeCheckpoint(source: .localFile(url),
                playlist: [raw, other, canonical], index: index, folder: savedFolder)
            let record = expectRecord(checkpoint, collectionFolder: savedFolder,
                playlistItems: [raw, other])
            #expect(record.playlistItems[0].url.absoluteString == raw.url.absoluteString)
            #expect(record.playlistItems[0].externalSubtitleURLs == raw.externalSubtitleURLs)
            #expect(record.playlistIndex == index)
        }
    }

    @Test(arguments: [
        "file://archive.invalid/Media/Movie.mkv",
        "file://user:password@localhost/Media/Movie.mkv",
        "file://localhost:123/Media/Movie.mkv",
        "https://example.invalid/Media/Movie.mkv",
    ])
    func unsupportedURLsNeverAcquireLocalMembership(spelling: String) throws {
        let unsupported = try decodedItem(spelling, marker: 1)
        let local = item("Movie", marker: 2)
        expectRecord(makeCheckpoint(source: .localFile(unsupported.url),
            playlist: [unsupported, local], index: 0), collectionFolder: nil)
        expectRecord(makeCheckpoint(source: .localFile(local.url),
            playlist: [unsupported], index: 0), collectionFolder: nil)
        expectRecord(makeCheckpoint(source: .remoteStream(unsupported.url),
            playlist: [unsupported], index: 0), collectionFolder: nil)
    }

    @Test func membershipUsesTheURLRatherThanTrustingTheSourceEnumCase() {
        let local = item("Movie", marker: 1)
        // Public enum cases and Codable can carry a URL of the other kind.
        expectRecord(makeCheckpoint(source: .remoteStream(local.url),
            playlist: [local], index: 0), collectionFolder: folder)
    }

    @Test(arguments: [42.25, -1.0, Double.infinity, Double.nan])
    func positionSanitizationAndMetadataAreUnchanged(position: Double) {
        let current = item("Movie", marker: 1)
        let checkpoint = makeCheckpoint(source: .localFile(current.url),
            playlist: [current], index: 0, position: position)
        let record = expectRecord(checkpoint, collectionFolder: folder)
        #expect(record.position == (position.isFinite && position > 0 ? position : 0))
        #expect(record.wasPaused)
        #expect(record.unshuffledPlaylistIDs == ["saved-second", "saved-first"])
    }

    @Test func snapshotsRemainIndependentAfterInputAndRecordMutation() {
        let first = item("First", marker: 1)
        let second = item("Second", marker: 2)
        var items = [first, second]
        let checkpoint = makeCheckpoint(source: .localFile(second.url),
            playlist: items, index: 1)
        items.removeAll()
        var record = expectRecord(checkpoint, collectionFolder: folder)
        let saved = record
        record.playlistItems.removeAll()
        record.unshuffledPlaylistIDs?.removeAll()
        #expect(checkpoint.playlist == [first, second])
        #expect(saved.playlistItems == [first, second])
        #expect(saved.unshuffledPlaylistIDs == ["saved-second", "saved-first"])
        expectRecord(checkpoint, collectionFolder: folder)
    }

    @Test func mutationsSaveClearAndPropagateStoreErrors() throws {
        let current = item("Movie", marker: 1)
        let checkpoint = makeCheckpoint(source: .localFile(current.url),
            playlist: [current], index: 0)
        let store = MemoryStore()
        try PlaybackCheckpointMutation.save(checkpoint).apply(to: store)
        let saved = try #require(store.load())
        var expected = checkpoint.record()
        expected.updatedAt = saved.updatedAt
        #expect(saved == expected)
        try PlaybackCheckpointMutation.clear.apply(to: store)
        #expect(store.load() == nil)

        #expect(throws: StoreFailure.save) {
            try PlaybackCheckpointMutation.save(checkpoint).apply(to: FailingStore())
        }
        #expect(throws: StoreFailure.clear) {
            try PlaybackCheckpointMutation.clear.apply(to: FailingStore())
        }
    }

    private func makeCheckpoint(
        source: MediaSource,
        playlist: [FolderPlaylistItem],
        index: Int?,
        folder: URL? = URL(fileURLWithPath: "/Media", isDirectory: true),
        position: Double = 42.25
    ) -> PlaybackCheckpoint {
        PlaybackCheckpoint(source: source, folder: folder, playlist: playlist,
            index: index, position: position, wasPaused: true,
            unshuffledPlaylistIDs: ["saved-second", "saved-first"])
    }

    @discardableResult
    private func expectRecord(
        _ checkpoint: PlaybackCheckpoint,
        collectionFolder: URL?,
        playlistItems: [FolderPlaylistItem]? = nil
    ) -> PlaybackSessionRecord {
        let before = Date()
        let actual = checkpoint.record()
        let after = Date()
        let expected = PlaybackSessionRecord(source: checkpoint.source,
            collectionFolder: collectionFolder,
            playlistItems: playlistItems ?? checkpoint.playlist,
            playlistIndex: checkpoint.index, position: checkpoint.position,
            wasPaused: checkpoint.wasPaused,
            unshuffledPlaylistIDs: checkpoint.unshuffledPlaylistIDs,
            updatedAt: actual.updatedAt)
        #expect(actual == expected)
        #expect(actual.collectionFolder?.absoluteString == collectionFolder?.absoluteString)
        #expect(actual.updatedAt >= before && actual.updatedAt <= after)
        return actual
    }

    private func item(_ stem: String, marker: Int) -> FolderPlaylistItem {
        FolderPlaylistItem(url: URL(fileURLWithPath: "/Media/\(stem).mkv"),
            externalSubtitleURLs: [URL(fileURLWithPath: "/Subtitles/\(marker).srt")],
            dateAdded: Date(timeIntervalSince1970: Double(marker)))
    }

    private func decodedItem(_ spelling: String, marker: Int) throws -> FolderPlaylistItem {
        let data = try JSONSerialization.data(withJSONObject: [
            "url": spelling,
            "externalSubtitleURLs": ["file:///Subtitles/\(marker).srt"],
            "dateAdded": Double(marker),
        ])
        return try JSONDecoder().decode(FolderPlaylistItem.self, from: data)
    }

    private final class MemoryStore: PlaybackSessionStoring, @unchecked Sendable {
        private let lock = NSLock()
        private var saved: PlaybackSessionRecord?
        func load() -> PlaybackSessionRecord? { lock.withLock { saved } }
        func save(_ session: PlaybackSessionRecord) { lock.withLock { saved = session } }
        func clear() { lock.withLock { saved = nil } }
    }

    private enum StoreFailure: Error, Equatable { case save, clear }

    private struct FailingStore: PlaybackSessionStoring {
        func load() -> PlaybackSessionRecord? { nil }
        func save(_ session: PlaybackSessionRecord) throws { throw StoreFailure.save }
        func clear() throws { throw StoreFailure.clear }
    }
}
