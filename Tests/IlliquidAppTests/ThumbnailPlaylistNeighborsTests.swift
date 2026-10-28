import Foundation
import Testing
import IlliquidCore
@testable import IlliquidApp

@Suite("Thumbnail playlist neighbors")
struct ThumbnailPlaylistNeighborsTests {
    private func item(_ name: String) -> FolderPlaylistItem {
        FolderPlaylistItem(url: URL(fileURLWithPath: "/media/library/\(name).mkv"))
    }

    @Test func emptyPlaylistHasNoNeighbors() {
        for current in [nil, item("missing").url] as [URL?] {
            let result = ThumbnailPlaylistNeighbors(items: [], current: current)
            #expect(result.urls.isEmpty)
            #expect(result.distances.isEmpty)
        }
    }

    @Test func nilAndMissingCurrentHaveNoNeighbors() {
        let items = (0..<100).map { item("episode-\($0)") }
        for current in [nil, item("missing").url] as [URL?] {
            let result = ThumbnailPlaylistNeighbors(items: items, current: current)
            #expect(result.urls.isEmpty)
            #expect(result.distances.isEmpty)
        }
    }

    @Test func singletonIncludesTheCurrentVideoAtDistanceZero() {
        let only = item("only")
        let result = ThumbnailPlaylistNeighbors(items: [only], current: only.url)
        #expect(result.urls == [only.url])
        #expect(result.distances == [only.url: 0])
    }

    @Test func windowsStayInPlaylistOrderAndClipAtBothEnds() {
        let items = (0..<15).map { item("episode-\($0)") }
        let cases: [(anchor: Int, offsets: [Int])] = [
            (0, [0, 1, 2, 3, 4]),
            (1, [0, 1, 2, 3, 4, 5]),
            (4, [0, 1, 2, 3, 4, 5, 6, 7, 8]),
            (5, [1, 2, 3, 4, 5, 6, 7, 8, 9]),
            (9, [5, 6, 7, 8, 9, 10, 11, 12, 13]),
            (13, [9, 10, 11, 12, 13, 14]),
            (14, [10, 11, 12, 13, 14]),
        ]
        for fixture in cases {
            let result = ThumbnailPlaylistNeighbors(items: items, current: items[fixture.anchor].url)
            #expect(result.urls == fixture.offsets.map { items[$0].url })
            #expect(result.distances.count == fixture.offsets.count)
            for offset in fixture.offsets {
                #expect(result.distances[items[offset].url] == abs(offset - fixture.anchor))
            }
        }
    }

    @Test func repeatedCurrentAnchorsAtItsFirstOccurrence() {
        var items = (0..<15).map { item("episode-\($0)") }
        items[10] = items[2]
        let result = ThumbnailPlaylistNeighbors(items: items, current: items[10].url)
        #expect(result.urls == Array(items.prefix(7)).map(\.url))
        #expect(result.distances[items[2].url] == 0)
        #expect(result.distances[items[9].url] == nil)
    }

    @Test func duplicateURLsKeepTheirLastDistanceWithoutDeduplicatingTheWindow() {
        let current = item("current")
        let repeated = item("repeated")
        let items = [
            item("before"), item("near-before"), current, repeated,
            current, repeated, item("after"), item("outside"),
        ]
        let result = ThumbnailPlaylistNeighbors(items: items, current: current.url)
        #expect(result.urls == Array(items.prefix(7)).map(\.url))
        #expect(result.urls.count == 7)
        #expect(result.distances.count == 5)
        // The previous scheduler assigned distances in ascending playlist order.
        // A later duplicate deliberately overwrites an earlier, closer distance.
        #expect(result.distances[current.url] == 2)
        #expect(result.distances[repeated.url] == 3)
        #expect(result.distances[items[0].url] == 2)
        #expect(result.distances[items[6].url] == 4)
        #expect(result.distances[items[7].url] == nil)
    }

