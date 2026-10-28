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
        // A standalone playlist cannot retain a collection folder. Otherwise,
        // normalize the source once, only after a supported item needs it.
        var collectionFolder: URL? = nil
        if let folder, source.url.isFileURL {
            var sourceKey: String?
            for item in playlist {
                guard let itemKey = NormalizedFileURL.persistenceKey(for: item.url) else { continue }
                if sourceKey == nil {
                    sourceKey = NormalizedFileURL.persistenceKey(for: source.url)
                }
                guard let sourceKey else { break }
                if itemKey == sourceKey {
                    collectionFolder = folder
                    break
                }
            }
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
