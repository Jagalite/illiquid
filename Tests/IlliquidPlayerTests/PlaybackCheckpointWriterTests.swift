import Foundation
import IlliquidCore
import Testing
@testable import IlliquidPlayer

@Suite("Playback checkpoint records")
struct PlaybackCheckpointWriterTests {
    @Test(arguments: [false, true])
    func folderMembershipDoesNotDependOnTheSavedIndex(hasFolder: Bool) {
        let items = (0..<3).map { item("Episode \($0).mkv", marker: $0) }
        let folder = URL(fileURLWithPath: "/Media", isDirectory: true)
        let sources = items.map(\.url) + [URL(fileURLWithPath: "/Media/Missing.mkv")]

        for (offset, source) in sources.enumerated() {
            for index in [nil, -1, 0, 2, 3, Int.max] as [Int?] {
                let checkpoint = makeCheckpoint(
                    source: .localFile(source), folder: hasFolder ? folder : nil,
                    items: items, index: index
                )
                let record = checkpoint.record()

                #expect(record == historicalRecord(checkpoint, updatedAt: record.updatedAt))
                #expect(record.collectionFolder == (hasFolder && offset < items.count ? folder : nil))
                #expect(record.playlistItems == items)
                #expect(record.playlistIndex == index)
            }
        }
    }

    @Test(arguments: [false, true])
    func emptyPlaylistNeverKeepsACollectionFolder(hasFolder: Bool) {
        let checkpoint = makeCheckpoint(
            source: .localFile(URL(fileURLWithPath: "/Media/Movie.mkv")),
            folder: hasFolder ? URL(fileURLWithPath: "/Media", isDirectory: true) : nil,
            items: [], index: 0
        )
        let record = checkpoint.record()

        #expect(record == historicalRecord(checkpoint, updatedAt: record.updatedAt))
        #expect(record.collectionFolder == nil)
        #expect(record.playlistItems.isEmpty)
        #expect(record.playlistIndex == 0)
    }

    @Test func decodedAliasesAndRelativeSourcesKeepTheCollectionFolder() throws {
        let folder = URL(fileURLWithPath: "/Media", isDirectory: true)
        let canonical = URL(fileURLWithPath: "/Media/Caf\u{e9}.mkv")
        let rawURL = try #require(URL(string: "file://LOCALHOST/Media/Season/../Cafe%CC%81.mkv"))
        let raw = try decodedItem(rawURL, marker: 7)
        // Decoding bypasses the normalizing FolderPlaylistItem initializer.
        #expect(raw.url.absoluteString == rawURL.absoluteString)
        #expect(raw.url.absoluteString.contains("/Season/../"))
        let base = try #require(URL(string: "file:///Media/"))
        let sources = [
            canonical,
            rawURL,
            try #require(URL(string: "file://localhost/Media/Caf%C3%A9.mkv")),
            try #require(URL(string: "Season/../Cafe%CC%81.mkv", relativeTo: base)),
        ]
        let items = [item("Other.mkv", marker: 0), raw]

        for url in sources {
            let checkpoint = makeCheckpoint(
                source: .localFile(url), folder: folder, items: items, index: nil
            )
            let record = checkpoint.record()

            #expect(record == historicalRecord(checkpoint, updatedAt: record.updatedAt))
            #expect(record.collectionFolder == folder)
            #expect(record.playlistItems == items)
            #expect(record.source == .localFile(url))
        }
    }

