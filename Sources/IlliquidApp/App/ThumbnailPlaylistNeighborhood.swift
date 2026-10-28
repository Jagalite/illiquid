import Foundation
import IlliquidCore

/// The bounded playlist contribution to a background thumbnail pass.
enum ThumbnailPlaylistNeighborhood {
    struct Plan: Equatable, Sendable {
        let urls: [URL]
        let distances: [URL: Int]
    }

    static func plan(items: [FolderPlaylistItem], current: URL?) -> Plan {
        // Match the original URL equality and first-occurrence behavior, including
        // decoded items that did not pass through the normalizing initializer.
        guard let current, let anchor = items.firstIndex(where: { $0.url == current }) else {
            return Plan(urls: [], distances: [:])
        }
        let indices = max(0, anchor - 4)..<min(items.count, anchor + 5)
        var urls: [URL] = []
        urls.reserveCapacity(indices.count)
        var distances: [URL: Int] = [:]
        for index in indices {
            let url = items[index].url
            urls.append(url)
            // Preserve the last distance when a URL occurs more than once.
            distances[url] = abs(index - anchor)
        }
        // Keep only these at-most-nine URLs after the synchronous planning call;
        // the scheduler does not retain a complete item snapshot across awaits.
        return Plan(urls: urls, distances: distances)
    }
}
