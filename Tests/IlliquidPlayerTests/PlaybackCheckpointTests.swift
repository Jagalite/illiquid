import Foundation
import IlliquidCore
import Testing
@testable import IlliquidPlayer

@Suite("Playback checkpoint construction")
struct PlaybackCheckpointTests {
    @Test(arguments: [0, 1, 32])
    func flatPlaylistsKeepNoCollectionFolder(count: Int) {
        let items = (0..<count).map { item("Episode \($0)", marker: $0) }
        let sources = [items.last?.url ?? localURL("Absent"), localURL("Missing")]
        for source in sources {
            let checkpoint = makeCheckpoint(source: .localFile(source), folder: nil, items: items)
            expectRecord(checkpoint, collectionFolder: nil)
        }
    }

    @Test(arguments: [0, 1, 2])
    func matchingItemsPreserveTheProvidedFolder(matchIndex: Int) {
        let items = [item("First", marker: 1), item("Middle", marker: 2), item("Last", marker: 3)]
        // The existing contract checks playlist membership, not path containment.
        let folder = URL(fileURLWithPath: "/Different collection", isDirectory: true)
        let checkpoint = makeCheckpoint(
            source: .localFile(items[matchIndex].url), folder: folder, items: items
        )
        expectRecord(checkpoint, collectionFolder: folder)
    }

    @Test func emptyAndMissingMembershipDiscardTheFolder() {
        let folder = URL(fileURLWithPath: "/Media", isDirectory: true)
        let source = MediaSource.localFile(localURL("Absent"))
        for items in [[], [item("Other", marker: 1)],
                      [item("First", marker: 1), item("Last", marker: 2)]] {
            let checkpoint = makeCheckpoint(source: source, folder: folder, items: items)
            expectRecord(checkpoint, collectionFolder: nil)
        }
    }

    @Test(arguments: [nil, Int.min, -1, 0, 1, 2, Int.max] as [Int?])
    func membershipDoesNotTrustTheSavedIndex(index: Int?) {
        let first = item("First", marker: 1)
        let last = item("Last", marker: 2)
        let folder = URL(fileURLWithPath: "/Media", isDirectory: true)
        for source in [last.url, localURL("Absent")] {
            let checkpoint = makeCheckpoint(
                source: .localFile(source), folder: folder, items: [first, last], index: index
            )
            expectRecord(checkpoint, collectionFolder: source == last.url ? folder : nil)
        }
    }

    @Test func localAliasesAndDecodedItemsRetainMembership() throws {
        let folder = URL(fileURLWithPath: "/Media", isDirectory: true)
        let canonical = item("Caf\u{00E9}", marker: 1)
        let base = try #require(URL(string: "file:///Media/"))
        let aliases = try [
            "file:///Media/Caf%C3%A9.mkv",
            "file:///Media/Season/../Cafe%CC%81.mkv",
            "file://localhost/Media/Caf%C3%A9.mkv",
            "file://LOCALHOST/Media/Cafe%CC%81.mkv",
        ].map { try #require(URL(string: $0)) } + [
            try #require(URL(string: "Season/../Cafe%CC%81.mkv", relativeTo: base)),
        ]
        for alias in aliases {
            let checkpoint = makeCheckpoint(
                source: .localFile(alias), folder: folder,
                items: [item("Other", marker: 0), canonical]
            )
            expectRecord(checkpoint, collectionFolder: folder)
        }

        let raw = try decodedItem(
            "file://LOCALHOST/Media/Season/../Cafe%CC%81.mkv?restore=1#chapter", marker: 2
        )
        #expect(raw.url.absoluteString.contains("/Season/../"))
        let checkpoint = makeCheckpoint(
            source: .localFile(canonical.url), folder: folder,
            items: [item("Other", marker: 0), raw]
        )
        expectRecord(checkpoint, collectionFolder: folder)
    }

    @Test(arguments: [
        "https://example.invalid/Media/Target.mkv",
        "file://archive.invalid/Media/Target.mkv",
        "file://127.0.0.1/Media/Target.mkv",
        "file://user@localhost/Media/Target.mkv",
        "file://user:example@localhost/Media/Target.mkv",
        "file://localhost:1234/Media/Target.mkv",
        "file:relative.mkv",
    ])
    func identicalUnsupportedURLsDoNotEstablishMembership(spelling: String) throws {
        let invalid = try decodedItem(spelling, marker: 1)
        let local = item("Target", marker: 2)
        let folder = URL(fileURLWithPath: "/Media", isDirectory: true)
        for items in [[invalid], [invalid, local]] {
            let checkpoint = makeCheckpoint(
                source: .localFile(invalid.url), folder: folder, items: items
            )
            // In particular, two failed normalizations must never compare equal.
            expectRecord(checkpoint, collectionFolder: nil)
        }

        let validSource = makeCheckpoint(
            source: .localFile(local.url), folder: folder, items: [invalid, local]
        )
        expectRecord(validSource, collectionFolder: folder)
        let onlyInvalidItems = makeCheckpoint(
            source: .localFile(local.url), folder: folder, items: [invalid]
        )
        expectRecord(onlyInvalidItems, collectionFolder: nil)
    }

