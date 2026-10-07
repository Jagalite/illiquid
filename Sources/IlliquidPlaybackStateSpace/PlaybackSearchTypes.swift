import IlliquidPlaybackCore

public enum PlaybackSearchAlgorithm: String, Codable, Hashable, Sendable {
  case breadthFirst
  case iterativeDeepening
}

public enum PlaybackSearchPORMode: String, Codable, Hashable, Sendable {
  case disabled
  case conservative
  case validation
}

public enum PlaybackSearchTermination: String, Codable, Hashable, Sendable {
  case completeWithinBounds
  case stateCapReached
  case edgeCapReached
  case timeBudgetReached
}

public struct PlaybackSearchConfiguration: Codable, Hashable, Sendable {
  public let profile: String
  public let algorithm: PlaybackSearchAlgorithm
  public let depthLimit: Int
  public let generationLimit: Int
  public let pendingEffectLimit: Int
  public let lateResultLimit: Int
  public let failureLimit: Int
  public let duplicateLimit: Int
  public let interruptLimit: Int
  public let stateLimit: Int
  public let edgeLimit: Int
  public let porMode: PlaybackSearchPORMode
  public let timeLimitSeconds: Double?

  public init(
    profile: String,
    algorithm: PlaybackSearchAlgorithm = .breadthFirst,
    depthLimit: Int,
    generationLimit: Int,
    pendingEffectLimit: Int,
    lateResultLimit: Int,
    failureLimit: Int,
    duplicateLimit: Int,
    interruptLimit: Int,
    stateLimit: Int,
    edgeLimit: Int,
    porMode: PlaybackSearchPORMode,
    timeLimitSeconds: Double? = nil
  ) {
    self.profile = profile
    self.algorithm = algorithm
    self.depthLimit = depthLimit
    self.generationLimit = generationLimit
    self.pendingEffectLimit = pendingEffectLimit
    self.lateResultLimit = lateResultLimit
    self.failureLimit = failureLimit
    self.duplicateLimit = duplicateLimit
    self.interruptLimit = interruptLimit
    self.stateLimit = stateLimit
    self.edgeLimit = edgeLimit
    self.porMode = porMode
    self.timeLimitSeconds = timeLimitSeconds
  }

  public static let pr = Self(
    profile: "pr", depthLimit: 12, generationLimit: 2,
    pendingEffectLimit: 4, lateResultLimit: 2, failureLimit: 1,
    duplicateLimit: 1, interruptLimit: 1, stateLimit: 50_000,
    edgeLimit: 500_000, porMode: .disabled, timeLimitSeconds: 60
  )

  public static let nightly = Self(
    profile: "nightly", depthLimit: 20, generationLimit: 3,
    pendingEffectLimit: 6, lateResultLimit: 4, failureLimit: 2,
    duplicateLimit: 1, interruptLimit: 2, stateLimit: 500_000,
    edgeLimit: 5_000_000, porMode: .conservative, timeLimitSeconds: 300
  )

  public static let qualification = Self(
    profile: "qualification", depthLimit: 28, generationLimit: 4,
    pendingEffectLimit: 8, lateResultLimit: 6, failureLimit: 3,
    duplicateLimit: 1, interruptLimit: 3, stateLimit: 2_000_000,
    edgeLimit: 25_000_000, porMode: .validation, timeLimitSeconds: 600
  )

  public static func validation(
    depthLimit: Int = 5,
    porMode: PlaybackSearchPORMode = .disabled
  ) -> Self {
    Self(
      profile: "validation", depthLimit: depthLimit, generationLimit: 1,
      pendingEffectLimit: 3, lateResultLimit: 1, failureLimit: 1,
      duplicateLimit: 1, interruptLimit: 1, stateLimit: 10_000,
      edgeLimit: 100_000, porMode: porMode, timeLimitSeconds: 30
    )
  }