    @Test func anchorUsesURLEqualityRatherThanPathEquality() throws {
        let first = try #require(URL(string: "https://one.example.test/episode.mkv"))
        let second = try #require(URL(string: "https://two.example.test/episode.mkv"))
        let items = [FolderPlaylistItem(url: first), FolderPlaylistItem(url: second)]
        #expect(items[0].url.path == items[1].url.path)
        let result = ThumbnailPlaylistNeighbors(items: items, current: second)
        #expect(result.urls == [first, second])
        #expect(result.distances == [first: 1, second: 0])
    }

    @Test func deterministicDifferentialMatchesThePreviousScheduler() {
        var random = DeterministicRandom()
        let pool = (0..<67).map { item("series é space-\($0)") }
        for trial in 0..<256 {
            let count = random.index(193)
            let items = (0..<count).map { _ in pool[random.index(pool.count)] }
            let current: URL?
            switch trial % 4 {
            case 0: current = nil
            case 1: current = item("not-in-playlist").url
            case 2: current = items.last?.url
            default: current = items.isEmpty ? nil : items[random.index(items.count)].url
            }
            let expected = originalProjection(items: items, current: current)
            let result = ThumbnailPlaylistNeighbors(items: items, current: current)
            #expect(result.urls == expected.urls)
            #expect(result.distances == expected.distances)
            #expect(result.urls.count <= 9)
            #expect(result.distances.count <= 9)
        }
    }

    @Test func rankedCandidatesRemainIdenticalForEveryPriority() {
        var items = (0..<24).map { item("episode-\($0)") }
        let current = items[8].url
        items[10] = items[8]
        items[12] = items[9]
        let visible: Set<URL> = [items[3].url, items[22].url]
        let excluded = URL(fileURLWithPath: "/media/excluded/episode.mkv")
        let discovered = [items[0].url, items[9].url, excluded]
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let recent = [
            items[9].url: now.addingTimeInterval(-60),
            items[23].url: now.addingTimeInterval(-90_000),
            excluded: now,
        ]
        func candidates(urls neighbors: [URL], distances: [URL: Int]) -> [ThumbnailPolicy.Candidate] {
            let urls = [current] + visible.sorted { $0.path < $1.path } + discovered
                + neighbors + recent.keys.sorted { $0.path < $1.path }
            return urls.map {
                ThumbnailPolicy.Candidate(url: $0, lastUsed: recent[$0],
                    isVisible: visible.contains($0), neighborDistance: distances[$0])
            }
        }

        let original = originalProjection(items: items, current: current)
        let result = ThumbnailPlaylistNeighbors(items: items, current: current)
        let expectedCandidates = candidates(urls: original.urls, distances: original.distances)
        let actualCandidates = candidates(urls: result.urls, distances: result.distances)
        #expect(actualCandidates == expectedCandidates)

        for priority in ThumbnailPreferences.Priority.allCases {
            var preferences = ThumbnailPreferences()
            preferences.priority = priority
            preferences.excludedFolderPaths = ["/media/excluded"]
            for limit in [0, 1, 4, 100] {
                let expected = ThumbnailPolicy.ranked(expectedCandidates, current: current,
                    folder: current.deletingLastPathComponent(), now: now,
                    preferences: preferences, maximumCount: limit)
                let actual = ThumbnailPolicy.ranked(actualCandidates, current: current,
                    folder: current.deletingLastPathComponent(), now: now,
                    preferences: preferences, maximumCount: limit)
                #expect(actual == expected)
                #expect(!actual.contains(excluded))
                if limit > 0 { #expect(actual.first == current) }
            }
        }
    }

    /// Frozen reference from ThumbnailBackgroundScheduler.runPass before the
    /// bounded projection. Keep its eager map to check behavior independently.
    private func originalProjection(items: [FolderPlaylistItem], current: URL?)
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

    private struct DeterministicRandom {
        private var state: UInt64 = 0x6E65_6967_6862_6F72

        mutating func index(_ upperBound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 32) % UInt64(upperBound))
        }
    }
}
