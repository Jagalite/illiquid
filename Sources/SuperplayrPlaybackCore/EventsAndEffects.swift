public enum ExecutorKind: String, Codable, Hashable, Sendable {
  case input
  case videoDecode
  case audioDecode
  case presentation
  case subtitle
  case persistence
  case platform
  case diagnostics
  case resource
  case mainActorControl
}

public struct EffectResultKind: RawRepresentable, Codable, Hashable, Comparable, Sendable {
  public let rawValue: String
  public init(rawValue: String) { self.rawValue = rawValue }
  public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

  public static let succeeded = Self(rawValue: "succeeded")
  public static let failed = Self(rawValue: "failed")
  public static let cancelled = Self(rawValue: "cancelled")
}

public struct EffectResultToken: Codable, Hashable, Sendable {
  public let kind: EffectResultKind
  public let streamID: PlaybackStreamID?
  public let graphRevision: PresentationGraphRevisionID?
  public let membershipRevision: PresentationMembershipRevisionID?
  public let component: String?

  public init(
    kind: EffectResultKind,
    streamID: PlaybackStreamID? = nil,
    graphRevision: PresentationGraphRevisionID? = nil,
    membershipRevision: PresentationMembershipRevisionID? = nil,
    component: String? = nil
  ) {
    self.kind = kind
    self.streamID = streamID
    self.graphRevision = graphRevision
    self.membershipRevision = membershipRevision
    self.component = component
  }

  public var canonicalKey: String {
    let stream = streamID.map { "\($0.kind.rawValue):\($0.demuxIndex)" } ?? "-"
    let graph = graphRevision.map { String($0.rawValue) } ?? "-"
    let membership = membershipRevision.map { String($0.rawValue) } ?? "-"
    return "\(kind.rawValue)|\(stream)|\(graph)|\(membership)|\(component ?? "-")"
  }
}

public enum EffectResultRequirement: Codable, Hashable, Sendable {
  case exactly(EffectResultToken)
  case oneOf(Set<EffectResultToken>)
}

public enum EffectCompletionContract: Codable, Hashable, Sendable {
  case oneShot(terminals: Set<EffectResultToken>)
  case phased(phases: [[EffectResultRequirement]], terminal: Set<EffectResultToken>)
  case subscription(
    id: PlaybackSubscriptionID,
    callbackKinds: Set<EffectResultToken>,
    terminals: Set<EffectResultToken>
  )
  case bestEffortMirror

  public static var standardOneShot: Self {
    .oneShot(terminals: [
      EffectResultToken(kind: .succeeded),
      EffectResultToken(kind: .failed),
      EffectResultToken(kind: .cancelled),
    ])
  }
}

public struct PlaybackFailure: Codable, Equatable, Sendable {
  public enum Domain: String, Codable, Sendable {
    case input
    case demux
    case videoDecode
    case audioDecode
    case presentation
    case subtitle
    case persistence
    case platform
    case resource
    case invariant
  }

  public enum Recoverability: String, Codable, Sendable {
    case retryable
    case fallbackAvailable
    case fatal
    case cancelled
  }

  public enum Stage: String, Codable, Sendable {
    case open
    case probe
    case configure
    case read
    case seek
    case interrupt
    case reset
    case close
    case sendPacket
    case receiveFrame
    case convert
    case enqueue
    case flush
    case drain
    case render
    case persist
    case release
    case shutdown
    case callback
  }

  public let domain: Domain
  public let stage: Stage
  public let stableCode: String
  public let nativeCode: Int64?
  public let recoverability: Recoverability
  public let streamID: PlaybackStreamID?
  public let formatRevision: MediaFormatRevisionID?
  public let codecName: String?
  public let codecProfile: Int?
  public let hardwareWasConfigured: Bool
  public let hardwareOutputWasObserved: Bool
  public let consecutiveCount: Int

  public init(
    domain: Domain,
    stage: Stage,
    stableCode: String,
    nativeCode: Int64? = nil,
    recoverability: Recoverability,
    streamID: PlaybackStreamID? = nil,
    formatRevision: MediaFormatRevisionID? = nil,
    codecName: String? = nil,
    codecProfile: Int? = nil,
    hardwareWasConfigured: Bool = false,
    hardwareOutputWasObserved: Bool = false,
    consecutiveCount: Int = 1
  ) {
    self.domain = domain
    self.stage = stage
    self.stableCode = stableCode
    self.nativeCode = nativeCode
    self.recoverability = recoverability
    self.streamID = streamID
    self.formatRevision = formatRevision
    self.codecName = codecName
    self.codecProfile = codecProfile
    self.hardwareWasConfigured = hardwareWasConfigured
    self.hardwareOutputWasObserved = hardwareOutputWasObserved
    self.consecutiveCount = consecutiveCount
  }
}

public enum PlaybackCommand: Codable, Equatable, Sendable {
  case load(source: MediaSourceIdentity, autoplay: Bool)
  case play
  case pause
  case setPlaybackSpeed(milliRate: Int32)
  case setLoop(start: MediaTimestamp?, end: MediaTimestamp?)
  case seek(target: MediaTimestamp, mode: SeekMode)
  case selectAudio(AudioSelectionIntent)
  case selectSubtitle(SubtitleSelectionIntent)
  case setSubtitleDelay(microseconds: Int64)
  case checkpoint
  case stop
  case shutdown
}

public enum SeekMode: String, Codable, Equatable, Sendable {
  case relative
  case keyframe
  case exact
  case preview
}

