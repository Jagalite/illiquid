import Foundation

// Comparison only: verbatim methods from PlaylistMutation.swift at
// 8c3cc3d4008d5d1b8d436bcf2d51d891382b6548 (blob 585e7a75bc1f2e080323509626482540d14d0b75).
// Do not use this implementation in production.
enum BaselinePlaylistMutation {
    public static func restoringOrder(
        _ items: [FolderPlaylistItem],
        ids: [FolderPlaylistItem.ID]
    ) -> [FolderPlaylistItem] {
        let unique = deduplicated(items)
        let byID = Dictionary(uniqueKeysWithValues: unique.map { ($0.id, $0) })
        var seen: Set<FolderPlaylistItem.ID> = []
        let restored = ids.compactMap { id -> FolderPlaylistItem? in
            guard seen.insert(id).inserted else { return nil }
            return byID[id]
        }
        return restored + unique.filter { !seen.contains($0.id) }
    }
    public static func deduplicated(_ items: [FolderPlaylistItem]) -> [FolderPlaylistItem] {
        var seen: Set<FolderPlaylistItem.ID> = []
        return items.filter { seen.insert($0.id).inserted }
    }
}
