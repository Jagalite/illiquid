import IlliquidCore

public struct PlaybackSessionID: RawRepresentable, Codable, Hashable, Comparable, Sendable {
  public let rawValue: UInt64
  public init(rawValue: UInt64) { self.rawValue = rawValue }
  public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct PlaybackGenerationID: RawRepresentable, Codable, Hashable, Comparable, Sendable {
  public let rawValue: UInt64
  public init(rawValue: UInt64) { self.rawValue = rawValue }
  public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct ApplicationEpochID: RawRepresentable, Codable, Hashable, Comparable, Sendable {
  public let rawValue: UInt64
  public init(rawValue: UInt64) { self.rawValue = rawValue }
  public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct PlaybackOperationID: RawRepresentable, Codable, Hashable, Comparable, Sendable {
  public let rawValue: UInt64
  public init(rawValue: UInt64) { self.rawValue = rawValue }
  public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct PlaybackEffectID: RawRepresentable, Codable, Hashable, Comparable, Sendable {
  public let rawValue: UInt64
  public init(rawValue: UInt64) { self.rawValue = rawValue }
  public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct PlaybackSubscriptionID: RawRepresentable, Codable, Hashable, Comparable, Sendable {
  public let rawValue: UInt64
  public init(rawValue: UInt64) { self.rawValue = rawValue }
  public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct ResourceLeaseID: RawRepresentable, Codable, Hashable, Comparable, Sendable {
  public let rawValue: UInt64
  public init(rawValue: UInt64) { self.rawValue = rawValue }
  public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct ResourceBatchLeaseID: RawRepresentable, Codable, Hashable, Comparable, Sendable {
  public let rawValue: UInt64
  public init(rawValue: UInt64) { self.rawValue = rawValue }
  public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct ResourceBorrowID: RawRepresentable, Codable, Hashable, Comparable, Sendable {
  public let rawValue: UInt64
  public init(rawValue: UInt64) { self.rawValue = rawValue }
  public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct TrackRevisionID: RawRepresentable, Codable, Hashable, Comparable, Sendable {
  public let rawValue: UInt64
  public init(rawValue: UInt64) { self.rawValue = rawValue }
  public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct DecoderRevisionID: RawRepresentable, Codable, Hashable, Comparable, Sendable {
  public let rawValue: UInt64
  public init(rawValue: UInt64) { self.rawValue = rawValue }
  public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct MediaFormatRevisionID: RawRepresentable, Codable, Hashable, Comparable, Sendable {
  public let rawValue: UInt64
  public init(rawValue: UInt64) { self.rawValue = rawValue }
  public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct PresentationRevisionID: RawRepresentable, Codable, Hashable, Comparable, Sendable {
  public let rawValue: UInt64
  public init(rawValue: UInt64) { self.rawValue = rawValue }
  public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct PresentationGraphRevisionID: RawRepresentable, Codable, Hashable, Comparable, Sendable
{
  public let rawValue: UInt64
  public init(rawValue: UInt64) { self.rawValue = rawValue }
  public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct PresentationMembershipRevisionID: RawRepresentable, Codable, Hashable, Comparable,
  Sendable
{
  public let rawValue: UInt64
  public init(rawValue: UInt64) { self.rawValue = rawValue }
  public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct SubtitleRevisionID: RawRepresentable, Codable, Hashable, Comparable, Sendable {
  public let rawValue: UInt64
  public init(rawValue: UInt64) { self.rawValue = rawValue }
  public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct OverlayRevisionID: RawRepresentable, Codable, Hashable, Comparable, Sendable {
  public let rawValue: UInt64
  public init(rawValue: UInt64) { self.rawValue = rawValue }
  public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct SurfaceRevisionID: RawRepresentable, Codable, Hashable, Comparable, Sendable {
  public let rawValue: UInt64
  public init(rawValue: UInt64) { self.rawValue = rawValue }
  public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct DisplayRevisionID: RawRepresentable, Codable, Hashable, Comparable, Sendable {
  public let rawValue: UInt64
  public init(rawValue: UInt64) { self.rawValue = rawValue }
  public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct PictureInPictureControllerID: RawRepresentable, Codable, Hashable, Comparable,
  Sendable
{
  public let rawValue: UInt64
  public init(rawValue: UInt64) { self.rawValue = rawValue }
  public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct SurfaceID: RawRepresentable, Codable, Hashable, Comparable, Sendable {
  public let rawValue: UInt64
  public init(rawValue: UInt64) { self.rawValue = rawValue }
  public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public enum ResourceLeaseKey: Codable, Hashable, Sendable {
  case single(ResourceLeaseID)
  case batch(ResourceBatchLeaseID)
}

public enum PlaybackStreamKind: String, Codable, Hashable, Sendable {
  case video
  case audio
  case subtitle
  case attachment
  case data
  case unknown
}

public struct PlaybackStreamID: Codable, Hashable, Sendable {
  public let kind: PlaybackStreamKind
  public let demuxIndex: Int32

  public init(kind: PlaybackStreamKind, demuxIndex: Int32) {
    self.kind = kind
    self.demuxIndex = demuxIndex
  }
}

public struct PlaybackTrackID: Codable, Hashable, Sendable {
  public let kind: MediaTrackKind
  public let mediaTrackID: Int64

  public init(kind: MediaTrackKind, mediaTrackID: Int64) {
    self.kind = kind
    self.mediaTrackID = mediaTrackID
  }
}

public struct PlaybackRevisionSet: Codable, Hashable, Sendable {
  public var track: TrackRevisionID?
  public var decoder: DecoderRevisionID?
  public var videoFormat: MediaFormatRevisionID?
  public var audioFormat: MediaFormatRevisionID?
  public var presentation: PresentationRevisionID?
  public var presentationGraph: PresentationGraphRevisionID?
  public var presentationMembership: PresentationMembershipRevisionID?
  public var subtitle: SubtitleRevisionID?
  public var overlay: OverlayRevisionID?
  public var surface: SurfaceRevisionID?

  public init(
    track: TrackRevisionID? = nil,
    decoder: DecoderRevisionID? = nil,
    videoFormat: MediaFormatRevisionID? = nil,
    audioFormat: MediaFormatRevisionID? = nil,
    presentation: PresentationRevisionID? = nil,
    presentationGraph: PresentationGraphRevisionID? = nil,
    presentationMembership: PresentationMembershipRevisionID? = nil,
    subtitle: SubtitleRevisionID? = nil,
    overlay: OverlayRevisionID? = nil,
    surface: SurfaceRevisionID? = nil
  ) {
    self.track = track
    self.decoder = decoder
    self.videoFormat = videoFormat
    self.audioFormat = audioFormat
    self.presentation = presentation
    self.presentationGraph = presentationGraph
    self.presentationMembership = presentationMembership
    self.subtitle = subtitle
    self.overlay = overlay
    self.surface = surface
  }
}

public struct ValidMediaTime: Codable, Hashable, Sendable {
  public let value: Int64
  public let timescale: Int32

  public init?(value: Int64, timescale: Int32) {
    guard timescale > 0 else { return nil }
    self.value = value
    self.timescale = timescale
  }
}

public enum TimestampFault: String, Codable, Hashable, Sendable {
  case zeroTimescale
  case nonFiniteSource
  case overflow
  case discontinuity
  case unmappable
}

public enum MediaTimestamp: Codable, Hashable, Sendable {
  case valid(ValidMediaTime)
  case unknown
  case invalid(TimestampFault)
}

public struct MediaDuration: Codable, Hashable, Comparable, Sendable {
  public let microseconds: UInt64
  public init(microseconds: UInt64) { self.microseconds = microseconds }
  public static func < (lhs: Self, rhs: Self) -> Bool { lhs.microseconds < rhs.microseconds }
}

public struct PlaybackInstant: Codable, Hashable, Comparable, Sendable {
  public let ticks: UInt64
  public init(ticks: UInt64) { self.ticks = ticks }
  public static func < (lhs: Self, rhs: Self) -> Bool { lhs.ticks < rhs.ticks }
}

public struct MediaSourceIdentity: RawRepresentable, Codable, Hashable, Comparable, Sendable {
  public let rawValue: String
  public init(rawValue: String) { self.rawValue = rawValue }
  public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public enum PlaybackAuthority: Codable, Hashable, Sendable {
  case application(ApplicationEpochID)
  case playback(
    sessionID: PlaybackSessionID,
    generation: PlaybackGenerationID,
    revisions: PlaybackRevisionSet
  )
}

public struct PlaybackEffectContext: Codable, Hashable, Sendable {
  public let authority: PlaybackAuthority
  public let operationID: PlaybackOperationID
  public let effectID: PlaybackEffectID
  public let streamID: PlaybackStreamID?
  public let trackID: PlaybackTrackID?

  public init(
    authority: PlaybackAuthority,
    operationID: PlaybackOperationID,
    effectID: PlaybackEffectID,
    streamID: PlaybackStreamID? = nil,
    trackID: PlaybackTrackID? = nil
  ) {
    self.authority = authority
    self.operationID = operationID
    self.effectID = effectID
    self.streamID = streamID
    self.trackID = trackID
  }
}
