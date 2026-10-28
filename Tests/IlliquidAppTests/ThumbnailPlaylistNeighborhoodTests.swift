import Foundation
import Testing
import IlliquidCore
@testable import IlliquidApp

@Suite("Thumbnail playlist neighborhood")
struct ThumbnailPlaylistNeighborhoodTests {
    private func file(_ name: String) -> URL {
        URL(fileURLWithPath: "/tmp/illiquid-thumbnail-neighborhood/\(name).mkv")
    }

    /// Literal pre-optimization algorithm, including its duplicate URL semantics.
    private func original(
        _ items: [FolderPlaylistItem], current: URL?
    ) -> (urls: [URL], distances: [URL: Int]) {
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

    private func check(_ items: [FolderPlaylistItem], current: URL?) {
        let expected = original(items, current: current)
        let actual = ThumbnailPlaylistNeighborhood(playlist: items, current: current)
        #expect(actual.urls == expected.urls)
        #expect(actual.urls.map(\.absoluteString) == expected.urls.map(\.absoluteString))
        #expect(actual.distances == expected.distances)
        #expect(actual.urls.count <= 9)
        #expect(actual.distances.count <= 9)
    }

    @Test func everyAnchorAndMissingSourceMatchOriginal() {
        for count in [0, 1, 2, 4, 5, 8, 9, 10, 32] {
            let items = (0..<count).map { FolderPlaylistItem(url: file("item-\($0)")) }
            let queries: [URL?] = [nil, file("absent")] + items.map { Optional($0.url) }
            for current in queries {
                check(items, current: current)
            }
        }
    }

    @Test func duplicatesKeepFirstAnchorAndLastDistance() {
        let repeated = file("repeated")
        let current = file("current")
        let input = [
            repeated, file("a"), file("b"), current, repeated,
            file("e"), current, repeated, file("tail"), file("tail2"),
        ]
        let items = input.map { FolderPlaylistItem(url: $0) }
        let actual = ThumbnailPlaylistNeighborhood(playlist: items, current: current)

        #expect(actual.urls == Array(input.prefix(8)))
        #expect(actual.distances[repeated] == 4)
        #expect(actual.distances[current] == 3)
        check(items, current: current)
    }

    @Test func duplicateLayoutsMatchOriginal() {
        let pool = (0..<11).map { file("duplicate-\($0)") }
        for count in [1, 5, 9, 17, 64, 129] {
            let items = (0..<count).map {
                FolderPlaylistItem(url: pool[($0 * $0 + 3 * $0) % pool.count])
            }
            for current in pool {
                check(items, current: current)
            }
        }
    }

    @Test func decodedURLRepresentationsUseExistingEquality() throws {
        struct RawItem: Encodable {
            let url: URL
            let externalSubtitleURLs: [URL] = []
        }
        let rawURLs = [
            URL(string: "file:///tmp/illiquid-thumbnail-neighborhood/a/../clip.mkv")!,
            URL(string: "file://localhost/tmp/illiquid-thumbnail-neighborhood/clip.mkv")!,
            URL(string: "https://example.invalid/video.mkv?q=one#chapter")!,
            URL(string: "file:///tmp/illiquid-thumbnail-neighborhood/space%20and%23.mkv")!,
            URL(string: "file:///tmp/illiquid-thumbnail-neighborhood/caf%C3%A9.mkv")!,
            URL(string: "file:///tmp/illiquid-thumbnail-neighborhood/cafe%CC%81.mkv")!,
            URL(string: "relative.mkv", relativeTo: file("base").deletingLastPathComponent())!,
        ]
        // Decoding bypasses FolderPlaylistItem's normalizing initializer.
        let data = try JSONEncoder().encode(rawURLs.map { RawItem(url: $0) })
        let items = try JSONDecoder().decode([FolderPlaylistItem].self, from: data)
        let queries: [URL?] = [nil, file("absent")] + rawURLs.map { Optional($0) }
            + items.map { Optional($0.url) } + items.map { Optional($0.url.standardized) }
        for current in queries {
            check(items, current: current)
        }
    }

    @Test func largePlaylistStillReturnsOnlyTheNeighborhood() {
        let items = (0..<10_000).map { FolderPlaylistItem(url: file("large-\($0)")) }
        for index in [0, 4, 5_000, 9_995, 9_999] {
            check(items, current: items[index].url)
        }
        check(items, current: nil)
        check(items, current: file("absent"))
    }

    @Test func resultSurvivesReplacingAndRemovingSourceItems() {
        var items = (0..<20).map {
            FolderPlaylistItem(url: file("item-\($0)"), externalSubtitleURLs: [file("subtitle-\($0)")])
        }
        let current = items[10].url
        let expected = original(items, current: current)
        let result = ThumbnailPlaylistNeighborhood(playlist: items, current: current)
        items[10] = FolderPlaylistItem(url: file("replacement"))
        items.removeAll(keepingCapacity: false)
        #expect(result.urls == expected.urls)
        #expect(result.distances == expected.distances)
    }
}
