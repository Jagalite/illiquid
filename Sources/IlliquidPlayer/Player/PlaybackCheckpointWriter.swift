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
        // A standalone playlist cannot retain a collection folder. When there
        // is a folder, prepare the invariant source identity once for the scan.
        let collectionFolder: URL?
        if let folder, !playlist.isEmpty, source.url.isFileURL,
           let sourceKey = NormalizedFileURL.persistenceKey(for: source.url),
           playlist.contains(where: {
               NormalizedFileURL.persistenceKey(for: $0.url) == sourceKey
           }) {
            collectionFolder = folder
        } else {
            collectionFolder = nil
        }
        return PlaybackSessionRecord(
            source: source,
            collectionFolder: collectionFolder,
            playlistItems: playlist,
            playlistIndex: index,
            position: position,
            wasPaused: wasPaused,
            unshuffledPlaylistIDs: unshuffledPlaylistIDs
        )
    }
}
