import Foundation

/// A cheap, path-independent filesystem version, not a hash of the entire video.
/// Device numbers are excluded because a remount may assign a different one.
public struct MediaContentVersion: Codable, Equatable, Sendable {
    public let fileIdentifier: UInt64
    public let byteCount: Int64
    public let modificationSeconds: Int64
    public let modificationNanoseconds: Int64
    public let creationSeconds: Int64
    public let creationNanoseconds: Int64

    public init(fileIdentifier: UInt64, byteCount: Int64,
                modificationSeconds: Int64, modificationNanoseconds: Int64,
                creationSeconds: Int64, creationNanoseconds: Int64) {
        self.fileIdentifier = fileIdentifier
        self.byteCount = byteCount
        self.modificationSeconds = modificationSeconds
        self.modificationNanoseconds = modificationNanoseconds
        self.creationSeconds = creationSeconds
        self.creationNanoseconds = creationNanoseconds
    }
}

public enum MediaContentVersionDisposition: Equatable, Sendable {
    case firstObservation, unchanged, changed
}

/// Preserved when a different content version replaces a path. Applicability
/// changes must not silently delete the previous movie's history.
public struct ReplacedMediaHistory: Codable, Equatable, Sendable {
    public let version: MediaContentVersion
    public var position: TimeInterval?
    public var duration: TimeInterval?
    public var isCompleted: Bool
    public var mediaSettings: MediaPlaybackSettings?
}