  public func withPORMode(_ mode: PlaybackSearchPORMode) -> Self {
    Self(
      profile: profile, algorithm: algorithm, depthLimit: depthLimit,
      generationLimit: generationLimit, pendingEffectLimit: pendingEffectLimit,
      lateResultLimit: lateResultLimit, failureLimit: failureLimit,
      duplicateLimit: duplicateLimit, interruptLimit: interruptLimit,
      stateLimit: stateLimit, edgeLimit: edgeLimit, porMode: mode,
      timeLimitSeconds: timeLimitSeconds
    )
  }

  public func withTimeLimitSeconds(_ seconds: Double?) -> Self {
    Self(
      profile: profile, algorithm: algorithm, depthLimit: depthLimit,
      generationLimit: generationLimit, pendingEffectLimit: pendingEffectLimit,
      lateResultLimit: lateResultLimit, failureLimit: failureLimit,
      duplicateLimit: duplicateLimit, interruptLimit: interruptLimit,
      stateLimit: stateLimit, edgeLimit: edgeLimit, porMode: porMode,
      timeLimitSeconds: seconds
    )
  }
}

public enum ExternalWaitReason: String, Codable, Hashable, Sendable {
  case userCommand
  case effectResult
  case drainFact
  case prerollFact
  case resourceCustody
  case shutdownCancellationFailure
  case shutdownFinalizationFailure
}

public enum AbstractQueueState: String, Codable, Hashable, CaseIterable, Sendable {
  case absent, empty, partial, full, draining, invalidated
}

public enum AbstractMechanismState: String, Codable, Hashable, Sendable {
  case absent, configuredHardware, configuredSoftware, flushing, draining, drained
  case failed, invalidated, prerolling, active
}

public enum CountClass: String, Codable, Hashable, Sendable {
  case zero, one, twoOrMore

  mutating func increment() {
    self =
      switch self {
      case .zero: .one
      case .one, .twoOrMore: .twoOrMore
      }
  }
}

public enum SeekExecutorPrerequisite: String, Codable, Hashable, CaseIterable, Sendable {
  case inputCancellation
  case videoReset
  case audioReset
  case presentationFence
  case subtitleVisibleClear
  case subtitleSourceInvalidation
  case demuxSeek
  case requiredStreamPreroll
}

public enum RecoveryExecutorPrerequisite: String, Codable, Hashable, CaseIterable, Sendable {
  case oldOutputFence, decoderTeardown, softwareConfiguration
  case presentationMembership, requiredStreamPreroll
}

extension RecoveryExecutorPrerequisite {
  var dependencies: Set<Self> {
    switch self {
    case .oldOutputFence:
      []
    case .decoderTeardown:
      [.oldOutputFence]
    case .softwareConfiguration:
      [.decoderTeardown]
    case .presentationMembership:
      [.oldOutputFence, .softwareConfiguration]
    case .requiredStreamPreroll:
      [.presentationMembership]
    }
  }
}

public enum TrackExecutorPrerequisite: String, Codable, Hashable, CaseIterable, Sendable {
  case replacementPrepared, replacementInstalled, pausedStart
  case requestedTrackObserved, oldOutputFence
}

public struct SeekSearchEnvironment: Codable, Hashable, Sendable {
  public var prerequisites: Set<SeekExecutorPrerequisite>
  public var generationChurn: Int
  public var interrupts: Int
  public var eofCycles: Int
  public var playlistAdvanceCount: CountClass
  public var oldOutputPresented: Bool

  public init(
    prerequisites: Set<SeekExecutorPrerequisite> = [], generationChurn: Int = 0,
    interrupts: Int = 0, eofCycles: Int = 0,
    playlistAdvanceCount: CountClass = .zero, oldOutputPresented: Bool = false
  ) {
    self.prerequisites = prerequisites
    self.generationChurn = generationChurn
    self.interrupts = interrupts
    self.eofCycles = eofCycles
    self.playlistAdvanceCount = playlistAdvanceCount
    self.oldOutputPresented = oldOutputPresented
  }
}