    @Test(arguments: [
        "https://example.invalid/Media/Movie.mkv",
        "file://media-server.example/Media/Movie.mkv",
        "file://127.0.0.1/Media/Movie.mkv",
        "file://user@localhost/Media/Movie.mkv",
        "file://user:example@localhost/Media/Movie.mkv",
        "file://localhost:1234/Media/Movie.mkv",
        "file://localhost:0/Media/Movie.mkv",
        "file:relative.mkv",
    ])
    func identicalUnsupportedURLsDoNotEstablishFolderMembership(_ spelling: String) throws {
        let url = try #require(URL(string: spelling))
        let raw = try decodedItem(url, marker: 1)
        let items = [raw, item("Movie.mkv", marker: 2)]
        let folder = URL(fileURLWithPath: "/Media", isDirectory: true)

        for source in [MediaSource.localFile(url), .remoteStream(url)] {
            let checkpoint = makeCheckpoint(source: source, folder: folder, items: items, index: 0)
            let record = checkpoint.record()

            #expect(record == historicalRecord(checkpoint, updatedAt: record.updatedAt))
            // Two failed persistence keys must not count as equal identities.
            #expect(record.collectionFolder == nil)
            #expect(record.source == source)
        }
    }

    @Test func localSourceIgnoresUnsupportedCandidateAuthorities() throws {
        let folder = URL(fileURLWithPath: "/Media", isDirectory: true)
        let selected = item("Movie.mkv", marker: 4)
        let unsupported = try [
            "file://media-server.example/Media/Movie.mkv",
            "file://user@localhost/Media/Movie.mkv",
            "https://example.invalid/Media/Movie.mkv",
        ].enumerated().map { offset, spelling in
            try decodedItem(try #require(URL(string: spelling)), marker: offset)
        }

        for includesSelected in [false, true] {
            let items = includesSelected ? unsupported + [selected] : unsupported
            let checkpoint = makeCheckpoint(
                source: .localFile(selected.url), folder: folder, items: items, index: 0
            )
            let record = checkpoint.record()

            #expect(record == historicalRecord(checkpoint, updatedAt: record.updatedAt))
            #expect(record.collectionFolder == (includesSelected ? folder : nil))
        }
    }

    @Test func membershipUsesTheURLWithoutReclassifyingTheStoredSource() {
        let selected = item("Movie.mkv", marker: 1)
        let folder = URL(fileURLWithPath: "/Media", isDirectory: true)
        // A directly constructed source can have an inconsistent enum case.
        // Checkpointing preserves it; load admission validates it elsewhere.
        let source = MediaSource.remoteStream(selected.url)
        let checkpoint = makeCheckpoint(source: source, folder: folder, items: [selected], index: 0)
        let record = checkpoint.record()

        #expect(record == historicalRecord(checkpoint, updatedAt: record.updatedAt))
        #expect(record.collectionFolder == folder)
        #expect(record.source == source)
    }

    @Test(arguments: [false, true])
    func duplicateMetadataAndAllCheckpointFieldsArePreserved(hasFolder: Bool) throws {
        let folder = URL(fileURLWithPath: "/Media", isDirectory: true)
        let canonical = URL(fileURLWithPath: "/Media/Caf\u{e9}.mkv")
        let alias = try #require(URL(string: "file://localhost/Media/Season/../Cafe%CC%81.mkv"))
        let first = try decodedItem(alias, marker: 3)
        let other = item("Other.mkv", marker: 4)
        let duplicate = FolderPlaylistItem(
            url: canonical,
            externalSubtitleURLs: [URL(fileURLWithPath: "/Subtitles/later.srt")],
            dateAdded: .distantFuture
        )
        let items = [first, other, duplicate, other]
        let source = MediaSource.localFile(canonical)

        for position in [42.5, -1, Double.infinity, -Double.infinity, Double.nan] {
            let checkpoint = makeCheckpoint(
                source: source, folder: hasFolder ? folder : nil,
                items: items, index: 2, position: position, wasPaused: false
            )
            let record = checkpoint.record()
            let expected = historicalRecord(checkpoint, updatedAt: record.updatedAt)

            #expect(record == expected)
            #expect(record.schemaVersion == PlaybackSessionRecord.currentSchemaVersion)
            #expect(record.source == source)
            #expect(record.collectionFolder == (hasFolder ? folder : nil))
            #expect(record.playlistItems == [first, other])
            #expect(record.playlistItems[0].externalSubtitleURLs == first.externalSubtitleURLs)
            #expect(record.playlistIndex == 2)
            #expect(record.unshuffledPlaylistIDs == checkpoint.unshuffledPlaylistIDs)
            #expect(record.position == (position == 42.5 ? 42.5 : 0))
            #expect(!record.wasPaused)
            #expect(try JSONDecoder().decode(
                PlaybackSessionRecord.self, from: JSONEncoder().encode(record)
            ) == record)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            #expect(try encoder.encode(record) == encoder.encode(expected))
        }
    }

    @Test func recordCapturesTheCurrentTimestamp() {
        let selected = item("Movie.mkv", marker: 1)
        let checkpoint = makeCheckpoint(
            source: .localFile(selected.url), folder: nil, items: [selected], index: 0
        )
        let before = Date()
        let record = checkpoint.record()
        let after = Date()

        #expect(record.updatedAt >= before)
        #expect(record.updatedAt <= after)
        #expect(record == historicalRecord(checkpoint, updatedAt: record.updatedAt))
    }

    @Test func distinctPathsAndLetterCaseRemainDistinct() {
        let selected = item("Movie.mkv", marker: 1)
        let folder = URL(fileURLWithPath: "/Media", isDirectory: true)

        for path in ["/Elsewhere/Movie.mkv", "/Media/movie.mkv"] {
            let checkpoint = makeCheckpoint(
                source: .localFile(URL(fileURLWithPath: path)), folder: folder,
                items: [selected], index: 0
            )
            let record = checkpoint.record()

            #expect(record == historicalRecord(checkpoint, updatedAt: record.updatedAt))
            #expect(record.collectionFolder == nil)
        }
    }

    private func makeCheckpoint(
        source: MediaSource, folder: URL?, items: [FolderPlaylistItem], index: Int?,
        position: TimeInterval = 42.5, wasPaused: Bool = true
    ) -> PlaybackCheckpoint {
        PlaybackCheckpoint(
            source: source, folder: folder, playlist: items, index: index,
            position: position, wasPaused: wasPaused,
            unshuffledPlaylistIDs: items.reversed().map(\.id)
        )
    }

    private func historicalRecord(_ checkpoint: PlaybackCheckpoint, updatedAt: Date) -> PlaybackSessionRecord {
        let belongsToFolder = checkpoint.source.url.isFileURL && checkpoint.playlist.contains {
            NormalizedFileURL.representsSameFile($0.url, checkpoint.source.url)
        }
        return PlaybackSessionRecord(
            source: checkpoint.source,
            collectionFolder: belongsToFolder ? checkpoint.folder : nil,
            playlistItems: checkpoint.playlist,
            playlistIndex: checkpoint.index,
            position: checkpoint.position,
            wasPaused: checkpoint.wasPaused,
            unshuffledPlaylistIDs: checkpoint.unshuffledPlaylistIDs,
            // The clock is not part of the optimization; compare every record
            // field using the timestamp captured by the production initializer.
            updatedAt: updatedAt
        )
    }

    private func item(_ name: String, marker: Int) -> FolderPlaylistItem {
        FolderPlaylistItem(
            url: URL(fileURLWithPath: "/Media/\(name)"),
            externalSubtitleURLs: [URL(fileURLWithPath: "/Subtitles/\(marker).srt")],
            dateAdded: Date(timeIntervalSince1970: Double(marker))
        )
    }

    private struct RawItemPayload: Encodable {
        let url: URL
        let externalSubtitleURLs: [URL]
        let dateAdded: Date?
    }

    private func decodedItem(_ url: URL, marker: Int) throws -> FolderPlaylistItem {
        let payload = RawItemPayload(
            url: url,
            externalSubtitleURLs: [
                URL(fileURLWithPath: "/Subtitles/\(marker).ja.srt"),
                URL(fileURLWithPath: "/Subtitles/\(marker).en.srt"),
            ],
            dateAdded: Date(timeIntervalSince1970: Double(marker))
        )
        return try JSONDecoder().decode(FolderPlaylistItem.self, from: JSONEncoder().encode(payload))
    }
}
