import Foundation
import IlliquidCore

enum PlaybackCheckpointMutation: Sendable {
    case save(PlaybackCheckpoint)
    case clear

    func apply(to store: any PlaybackSessionStoring) throws {
        switch self {
        case let .save(checkpoint): try store.save(checkpoint.record())
        case .clear: try store.clear()
        }
    }
}

/// Captures values on the main actor; playlist identity work, encoding and I/O
/// happen on the writer queue. The latest pending checkpoint replaces older ones.
struct PlaybackCheckpoint: Sendable {
    let source: MediaSource
    let folder: URL?
    let playlist: [FolderPlaylistItem]
    let index: Int?
    let position: TimeInterval
    let wasPaused: Bool
    let unshuffledPlaylistIDs: [FolderPlaylistItem.ID]?

    func record() -> PlaybackSessionRecord {
        PlaybackSessionRecord(
            source: source,
            collectionFolder: matchingCollectionFolder(),
            playlistItems: playlist,
            playlistIndex: index,
            position: position,
            wasPaused: wasPaused,
            unshuffledPlaylistIDs: unshuffledPlaylistIDs
        )
    }

    private func matchingCollectionFolder() -> URL? {
        guard let folder, !playlist.isEmpty, source.url.isFileURL else { return nil }
        var sourceKey: String?
        var probedIndex: Int?

        // The captured index is a hint, not proof of membership. A singleton
        // already has a one-item scan and needs no separate probe.
        if playlist.count > 1, let index, playlist.indices.contains(index) {
            probedIndex = index
            if let itemKey = NormalizedFileURL.persistenceKey(for: playlist[index].url) {
                guard let key = NormalizedFileURL.persistenceKey(for: source.url) else { return nil }
                sourceKey = key
                if itemKey == key { return folder }
            }
        }

        // Skip an already probed item. Resolve the source only after a supported
        // item is found, so all-unsupported playlists avoid that work entirely.
        for candidateIndex in playlist.indices where candidateIndex != probedIndex {
            guard let itemKey = NormalizedFileURL.persistenceKey(for: playlist[candidateIndex].url)
            else { continue }
            if sourceKey == nil {
                sourceKey = NormalizedFileURL.persistenceKey(for: source.url)
            }
            guard let sourceKey else { return nil }
            if itemKey == sourceKey { return folder }
        }
        return nil
    }
}
