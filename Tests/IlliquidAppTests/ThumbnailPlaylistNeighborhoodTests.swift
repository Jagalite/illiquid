import Foundation
import Testing
import IlliquidCore
@testable import IlliquidApp

@Suite("Thumbnail playlist neighborhood")
struct ThumbnailPlaylistNeighborhoodTests {
    private func items(_ count: Int) -> [FolderPlaylistItem] {
        (0..<count).map {
            FolderPlaylistItem(url: URL(fileURLWithPath: "/media/video-\($0).mkv"))
        }
    }

    // Independent reference: the scheduler's former complete URL projection.
    private func reference(_ items: [FolderPlaylistItem], current: URL?)
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

    private func check(_ playlist: [FolderPlaylistItem], current: URL?) {
        let expected = reference(playlist, current: current)
        let actual = ThumbnailPlaylistNeighborhood(playlist: playlist, current: current)
        #expect(actual.urls == expected.urls)
        #expect(actual.distances == expected.distances)
        #expect(actual.urls.count <= 9)
        #expect(actual.distances.count <= actual.urls.count)
    }

    @Test func everySmallPlaylistBoundaryMatchesPriorOrdering() {
        let missing = URL(fileURLWithPath: "/media/missing.mkv")
        for count in 0...13 {
            let playlist = items(count)
            check(playlist, current: nil)
            check(playlist, current: missing)
            for item in playlist {
                check(playlist, current: item.url)
            }
        }
    }

    @Test(arguments: [32, 10_000])
    func largePlaylistsKeepOnlyTheSelectedWindow(count: Int) {
        let playlist = items(count)
        for index in [0, 3, 4, count / 2, count - 5, count - 1] {
            check(playlist, current: playlist[index].url)
        }
        check(playlist, current: nil)
        check(playlist, current: URL(fileURLWithPath: "/elsewhere/video.mkv"))
    }

    @Test func duplicateCurrentUsesFirstAnchorAndLastDistanceAssignment() {
        let unique = items(10)
        let playlist = [unique[0], unique[1], unique[2], unique[3], unique[0],
                        unique[4], unique[1], unique[5], unique[6], unique[7], unique[0]]
        let result = ThumbnailPlaylistNeighborhood(playlist: playlist, current: unique[0].url)
        #expect(result.urls == [unique[0], unique[1], unique[2], unique[3], unique[0]].map(\.url))
        #expect(result.distances[unique[0].url] == 4)
        check(playlist, current: unique[0].url)
        check(playlist, current: unique[4].url)
    }

    @Test func repeatedAndReorderedInputsMatchReference() {
        let pool = items(17)
        var seed: UInt64 = 0x54484d42
        for count in 0..<96 {
            var playlist: [FolderPlaylistItem] = []
            for _ in 0..<count {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                playlist.append(pool[Int(seed % UInt64(pool.count))])
            }
            for item in pool {
                check(playlist, current: item.url)
            }
        }
    }

    @Test func decodedURLsKeepTheExistingEqualitySemantics() throws {
        struct StoredItem: Encodable {
            let url: URL
            let externalSubtitleURLs: [URL] = []
        }
        let rawURLs = try [
            "file:///media/sub/../video.mkv",
            "file://localhost/media/video.mkv",
            "https://example.invalid/video.mkv",
            "file:///media/caf%C3%A9.mkv",
        ].map { try #require(URL(string: $0)) }
        let data = try JSONEncoder().encode(rawURLs.map { StoredItem(url: $0) })
        let playlist = try JSONDecoder().decode([FolderPlaylistItem].self, from: data)
        for url in rawURLs {
            check(playlist, current: url)
            check(playlist, current: url.standardizedFileURL)
        }
    }

    @Test func resultIsIndependentOfLaterPlaylistChanges() {
        var playlist = items(20)
        let current = playlist[10].url
        let expected = reference(playlist, current: current)
        let result = ThumbnailPlaylistNeighborhood(playlist: playlist, current: current)
        playlist.removeAll()
        #expect(result.urls == expected.urls)
        #expect(result.distances == expected.distances)
    }
}
