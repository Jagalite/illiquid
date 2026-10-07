public enum PlaybackLifecyclePhase: String, Codable, Equatable, Sendable {
  case running
  case shuttingDown
  case terminated
  case invariantFailed
}

public enum PlaybackExternalWaitReason: String, Codable, Equatable, Hashable, Sendable {
  case shutdownCancellationFailed
  case shutdownFinalizationFailed
}

public enum PlaybackMachinePhase: String, Codable, Equatable, Sendable {
  case idle
  case opening
  case probing
  case configuring
  case prerolling
  case ready
  case seeking
  case buffering
  case playing
  case paused
  case draining
  case ended
  case stopping
  case stopped
  case failed
}

public enum DesiredTransport: String, Codable, Equatable, Sendable {
  case playing
  case paused
  case stopped
}

public enum ActualTransport: String, Codable, Equatable, Sendable {
  case stopped
  case paused
  case playing
  case buffering
}

public struct ActivePlaybackSession: Codable, Equatable, Sendable {
  public var id: PlaybackSessionID
  public var source: MediaSourceIdentity
  public var generation: PlaybackGenerationID
  public var revisions: PlaybackRevisionSet
  public var phase: PlaybackMachinePhase
  public var desiredTransport: DesiredTransport
  public var actualTransport: ActualTransport
  public var logicalPosition: MediaTimestamp
  public var duration: MediaTimestamp
  public var activeOperationID: PlaybackOperationID
  public var lastFailure: PlaybackFailure?
  public var subtitles: SubtitleMachineState
  public var seek: SeekTransactionState?
  public var loading: LoadingTransactionState?
  public var drain: PlaybackDrainState
  public var recovery: RecoveryMachineState
  public var synchronization: SynchronizationMachineState
  public var lifecycleState: LifecycleMachineState
  public var tracks: TrackSelectionMachineState
  public var controls: ControlMachineState

  public init(
    id: PlaybackSessionID,
    source: MediaSourceIdentity,
    generation: PlaybackGenerationID,
    revisions: PlaybackRevisionSet = PlaybackRevisionSet(),
    phase: PlaybackMachinePhase,
    desiredTransport: DesiredTransport,
    actualTransport: ActualTransport,
    logicalPosition: MediaTimestamp = .unknown,
    duration: MediaTimestamp = .unknown,
    activeOperationID: PlaybackOperationID,
    lastFailure: PlaybackFailure? = nil,
    subtitles: SubtitleMachineState = SubtitleMachineState(),
    seek: SeekTransactionState? = nil,
    loading: LoadingTransactionState? = nil,
    drain: PlaybackDrainState = PlaybackDrainState(),
    recovery: RecoveryMachineState = RecoveryMachineState(),
    synchronization: SynchronizationMachineState = SynchronizationMachineState(),
    lifecycleState: LifecycleMachineState = LifecycleMachineState(),
    tracks: TrackSelectionMachineState = TrackSelectionMachineState(),
    controls: ControlMachineState = ControlMachineState()
  ) {
    self.id = id
    self.source = source
    self.generation = generation
    self.revisions = revisions
    self.phase = phase
    self.desiredTransport = desiredTransport
    self.actualTransport = actualTransport
    self.logicalPosition = logicalPosition
    self.duration = duration
    self.activeOperationID = activeOperationID
    self.lastFailure = lastFailure
    self.subtitles = subtitles
    self.seek = seek
    self.loading = loading
    self.drain = drain
    self.recovery = recovery
    self.synchronization = synchronization
    self.lifecycleState = lifecycleState
    self.tracks = tracks
    self.controls = controls
  }

  public var authority: PlaybackAuthority {
    .playback(sessionID: id, generation: generation, revisions: revisions)
  }
}

public struct OutstandingEffectRecord: Codable, Equatable, Sendable {
  public let effect: PlaybackEffect
  public var acceptedTokens: Set<EffectResultToken>

  public init(effect: PlaybackEffect, acceptedTokens: Set<EffectResultToken> = []) {
    self.effect = effect
    self.acceptedTokens = acceptedTokens
  }
}

public struct ResourceLeaseRecord: Codable, Equatable, Sendable {
  public let key: ResourceLeaseKey
  public let authority: PlaybackAuthority
  public let storageExecutor: ExecutorKind
  public var currentCustodian: ExecutorKind
  public var activeBorrows: Set<ResourceBorrowID>
  public var inFlightUseCount: Int
  public var releaseRequested: Bool
  public var physicalReleaseObserved: Bool

