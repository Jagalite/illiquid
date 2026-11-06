import Foundation
import IlliquidPlaybackModel
import Statelessness

/// Source and toolchain identity supplied by the runner.
public struct PlaybackVerificationProvenance: Codable, Hashable, Sendable {
  public let sourceRevision: String
  public let sourceDirty: Bool
  /// SHA-256 of each modified or untracked file, keyed by repository path.
  public let dirtyFiles: [String: String]
  public let swiftVersion: String
  public let platform: String

  public init(
    sourceRevision: String, sourceDirty: Bool, dirtyFiles: [String: String] = [:],
    swiftVersion: String = "unknown", platform: String = "unknown"
  ) {
    self.sourceRevision = sourceRevision
    self.sourceDirty = sourceDirty
    self.dirtyFiles = dirtyFiles
    self.swiftVersion = swiftVersion
    self.platform = platform
  }
}

/// Illiquid's qualification envelope around Statelessness evidence.
///
/// The traces are `stateless.continued-trace-json` v1 bytes produced by
/// `recordContinued` with `PlaybackModelCodec`. They are verified with
/// `replayContinued`, which compares every step's disposition, outputs,
/// post-state and checks. A verified prefix is never reported as reproduction.
public struct PlaybackVerificationArtifact: Codable, Equatable, Sendable {
  public struct Violation: Codable, Hashable, Sendable {
    public let phase: String
    public let property: String
    public let details: String
  }

  public struct Finding: Codable, Equatable, Sendable {
    public let index: UInt64
    public let edge: Int?
    public let violations: [Violation]
    public let requiresContinuedEvidence: Bool
  }

  public struct ShrinkStep: Codable, Equatable, Sendable {
    public let attempt: UInt64
    public let candidateLength: UInt64
    public let operation: String
    public let outcome: String
  }

  public struct Minimization: Codable, Equatable, Sendable {
    /// shrink64 or shrinkContinued.
    public let shrinker: String
    public let termination: String
    public let attempts: UInt64
    public let validatedOriginal: Bool
    public let history: [ShrinkStep]
  }

  public static let schema = "illiquid.playback-verification-artifact"
  public static let currentSchemaVersion: UInt32 = 1

  public let schema: String
  public let schemaVersion: UInt32
  public let engine: String
  public let engineRevision: String
  public let provenance: PlaybackVerificationProvenance
  /// "search", or "legacy-artifact-v1:<sha256 of the original bytes>".
  public let source: String
  public let model: PlaybackSearchModel
  public let seedProfile: String
  public let configuration: PlaybackSearchConfiguration
  public let oracle: PlaybackSearchOracle
  public let metadataName: String
  public let modelVersion: UInt32
  public let propertiesVersion: UInt32
  public let codecVersion: UInt32
  /// Present for artifacts produced by a search.
  public let search: PlaybackVerificationSummary?
  public let finding: Finding
  /// The selected property; the minimized witness ends with it.
  public let target: Violation
  public let originalWitness: [SearchAction]
  public let minimizedWitness: [SearchAction]
  public let minimization: Minimization
  public let originalTrace: String
  public let minimizedTrace: String
  /// Fields of a converted artifact that this format does not preserve.
  public let unpreservedFields: [String]
}

public enum PlaybackArtifactError: Error, CustomStringConvertible {
  case findingNotRetained(String)
  case targetNotReproduced(String)
  case incompatibleArtifact(String)

  public var description: String {
    switch self {
    case .findingNotRetained(let value): "finding not retained: \(value)"
    case .targetNotReproduced(let value): "target not reproduced: \(value)"
    case .incompatibleArtifact(let value): "incompatible artifact: \(value)"
    }
  }
}

public enum PlaybackVerificationArtifacts {
  public static func encode(_ artifact: PlaybackVerificationArtifact) throws -> [UInt8] {
    try CanonicalJSON.encode(artifact)
  }

  public static func decode(_ bytes: [UInt8]) throws -> PlaybackVerificationArtifact {
    let artifact = try CanonicalJSON.decode(PlaybackVerificationArtifact.self, from: bytes)
    guard artifact.schema == PlaybackVerificationArtifact.schema,
      artifact.schemaVersion == PlaybackVerificationArtifact.currentSchemaVersion
    else {
      throw PlaybackArtifactError.incompatibleArtifact(
        "\(artifact.schema) v\(artifact.schemaVersion)")
    }
    return artifact
  }

