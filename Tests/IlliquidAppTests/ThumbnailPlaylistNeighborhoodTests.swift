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

    // Consolidated regression provenance is recorded in the benchmark README.
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
        let result = ThumbnailPlaylistNeighborhood(playlist: items, current: current)
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

    @Test func restoredURLRepresentationsKeepExactEqualitySemantics() throws {
        let raw = try decodedItem("file://localhost/Media/Season/../Cafe%CC%81.mkv?restore=1#chapter")
        let canonical = FolderPlaylistItem(url: URL(fileURLWithPath: "/Media/Caf\u{00E9}.mkv"))
        #expect(raw.id == canonical.id)
        #expect(raw.url != canonical.url)
        let remote = try decodedItem("https://example.invalid/Media/Caf%C3%A9.mkv")
        let nonlocal = try decodedItem("file://archive.invalid/Media/Caf%C3%A9.mkv")
        let playlist = [raw] + (0..<10).map(item) + [canonical, remote, nonlocal]

        for current in [raw.url, canonical.url, remote.url, nonlocal.url] {
            let result = ThumbnailPlaylistNeighborhood(playlist: playlist, current: current)
            let expected = originalProjection(items: playlist, current: current)
            #expect(result.urls == expected.urls)
            #expect(result.distances == expected.distances)
            #expect(result.urls.map(\.absoluteString) == expected.urls.map(\.absoluteString))
        }
        // A normalized identity must not make a differently represented URL
        // match when that exact URL is absent from the playlist.
        #expect(ThumbnailPlaylistNeighborhood(playlist: [raw], current: canonical.url).urls.isEmpty)
    }

    @Test func seededMixedPlaylistsMatchTheOriginalProjection() throws {
        let corpus = (0..<16).map(item) + [
            try decodedItem("file:///Media/Caf%C3%A9.mkv"),
            try decodedItem("file:///Media/Cafe%CC%81.mkv"),
            try decodedItem("file:///Media/Season/../0.mkv"),
            try decodedItem("https://example.invalid/video.mkv"),
            try decodedItem("file://archive.invalid/Media/0.mkv"),
        ]
        var state: UInt64 = 0x7468_756D_626E_6169
        for count in 0...96 {
            let playlist = (0..<count).map { _ in
                state = state &* 6_364_136_223_846_793_005 &+ 1
                return corpus[Int((state >> 32) % UInt64(corpus.count))]
            }
            let queries: [URL?] = [nil, item(999).url] + corpus.map { Optional($0.url) }
            for current in queries {
                let result = ThumbnailPlaylistNeighborhood(playlist: playlist, current: current)
                let expected = originalProjection(items: playlist, current: current)
                #expect(result.urls == expected.urls)
                #expect(result.distances == expected.distances)
                #expect(result.urls.count <= 9)
            }
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

    private func item(_ index: Int) -> FolderPlaylistItem {
        FolderPlaylistItem(url: URL(fileURLWithPath: "/Media/\(index).mkv"),
                           externalSubtitleURLs: [URL(fileURLWithPath: "/Subtitles/\(index).srt")],
                           dateAdded: Date(timeIntervalSince1970: Double(index)))
    }

    private func decodedItem(_ spelling: String) throws -> FolderPlaylistItem {
        let data = try JSONSerialization.data(withJSONObject: [
            "url": spelling, "externalSubtitleURLs": [String](),
        ])
        return try JSONDecoder().decode(FolderPlaylistItem.self, from: data)
    }
}
