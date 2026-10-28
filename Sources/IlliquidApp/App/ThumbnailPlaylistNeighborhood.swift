import Foundation
import IlliquidCore

/// Owns only the small playlist window needed by one background thumbnail pass.
struct ThumbnailPlaylistNeighborhood: Sendable {
    let urls: [URL]
    let distances: [URL: Int]

    init(playlist: [FolderPlaylistItem], current: URL?) {
        guard let current,
              let anchor = playlist.firstIndex(where: { $0.url == current }) else {
            urls = []
            distances = [:]
            return
        }

        let indices = max(0, anchor - 4)..<min(playlist.count, anchor + 5)
        var urls: [URL] = []
        urls.reserveCapacity(indices.count)
        var distances: [URL: Int] = [:]
        distances.reserveCapacity(indices.count)
        for index in indices {
            let url = playlist[index].url
            urls.append(url)
            // Keep the existing last-occurrence distance for duplicate URLs.
            distances[url] = abs(index - anchor)
        }
        self.urls = urls
        self.distances = distances
    }
}
