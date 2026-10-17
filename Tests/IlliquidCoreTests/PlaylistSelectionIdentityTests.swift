import Foundation
import Testing
@testable import IlliquidCore

@Suite("Playlist selection identity")
struct PlaylistSelectionIdentityTests {
    private func local(_ name: String) -> URL {
        URL(fileURLWithPath: "/Media/" + name, isDirectory: false)
    }

    private func item(_ name: String) -> FolderPlaylistItem {
        FolderPlaylistItem(url: local(name))
    }

    @Test func firstDuplicateWinsWithoutChangingTheItems() {
        let first = FolderPlaylistItem(
            url: local("Current.mkv"),
            externalSubtitleURLs: [local("first.srt")],
            dateAdded: Date(timeIntervalSince1970: 1)
        )
        let duplicate = FolderPlaylistItem(
            url: local("Season/../Current.mkv"),
            externalSubtitleURLs: [local("second.srt")],
            dateAdded: Date(timeIntervalSince1970: 2)
        )
        let items = [item("Other.mkv"), first, duplicate]
        let index = PlaylistMutation.indexPreservingCurrentIdentity(
            currentURL: local("Current.mkv"), fallbackIndex: 2, in: items
        )
        #expect(index == 1)
        #expect(items == [item("Other.mkv"), first, duplicate])
        #expect(items[1].externalSubtitleURLs == [local("first.srt")])
        #expect(items[2].dateAdded == Date(timeIntervalSince1970: 2))
    }

    @Test func currentIdentityWinsOverTheOldIndexAfterReordering() {
        let a = item("A.mkv"), b = item("B.mkv"), c = item("C.mkv")
        #expect(PlaylistMutation.indexPreservingCurrentIdentity(
            currentURL: b.url, fallbackIndex: 0, in: [a, c, b]
        ) == 2)
        #expect(PlaylistMutation.indexPreservingCurrentIdentity(
            currentURL: b.url, fallbackIndex: 2, in: [c, b, a]
        ) == 1)
    }

    @Test func currentDotUnicodeAndRelativeAliasesSelectTheLocalItem() throws {
        let items = [item("Other.mkv"), item("Caf\u{E9}.mkv")]
        let base = try #require(URL(string: "file://LOCALHOST/Media/Season/"))
        let relative = try #require(URL(string: "../Cafe%CC%81.mkv", relativeTo: base))
        for current in [local("Season/../Cafe\u{301}.mkv"), relative] {
            #expect(PlaylistMutation.indexPreservingCurrentIdentity(
                currentURL: current, fallbackIndex: 0, in: items
            ) == 1)
        }
        #expect(PlaylistMutation.indexPreservingCurrentIdentity(
            currentURL: local("CAF\u{C9}.mkv"), fallbackIndex: 0, in: items
        ) == 0)
    }

    @Test func decodedNoncanonicalItemURLsStillMatchCanonicalCurrentURLs() throws {
        // Synthesized decoding bypasses FolderPlaylistItem's normalizing initializer.
        let data = Data(#"{"url":"file://localhost/Media/Season/../Cafe%CC%81.mkv","externalSubtitleURLs":[]}"#.utf8)
        let decoded = try JSONDecoder().decode(FolderPlaylistItem.self, from: data)
        #expect(decoded.url.absoluteString.contains("/Season/../"))
        #expect(PlaylistMutation.indexPreservingCurrentIdentity(
            currentURL: local("Caf\u{E9}.mkv"), fallbackIndex: 0,
            in: [item("Other.mkv"), decoded]
        ) == 1)
    }

    @Test(arguments: [
        "file://server.example/Media/Current.mkv",
        "file://user@localhost/Media/Current.mkv",
        "file://localhost:42/Media/Current.mkv",
        "https://example.test/Media/Current.mkv",
        "file:relative.mkv",
    ])
    func identicalUnidentifiableURLsDoNotCountAsAMatch(_ input: String) throws {
        let current = try #require(URL(string: input))
        let items = [item("First.mkv"), FolderPlaylistItem(url: current), item("Last.mkv")]
        // Comparing two absent optional keys must not select index 1.
        #expect(PlaylistMutation.indexPreservingCurrentIdentity(
            currentURL: current, fallbackIndex: 2, in: items
        ) == 2)
        #expect(PlaylistMutation.indexPreservingCurrentIdentity(
            currentURL: current, fallbackIndex: nil, in: items
        ) == 0)
    }

    @Test func remoteAuthorityCannotHideALaterLocalMatchWithTheSamePath() throws {
        let remote = try #require(URL(string: "file://server.example/Media/Current.mkv"))
        let items = [FolderPlaylistItem(url: remote), item("Current.mkv")]
        #expect(PlaylistMutation.indexPreservingCurrentIdentity(
            currentURL: local("Current.mkv"), fallbackIndex: 0, in: items
        ) == 1)
    }

    @Test func missingOrAbsentCurrentUsesAnyValidFallback() throws {
        let remote = try #require(URL(string: "https://example.test/first.mkv"))
        let items = [FolderPlaylistItem(url: remote), item("B.mkv"), item("C.mkv")]
        let currents: [URL?] = [nil, local("Missing.mkv")]
        for current in currents {
            for fallback in items.indices {
                #expect(PlaylistMutation.indexPreservingCurrentIdentity(
                    currentURL: current, fallbackIndex: fallback, in: items
                ) == fallback)
            }
        }
    }

    @Test func invalidOrAbsentFallbackDefaultsToTheFirstItem() {
        let items = [item("First.mkv"), item("Second.mkv")]
        let currents: [URL?] = [nil, local("Missing.mkv")]
        let fallbacks: [Int?] = [nil, -1, items.count, Int.min, Int.max]
        for current in currents {
            for fallback in fallbacks {
                #expect(PlaylistMutation.indexPreservingCurrentIdentity(
                    currentURL: current, fallbackIndex: fallback, in: items
                ) == 0)
            }
        }
    }

    @Test func emptyItemsHaveNoSelectionRegardlessOfCurrentOrFallback() throws {
        let remote = try #require(URL(string: "https://example.test/current.mkv"))
        let currents: [URL?] = [nil, local("Current.mkv"), remote]
        let fallbacks: [Int?] = [nil, 0, -1, Int.max]
        for current in currents {
            for fallback in fallbacks {
                #expect(PlaylistMutation.indexPreservingCurrentIdentity(
                    currentURL: current, fallbackIndex: fallback, in: []
                ) == nil)
            }
        }
    }
}
