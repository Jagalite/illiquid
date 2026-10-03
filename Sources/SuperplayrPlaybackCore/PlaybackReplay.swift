import Foundation

public struct CanonicalOutstandingEffect: Codable, Equatable, Sendable {
  public let effectID: PlaybackEffectID
  public let effect: CanonicalPlaybackEffect
  public let acceptedTokens: [EffectResultToken]
}

public enum CanonicalEffectResultRequirement: Codable, Equatable, Sendable {
  case exactly(EffectResultToken)
  case oneOf([EffectResultToken])
}

public enum CanonicalEffectCompletionContract: Codable, Equatable, Sendable {
  case oneShot(terminals: [EffectResultToken])
  case phased(phases: [[CanonicalEffectResultRequirement]], terminal: [EffectResultToken])
  case subscription(
    id: PlaybackSubscriptionID,
    callbackKinds: [EffectResultToken],
    terminals: [EffectResultToken]
  )
  case bestEffortMirror
}

public struct CanonicalPlaybackEffect: Codable, Equatable, Sendable {
  public let executor: ExecutorKind
  public let context: PlaybackEffectContext
  public let kind: PlaybackEffectKind
  public let completion: CanonicalEffectCompletionContract
  public let isCleanup: Bool
  public let exclusiveKey: String?

  public init(effect: PlaybackEffect) {
    executor = effect.executor
    context = effect.context
    kind = effect.kind
    completion = canonicalCompletion(effect.completion)
    isCleanup = effect.isCleanup
    exclusiveKey = effect.exclusiveKey
  }
}

public struct CanonicalResourceLease: Codable, Equatable, Sendable {
  public let key: ResourceLeaseKey
  public let authority: PlaybackAuthority
  public let storageExecutor: ExecutorKind
  public let currentCustodian: ExecutorKind
  public let activeBorrows: [ResourceBorrowID]
  public let inFlightUseCount: Int
  public let releaseRequested: Bool
  public let physicalReleaseObserved: Bool
}

public struct PlaybackCanonicalState: Codable, Equatable, Sendable {
  public let schemaVersion: UInt32
  public let applicationEpoch: ApplicationEpochID
  public let lifecycle: PlaybackLifecyclePhase
  public let activeSession: ActivePlaybackSession?
  public let outstandingEffects: [CanonicalOutstandingEffect]
  public let completedEffectIDs: [PlaybackEffectID]
  public let resourceLeases: [CanonicalResourceLease]
  public let allocator: PlaybackIDAllocator
  public let snapshotRevision: UInt64
  public let lastVirtualTime: PlaybackInstant
  public let acceptedEventCount: UInt64
  public let rejectedEventCount: UInt64
  public let diagnosticEventCount: UInt64
  public let lastPersistenceFailureCode: String?
  public let externalWaitReason: PlaybackExternalWaitReason?

  public init(state: PlaybackCoreState) {
    schemaVersion = state.schemaVersion
    applicationEpoch = state.applicationEpoch
    lifecycle = state.lifecycle
    activeSession = state.activeSession
    outstandingEffects = state.outstandingEffects
      .map { effectID, record in
        CanonicalOutstandingEffect(
          effectID: effectID,
          effect: CanonicalPlaybackEffect(effect: record.effect),
          acceptedTokens: record.acceptedTokens.sorted {
            $0.canonicalKey < $1.canonicalKey
          }
        )
      }
      .sorted { $0.effectID < $1.effectID }
    completedEffectIDs = state.completedEffectIDs.sorted()
    resourceLeases = state.resourceLeases
      .map { key, record in
        CanonicalResourceLease(
          key: key,
          authority: record.authority,
          storageExecutor: record.storageExecutor,
          currentCustodian: record.currentCustodian,
          activeBorrows: record.activeBorrows.sorted(),
          inFlightUseCount: record.inFlightUseCount,
          releaseRequested: record.releaseRequested,
          physicalReleaseObserved: record.physicalReleaseObserved
        )
      }
      .sorted { canonicalLeaseKey($0.key) < canonicalLeaseKey($1.key) }
    allocator = state.allocator
    snapshotRevision = state.snapshotRevision
    lastVirtualTime = state.lastVirtualTime
    acceptedEventCount = state.acceptedEventCount
    rejectedEventCount = state.rejectedEventCount
    diagnosticEventCount = state.diagnosticEventCount
    lastPersistenceFailureCode = state.lastPersistenceFailureCode
    externalWaitReason = state.externalWaitReason
  }
}

public struct PlaybackReplayStep: Codable, Equatable, Sendable {
  public let envelope: PlaybackEventEnvelope
  public let disposition: EventDisposition
  public let preState: PlaybackCanonicalState
  public let postState: PlaybackCanonicalState
  public let preStateDigest: String
  public let postStateDigest: String
  public let generatedEffects: [CanonicalPlaybackEffect]
  public let invariantResults: [PlaybackInvariantViolation]

