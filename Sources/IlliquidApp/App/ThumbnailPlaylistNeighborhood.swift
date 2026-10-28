import Foundation
import IlliquidCore

/// Copy only the bounded neighborhood before the background pass can suspend.
/// Neither the complete playlist nor a slice of its storage escapes this lookup.
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
        let lower = max(0, anchor - 4)
        let upper = min(playlist.count, anchor + 5)
        var urls: [URL] = []
        var distances: [URL: Int] = [:]
        urls.reserveCapacity(upper - lower)
        distances.reserveCapacity(upper - lower)
        for index in lower..<upper {
            let url = playlist[index].url
            urls.append(url)
            // Preserve the existing last-occurrence distance for duplicate URLs.
            distances[url] = abs(index - anchor)
        }
        self.urls = urls
        self.distances = distances
    }
}