public struct EOFDrainSearchEnvironment: Codable, Hashable, Sendable {
  public var playlistAdvanceCount: CountClass = .zero
  public var generationChurn = 0
  public var interrupts = 0
  public var externalWait: ExternalWaitReason?
  public init() {}
}

public struct RecoverySearchEnvironment: Codable, Hashable, Sendable {
  public var prerequisites: Set<RecoveryExecutorPrerequisite> = []
  public var decoder: AbstractMechanismState = .configuredHardware
  public var presenter: AbstractMechanismState = .active
  public var failures = 0
  public var generationChurn = 0
  public var interrupts = 0
  public var oldOutputPresented = false
  public init() {}
}

public struct TrackSubtitleSearchEnvironment: Codable, Hashable, Sendable {
  public var prerequisites: Set<TrackExecutorPrerequisite> = []
  public var generationChurn = 0
  public var interrupts = 0
  public var invalidations = 0
  public var oldOverlayAccepted = false
  public init() {}
}

public struct StopShutdownSearchEnvironment: Codable, Hashable, Sendable {
  public var everShutdown = false
  public var cleanupApplications: [String: CountClass] = [:]
  public var externalWait: ExternalWaitReason?
  public var resourcesReturned = false
  public init() {}
}

public struct PrerollBufferingSearchEnvironment: Codable, Hashable, Sendable {
  public var videoQueue: AbstractQueueState = .empty
  public var audioQueue: AbstractQueueState = .empty
  public var startupSatisfied = false
  public var interrupts = 0
  public init() {}
}

public enum PlaybackModelEnvironment: Codable, Hashable, Sendable {
  case seek(SeekSearchEnvironment)
  case eofDrain(EOFDrainSearchEnvironment)
  case recovery(RecoverySearchEnvironment)
  case trackSubtitles(TrackSubtitleSearchEnvironment)
  case stopShutdown(StopShutdownSearchEnvironment)
  case prerollBuffering(PrerollBufferingSearchEnvironment)
}

public struct RetainedEffectResult: Codable, Equatable, Sendable {
  public let effect: PlaybackEffect
  public let result: PlaybackEffectResult
  public var deliveries: Int

  public init(effect: PlaybackEffect, result: PlaybackEffectResult, deliveries: Int = 1) {
    self.effect = effect
    self.result = result
    self.deliveries = deliveries
  }
}

public struct PlaybackSearchGhost: Codable, Hashable, Sendable {
  public var generationChurn: Int
  public var duplicateClasses: Set<String>
  public var everShutdown: Bool
  public var playlistAdvanceCount: CountClass
  public var externalWait: ExternalWaitReason?

  public init(
    generationChurn: Int = 0, duplicateClasses: Set<String> = [],
    everShutdown: Bool = false, playlistAdvanceCount: CountClass = .zero,
    externalWait: ExternalWaitReason? = nil
  ) {
    self.generationChurn = generationChurn
    self.duplicateClasses = duplicateClasses
    self.everShutdown = everShutdown
    self.playlistAdvanceCount = playlistAdvanceCount
    self.externalWait = externalWait
  }
}

public struct PlaybackSearchNode: Sendable {
  public let model: PlaybackSearchModel
  public let seedProfile: String
  public var coreState: PlaybackCoreState
  public var environment: PlaybackModelEnvironment
  public var lateResults: [RetainedEffectResult]
  public var ghost: PlaybackSearchGhost
  public var nextSequence: UInt64
  public var depth: Int

  public init(
    model: PlaybackSearchModel,
    seedProfile: String = "manual",
    coreState: PlaybackCoreState,
    environment: PlaybackModelEnvironment,
    lateResults: [RetainedEffectResult] = [],
    ghost: PlaybackSearchGhost = PlaybackSearchGhost(),
    nextSequence: UInt64 = 1,
    depth: Int = 0
  ) {
    self.model = model
    self.seedProfile = seedProfile
    self.coreState = coreState
    self.environment = environment
    self.lateResults = lateResults
    self.ghost = ghost
    self.nextSequence = nextSequence
    self.depth = depth
  }
}

