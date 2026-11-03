import Foundation
import IlliquidPlaybackModel
import Statelessness

/// The Statelessness engine identity recorded in every summary and artifact.
public enum PlaybackVerificationEngine {
  public static let name = "statelessness-swift"
  /// Must equal the exact revision pinned in Package.swift.
  public static let revision = "3fbdca7c49be3cf32da613f887a7f149e0b97087"
  public static let profiles = swiftExtensionProfiles
}

public struct PlaybackVerificationSummary: Codable, Hashable, Sendable {
  public let schemaVersion: UInt32
  public let engine: String
  public let engineRevision: String
  public let model: PlaybackSearchModel
  public let modelVersion: UInt32
  public let propertiesVersion: UInt32
  public let codecVersion: UInt32
  public let seedProfile: String
  public let configuration: PlaybackSearchConfiguration
  public let failurePolicy: String
  /// Statelessness termination: graph_exhausted, depth_bound, state_limit,
  /// transition_limit, deadline, graph_retention_limit, model_error, ...
  public let termination: String
  /// exhaustive, bounded(depth), or incomplete(reason).
  public let coverage: String
  /// True only for a finished search (exhaustive or bounded by depth).
  public let completeWithinBounds: Bool
  public let stateCount: Int
  /// Evaluated transitions, including reduced edges.
  public let edgeCount: Int
  public let graphEdgeCount: Int
  public let duplicateEdgeCount: Int
  public let reducedEdgeCount: Int
  public let rejectedSuccessorCount: Int
  public let productionTransitionCount: Int
  public let gateRejectionCount: Int
  public let peakFrontier: Int
  public let deepestCompletedLayer: Int
  public let findingCount: UInt64
  public let failedProperties: [String]
  public let reductionPolicyVersion: UInt32
  public let validatedDiamondCount: Int
  /// Noncommuting pairs not declared dependent: a validation failure.
  public let nonCommutingDiamondCount: Int
  /// Noncommuting pairs declared dependent by the reduction policy.
  public let declaredDependentDiamondCount: Int
  public let estimatedGraphBytes: UInt64
  /// FNV-1a over the sorted digests of every admitted canonical key.
  public let canonicalDigest: String
}

public struct PlaybackVerificationRun {
  public let summary: PlaybackVerificationSummary
  public let oracle: PlaybackSearchOracle
  public let model: PlaybackStatelessnessModel
  public let report: PlaybackGraphReport
  public let progress: ProgressReport
  public let diamonds: DiamondReport<SearchAction>?
}

public enum PlaybackVerifier {
  public struct Progress: Sendable {
    public let model: PlaybackSearchModel
    public let seedProfile: String
    public let depth: Int
    public let stateCount: Int
    public let edgeCount: UInt64
  }

  public static func run(
    model: PlaybackSearchModel,
    seedProfile: String,
    configuration: PlaybackSearchConfiguration,
    oracle: PlaybackSearchOracle = .production,
    maxRetainedFindings: Int = 64,
    maxGraphBytes: UInt64? = nil,
    progressHandler: (@Sendable (Progress) -> Void)? = nil
  ) throws -> PlaybackVerificationRun {
    let statelessModel = try PlaybackStatelessnessModels.make(
      model: model, seedProfile: seedProfile, configuration: configuration, oracle: oracle)
    var states = 1
    var transitions: UInt64 = 0
    let events: ((GraphEvent<SearchAction, PlaybackModelObservation>) throws -> Void)? =
      progressHandler.map { handler in
        { event in
          switch event {
          case .successorAdmitted: states += 1
          case .edgeEvaluated: transitions += 1
          case .layerCompleted(let depth):
            handler(
              Progress(
                model: model, seedProfile: seedProfile, depth: depth, stateCount: states,
                edgeCount: transitions))
          default: break
          }
        }
      }
    let report = try exploreGraph(
      statelessModel,
      config: PlaybackStatelessnessModels.searchConfig(configuration),
      limits: PlaybackStatelessnessModels.searchLimits(configuration),
      options: PlaybackStatelessnessModels.graphOptions(
        configuration: configuration, maxRetainedFindings: maxRetainedFindings,
        maxGraphBytes: maxGraphBytes, events: events))
    let progress = try PlaybackProgressPolicy.analyze(report)
    let diamonds: DiamondReport<SearchAction>? =
      configuration.porMode == .validation
      ? try PlaybackReductionPolicy.validateDiamonds(model: statelessModel, report: report)
      : nil
    return PlaybackVerificationRun(
      summary: summarize(
        model: model, seedProfile: seedProfile, configuration: configuration, oracle: oracle,
        report: report, diamonds: diamonds),
      oracle: oracle, model: statelessModel, report: report, progress: progress,
      diamonds: diamonds)
  }

