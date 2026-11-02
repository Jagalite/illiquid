import IlliquidPlaybackCore
import Statelessness

/// A playback search node paired with its canonical search identity.
///
/// The key is derived from `node` when the value is constructed and both are
/// immutable, so the cached key cannot become stale. Equality and hashing use
/// the key: it is the existing semantic quotient, not executable state. The
/// hash is the key's own `Hashable` hash, so it is consistent with key equality
/// (including Unicode canonical equivalence). It is process-local and is never
/// written to evidence; evidence uses `PlaybackModelCodec`.
public struct PlaybackModelState: Sendable {
  public let node: PlaybackSearchNode
  public let key: PlaybackSearchStateKey
  public let keyHash: UInt64

  public init(node: PlaybackSearchNode) {
    self.node = node
    key = PlaybackSearchCanonicalizer.key(for: node)
    keyHash = UInt64(bitPattern: Int64(key.hashValue))
  }
}

/// How one model step reached (or did not reach) the production core.
public enum PlaybackModelStepKind: String, Codable, Hashable, Sendable {
  /// A command or accepted ingress called `PlaybackCore.update(_:)` once.
  case production
  /// Ingress from a previous or unrelated authority was rejected at the gate.
  case ingressRejected
  /// An environment-only step: executor prerequisites, queues, custody.
  case environment
  /// The action materialized no production event in this state.
  case notMaterialized
}

/// The observation emitted by one playback model step.
public struct PlaybackModelObservation: Codable, Equatable, Sendable {
  public let kind: PlaybackModelStepKind
  public let transition: PlaybackTransition?
  public let envelope: PlaybackEventEnvelope?
  /// Production and model violations in the order the transition adapter
  /// records them. Test oracles are properties and are not observations.
  public let violations: [PlaybackInvariantViolation]
  public let isFairProgress: Bool

  public init(
    kind: PlaybackModelStepKind, transition: PlaybackTransition?,
    envelope: PlaybackEventEnvelope?, violations: [PlaybackInvariantViolation],
    isFairProgress: Bool
  ) {
    self.kind = kind
    self.transition = transition
    self.envelope = envelope
    self.violations = violations
    self.isFairProgress = isFairProgress
  }

  public var calledProductionCore: Bool { kind == .production }
}

public typealias PlaybackStatelessnessModel = Model<
  PlaybackModelState, SearchAction, PlaybackModelObservation
>
public typealias PlaybackGraphReport = GraphSearchReport<
  PlaybackModelState, SearchAction, PlaybackModelObservation
>
public typealias PlaybackGraphEdge = GraphEdge<SearchAction, PlaybackModelObservation>

public enum PlaybackStatelessnessModelError: Error, CustomStringConvertible {
  case unsupportedAlgorithm(PlaybackSearchAlgorithm)

  public var description: String {
    switch self {
    case .unsupportedAlgorithm(let algorithm):
      "search algorithm \(algorithm.rawValue) is not implemented"
    }
  }
}

public enum PlaybackStatelessnessModels {
  /// Builds the Statelessness model for one model family and seed.
  ///
  /// `step` calls the playback transition adapter `apply` exactly once per
  /// input, and therefore `PlaybackCore.update(_:)` at most once.
  /// `checkTransition` reads the step's observation and never reruns it.
  public static func make(
    model: PlaybackSearchModel,
    seedProfile: String,
    configuration: PlaybackSearchConfiguration,
    oracle: PlaybackSearchOracle = .production
  ) throws -> PlaybackStatelessnessModel {
    guard configuration.algorithm == .breadthFirst else {
      throw PlaybackStatelessnessModelError.unsupportedAlgorithm(configuration.algorithm)
    }
    let definition = PlaybackSearchModelDefinition(model: model)
    let seed = try definition.makeSeed(profile: seedProfile)
    return Model(
      initialState: { PlaybackModelState(node: seed) },
      step: { state, action in
        let observation = step(action: action, node: state.node, configuration: configuration)
        return Transition(
          state: PlaybackModelState(node: observation.node),
          outputs: [observation.observation],
          disposition: disposition(observation.observation)
        )
      },
      checkState: { _ in [] },
      // Every stored type is a value type or an immutable `Sendable` final
      // class (`PendingPlaybackSession`), so sharing is a deep copy.
      cloneState: { $0 },
      cloneInput: { $0 },
      cloneOutput: { $0 },
      checkTransition: { _, action, transition in
        transitionChecks(action: action, transition: transition, oracle: oracle)
      },
      inputs: { state in
        InputIterator(
          values: definition.enabledActions(for: state.node, configuration: configuration))
      },
      equalStates: { $0.key == $1.key },
      hashState: { $0.keyHash },
      codec: PlaybackModelCodec.codec(model: model, oracle: oracle)
    )
  }

