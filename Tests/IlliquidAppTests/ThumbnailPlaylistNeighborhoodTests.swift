import Foundation
import Testing
import IlliquidCore
@testable import IlliquidApp

@Suite("Thumbnail playlist neighborhood")
struct ThumbnailPlaylistNeighborhoodTests {
    private func media(_ name: String) -> URL {
        URL(fileURLWithPath: "/media/\(name).mkv")
    }

    private func playlist(_ names: [String]) -> [FolderPlaylistItem] {
        names.map { FolderPlaylistItem(url: media($0)) }
    }

    @Test func absentCurrentHasNoNeighbors() {
        let entries = playlist(["a", "b", "c"])
        let absent: [URL?] = [nil, media("missing")]
        for current in absent {
            let result = ThumbnailPlaylistNeighborhood(playlist: entries, current: current)
            #expect(result.urls.isEmpty)
            #expect(result.distances.isEmpty)
        }
        let empty = ThumbnailPlaylistNeighborhood(playlist: [], current: media("a"))
        #expect(empty.urls.isEmpty)
        #expect(empty.distances.isEmpty)
    }

    @Test func shortPlaylistsKeepEveryNeighborInPlaylistOrder() {
        let single = ThumbnailPlaylistNeighborhood(playlist: playlist(["only"]), current: media("only"))
        #expect(single.urls == [media("only")])
        #expect(single.distances == [media("only"): 0])

        let result = ThumbnailPlaylistNeighborhood(playlist: playlist(["a", "b", "c"]), current: media("b"))
        #expect(result.urls == [media("a"), media("b"), media("c")])
        #expect(result.distances == [media("a"): 1, media("b"): 0, media("c"): 1])
    }

    @Test func boundariesClipTheWindowWithoutWrapping() {
        let entries = playlist(["a", "b", "c", "d", "e", "f", "g"])
        let first = ThumbnailPlaylistNeighborhood(playlist: entries, current: media("a"))
        #expect(first.urls == ["a", "b", "c", "d", "e"].map(media))
        #expect(first.distances == [
            media("a"): 0, media("b"): 1, media("c"): 2, media("d"): 3, media("e"): 4,
        ])

        let last = ThumbnailPlaylistNeighborhood(playlist: entries, current: media("g"))
        #expect(last.urls == ["c", "d", "e", "f", "g"].map(media))
        #expect(last.distances == [
            media("c"): 4, media("d"): 3, media("e"): 2, media("f"): 1, media("g"): 0,
        ])
    }

    @Test func interiorWindowIncludesFourVideosOnEitherSide() {
        let entries = playlist(["a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k"])
        let result = ThumbnailPlaylistNeighborhood(playlist: entries, current: media("f"))
        #expect(result.urls == ["b", "c", "d", "e", "f", "g", "h", "i", "j"].map(media))
        #expect(result.distances == [
            media("b"): 4, media("c"): 3, media("d"): 2, media("e"): 1, media("f"): 0,
            media("g"): 1, media("h"): 2, media("i"): 3, media("j"): 4,
        ])
    }

    @Test func duplicatesUseFirstAnchorAndLastDistanceWithoutDroppingURLs() {
        let entries = playlist(["a", "x", "current", "b", "x", "current", "c", "d", "e"])
        let result = ThumbnailPlaylistNeighborhood(playlist: entries, current: media("current"))
        #expect(result.urls == ["a", "x", "current", "b", "x", "current", "c"].map(media))
        #expect(result.distances == [
            media("a"): 2, media("x"): 2, media("current"): 3, media("b"): 1, media("c"): 4,
        ])
    }

    @Test func largePlaylistReturnsOnlyTheNeighborhoodNearItsEnd() {
        let entries = (0..<10_000).map { FolderPlaylistItem(url: media(String($0))) }
        let result = ThumbnailPlaylistNeighborhood(playlist: entries, current: media("9997"))
        #expect(result.urls == ["9993", "9994", "9995", "9996", "9997", "9998", "9999"].map(media))
        #expect(result.distances == [
            media("9993"): 4, media("9994"): 3, media("9995"): 2, media("9996"): 1,
            media("9997"): 0, media("9998"): 1, media("9999"): 2,
        ])
    }
}