  /// One artifact per failed property, built from the first finding of that
  /// property. Findings whose witnesses were not retained are reported.
  public static func build(
    run: PlaybackVerificationRun,
    provenance: PlaybackVerificationProvenance,
    shrinkConfig: ShrinkConfig64 = ShrinkConfig64()
  ) throws -> (artifacts: [PlaybackVerificationArtifact], unretained: [String]) {
    var artifacts: [PlaybackVerificationArtifact] = []
    var unretained: [String] = []
    for property in run.report.failedProperties {
      guard
        let finding = run.report.findings.first(where: { $0.index == property.firstFinding }),
        let target = finding.violations.first(where: {
          $0.phase == property.phase && $0.check.id == property.id
        })
      else {
        unretained.append("\(property.phase):\(property.id)")
        continue
      }
      artifacts.append(
        try build(
          model: run.model, family: run.summary.model, seedProfile: run.summary.seedProfile,
          configuration: run.summary.configuration, oracle: run.oracle,
          provenance: provenance, source: "search", search: run.summary,
          finding: .init(
            index: finding.index, edge: finding.edge,
            violations: finding.violations.map(artifactViolation),
            requiresContinuedEvidence: finding.requiresContinuedEvidence),
          witness: finding.witness, target: target, shrinkConfig: shrinkConfig,
          unpreserved: []))
    }
    return (artifacts, unretained)
  }

  static func build(
    model: PlaybackStatelessnessModel, family: PlaybackSearchModel, seedProfile: String,
    configuration: PlaybackSearchConfiguration, oracle: PlaybackSearchOracle,
    provenance: PlaybackVerificationProvenance, source: String,
    search: PlaybackVerificationSummary?, finding: PlaybackVerificationArtifact.Finding,
    witness: [SearchAction], target: Statelessness.Violation, shrinkConfig: ShrinkConfig64,
    unpreserved: [String]
  ) throws -> PlaybackVerificationArtifact {
    let generator = PlaybackStatelessnessModels.generator(model)
    let minimized: [SearchAction]
    let minimization: PlaybackVerificationArtifact.Minimization
    if finding.requiresContinuedEvidence {
      let report = try shrinkContinued(
        generator, inputs: witness, target: target, config: shrinkConfig)
      minimized = report.base.minimized.inputs
      minimization = summarize(report.base, shrinker: "shrinkContinued")
    } else {
      let report = try shrink64(
        generator, original: Failure(inputs: witness, violations: [target]),
        config: shrinkConfig)
      minimized = report.minimized.inputs
      minimization = summarize(report, shrinker: "shrink64")
    }
    let original = try recordEvidence(model, witness)
    let reduced = try recordEvidence(model, minimized)
    for (trace, name) in [(original, "original"), (reduced, "minimized")] {
      guard endsWith(trace, target: target) else {
        throw PlaybackArtifactError.targetNotReproduced("\(name) witness for \(target.check.id)")
      }
    }
    let metadata = PlaybackModelCodec.metadata(model: family, oracle: oracle)
    return PlaybackVerificationArtifact(
      schema: PlaybackVerificationArtifact.schema,
      schemaVersion: PlaybackVerificationArtifact.currentSchemaVersion,
      engine: PlaybackVerificationEngine.name,
      engineRevision: PlaybackVerificationEngine.revision, provenance: provenance,
      source: source, model: family, seedProfile: seedProfile, configuration: configuration,
      oracle: oracle, metadataName: metadata.name, modelVersion: metadata.modelVersion,
      propertiesVersion: metadata.propertiesVersion, codecVersion: metadata.codecVersion,
      search: search, finding: finding, target: artifactViolation(target),
      originalWitness: witness, minimizedWitness: minimized, minimization: minimization,
      originalTrace: String(decoding: try encodeContinuedTrace(original), as: UTF8.self),
      minimizedTrace: String(decoding: try encodeContinuedTrace(reduced), as: UTF8.self),
      unpreservedFields: unpreserved)
  }

  static func recordEvidence(
    _ model: PlaybackStatelessnessModel, _ inputs: [SearchAction]
  ) throws -> ContinuedTrace {
    let trace = try recordContinued(model, inputs: InputIterator(values: inputs))
    guard trace.trace.termination == .completed, trace.trace.steps.count == inputs.count else {
      throw PlaybackArtifactError.targetNotReproduced(
        "recording ended with \(trace.trace.termination.rawValue): \(trace.trace.error)")
    }
    return trace
  }

  static func endsWith(_ trace: ContinuedTrace, target: Statelessness.Violation) -> Bool {
    guard let last = trace.trace.steps.last else { return false }
    return last.checks.contains { $0.status == .failed && $0.id == target.check.id }
  }

  static func artifactViolation(_ violation: Statelessness.Violation)
    -> PlaybackVerificationArtifact.Violation
  {
    .init(
      phase: violation.phase, property: violation.check.id, details: violation.check.details)
  }