  static func summarize(
    model: PlaybackSearchModel, seedProfile: String,
    configuration: PlaybackSearchConfiguration, oracle: PlaybackSearchOracle,
    report: PlaybackGraphReport, diamonds: DiamondReport<SearchAction>?
  ) -> PlaybackVerificationSummary {
    let metadata = PlaybackModelCodec.metadata(model: model, oracle: oracle)
    var layers: [Int: Int] = [:]
    for node in report.nodes { layers[node.depth, default: 0] += 1 }
    var production = 0
    var gate = 0
    for edge in report.edges {
      if edge.outputs.first?.calledProductionModel == true { production += 1 }
      if edge.outputs.first?.kind == .ingressRejected { gate += 1 }
    }
    let complete: Bool
    let coverage: String
    switch report.coverage {
    case .exhaustive:
      complete = true
      coverage = "exhaustive"
    case .bounded(let depthCutoff, let failurePruned):
      complete = true
      coverage = "bounded(depthCutoff:\(depthCutoff),failurePruned:\(failurePruned))"
    case .incomplete(let reason):
      complete = false
      coverage = "incomplete(\(reason))"
    }
    return PlaybackVerificationSummary(
      schemaVersion: 1, engine: PlaybackVerificationEngine.name,
      engineRevision: PlaybackVerificationEngine.revision,
      model: model, modelVersion: metadata.modelVersion,
      propertiesVersion: metadata.propertiesVersion, codecVersion: metadata.codecVersion,
      seedProfile: seedProfile, configuration: configuration,
      failurePolicy: "collect(expandFailingSuccessors:true)",
      termination: report.termination, coverage: coverage, completeWithinBounds: complete,
      stateCount: report.states, edgeCount: Int(clamping: report.transitions),
      graphEdgeCount: Int(clamping: report.graphEdges),
      duplicateEdgeCount: Int(clamping: report.duplicateEdges),
      reducedEdgeCount: Int(clamping: report.reducedEdges),
      rejectedSuccessorCount: Int(clamping: report.rejectedSuccessors),
      productionTransitionCount: production, gateRejectionCount: gate,
      peakFrontier: layers.values.max() ?? 0,
      deepestCompletedLayer: max(0, report.completedLayers - 1),
      findingCount: report.findingCount,
      failedProperties: report.failedProperties.map { "\($0.phase):\($0.id)" },
      reductionPolicyVersion: PlaybackReductionPolicy.version,
      validatedDiamondCount: Int(clamping: diamonds?.validated ?? 0),
      nonCommutingDiamondCount: diamonds?.nonCommuting.count(where: {
        !PlaybackReductionPolicy.isDeclaredDependent($0.first, $0.second)
      }) ?? 0,
      declaredDependentDiamondCount: diamonds?.nonCommuting.count(where: {
        PlaybackReductionPolicy.isDeclaredDependent($0.first, $0.second)
      }) ?? 0,
      estimatedGraphBytes: report.estimatedGraphBytes,
      canonicalDigest: canonicalDigest(report.nodes.map(\.state.key)))
  }

  public static func canonicalDigest(_ keys: [PlaybackSearchStateKey]) -> String {
    var hash: UInt64 = 14_695_981_039_346_656_037
    for digest in keys.map(PlaybackSearchCanonicalizer.digest).sorted() {
      for byte in digest.utf8 {
        hash ^= UInt64(byte)
        hash &*= 1_099_511_628_211
      }
    }
    return "fnv1a64:" + String(hash, radix: 16)
  }
}

/// One seed's qualification record. Coverage, findings, progress, diamonds and
/// trend are separate facts; `passed` never treats incomplete coverage as
/// success.
public struct PlaybackVerificationRecord: Codable, Sendable {
  public let summary: PlaybackVerificationSummary
  public let progress: PlaybackProgressReport
  public let progressGraphComplete: Bool
  public let failureArtifactPaths: [String]
  public let unretainedFindings: [String]
  public let trendViolations: [PlaybackSearchTrendViolation]
  public let provenance: PlaybackVerificationProvenance
  public let maxGraphBytes: UInt64?
  /// Wall time of the search and analysis on the recording host; cost
  /// evidence only, never part of acceptance or resume identity.
  public let elapsedSeconds: Double?
  public let evidenceStatement: String

  public init(
    summary: PlaybackVerificationSummary, progress: PlaybackProgressReport,
    progressGraphComplete: Bool, failureArtifactPaths: [String], unretainedFindings: [String],
    trendViolations: [PlaybackSearchTrendViolation], provenance: PlaybackVerificationProvenance,
    maxGraphBytes: UInt64?, elapsedSeconds: Double? = nil
  ) {
    self.summary = summary
    self.progress = progress
    self.progressGraphComplete = progressGraphComplete
    self.failureArtifactPaths = failureArtifactPaths
    self.unretainedFindings = unretainedFindings
    self.trendViolations = trendViolations
    self.provenance = provenance
    self.maxGraphBytes = maxGraphBytes
    self.elapsedSeconds = elapsedSeconds
    let clean =
      summary.findingCount == 0 && progress.stuckStates.isEmpty
      && progress.closedNonterminalSCCs.isEmpty && trendViolations.isEmpty
      && summary.nonCommutingDiamondCount == 0
    evidenceStatement =
      if !clean {
        "State-space qualification found a violation; inspect this record and its artifacts."
      } else if !summary.completeWithinBounds {
        "Incomplete search (\(summary.coverage)); no violation found in the explored part, "
          + "which is not coverage of the recorded bounds."
      } else {
        "No invariant or progress violation within the recorded model/version/configuration "
          + "bounds (\(summary.coverage))."
      }
  }

  /// No finding, progress, diamond, trend or retention failure in the
  /// explored part. Says nothing about coverage.
  public var clean: Bool {
    summary.findingCount == 0 && progress.stuckStates.isEmpty
      && progress.closedNonterminalSCCs.isEmpty && trendViolations.isEmpty
      && summary.nonCommutingDiamondCount == 0 && unretainedFindings.isEmpty
  }

  /// Qualification passes only for a clean, finished search.
  public var passed: Bool { clean && summary.completeWithinBounds }

  /// The same record with trend violations re-evaluated against `baseline`.
  public func reevaluated(against baseline: PlaybackSearchTrendBaseline?) -> Self {
    Self(
      summary: summary, progress: progress, progressGraphComplete: progressGraphComplete,
      failureArtifactPaths: failureArtifactPaths, unretainedFindings: unretainedFindings,
      trendViolations: baseline.map { PlaybackSearchTrendEvaluator.evaluate(summary, against: $0) }
        ?? [],
      provenance: provenance, maxGraphBytes: maxGraphBytes, elapsedSeconds: elapsedSeconds)
  }
}