public struct PlaybackSearchInventory: Codable, Hashable, Sendable {
  public let seedProfiles: [String]
  public let actionClasses: [String]
  public let requiredScenarios: [String]
}

public struct PlaybackSearchSummary: Codable, Hashable, Sendable {
  public let model: PlaybackSearchModel
  public let modelVersion: UInt32
  public let seedProfile: String
  public let configuration: PlaybackSearchConfiguration
  public let termination: PlaybackSearchTermination
  public let stateCount: Int
  public let edgeCount: Int
  public let productionTransitionCount: Int
  public let gateRejectionCount: Int
  public let peakFrontier: Int
  public let deepestCompletedLayer: Int
  public let reducedEdgeCount: Int
  public let validatedDiamondCount: Int
  public let nonCommutingDiamondCount: Int
  public let canonicalDigest: String
}

public struct PlaybackSearchFailure: Codable, Hashable, Sendable {
  public let invariantName: String
  public let details: String
  public let nodeIndex: Int
  public let fromNodeIndex: Int
  public let action: SearchAction
  public let depth: Int
}

public enum PlaybackSearchOracle: Codable, Hashable, Sendable {
  case production
  case failOnActionClass(String, invariantName: String)

  func violation(for action: SearchAction, transition: PlaybackTransition?)
    -> PlaybackInvariantViolation?
  {
    switch self {
    case .production:
      return nil
    case .failOnActionClass(let actionClass, let invariantName):
      guard action.stableClass == actionClass,
        transition?.disposition == .accepted
      else { return nil }
      return PlaybackInvariantViolation(
        name: invariantName,
        details: "Test-only oracle rejected accepted action class \(actionClass)."
      )
    }
  }
}

public struct PlaybackSearchResult: Sendable {
  public let summary: PlaybackSearchSummary
  public let oracle: PlaybackSearchOracle
  public let failures: [PlaybackSearchFailure]
  public let graph: PlaybackSearchGraph
  public let nodes: [PlaybackSearchNode]
  public let predecessors: [PlaybackSearchPredecessor?]
}

public struct PlaybackSearchPredecessor: Codable, Hashable, Sendable {
  public let nodeIndex: Int
  public let action: SearchAction
}

public struct PlaybackSearchGraph: Codable, Hashable, Sendable {
  public struct Edge: Codable, Hashable, Sendable {
    public let from: Int
    public let to: Int
    public let actionClass: String
    public let isFairProgress: Bool
  }
  public var edges: [Edge]
  public init(edges: [Edge] = []) { self.edges = edges }
}

public struct PlaybackSearchQualificationRecord: Codable, Sendable {
  public let summary: PlaybackSearchSummary
  public let progress: PlaybackProgressReport
  public let failureArtifactPaths: [String]
  public let trendViolations: [PlaybackSearchTrendViolation]
  public let evidenceStatement: String
  public let sourceRevision: String?
  public let sourceDirty: Bool?

  public init(
    summary: PlaybackSearchSummary,
    progress: PlaybackProgressReport,
    failureArtifactPaths: [String],
    trendViolations: [PlaybackSearchTrendViolation] = [],
    sourceRevision: String? = nil,
    sourceDirty: Bool? = nil
  ) {
    self.summary = summary
    self.progress = progress
    self.failureArtifactPaths = failureArtifactPaths
    self.trendViolations = trendViolations
    self.sourceRevision = sourceRevision
    self.sourceDirty = sourceDirty
    evidenceStatement =
      if failureArtifactPaths.isEmpty
        && progress.stuckStates.isEmpty
        && progress.closedNonterminalSCCs.isEmpty
        && trendViolations.isEmpty
        && summary.nonCommutingDiamondCount == 0
      {
        "No invariant or progress violation within the recorded model/version/configuration bounds."
      } else {
        "State-space qualification found a violation; inspect this record and its artifacts."
      }
  }
}
