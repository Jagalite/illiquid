import CryptoKit
import Foundation
import IlliquidPlaybackModel
import Statelessness
import Testing

@testable import IlliquidPlaybackStateSpace

/// Statelessness verification against immutable migration evidence.
///
/// The golden fixture was recorded from the retired explorer (oracle revision
/// `ea2ff568`) after the Statelessness engine passed strict edge-by-edge
/// parity with it; see Documentation/StatelessnessMigration/STATUS.md.
@Suite("Statelessness verification")
struct StatelessnessMigrationTests {
  static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("Fixtures")
  static let golden = try! JSONDecoder().decode(
    Golden.self,
    from: Data(contentsOf: fixtures.appendingPathComponent("statelessness-migration-golden-v1.json")))

  static func configuration(_ por: PlaybackSearchPORMode = .disabled)
    -> PlaybackSearchConfiguration
  {
    PlaybackSearchConfiguration.validation(depthLimit: golden.depthLimit, porMode: por)
      .withTimeLimitSeconds(nil)
  }

  static var allSeeds: [(PlaybackSearchModel, String)] {
    PlaybackSearchModel.allCases.flatMap { model in
      PlaybackSearchModelDefinition(model: model).inventory.seedProfiles.map { (model, $0) }
    }
  }

  static func model(
    _ model: PlaybackSearchModel, _ seed: String,
    oracle: PlaybackSearchOracle = .production,
    configuration: PlaybackSearchConfiguration = configuration()
  ) throws -> PlaybackStatelessnessModel {
    try PlaybackStatelessnessModels.make(
      model: model, seedProfile: seed, configuration: configuration, oracle: oracle)
  }

  static func explore(
    _ statelessModel: PlaybackStatelessnessModel,
    configuration: PlaybackSearchConfiguration = configuration()
  ) throws -> PlaybackGraphReport {
    try exploreGraph(
      statelessModel,
      config: PlaybackStatelessnessModels.searchConfig(configuration),
      limits: PlaybackStatelessnessModels.searchLimits(configuration),
      options: PlaybackStatelessnessModels.graphOptions(
        configuration: configuration, maxRetainedFindings: 100_000))
  }

  // MARK: Golden evidence.