  public init(
    key: ResourceLeaseKey,
    authority: PlaybackAuthority,
    storageExecutor: ExecutorKind,
    currentCustodian: ExecutorKind,
    activeBorrows: Set<ResourceBorrowID> = [],
    inFlightUseCount: Int = 0,
    releaseRequested: Bool = false,
    physicalReleaseObserved: Bool = false
  ) {
    self.key = key
    self.authority = authority
    self.storageExecutor = storageExecutor
    self.currentCustodian = currentCustodian
    self.activeBorrows = activeBorrows
    self.inFlightUseCount = inFlightUseCount
    self.releaseRequested = releaseRequested
    self.physicalReleaseObserved = physicalReleaseObserved
  }
}

public struct PlaybackIDAllocator: Codable, Equatable, Sendable {
  public var nextSession: UInt64
  public var nextOperation: UInt64
  public var nextEffect: UInt64
  public var nextLease: UInt64

  public init(
    nextSession: UInt64 = 1,
    nextOperation: UInt64 = 1,
    nextEffect: UInt64 = 1,
    nextLease: UInt64 = 1
  ) {
    self.nextSession = nextSession
    self.nextOperation = nextOperation
    self.nextEffect = nextEffect
    self.nextLease = nextLease
  }

  mutating func allocateSession() -> PlaybackSessionID? {
    guard nextSession < UInt64.max else { return nil }
    defer { nextSession += 1 }
    return PlaybackSessionID(rawValue: nextSession)
  }

  mutating func allocateOperation() -> PlaybackOperationID? {
    guard nextOperation < UInt64.max else { return nil }
    defer { nextOperation += 1 }
    return PlaybackOperationID(rawValue: nextOperation)
  }

  mutating func allocateEffect() -> PlaybackEffectID? {
    guard nextEffect < UInt64.max else { return nil }
    defer { nextEffect += 1 }
    return PlaybackEffectID(rawValue: nextEffect)
  }

  mutating func allocateLease() -> ResourceLeaseID? {
    guard nextLease < UInt64.max else { return nil }
    defer { nextLease += 1 }
    return ResourceLeaseID(rawValue: nextLease)
  }
}

@dynamicMemberLookup
public final class PendingPlaybackSession: Codable, Equatable, Sendable {
  public let value: ActivePlaybackSession

  public init(_ value: ActivePlaybackSession) {
    self.value = value
  }

  public subscript<T>(
    dynamicMember keyPath: KeyPath<ActivePlaybackSession, T>
  ) -> T {
    value[keyPath: keyPath]
  }

  public static func == (
    lhs: PendingPlaybackSession,
    rhs: PendingPlaybackSession
  ) -> Bool {
    lhs.value == rhs.value
  }

  public required init(from decoder: Decoder) throws {
    value = try ActivePlaybackSession(from: decoder)
  }

  public func encode(to encoder: Encoder) throws {
    try value.encode(to: encoder)
  }
}

public struct PlaybackCoreState: Codable, Equatable, Sendable {
  public var loopRange: PlaybackLoopRange?
  public var preferredPlaybackMilliRate: Int32?
  public var playbackMilliRate: Int32 { preferredPlaybackMilliRate ?? 1_000 }
  public var schemaVersion: UInt32
  public var applicationEpoch: ApplicationEpochID
  public var lifecycle: PlaybackLifecyclePhase
  public var activeSession: ActivePlaybackSession?
  /// A source replacement that has native preparation authority but has not
  /// crossed the committed renderer-preroll boundary. The active session
  /// remains the only source visible to product state until this settles.
  public var pendingSession: PendingPlaybackSession?
  public var lastLoadFailure: PlaybackFailure?
  public var outstandingEffects: [PlaybackEffectID: OutstandingEffectRecord]
  public var completedEffectIDs: Set<PlaybackEffectID>
  public var resourceLeases: [ResourceLeaseKey: ResourceLeaseRecord]
  public var allocator: PlaybackIDAllocator
  public var snapshotRevision: UInt64
  public var lastVirtualTime: PlaybackInstant
  public var acceptedEventCount: UInt64
  public var rejectedEventCount: UInt64
  public var diagnosticEventCount: UInt64
  public var lastPersistenceFailureCode: String?
  public var externalWaitReason: PlaybackExternalWaitReason?