    @Test func sourceURLAndOpaqueFolderKeepTheirExistingSemantics() throws {
        let target = item("Target", marker: 1)
        let remoteURL = try #require(URL(string: "https://example.invalid/Media/Target.mkv"))
        let opaqueFolder = try #require(URL(string: "https://example.invalid/opaque-folder"))
        let remoteItem = try decodedItem(remoteURL.absoluteString, marker: 2)
        let remote = makeCheckpoint(
            source: .remoteStream(remoteURL), folder: opaqueFolder, items: [remoteItem, target]
        )
        expectRecord(remote, collectionFolder: nil)

        // Public enum cases can be paired with arbitrary URLs. record() has
        // historically used the URL's scheme, leaving source validation elsewhere.
        let malformedRemote = makeCheckpoint(
            source: .remoteStream(target.url), folder: opaqueFolder, items: [target]
        )
        expectRecord(malformedRemote, collectionFolder: opaqueFolder)
    }

    @Test func pathCaseRemainsSignificant() {
        let folder = URL(fileURLWithPath: "/Media", isDirectory: true)
        let checkpoint = makeCheckpoint(
            source: .localFile(localURL("target")), folder: folder,
            items: [item("Target", marker: 1)]
        )
        expectRecord(checkpoint, collectionFolder: nil)
    }

    @Test(arguments: [false, true])
    func duplicateAliasesKeepTheFirstCompleteItemAndSavedFields(hasFolder: Bool) throws {
        let first = try decodedItem("file:///Media/Season/../Cafe%CC%81.mkv", marker: 1)
        let duplicate = item("Caf\u{00E9}", marker: 2)
        let other = item("Other", marker: 3)
        let folder = hasFolder ? URL(fileURLWithPath: "/Media", isDirectory: true) : nil
        let checkpoint = makeCheckpoint(
            source: .localFile(duplicate.url), folder: folder,
            items: [first, other, duplicate, first], index: 3
        )
        expectRecord(checkpoint, collectionFolder: folder, items: [first, other])
    }

    @Test(arguments: [-1.0, Double.nan, Double.infinity, -Double.infinity])
    func invalidPositionStillNormalizesDuringRecordConstruction(position: TimeInterval) {
        let target = item("Target", marker: 1)
        let checkpoint = PlaybackCheckpoint(
            source: .localFile(target.url), folder: nil, playlist: [target], index: 0,
            position: position, wasPaused: false, unshuffledPlaylistIDs: nil
        )
        expectRecord(checkpoint, collectionFolder: nil, position: 0)
    }

    private func makeCheckpoint(
        source: MediaSource,
        folder: URL?,
        items: [FolderPlaylistItem],
        index: Int? = nil
    ) -> PlaybackCheckpoint {
        PlaybackCheckpoint(
            source: source, folder: folder, playlist: items, index: index,
            position: 12.5, wasPaused: true,
            unshuffledPlaylistIDs: ["saved second identity", "saved first identity", "saved second identity"]
        )
    }

    private func expectRecord(
        _ checkpoint: PlaybackCheckpoint,
        collectionFolder: URL?,
        items: [FolderPlaylistItem]? = nil,
        position: TimeInterval? = nil
    ) {
        let expectedItems = items ?? checkpoint.playlist
        let expectedPosition = position ?? checkpoint.position
        let timestamp = Date(timeIntervalSince1970: 123)
        var actual = checkpoint.record()
        // Date() is the only nondeterministic field; compare every other field.
        actual.updatedAt = timestamp
        let expected = PlaybackSessionRecord(
            source: checkpoint.source, collectionFolder: collectionFolder,
            playlistItems: expectedItems, playlistIndex: checkpoint.index,
            position: expectedPosition, wasPaused: checkpoint.wasPaused,
            unshuffledPlaylistIDs: checkpoint.unshuffledPlaylistIDs, updatedAt: timestamp
        )
        #expect(actual == expected)
        #expect(actual.playlistItems == expectedItems)
        #expect(actual.position == expectedPosition)
    }

    private func item(_ stem: String, marker: Int) -> FolderPlaylistItem {
        FolderPlaylistItem(
            url: localURL(stem),
            externalSubtitleURLs: [URL(fileURLWithPath: "/Subtitles/\(marker).srt")],
            dateAdded: Date(timeIntervalSince1970: Double(marker))
        )
    }

    private func localURL(_ stem: String) -> URL {
        URL(fileURLWithPath: "/Media/\(stem).mkv")
    }

    private func decodedItem(_ spelling: String, marker: Int) throws -> FolderPlaylistItem {
        let url = try #require(URL(string: spelling))
        let data = try JSONSerialization.data(withJSONObject: [
            "url": url.absoluteString,
            "externalSubtitleURLs": ["file:///Subtitles/\(marker).srt"],
            "dateAdded": Double(marker),
        ])
        return try JSONDecoder().decode(FolderPlaylistItem.self, from: data)
    }
}
