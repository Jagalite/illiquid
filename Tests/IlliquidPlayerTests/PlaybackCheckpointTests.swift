import Foundation
import Testing
import IlliquidCore
@testable import IlliquidPlayer

@Suite("Playback checkpoint folder membership")
struct PlaybackCheckpointTests {
    private let folder = URL(fileURLWithPath: "/Media/Series", isDirectory: true)

    @Test(arguments: [0, 2, 9])
    func noFolderStaysAbsentWhetherTheSourceMatchesOrNot(sourceIndex: Int) {
        let items = (0..<3).map(item)
        let source = MediaSource.localFile(item(sourceIndex).url)
        let record = checkpoint(source: source, playlist: items).record()

        #expect(record.collectionFolder == nil)
        #expect(record.source == source)
        #expect(record.playlistItems == items)
    }

    @Test(arguments: [false, true])
    func emptyPlaylistDoesNotRetainAFolder(hasFolder: Bool) {
        let source = MediaSource.localFile(item(0).url)
        let record = checkpoint(source: source, folder: hasFolder ? folder : nil).record()

        #expect(record.collectionFolder == nil)
        #expect(record.playlistItems.isEmpty)
        #expect(record.source == source)
    }

    @Test(arguments: [0, 2])
    func firstAndLastMatchesRetainTheSuppliedFolder(sourceIndex: Int) {
        let items = (0..<3).map(item)
        // Membership follows the source URL, even when the saved index differs.
        let record = checkpoint(
            source: .localFile(items[sourceIndex].url),
            folder: folder,
            playlist: items,
            index: 1
        ).record()

        #expect(record.collectionFolder == folder)
        #expect(record.playlistIndex == 1)
        #expect(record.playlistItems == items)
    }

    @Test
    func matchingSourceRetainsTheExactFolderWithoutInferringPathContainment() throws {
        let suppliedFolder = try #require(URL(string: "file:///Saved/Collection/../Collection/"))
        let selected = item(0)
        let record = checkpoint(
            source: .localFile(selected.url),
            folder: suppliedFolder,
            playlist: [selected]
        ).record()

        #expect(record.collectionFolder == suppliedFolder)
        #expect(record.collectionFolder?.absoluteString == suppliedFolder.absoluteString)
    }

    @Test
    func missingSourceClearsAStaleFolderWithoutDroppingThePlaylist() {
        let items = (0..<3).map(item)
        let source = MediaSource.localFile(item(99).url)
        let record = checkpoint(
            source: source, folder: folder, playlist: items, index: 2
        ).record()

        #expect(record.collectionFolder == nil)
        #expect(record.source == source)
        #expect(record.playlistItems == items)
        #expect(record.playlistIndex == 2)
    }

    @Test(arguments: [
        "file:///Media/Series/Season/../Caf%C3%A9.mkv",
        "file:///Media/Series/Cafe%CC%81.mkv",
        "file://LOCALHOST/Media/Series/Caf%C3%A9.mkv",
    ])
    func lexicalAndUnicodeSourceAliasesMatchWithoutRewritingTheSource(input: String) throws {
        let sourceURL = try #require(URL(string: input))
        let selected = FolderPlaylistItem(url: URL(fileURLWithPath: "/Media/Series/Caf\u{00E9}.mkv"))
        let record = checkpoint(
            source: .localFile(sourceURL), folder: folder, playlist: [item(0), selected]
        ).record()

        #expect(record.collectionFolder == folder)
        #expect(record.source == .localFile(sourceURL))
        #expect(record.source.url.absoluteString == sourceURL.absoluteString)
        #expect(record.playlistItems == [item(0), selected])
    }

