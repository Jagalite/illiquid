import Foundation
import Testing
@testable import IlliquidCore

@Suite("Playlist identity lookup")
struct PlaylistIdentityLookupTests {
    @Test func localAliasesSelectTheSameItem() throws {
        let canonical = URL(fileURLWithPath: "/Media/Café.mkv")
        let base = try #require(URL(string: "file:///Media/"))
        let aliases = try [
            "file:///Media/Caf%C3%A9.mkv",
            "file:///Media/Season/../Cafe%CC%81.mkv",
            "file://localhost/Media/Caf%C3%A9.mkv",
            "file://LOCALHOST/Media/Cafe%CC%81.mkv",
        ].map { try #require(URL(string: $0)) } + [
            try #require(URL(string: "Season/../Cafe%CC%81.mkv", relativeTo: base)),
        ]
        let selected = item(canonical, marker: 1)
        let items = [item(URL(fileURLWithPath: "/Media/Other.mkv"), marker: 0), selected]
        let folder = FolderPlaylist(folderURL: base, items: [selected])

        for alias in aliases {
            #expect(PlaylistMutation.indexPreservingCurrentIdentity(
                currentURL: alias, fallbackIndex: 0, in: items
            ) == 1)
            #expect(folder.index(of: alias) == 0)
            #expect(folder.initialIndex(restoring: alias) == 0)
        }
    }

    @Test func firstDuplicateWinsWithoutReplacingItsMetadata() {
        let target = URL(fileURLWithPath: "/Media/A.mkv")
        let first = FolderPlaylistItem(
            url: target,
            externalSubtitleURLs: [URL(fileURLWithPath: "/Media/first.srt")],
            dateAdded: Date(timeIntervalSince1970: 1)
        )
        let duplicate = FolderPlaylistItem(
            url: URL(fileURLWithPath: "/Media/Season/../A.mkv"),
            externalSubtitleURLs: [URL(fileURLWithPath: "/Media/second.srt")],
            dateAdded: Date(timeIntervalSince1970: 2)
        )
        let items = [item(URL(fileURLWithPath: "/Media/B.mkv"), marker: 3), first, duplicate]
        #expect(PlaylistMutation.indexPreservingCurrentIdentity(
            currentURL: target, fallbackIndex: 2, in: items
        ) == 1)

        let folder = FolderPlaylist(folderURL: URL(fileURLWithPath: "/Media"), items: items)
        #expect(folder.index(of: target) == 0)
        #expect(folder.items[0] == first)
        #expect(folder.items[1] == duplicate)
    }

    @Test func decodedRawItemsAreNormalizedDuringLookup() throws {
        // Synthesized Decodable does not call FolderPlaylistItem's public init.
        let raw = try #require(URL(string: "file://LOCALHOST/Media/Season/../Cafe%CC%81.mkv"))
        let decoded = try decodedItem(raw, marker: 1)
        #expect(decoded.url.absoluteString == raw.absoluteString)
        #expect(decoded.url.absoluteString.contains("/Season/../"))
        let current = URL(fileURLWithPath: "/Media/Café.mkv")
        let items = [item(URL(fileURLWithPath: "/Media/Other.mkv"), marker: 0), decoded]
        #expect(PlaylistMutation.indexPreservingCurrentIdentity(
            currentURL: current, fallbackIndex: 0, in: items
        ) == 1)
        let folder = FolderPlaylist(folderURL: URL(fileURLWithPath: "/Media"), items: [decoded])
        #expect(folder.index(of: current) == 0)
        #expect(folder.index(of: raw) == 0)
    }

    @Test func matchesOverrideFallbackAndMissingTargetsRespectItsBounds() {
        let items = ["A", "B", "C"].enumerated().map {
            item(URL(fileURLWithPath: "/Media/\($0.element).mkv"), marker: $0.offset)
        }
        let missing = URL(fileURLWithPath: "/Media/Missing.mkv")
        let cases: [(fallback: Int?, expected: Int)] = [
            (nil, 0), (Int.min, 0), (-1, 0), (0, 0), (1, 1), (2, 2),
            (3, 0), (100, 0), (Int.max, 0),
        ]
        for testCase in cases {
            for current in [nil, missing] as [URL?] {
                #expect(PlaylistMutation.indexPreservingCurrentIdentity(
                    currentURL: current, fallbackIndex: testCase.fallback, in: items
                ) == testCase.expected)
            }
            #expect(PlaylistMutation.indexPreservingCurrentIdentity(
                currentURL: items[1].url, fallbackIndex: testCase.fallback, in: items
            ) == 1)
        }
        let folder = FolderPlaylist(folderURL: URL(fileURLWithPath: "/Media"), items: items)
        #expect(folder.index(of: missing) == nil)
        #expect(folder.initialIndex(restoring: missing) == 0)
        #expect(folder.initialIndex(restoring: nil) == 0)
    }

    @Test func emptyPlaylistsHaveNoSelection() throws {
        let targets: [URL?] = [
            nil,
            URL(fileURLWithPath: "/Media/A.mkv"),
            try #require(URL(string: "https://example.invalid/Media/A.mkv")),
            try #require(URL(string: "file://media-server.example/Media/A.mkv")),
        ]
        let folder = FolderPlaylist(folderURL: URL(fileURLWithPath: "/Media"), items: [])
        for target in targets {
            for fallback in [nil, Int.min, -1, 0, 1, Int.max] as [Int?] {
                #expect(PlaylistMutation.indexPreservingCurrentIdentity(
                    currentURL: target, fallbackIndex: fallback, in: []
                ) == nil)
            }
            if let target { #expect(folder.index(of: target) == nil) }
            #expect(folder.initialIndex(restoring: target) == nil)
        }
    }

    @Test(arguments: [
        "https://example.invalid/Media/A.mkv",
        "file://media-server.example/Media/A.mkv",
        "file://127.0.0.1/Media/A.mkv",
        "file://user@localhost/Media/A.mkv",
        "file://user:example@localhost/Media/A.mkv",
        "file://localhost:1234/Media/A.mkv",
        "file://localhost:0/Media/A.mkv",
        "file:relative.mkv",
    ])
    func identicalUnsupportedURLsDoNotBecomeMatches(_ spelling: String) throws {
        let unsupported = try #require(URL(string: spelling))
        let local = URL(fileURLWithPath: "/Media/A.mkv")
        let items = [
            item(unsupported, marker: 0),
            item(local, marker: 1),
            item(URL(fileURLWithPath: "/Media/B.mkv"), marker: 2),
        ]
        // A nil target key must not equal another nil key, even for identical URLs.
        #expect(PlaylistMutation.indexPreservingCurrentIdentity(
            currentURL: unsupported, fallbackIndex: 2, in: items
        ) == 2)
        #expect(PlaylistMutation.indexPreservingCurrentIdentity(
            currentURL: local, fallbackIndex: 2, in: items
        ) == 1)
        let folder = FolderPlaylist(folderURL: URL(fileURLWithPath: "/Media"), items: items)
        #expect(folder.index(of: unsupported) == nil)
        #expect(folder.initialIndex(restoring: unsupported) == 0)
    }

    @Test func supportedTargetDoesNotMatchAnAllUnsupportedPlaylist() throws {
        let unsupported = try [
            "https://example.invalid/Media/A.mkv",
            "file://media-server.example/Media/A.mkv",
            "file://user@localhost/Media/A.mkv",
        ].enumerated().map {
            item(try #require(URL(string: $0.element)), marker: $0.offset)
        }
        let current = URL(fileURLWithPath: "/Media/A.mkv")
        #expect(PlaylistMutation.indexPreservingCurrentIdentity(
            currentURL: current, fallbackIndex: 2, in: unsupported
        ) == 2)
        #expect(PlaylistMutation.indexPreservingCurrentIdentity(
            currentURL: current, fallbackIndex: nil, in: unsupported
        ) == 0)
        let folder = FolderPlaylist(folderURL: URL(fileURLWithPath: "/Media"), items: unsupported)
        #expect(folder.index(of: current) == nil)
        #expect(folder.initialIndex(restoring: current) == 0)
    }

    @Test func distinctPathsRemainDistinct() {
        let target = URL(fileURLWithPath: "/Media/A.mkv")
        let items = [item(target, marker: 0), item(URL(fileURLWithPath: "/Media/B.mkv"), marker: 1)]
        let folder = FolderPlaylist(folderURL: URL(fileURLWithPath: "/Media"), items: items)
        for other in ["/Elsewhere/A.mkv", "/Media/a.mkv"] {
            let current = URL(fileURLWithPath: other)
            #expect(PlaylistMutation.indexPreservingCurrentIdentity(
                currentURL: current, fallbackIndex: 1, in: items
            ) == 1)
            #expect(folder.index(of: current) == nil)
        }
    }

    @Test func allSmallQueuesMatchIndependentIdentityLabels() throws {
        let a = URL(fileURLWithPath: "/Media/A.mkv")
        let alias = try #require(URL(string: "file://localhost/Media/Season/../A.mkv"))
        let b = URL(fileURLWithPath: "/Media/B.mkv")
        let invalid = try #require(URL(string: "https://example.invalid/Media/A.mkv"))
        // Labels specify the expected identity independently of URL normalization.
        // Dates are fixture markers, allowing us to recover labels after folder sorting.
        let fixtures: [(item: FolderPlaylistItem, identity: Int?)] = [
            (item(a, marker: 0), 0),
            (try decodedItem(alias, marker: 1), 0),
            (item(b, marker: 2), 1),
            (item(invalid, marker: 3), nil),
        ]
        let targets: [(url: URL?, identity: Int?)] = [
            (nil, nil), (a, 0), (alias, 0), (b, 1),
            (URL(fileURLWithPath: "/Media/Missing.mkv"), 2), (invalid, nil),
        ]
        var queues: [[Int]] = [[]]
        var layer: [[Int]] = [[]]
        for _ in 0..<3 {
            layer = layer.flatMap { prefix in fixtures.indices.map { prefix + [$0] } }
            queues.append(contentsOf: layer)
        }
        var selectionChecks = 0
        var folderChecks = 0
        var restorationChecks = 0
        for queue in queues {
            let items = queue.map { fixtures[$0].item }
            let identities = queue.map { fixtures[$0].identity }
            let folder = FolderPlaylist(folderURL: URL(fileURLWithPath: "/Media"), items: items)
            let folderIdentities = try folder.items.map { item in
                let marker = try #require(item.dateAdded).timeIntervalSince1970
                return fixtures[Int(marker)].identity
            }
            let fallbacks: [Int?] = [nil, Int.min, -1, 0, 1, items.count, Int.max]
            for target in targets {
                let match = expectedMatch(target.identity, in: identities)
                for fallback in fallbacks {
                    let expected: Int?
                    if let match {
                        expected = match
                    } else if let fallback, fallback >= 0, fallback < items.count {
                        expected = fallback
                    } else {
                        expected = items.isEmpty ? nil : 0
                    }
                    #expect(PlaylistMutation.indexPreservingCurrentIdentity(
                        currentURL: target.url, fallbackIndex: fallback, in: items
                    ) == expected)
                    selectionChecks += 1
                }
                let folderMatch = expectedMatch(target.identity, in: folderIdentities)
                if let targetURL = target.url {
                    #expect(folder.index(of: targetURL) == folderMatch)
                    folderChecks += 1
                }
                #expect(folder.initialIndex(restoring: target.url)
                    == (folderMatch ?? (items.isEmpty ? nil : 0)))
                restorationChecks += 1
            }
        }
        #expect(queues.count == 85)
        #expect(selectionChecks == 3_570)
        #expect(folderChecks == 425)
        #expect(restorationChecks == 510)
    }

    private func expectedMatch(_ identity: Int?, in identities: [Int?]) -> Int? {
        guard let identity else { return nil }
        for (index, candidate) in identities.enumerated() where candidate == identity {
            return index
        }
        return nil
    }

    private func item(_ url: URL, marker: Int) -> FolderPlaylistItem {
        FolderPlaylistItem(url: url, dateAdded: Date(timeIntervalSince1970: Double(marker)))
    }

    private struct RawItemPayload: Encodable {
        let url: URL
        let externalSubtitleURLs: [URL]
        let dateAdded: Date?
    }

    private func decodedItem(_ url: URL, marker: Int) throws -> FolderPlaylistItem {
        let payload = RawItemPayload(
            url: url, externalSubtitleURLs: [],
            dateAdded: Date(timeIntervalSince1970: Double(marker))
        )
        return try JSONDecoder().decode(FolderPlaylistItem.self, from: JSONEncoder().encode(payload))
    }
}
