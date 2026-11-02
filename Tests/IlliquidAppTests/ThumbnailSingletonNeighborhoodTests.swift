import Foundation
import IlliquidCore
import Testing
@testable import IlliquidApp

@Suite("Thumbnail singleton neighborhood")
struct ThumbnailSingletonNeighborhoodTests {
    private func representation(_ url: URL) -> [String] {
        [url.absoluteString, url.relativeString, url.baseURL?.absoluteString ?? ""]
    }

    @Test func decodedSingletonsKeepTheStoredURLRepresentation() throws {
        struct RawItem: Encodable {
            let url: URL
            let externalSubtitleURLs: [URL] = []
        }
        let base = URL(fileURLWithPath: "/media/season", isDirectory: true)
        let originals = [
            URL(string: "file:///media/season/../episode.mkv")!,
            URL(string: "file://localhost/media/episode.mkv")!,
            URL(string: "https://example.invalid/video.mkv?q=one#chapter")!,
            URL(string: "file:///media/space%20and%23.mkv")!,
            URL(string: "file:///media/caf%C3%A9.mkv")!,
            URL(string: "file:///media/cafe%CC%81.mkv")!,
            URL(string: "episode.mkv", relativeTo: base)!,
        ]

        for original in originals {
            // Decode raw representations without FolderPlaylistItem normalization.
            let data = try JSONEncoder().encode([RawItem(url: original)])
            let playlist = try JSONDecoder().decode([FolderPlaylistItem].self, from: data)
            let stored = try #require(playlist.first?.url)
            let queries: [URL?] = [
                nil, original, stored, stored.absoluteURL, stored.standardized,
                URL(fileURLWithPath: "/media/absent.mkv"),
                URL(string: "https://example.invalid/absent.mkv")!,
            ]
            for query in queries {
                let result = ThumbnailPlaylistNeighborhood(playlist: playlist, current: query)
                let matches = query.map { stored == $0 } ?? false
                if matches {
                    #expect(result.urls.map(representation) == [representation(stored)])
                    #expect(result.distances.count == 1)
                    #expect(result.distances[stored] == 0)
                    #expect(result.distances.keys.map(representation) == [representation(stored)])
                } else {
                    #expect(result.urls.isEmpty)
                    #expect(result.distances.isEmpty)
                }
            }
        }
    }
}
