import Foundation

public struct PlaybackPreferences: Codable, Equatable, Sendable {
    public static let standard = PlaybackPreferences(
        volume: 100,
        isMuted: false,
        playbackSpeed: 1,
        isSidebarVisible: true,
        repeatMode: .off,
        isShuffleEnabled: false,
        hardwareDecodingPolicy: .automatic,
        preferredAudioOutputDeviceID: nil
    )

    public var remembersPlaybackHistory: Bool
    public var restoresSessionPaused: Bool
    public var volume: Double
    public var isMuted: Bool
    public var playbackSpeed: Double
    public var isSidebarVisible: Bool
    public var repeatMode: PlaybackRepeatMode
    public var isShuffleEnabled: Bool
    public var hardwareDecodingPolicy: HardwareDecodingPolicy
    public var trackSelection: TrackSelectionPreferences
    public var subtitleFallbackEncoding: SubtitleFallbackEncoding
    public var preferredAudioOutputDeviceID: String?

    public init(
        volume: Double,
        isMuted: Bool,
        playbackSpeed: Double,
        isSidebarVisible: Bool,
        repeatMode: PlaybackRepeatMode = .off,
        isShuffleEnabled: Bool = false,
        hardwareDecodingPolicy: HardwareDecodingPolicy = .automatic,
        preferredAudioOutputDeviceID: String? = nil,
        subtitleFallbackEncoding: SubtitleFallbackEncoding = .unicodeOnly,
        trackSelection: TrackSelectionPreferences = .init(),
        remembersPlaybackHistory: Bool = true,
        restoresSessionPaused: Bool = true
    ) {
        self.remembersPlaybackHistory = remembersPlaybackHistory
        self.restoresSessionPaused = restoresSessionPaused
        self.trackSelection = trackSelection.sanitized()
        self.subtitleFallbackEncoding = subtitleFallbackEncoding
        self.volume = Self.validVolume(volume)
        self.isMuted = isMuted
        self.playbackSpeed = Self.validPlaybackSpeed(playbackSpeed)
        self.isSidebarVisible = isSidebarVisible
        self.repeatMode = repeatMode
        self.isShuffleEnabled = isShuffleEnabled
        self.hardwareDecodingPolicy = hardwareDecodingPolicy
        self.preferredAudioOutputDeviceID = Self.validAudioOutputDeviceID(
            preferredAudioOutputDeviceID
        )
    }

    public func sanitized() -> PlaybackPreferences {
        PlaybackPreferences(
            volume: volume,
            isMuted: isMuted,
            playbackSpeed: playbackSpeed,
            isSidebarVisible: isSidebarVisible,
            repeatMode: repeatMode,
            isShuffleEnabled: isShuffleEnabled,
            hardwareDecodingPolicy: hardwareDecodingPolicy,
            preferredAudioOutputDeviceID: preferredAudioOutputDeviceID,
            subtitleFallbackEncoding: subtitleFallbackEncoding,
            trackSelection: trackSelection,
            remembersPlaybackHistory: remembersPlaybackHistory,
            restoresSessionPaused: restoresSessionPaused
        )
    }

    private static func validVolume(_ volume: Double) -> Double {
        guard volume.isFinite else {
            return standardVolume
        }
        return min(max(volume, 0), 100)
    }

    private static func validPlaybackSpeed(_ speed: Double) -> Double {
        guard speed.isFinite, speed > 0 else {
            return standardPlaybackSpeed
        }
        return min(max(speed, 0.25), 4)
    }

    private static let standardVolume = 100.0
    private static let standardPlaybackSpeed = 1.0

    private static func validAudioOutputDeviceID(_ id: String?) -> String? {
        guard let id = id?.trimmingCharacters(in: .whitespacesAndNewlines),
              !id.isEmpty,
              id != "auto"
        else {
            return nil
        }
        return id
    }

    private enum CodingKeys: String, CodingKey {
        case remembersPlaybackHistory
        case restoresSessionPaused
        case volume
        case isMuted
        case playbackSpeed
        case isSidebarVisible
        case repeatMode
        case isShuffleEnabled
        case hardwareDecodingPolicy
        case trackSelection
        case subtitleFallbackEncoding
        case preferredAudioOutputDeviceID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            volume: try container.decodeIfPresent(Double.self, forKey: .volume) ?? Self.standardVolume,
            isMuted: try container.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false,
            playbackSpeed: try container.decodeIfPresent(Double.self, forKey: .playbackSpeed) ?? Self.standardPlaybackSpeed,
            isSidebarVisible: try container.decodeIfPresent(Bool.self, forKey: .isSidebarVisible) ?? true,
            repeatMode: try container.decodeIfPresent(
                PlaybackRepeatMode.self,
                forKey: .repeatMode
            ) ?? .off,
            isShuffleEnabled: try container.decodeIfPresent(
                Bool.self,
                forKey: .isShuffleEnabled
            ) ?? false,
            hardwareDecodingPolicy: try container.decodeIfPresent(
                HardwareDecodingPolicy.self,
                forKey: .hardwareDecodingPolicy
            ) ?? .automatic,
            preferredAudioOutputDeviceID: try container.decodeIfPresent(
                String.self,
                forKey: .preferredAudioOutputDeviceID
            ),
            subtitleFallbackEncoding: try container.decodeIfPresent(
                SubtitleFallbackEncoding.self, forKey: .subtitleFallbackEncoding
            ) ?? .unicodeOnly,
            trackSelection: try container.decodeIfPresent(TrackSelectionPreferences.self, forKey: .trackSelection) ?? .init(),
            remembersPlaybackHistory: try container.decodeIfPresent(Bool.self, forKey: .remembersPlaybackHistory) ?? true,
            restoresSessionPaused: try container.decodeIfPresent(Bool.self, forKey: .restoresSessionPaused) ?? true
        )
    }
}
