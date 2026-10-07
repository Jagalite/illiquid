import Foundation

/// Product-level playback intents. Backend-specific command names and argument
/// encoding are intentionally defined outside IlliquidCore.
public enum PlaybackCommand: Equatable, Sendable {
    case load(MediaSource)
    case stop
    case seekRelative(TimeInterval)
    case seekAbsolute(TimeInterval)
    case seekAbsolutePreview(TimeInterval)
    case frameStepForward
    case frameStepBackward
    case addSubtitle(URL, select: Bool)
    case screenshot(URL, includeSubtitles: Bool)
    case addVideoFilter(VideoFilterPreset)
    case removeVideoFilter(VideoFilterPreset)
}
