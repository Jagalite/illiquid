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
        let belongsToFolder: Bool
        if folder == nil || !source.url.isFileURL {
            belongsToFolder = false
        } else if let index, playlist.indices.contains(index),
                  NormalizedFileURL.representsSameFile(playlist[index].url, source.url) {
            // The captured index is only a hint; a matching identity proves
            // membership without scanning all preceding playlist items.
            belongsToFolder = true
        } else {
            // A stale or missing index must retain the original membership rule.
            belongsToFolder = playlist.contains {
                NormalizedFileURL.representsSameFile($0.url, source.url)
            }
        }
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
}
