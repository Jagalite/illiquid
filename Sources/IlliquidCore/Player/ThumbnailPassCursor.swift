import Foundation

/// Progress through a ranked candidate snapshot, retained across cancelled work
/// budgets. Advance BEFORE probing or decoding; a slow request must not become
/// the first request of every subsequent pass. This is not an I/O timeout.
public struct ThumbnailPassCursor: Sendable {
    public private(set) var lastAttemptedURL: URL?

    public init() {}

    public func batch(from ranked: [URL], limit: Int) -> [URL] {
        guard !ranked.isEmpty, limit > 0 else { return [] }
        let afterLast = lastAttemptedURL.flatMap { ranked.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
        let start = afterLast < ranked.count ? afterLast : 0
        return Array(ranked.dropFirst(start).prefix(min(limit, 64)))
    }

    public mutating func advance(past url: URL) {
        lastAttemptedURL = url.standardizedFileURL
    }

    public func hasRemaining(in ranked: [URL]) -> Bool {
        guard !ranked.isEmpty else { return false }
        guard let lastAttemptedURL, let index = ranked.firstIndex(of: lastAttemptedURL) else { return true }
        return index + 1 < ranked.count
    }
}
