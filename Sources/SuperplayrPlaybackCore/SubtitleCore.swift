public enum SubtitleInvalidationReason: String, Codable, Equatable, Sendable {
  case seek
  case replacement
  case trackChange
  case stop
  case shutdown
}

public enum SubtitleCoreEvent: Codable, Equatable, Sendable {
  case invalidate(reason: SubtitleInvalidationReason)
  case overlayCommitCandidate(authority: PlaybackAuthority, revision: OverlayRevisionID)
  case sourceInstalled(MediaSourceIdentity, external: Bool)
  case appliedDelay(microseconds: Int64)
}

public struct SubtitleMachineState: Codable, Equatable, Sendable {
  public var subtitleRevision: SubtitleRevisionID
  public var overlayRevision: OverlayRevisionID
  public var pendingVisibleClear: OverlayRevisionID?
  public var pendingSourceInvalidation: SubtitleRevisionID?
  public var lastAcceptedOverlayRevision: OverlayRevisionID?
  public var rejectedOverlayCommitCount: UInt64
  public var installedSource: MediaSourceIdentity?
  public var installedSourceIsExternal: Bool
  public var appliedDelayMicroseconds: Int64

  public init(
    subtitleRevision: SubtitleRevisionID = SubtitleRevisionID(rawValue: 0),
    overlayRevision: OverlayRevisionID = OverlayRevisionID(rawValue: 0),
    pendingVisibleClear: OverlayRevisionID? = nil,
    pendingSourceInvalidation: SubtitleRevisionID? = nil,
    lastAcceptedOverlayRevision: OverlayRevisionID? = nil,
    rejectedOverlayCommitCount: UInt64 = 0,
    installedSource: MediaSourceIdentity? = nil,
    installedSourceIsExternal: Bool = false,
    appliedDelayMicroseconds: Int64 = 0
  ) {
    self.subtitleRevision = subtitleRevision
    self.overlayRevision = overlayRevision
    self.pendingVisibleClear = pendingVisibleClear
    self.pendingSourceInvalidation = pendingSourceInvalidation
    self.lastAcceptedOverlayRevision = lastAcceptedOverlayRevision
    self.rejectedOverlayCommitCount = rejectedOverlayCommitCount
    self.installedSource = installedSource
    self.installedSourceIsExternal = installedSourceIsExternal
    self.appliedDelayMicroseconds = appliedDelayMicroseconds
  }
}