  @Test
  func everySeedMatchesTheGoldenEvidence() throws {
    #expect(Self.golden.seeds.count == Self.allSeeds.count)
    for (model, seed) in Self.allSeeds {
      let name = "\(model.rawValue)/\(seed)"
      let expected = try #require(Self.golden.seed(model, seed), "\(name)")
      let run = try PlaybackVerifier.run(
        model: model, seedProfile: seed, configuration: Self.configuration(),
        maxRetainedFindings: 100_000)
      #expect(run.summary.completeWithinBounds, "\(name)")
      #expect(Golden.Seed(run: run) == expected.unreduced, "\(name)")
      #expect(try edgeSequenceDigest(run.report) == expected.edgeSequenceSHA256, "\(name)")
      #expect(run.summary.findingCount == 0, "\(name)")

      let reduced = try PlaybackVerifier.run(
        model: model, seedProfile: seed, configuration: Self.configuration(.validation))
      #expect(reduced.summary.stateCount == expected.reducedStates, "\(name)")
      #expect(reduced.summary.canonicalDigest == expected.canonicalDigest, "\(name)")
      #expect(reduced.summary.reducedEdgeCount == expected.reducedEdges, "\(name)")
      #expect(reduced.summary.validatedDiamondCount == expected.validatedDiamonds, "\(name)")
      // The frozen reducer counted every noncommuting pair. Policy v2 splits
      // declared-dependent queue pairs from validation failures.
      #expect(
        reduced.summary.nonCommutingDiamondCount + reduced.summary.declaredDependentDiamondCount
          == expected.nonCommutingDiamonds, "\(name)")
      #expect(reduced.summary.nonCommutingDiamondCount == 0, "\(name)")
      let comparison = try compareReduction(
        run.model, unreduced: run.report, reduced: reduced.report,
        progress: PlaybackProgressPolicy.reductionPredicates)
      #expect(comparison.equivalent, "\(name): \(comparison)")
    }
  }

  @Test
  func injectedOracleFailuresAreCollectedWithoutStopping() throws {
    let oracle = PlaybackSearchOracle.failOnActionClass(
      "command.pause", invariantName: "injectedPauseOracle")
    let run = try PlaybackVerifier.run(
      model: .seek, seedProfile: "ready-playing", configuration: Self.configuration(),
      oracle: oracle, maxRetainedFindings: 100_000)
    let expected = try #require(Self.golden.seed(.seek, "ready-playing"))
    #expect(run.report.findingCount > 1)
    #expect(run.report.failedProperties.map(\.id) == ["injectedPauseOracle"])
    #expect(run.report.findings.contains { $0.requiresContinuedEvidence })
    // A property never prunes exploration.
    #expect(run.summary.stateCount == expected.states)
    #expect(run.summary.canonicalDigest == expected.canonicalDigest)
  }

  @Test
  func cachedSearchIdentityMatchesRecomputedIdentity() throws {
    for (model, seed) in Self.allSeeds.prefix(8) {
      let report = try Self.explore(Self.model(model, seed))
      for node in report.nodes {
        #expect(node.state.key == PlaybackSearchCanonicalizer.key(for: node.state.node))
      }
    }
  }

  /// Production is called exactly once for commands and accepted ingress, and
  /// never for rejected ingress or environment steps. Each core call advances
  /// the envelope sequence by exactly one.
  @Test
  func stepsCallProductionAtMostOnceAndOnlyWhenAdmitted() throws {
    var production = 0
    var other = 0
    for (model, seed) in Self.allSeeds {
      let report = try Self.explore(Self.model(model, seed))
      let definition = PlaybackSearchModelDefinition(model: model)
      for node in report.nodes.prefix(40) {
        let source = node.state.node
        for action in definition.enabledActions(
          for: source, configuration: Self.configuration())
        {
          let (successor, observation) = PlaybackStatelessnessModels.step(
            action: action, node: source, configuration: Self.configuration())
          let calls = successor.nextSequence - source.nextSequence
          #expect(calls == (observation.calledProductionModel ? 1 : 0))
          #expect((observation.envelope != nil) == observation.calledProductionModel)
          switch observation.kind {
          case .production:
            production += 1
            #expect(!action.isEnvironmentOnly)
          case .ingressRejected:
            other += 1
            if case .runtimeFact(_, let ingress) = action {
              #expect(ingress != .current)
            } else {
              Issue.record("non-ingress action rejected at the gate: \(action)")
            }
          case .environment:
            other += 1
            #expect(action.isEnvironmentOnly)
          case .notMaterialized:
            other += 1
          }
        }
      }
    }
    #expect(production > 0)
    #expect(other > 0)
  }

  // MARK: Negative controls. Each must be caught by the golden comparison.

  static func goldenMismatch(_ broken: PlaybackStatelessnessModel) throws -> Bool {
    let report = try explore(broken)
    let expected = golden.seed(.seek, "ready-playing")!
    let digest = try edgeSequenceDigest(report)
    return report.states != expected.states
      || Int(report.transitions) != expected.transitions
      || PlaybackVerifier.canonicalDigest(report.nodes.map(\.state.key))
        != expected.canonicalDigest
      || digest != expected.edgeSequenceSHA256
  }

  @Test
  func intactModelMatchesTheGoldenControlSeed() throws {
    #expect(try !Self.goldenMismatch(Self.model(.seek, "ready-playing")))
  }

  @Test
  func negativeControlMissingTransitionIsDetected() throws {
    var broken = try Self.model(.seek, "ready-playing")
    let inputs = broken.inputs!
    broken.inputs = { state in
      var values: [SearchAction] = []
      let iterator = try inputs(state)
      while let value = try iterator.next() { values.append(value) }
      return InputIterator(values: Array(values.dropLast()))
    }
    #expect(try Self.goldenMismatch(broken))
  }

  @Test
  func negativeControlIncorrectIdentityMergingIsDetected() throws {
    var broken = try Self.model(.seek, "ready-playing")
    broken.equalStates = { $0.key.lifecycle == $1.key.lifecycle }
    broken.hashState = { stableHash($0.key.lifecycle) }
    #expect(try Self.goldenMismatch(broken))
  }

  @Test
  func negativeControlStaleIngressAdmissionIsDetected() throws {
    var detected = 0
    for (model, seed) in Self.allSeeds {
      var broken = try Self.model(model, seed)
      let step = broken.step
      broken.step = { state, action in
        if case .runtimeFact(let fact, .previous) = action {
          return try step(state, .runtimeFact(fact, ingress: .current))
        }
        return try step(state, action)
      }
      let digest = try edgeSequenceDigest(Self.explore(broken))
      if digest != Self.golden.seed(model, seed)!.edgeSequenceSHA256 { detected += 1 }
    }
    #expect(detected > 0)
  }

  @Test
  func negativeControlForcedAcceptedDispositionIsDetected() throws {
    var broken = try Self.model(.seek, "ready-playing")
    let step = broken.step
    broken.step = { state, action in
      let transition = try step(state, action)
      return Transition(state: transition.state, outputs: transition.outputs)
    }
    #expect(try Self.goldenMismatch(broken))
  }

  @Test
  func negativeControlOmittedObservedEffectsAreDetected() throws {
    var broken = try Self.model(.seek, "ready-playing")
    let step = broken.step
    broken.step = { state, action in
      let transition = try step(state, action)
      let outputs = transition.outputs.map { observation in
        guard let production = observation.transition, !production.effects.isEmpty else {
          return observation
        }
        return PlaybackModelObservation(
          kind: observation.kind,
          transition: PlaybackTransition(
            disposition: production.disposition, effects: [],
            snapshot: production.snapshot,
            invariantViolations: production.invariantViolations),
          envelope: observation.envelope, violations: observation.violations,
          isFairProgress: observation.isFairProgress)
      }
      return Transition(
        state: transition.state, outputs: outputs, disposition: transition.disposition)
    }
    #expect(try Self.goldenMismatch(broken))
  }

  @Test
  func negativeControlSuppressedChecksAreDetected() throws {
    let oracle = PlaybackSearchOracle.failOnActionClass(
      "command.pause", invariantName: "injectedPauseOracle")
    var broken = try Self.model(.seek, "ready-playing", oracle: oracle)
    let checks = broken.checkTransition!
    broken.checkTransition = { state, action, transition in
      try checks(state, action, transition).filter { $0.status != .failed }
    }
    let intact = try Self.explore(Self.model(.seek, "ready-playing", oracle: oracle))
    let suppressed = try Self.explore(broken)
    #expect(intact.findingCount > 0)
    #expect(suppressed.findingCount == 0)
    let intactDigest = try edgeSequenceDigest(intact)
    let suppressedDigest = try edgeSequenceDigest(suppressed)
    #expect(intactDigest != suppressedDigest)
  }

  @Test
  func negativeControlFalseProgressIsDetected() throws {
    // Declaring external waits to be transactions without fair edges is a
    // false progress claim; it must change the recorded progress classes.
    let (model, seed) = try #require(
      Self.allSeeds.first { Self.golden.seed($0.0, $0.1)!.progress.externalWaitStates > 0 })
    let report = try Self.explore(Self.model(model, seed))
    let wrong = try analyzeProgress(
      ProgressGraph(report: report, fair: { _ in false }),
      kind: {
        let kind = PlaybackProgressPolicy.kind(report.nodes[$0].state.node)
        return kind == .externalWait ? .transaction : kind
      },
      rank: { PlaybackProgressPolicy.rank(report.nodes[$0].state.node) })
    #expect(PlaybackProgressPolicy.summary(wrong) != Self.golden.seed(model, seed)!.progress)
    #expect(!wrong.stuckStates.isEmpty)
  }

  @Test
  func negativeControlIncorrectReductionIsDetected() throws {
    // Statelessness refuses unsound collapses itself (equal disposition, checks
    // and successor are required), so the realistic defect is pruning: a
    // reduction that drops failed results before execution. The
    // reduced-versus-unreduced comparison must reject it.
    let model = try Self.model(.stopShutdown, "opening")
    let unreduced = try Self.explore(model)
    var pruned = model
    let inputs = model.inputs!
    pruned.inputs = { state in
      var values: [SearchAction] = []
      let iterator = try inputs(state)
      while let value = try iterator.next() {
        if case .result(_, .failed, _) = value { continue }
        values.append(value)
      }
      return InputIterator(values: values)
    }
    let reduced = try Self.explore(pruned)
    let comparison = try compareReduction(
      model, unreduced: unreduced, reduced: reduced,
      progress: PlaybackProgressPolicy.reductionPredicates)
    #expect(!comparison.equivalent)
    #expect(!comparison.missingInReduced.isEmpty || !comparison.unrepresentedEdges.isEmpty)
  }

  @Test
  func onlySameStreamQueueOfferAndConsumeAreDeclaredDependent() throws {
    typealias Policy = PlaybackReductionPolicy
    #expect(Policy.isDeclaredDependent(.queueOffer(.video), .queueConsume(.video)))
    #expect(Policy.isDeclaredDependent(.queueConsume(.audio), .queueOffer(.audio)))
    #expect(!Policy.isDeclaredDependent(.queueOffer(.video), .queueConsume(.audio)))
    #expect(!Policy.isDeclaredDependent(.queueOffer(.video), .queueOffer(.video)))
    #expect(!Policy.isDeclaredDependent(.seekAggregateReady, .queueOffer(.video)))
    let run = try PlaybackVerifier.run(
      model: .prerollBuffering, seedProfile: "playing-av",
      configuration: Self.configuration(.validation))
    let diamonds = try #require(run.diamonds)
    #expect(run.summary.declaredDependentDiamondCount > 0)
    #expect(run.summary.nonCommutingDiamondCount == 0)
    #expect(diamonds.nonCommuting.allSatisfy { Policy.isDeclaredDependent($0.first, $0.second) })
  }

  @Test
  func negativeControlUndeclaredNoncommutingPairFailsValidation() throws {
    // Without the declaration, the same diamonds are validation failures; with
    // a declaration that names a different stream, they still are.
    let run = try PlaybackVerifier.run(
      model: .prerollBuffering, seedProfile: "playing-av",
      configuration: Self.configuration(.validation))
    let diamonds = try #require(run.diamonds)
    let undeclaredWithoutPolicy = diamonds.nonCommuting.count
    let undeclaredWithWrongStream = diamonds.nonCommuting.count {
      switch ($0.first, $0.second) {
      case (.queueOffer(let a), .queueConsume(let b)), (.queueConsume(let a), .queueOffer(let b)):
        a == b  // the wrong declaration covers cross-stream pairs only
      default: true
      }
    }
    #expect(undeclaredWithoutPolicy > 0)
    #expect(undeclaredWithWrongStream > 0)
    #expect(run.summary.nonCommutingDiamondCount == 0)
  }

  // MARK: Caps and coverage.

  static func capped(states: Int, edges: Int, depth: Int = 5) -> PlaybackSearchConfiguration {
    PlaybackSearchConfiguration(
      profile: "validation", depthLimit: depth, generationLimit: 1, pendingEffectLimit: 3,
      lateResultLimit: 1, failureLimit: 1, duplicateLimit: 1, interruptLimit: 1,
      stateLimit: states, edgeLimit: edges, porMode: .disabled)
  }

  @Test
  func capBoundariesReportExactCoverage() throws {
    let expected = try #require(Self.golden.seed(.seek, "ready-playing"))
    let cases: [(PlaybackSearchConfiguration, String)] = [
      (Self.capped(states: expected.states, edges: 1_000_000), "depth_bound"),
      (Self.capped(states: expected.states - 1, edges: 1_000_000), "state_limit"),
      (Self.capped(states: 10, edges: 1_000_000), "state_limit"),
      (Self.capped(states: 1_000_000, edges: expected.transitions), "depth_bound"),
      (Self.capped(states: 1_000_000, edges: expected.transitions - 1), "transition_limit"),
      (Self.capped(states: 1_000_000, edges: 3), "transition_limit"),
      (Self.capped(states: 1_000_000, edges: 1_000_000, depth: 0), "depth_bound"),
    ]
    for (configuration, termination) in cases {
      let run = try PlaybackVerifier.run(
        model: .seek, seedProfile: "ready-playing", configuration: configuration)
      #expect(run.summary.termination == termination, "\(configuration)")
      #expect(run.summary.completeWithinBounds == (termination == "depth_bound"))
      if termination != "depth_bound" {
        #expect(run.summary.coverage == "incomplete(\(termination))")
        #expect(!run.progress.graphComplete)
      }
      if termination == "state_limit" {
        #expect(run.report.edges.last?.target == .rejected("state_limit"))
      }
    }
  }

  @Test
  func graphByteBudgetEndsTheSearchAsIncompleteWithoutCrashing() throws {
    let run = try PlaybackVerifier.run(
      model: .seek, seedProfile: "ready-playing", configuration: Self.configuration(),
      maxGraphBytes: 200_000)
    #expect(run.summary.termination == "graph_retention_limit")
    #expect(run.summary.coverage == "incomplete(graph_retention_limit)")
    #expect(!run.summary.completeWithinBounds)
    #expect(!run.progress.graphComplete)
    #expect(run.progress.unmeasuredStates > 0)
    // An edge-charge cutoff leaves `edgesRetained` false; progress must still
    // be computed from the retained edges rather than throwing.
    var unretained = run.report
    unretained.edgesRetained = false
    #expect(throws: (any Error).self) {
      try ProgressGraph(report: unretained, fair: PlaybackProgressPolicy.isFair)
    }
    let progress = try PlaybackProgressPolicy.analyze(unretained)
    #expect(progress == run.progress)
  }

  /// Discrepancy D3: the edge that reaches the state cap keeps its finding.
  @Test
  func stateCapEdgeFindingIsReported() throws {
    var model = try Self.model(.seek, "ready-playing")
    model.checkTransition = { _, _, _ in [.failed("everyEdgeFails", "control")] }
    let configuration = Self.capped(states: 1, edges: 1_000_000)
    let report = try Self.explore(model, configuration: configuration)
    #expect(report.termination == "state_limit")
    let capEdge = try #require(report.edges.last)
    #expect(capEdge.target == .rejected("state_limit"))
    #expect(report.findings.last?.edge == capEdge.id)
    #expect(report.findingCount == UInt64(report.edges.count))
  }

  @Test
  func searchIdentityHashIsConsistentWithCanonicallyEquivalentText() throws {
    let seed = try PlaybackSearchModelDefinition(model: .seek).makeSeed(profile: "ready-playing")
    func node(_ profile: String) -> PlaybackSearchNode {
      PlaybackSearchNode(
        model: seed.model, seedProfile: profile, coreState: seed.coreState,
        environment: seed.environment, lateResults: seed.lateResults, ghost: seed.ghost,
        nextSequence: seed.nextSequence, depth: seed.depth)
    }
    let composed = PlaybackModelState(node: node("\u{e9}"))
    let decomposed = PlaybackModelState(node: node("e\u{301}"))
    #expect(composed.key == decomposed.key)
    #expect(composed.keyHash == decomposed.keyHash)
  }

  @Test
  func incompleteCleanRecordDoesNotPassAndResumeUsesTheCurrentBaseline() throws {
    let timed = try PlaybackVerifier.run(
      model: .seek, seedProfile: "ready-playing",
      configuration: PlaybackSearchConfiguration.validation(depthLimit: 8).withTimeLimitSeconds(0))
    let provenance = PlaybackVerificationProvenance(sourceRevision: "test", sourceDirty: false)
    func record(_ run: PlaybackVerificationRun) -> PlaybackVerificationRecord {
      PlaybackVerificationRecord(
        summary: run.summary, progress: PlaybackProgressPolicy.summary(run.progress),
        progressGraphComplete: run.progress.graphComplete, failureArtifactPaths: [],
        unretainedFindings: [], trendViolations: [], provenance: provenance, maxGraphBytes: nil)
    }
    let incomplete = record(timed)
    #expect(incomplete.clean)
    #expect(!incomplete.passed)

    let finished = record(
      try PlaybackVerifier.run(
        model: .seek, seedProfile: "ready-playing", configuration: Self.configuration()))
    #expect(finished.passed)
    let baseline = PlaybackSearchTrendBaseline(entries: [
      .init(
        model: .seek, seedProfile: "ready-playing", modelVersion: finished.summary.modelVersion,
        stateCount: finished.summary.stateCount, edgeCount: finished.summary.edgeCount,
        canonicalDigest: "different")
    ])
    let resumed = finished.reevaluated(against: baseline)
    #expect(resumed.trendViolations.contains { $0.kind == .normalizationDrift })
    #expect(!resumed.passed)
  }

  // MARK: Codec.

  @Test
  func stateCodecIsLosslessAndDeterministicForAdmittedStates() throws {
    for (model, seed) in Self.allSeeds {
      let report = try Self.explore(Self.model(model, seed))
      for node in report.nodes.prefix(60) {
        let bytes = try PlaybackModelCodec.encodeState(node.state)
        let decoded = try PlaybackModelCodec.decodeState(bytes)
        #expect(decoded.node.coreState == node.state.node.coreState)
        #expect(decoded.node.environment == node.state.node.environment)
        #expect(decoded.node.lateResults == node.state.node.lateResults)
        #expect(decoded.node.ghost == node.state.node.ghost)
        #expect(decoded.node.nextSequence == node.state.node.nextSequence)
        #expect(decoded.key == node.state.key)
        #expect(try PlaybackModelCodec.encodeState(decoded) == bytes)
      }
      for edge in report.edges.prefix(200) {
        let input = try PlaybackModelCodec.encodeInput(edge.input)
        #expect(try PlaybackModelCodec.decodeInput(input) == edge.input)
        for output in edge.outputs {
          let bytes = try PlaybackModelCodec.encodeOutput(output)
          #expect(try PlaybackModelCodec.decodeOutput(bytes) == output)
        }
      }
    }
  }

  @Test
  func canonicalJSONIgnoresUnorderedCollectionHistory() throws {
    let values = (0..<200).map { "value-\($0)" }
    var forward: Set<String> = []
    var backward: Set<String> = []
    backward.reserveCapacity(4_096)
    for value in values { forward.insert(value) }
    for value in values.reversed() { backward.insert(value) }
    #expect(try CanonicalJSON.encode(forward) == CanonicalJSON.encode(backward))
    var ascending: [PlaybackEffectID: String] = [:]
    var descending: [PlaybackEffectID: String] = [:]
    descending.reserveCapacity(4_096)
    for (index, value) in values.enumerated() {
      ascending[PlaybackEffectID(rawValue: UInt64(index))] = value
    }
    for (index, value) in values.enumerated().reversed() {
      descending[PlaybackEffectID(rawValue: UInt64(index))] = value
    }
    let bytes = try CanonicalJSON.encode(ascending)
    #expect(try CanonicalJSON.encode(descending) == bytes)
    #expect(try CanonicalJSON.decode([PlaybackEffectID: String].self, from: bytes) == ascending)
    #expect(throws: EncodingError.self) { try CanonicalJSON.encode([Double.nan]) }
    // Values equal in Swift encode to equal bytes.
    #expect(try CanonicalJSON.encode(["\u{e9}"]) == CanonicalJSON.encode(["e\u{301}"]))
    #expect(
      try CanonicalJSON.encode(Set(["\u{e9}", "x"])) == CanonicalJSON.encode(Set(["e\u{301}", "x"])))
    #expect(try CanonicalJSON.encode(["\u{e9}": 1]) == CanonicalJSON.encode(["e\u{301}": 1]))
    #expect(try CanonicalJSON.encode([0.0]) == CanonicalJSON.encode([-0.0]))
    #expect(try CanonicalJSON.decode([String].self, from: CanonicalJSON.encode(["e\u{301}"])) == ["e\u{301}"])
  }

  // MARK: Artifacts, replay and continued-failure evidence.

  static func oracleRun(depth: Int = 3) throws -> PlaybackVerificationRun {
    try PlaybackVerifier.run(
      model: .seek, seedProfile: "ready-playing",
      configuration: .validation(depthLimit: depth),
      oracle: .failOnActionClass("command.seekExact", invariantName: "syntheticSeekFailure"))
  }

  static func oracleArtifact(depth: Int = 3) throws -> PlaybackVerificationArtifact {
    try #require(
      PlaybackVerificationArtifacts.build(
        run: oracleRun(depth: depth),
        provenance: .init(sourceRevision: "test", sourceDirty: false)
      ).artifacts.first)
  }

  @Test
  func artifactIsDeterministicMinimizedAndReplayable() throws {
    let artifact = try Self.oracleArtifact()
    let again = try Self.oracleArtifact()
    #expect(artifact.minimizedWitness == [.command(.seekExact)])
    #expect(artifact.minimization.shrinker == "shrink64")
    let bytes = try PlaybackVerificationArtifacts.encode(artifact)
    let againBytes = try PlaybackVerificationArtifacts.encode(again)
    #expect(bytes == againBytes)
    let decoded = try PlaybackVerificationArtifacts.decode(bytes)
    #expect(decoded == artifact)
    let replay = try PlaybackArtifactReplayer.replay(decoded)
    #expect(replay.reproduced)
    #expect(replay.productionTransitionCount == 1)
  }

  @Test
  func causalShrinkingReplaysProductionForAcceptedCandidates() throws {
    let model = try Self.model(
      .seek, "ready-playing",
      oracle: .failOnActionClass("command.seekExact", invariantName: "syntheticSeekFailure"),
      configuration: .validation(depthLimit: 6))
    let witness: [SearchAction] = [.command(.pause), .command(.play), .command(.seekExact)]
    let recorded = try PlaybackVerificationArtifacts.recordEvidence(model, witness)
    let target = try #require(recorded.trace.steps.last?.checks.first { $0.status == .failed })
    let report = try shrink64(
      PlaybackStatelessnessModels.generator(model),
      original: Failure(inputs: witness, violations: [.init(phase: "transition", check: target)]))
    #expect(report.minimized.inputs == [.command(.seekExact)])
    #expect(report.attempts > 1)
  }

  @Test
  func continuedFailureWitnessIsShrunkAndReplayedAcrossEarlierFailures() throws {
    let oracle = PlaybackSearchOracle.failOnActionClass(
      "command.pause", invariantName: "injectedPauseOracle")
    let run = try PlaybackVerifier.run(
      model: .seek, seedProfile: "ready-playing", configuration: .validation(depthLimit: 3),
      oracle: oracle, maxRetainedFindings: 100_000)
    let finding = try #require(run.report.findings.first { $0.requiresContinuedEvidence })
    let target = try #require(finding.violations.first)
    let artifact = try PlaybackVerificationArtifacts.build(
      model: run.model, family: .seek, seedProfile: "ready-playing",
      configuration: run.summary.configuration, oracle: oracle,
      provenance: .init(sourceRevision: "test", sourceDirty: false), source: "search",
      search: run.summary,
      finding: .init(
        index: finding.index, edge: finding.edge,
        violations: finding.violations.map(PlaybackVerificationArtifacts.artifactViolation),
        requiresContinuedEvidence: true),
      witness: finding.witness, target: target, shrinkConfig: ShrinkConfig64(), unpreserved: [])
    #expect(artifact.minimization.shrinker == "shrinkContinued")
    #expect(artifact.minimizedWitness.count <= finding.witness.count)
    let original = try parseContinuedTrace(Array(artifact.originalTrace.utf8))
    #expect(original.failingSequences.count >= 2)
    #expect(try PlaybackArtifactReplayer.replay(artifact).reproduced)
    // Stop-at-failure readers reject continued evidence.
    #expect(throws: (any Error).self) { try parseTrace(Array(artifact.originalTrace.utf8)) }
  }

  static func reencoded(
    _ artifact: PlaybackVerificationArtifact, change: (inout [String: Any]) throws -> Void
  ) throws -> PlaybackVerificationArtifact {
    var json = try #require(
      JSONSerialization.jsonObject(
        with: Data(PlaybackVerificationArtifacts.encode(artifact))) as? [String: Any])
    try change(&json)
    return try PlaybackVerificationArtifacts.decode(
      Array(JSONSerialization.data(withJSONObject: json)))
  }

  @Test
  func corruptedIncompatibleAndRetargetedArtifactsAreRejected() throws {
    let artifact = try Self.oracleArtifact()

    // A corrupted output in the minimized trace: replay must not be exact.
    let trace = try parseContinuedTrace(Array(artifact.minimizedTrace.utf8))
    let step = try #require(trace.trace.steps.first)
    let observation = try PlaybackModelCodec.decodeOutput(try #require(step.outputs.first))
    let flipped = PlaybackModelObservation(
      kind: observation.kind, transition: observation.transition,
      envelope: observation.envelope, violations: observation.violations,
      isFairProgress: !observation.isFairProgress)
    let corruptedSteps =
      [
        TraceStep(
          input: step.input, disposition: step.disposition,
          outputs: [try PlaybackModelCodec.encodeOutput(flipped)], postState: step.postState,
          checks: step.checks)
      ] + trace.trace.steps.dropFirst()
    let corruptedTrace = ContinuedTrace(
      trace: Trace(
        metadata: trace.trace.metadata, initialState: trace.trace.initialState,
        initialChecks: trace.trace.initialChecks, steps: corruptedSteps,
        termination: trace.trace.termination))
    let corrupted = try Self.reencoded(artifact) {
      $0["minimizedTrace"] = String(
        decoding: try encodeContinuedTrace(corruptedTrace), as: UTF8.self)
    }
    #expect(try !PlaybackArtifactReplayer.replay(corrupted).reproduced)

    // Truncated trace bytes fail to parse.
    let truncated = try Self.reencoded(artifact) {
      $0["minimizedTrace"] = String(artifact.minimizedTrace.dropLast(10))
    }
    #expect(throws: (any Error).self) { try PlaybackArtifactReplayer.replay(truncated) }

    // An incompatible model version is refused, not reinterpreted.
    let incompatible = try Self.reencoded(artifact) {
      $0["modelVersion"] = artifact.modelVersion + 1
    }
    #expect(throws: PlaybackArtifactError.self) {
      try PlaybackArtifactReplayer.replay(incompatible)
    }

    // A wrong property target is not reported as reproduced.
    let retargeted = try Self.reencoded(artifact) {
      var target = try #require($0["target"] as? [String: Any])
      target["property"] = "someOtherProperty"
      $0["target"] = target
    }
    let wrongTarget = try PlaybackArtifactReplayer.replay(retargeted)
    #expect(!wrongTarget.targetReproduced)
    #expect(!wrongTarget.reproduced)
  }

  @Test
  func replayIsBoundToTheNamedSeedAndBothWitnesses() throws {
    let artifact = try Self.oracleArtifact()
    let otherSeed = try Self.reencoded(artifact) { $0["seedProfile"] = "ready-paused" }
    #expect(try !PlaybackArtifactReplayer.replay(otherSeed).reproduced)
    let otherWitness = try Self.reencoded(artifact) {
      $0["originalWitness"] = try JSONSerialization.jsonObject(
        with: Data(CanonicalJSON.encode([SearchAction.command(.pause)])))
    }
    #expect(try !PlaybackArtifactReplayer.replay(otherWitness).reproduced)
  }

  @Test
  func legacyArtifactConvertsAndReplaysThroughTheStatelessnessModel() throws {
    let bytes = try Data(
      contentsOf: Self.fixtures.appendingPathComponent(
        "legacy-artifact-v1-seek-ready-playing.json"))
    let converted = try PlaybackLegacyArtifactConverter.convert(Array(bytes), sha256: "fixture")
    #expect(converted.source == "legacy-artifact-v1:fixture")
    #expect(!converted.unpreservedFields.isEmpty)
    #expect(converted.target.property == "syntheticSeekFailure")
    #expect(try PlaybackArtifactReplayer.replay(converted).reproduced)

    var json = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    json["modelVersion"] = 1
    let old = try JSONSerialization.data(withJSONObject: json)
    #expect(throws: PlaybackArtifactError.self) {
      try PlaybackLegacyArtifactConverter.convert(Array(old), sha256: "old")
    }
  }

  /// Fresh-process replay: set ILLIQUID_MIGRATION_ARTIFACT_OUT to write an
  /// artifact in one process and ILLIQUID_MIGRATION_ARTIFACT_IN to replay it in
  /// another, or replay it with `IlliquidStateSpaceExplorer --replay`.
  @Test
  func artifactRoundTripsAcrossProcessesWhenRequested() throws {
    let environment = ProcessInfo.processInfo.environment
    if let output = environment["ILLIQUID_MIGRATION_ARTIFACT_OUT"] {
      try Data(PlaybackVerificationArtifacts.encode(Self.oracleArtifact())).write(
        to: URL(fileURLWithPath: output))
    }
    if let input = environment["ILLIQUID_MIGRATION_ARTIFACT_IN"] {
      let artifact = try PlaybackVerificationArtifacts.decode(
        Array(Data(contentsOf: URL(fileURLWithPath: input))))
      #expect(try PlaybackArtifactReplayer.replay(artifact).reproduced)
    }
  }

  @Test
  func eligibleArtifactPromotesToRuntimeScheduleWithoutInventingMechanisms() throws {
    let promoted = try #require(try PlaybackRuntimePromotion.promote(Self.oracleArtifact(depth: 1)))
    #expect(!promoted.steps.isEmpty)
    #expect(promoted.steps.allSatisfy { $0.effectContextPreserved })
  }

  /// Opt-in cost breakdown on one seed at a named profile's bounds:
  /// ILLIQUID_MIGRATION_COST_SEED=model/seed, ILLIQUID_MIGRATION_COST_PROFILE.
  @Test
  func costBreakdownWhenRequested() throws {
    let environment = ProcessInfo.processInfo.environment
    guard let selected = environment["ILLIQUID_MIGRATION_COST_SEED"] else { return }
    let parts = selected.split(separator: "/").map(String.init)
    let family = try #require(PlaybackSearchModel(rawValue: parts[0]))
    let configuration: PlaybackSearchConfiguration =
      environment["ILLIQUID_MIGRATION_COST_PROFILE"] == "pr"
      ? PlaybackSearchConfiguration.pr.withTimeLimitSeconds(nil) : Self.configuration()
    let clock = ContinuousClock()
    final class Totals: @unchecked Sendable {
      var step = Duration.zero, apply = Duration.zero, key = Duration.zero
      var inputs = Duration.zero, hash = Duration.zero, equal = Duration.zero
      var checks = Duration.zero
    }
    let totals = Totals()
    var model = try Self.model(family, parts[1], configuration: configuration)
    let step = model.step, inputs = model.inputs!, equal = model.equalStates!
    let checks = model.checkTransition!
    model.step = { state, action in
      var result: Transition<PlaybackModelState, PlaybackModelObservation>?
      totals.step += try clock.measure { result = try step(state, action) }
      return result!
    }
    model.inputs = { state in
      var result: InputIterator<SearchAction>?
      totals.inputs += try clock.measure { result = try inputs(state) }
      return result!
    }
    model.equalStates = { a, b in
      var result = false
      totals.equal += try clock.measure { result = try equal(a, b) }
      return result
    }
    model.checkTransition = { a, b, c in
      var result: [Check] = []
      totals.checks += try clock.measure { result = try checks(a, b, c) }
      return result
    }
    var report: PlaybackGraphReport?
    let total = try clock.measure { report = try Self.explore(model, configuration: configuration) }
    // Split step into apply and key derivation on a sample of admitted states.
    let definition = PlaybackSearchModelDefinition(model: family)
    for node in report!.nodes.prefix(2_000) {
      for action in definition.enabledActions(for: node.state.node, configuration: configuration) {
        var successor: PlaybackSearchNode?
        totals.apply += clock.measure {
          successor = apply(action: action, to: node.state.node, configuration: configuration).node
        }
        totals.key += clock.measure { _ = PlaybackModelState(node: successor!) }
      }
    }
    let progress = try clock.measure { _ = try PlaybackProgressPolicy.analyze(report!) }
    print(
      "[cost] \(selected) states=\(report!.states) transitions=\(report!.transitions) "
        + "total=\(total) step=\(totals.step) inputs=\(totals.inputs) equal=\(totals.equal) "
        + "checks=\(totals.checks) progress=\(progress) sample(apply=\(totals.apply) "
        + "stateKey=\(totals.key))")
  }

  /// Opt-in diamond probe: ILLIQUID_MIGRATION_DIAMOND_SEED=model/seed and
  /// ILLIQUID_MIGRATION_DIAMOND_DEPTHS=6,8,... print noncommuting witnesses.
  @Test
  func diamondProbeWhenRequested() throws {
    let environment = ProcessInfo.processInfo.environment
    guard let selected = environment["ILLIQUID_MIGRATION_DIAMOND_SEED"] else { return }
    let parts = selected.split(separator: "/").map(String.init)
    let family = try #require(PlaybackSearchModel(rawValue: parts[0]))
    let depths = (environment["ILLIQUID_MIGRATION_DIAMOND_DEPTHS"] ?? "6").split(separator: ",")
      .compactMap { Int($0) }
    for depth in depths {
      let configuration = PlaybackSearchConfiguration.validation(
        depthLimit: depth, porMode: .validation
      ).withTimeLimitSeconds(nil)
      let run = try PlaybackVerifier.run(
        model: family, seedProfile: parts[1], configuration: configuration)
      let diamonds = try #require(run.diamonds)
      var classes: [String: Int] = [:]
      for witness in diamonds.nonCommuting {
        classes[
          "\(witness.first.stableClass) x \(witness.second.stableClass) (\(witness.reason))",
          default: 0] += 1
      }
      print(
        "[diamond] \(selected) depth=\(depth) states=\(run.summary.stateCount) "
          + "validated=\(diamonds.validated) noncommuting=\(diamonds.nonCommuting.count) "
          + "\(classes.sorted { $0.value > $1.value }.prefix(8))")
      if let witness = diamonds.nonCommuting.first {
        let node = run.report.nodes[witness.node].state.node
        print("[diamond] first witness node env=\(node.environment) depth=\(node.depth)")
      }
    }
  }

  // MARK: Phase 0 inventory freeze.

  struct FrozenInventory: Codable, Equatable {
    struct Family: Codable, Equatable {
      let model: String
      let modelVersion: UInt32
      let seedProfiles: [String]
      let actionClasses: [String]
      let requiredScenarios: [String]
    }
    let families: [Family]
    let profiles: [PlaybackSearchConfiguration]
  }

  static var currentInventory: FrozenInventory {
    FrozenInventory(
      families: PlaybackSearchModel.allCases.map { model in
        let definition = PlaybackSearchModelDefinition(model: model)
        return .init(
          model: model.rawValue, modelVersion: definition.modelVersion,
          seedProfiles: definition.inventory.seedProfiles,
          actionClasses: definition.inventory.actionClasses,
          requiredScenarios: definition.inventory.requiredScenarios)
      },
      profiles: [.pr, .nightly, .qualification, .validation()])
  }

  @Test
  func inventoryMatchesTheFrozenPhase0Inventory() throws {
    let frozen = try JSONDecoder().decode(
      FrozenInventory.self,
      from: Data(
        contentsOf: Self.fixtures.appendingPathComponent(
          "statelessness-migration-inventory-v1.json")))
    #expect(frozen == Self.currentInventory)
  }
}

