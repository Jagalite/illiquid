import Foundation
import IlliquidPlaybackCore

public struct PlaybackSearchMinimizationRecord: Codable, Hashable, Sendable {
  public let fromSteps: Int
  public let toSteps: Int
  public let replayCount: Int
}

public struct PlaybackSearchArtifactStep: Codable, Equatable, Sendable {
  public let action: SearchAction
  public let envelope: PlaybackEventEnvelope?
  public let gateRejected: Bool
  public let disposition: EventDisposition?
  public let preState: PlaybackCanonicalState
  public let postState: PlaybackCanonicalState
  public let preSearchDigest: String
  public let postSearchDigest: String
  public let generatedEffects: [CanonicalPlaybackEffect]
  public let invariantObservations: [PlaybackInvariantViolation]
}

public struct PlaybackSearchArtifact: Codable, Equatable, Sendable {
  public let schemaVersion: UInt32
  public let explorerVersion: UInt32
  public let sourceRevision: String
  public let dirty: Bool
  public let model: PlaybackSearchModel
  public let modelVersion: UInt32
  public let seedProfile: String
  public let configuration: PlaybackSearchConfiguration
  public let oracle: PlaybackSearchOracle
  public let summary: PlaybackSearchSummary
  public let initialState: PlaybackCanonicalState
  public let originalTrace: [PlaybackSearchArtifactStep]
  public let minimizedTrace: [PlaybackSearchArtifactStep]
  public let minimizationHistory: [PlaybackSearchMinimizationRecord]
  public let failedInvariant: PlaybackSearchFailure

  public init(
    schemaVersion: UInt32 = 1,
    explorerVersion: UInt32 = 1,
    sourceRevision: String,
    dirty: Bool,
    model: PlaybackSearchModel,
    modelVersion: UInt32,
    seedProfile: String,
    configuration: PlaybackSearchConfiguration,
    oracle: PlaybackSearchOracle,
    summary: PlaybackSearchSummary,
    initialState: PlaybackCanonicalState,
    originalTrace: [PlaybackSearchArtifactStep],
    minimizedTrace: [PlaybackSearchArtifactStep],
    minimizationHistory: [PlaybackSearchMinimizationRecord],
    failedInvariant: PlaybackSearchFailure
  ) {
    self.schemaVersion = schemaVersion
    self.explorerVersion = explorerVersion
    self.sourceRevision = sourceRevision
    self.dirty = dirty
    self.model = model
    self.modelVersion = modelVersion
    self.seedProfile = seedProfile
    self.configuration = configuration
    self.oracle = oracle
    self.summary = summary
    self.initialState = initialState
    self.originalTrace = originalTrace
    self.minimizedTrace = minimizedTrace
    self.minimizationHistory = minimizationHistory
    self.failedInvariant = failedInvariant
  }
}

public enum PlaybackSearchArtifactCodec {
  public static func encode(_ artifact: PlaybackSearchArtifact) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(artifact)
  }

  public static func decode(_ data: Data) throws -> PlaybackSearchArtifact {
    try JSONDecoder().decode(PlaybackSearchArtifact.self, from: data)
  }
}

public enum PlaybackSearchArtifactBuilder {
  public static func build(
    result: PlaybackSearchResult,
    failure: PlaybackSearchFailure,
    sourceRevision: String,
    dirty: Bool
  ) throws -> PlaybackSearchArtifact {
    let actions = traceActions(result: result, failure: failure)
    let oracle = result.oracle
    let original = try replayActions(
      actions, model: result.summary.model, seedProfile: result.summary.seedProfile,
      configuration: result.summary.configuration, oracle: oracle
    )
    let minimized = try PlaybackSearchMinimizer.minimize(
      actions: actions, model: result.summary.model,
      seedProfile: result.summary.seedProfile,
      configuration: result.summary.configuration, oracle: oracle,
      invariantName: failure.invariantName
    )
    let minimizedReplay = try replayActions(
      minimized.actions, model: result.summary.model,
      seedProfile: result.summary.seedProfile,
      configuration: result.summary.configuration, oracle: oracle
    )
    let seed = try PlaybackSearchModelDefinition(model: result.summary.model)
      .makeSeed(profile: result.summary.seedProfile)
    return PlaybackSearchArtifact(
      sourceRevision: sourceRevision, dirty: dirty,
      model: result.summary.model,
      modelVersion: result.summary.modelVersion,
      seedProfile: result.summary.seedProfile,
      configuration: result.summary.configuration,
      oracle: oracle,
      summary: result.summary,
      initialState: PlaybackCanonicalState(state: seed.coreState),
      originalTrace: original.steps,
      minimizedTrace: minimizedReplay.steps,
      minimizationHistory: minimized.history,
      failedInvariant: failure
    )
  }

