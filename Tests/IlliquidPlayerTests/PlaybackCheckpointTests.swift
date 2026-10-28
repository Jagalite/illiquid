import Foundation
import XCTest
import IlliquidCore
@testable import IlliquidPlayer

final class PlaybackCheckpointTests: XCTestCase {
    private let folder = URL(fileURLWithPath: "/CheckpointTests", isDirectory: true)

    private struct RawItem: Encodable {
        let url: URL
        let externalSubtitleURLs: [URL]
        let dateAdded: Date?
    }

    private func rawItem(_ url: URL, marker: Int = 0) throws -> FolderPlaylistItem {
        let raw = RawItem(
            url: url,
            externalSubtitleURLs: [URL(fileURLWithPath: "/Subtitles/\(marker).srt")],
            dateAdded: Date(timeIntervalSince1970: Double(marker))
        )
        return try JSONDecoder().decode(FolderPlaylistItem.self, from: JSONEncoder().encode(raw))
    }

    private func checkpoint(
        source: MediaSource, items: [FolderPlaylistItem], index: Int?,
        folder: URL?, position: Double = 42.5
    ) -> PlaybackCheckpoint {
        PlaybackCheckpoint(
            source: source, folder: folder, playlist: items, index: index,
            position: position, wasPaused: true, unshuffledPlaylistIDs: ["saved-b", "saved-a"]
        )
    }

    private func assertRecord(
        _ input: PlaybackCheckpoint, folder expectedFolder: URL?,
        items expectedItems: [FolderPlaylistItem],
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let before = Date()
        var actual = input.record()
        let after = Date()
        XCTAssertGreaterThanOrEqual(actual.updatedAt, before, file: file, line: line)
        XCTAssertLessThanOrEqual(actual.updatedAt, after, file: file, line: line)
        let expected = PlaybackSessionRecord(
            source: input.source, collectionFolder: expectedFolder,
            playlistItems: expectedItems, playlistIndex: input.index,
            position: input.position, wasPaused: input.wasPaused,
            unshuffledPlaylistIDs: input.unshuffledPlaylistIDs,
            updatedAt: Date(timeIntervalSince1970: 1234)
        )
        actual.updatedAt = expected.updatedAt
        XCTAssertEqual(actual, expected, file: file, line: line)
        let encoded = try JSONEncoder().encode(actual)
        XCTAssertEqual(try JSONDecoder().decode(PlaybackSessionRecord.self, from: encoded),
                       expected, file: file, line: line)
    }

    func testIndependentIdentityMatrixWithEveryHint() throws {
        let identities: [(String?, URL)] = [
            ("a", URL(string: "file:///Media/a.mkv")!),
            ("a", URL(string: "file:///Media/./a.mkv")!),
            ("a", URL(string: "file:///Media/sub/../a.mkv")!),
            ("a", URL(string: "file://localhost/Media/a.mkv")!),
            ("unicode", URL(fileURLWithPath: "/Media/caf\u{00E9}.mkv")),
            ("unicode", URL(fileURLWithPath: "/Media/cafe\u{0301}.mkv")),
            ("case", URL(string: "file:///Media/A.mkv")!),
            ("prefix", URL(string: "file:///Media/a.mkv.backup")!),
            (nil, URL(string: "https://example.invalid/a.mkv")!),
            (nil, URL(string: "file://remote.invalid/Media/a.mkv")!),
            (nil, URL(string: "file://user@localhost/Media/a.mkv")!),
        ]
        let hints: [Int?] = [nil, 0, 1, -1, Int.min, Int.max]
        for (queryIdentity, queryURL) in identities {
            for (itemIdentity, itemURL) in identities {
                let item = try rawItem(itemURL)
                let expectedFolder = queryIdentity != nil && queryIdentity == itemIdentity ? folder : nil
                for hint in hints {
                    try assertRecord(
                        checkpoint(source: .localFile(queryURL), items: [item], index: hint, folder: folder),
                        folder: expectedFolder, items: [item]
                    )
                }
            }
        }
    }

