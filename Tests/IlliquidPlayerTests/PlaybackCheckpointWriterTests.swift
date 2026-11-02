import Foundation
import Testing
import IlliquidCore
@testable import IlliquidPlayer

@Suite("Playback checkpoint folder membership")
struct PlaybackCheckpointWriterTests {
    private let folder = URL(fileURLWithPath: "/Collection", isDirectory: true)

    private func checkpoint(
        _ source: MediaSource,
        items: [FolderPlaylistItem],
        folder: URL?,
        index: Int? = 7,
        position: TimeInterval = 23.5
    ) -> PlaybackCheckpoint {
        PlaybackCheckpoint(
            source: source,
            folder: folder,
            playlist: items,
            index: index,
            position: position,
            wasPaused: true,
            unshuffledPlaylistIDs: ["saved-order", "retained-verbatim"]
        )
    }

    @discardableResult
    private func check(
        _ checkpoint: PlaybackCheckpoint,
        folder: URL?,
        items: [FolderPlaylistItem],
        position: TimeInterval? = nil
    ) -> PlaybackSessionRecord {
        let inputItems = checkpoint.playlist
        let record = checkpoint.record()
        #expect(record.schemaVersion == PlaybackSessionRecord.currentSchemaVersion)
        #expect(record.source == checkpoint.source)
        #expect(record.collectionFolder == folder)
        #expect(record.playlistItems == items)
        #expect(record.playlistIndex == checkpoint.index)
        #expect(record.unshuffledPlaylistIDs == checkpoint.unshuffledPlaylistIDs)
        #expect(record.position == (position ?? checkpoint.position))
        #expect(record.wasPaused == checkpoint.wasPaused)
        #expect(checkpoint.playlist == inputItems)
        return record
    }

    private struct ItemPayload: Encodable {
        let url: URL
        let externalSubtitleURLs: [URL]
        let dateAdded: Date?
    }

    private func decodedItem(
        _ url: URL,
        subtitles: [URL] = [],
        date: Date? = nil
    ) throws -> FolderPlaylistItem {
        let payload = ItemPayload(url: url, externalSubtitleURLs: subtitles, dateAdded: date)
        return try JSONDecoder().decode(FolderPlaylistItem.self, from: JSONEncoder().encode(payload))
    }

    private static let unsupportedFileURLs = [
        "file://server.example/Media/feature.mkv",
        "file://localhost.example/Media/feature.mkv",
        "file://127.0.0.1/Media/feature.mkv",
        "file://user@localhost/Media/feature.mkv",
        "file://user:secret@localhost/Media/feature.mkv",
        "file://localhost:1234/Media/feature.mkv",
        "file:relative.mkv",
        "file://",
    ]

    @Test(arguments: [0, 16, 31])
    func findsSourceAtAnyPosition(_ matchingIndex: Int) throws {
        let items = (0..<32).map {
            FolderPlaylistItem(url: URL(fileURLWithPath: "/Media/episode-\($0).mkv"))
        }
        let alias = try #require(URL(string: "file:///Media/temporary/../episode-\(matchingIndex).mkv"))
        check(checkpoint(.localFile(alias), items: items, folder: folder), folder: folder, items: items)
    }

    @Test(arguments: [0, 32])
    func dropsFolderWhenSourceIsMissing(_ itemCount: Int) {
        let items = (0..<itemCount).map {
            FolderPlaylistItem(url: URL(fileURLWithPath: "/Media/episode-\($0).mkv"))
        }
        let source = MediaSource.localFile(URL(fileURLWithPath: "/Media/missing.mkv"))
        check(checkpoint(source, items: items, folder: folder), folder: nil, items: items)
    }

    @Test(arguments: PlaybackCheckpointWriterTests.unsupportedFileURLs)
    func invalidIdentitiesNeverMatchEachOther(_ input: String) throws {
        let url = try #require(URL(string: input))
        let item = try decodedItem(url)
        check(checkpoint(.localFile(url), items: [item], folder: folder), folder: nil, items: [item])
        let local = MediaSource.localFile(URL(fileURLWithPath: "/Media/feature.mkv"))
        check(checkpoint(local, items: [item], folder: folder), folder: nil, items: [item])
    }

