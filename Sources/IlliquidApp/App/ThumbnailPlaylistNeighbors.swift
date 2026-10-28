import Foundation
import IlliquidCore

/// The thumbnail priority window around the first matching playlist URL.
/// Keeps the URL array and distance map bounded to nine entries each.
struct ThumbnailPlaylistNeighbors {
    let urls: [URL]
    let distances: [URL: Int]

    init(items: [FolderPlaylistItem], current: URL?) {
        guard let current, let anchor = items.firstIndex(where: { $0.url == current }) else {
            urls = []
            distances = [:]
            return
        }

        let lower = max(0, anchor - 4)
        let upper = min(items.count, anchor + 5)
        var urls: [URL] = []
        var distances: [URL: Int] = [:]
        urls.reserveCapacity(upper - lower)
        for index in lower..<upper {
            let url = items[index].url
            urls.append(url)
            // Match the scheduler's existing last-occurrence distance when a
            // URL appears more than once inside the selected window.
            distances[url] = abs(index - anchor)
        }
        self.urls = urls
        self.distances = distances
    }
}
