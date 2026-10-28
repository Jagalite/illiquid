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
        // The source identity is invariant across this scan. Keep normalizing
        // each item: decoded playlists can contain unprepared URLs.
        let belongsToFolder: Bool
        if source.url.isFileURL, !playlist.isEmpty,
           let sourceKey = NormalizedFileURL.persistenceKey(for: source.url) {
            belongsToFolder = playlist.contains {
                NormalizedFileURL.persistenceKey(for: $0.url) == sourceKey
            }
        } else {
            belongsToFolder = false
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