  static func summarize(
    _ report: ShrinkReport64<SearchAction>, shrinker: String
  ) -> PlaybackVerificationArtifact.Minimization {
    PlaybackVerificationArtifact.Minimization(
      shrinker: shrinker, termination: report.termination, attempts: report.attempts,
      validatedOriginal: report.validatedOriginal,
      history: report.history.map {
        .init(
          attempt: $0.attempt, candidateLength: $0.candidateLength,
          operation: String(describing: $0.operation), outcome: String(describing: $0.outcome))
      })
  }

  /// Rebuilds the model named by an artifact.
  public static func model(
    for artifact: PlaybackVerificationArtifact
  ) throws -> PlaybackStatelessnessModel {
    try PlaybackStatelessnessModels.make(
      model: artifact.model, seedProfile: artifact.seedProfile,
      configuration: artifact.configuration, oracle: artifact.oracle)
  }
}

public struct PlaybackArtifactReplay: Sendable {
  public let originalComplete: Bool
  public let minimizedComplete: Bool
  public let targetReproduced: Bool
  public let productionTransitionCount: Int
  public var reproduced: Bool { originalComplete && minimizedComplete && targetReproduced }
}

public enum PlaybackArtifactReplayer {
  /// Replays both traces through the current model. Every recorded step must
  /// match exactly and the minimized trace must end with the target.
  public static func replay(_ artifact: PlaybackVerificationArtifact) throws
    -> PlaybackArtifactReplay
  {
    let model = try PlaybackVerificationArtifacts.model(for: artifact)
    let metadata = PlaybackModelCodec.metadata(model: artifact.model, oracle: artifact.oracle)
    guard metadata.name == artifact.metadataName,
      metadata.modelVersion == artifact.modelVersion,
      metadata.propertiesVersion == artifact.propertiesVersion,
      metadata.codecVersion == artifact.codecVersion
    else {
      throw PlaybackArtifactError.incompatibleArtifact(
        "artifact model \(artifact.metadataName) v\(artifact.modelVersion)/"
          + "\(artifact.propertiesVersion)/\(artifact.codecVersion) does not match the current model")
    }
    let original = try parseContinuedTrace(Array(artifact.originalTrace.utf8))
    let minimized = try parseContinuedTrace(Array(artifact.minimizedTrace.utf8))
    // Replay starts from the trace's recorded initial state, so bind both
    // traces to the named seed and both witnesses to their traces.
    let seed = try PlaybackModelCodec.encodeState(model.initialState())
    let originalActions = try original.trace.steps.map {
      try PlaybackModelCodec.decodeInput($0.input)
    }
    let bound =
      original.trace.initialState == seed && minimized.trace.initialState == seed
      && originalActions == artifact.originalWitness
    let originalReplay = try replayContinued(model, trace: original)
    let minimizedReplay = try replayContinued(model, trace: minimized)
    let actions = try minimized.trace.steps.map { try PlaybackModelCodec.decodeInput($0.input) }
    let outputs = try minimized.trace.steps.flatMap {
      try $0.outputs.map(PlaybackModelCodec.decodeOutput)
    }
    let target = Statelessness.Violation(
      phase: artifact.target.phase,
      check: .failed(artifact.target.property, artifact.target.details))
    return PlaybackArtifactReplay(
      originalComplete: originalReplay.completeReproduction && bound,
      minimizedComplete: minimizedReplay.completeReproduction
        && actions == artifact.minimizedWitness && bound,
      targetReproduced: PlaybackVerificationArtifacts.endsWith(minimized, target: target),
      productionTransitionCount: outputs.count(where: \.calledProductionModel))
  }
}

/// Reads schema-version-1 artifacts written by the original explorer and
/// re-executes their actions through the Statelessness model. Original bytes
/// are never modified; the converted artifact records their SHA-256.
public enum PlaybackLegacyArtifactConverter {
  public struct LegacyArtifact: Decodable {
    struct Step: Decodable {
      let action: SearchAction
      let postSearchDigest: String
      let invariantObservations: [PlaybackInvariantViolation]
    }
    struct Failure: Decodable {
      let invariantName: String
      let details: String
    }
    let schemaVersion: UInt32
    let model: PlaybackSearchModel
    let modelVersion: UInt32
    let seedProfile: String
    let configuration: PlaybackSearchConfiguration
    let oracle: PlaybackSearchOracle
    let sourceRevision: String
    let dirty: Bool
    let originalTrace: [Step]
    let minimizedTrace: [Step]
    let failedInvariant: Failure
  }

