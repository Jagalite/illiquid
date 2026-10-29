import Foundation
import IlliquidCore

/// The completed plan retains only nearby URLs and their ranking distances.
/// Search the playlist in place instead of projecting every item to a URL.
struct ThumbnailPlaylistNeighborhood {
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

        let bounds = max(playlist.startIndex, anchor - 4)..<min(playlist.endIndex, anchor + 5)
        var urls: [URL] = []
        var distances: [URL: Int] = [:]
        urls.reserveCapacity(bounds.count)
        distances.reserveCapacity(bounds.count)
        for index in bounds {
            let url = playlist[index].url
            urls.append(url)
            // Preserve the last distance for a duplicate URL in this window,
            // just as the scheduler's original dictionary assignments did.
            distances[url] = abs(index - anchor)
        }
        self.urls = urls
        self.distances = distances
    }
}
