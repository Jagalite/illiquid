import Foundation
import Testing
import IlliquidCore
@testable import IlliquidApp

@Suite("Thumbnail playlist neighborhood planning")
struct ThumbnailCandidatePlanningTests {
    private func item(_ index: Int) -> FolderPlaylistItem {
        FolderPlaylistItem(url: URL(fileURLWithPath: "/media/thumbnail-planning/episode-\(index).mkv"))
    }

    @Test func emptyMissingAndNilCurrentProduceNoNeighbors() {
        let items = (0..<12).map(item)
        let empty = ThumbnailPlaylistNeighborhood.Plan(urls: [], distances: [:])
        #expect(ThumbnailPlaylistNeighborhood.plan(items: [], current: nil) == empty)
        #expect(ThumbnailPlaylistNeighborhood.plan(items: [], current: items[0].url) == empty)
        #expect(ThumbnailPlaylistNeighborhood.plan(items: items, current: nil) == empty)
        #expect(ThumbnailPlaylistNeighborhood.plan(items: items, current: item(99).url) == empty)
    }

    @Test func smallPlaylistsIncludeTheirEntireNeighborhood() {
        let singleton = item(0)
        #expect(ThumbnailPlaylistNeighborhood.plan(items: [singleton], current: singleton.url)
            == .init(urls: [singleton.url], distances: [singleton.url: 0]))
        let items = (0..<3).map(item)
        #expect(ThumbnailPlaylistNeighborhood.plan(items: items, current: items[1].url)
            == .init(urls: items.map(\.url),
                     distances: [items[0].url: 1, items[1].url: 0, items[2].url: 1]))
    }

    @Test func neighborhoodClipsAtBothEndsAndKeepsOriginalOrder() {
        let items = (0..<12).map(item)
        let cases: [(anchor: Int, expected: [Int])] = [
            (0, [0, 1, 2, 3, 4]),
            (3, [0, 1, 2, 3, 4, 5, 6, 7]),
            (4, [0, 1, 2, 3, 4, 5, 6, 7, 8]),
            (7, [3, 4, 5, 6, 7, 8, 9, 10, 11]),
            (11, [7, 8, 9, 10, 11]),
        ]
        for test in cases {
            let plan = ThumbnailPlaylistNeighborhood.plan(items: items, current: items[test.anchor].url)
            #expect(plan.urls == test.expected.map { items[$0].url })
            #expect(plan.distances.count == test.expected.count)
            for index in test.expected {
                #expect(plan.distances[items[index].url] == abs(index - test.anchor))
            }
        }
    }

    @Test func firstOccurrenceSelectsWindowAndLastDuplicateSetsDistance() {
        var items = (0..<12).map(item)
        let current = items[2]
        let repeatedNeighbor = items[1]
        items[4] = repeatedNeighbor
        items[6] = current
        let plan = ThumbnailPlaylistNeighborhood.plan(items: items, current: current.url)
        #expect(plan.urls == [items[0].url, repeatedNeighbor.url, current.url,
                              items[3].url, repeatedNeighbor.url, items[5].url, current.url])
        #expect(plan.distances == [items[0].url: 2, repeatedNeighbor.url: 2,
                                   current.url: 4, items[3].url: 1, items[5].url: 3])
    }

    @Test func decodedURLsKeepTheirSpellingAndMatchWithoutNormalization() throws {
        let alias = try #require(URL(string: "file:///media/thumbnail-planning/nested/../episode.mkv"))
        let canonical = URL(fileURLWithPath: "/media/thumbnail-planning/episode.mkv")
        try #require(alias != canonical)
        let rawItem = try JSONDecoder().decode(FolderPlaylistItem.self, from: JSONEncoder().encode(
            RawItem(url: alias, externalSubtitleURLs: [])))
        try #require(rawItem.url.absoluteString == alias.absoluteString)
        var items = (0..<12).map(item)
        items[0] = rawItem
        items[10] = FolderPlaylistItem(url: canonical)

        let canonicalPlan = ThumbnailPlaylistNeighborhood.plan(items: items, current: canonical)
        #expect(canonicalPlan.urls == items[6..<12].map(\.url))
        #expect(canonicalPlan.distances[canonical] == 0)
        let aliasPlan = ThumbnailPlaylistNeighborhood.plan(items: items, current: alias)
        #expect(aliasPlan.urls.map(\.absoluteString) == items[0..<5].map { $0.url.absoluteString })
        #expect(aliasPlan.distances[alias] == 0)
        #expect(ThumbnailPlaylistNeighborhood.plan(items: [rawItem], current: canonical).urls.isEmpty)
    }

    @Test func remoteURLsRemainInTheNeighborhoodForTheRankingPolicyToHandle() throws {
        let remote = try #require(URL(string: "https://example.test/video.mkv?track=1#t=2"))
        let items = [item(0), FolderPlaylistItem(url: remote), item(2)]
        #expect(ThumbnailPlaylistNeighborhood.plan(items: items, current: remote)
            == .init(urls: items.map(\.url),
                     distances: [items[0].url: 1, remote: 0, items[2].url: 1]))
    }

    @Test func retainedPlanIsIndependentOfSubsequentPlaylistChanges() {
        var items = (0..<12).map(item)
        let original = items
        let plan = ThumbnailPlaylistNeighborhood.plan(items: items, current: items[6].url)
        #expect(items == original)
        items.removeAll()
        items.append(item(99))
        #expect(plan.urls == original[2..<11].map(\.url))
        #expect(plan.distances[original[6].url] == 0)
        #expect(plan.distances[items[0].url] == nil)
    }

    @Test func generatedUniqueAndDuplicatePlaylistsMatchPreviousPlanning() {
        let pool = (0..<25).map(item)
        for count in 0...24 {
            for duplicates in [false, true] {
                let items = (0..<count).map { pool[duplicates ? ($0 * 7 + count) % 11 : $0] }
                let queries: [URL?] = [nil, item(99).url] + items.map { Optional($0.url) }
                for current in queries {
                    let plan = ThumbnailPlaylistNeighborhood.plan(items: items, current: current)
                    #expect(plan == previousPlan(items: items, current: current))
                    #expect(plan.urls.count <= 9)
                }
            }
        }
    }

    private struct RawItem: Encodable {
        let url: URL
        let externalSubtitleURLs: [URL]
    }

    /// The previous scheduler's eager URL projection, retained as a parity oracle.
    private func previousPlan(items: [FolderPlaylistItem], current: URL?) -> ThumbnailPlaylistNeighborhood.Plan {
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
        return .init(urls: neighbors, distances: distances)
    }
}