  private static func traceActions(
    result: PlaybackSearchResult,
    failure: PlaybackSearchFailure
  ) -> [SearchAction] {
    var prefix: [SearchAction] = []
    var cursor = failure.fromNodeIndex
    while let predecessor = result.predecessors[cursor] {
      prefix.append(predecessor.action)
      cursor = predecessor.nodeIndex
    }
    return prefix.reversed() + [failure.action]
  }
}

public struct PlaybackSearchReplayOutcome: Sendable {
  public let reproducedFailure: Bool
  public let productionTransitionCount: Int
}

public enum PlaybackSearchArtifactReplayer {
  public static func replay(
    _ artifact: PlaybackSearchArtifact
  ) throws -> PlaybackSearchReplayOutcome {
    let actions = artifact.minimizedTrace.map(\.action)
    let replay = try replayActions(
      actions, model: artifact.model, seedProfile: artifact.seedProfile,
      configuration: artifact.configuration, oracle: artifact.oracle
    )
    guard replay.steps.count == artifact.minimizedTrace.count else {
      throw PlaybackSearchReplayError.stepCountMismatch
    }
    for (expected, actual) in zip(artifact.minimizedTrace, replay.steps) {
      guard expected.disposition == actual.disposition,
        expected.postSearchDigest == actual.postSearchDigest
      else { throw PlaybackSearchReplayError.transitionMismatch }
    }
    return PlaybackSearchReplayOutcome(
      reproducedFailure: replay.violations.contains {
        $0.name == artifact.failedInvariant.invariantName
      },
      productionTransitionCount: replay.productionReplayCount
    )
  }
}

public enum PlaybackSearchReplayError: Error {
  case stepCountMismatch
  case transitionMismatch
}

public struct PlaybackSearchMinimizationResult: Sendable {
  public let actions: [SearchAction]
  public let history: [PlaybackSearchMinimizationRecord]
  public let productionReplayCount: Int
}

public enum PlaybackSearchMinimizer {
  public static func minimize(
    actions: [SearchAction],
    model: PlaybackSearchModel,
    seedProfile: String,
    configuration: PlaybackSearchConfiguration,
    oracle: PlaybackSearchOracle,
    invariantName: String? = nil
  ) throws -> PlaybackSearchMinimizationResult {
    let expected = invariantName ?? oracle.invariantName
    var current = actions
    var history: [PlaybackSearchMinimizationRecord] = []
    var replayCount = 0
    var chunk = max(current.count / 2, 1)
    while chunk > 0, current.count > 1 {
      var acceptedDeletion = false
      var start = 0
      while start < current.count {
        let end = min(start + chunk, current.count)
        var candidate = current
        candidate.removeSubrange(start..<end)
        guard !candidate.isEmpty,
          try causallyValid(
            candidate, model: model, seedProfile: seedProfile,
            configuration: configuration
          )
        else {
          start += chunk
          continue
        }
        let replay = try replayActions(
          candidate, model: model, seedProfile: seedProfile,
          configuration: configuration, oracle: oracle
        )
        replayCount += replay.productionReplayCount
        if replay.violations.contains(where: { $0.name == expected }) {
          history.append(
            .init(
              fromSteps: current.count, toSteps: candidate.count,
              replayCount: replay.productionReplayCount
            ))
          current = candidate
          acceptedDeletion = true
          break
        }
        start += chunk
      }
      if !acceptedDeletion { chunk /= 2 }
    }
    return PlaybackSearchMinimizationResult(
      actions: current, history: history, productionReplayCount: replayCount
    )
  }
}

struct ReplayedSearchTrace {
  let steps: [PlaybackSearchArtifactStep]
  let violations: [PlaybackInvariantViolation]
  let productionReplayCount: Int
}

