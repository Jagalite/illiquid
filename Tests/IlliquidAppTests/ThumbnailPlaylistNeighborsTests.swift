import Foundation
import IlliquidCore
import Testing
@testable import IlliquidApp

@Suite("Thumbnail playlist neighbors")
struct ThumbnailPlaylistNeighborsTests {
    @Test func emptyMissingAndAbsentCurrentHaveNoNeighbors() {
        let playlist = (0..<12).map(item)
        for (input, current) in [
            ([FolderPlaylistItem](), Optional<URL>.none),
            ([], playlist[0].url),
            (playlist, nil),
            (playlist, item(99).url),
        ] {
            let result = ThumbnailPlaylistNeighbors(playlist: input, current: current)
            #expect(result.urls.isEmpty)
            #expect(result.distances.isEmpty)
        }
    }

    @Test func everySmallPlaylistPositionKeepsTheOriginalWindow() {
        for count in 1...24 {
            let playlist = (0..<count).map(item)
            for anchor in playlist.indices {
                let result = ThumbnailPlaylistNeighbors(playlist: playlist, current: playlist[anchor].url)
                let expected = originalNeighbors(playlist: playlist, current: playlist[anchor].url)
                #expect(result.urls == expected.urls)
                #expect(result.distances == expected.distances)
                #expect(result.urls.count <= 9)
                #expect(result.distances[playlist[anchor].url] == 0)
            }
        }
    }

    @Test func duplicateURLsKeepFirstAnchorAndLastWindowDistance() {
        let current = item(0)
        let duplicate = item(1)
        let playlist = [item(2), current, duplicate, current, item(3), duplicate, item(4), current]
        let result = ThumbnailPlaylistNeighbors(playlist: playlist, current: current.url)

        // The first current is at index 1, so the window ends at index 5.
        // A duplicate current in that window overwrites its zero distance.
        #expect(result.urls == Array(playlist.prefix(6)).map(\.url))
        #expect(result.distances[current.url] == 2)
        #expect(result.distances[duplicate.url] == 4)
        #expect(result.distances[item(4).url] == nil)
        let expected = originalNeighbors(playlist: playlist, current: current.url)
        #expect(result.urls == expected.urls)
        #expect(result.distances == expected.distances)
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
            let result = ThumbnailPlaylistNeighbors(playlist: playlist, current: current)
            let expected = originalNeighbors(playlist: playlist, current: current)
            #expect(result.urls == expected.urls)
            #expect(result.distances == expected.distances)
            #expect(result.urls.map(\.absoluteString) == expected.urls.map(\.absoluteString))
        }
        // A normalized identity must not make a differently represented URL
        // match when that exact URL is absent from the playlist.
        #expect(ThumbnailPlaylistNeighbors(playlist: [raw], current: canonical.url).urls.isEmpty)
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
                let result = ThumbnailPlaylistNeighbors(playlist: playlist, current: current)
                let expected = originalNeighbors(playlist: playlist, current: current)
                #expect(result.urls == expected.urls)
                #expect(result.distances == expected.distances)
                #expect(result.urls.count <= 9)
            }
        }
    }

    @Test func largePlaylistResultsStayBoundedAndIndependent() {
        var playlist = (0..<10_000).map(item)
        let current = playlist[5_000].url
        let expected = originalNeighbors(playlist: playlist, current: current)
        let result = ThumbnailPlaylistNeighbors(playlist: playlist, current: current)
        #expect(result.urls.count == 9)
        #expect(result.distances.count == 9)

        playlist[5_000] = item(20_000)
        playlist.removeAll(keepingCapacity: false)
        #expect(result.urls == expected.urls)
        #expect(result.distances == expected.distances)
        #expect(result.distances[current] == 0)
    }

    // The scheduler's original projection is the reference. Keep its eager map,
    // first URL match, bounded slice, and separate distance pass independent of
    // the production helper's direct traversal.
    private func originalNeighbors(playlist items: [FolderPlaylistItem], current: URL?)
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