// MARK: Golden fixture support.

struct Golden: Decodable {
  struct Seed: Equatable {
    let states: Int
    let transitions: Int
    let productionTransitions: Int
    let gateRejections: Int
    let peakFrontier: Int
    let canonicalDigest: String
    let progress: PlaybackProgressReport

    init(run: PlaybackVerificationRun) {
      states = run.summary.stateCount
      transitions = run.summary.edgeCount
      productionTransitions = run.summary.productionTransitionCount
      gateRejections = run.summary.gateRejectionCount
      peakFrontier = run.summary.peakFrontier
      canonicalDigest = run.summary.canonicalDigest
      progress = PlaybackProgressPolicy.summary(run.progress)
    }

    init(_ entry: Entry) {
      states = entry.states
      transitions = entry.transitions
      productionTransitions = entry.productionTransitions
      gateRejections = entry.gateRejections
      peakFrontier = entry.peakFrontier
      canonicalDigest = entry.canonicalDigest
      progress = entry.progress
    }
  }

  struct Entry: Decodable {
    let model: String
    let seed: String
    let states: Int
    let transitions: Int
    let productionTransitions: Int
    let gateRejections: Int
    let peakFrontier: Int
    let canonicalDigest: String
    let edgeSequenceSHA256: String
    let progress: PlaybackProgressReport
    let reducedStates: Int
    let reducedEdges: Int
    let validatedDiamonds: Int
    let nonCommutingDiamonds: Int

    var unreduced: Seed { Seed(self) }
  }

  let schema: String
  let oracleRevision: String
  let depthLimit: Int
  let seeds: [Entry]

  func seed(_ model: PlaybackSearchModel, _ seed: String) -> Entry? {
    seeds.first { $0.model == model.rawValue && $0.seed == seed }
  }
}

struct EdgeRecord: Encodable {
  let source: Int
  let input: SearchAction
  let disposition: String
  let outputs: [PlaybackModelObservation]
  let checks: [String]
  let target: String
}

/// SHA-256 of the canonical encoding of every evaluated edge, in order. This
/// is the same digest recorded in the golden fixture.
func edgeSequenceDigest(_ report: PlaybackGraphReport) throws -> String {
  var hasher = SHA256()
  for edge in report.edges {
    let record = EdgeRecord(
      source: edge.source, input: edge.input, disposition: "\(edge.disposition)",
      outputs: edge.outputs,
      checks: (edge.stateChecks + edge.transitionChecks).map {
        "\($0.id)|\($0.status.rawValue)|\($0.details)"
      },
      target: "\(edge.target)")
    hasher.update(data: try CanonicalJSON.encode(record) + [0x0a])
  }
  return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}