  public init(
    schemaVersion: UInt32 = 1,
    applicationEpoch: ApplicationEpochID = ApplicationEpochID(rawValue: 1),
    lifecycle: PlaybackLifecyclePhase = .running,
    activeSession: ActivePlaybackSession? = nil,
    pendingSession: ActivePlaybackSession? = nil,
    lastLoadFailure: PlaybackFailure? = nil,
    outstandingEffects: [PlaybackEffectID: OutstandingEffectRecord] = [:],
    completedEffectIDs: Set<PlaybackEffectID> = [],
    resourceLeases: [ResourceLeaseKey: ResourceLeaseRecord] = [:],
    allocator: PlaybackIDAllocator = PlaybackIDAllocator(),
    snapshotRevision: UInt64 = 0,
    lastVirtualTime: PlaybackInstant = PlaybackInstant(ticks: 0),
    acceptedEventCount: UInt64 = 0,
    rejectedEventCount: UInt64 = 0,
    diagnosticEventCount: UInt64 = 0,
    lastPersistenceFailureCode: String? = nil,
    externalWaitReason: PlaybackExternalWaitReason? = nil
  ) {
    self.schemaVersion = schemaVersion
    self.applicationEpoch = applicationEpoch
    self.lifecycle = lifecycle
    self.activeSession = activeSession
    self.pendingSession = pendingSession.map(PendingPlaybackSession.init)
    self.lastLoadFailure = lastLoadFailure
    self.outstandingEffects = outstandingEffects
    self.completedEffectIDs = completedEffectIDs
    self.resourceLeases = resourceLeases
    self.allocator = allocator
    self.snapshotRevision = snapshotRevision
    self.lastVirtualTime = lastVirtualTime
    self.acceptedEventCount = acceptedEventCount
    self.rejectedEventCount = rejectedEventCount
    self.diagnosticEventCount = diagnosticEventCount
    self.lastPersistenceFailureCode = lastPersistenceFailureCode
    self.externalWaitReason = externalWaitReason
  }
}

public struct PlaybackUISnapshot: Codable, Equatable, Sendable {
  public let sessionID: PlaybackSessionID?
  public let revision: UInt64
  public let lifecycle: PlaybackLifecyclePhase
  public let phase: PlaybackMachinePhase
  public let source: MediaSourceIdentity?
  public let pendingSource: MediaSourceIdentity?
  public let desiredTransport: DesiredTransport
  public let actualTransport: ActualTransport
  public let position: MediaTimestamp
  public let duration: MediaTimestamp
  public let isBuffering: Bool
  public let selectedAudioTrackID: PlaybackTrackID?
  public let selectedSubtitleTrackID: PlaybackTrackID?
  public let subtitleDelayMicroseconds: Int64
  public let failureCode: String?

  public init(state: PlaybackCoreState) {
    sessionID = state.activeSession?.id
    revision = state.snapshotRevision
    lifecycle = state.lifecycle
    phase =
      state.activeSession?.phase
      ?? state.pendingSession?.phase
      ?? (state.lastLoadFailure == nil ? .idle : .failed)
    source = state.activeSession?.source
    pendingSource = state.pendingSession?.source
    desiredTransport =
      state.activeSession?.desiredTransport
      ?? state.pendingSession?.desiredTransport
      ?? .stopped
    actualTransport =
      state.activeSession?.actualTransport
      ?? state.pendingSession?.actualTransport
      ?? .stopped
    // Expose accepted seek intent immediately, even when native dispatch is
    // coalesced. The core's accepted playback clock remains separate.
    position = state.activeSession?.seek?.target ?? state.activeSession?.logicalPosition ?? .unknown
    duration = state.activeSession?.duration ?? .unknown
    isBuffering = state.activeSession?.synchronization.isBuffering ?? false
    selectedAudioTrackID = switch state.activeSession?.tracks.effectiveAudio {
    case .stream(let id): id
    case .off, .automatic, nil: nil
    }
    selectedSubtitleTrackID = switch state.activeSession?.tracks.effectiveSubtitle {
    case .embedded(let id): id
    case .external:
      PlaybackTrackID(kind: .subtitle, mediaTrackID: Int64.max)
    case .off, .automatic, nil: nil
    }
    subtitleDelayMicroseconds = state.activeSession?.controls.appliedSubtitleDelayMicroseconds ?? 0
    failureCode =
      state.lastLoadFailure?.stableCode
      ?? state.activeSession?.lastFailure?.stableCode
  }
}

public struct PlaybackLoopRange: Codable, Equatable, Sendable {
  public let sessionID: PlaybackSessionID
  public let start: MediaTimestamp
  public let end: MediaTimestamp
}
