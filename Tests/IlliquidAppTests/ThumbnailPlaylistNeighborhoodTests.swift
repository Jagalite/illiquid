import Foundation
import Testing
import IlliquidCore
@testable import IlliquidApp

@Suite("Thumbnail playlist neighborhoods")
struct ThumbnailPlaylistNeighborhoodTests {
    private func item(_ number: Int) -> FolderPlaylistItem {
        FolderPlaylistItem(
            url: URL(fileURLWithPath: "/Media/Episode-\(number).mkv"),
            externalSubtitleURLs: [URL(fileURLWithPath: "/Media/Episode-\(number).srt")],
            dateAdded: Date(timeIntervalSince1970: Double(number))
        )
    }

    private func legacy(_ items: [FolderPlaylistItem], current: URL?)
        -> (urls: [URL], distances: [URL: Int]) {
        let playlist = items.map(\.url)
        let anchor = current.flatMap { playlist.firstIndex(of: $0) }
        let neighbors = anchor.map { index in
            Array(playlist[max(0, index - 4)..<min(playlist.count, index + 5)])
        } ?? []
        var distances: [URL: Int] = [:]
        if let anchor {
            for index in max(0, anchor - 4)..<min(playlist.count, anchor + 5) {
                distances[playlist[index]] = abs(index - anchor)
            }
        }
        return (neighbors, distances)
    }

    @Test func emptyNilAndMissingSelectionsHaveNoNeighbors() {
        let items = (0..<12).map(item)
        let selections: [URL?] = [nil, item(99).url]
        for current in selections {
            let empty = ThumbnailPlaylistNeighborhood(playlist: [], current: current)
            #expect(empty.urls.isEmpty)
            #expect(empty.distances.isEmpty)
            let missing = ThumbnailPlaylistNeighborhood(playlist: items, current: current)
            #expect(missing.urls.isEmpty)
            #expect(missing.distances.isEmpty)
        }
    }

    @Test func everyAnchorClipsToFourItemsOnEachSide() {
        for count in [1, 2, 4, 5, 8, 9, 10, 17, 32] {
            let items = (0..<count).map(item)
            for anchor in items.indices {
                let result = ThumbnailPlaylistNeighborhood(playlist: items, current: items[anchor].url)
                // Deliberately derive the expectation from distances, not the
                // implementation's lower/upper range calculation.
                let expected = items.indices.filter { abs($0 - anchor) <= 4 }
                #expect(result.urls == expected.map { items[$0].url })
                #expect(result.distances == Dictionary(uniqueKeysWithValues:
                    expected.map { (items[$0].url, abs($0 - anchor)) }))
                #expect(result.urls.count <= 9)
            }
        }
    }

    @Test func firstDuplicateAnchorsAndLastWindowOccurrenceSetsDistance() {
        let a = item(1), b = item(2), c = item(3), d = item(4)
        let items = [a, b, c, a, d, b, a, c, b]
        let result = ThumbnailPlaylistNeighborhood(playlist: items, current: a.url)
        #expect(result.urls == [a.url, b.url, c.url, a.url, d.url])
        #expect(result.distances == [a.url: 3, b.url: 1, c.url: 2, d.url: 4])

        let second = ThumbnailPlaylistNeighborhood(playlist: items, current: b.url)
        #expect(second.urls == [a.url, b.url, c.url, a.url, d.url, b.url])
        #expect(second.distances[b.url] == 4)
        #expect(second.distances[a.url] == 2)
    }

    @Test func usesStoredURLValuesWithoutNormalizingOrResolvingThem() throws {
        // Codable can bypass the normalizing public initializer. Preserve those
        // representations and Foundation's URL equality contract.
        struct EncodedItem: Encodable {
            let url: URL
            let externalSubtitleURLs: [URL] = []
            let dateAdded: Date? = nil
        }
        let urls = [
            try #require(URL(string: "file:///Media/Season/../Episode%201.mkv")),
            try #require(URL(string: "file:///Media/Episode%201.mkv")),
            try #require(URL(string: "https://example.invalid/Episode%201.mkv?part=1")),
            try #require(URL(string: "https://example.invalid/Episode%201.mkv?part=2")),
        ]
        let data = try JSONEncoder().encode(urls.map { EncodedItem(url: $0) })
        let items = try JSONDecoder().decode([FolderPlaylistItem].self, from: data)
        for current in urls.map(Optional.some) + [nil] {
            let result = ThumbnailPlaylistNeighborhood(playlist: items, current: current)
            let expected = legacy(items, current: current)
            #expect(result.urls == expected.urls)
            #expect(result.urls.map(\.absoluteString) == expected.urls.map(\.absoluteString))
            #expect(result.distances == expected.distances)
        }
    }

    @Test func randomizedPlaylistsMatchLegacyOrderAndDistances() {
        var seed: UInt64 = 0x7A11_2026
        func next(_ limit: Int) -> Int {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int(seed % UInt64(limit))
        }
        let pool = (0..<24).map(item)
        for _ in 0..<256 {
            let items = (0..<next(97)).map { _ in pool[next(pool.count)] }
            let current: URL? = switch next(4) {
            case 0: nil
            case 1: item(99).url
            default: items.isEmpty ? pool[0].url : items[next(items.count)].url
            }
            let result = ThumbnailPlaylistNeighborhood(playlist: items, current: current)
            let expected = legacy(items, current: current)
            #expect(result.urls == expected.urls)
            #expect(result.distances == expected.distances)
            #expect(result.urls.count <= 9)
        }
    }

    @Test func resultSurvivesSourceReplacementWithOnlyItsNeighborhoodValues() {
        var items = (0..<10_000).map(item)
        let anchor = 5_000
        let expected = ((anchor - 4)...(anchor + 4)).map { items[$0].url }
        let result = ThumbnailPlaylistNeighborhood(playlist: items, current: items[anchor].url)
        items.removeAll(keepingCapacity: false)
        items.append(item(99_999))
        #expect(result.urls == expected)
        #expect(result.urls.count == 9)
        #expect(result.distances.count == 9)
        #expect(result.distances[expected[4]] == 0)
    }
}
