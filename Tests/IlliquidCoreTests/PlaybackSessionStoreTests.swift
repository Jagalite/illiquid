import Foundation
import Testing
@testable import IlliquidCore

@Suite("Atomic playback session store")
struct PlaybackSessionStoreTests {
    @Test("Illiquid uses its own Application Support session location")
    func illiquidUsesOwnSessionLocation() {
        let store = AtomicPlaybackSessionStore()
        #expect(store.fileURL.lastPathComponent == "PlaybackSession.json")
        #expect(store.fileURL.deletingLastPathComponent().lastPathComponent == "Illiquid")
    }

    @Test func roundTripsVersionedSessionAndClearsIt() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = AtomicPlaybackSessionStore(
            fileURL: directory.appendingPathComponent("session.json")
        )
        let source = MediaSource.localFile(URL(fileURLWithPath: "/Media/movie.mkv"))
        let record = PlaybackSessionRecord(
            source: source,
            collectionFolder: URL(fileURLWithPath: "/Media", isDirectory: true),
            playlistIndex: 3,
            position: 42.5,
            wasPaused: true,
            updatedAt: Date(timeIntervalSince1970: 1_234)
        )

        try store.save(record)
        #expect(try store.load() == record)

        try store.clear()
        #expect(try store.load() == nil)
    }

    @Test func sanitizesInvalidPosition() {
        let record = PlaybackSessionRecord(
            source: .remoteStream(URL(string: "https://example.com/live.m3u8")!),
            position: .infinity,
            wasPaused: false
        )

        #expect(record.position == 0)
    }

    @Test func roundTripsShuffledPlaylistWithSubtitleURLsAndDates() throws {
        let record = Self.richSession()
        try withTemporaryStore { store in
            try store.save(record)
            let saved = try store.load()
            let loaded = try #require(saved)

            #expect(loaded == record)
            #expect(loaded.schemaVersion == PlaybackSessionRecord.currentSchemaVersion)
            // These arrays carry playback order; JSON object-key order does not.
            #expect(loaded.playlistItems.map(\.url) == record.playlistItems.map(\.url))
            #expect(loaded.unshuffledPlaylistIDs == record.unshuffledPlaylistIDs)
            #expect(loaded.playlistItems.map(\.externalSubtitleURLs)
                    == record.playlistItems.map(\.externalSubtitleURLs))
            #expect(loaded.playlistItems.map(\.dateAdded) == record.playlistItems.map(\.dateAdded))
            // Preserve literal URL spelling as well as URL/String equality.
            #expect(loaded.playlistItems.map { Array($0.url.absoluteString.utf8) }
                    == record.playlistItems.map { Array($0.url.absoluteString.utf8) })
        }
    }

    @Test func loadsAndRewritesHistoricalSortedSessionWithoutChangingItsMeaning() throws {
        let record = Self.richSession()
        let historicalEncoder = JSONEncoder()
        historicalEncoder.outputFormatting = [.sortedKeys]
        let historicalData = try historicalEncoder.encode(record)

        try withTemporaryStore { store in
            try FileManager.default.createDirectory(
                at: store.fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try historicalData.write(to: store.fileURL, options: [.atomic])
            let saved = try store.load()
            var loaded = try #require(saved)
            #expect(loaded == record)

            try store.save(loaded)
            #expect(try store.load() == record)
            loaded.position = 321.25
            loaded.playlistIndex = 2
            loaded.wasPaused = false
            try store.save(loaded)
            #expect(try store.load() == loaded)
            #expect(loaded.schemaVersion == record.schemaVersion)
        }
    }

    @Test func encodingFailurePreservesThePreviousSessionFile() throws {
        let record = Self.richSession()
        try withTemporaryStore { store in
            try store.save(record)
            let originalData = try Data(contentsOf: store.fileURL)
            var invalid = record
            invalid.updatedAt = Date(timeIntervalSinceReferenceDate: .infinity)

            #expect(throws: EncodingError.self) {
                try store.save(invalid)
            }
            let survivingData = try Data(contentsOf: store.fileURL)
            #expect(survivingData == originalData)
            #expect(try store.load() == record)
        }
    }

    @Test func decodesVersionOneSessionsWithoutPlaylistItems() throws {
        let data = Data("""
            {
              "schemaVersion": 1,
              "source": {"localFile":{"_0":"file:///Media/legacy.mkv"}},
              "playlistIndex": 0,
              "position": 12,
              "wasPaused": true,
              "updatedAt": -978307200
            }
            """.utf8)

        let record = try JSONDecoder().decode(PlaybackSessionRecord.self, from: data)
        #expect(record.schemaVersion == 1)
        #expect(record.playlistItems.isEmpty)
        #expect(record.position == 12)
        #expect(record.wasPaused)
    }

    private func withTemporaryStore(_ body: (AtomicPlaybackSessionStore) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(AtomicPlaybackSessionStore(fileURL: directory.appendingPathComponent("session.json")))
    }

    private static func richSession() -> PlaybackSessionRecord {
        let folder = URL(fileURLWithPath: "/Media/東京/Series #1%", isDirectory: true)
        let items = [
            FolderPlaylistItem(
                url: folder.appendingPathComponent("Épisode 10 \"雪\".mkv"),
                externalSubtitleURLs: [
                    folder.appendingPathComponent("Épisode 10.ja.srt"),
                    folder.appendingPathComponent("Épisode 10.en.srt"),
                ],
                dateAdded: Date(timeIntervalSinceReferenceDate: 123.5)
            ),
            FolderPlaylistItem(url: folder.appendingPathComponent("E\u{301}pisode 2 #100%.mkv")),
            FolderPlaylistItem(
                url: folder.appendingPathComponent("Episode 1 \\bonus.mkv"),
                externalSubtitleURLs: [folder.appendingPathComponent("Episode 1.字幕.ass")],
                dateAdded: Date(timeIntervalSinceReferenceDate: -456.25)
            ),
        ]
        return PlaybackSessionRecord(
            source: .localFile(items[1].url),
            collectionFolder: folder,
            playlistItems: items,
            playlistIndex: 1,
            position: 123.625,
            wasPaused: true,
            unshuffledPlaylistIDs: [items[2].id, items[1].id, items[0].id],
            updatedAt: Date(timeIntervalSinceReferenceDate: 789.5)
        )
    }
}
