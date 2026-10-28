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
        var probedIndex: Int?

        // Verify the captured index instead of trusting it. A singleton already
        // has a one-item scan and needs no separate probe.
        if playlist.count > 1, let index, playlist.indices.contains(index) {
            probedIndex = index
            if NormalizedFileURL.persistenceKey(for: playlist[index].url) == sourceKey {
                return folder
            }
        }

        // A stale or unsupported hinted item has already failed the same test.
        // Visit each remaining item at most once while retaining source identity.
        for candidateIndex in playlist.indices where candidateIndex != probedIndex {
            if NormalizedFileURL.persistenceKey(for: playlist[candidateIndex].url) == sourceKey {
                return folder
            }
        }
        return nil
    }
}
