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
        return PlaybackSessionRecord(
            source: source,
            collectionFolder: belongsToFolder ? folder : nil,
            playlistItems: playlist,
            playlistIndex: index,
            position: position,
            wasPaused: wasPaused,
            unshuffledPlaylistIDs: unshuffledPlaylistIDs
        )
    }

    private var belongsToFolder: Bool {
        guard folder != nil, source.url.isFileURL, !playlist.isEmpty else { return false }

        // The captured index is a hint, not an identity guarantee: restored or
        // edited playlists can leave it stale. Validate the selected item first
        // so ordinary progress checkpoints do not scan the entire playlist.
        if let index, playlist.indices.contains(index),
           NormalizedFileURL.representsSameFile(playlist[index].url, source.url) {
            return true
        }

        // Missing or stale indices retain the same membership behavior. The
        // source identity is invariant, so compute it only once for this scan.
        guard let sourceKey = NormalizedFileURL.persistenceKey(for: source.url)
        else { return false }
        return playlist.contains {
            NormalizedFileURL.persistenceKey(for: $0.url) == sourceKey
        }
    }
}