  /// Fields of the legacy format that the converted artifact does not keep.
  public static let unpreservedFields = [
    "explorerVersion", "summary", "initialState", "originalTrace[].preState",
    "originalTrace[].postState", "originalTrace[].preSearchDigest",
    "originalTrace[].generatedEffects", "minimizedTrace[].preState",
    "minimizedTrace[].postState", "minimizationHistory",
  ]

  public static func convert(
    _ bytes: [UInt8], sha256: String
  ) throws -> PlaybackVerificationArtifact {
    let legacy = try JSONDecoder().decode(LegacyArtifact.self, from: Data(bytes))
    guard legacy.schemaVersion == 1 else {
      throw PlaybackArtifactError.incompatibleArtifact("legacy schema \(legacy.schemaVersion)")
    }
    let current = PlaybackSearchModelDefinition(model: legacy.model).modelVersion
    guard legacy.modelVersion == current else {
      throw PlaybackArtifactError.incompatibleArtifact(
        "legacy model version \(legacy.modelVersion) needs its pinned historical checkout; "
          + "current is \(current)")
    }
    let model = try PlaybackStatelessnessModels.make(
      model: legacy.model, seedProfile: legacy.seedProfile,
      configuration: legacy.configuration, oracle: legacy.oracle)
    let witness = legacy.originalTrace.map(\.action)
    let recorded = try PlaybackVerificationArtifacts.recordEvidence(model, witness)
    // The converted replay must match every legacy post-state search digest.
    for (index, (legacyStep, step)) in zip(legacy.originalTrace, recorded.trace.steps)
      .enumerated()
    {
      let state = try PlaybackModelCodec.decodeState(step.postState)
      guard PlaybackSearchCanonicalizer.digest(state.key) == legacyStep.postSearchDigest else {
        throw PlaybackArtifactError.incompatibleArtifact(
          "legacy step \(index) search digest differs under current semantics")
      }
    }
    guard
      let last = recorded.trace.steps.last,
      let check = last.checks.first(where: {
        $0.status == .failed && $0.id == legacy.failedInvariant.invariantName
      })
    else {
      throw PlaybackArtifactError.targetNotReproduced(legacy.failedInvariant.invariantName)
    }
    let target = Statelessness.Violation(phase: "transition", check: check)
    let earlier = recorded.trace.steps.dropLast().contains {
      $0.checks.contains { $0.status == .failed }
    }
    return try PlaybackVerificationArtifacts.build(
      model: model, family: legacy.model, seedProfile: legacy.seedProfile,
      configuration: legacy.configuration, oracle: legacy.oracle,
      provenance: PlaybackVerificationProvenance(
        sourceRevision: legacy.sourceRevision, sourceDirty: legacy.dirty),
      source: "legacy-artifact-v1:\(sha256)", search: nil,
      finding: .init(
        index: 0, edge: nil,
        violations: last.checks.filter { $0.status == .failed }.map {
          .init(phase: "transition", property: $0.id, details: $0.details)
        },
        requiresContinuedEvidence: earlier),
      witness: witness, target: target, shrinkConfig: ShrinkConfig64(),
      unpreserved: unpreservedFields)
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

/// Bridges a minimized witness to a native runtime schedule. Promotion is not
/// evidence that simulated playback exercised real decoders or renderers.
public enum PlaybackRuntimePromotion {
  public static func promote(
    _ artifact: PlaybackVerificationArtifact
  ) throws -> PlaybackRuntimePromotionTrace? {
    let trace = try parseContinuedTrace(Array(artifact.minimizedTrace.utf8))
    var steps: [PlaybackRuntimePromotionStep] = []
    for step in trace.trace.steps {
      let action = try PlaybackModelCodec.decodeInput(step.input)
      let observation = try step.outputs.first.map(PlaybackModelCodec.decodeOutput)
      switch action {
      case .seekPrerequisite, .seekAggregateReady, .recoveryPrerequisite,
        .trackPrerequisite, .recoveryAggregateReady, .trackAggregateReady,
        .queueOffer, .queueConsume, .resourceCustodyReturned:
        return nil
      case .runtimeFact(_, let ingress) where ingress != .current:
        return nil
      default:
        steps.append(
          PlaybackRuntimePromotionStep(
            action: action, envelope: observation?.envelope,
            effectContextPreserved: contextIsPreserved(action, observation?.envelope)))
      }
    }
    return PlaybackRuntimePromotionTrace(modelVersion: artifact.modelVersion, steps: steps)
  }

  static func contextIsPreserved(_ action: SearchAction, _ envelope: PlaybackEventEnvelope?)
    -> Bool
  {
    guard case .effectResult(let result)? = envelope?.event else { return true }
    guard case .result(let effectID, _, _) = action else { return true }
    return result.context.effectID == effectID
  }
}
