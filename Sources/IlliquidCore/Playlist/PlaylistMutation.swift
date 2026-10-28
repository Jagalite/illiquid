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

    /// Restore checkpoint identities without rebuilding playlist items or
    /// normalizing each surviving URL a second time.
    public static func restoringIdentityOrder(
        _ items: [FolderPlaylistItem],
        ids: [FolderPlaylistItem.ID]
    ) -> [FolderPlaylistItem.ID] {
        guard !items.isEmpty else { return [] }

        var remaining: Set<FolderPlaylistItem.ID> = []
        var currentOrder: [FolderPlaylistItem.ID] = []
        for item in items {
            let id = item.id
            if remaining.insert(id).inserted { currentOrder.append(id) }
        }
        guard !ids.isEmpty else { return currentOrder }

        var restored: [FolderPlaylistItem.ID] = []
        restored.reserveCapacity(remaining.count)
        for id in ids {
            // String equality admits different Unicode spellings. Return the
            // current item's stored identity, not the saved key's representation.
            if let currentID = remaining.remove(id) { restored.append(currentID) }
        }
        for id in currentOrder {
            if let currentID = remaining.remove(id) { restored.append(currentID) }
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
        guard !items.isEmpty else { return [] }
        guard items.count > 1 else { return uniqueResult(items) }
        var seen: Set<FolderPlaylistItem.ID> = []
        for index in items.indices {
            if !seen.insert(items[index].id).inserted {
                // Defer the duplicate-result allocation until the first repeat,
                // preserving each first item's complete metadata and order.
                var result = Array(items[..<index])
                for item in items[(index + 1)...] where seen.insert(item.id).inserted {
                    result.append(item)
                }
                return result
            }
        }
        return uniqueResult(items)
    }

    private static func uniqueResult(_ items: [FolderPlaylistItem]) -> [FolderPlaylistItem] {
        let capacity = items.capacity
        // Ordinary geometric growth and small buffers are worth sharing. A
        // heavily reduced playlist should not keep its former large allocation
        // alive after its caller releases the input.
        guard capacity > 64, items.count < capacity / 2 else { return items }
        var compact: [FolderPlaylistItem] = []
        compact.reserveCapacity(items.count)
        compact.append(contentsOf: items)
        return compact
    }

    public static func sorted(
        _ items: [FolderPlaylistItem],
        by order: PlaylistSortOrder,
        ascending: Bool
    ) -> [FolderPlaylistItem] {
        guard items.count > 1 else { return items }

        // Keep keys local to this sort. Date ordering needs filenames only
        // when dates tie, and normalized identities only break name-order ties.
        var filenames: [String?] = order == .name
            ? items.map { $0.url.lastPathComponent } : []
        var identities: [FolderPlaylistItem.ID?] = []

        func filename(at index: Int) -> String {
            if filenames.isEmpty {
                filenames = Array(repeating: nil, count: items.count)
            }
            if let cached = filenames[index] { return cached }
            let value = items[index].url.lastPathComponent
            filenames[index] = value
            return value
        }

        func identity(at index: Int) -> FolderPlaylistItem.ID {
            if identities.isEmpty {
                identities = Array(repeating: nil, count: items.count)
            }
            if let cached = identities[index] { return cached }
            let value = items[index].id
            identities[index] = value
            return value
        }

        func precedes(_ lhs: Int, _ rhs: Int) -> Bool {
            if order == .dateAdded {
                switch (items[lhs].dateAdded, items[rhs].dateAdded) {
                case let (left?, right?) where left != right:
                    return left < right
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                default:
                    break
                }
            }

            let comparison = filename(at: lhs).localizedStandardCompare(filename(at: rhs))
            guard comparison == .orderedSame else { return comparison == .orderedAscending }
            switch order {
            case .name:
                return identity(at: lhs) < identity(at: rhs)
            case .dateAdded:
                // Date ties use the original literal paths, whereas name ties
                // use normalized identities. These are distinct contracts.
                return items[lhs].url.path.compare(items[rhs].url.path, options: [.literal]) == .orderedAscending
            }
        }

        // Move indices during the stable sort, then retain each original item
        // and its subtitle metadata in the result. Complete ties stay in order.
        let indices = items.indices.sorted { lhs, rhs in
            ascending ? precedes(lhs, rhs) : precedes(rhs, lhs)
        }
        return indices.map { items[$0] }
    }

    public static func indexPreservingCurrentIdentity(
        currentURL: URL?,
        fallbackIndex: Int?,
        in items: [FolderPlaylistItem]
    ) -> Int? {
        // An empty playlist has no selection; a singleton always selects its
        // only item regardless of the current URL or fallback.
        guard items.count > 1 else { return items.indices.first }
        // The target is invariant for this scan; normalize it once, just as
        // each candidate is normalized once when it is visited.
        if let currentURL,
           let currentKey = NormalizedFileURL.persistenceKey(for: currentURL),
           let index = items.firstIndex(where: {
               NormalizedFileURL.persistenceKey(for: $0.url) == currentKey
           })
        {
            return index
        }
        if let fallbackIndex, items.indices.contains(fallbackIndex) {
            return fallbackIndex
        }
        return items.startIndex
    }
}
