import Foundation
import IlliquidCore

/// The bounded playlist input to one background thumbnail pass.
/// Own the selected URLs so an asynchronous pass never retains a playlist slice.
struct ThumbnailPlaylistNeighborhood {
    let urls: [URL]
    let distances: [URL: Int]

    init(playlist: [FolderPlaylistItem], current: URL?) {
        guard let current, let anchor = playlist.firstIndex(where: { $0.url == current }) else {
            urls = []
            distances = [:]
            return
        }

        let lower = max(playlist.startIndex, anchor - 4)
        let upper = min(playlist.endIndex, anchor + 5)
        var urls: [URL] = []
        var distances: [URL: Int] = [:]
        urls.reserveCapacity(upper - lower)
        distances.reserveCapacity(upper - lower)
        for index in lower..<upper {
            let url = playlist[index].url
            urls.append(url)
            // Keep the original last-occurrence distance for duplicate URLs.
            distances[url] = abs(index - anchor)
        }
        self.urls = urls
        self.distances = distances
    }
}