  /// The model with replay causality for shrinking. Causal validity is the
  /// established playback rule: a delivered result must name an outstanding
  /// effect. Membership in the bounded search alphabet is not required.
  public static func generator(
    _ model: PlaybackStatelessnessModel
  ) -> Generate<PlaybackModelState, SearchAction, PlaybackModelObservation> {
    Generate(
      model: model,
      generate: { _, _ in nil },
      isEnabled: { state, action in
        if case .result(let effectID, _, _) = action {
          return state.node.coreState.outstandingEffects[effectID] != nil
        }
        return true
      },
      equalInputs: { $0 == $1 })
  }

  /// Search bounds for `configuration`.
  public static func searchConfig(_ configuration: PlaybackSearchConfiguration) -> SearchConfig {
    SearchConfig(
      maxStates: configuration.stateLimit,
      maxTransitions: UInt64(max(0, configuration.edgeLimit)),
      maxDepth: configuration.depthLimit
    )
  }

  public static func searchLimits(_ configuration: PlaybackSearchConfiguration) -> SearchLimits {
    let duration = configuration.timeLimitSeconds.flatMap { $0.isFinite ? max(0, $0) : nil }
    return SearchLimits(control: RunLimits(maxDuration: duration))
  }

  /// Playback verification keeps exploring past failed transitions, stated
  /// explicitly as collection with failing-successor expansion. Reduction is
  /// enabled for the `conservative` and `validation` POR modes.
  public static func graphOptions(
    configuration: PlaybackSearchConfiguration,
    maxRetainedFindings: Int = 64,
    maxGraphBytes: UInt64? = nil,
    events: ((GraphEvent<SearchAction, PlaybackModelObservation>) throws -> Void)? = nil
  ) -> GraphSearchOptions<PlaybackModelState, SearchAction, PlaybackModelObservation> {
    GraphSearchOptions(
      failurePolicy: .collect(
        maxRetainedFindings: maxRetainedFindings, expandFailingSuccessors: true),
      retention: GraphRetention(retainEdges: true, maxGraphBytes: maxGraphBytes),
      events: events,
      reduction: configuration.porMode == .disabled ? nil : PlaybackReductionPolicy.reduction)
  }

  static func step(
    action: SearchAction,
    node: PlaybackSearchNode,
    configuration: PlaybackSearchConfiguration
  ) -> (node: PlaybackSearchNode, observation: PlaybackModelObservation) {
    let applied = apply(action: action, to: node, configuration: configuration)
    let kind: PlaybackModelStepKind =
      if applied.calledProductionCore {
        .production
      } else if applied.gateRejected {
        .ingressRejected
      } else if action.isEnvironmentOnly {
        .environment
      } else {
        .notMaterialized
      }
    return (
      applied.node,
      PlaybackModelObservation(
        kind: kind, transition: applied.transition, envelope: applied.envelope,
        violations: applied.violations, isFairProgress: applied.isFairProgress
      )
    )
  }

  static func disposition(_ observation: PlaybackModelObservation) -> Disposition {
    switch observation.kind {
    case .environment: return .accepted
    case .ingressRejected: return .rejected("ingress")
    case .notMaterialized: return .ignored("not-materialized")
    case .production:
      switch observation.transition?.disposition {
      case .accepted?: return .accepted
      case .duplicate?: return .ignored("duplicate")
      case .stale(let reason)?: return .rejected("stale.\(reason.rawValue)")
      case .invalid?: return .rejected("invalid")
      case .ignoredAfterTermination?: return .ignored("post-termination")
      case nil: return .ignored("not-materialized")
      }
    }
  }

  static func transitionChecks(
    action: SearchAction,
    transition: Transition<PlaybackModelState, PlaybackModelObservation>,
    oracle: PlaybackSearchOracle
  ) -> [Check] {
    var violations = transition.outputs.flatMap(\.violations)
    if let violation = oracle.violation(
      for: action, transition: transition.outputs.first?.transition)
    {
      violations.append(violation)
    }
    return violations.map { .failed($0.name, $0.details) }
  }
}

extension SearchAction {
  /// Actions that only advance the modeled environment and never call production.
  var isEnvironmentOnly: Bool {
    switch self {
    case .command, .result, .lateResult, .runtimeFact: false
    case .seekPrerequisite, .seekAggregateReady, .recoveryPrerequisite, .trackPrerequisite,
      .recoveryAggregateReady, .trackAggregateReady, .queueOffer, .queueConsume,
      .resourceCustodyReturned:
      true
    }
  }
}

func stableHash(_ text: String) -> UInt64 {
  var hash: UInt64 = 14_695_981_039_346_656_037
  for byte in text.utf8 {
    hash ^= UInt64(byte)
    hash &*= 1_099_511_628_211
  }
  return hash
}
