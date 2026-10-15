import Foundation
import IlliquidCore
import Observation

/// Narrow product projection for infrequently changing media-tool state. UI
/// consumers observe this store rather than reading private playback authority.
/// Clock ticks never re-publish an unchanged caption source or settings record.
@MainActor
@Observable
public final class PlaybackToolsStore {
    public internal(set) var mediaSettings = MediaPlaybackSettings()
    public internal(set) var canEditMediaSettings = false
    public internal(set) var defaultPlaybackSpeed = 1.0
    public internal(set) var remembersPlaybackHistory = true
    public internal(set) var captionSourceRequest: CaptionSourceRequest?

    public init() {}
}