    @Test
    func decodedUnnormalizedPlaylistEntryStillMatches() throws {
        // Codable can bypass FolderPlaylistItem's normalizing initializer.
        let data = Data(#"{"url":"file:///Media/Series/Season/../Cafe%CC%81.mkv","externalSubtitleURLs":[]}"#.utf8)
        let selected = try JSONDecoder().decode(FolderPlaylistItem.self, from: data)
        let source = MediaSource.localFile(URL(fileURLWithPath: "/Media/Series/Caf\u{00E9}.mkv"))
        let record = checkpoint(
            source: source, folder: folder, playlist: [item(0), selected]
        ).record()

        #expect(record.collectionFolder == folder)
        #expect(record.playlistItems == [item(0), selected])
        #expect(record.playlistItems[1].url.absoluteString == selected.url.absoluteString)
    }

    @Test(arguments: [false, true])
    func remoteURLNeverAcquiresAFolderEvenWhenPresentInThePlaylist(localLabel: Bool) throws {
        let remote = try #require(URL(string: "https://media.example/Series/Episode.mkv"))
        // Public enum construction also permits a mismatched source label.
        let source: MediaSource = localLabel ? .localFile(remote) : .remoteStream(remote)
        let items = [FolderPlaylistItem(url: remote), item(0)]
        let record = checkpoint(source: source, folder: folder, playlist: items).record()

        #expect(record.collectionFolder == nil)
        #expect(record.source == source)
        #expect(record.playlistItems == items)
    }

    @Test(arguments: [
        "file://media-server.example/Media/Series/Episode-0.mkv",
        "file://user@localhost/Media/Series/Episode-0.mkv",
        "file://localhost:1234/Media/Series/Episode-0.mkv",
        "file:relative.mkv",
    ])
    func unsupportedSourceDoesNotMatchAnIdenticalInvalidPlaylistURL(input: String) throws {
        let invalid = try #require(URL(string: input))
        let items = [FolderPlaylistItem(url: invalid), item(0)]
        let record = checkpoint(
            source: .localFile(invalid), folder: folder, playlist: items
        ).record()

        // Neither equal raw URLs nor two absent normalized keys prove membership.
        #expect(record.collectionFolder == nil)
        #expect(record.source == .localFile(invalid))
        #expect(record.playlistItems == items)
    }

    @Test
    func unsupportedPlaylistEntriesAreSkippedBeforeAValidMatch() throws {
        let invalid = try #require(URL(string: "file://media-server.example/Media/Series/Episode-0.mkv"))
        let remote = try #require(URL(string: "https://media.example/Series/Episode-0.mkv"))
        let selected = item(0)
        let items = [FolderPlaylistItem(url: invalid), FolderPlaylistItem(url: remote), selected]
        let record = checkpoint(
            source: .localFile(selected.url), folder: folder, playlist: items
        ).record()

        #expect(record.collectionFolder == folder)
        #expect(record.playlistItems == items)
    }

    @Test
    func validFileURLRetainsExistingMembershipSemanticsDespiteItsEnumLabel() {
        let selected = item(0)
        let source = MediaSource.remoteStream(selected.url)
        let record = checkpoint(
            source: source, folder: folder, playlist: [selected]
        ).record()

        // Checkpoint construction preserves data. Source-open authorization
        // separately rejects a mismatched label through MediaLoadRequest.
        #expect(record.collectionFolder == folder)
        #expect(record.source == source)
    }

    @Test
    func completeRecordKeepsFirstDuplicateMetadataAndRoundTrips() throws {
        let selected = item(2)
        let other = item(0)
        let duplicate = FolderPlaylistItem(
            url: selected.url,
            externalSubtitleURLs: [URL(fileURLWithPath: "/Subtitles/replacement.srt")],
            dateAdded: .distantFuture
        )
        let order = [other.id, selected.id]
        let record = checkpoint(
            source: .localFile(selected.url),
            folder: folder,
            playlist: [selected, other, duplicate, other],
            index: 0,
            position: 123.25,
            wasPaused: false,
            unshuffledIDs: order
        ).record()

        #expect(record.schemaVersion == PlaybackSessionRecord.currentSchemaVersion)
        #expect(record.source == .localFile(selected.url))
        #expect(record.collectionFolder == folder)
        #expect(record.playlistItems == [selected, other])
        #expect(record.playlistItems[0].externalSubtitleURLs == selected.externalSubtitleURLs)
        #expect(record.playlistItems[0].dateAdded == selected.dateAdded)
        #expect(record.playlistIndex == 0)
        #expect(record.position == 123.25)
        #expect(!record.wasPaused)
        #expect(record.unshuffledPlaylistIDs == order)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(record)
        let restored = try JSONDecoder().decode(PlaybackSessionRecord.self, from: encoded)
        #expect(restored == record)
        #expect(restored.updatedAt == record.updatedAt)
        #expect(try encoder.encode(restored) == encoded)
    }

    @Test(arguments: [-1.0, Double.nan, Double.infinity, -Double.infinity])
    func invalidPositionStillUsesTheSessionRecordSanitizer(position: Double) {
        let selected = item(0)
        let record = checkpoint(
            source: .localFile(selected.url), folder: folder,
            playlist: [selected], position: position
        ).record()

        #expect(record.position == 0)
        #expect(record.wasPaused)
        #expect(record.playlistIndex == nil)
        #expect(record.unshuffledPlaylistIDs == nil)
        #expect(record.collectionFolder == folder)
    }

    @Test
    func saveAndClearMutationsDeliverTheExpectedRecordToTheStore() throws {
        let selected = item(0)
        let store = RecordingSessionStore()
        try PlaybackCheckpointMutation.save(checkpoint(
            source: .localFile(selected.url), folder: folder,
            playlist: [selected], index: 0, position: 77
        )).apply(to: store)

        let saved = try #require(store.load())
        #expect(saved.source == .localFile(selected.url))
        #expect(saved.collectionFolder == folder)
        #expect(saved.playlistItems == [selected])
        #expect(saved.playlistIndex == 0)
        #expect(saved.position == 77)
        #expect(saved.wasPaused)
        #expect(saved.unshuffledPlaylistIDs == nil)

        try PlaybackCheckpointMutation.clear.apply(to: store)
        #expect(store.load() == nil)
    }

    private func item(_ index: Int) -> FolderPlaylistItem {
        FolderPlaylistItem(
            url: URL(fileURLWithPath: "/Media/Series/Episode-\(index).mkv"),
            externalSubtitleURLs: [URL(fileURLWithPath: "/Subtitles/Episode-\(index).srt")],
            dateAdded: Date(timeIntervalSince1970: Double(index))
        )
    }

    private func checkpoint(
        source: MediaSource,
        folder: URL? = nil,
        playlist: [FolderPlaylistItem] = [],
        index: Int? = nil,
        position: TimeInterval = 42.5,
        wasPaused: Bool = true,
        unshuffledIDs: [FolderPlaylistItem.ID]? = nil
    ) -> PlaybackCheckpoint {
        PlaybackCheckpoint(
            source: source,
            folder: folder,
            playlist: playlist,
            index: index,
            position: position,
            wasPaused: wasPaused,
            unshuffledPlaylistIDs: unshuffledIDs
        )
    }

    private final class RecordingSessionStore: PlaybackSessionStoring, @unchecked Sendable {
        private let lock = NSLock()
        private var record: PlaybackSessionRecord?

        func load() -> PlaybackSessionRecord? {
            lock.lock()
            defer { lock.unlock() }
            return record
        }

        func save(_ session: PlaybackSessionRecord) {
            lock.lock()
            defer { lock.unlock() }
            record = session
        }

        func clear() {
            lock.lock()
            defer { lock.unlock() }
            record = nil
        }
    }
}
