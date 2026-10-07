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
}
