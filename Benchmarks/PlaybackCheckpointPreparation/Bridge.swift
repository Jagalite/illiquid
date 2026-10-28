import Foundation
import IlliquidCore

// Compiled with the complete production checkpoint file as IlliquidPlayer.
// A separate driver can call the internal production type through this thin
// public boundary without making it part of the application's public API.
public struct CheckpointBenchmark {
    private let checkpoint: PlaybackCheckpoint

    public init(source: MediaSource, folder: URL?, playlist: [FolderPlaylistItem],
                index: Int?, position: TimeInterval, wasPaused: Bool,
                unshuffledPlaylistIDs: [FolderPlaylistItem.ID]?) {
        checkpoint = PlaybackCheckpoint(
            source: source, folder: folder, playlist: playlist, index: index,
            position: position, wasPaused: wasPaused,
            unshuffledPlaylistIDs: unshuffledPlaylistIDs
        )
    }

    @inline(never)
    public func record() -> PlaybackSessionRecord { checkpoint.record() }
}
