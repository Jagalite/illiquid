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

    @Test(arguments: [false, true])
    func preservesCompleteStateWhenRewritingSortedSession(isRemote: Bool) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("session.json")
        let store = AtomicPlaybackSessionStore(fileURL: fileURL)
        let folder = URL(fileURLWithPath: "/Media/Café 日本語", isDirectory: true)
        let items = [2, 0, 1].map { index in
            FolderPlaylistItem(
                url: folder.appendingPathComponent("Episode \(index) #%.mkv"),
                externalSubtitleURLs: [
                    folder.appendingPathComponent("Episode \(index).日本語.srt"),
                    folder.appendingPathComponent("Episode \(index).en.srt"),
                ],
                dateAdded: index == 0 ? nil : Date(timeIntervalSince1970: Double(index))
            )
        }
        let source: MediaSource = isRemote
            ? .remoteStream(URL(string: "https://example.com/live.m3u8?audio=2&sub=en#start")!)
            : .localFile(items[1].url)
        let record = PlaybackSessionRecord(
            source: source,
            collectionFolder: folder,
            playlistItems: items,
            playlistIndex: 1,
            position: 123.75,
            wasPaused: true,
            unshuffledPlaylistIDs: [items[1].id, items[2].id, items[0].id],
            updatedAt: Date(timeIntervalSince1970: 1_234.5)
        )

        // A previous build wrote sorted keys. Both versions must preserve every
        // value and array order, without requiring the same object-key order.
        let previousEncoder = JSONEncoder()
        previousEncoder.outputFormatting = [.sortedKeys]
        let previousData = try previousEncoder.encode(record)
        try previousData.write(to: fileURL, options: .atomic)
        #expect(try store.load() == record)

        try store.save(record)
        let rewrittenData = try Data(contentsOf: fileURL)
        let previousJSON = try #require(JSONSerialization.jsonObject(with: previousData) as? NSDictionary)
        let rewrittenJSON = try #require(JSONSerialization.jsonObject(with: rewrittenData) as? NSDictionary)
        #expect(previousJSON.isEqual(rewrittenJSON))
        #expect(try store.load() == record)
    }

    @Test func failedEncodingPreservesPreviousCheckpoint() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("session.json")
        let store = AtomicPlaybackSessionStore(fileURL: fileURL)
        let record = PlaybackSessionRecord(
            source: .localFile(URL(fileURLWithPath: "/Media/movie.mkv")),
            position: 42.5,
            wasPaused: true
        )
        try store.save(record)
        let previousData = try Data(contentsOf: fileURL)
        var invalid = record
        invalid.position = .infinity

        #expect(throws: EncodingError.self) { try store.save(invalid) }
        #expect(try Data(contentsOf: fileURL) == previousData)
        #expect(try store.load() == record)
    }
}