  public init(
    envelope: PlaybackEventEnvelope,
    disposition: EventDisposition,
    preState: PlaybackCanonicalState,
    postState: PlaybackCanonicalState,
    preStateDigest: String,
    postStateDigest: String,
    generatedEffects: [PlaybackEffect],
    invariantResults: [PlaybackInvariantViolation]
  ) {
    self.envelope = envelope
    self.disposition = disposition
    self.preState = preState
    self.postState = postState
    self.preStateDigest = preStateDigest
    self.postStateDigest = postStateDigest
    self.generatedEffects = generatedEffects.map(CanonicalPlaybackEffect.init)
    self.invariantResults = invariantResults
  }
}

public struct PlaybackReplayFailure: Codable, Equatable, Sendable {
  public let invariantName: String
  public let step: UInt64
  public let details: String

  public init(invariantName: String, step: UInt64, details: String) {
    self.invariantName = invariantName
    self.step = step
    self.details = details
  }
}

public struct PlaybackReplayShrinkRecord: Codable, Equatable, Sendable {
  public let fromSteps: Int
  public let toSteps: Int

  public init(fromSteps: Int, toSteps: Int) {
    self.fromSteps = fromSteps
    self.toSteps = toSteps
  }
}

public struct PlaybackReplayDocument: Codable, Equatable, Sendable {
  public let schemaVersion: UInt32
  public let superplayrRevision: String
  public let modelVersion: UInt32
  public let seed: UInt64
  public let initialState: PlaybackCanonicalState
  public let steps: [PlaybackReplayStep]
  public let finalState: PlaybackCanonicalState
  public let rejectedStaleEvents: [UInt64]
  public let failedInvariant: PlaybackReplayFailure?
  public let shrinkHistory: [PlaybackReplayShrinkRecord]

  public init(
    schemaVersion: UInt32 = 1,
    superplayrRevision: String,
    modelVersion: UInt32 = 1,
    seed: UInt64,
    initialState: PlaybackCanonicalState,
    steps: [PlaybackReplayStep],
    finalState: PlaybackCanonicalState,
    rejectedStaleEvents: [UInt64],
    failedInvariant: PlaybackReplayFailure? = nil,
    shrinkHistory: [PlaybackReplayShrinkRecord] = []
  ) {
    self.schemaVersion = schemaVersion
    self.superplayrRevision = superplayrRevision
    self.modelVersion = modelVersion
    self.seed = seed
    self.initialState = initialState
    self.steps = steps
    self.finalState = finalState
    self.rejectedStaleEvents = rejectedStaleEvents.sorted()
    self.failedInvariant = failedInvariant
    self.shrinkHistory = shrinkHistory
  }
}

public enum PlaybackReplayCodec {
  public static func encode(_ replay: PlaybackReplayDocument) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(replay)
  }

  public static func decode(_ data: Data) throws -> PlaybackReplayDocument {
    try JSONDecoder().decode(PlaybackReplayDocument.self, from: data)
  }

  public static func digest(_ state: PlaybackCanonicalState) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let bytes = (try? encoder.encode(state)) ?? Data()
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in bytes {
      hash ^= UInt64(byte)
      hash &*= 1_099_511_628_211
    }
    return "fnv1a64:\(hex(hash))"
  }

  private static func hex(_ value: UInt64) -> String {
    let digits = Array("0123456789abcdef")
    var value = value
    var result = Array(repeating: Character("0"), count: 16)
    for index in stride(from: 15, through: 0, by: -1) {
      result[index] = digits[Int(value & 0xF)]
      value >>= 4
    }
    return String(result)
  }
}

private func canonicalLeaseKey(_ key: ResourceLeaseKey) -> String {
  switch key {
  case .single(let id): return "single:\(id.rawValue)"
  case .batch(let id): return "batch:\(id.rawValue)"
  }
}

private func canonicalCompletion(
  _ completion: EffectCompletionContract
) -> CanonicalEffectCompletionContract {
  switch completion {
  case .oneShot(let terminals):
    return .oneShot(terminals: terminals.sorted { $0.canonicalKey < $1.canonicalKey })
  case .phased(let phases, let terminal):
    return .phased(
      phases: phases.map { phase in
        phase.map { requirement in
          switch requirement {
          case .exactly(let token):
            return .exactly(token)
          case .oneOf(let tokens):
            return .oneOf(tokens.sorted { $0.canonicalKey < $1.canonicalKey })
          }
        }
      },
      terminal: terminal.sorted { $0.canonicalKey < $1.canonicalKey }
    )
  case .subscription(let id, let callbackKinds, let terminals):
    return .subscription(
      id: id,
      callbackKinds: callbackKinds.sorted { $0.canonicalKey < $1.canonicalKey },
      terminals: terminals.sorted { $0.canonicalKey < $1.canonicalKey }
    )
  case .bestEffortMirror:
    return .bestEffortMirror
  }
}