public enum PlaybackEvent: Codable, Equatable, Sendable {
  case command(PlaybackCommand)
  case effectResult(PlaybackEffectResult)
  case deadlineReached(operationID: PlaybackOperationID)
  case diagnosticObserved(code: String)
  case subtitle(SubtitleCoreEvent)
  case acceptedClockSample(MediaTimestamp)
  case audioOutputChanged(MediaTimestamp)
  case durationObserved(MediaTimestamp)
  case catalogObserved(PlaybackCatalog)
  case demuxEndOfFile(requiredDrain: Set<PlaybackDrainComponent>)
  case drainObserved(PlaybackDrainComponent)
  case failureObserved(PlaybackFailure)
  case synchronization(SynchronizationCoreEvent)
  case lifecycle(LifecycleCoreEvent)
}

public struct PlaybackEventEnvelope: Codable, Equatable, Sendable {
  public let sequence: UInt64
  public let virtualTime: PlaybackInstant
  public let event: PlaybackEvent

  public init(sequence: UInt64, virtualTime: PlaybackInstant, event: PlaybackEvent) {
    self.sequence = sequence
    self.virtualTime = virtualTime
    self.event = event
  }
}

public enum PlaybackEffectKind: Codable, Equatable, Sendable {
  case openSource(MediaSourceIdentity)
  case probeSource
  case configureSession(InitialTrackSelectionState)
  case awaitPreroll
  case applyRate(milliRate: Int32)
  /// Aggregate native seek transaction. Success proves input interruption,
  /// queue/decoder reset, presentation fencing, subtitle invalidation, demux
  /// seek, and required-stream preroll for the target generation.
  case seekPipeline(target: MediaTimestamp, mode: SeekMode)
  case seek(target: MediaTimestamp, mode: SeekMode)
  /// Aggregate track replacement. Success proves that the replacement session
  /// is prepared, installed, started paused, and exposes the requested track.
  case applyAudioSelection(AudioSelectionIntent, revision: TrackRevisionID)
  case applySubtitleSelection(SubtitleSelectionIntent, revision: TrackRevisionID)
  case applySubtitleDelay(microseconds: Int64)
  case cancelSession
  case persistCheckpoint
  case cancelInputRead
  case flushDecoder(PlaybackStreamKind)
  case installPresentationFence(removeDisplayedImage: Bool)
  case clearSubtitleOverlay(revision: OverlayRevisionID)
  case invalidateSubtitleSource(revision: SubtitleRevisionID)
  case releaseLease(ResourceLeaseKey)
  case finalizeShutdown
  case advancePlaylist
  case resumeVideoDecoderAfterTransientFailure(
    streamID: PlaybackStreamID,
    consecutiveCount: Int
  )
  case recreateVideoDecoderInSoftware(
    streamID: PlaybackStreamID,
    decoderRevision: DecoderRevisionID
  )
  case flushPresentationForRecovery(revision: PresentationRevisionID)
  case rebuildPresentationGraph(revision: PresentationGraphRevisionID)
  case flushAudioPresentationForRecovery(revision: PresentationRevisionID)
  case rebuildAudioPresentation(revision: PresentationGraphRevisionID)
  case disableAudioTrack(streamID: PlaybackStreamID)
  case disableSubtitleTrack(streamID: PlaybackStreamID?)
  case correctAudioVideoDrift(microseconds: Int64)
  case reconfigureMediaFormat(
    stream: SynchronizedStream,
    revision: MediaFormatRevisionID
  )
  case resumeAfterWake(position: MediaTimestamp, milliRate: Int32)
  case mirrorDiagnostic(code: String)
}

public struct PlaybackEffect: Codable, Equatable, Sendable {
  public let executor: ExecutorKind
  public let context: PlaybackEffectContext
  public let kind: PlaybackEffectKind
  public let completion: EffectCompletionContract
  public let isCleanup: Bool
  public let exclusiveKey: String?

  public init(
    executor: ExecutorKind,
    context: PlaybackEffectContext,
    kind: PlaybackEffectKind,
    completion: EffectCompletionContract = .standardOneShot,
    isCleanup: Bool = false,
    exclusiveKey: String? = nil
  ) {
    self.executor = executor
    self.context = context
    self.kind = kind
    self.completion = completion
    self.isCleanup = isCleanup
    self.exclusiveKey = exclusiveKey
  }
}

public struct PlaybackEffectResult: Codable, Equatable, Sendable {
  public let context: PlaybackEffectContext
  public let token: EffectResultToken
  public let failure: PlaybackFailure?

  public init(
    context: PlaybackEffectContext,
    token: EffectResultToken,
    failure: PlaybackFailure? = nil
  ) {
    self.context = context
    self.token = token
    self.failure = failure
  }
}

public enum EventDisposition: Codable, Equatable, Sendable {
  case accepted
  case duplicate(effectID: PlaybackEffectID)
  case stale(reason: StaleReason)
  case invalid(reason: String)
  case ignoredAfterTermination
}

public enum StaleReason: String, Codable, Equatable, Sendable {
  case unknownEffect
  case authorityMismatch
  case operationMismatch
  case generationMismatch
  case sessionMismatch
  case expiredDeadline
}

public struct PlaybackTransition: Codable, Equatable, Sendable {
  public let disposition: EventDisposition
  public let effects: [PlaybackEffect]
  public let snapshot: PlaybackUISnapshot
  public let invariantViolations: [PlaybackInvariantViolation]

  public init(
    disposition: EventDisposition,
    effects: [PlaybackEffect],
    snapshot: PlaybackUISnapshot,
    invariantViolations: [PlaybackInvariantViolation]
  ) {
    self.disposition = disposition
    self.effects = effects
    self.snapshot = snapshot
    self.invariantViolations = invariantViolations
  }
}
