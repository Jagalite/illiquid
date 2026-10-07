import IlliquidPlayback

/// User-facing operations derived from the active runtime contract.
///
/// Views, commands, shortcuts, context menus, persistence restoration, and
/// Now Playing use this type instead of independently interpreting raw runtime
/// capability flags.
public enum PlayerOperation: CaseIterable, Equatable, Sendable {
    case openLocalFiles
    case openRemoteStream
    case seekRelative
    case seekExact
    case seekPreview
    case changePlaybackSpeed
    case selectAudioTrack
    case selectSubtitleTrack
    case loadExternalSubtitle
    case changeAudioDelay
    case changeSubtitleDelay
    case stepFrame
    case saveScreenshot
    case selectChapter
    case selectAudioDevice
    case changeVideoGeometry
    case changeVideoAdjustments
    case changeVideoFilters
    case changeHardwareDecodingPolicy
    case pictureInPicture

    fileprivate var requiredCapability: PlaybackCapabilities {
        switch self {
        case .openLocalFiles: .localFiles
        case .openRemoteStream: .remoteStreams
        case .seekRelative: .relativeSeeking
        case .seekExact: .exactSeeking
        case .seekPreview: .previewSeeking
        case .changePlaybackSpeed: .playbackSpeed
        case .selectAudioTrack: .audioTracks
        case .selectSubtitleTrack: .subtitleTracks
        case .loadExternalSubtitle: .externalSubtitles
        case .changeAudioDelay: .audioDelay
        case .changeSubtitleDelay: .subtitleDelay
        case .stepFrame: .frameStepping
        case .saveScreenshot: .screenshots
        case .selectChapter: .chapters
        case .selectAudioDevice: .audioDeviceSelection
        case .changeVideoGeometry: .videoGeometry
        case .changeVideoAdjustments: .videoAdjustments
        case .changeVideoFilters: .videoFilters
        case .changeHardwareDecodingPolicy: .hardwareDecodingPolicy
        case .pictureInPicture: .pictureInPicture
        }
    }
}

public struct PlayerCapabilityModel: Equatable, Sendable {
    public let capabilities: PlaybackCapabilities

    public init(capabilities: PlaybackCapabilities) {
        self.capabilities = capabilities
    }

    public func supports(_ operation: PlayerOperation) -> Bool {
        capabilities.contains(operation.requiredCapability)
    }

    /// A runtime that cannot apply playback speed must never display, persist,
    /// or publish a non-default value.
    public func sanitizedPlaybackSpeed(_ speed: Double) -> Double {
        supports(.changePlaybackSpeed) ? min(max(speed, 0.25), 4) : 1
    }
}
