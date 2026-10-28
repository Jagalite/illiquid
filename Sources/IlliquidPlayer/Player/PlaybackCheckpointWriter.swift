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
        guard let folder, !playlist.isEmpty, source.url.isFileURL,
              let sourceKey = NormalizedFileURL.persistenceKey(for: source.url)
        else { return nil }

        // The captured index normally identifies the source, but can be stale.
        // Validate it before skipping the membership scan; any match suffices.
        if let index, playlist.indices.contains(index),
           NormalizedFileURL.persistenceKey(for: playlist[index].url) == sourceKey {
            return folder
        }
        return playlist.contains {
            NormalizedFileURL.persistenceKey(for: $0.url) == sourceKey
        } ? folder : nil
    }
}
