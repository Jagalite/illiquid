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
            collectionFolder: folderContainingSource(),
            playlistItems: playlist,
            playlistIndex: index,
            position: position,
            wasPaused: wasPaused,
            unshuffledPlaylistIDs: unshuffledPlaylistIDs
        )
    }

    private func folderContainingSource() -> URL? {
        guard let folder, !playlist.isEmpty,
              let sourceKey = NormalizedFileURL.persistenceKey(for: source.url)
        else { return nil }

        // The captured index is only a hint: restored or changed playlists can
        // disagree with it. Verify identity before using the shortcut.
        // At zero the scan already checks this item first; avoid repeating
        // that normalization when the hinted item does not match.
        if let index, index > 0, playlist.indices.contains(index),
           NormalizedFileURL.persistenceKey(for: playlist[index].url) == sourceKey {
            return folder
        }

        // Normalize the invariant source once even when the hint is absent or
        // stale. Decoded playlist items still require their own normalization.
        return playlist.contains {
            NormalizedFileURL.persistenceKey(for: $0.url) == sourceKey
        } ? folder : nil
    }
}
