import Foundation
import Testing
import IlliquidCore

@Suite("Folder playlist identity lookup")
struct FolderPlaylistLookupTests {
    @Test func emptyAndSingletonPlaylistsKeepLookupAndRestorePolicy() throws {
        let local = URL(fileURLWithPath: "/Media/Episode 2.mkv")
        let missing = URL(fileURLWithPath: "/Media/Missing.mkv")
        let remote = try #require(URL(string: "https://example.invalid/Media/Episode%202.mkv"))
        let empty = playlist([])
        #expect(empty.initialIndex(restoring: nil) == nil)
        for query in [local, missing, remote] {
            #expect(empty.index(of: query) == nil)
            #expect(empty.initialIndex(restoring: query) == nil)
        }

        let singleton = playlist([FolderPlaylistItem(url: local)])
        #expect(singleton.index(of: local) == 0)
        #expect(singleton.index(of: missing) == nil)
        #expect(singleton.index(of: remote) == nil)
        #expect(singleton.initialIndex(restoring: local) == 0)
        #expect(singleton.initialIndex(restoring: missing) == 0)
        #expect(singleton.initialIndex(restoring: remote) == 0)
        #expect(singleton.initialIndex(restoring: nil) == 0)
    }

    @Test func duplicateIdentitiesReturnTheFirstCompleteItemInPlaylistOrder() throws {
        let direct = URL(fileURLWithPath: "/Media/Caf\u{00E9} 2.mkv")
        let alias = try #require(URL(string: "file://LOCALHOST/Media/Season/../Cafe%CC%81%202.mkv"))
        let first = FolderPlaylistItem(
            url: alias,
            externalSubtitleURLs: [URL(fileURLWithPath: "/Media/first.srt")],
            dateAdded: Date(timeIntervalSince1970: 100)
        )
        let second = FolderPlaylistItem(
            url: direct,
            externalSubtitleURLs: [URL(fileURLWithPath: "/Media/second.srt")],
            dateAdded: Date(timeIntervalSince1970: 200)
        )
        let value = playlist([
            FolderPlaylistItem(url: URL(fileURLWithPath: "/Media/Z.mkv")),
            first,
            second,
        ])
        let index = try #require(value.index(of: alias))
        #expect(index == originalIndex(in: value, of: direct))
        #expect(value.items[index] == first)
        #expect(value.items.filter { $0.id == first.id }.count == 2)
    }

