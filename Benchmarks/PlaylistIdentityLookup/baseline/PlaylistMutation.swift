import Foundation

public enum PlaylistOpenMode: String, Codable, Equatable, Sendable {
    case replace
    case append
}

public enum PlaylistSortOrder: String, Codable, CaseIterable, Sendable {
    case name
    case dateAdded
}

public enum PlaybackRepeatMode: String, Codable, CaseIterable, Sendable {
    case off
    case all
    case one
}

public enum PlaylistMutation {
    /// Keep surviving base-order entries, then append newly added entries in
    /// their current order. Removed entries never return when shuffle is off.
    public static func restoringOrder(
        _ items: [FolderPlaylistItem],
        ids: [FolderPlaylistItem.ID]
    ) -> [FolderPlaylistItem] {
        guard !items.isEmpty else { return [] }
        guard !ids.isEmpty else { return deduplicated(items) }

        // Compute each identity once, keeping the first item's complete metadata.
        // Re-reading item.id in separate deduplication, indexing and filtering
        // passes repeats URL normalization on the main-actor shuffle path.
        var byID: [FolderPlaylistItem.ID: FolderPlaylistItem] = [:]
        var currentOrder: [FolderPlaylistItem.ID] = []
        for item in items {
            let id = item.id
            guard byID[id] == nil else { continue }
            byID[id] = item
            currentOrder.append(id)
        }

        var restored: [FolderPlaylistItem] = []
        restored.reserveCapacity(byID.count)
        for id in ids {
            if let item = byID.removeValue(forKey: id) { restored.append(item) }
        }
        // Taking entries out of the map also deduplicates saved IDs. Remaining
        // entries are new additions and must retain their current relative order.
        for id in currentOrder {
            if let item = byID.removeValue(forKey: id) { restored.append(item) }
        }
        return restored
    }

    public static func deduplicatedSubtitleURLs(_ urls: [URL]) -> [URL] {
        var seen: Set<String> = []
        return urls.filter { url in
            let key = NormalizedFileURL.persistenceKey(for: url) ?? url.absoluteString
            return seen.insert(key).inserted
        }
    }

    public static func deduplicated(_ items: [FolderPlaylistItem]) -> [FolderPlaylistItem] {
        var seen: Set<FolderPlaylistItem.ID> = []
        return items.filter { seen.insert($0.id).inserted }
    }

    public static func sorted(
        _ items: [FolderPlaylistItem],
        by order: PlaylistSortOrder,
        ascending: Bool
    ) -> [FolderPlaylistItem] {
        func precedes(_ lhs: FolderPlaylistItem, _ rhs: FolderPlaylistItem) -> Bool {
            switch order {
            case .name:
                let comparison = lhs.url.lastPathComponent.localizedStandardCompare(
                    rhs.url.lastPathComponent
                )
                if comparison == .orderedSame { return lhs.id < rhs.id }
                return comparison == .orderedAscending
            case .dateAdded:
                switch (lhs.dateAdded, rhs.dateAdded) {
                case let (left?, right?) where left != right:
                    return left < right
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                default:
                    return NaturalFilenameOrdering.areInIncreasingOrder(
                        lhs.url,
                        rhs.url
                    )
                }
            }
        }
        return items.sorted { lhs, rhs in
            ascending ? precedes(lhs, rhs) : precedes(rhs, lhs)
        }
    }

    public static func indexPreservingCurrentIdentity(
        currentURL: URL?,
        fallbackIndex: Int?,
        in items: [FolderPlaylistItem]
    ) -> Int? {
        if let currentURL,
           let index = items.firstIndex(where: {
               NormalizedFileURL.representsSameFile($0.url, currentURL)
           })
        {
            return index
        }
        if let fallbackIndex, items.indices.contains(fallbackIndex) {
            return fallbackIndex
        }
        return items.isEmpty ? nil : items.startIndex
    }
}
