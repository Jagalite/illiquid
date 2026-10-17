import Foundation

public struct FolderPlaylistItem: Identifiable, Codable, Hashable, Sendable {
    public let url: URL
    public let externalSubtitleURLs: [URL]
    public let dateAdded: Date?

    public var id: String {
        NormalizedFileURL.persistenceKey(for: url) ?? url.absoluteString
    }

    public init(
        url: URL,
        externalSubtitleURLs: [URL] = [],
        dateAdded: Date? = nil
    ) {
        self.url = NormalizedFileURL.normalize(url) ?? url
        self.externalSubtitleURLs = NaturalFilenameOrdering.sort(externalSubtitleURLs)
        self.dateAdded = dateAdded
    }

    /// Reads filesystem metadata; callers must keep this off the UI actor.
    public static func metadataDate(for url: URL) -> Date? {
        guard url.isFileURL else { return nil }
        let keys: Set<URLResourceKey> = [
            .addedToDirectoryDateKey,
            .creationDateKey,
            .contentModificationDateKey,
        ]
        let values = try? url.resourceValues(forKeys: keys)
        return values?.addedToDirectoryDate
            ?? values?.creationDate
            ?? values?.contentModificationDate
    }
}

/// An ephemeral playlist representing the currently opened folder.
public struct FolderPlaylist: Equatable, Sendable {
    public let folderURL: URL
    public let items: [FolderPlaylistItem]

    public var mediaURLs: [URL] {
        items.map(\.url)
    }

    public var isEmpty: Bool {
        items.isEmpty
    }

    public var count: Int {
        items.count
    }

    public init(folderURL: URL, items: [FolderPlaylistItem]) {
        self.folderURL = NormalizedFileURL.normalize(folderURL) ?? folderURL
        self.items = items.sorted {
            NaturalFilenameOrdering.areInIncreasingOrder($0.url, $1.url)
        }
    }

    public subscript(index: Int) -> FolderPlaylistItem {
        items[index]
    }

    public func index(of mediaURL: URL) -> Int? {
        items.firstIndex { NormalizedFileURL.representsSameFile($0.url, mediaURL) }
    }

    /// Returns the last watched file when it is still in this playlist, otherwise
    /// the first item. Empty playlists return `nil`.
    public func initialIndex(restoring lastWatchedFile: URL?) -> Int? {
        guard !items.isEmpty else {
            return nil
        }

        if let lastWatchedFile, let restoredIndex = index(of: lastWatchedFile) {
            return restoredIndex
        }

        return items.startIndex
    }

    public func nextIndex(after index: Int) -> Int? {
        let candidate = index + 1
        return items.indices.contains(candidate) ? candidate : nil
    }

    public func previousIndex(before index: Int) -> Int? {
        let candidate = index - 1
        return items.indices.contains(candidate) ? candidate : nil
    }
}
