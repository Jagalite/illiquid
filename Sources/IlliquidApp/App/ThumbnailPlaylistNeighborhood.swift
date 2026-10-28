import Foundation
import IlliquidCore

/// The bounded playlist metadata needed by one background thumbnail pass.
/// Do not retain the playlist or a slice across the scheduler's async work.
struct ThumbnailPlaylistNeighborhood: Sendable {
    let urls: [URL]
    let distances: [URL: Int]

    init(playlist: [FolderPlaylistItem], current: URL?) {
        guard let current,
              let anchor = playlist.firstIndex(where: { $0.url == current })
        else {
            urls = []
            distances = [:]
            return
        }

        let bounds = max(0, anchor - 4)..<min(playlist.count, anchor + 5)
        var urls: [URL] = []
        var distances: [URL: Int] = [:]
        urls.reserveCapacity(bounds.count)
        distances.reserveCapacity(bounds.count)
        for index in bounds {
            let url = playlist[index].url
            urls.append(url)
            // Preserve the original last-occurrence distance for duplicate URLs.
            distances[url] = abs(index - anchor)
        }
        self.urls = urls
        self.distances = distances
    }
}
