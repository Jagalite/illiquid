import IlliquidPlaybackCore
import Testing

@testable import IlliquidPlaybackStateSpace

@Suite("Playback bounded state-space explorer")
struct PlaybackStateSpaceTests {
  @Test
  func exposesAllSixIndependentModels() {
    #expect(
      PlaybackSearchModel.allCases.map(\.rawValue) == [
        "seek", "eof-drain", "recovery", "track-subtitles", "stop-shutdown",
        "preroll-buffering",
      ])
  }

  @Test
  func everyModelPublishesACompleteScenarioInventory() {
    for model in PlaybackSearchModel.allCases {
      let inventory = PlaybackSearchModelDefinition(model: model).inventory
      #expect(!inventory.seedProfiles.isEmpty)
      #expect(!inventory.actionClasses.isEmpty)
      #expect(!inventory.requiredScenarios.isEmpty)
      #expect(Set(inventory.requiredScenarios).count == inventory.requiredScenarios.count)
    }
  }

  @Test
  func modelVersionsRecordPendingSourceAndRecoveryDependencySemantics() throws {
    let definition = PlaybackSearchModelDefinition(model: .seek)
    #expect(definition.modelVersion == 10)
    #expect(PlaybackSearchModelDefinition(model: .eofDrain).modelVersion == 10)
    for model in PlaybackSearchModel.allCases
    where model != .seek && model != .eofDrain
    {
      #expect(PlaybackSearchModelDefinition(model: model).modelVersion == 9)
    }

    let seed = try definition.makeSeed(profile: "ready-playing")
    let applied = apply(
      action: .command(.seekRelative),
      to: seed,
      configuration: .validation(depthLimit: 1)
    )

    #expect(applied.node.coreState.activeSession?.seek?.mode == .relative)
    #expect(applied.transition?.effects.contains {
      if case .seekPipeline(_, .exact) = $0.kind { return true }
      return false
    } == true)
  }

  @Test
  func approvedProfilesFreezeConservativeBounds() {
    #expect(PlaybackSearchConfiguration.pr.depthLimit == 12)
    #expect(PlaybackSearchConfiguration.pr.generationLimit == 2)
    #expect(PlaybackSearchConfiguration.pr.pendingEffectLimit == 4)
    #expect(PlaybackSearchConfiguration.pr.lateResultLimit == 2)
    #expect(PlaybackSearchConfiguration.pr.stateLimit == 50_000)
    #expect(PlaybackSearchConfiguration.pr.edgeLimit == 500_000)
    #expect(PlaybackSearchConfiguration.nightly.depthLimit == 20)
    #expect(PlaybackSearchConfiguration.qualification.depthLimit == 28)
  }

  @Test
  func trendPolicyFlagsCountAndNormalizationDrift() throws {
    let result = try PlaybackStateSpaceExplorer().run(
      model: .recovery, seedProfile: "playing-hardware",
      configuration: .validation(depthLimit: 2)
    )
    let baseline = PlaybackSearchTrendBaseline(entries: [
      .init(
        model: .recovery, seedProfile: "playing-hardware",
        modelVersion: result.summary.modelVersion,
        stateCount: max(result.summary.stateCount / 2, 1),
        edgeCount: max(result.summary.edgeCount / 2, 1),
        canonicalDigest: "different"
      )
    ])
    let violations = PlaybackSearchTrendEvaluator.evaluate(
      result.summary, against: baseline, tolerancePercent: 25
    )
    #expect(violations.contains { $0.kind == .stateCountDrift })
    #expect(violations.contains { $0.kind == .edgeCountDrift })
    #expect(violations.contains { $0.kind == .normalizationDrift })
  }

  @Test
  func canonicalizationIsIdempotentAndAlphaRenamingInvariant() {
    let first = makeNode(session: 4, operation: 9, effect: 12)
    let renamed = makeNode(session: 44, operation: 90, effect: 120)
    let firstKey = PlaybackSearchCanonicalizer.key(for: first)
    let secondPass = PlaybackSearchCanonicalizer.key(for: first, previousKey: firstKey)

    #expect(firstKey == secondPass)
    #expect(firstKey == PlaybackSearchCanonicalizer.key(for: renamed))
  }

  @Test
  func canonicalizationPreservesBehaviorallyDistinctPendingEffects() {
    let first = makeNode(session: 1, operation: 1, effect: 1)
    var second = first
    second.coreState.outstandingEffects.removeAll()

    #expect(
      PlaybackSearchCanonicalizer.key(for: first)
        != PlaybackSearchCanonicalizer.key(for: second))
  }

  @Test
  func equalKeysExposeEqualNormalizedEnabledActions() {
    let first = makeNode(session: 4, operation: 9, effect: 12)
    let renamed = makeNode(session: 44, operation: 90, effect: 120)
    let definition = PlaybackSearchModelDefinition(model: .seek)

    #expect(
      PlaybackSearchCanonicalizer.key(for: first)
        == PlaybackSearchCanonicalizer.key(for: renamed))
    #expect(
      definition.enabledActionClasses(for: first)
        == definition.enabledActionClasses(for: renamed))
  }

  @Test
  func aggregateRecoveryAndReplacementSuccessWaitForExecutorPrerequisites() throws {
    let configuration = PlaybackSearchConfiguration.validation(depthLimit: 8)
    for model in [PlaybackSearchModel.recovery, .trackSubtitles] {
      let definition = PlaybackSearchModelDefinition(model: model)
      let seed = model == .recovery ? "playing-hardware" : "automatic"
      var node = try definition.makeSeed(profile: seed)
      if model == .recovery {
        node =
          apply(
            action: .runtimeFact(.recoverableVideoFailure, ingress: .current),
            to: node, configuration: configuration
          ).node
      } else {
        node =
          apply(
            action: .command(.selectAudio), to: node, configuration: configuration
          ).node
      }
      #expect(!definition.enabledActionClasses(for: node).contains("result.succeeded.none"))

      let prerequisites: [SearchAction] =
        model == .recovery
        ? RecoveryExecutorPrerequisite.allCases.map(SearchAction.recoveryPrerequisite)
        : TrackExecutorPrerequisite.allCases.map(SearchAction.trackPrerequisite)
      for prerequisite in prerequisites {
        node = apply(action: prerequisite, to: node, configuration: configuration).node
      }
      #expect(definition.enabledActionClasses(for: node).contains("result.succeeded.none"))
    }
  }

  @Test
  func recoveryExecutorPrerequisitesAdvanceAbstractMechanismLifecycle() throws {
    let configuration = PlaybackSearchConfiguration.validation(depthLimit: 8)
    let definition = PlaybackSearchModelDefinition(model: .recovery)
    var node = try definition.makeSeed(profile: "playing-hardware")
    node =
      apply(
        action: .runtimeFact(.recoverableVideoFailure, ingress: .current),
        to: node, configuration: configuration
      ).node
    guard case .recovery(let failed) = node.environment else {
      Issue.record("Expected recovery environment")
      return
    }
    #expect(failed.decoder == .failed)

    node =
      apply(
        action: .recoveryPrerequisite(.oldOutputFence),
        to: node, configuration: configuration
      ).node
    node =
      apply(
        action: .recoveryPrerequisite(.decoderTeardown),
        to: node, configuration: configuration
      ).node
    node =
      apply(
        action: .recoveryPrerequisite(.softwareConfiguration),
        to: node, configuration: configuration
      ).node
    node =
      apply(
        action: .recoveryPrerequisite(.presentationMembership),
        to: node, configuration: configuration
      ).node
    node =
      apply(
        action: .recoveryPrerequisite(.requiredStreamPreroll),
        to: node, configuration: configuration
      ).node
    guard case .recovery(let ready) = node.environment else {
      Issue.record("Expected recovery environment")
      return
    }
    #expect(ready.decoder == .configuredSoftware)
    #expect(ready.presenter == .active)
  }

  @Test
  func recoveryPrerequisitesExposeOnlyDependencyReadyActions() throws {
    let configuration = PlaybackSearchConfiguration.validation(depthLimit: 8)
    let definition = PlaybackSearchModelDefinition(model: .recovery)
    var node = try definition.makeSeed(profile: "playing-hardware")
    node = apply(
      action: .runtimeFact(.recoverableVideoFailure, ingress: .current),
      to: node, configuration: configuration
    ).node

    #expect(
      definition.enabledActions(for: node, configuration: configuration)
        .filter {
          if case .recoveryPrerequisite = $0 { return true }
          return false
        } == [.recoveryPrerequisite(.oldOutputFence)]
    )
    let unchanged = apply(
      action: .recoveryPrerequisite(.softwareConfiguration),
      to: node, configuration: configuration
    ).node
    #expect(unchanged.environment == node.environment)

    node = apply(
      action: .recoveryPrerequisite(.oldOutputFence),
      to: node, configuration: configuration
    ).node
    #expect(
      definition.enabledActions(for: node, configuration: configuration)
        .contains(.recoveryPrerequisite(.decoderTeardown))
    )
  }

  @Test
  func explorerTerminatesAtConfiguredWallClockBudget() throws {
    let result = try PlaybackStateSpaceExplorer().run(
      model: .seek,
      seedProfile: "ready-playing",
      configuration: PlaybackSearchConfiguration.validation(depthLimit: 8)
        .withTimeLimitSeconds(0)
    )

    #expect(result.summary.termination == .timeBudgetReached)
    #expect(result.summary.stateCount == 1)
  }

  @Test
  func recoveryMechanismLifecycleParticipatesInStableCanonicalDigest() throws {
    let definition = PlaybackSearchModelDefinition(model: .recovery)
    let hardware = try definition.makeSeed(profile: "playing-hardware")
    var failed = hardware
    guard case .recovery(var environment) = failed.environment else {
      Issue.record("Expected recovery environment")
      return
    }
    environment.decoder = .failed
    failed.environment = .recovery(environment)

    #expect(
      PlaybackSearchCanonicalizer.digest(
        PlaybackSearchCanonicalizer.key(for: hardware)
      )
        != PlaybackSearchCanonicalizer.digest(
          PlaybackSearchCanonicalizer.key(for: failed)
        ))
  }

  @Test
  func actionCardinalityBudgetsControlFailureAndDuplicateClasses() throws {
    let configuration = PlaybackSearchConfiguration.validation(depthLimit: 5)
    let noFaultClasses = PlaybackSearchConfiguration(
      profile: "no-fault-classes", depthLimit: 5, generationLimit: 1,
      pendingEffectLimit: 3, lateResultLimit: 1, failureLimit: 0,
      duplicateLimit: 0, interruptLimit: 0, stateLimit: 10_000,
      edgeLimit: 100_000, porMode: .disabled
    )
    let definition = PlaybackSearchModelDefinition(model: .seek)
    var node = try definition.makeSeed(profile: "ready-playing")
    node = apply(action: .command(.seekExact), to: node, configuration: configuration).node
    node = apply(action: .seekAggregateReady, to: node, configuration: configuration).node
    let effect = try #require(
      node.coreState.outstandingEffects.values.first {
        if case .seekPipeline = $0.effect.kind { return true }
        return false
      }?.effect)
    #expect(
      definition.enabledActions(for: node, configuration: configuration).contains {
        $0.stableClass == "result.failed.none"
      })
    #expect(
      !definition.enabledActions(for: node, configuration: noFaultClasses).contains {
        $0.stableClass == "result.failed.none"
      })
    node =
      apply(
        action: .result(effectID: effect.context.effectID, outcome: .succeeded, mutation: .none),
        to: node, configuration: configuration
      ).node
    #expect(
      definition.enabledActions(for: node, configuration: configuration).contains {
        $0.stableClass == "result.duplicate"
      })
    #expect(
      !definition.enabledActions(for: node, configuration: noFaultClasses).contains {
        $0.stableClass == "result.duplicate"
      })
  }

  @Test
  func layeredBFSIsDeterministicAndUsesProductionTransitions() throws {
    let configuration = PlaybackSearchConfiguration.validation(depthLimit: 4)
    let first = try PlaybackStateSpaceExplorer().run(
      model: .seek,
      seedProfile: "ready-playing",
      configuration: configuration
    )
    let second = try PlaybackStateSpaceExplorer().run(
      model: .seek,
      seedProfile: "ready-playing",
      configuration: configuration
    )

    #expect(first.summary == second.summary)
    #expect(first.summary.termination == .completeWithinBounds)
    #expect(first.summary.productionTransitionCount > 0)
    #expect(first.summary.stateCount > 1)
    #expect(first.failures.isEmpty)
  }

  @Test
  func everyAdvertisedSeedCanBeConstructed() throws {
    for model in PlaybackSearchModel.allCases {
      let definition = PlaybackSearchModelDefinition(model: model)
      for seed in definition.inventory.seedProfiles {
        _ = try definition.makeSeed(profile: seed)
      }
    }
  }

  @Test
  func allSixModelsCompleteAtValidationBounds() throws {
    for model in PlaybackSearchModel.allCases {
      let definition = PlaybackSearchModelDefinition(model: model)
      let result = try PlaybackStateSpaceExplorer().run(
        model: model,
        seedProfile: try #require(definition.inventory.seedProfiles.first),
        configuration: .validation(depthLimit: 3)
      )
      #expect(result.summary.termination == .completeWithinBounds)
      #expect(result.failures.isEmpty, Comment(rawValue: model.rawValue))
    }
  }

  @Test
  func syntheticFailureProducesStableReplayableArtifact() throws {
    let oracle = PlaybackSearchOracle.failOnActionClass(
      "command.seekExact", invariantName: "syntheticSeekFailure"
    )
    let result = try PlaybackStateSpaceExplorer().run(
      model: .seek, seedProfile: "ready-playing",
      configuration: .validation(depthLimit: 2), oracle: oracle
    )
    let failure = try #require(
      result.failures.first {
        $0.invariantName == "syntheticSeekFailure"
      })
    let artifact = try PlaybackSearchArtifactBuilder.build(
      result: result, failure: failure, sourceRevision: "test", dirty: false
    )

    let first = try PlaybackSearchArtifactCodec.encode(artifact)
    let second = try PlaybackSearchArtifactCodec.encode(
      PlaybackSearchArtifactCodec.decode(first)
    )
    #expect(first == second)
    #expect(try PlaybackSearchArtifactReplayer.replay(artifact).reproducedFailure)
  }

  @Test
  func causalMinimizerReplaysProductionCoreForEveryAcceptedCandidate() throws {
    let oracle = PlaybackSearchOracle.failOnActionClass(
      "command.seekExact", invariantName: "syntheticSeekFailure"
    )
    let minimized = try PlaybackSearchMinimizer.minimize(
      actions: [.command(.pause), .command(.play), .command(.seekExact), .command(.pause)],
      model: .seek, seedProfile: "ready-playing",
      configuration: .validation(depthLimit: 6), oracle: oracle
    )

    #expect(minimized.actions == [.command(.seekExact)])
    #expect(minimized.productionReplayCount > 0)
    #expect(!minimized.history.isEmpty)
  }

  @Test
  func progressAnalysisSeparatesNamedWaitsCutoffsAndStuckSCCs() throws {
    let result = try PlaybackStateSpaceExplorer().run(
      model: .stopShutdown, seedProfile: "opening",
      configuration: .validation(depthLimit: 2)
    )
    let progress = PlaybackProgressAnalyzer.analyze(result)
    #expect(progress.externalWaitStates > 0)
    #expect(progress.unmeasuredCutoffStates > 0)
    #expect(progress.stuckStates.isEmpty)

    let cycle = PlaybackProgressAnalyzer.stronglyConnectedComponents(
      nodeCount: 2,
      edges: [
        .init(from: 0, to: 1, actionClass: "noop", isFairProgress: false),
        .init(from: 1, to: 0, actionClass: "noop", isFairProgress: false),
      ]
    )
    #expect(cycle.contains(Set([0, 1])))
  }

  @Test
  func externalSubtitleSeedHasNoStuckProgressStates() throws {
    let result = try PlaybackStateSpaceExplorer().run(
      model: .trackSubtitles, seedProfile: "external-subtitle",
      configuration: .pr
    )
    let progress = PlaybackProgressAnalyzer.analyze(result)
    #expect(progress.stuckStates.isEmpty)
    #expect(progress.closedNonterminalSCCs.isEmpty)
  }

  @Test
  func conservativePORMatchesUnreducedReachabilityAndFailures() throws {
    let explorer = PlaybackStateSpaceExplorer()
    let unreduced = try explorer.run(
      model: .stopShutdown, seedProfile: "opening",
      configuration: .validation(depthLimit: 3, porMode: .disabled)
    )
    let reduced = try explorer.run(
      model: .stopShutdown, seedProfile: "opening",
      configuration: .validation(depthLimit: 3, porMode: .validation)
    )

    #expect(reduced.summary.canonicalDigest == unreduced.summary.canonicalDigest)
    #expect(reduced.failures == unreduced.failures)
    #expect(reduced.summary.edgeCount < unreduced.summary.edgeCount)
    #expect(reduced.summary.reducedEdgeCount > 0)
    #expect(reduced.summary.nonCommutingDiamondCount == 0)
  }

  @Test
  func porValidationReportsEveryNonCommutingCandidatePair() throws {
    let definition = PlaybackSearchModelDefinition(model: .prerollBuffering)
    let node = try definition.makeSeed(profile: "partial-av")
    let configuration = PlaybackSearchConfiguration.validation(
      depthLimit: 2, porMode: .validation
    )
    let reduction = PlaybackPartialOrderReducer.reduce(
      actions: definition.enabledActions(for: node, configuration: configuration),
      node: node, definition: definition, configuration: configuration,
      validateDiamonds: true
    )

    #expect(reduction.validatedDiamondCount > 0)
    #expect(reduction.nonCommutingDiamondCount == 0)
  }

  @Test
  func eligibleArtifactPromotesToRuntimeScheduleWithoutInventingMechanisms() throws {
    let oracle = PlaybackSearchOracle.failOnActionClass(
      "command.seekExact", invariantName: "syntheticSeekFailure"
    )
    let result = try PlaybackStateSpaceExplorer().run(
      model: .seek, seedProfile: "ready-playing",
      configuration: .validation(depthLimit: 1), oracle: oracle
    )
    let failure = try #require(result.failures.first)
    let artifact = try PlaybackSearchArtifactBuilder.build(
      result: result, failure: failure, sourceRevision: "test", dirty: false
    )
    let promoted = try #require(PlaybackRuntimePromotion.promote(artifact))
    #expect(!promoted.steps.isEmpty)
    #expect(promoted.steps.allSatisfy { $0.effectContextPreserved })
  }

  private func makeNode(
    session: UInt64,
    operation: UInt64,
    effect: UInt64
  ) -> PlaybackSearchNode {
    let sessionID = PlaybackSessionID(rawValue: session)
    let operationID = PlaybackOperationID(rawValue: operation)
    let effectID = PlaybackEffectID(rawValue: effect)
    var synchronization = SynchronizationMachineState(desiredMilliRate: 1_000)
    _ = synchronization.satisfyStartupObligation()
    let active = ActivePlaybackSession(
      id: sessionID,
      source: MediaSourceIdentity(rawValue: "fixture-alpha.mkv"),
      generation: PlaybackGenerationID(rawValue: 7),
      phase: .playing,
      desiredTransport: .playing,
      actualTransport: .playing,
      activeOperationID: operationID,
      synchronization: synchronization
    )
    let context = PlaybackEffectContext(
      authority: active.authority,
      operationID: operationID,
      effectID: effectID
    )
    let pending = PlaybackEffect(
      executor: .presentation,
      context: context,
      kind: .applyRate(milliRate: 1_000),
      exclusiveKey: "presentation.rate.\(session).7"
    )
    var state = PlaybackCoreState(activeSession: active)
    state.outstandingEffects[effectID] = OutstandingEffectRecord(effect: pending)
    state.allocator = PlaybackIDAllocator(
      nextSession: session + 1,
      nextOperation: operation + 1,
      nextEffect: effect + 1
    )
    return PlaybackSearchNode(
      model: .seek,
      coreState: state,
      environment: .seek(SeekSearchEnvironment())
    )
  }
}