    @Test func decodedRawItemsAreNormalizedDuringLookup() throws {
        let raw = try #require(URL(string:
            "file://LOCALHOST/Media/Season/../Cafe%CC%81%202.mkv?edition=raw#chapter"))
        let item = try decodedItem(url: raw, revision: 7)
        // Synthesized Decodable assigns the stored fields directly; the public
        // initializer's normalization is deliberately bypassed by this fixture.
        #expect(item.url.absoluteString == raw.absoluteString)
        #expect(item.url.absoluteString != FolderPlaylistItem(url: raw).url.absoluteString)
        let value = playlist([item])
        let query = URL(fileURLWithPath: "/Media/Caf\u{00E9} 2.mkv")
        #expect(value.index(of: query) == 0)
        #expect(value.initialIndex(restoring: query) == 0)
        #expect(value.items[0] == item)
    }

    @Test(arguments: [
        "https://example.invalid/Media/Episode%202.mkv",
        "ftp://example.invalid/Media/Episode%202.mkv",
        "file://media-server.example/Media/Episode%202.mkv",
        "file://localhost.example/Media/Episode%202.mkv",
        "file://127.0.0.1/Media/Episode%202.mkv",
        "file://[::1]/Media/Episode%202.mkv",
        "file://user@localhost/Media/Episode%202.mkv",
        "file://user:password@localhost/Media/Episode%202.mkv",
        "file://localhost:1234/Media/Episode%202.mkv",
        "file:relative.mkv", "file:", "file://", "file://localhost",
    ])
    func unsupportedURLsNeverMatchEvenAnIdenticalStoredURL(_ input: String) throws {
        let url = try #require(URL(string: input))
        #expect(NormalizedFileURL.persistenceKey(for: url) == nil)
        let value = playlist([try decodedItem(url: url)])
        // Two missing persistence keys must not become an equality match, and
        // FolderPlaylistItem.id's absoluteString fallback is not file identity.
        #expect(value.index(of: url) == nil)
        #expect(value.index(of: URL(fileURLWithPath: "/Media/Episode 2.mkv")) == nil)
        #expect(value.initialIndex(restoring: url) == 0)
    }

    @Test func relativeQueriesValidateTheirAbsoluteBase() throws {
        let direct = URL(fileURLWithPath: "/Media/Episode 2.mkv")
        let localBase = URL(fileURLWithPath: "/Media/Season", isDirectory: true)
        let remoteBase = try #require(URL(string: "file://archive.example/Media/Season/"))
        let local = try #require(URL(string: "../Episode%202.mkv", relativeTo: localBase))
        let remote = try #require(URL(string: "../Episode%202.mkv", relativeTo: remoteBase))
        let value = playlist([FolderPlaylistItem(url: direct)])
        #expect(value.index(of: local) == 0)
        #expect(value.index(of: remote) == nil)
        #expect(value.index(of: local) == originalIndex(in: value, of: local))
        #expect(value.index(of: remote) == originalIndex(in: value, of: remote))
    }

    @Test func mixedStoredRepresentationsMatchTheOriginalIdentityPredicate() throws {
        let localBase = URL(fileURLWithPath: "/Media", isDirectory: true)
        let remoteBase = try #require(URL(string: "file://archive.example/Media/"))
        var urls = [
            URL(fileURLWithPath: "/Media/Episode 1.mkv"),
            URL(fileURLWithPath: "/Media/Episode 2.mkv"),
            URL(fileURLWithPath: "/Media/episode 2.mkv"),
            URL(fileURLWithPath: "/Media/Episode 10.mkv"),
            URL(fileURLWithPath: "/Media/Caf\u{00E9} 2.mkv"),
            URL(fileURLWithPath: "/Media/Cafe\u{0301} 2.mkv"),
            URL(fileURLWithPath: "/Media/\u{4E16}\u{754C} \u{1F3AC} 2.mkv"),
            URL(fileURLWithPath: "/Media/Episode 2.mkv", isDirectory: true),
            URL(fileURLWithPath: "/Media/Notes.txt"),
            URL(fileURLWithPath: "/Outside/Feature.mkv"),
            URL(fileURLWithPath: "/", isDirectory: true),
        ]
        for input in [
            "file://localhost/Media/Episode%202.mkv",
            "file://LOCALHOST/Media/Episode%202.mkv",
            "file:///Media/Season/../Episode%202.mkv",
            "file:///Media/Cafe%CC%81%202.mkv",
            "file:///Media/Episode%202.mkv?copy=1#chapter",
            "file:///Media/100%25%20complete.mkv",
            "file:///Media/A%23B%3F.mkv",
            "file://archive.example/Media/Episode%202.mkv",
            "file://user@localhost/Media/Episode%202.mkv",
            "file://localhost:1234/Media/Episode%202.mkv",
            "https://example.invalid/Media/Episode%202.mkv",
            "file:relative.mkv",
        ] {
            urls.append(try #require(URL(string: input)))
        }
        urls.append(try #require(URL(string: "Episode%202.mkv", relativeTo: localBase)))
        urls.append(try #require(URL(string: "Episode%202.mkv", relativeTo: remoteBase)))

        let rawItems = try urls.enumerated().map { try decodedItem(url: $0.element, revision: $0.offset) }
        let initializedItems = urls.enumerated().map {
            FolderPlaylistItem(url: $0.element, dateAdded: Date(timeIntervalSince1970: Double($0.offset)))
        }
        let queries = urls + [URL(fileURLWithPath: "/Media/Missing.mkv")]
        // Include both stored raw payloads and values passed through init. Vary
        // source order to exercise first-match behavior among duplicate aliases.
        for items in [rawItems, initializedItems, rawItems + initializedItems] {
            for offset in [0, 1, items.count / 2] {
                let rotated = Array(items.dropFirst(offset)) + Array(items.prefix(offset))
                let value = playlist(rotated)
                for query in queries {
                    let expected = originalIndex(in: value, of: query)
                    #expect(value.index(of: query) == expected)
                    #expect(value.initialIndex(restoring: query) == (expected ?? value.items.startIndex))
                }
            }
        }
    }

    private func playlist(_ items: [FolderPlaylistItem]) -> FolderPlaylist {
        FolderPlaylist(folderURL: URL(fileURLWithPath: "/Media", isDirectory: true), items: items)
    }

    private func originalIndex(in playlist: FolderPlaylist, of query: URL) -> Int? {
        playlist.items.firstIndex { NormalizedFileURL.representsSameFile($0.url, query) }
    }

    private func decodedItem(url: URL, revision: Int = 0) throws -> FolderPlaylistItem {
        struct StoredItem: Encodable {
            let url: URL
            let externalSubtitleURLs: [URL]
            let dateAdded: Date
        }
        let stored = StoredItem(
            url: url,
            externalSubtitleURLs: [URL(fileURLWithPath: "/Media/subtitle-\(revision).srt")],
            dateAdded: Date(timeIntervalSince1970: Double(revision))
        )
        return try JSONDecoder().decode(FolderPlaylistItem.self, from: JSONEncoder().encode(stored))
    }
}