func replayActions(
  _ actions: [SearchAction],
  model: PlaybackSearchModel,
  seedProfile: String,
  configuration: PlaybackSearchConfiguration,
  oracle: PlaybackSearchOracle
) throws -> ReplayedSearchTrace {
  var node = try PlaybackSearchModelDefinition(model: model).makeSeed(profile: seedProfile)
  var steps: [PlaybackSearchArtifactStep] = []
  var violations: [PlaybackInvariantViolation] = []
  var productionCount = 0
  for action in actions {
    let preState = PlaybackCanonicalState(state: node.coreState)
    let preSearchDigest = PlaybackSearchCanonicalizer.digest(
      PlaybackSearchCanonicalizer.key(for: node)
    )
    let applied = apply(action: action, to: node, configuration: configuration)
    if applied.calledProductionCore { productionCount += 1 }
    var observations = applied.violations
    if let violation = oracle.violation(for: action, transition: applied.transition) {
      observations.append(violation)
    }
    violations += observations
    steps.append(
      PlaybackSearchArtifactStep(
        action: action, envelope: applied.envelope,
        gateRejected: applied.gateRejected,
        disposition: applied.transition?.disposition,
        preState: preState,
        postState: PlaybackCanonicalState(state: applied.node.coreState),
        preSearchDigest: preSearchDigest,
        postSearchDigest: PlaybackSearchCanonicalizer.digest(
          PlaybackSearchCanonicalizer.key(for: applied.node)
        ),
        generatedEffects: applied.transition?.effects.map(CanonicalPlaybackEffect.init) ?? [],
        invariantObservations: observations
      ))
    node = applied.node
  }
  return ReplayedSearchTrace(
    steps: steps, violations: violations, productionReplayCount: productionCount
  )
}

func causallyValid(
  _ actions: [SearchAction],
  model: PlaybackSearchModel,
  seedProfile: String,
  configuration: PlaybackSearchConfiguration
) throws -> Bool {
  var node = try PlaybackSearchModelDefinition(model: model).makeSeed(profile: seedProfile)
  for action in actions {
    if case .result(let effectID, _, _) = action,
      node.coreState.outstandingEffects[effectID] == nil
    {
      return false
    }
    node = apply(action: action, to: node, configuration: configuration).node
  }
  return true
}

extension PlaybackSearchOracle {
  fileprivate var invariantName: String {
    switch self {
    case .production: return "productionInvariant"
    case .failOnActionClass(_, let invariantName): return invariantName
    }
  }
}

public struct PlaybackRuntimePromotionStep: Codable, Equatable, Sendable {
  public let action: SearchAction
  public let envelope: PlaybackEventEnvelope?
  public let effectContextPreserved: Bool
}

public struct PlaybackRuntimePromotionTrace: Codable, Equatable, Sendable {
  public let modelVersion: UInt32
  public let steps: [PlaybackRuntimePromotionStep]
}

public enum PlaybackRuntimePromotion {
  public static func promote(
    _ artifact: PlaybackSearchArtifact
  ) -> PlaybackRuntimePromotionTrace? {
    var steps: [PlaybackRuntimePromotionStep] = []
    for step in artifact.minimizedTrace {
      switch step.action {
      case .seekPrerequisite, .seekAggregateReady, .recoveryPrerequisite,
        .trackPrerequisite, .recoveryAggregateReady, .trackAggregateReady,
        .queueOffer, .queueConsume, .resourceCustodyReturned:
        return nil
      case .runtimeFact(_, let ingress) where ingress != .current:
        return nil
      default:
        steps.append(
          PlaybackRuntimePromotionStep(
            action: step.action, envelope: step.envelope,
            effectContextPreserved: contextIsPreserved(step)
          ))
      }
    }
    return PlaybackRuntimePromotionTrace(
      modelVersion: artifact.modelVersion, steps: steps
    )
  }

  private static func contextIsPreserved(_ step: PlaybackSearchArtifactStep) -> Bool {
    guard case .effectResult(let result)? = step.envelope?.event else { return true }
    guard case .result(let effectID, _, _)? = Optional(step.action) else { return true }
    return result.context.effectID == effectID
  }
}