    @Test
    func decodedAliasesRetainFirstMetadataAndRoundTrip() throws {
        let alias = try #require(URL(string: "file:///Media/temporary/../cafe%CC%81.mkv"))
        let canonical = try #require(URL(string: "file://LOCALHOST/Media/caf%C3%A9.mkv"))
        let subtitles = [
            URL(fileURLWithPath: "/Subs/z.srt"),
            URL(fileURLWithPath: "/Subs/a.srt"),
        ]
        let first = try decodedItem(alias, subtitles: subtitles, date: Date(timeIntervalSince1970: 100))
        let duplicate = try decodedItem(canonical, subtitles: [], date: Date(timeIntervalSince1970: 200))
        #expect(first.url.absoluteString == alias.absoluteString)
        #expect(first.externalSubtitleURLs == subtitles)
        let input = checkpoint(.localFile(canonical), items: [first, duplicate], folder: folder, index: 1)
        let record = check(input, folder: folder, items: [first])
        #expect(record.playlistItems[0].dateAdded == Date(timeIntervalSince1970: 100))
        let data = try JSONEncoder().encode(record)
        #expect(try JSONDecoder().decode(PlaybackSessionRecord.self, from: data) == record)
    }

    @Test
    func skipsInvalidItemsBeforeFindingLocalhostAlias() throws {
        let invalid = try decodedItem(#require(URL(string: "file://server.example/Media/feature.mkv")))
        let remote = try decodedItem(#require(URL(string: "https://example.com/Media/feature.mkv")))
        let local = try decodedItem(#require(URL(string: "file://LOCALHOST/Media/./feature.mkv")))
        let items = [invalid, remote, local]
        let source = MediaSource.localFile(URL(fileURLWithPath: "/Media/feature.mkv"))
        check(checkpoint(source, items: items, folder: folder), folder: folder, items: items)
    }

    @Test
    func preservesURLBasedBehaviorForMislabeledSourceCasesAndNilFolder() throws {
        let local = URL(fileURLWithPath: "/Media/feature.mkv")
        let remote = try #require(URL(string: "https://example.com/Media/feature.mkv"))
        let localItems = [FolderPlaylistItem(url: local)]
        let remoteItems = [FolderPlaylistItem(url: remote)]
        // The existing checkpoint contract checks the URL, not the enum label.
        check(checkpoint(.remoteStream(local), items: localItems, folder: folder), folder: folder, items: localItems)
        check(checkpoint(.localFile(remote), items: remoteItems, folder: folder), folder: nil, items: remoteItems)
        check(checkpoint(.remoteStream(remote), items: remoteItems, folder: folder), folder: nil, items: remoteItems)
        check(checkpoint(.localFile(local), items: localItems, folder: nil), folder: nil, items: localItems)
    }

    @Test(arguments: [-3, 0, 1, 99])
    func membershipDoesNotTrustOrRewriteSavedIndex(_ index: Int) {
        let local = URL(fileURLWithPath: "/Media/feature.mkv")
        let items = [
            FolderPlaylistItem(url: local),
            FolderPlaylistItem(url: URL(fileURLWithPath: "/Media/other.mkv")),
        ]
        check(checkpoint(.localFile(local), items: items, folder: folder, index: index), folder: folder, items: items)
    }

    @Test(arguments: [Double.nan, Double.infinity, -Double.infinity, -1, 0, 42.25])
    func retainsSessionPositionSanitization(_ position: Double) {
        let local = URL(fileURLWithPath: "/Media/feature.mkv")
        let items = [FolderPlaylistItem(url: local)]
        let input = checkpoint(.localFile(local), items: items, folder: folder, position: position)
        check(input, folder: folder, items: items, position: position.isFinite ? max(0, position) : 0)
    }

    @Test
    func relativeSourcesRetainTheirBaseAuthorityAndOriginalURL() throws {
        let base = URL(fileURLWithPath: "/Media/", isDirectory: true)
        let relative = try #require(URL(string: "feature.mkv", relativeTo: base))
        let items = [FolderPlaylistItem(url: URL(fileURLWithPath: "/Media/feature.mkv"))]
        check(checkpoint(.localFile(relative), items: items, folder: folder),
              folder: relative.isFileURL ? folder : nil, items: items)
        let remoteBase = try #require(URL(string: "file://server.example/Media/"))
        let remote = try #require(URL(string: "feature.mkv", relativeTo: remoteBase))
        check(checkpoint(.localFile(remote), items: items, folder: folder), folder: nil, items: items)
    }
}
