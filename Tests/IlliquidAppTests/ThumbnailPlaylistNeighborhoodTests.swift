import Foundation
import IlliquidCore
import Testing
@testable import IlliquidApp

@Suite("Thumbnail playlist neighborhood")
struct ThumbnailPlaylistNeighborhoodTests {
    private func item(_ name: String) -> FolderPlaylistItem {
        FolderPlaylistItem(url: URL(fileURLWithPath: "/media/\(name).mkv"))
    }

    @Test func emptyMissingAndNilSelectionsHaveNoNeighbors() {
        let playlist = [item("a"), item("b")]
        for (items, current) in [
            ([FolderPlaylistItem](), Optional(playlist[0].url)),
            (playlist, nil),
            (playlist, Optional(item("missing").url)),
        ] {
            let result = ThumbnailPlaylistNeighborhood(playlist: items, current: current)
            #expect(result.urls.isEmpty)
            #expect(result.distances.isEmpty)
        }
    }

    @Test func singletonAndClippedWindowsKeepPlaylistOrder() {
        let playlist = (0..<13).map { item(String($0)) }
        let cases: [(anchor: Int, indices: [Int], distances: [Int])] = [
            (0, [0, 1, 2, 3, 4], [0, 1, 2, 3, 4]),
            (2, [0, 1, 2, 3, 4, 5, 6], [2, 1, 0, 1, 2, 3, 4]),
            (6, [2, 3, 4, 5, 6, 7, 8, 9, 10], [4, 3, 2, 1, 0, 1, 2, 3, 4]),
            (12, [8, 9, 10, 11, 12], [4, 3, 2, 1, 0]),
        ]
        for test in cases {
            let result = ThumbnailPlaylistNeighborhood(
                playlist: playlist, current: playlist[test.anchor].url)
            #expect(result.urls == test.indices.map { playlist[$0].url })
            for (index, distance) in zip(test.indices, test.distances) {
                #expect(result.distances[playlist[index].url] == distance)
            }
            #expect(result.distances.count == test.indices.count)
        }

        let single = ThumbnailPlaylistNeighborhood(
            playlist: [playlist[0]], current: playlist[0].url)
        #expect(single.urls == [playlist[0].url])
        #expect(single.distances == [playlist[0].url: 0])
    }

    @Test func firstDuplicateAnchorsAndLastWindowOccurrenceSuppliesDistance() {
        let a = item("a"), b = item("b"), c = item("c"), d = item("d")
        let playlist = [a, b, c, a, d, item("outside"), a]
        let result = ThumbnailPlaylistNeighborhood(playlist: playlist, current: a.url)
        #expect(result.urls == [a.url, b.url, c.url, a.url, d.url])
        #expect(result.distances == [a.url: 3, b.url: 1, c.url: 2, d.url: 4])

        let repeatedNeighbor = ThumbnailPlaylistNeighborhood(
            playlist: [b, a, c, d, b, item("e"), b], current: d.url)
        #expect(repeatedNeighbor.distances[b.url] == 3)
        #expect(repeatedNeighbor.urls == [b.url, a.url, c.url, d.url, b.url, item("e").url, b.url])
    }

    @Test func decodedURLsKeepExactURLEqualitySemantics() throws {
        // Decoding bypasses FolderPlaylistItem's normalizing initializer.
        struct RawItem: Encodable {
            let url: URL
            let externalSubtitleURLs: [URL] = []
            let dateAdded: Date? = nil
        }
        let alias = try #require(URL(string: "file:///media/season/../episode.mkv"))
        let canonical = URL(fileURLWithPath: "/media/episode.mkv")
        let remote = try #require(URL(string: "https://example.invalid/video.mkv"))
        let playlist = try JSONDecoder().decode(
            [FolderPlaylistItem].self,
            from: JSONEncoder().encode([RawItem(url: alias), RawItem(url: remote)]))
        let aliasResult = ThumbnailPlaylistNeighborhood(playlist: playlist, current: alias)
        #expect(aliasResult.urls == [alias, remote])
        #expect(aliasResult.distances == [alias: 0, remote: 1])
        let remoteResult = ThumbnailPlaylistNeighborhood(playlist: playlist, current: remote)
        #expect(remoteResult.distances == [alias: 1, remote: 0])
        // Do not introduce path canonicalization that the old URL search did not do.
        #expect(alias != canonical)
        #expect(ThumbnailPlaylistNeighborhood(playlist: playlist, current: canonical).urls.isEmpty)
    }

    @Test func largePlaylistProducesOnlyTheBoundedWindow() {
        let playlist = (0..<10_000).map { item(String($0)) }
        let result = ThumbnailPlaylistNeighborhood(playlist: playlist, current: playlist[5_000].url)
        #expect(result.urls == Array(playlist[4_996...5_004].map(\.url)))
        #expect(result.distances.count == 9)
        #expect(playlist.count == 10_000)
    }

    @Test func exhaustiveSmallPlaylistsMatchAnIndependentLabelOracle() {
        let items = [item("a"), item("b"), item("c")]
        let absent = item("absent").url
        for length in 0...6 {
            let combinations = (0..<length).reduce(1) { value, _ in value * items.count }
            for code in 0..<combinations {
                var remainder = code
                var labels: [Int] = []
                for _ in 0..<length {
                    labels.append(remainder % items.count)
                    remainder /= items.count
                }
                let playlist = labels.map { items[$0] }
                for selected in -1...3 {
                    let current = selected < 0 ? nil
                        : (selected < items.count ? items[selected].url : absent)
                    let result = ThumbnailPlaylistNeighborhood(playlist: playlist, current: current)
                    var anchor: Int?
                    for (position, label) in labels.enumerated() where label == selected {
                        if anchor == nil { anchor = position }
                    }
                    let included = labels.indices.filter { position in
                        anchor.map { abs(position - $0) <= 4 } ?? false
                    }
                    let expectedURLs = included.map { items[labels[$0]].url }
                    var expectedDistances: [URL: Int] = [:]
                    if let anchor {
                        for position in included {
                            expectedDistances[items[labels[position]].url] = abs(position - anchor)
                        }
                    }
                    #expect(result.urls == expectedURLs)
                    #expect(result.distances == expectedDistances)
                }
            }
        }
    }
}
