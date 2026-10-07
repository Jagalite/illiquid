import Foundation

public struct PlaybackCapabilities: OptionSet, Codable, Equatable, Sendable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public static let localFiles = Self(rawValue: 1 << 0)
    public static let remoteStreams = Self(rawValue: 1 << 1)
    public static let relativeSeeking = Self(rawValue: 1 << 2)
    public static let exactSeeking = Self(rawValue: 1 << 3)
    public static let previewSeeking = Self(rawValue: 1 << 4)
    public static let playbackSpeed = Self(rawValue: 1 << 5)
    public static let audioTracks = Self(rawValue: 1 << 6)
    public static let subtitleTracks = Self(rawValue: 1 << 7)
    public static let externalSubtitles = Self(rawValue: 1 << 8)
    public static let audioDelay = Self(rawValue: 1 << 9)
    public static let subtitleDelay = Self(rawValue: 1 << 10)
    public static let frameStepping = Self(rawValue: 1 << 11)
    public static let screenshots = Self(rawValue: 1 << 12)
    public static let chapters = Self(rawValue: 1 << 13)
    public static let audioDeviceSelection = Self(rawValue: 1 << 14)
    public static let videoGeometry = Self(rawValue: 1 << 21)
    public static let videoAdjustments = Self(rawValue: 1 << 15)
    public static let videoFilters = Self(rawValue: 1 << 16)
    public static let hardwareDecodingPolicy = Self(rawValue: 1 << 17)
    public static let nativeSampleBufferSurface = Self(rawValue: 1 << 18)
    public static let pictureInPicture = Self(rawValue: 1 << 20)
}

public enum SeekMode: Equatable, Sendable {
    case relative
    case absoluteExact
    case absolutePreview
}

public struct UnsupportedPlaybackCapabilityError: LocalizedError, Equatable, Sendable {
    public let operation: String

    public init(_ operation: String) {
        self.operation = operation
    }

    public var errorDescription: String? {
        "Native playback does not support \(operation)."
    }
}
