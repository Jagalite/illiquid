import Foundation
import IlliquidCore

/// A thumbnail pass needs only the four playlist entries on either side of the
/// current video. Search the existing items without projecting every URL into
/// a temporary array, then retain only that bounded window.
struct ThumbnailPlaylistNeighbors: Equatable, Sendable {
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

        let lower = max(0, anchor - 4)
        let upper = min(playlist.count, anchor + 5)
        var urls: [URL] = []
        var distances: [URL: Int] = [:]
        urls.reserveCapacity(upper - lower)
        distances.reserveCapacity(upper - lower)
        for index in lower..<upper {
            let url = playlist[index].url
            urls.append(url)
            // Preserve the scheduler's last-occurrence distance if a restored
            // playlist contains duplicate URLs in this window.
            distances[url] = abs(index - anchor)
        }
        self.urls = urls
        self.distances = distances
    }
}