    func testStaleAndInvalidHintsPreserveMembershipMetadataAndRawIndex() throws {
        let first = try rawItem(URL(fileURLWithPath: "/Media/a.mkv"), marker: 1)
        let second = try rawItem(URL(fileURLWithPath: "/Media/b.mkv"), marker: 2)
        let duplicate = try rawItem(URL(string: "file:///Media/./a.mkv")!, marker: 99)
        let playlist = [first, second, duplicate]
        let hints: [Int?] = [nil, 0, 1, 2, 3, -1, Int.min, Int.max]
        for hint in hints {
            for source in [first.url, second.url] {
                try assertRecord(
                    checkpoint(source: .localFile(source), items: playlist, index: hint, folder: folder),
                    folder: folder, items: [first, second]
                )
            }
            try assertRecord(
                checkpoint(source: .localFile(URL(fileURLWithPath: "/Media/missing.mkv")),
                           items: playlist, index: hint, folder: folder),
                folder: nil, items: [first, second]
            )
        }
    }

    func testAbsentFolderAndEmptyPlaylist() throws {
        let item = try rawItem(URL(fileURLWithPath: "/Media/a.mkv"))
        try assertRecord(
            checkpoint(source: .localFile(item.url), items: [item], index: 0, folder: nil),
            folder: nil, items: [item]
        )
        try assertRecord(
            checkpoint(source: .localFile(item.url), items: [], index: Int.max, folder: folder),
            folder: nil, items: []
        )
    }

    func testSourceKindDoesNotReplaceExistingURLIdentityContract() throws {
        let item = try rawItem(URL(fileURLWithPath: "/Media/a.mkv"))
        try assertRecord(
            checkpoint(source: .remoteStream(item.url), items: [item], index: 0, folder: folder),
            folder: folder, items: [item]
        )
        let remote = URL(string: "https://example.invalid/a.mkv")!
        let remoteItem = try rawItem(remote)
        for source in [MediaSource.localFile(remote), .remoteStream(remote)] {
            try assertRecord(checkpoint(source: source, items: [remoteItem], index: 0, folder: folder),
                             folder: nil, items: [remoteItem])
        }
    }

    func testInvalidPositionsStillUseRecordSanitization() throws {
        let item = try rawItem(URL(fileURLWithPath: "/Media/a.mkv"))
        for position in [-1, Double.infinity, -Double.infinity, Double.nan, 0, 42.5] {
            let input = checkpoint(source: .localFile(item.url), items: [item],
                                   index: 0, folder: folder, position: position)
            XCTAssertEqual(input.record().position, position.isFinite ? max(0, position) : 0)
            try assertRecord(input, folder: folder, items: [item])
        }
    }

    func testSaveAndClearMutationsUseTheCompleteRecord() throws {
        final class Store: PlaybackSessionStoring, @unchecked Sendable {
            var record: PlaybackSessionRecord?
            func load() throws -> PlaybackSessionRecord? { record }
            func save(_ session: PlaybackSessionRecord) throws { record = session }
            func clear() throws { record = nil }
        }
        let store = Store()
        let item = try rawItem(URL(fileURLWithPath: "/Media/a.mkv"), marker: 7)
        let input = checkpoint(source: .localFile(item.url), items: [item], index: 0, folder: folder)
        try PlaybackCheckpointMutation.save(input).apply(to: store)
        let saved = try XCTUnwrap(store.record)
        XCTAssertEqual(saved.collectionFolder, folder)
        XCTAssertEqual(saved.playlistItems, [item])
        XCTAssertEqual(saved.unshuffledPlaylistIDs, input.unshuffledPlaylistIDs)
        XCTAssertEqual(saved.position, input.position)
        try PlaybackCheckpointMutation.clear.apply(to: store)
        XCTAssertNil(try store.load())
    }
}
