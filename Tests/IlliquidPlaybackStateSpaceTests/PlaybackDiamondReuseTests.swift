import IlliquidPlaybackCore
import Testing
@testable import IlliquidPlaybackStateSpace

@Suite("Playback diamond first-step reuse")
struct PlaybackDiamondReuseTests {
  private struct Fixture {
    let definition: PlaybackSearchModelDefinition
    let node: PlaybackSearchNode
    let candidateCount: Int
  }

  private var configuration: PlaybackSearchConfiguration {
    .validation(depthLimit: 4, porMode: .validation).withTimeLimitSeconds(nil)
  }

  @Test
  func realisticFiveSevenAndEightCandidateBranchesMatchOriginalPairs() throws {
    let configuration = configuration
    for fixture in try fixtures(configuration: configuration) {
      let actions = fixture.definition.enabledActions(
        for: fixture.node, configuration: configuration
      )
      #expect(diamondCandidates(actions).count == fixture.candidateCount)
      // Retained action order is observable even when diamond counts agree.
      for ordered in [actions, Array(actions.reversed())] {
        let result = assertMatchesOriginal(
          actions: ordered, node: fixture.node,
          definition: fixture.definition, configuration: configuration
        )
        #expect(result.validatedDiamondCount > 0)
      }
    }
  }

  @Test
  func emptyZeroOneAndTwoCandidateInputsKeepOriginalResults() throws {
    let configuration = configuration
    let definition = PlaybackSearchModelDefinition(model: .prerollBuffering)
    let node = try definition.makeSeed(profile: "playing-av")
    let empty = assertMatchesOriginal(
      actions: [], node: node, definition: definition, configuration: configuration
    )
    #expect(empty.actions.isEmpty)
    #expect(empty.validatedDiamondCount == 0)
    #expect(empty.nonCommutingDiamondCount == 0)

    let independent: [SearchAction] = [.queueOffer(.video), .queueConsume(.audio)]
    for count in 0...2 {
      let actions: [SearchAction] = [.command(.pause)]
        + Array(independent.prefix(count))
        + [.runtimeFact(.eofAV, ingress: .previous)]
      #expect(diamondCandidates(actions).count == count)
      let result = assertMatchesOriginal(
        actions: actions, node: node, definition: definition, configuration: configuration
      )
      #expect(result.actions == actions)
      #expect(result.removedCount == 0)
      #expect(result.validatedDiamondCount == (count == 2 ? 1 : 0))
      #expect(result.nonCommutingDiamondCount == 0)
    }
  }

  @Test
  func repeatedPrerequisiteRetainsMultiplicityButCannotFollowItself() throws {
    let configuration = configuration
    let fixture = try #require(
      fixtures(configuration: configuration).first { $0.candidateCount == 8 }
    )
    let actions: [SearchAction] = [
      .seekPrerequisite(.inputCancellation),
      .seekPrerequisite(.inputCancellation),
      .seekPrerequisite(.videoReset),
    ]
    let result = assertMatchesOriginal(
      actions: actions, node: fixture.node,
      definition: fixture.definition, configuration: configuration
    )
    #expect(result.actions == actions)
    #expect(result.removedCount == 0)
    // The duplicate pair is no longer mutually enabled after its first step.
    // Each occurrence still forms a distinct pair with videoReset.
    #expect(result.validatedDiamondCount == 2)
    #expect(result.nonCommutingDiamondCount == 0)
  }

  @Test
  func duplicateQueueActionsPreserveNonCommutingPairCounts() throws {
    let configuration = configuration
    let definition = PlaybackSearchModelDefinition(model: .prerollBuffering)
    var node = try definition.makeSeed(profile: "playing-av")
    node = apply(
      action: .queueConsume(.video), to: node, configuration: configuration
    ).node
    let actions: [SearchAction] = [
      .queueOffer(.video), .queueOffer(.video),
      .queueConsume(.video), .queueOffer(.audio),
    ]
    let result = assertMatchesOriginal(
      actions: actions, node: node, definition: definition, configuration: configuration
    )
    #expect(result.actions == actions)
    #expect(result.removedCount == 0)
    #expect(result.validatedDiamondCount == 6)
    // From empty, offer/consume and consume/offer end in different queue states.
    // Both occurrences of offer must contribute a noncommuting pair.
    #expect(result.nonCommutingDiamondCount == 2)
  }

  @Test
  func wrongOperationDeduplicationStillPrecedesDiamondValidation() throws {
    let configuration = configuration
    let fixture = try #require(
      fixtures(configuration: configuration).first { $0.candidateCount == 8 }
    )
    let effectID = try #require(fixture.node.coreState.outstandingEffects.keys.min())
    let duplicate = SearchAction.result(
      effectID: effectID, outcome: .succeeded, mutation: .wrongOperation
    )
    let prerequisites = diamondCandidates(
      fixture.definition.enabledActions(for: fixture.node, configuration: configuration)
    )
    let actions = [duplicate] + prerequisites + [duplicate]
    let result = assertMatchesOriginal(
      actions: actions, node: fixture.node,
      definition: fixture.definition, configuration: configuration
    )
    #expect(result.actions == Array(actions.dropLast()))
    #expect(result.removedCount == 1)
    #expect(result.validatedDiamondCount == 28)
    #expect(result.nonCommutingDiamondCount == 0)
  }

  @Test
  func disabledValidationLeavesDiamondCountsZeroInEveryPORMode() throws {
    let base = configuration
    for fixture in try fixtures(configuration: base) {
      for mode in [PlaybackSearchPORMode.disabled, .conservative, .validation] {
        let configuration = base.withPORMode(mode)
        let actions = fixture.definition.enabledActions(
          for: fixture.node, configuration: configuration
        )
        let result = assertMatchesOriginal(
          actions: actions, node: fixture.node,
          definition: fixture.definition, configuration: configuration,
          validateDiamonds: false
        )
        #expect(result.validatedDiamondCount == 0)
        #expect(result.nonCommutingDiamondCount == 0)
      }
    }
  }

  private func fixtures(configuration: PlaybackSearchConfiguration) throws -> [Fixture] {
    let seek = PlaybackSearchModelDefinition(model: .seek)
    var seeking = try seek.makeSeed(profile: "ready-playing")
    seeking = apply(
      action: .command(.seekExact), to: seeking, configuration: configuration
    ).node
    let eof = PlaybackSearchModelDefinition(model: .eofDrain)
    var draining = try eof.makeSeed(profile: "playing-av")
    draining = apply(
      action: .runtimeFact(.eofAV, ingress: .current),
      to: draining, configuration: configuration
    ).node
    let queues = PlaybackSearchModelDefinition(model: .prerollBuffering)
    return [
      Fixture(definition: seek, node: seeking, candidateCount: 8),
      Fixture(definition: eof, node: draining, candidateCount: 7),
      Fixture(definition: queues, node: try queues.makeSeed(profile: "playing-av"), candidateCount: 5),
    ]
  }

  @discardableResult
  private func assertMatchesOriginal(
    actions: [SearchAction], node: PlaybackSearchNode,
    definition: PlaybackSearchModelDefinition, configuration: PlaybackSearchConfiguration,
    validateDiamonds: Bool = true
  ) -> PlaybackPartialOrderReducer.Reduction {
    let expected = OriginalDiamondReducer.reduce(
      actions: actions, node: node, definition: definition,
      configuration: configuration, validateDiamonds: validateDiamonds
    )
    let actual = PlaybackPartialOrderReducer.reduce(
      actions: actions, node: node, definition: definition,
      configuration: configuration, validateDiamonds: validateDiamonds
    )
    #expect(actual.actions == expected.actions)
    #expect(actual.removedCount == expected.removedCount)
    #expect(actual.validatedDiamondCount == expected.validatedDiamondCount)
    #expect(actual.nonCommutingDiamondCount == expected.nonCommutingDiamondCount)
    return actual
  }

  private func diamondCandidates(_ actions: [SearchAction]) -> [SearchAction] {
    actions.filter {
      switch $0 {
      case .runtimeFact(let fact, .current): return isFair(fact)
      case .seekPrerequisite, .seekAggregateReady, .recoveryPrerequisite,
        .trackPrerequisite, .recoveryAggregateReady, .trackAggregateReady,
        .queueOffer, .queueConsume:
        return true
      default: return false
      }
    }
  }
}

// The uncached production algorithm at ea2ff568237e2667f7b1aeee67b11a44ebe95b72.
// Retain both first-leg computations inside every pair as a differential oracle.
private enum OriginalDiamondReducer {
  struct Reduction: Sendable {
    let actions: [SearchAction]
    let removedCount: Int
    let validatedDiamondCount: Int
    let nonCommutingDiamondCount: Int
  }

  static func reduce(
    actions: [SearchAction],
    node: PlaybackSearchNode,
    definition: PlaybackSearchModelDefinition,
    configuration: PlaybackSearchConfiguration,
    validateDiamonds: Bool
  ) -> Reduction {
    var retained: [SearchAction] = []
    var signatures: [String: Set<String>] = [:]
    var removed = 0
    for action in actions {
      guard isSafeEquivalenceCandidate(action) else {
        retained.append(action)
        continue
      }
      let applied = apply(action: action, to: node, configuration: configuration)
      let state = PlaybackSearchCanonicalizer.digest(
        PlaybackSearchCanonicalizer.key(for: applied.node)
      )
      let observation = applied.violations.map(\.name).sorted().joined(separator: ",")
      let disposition = String(describing: applied.transition?.disposition)
      let signature = "\(state)|\(observation)|\(disposition)|\(applied.gateRejected)"
      var seen = signatures[action.stableClass, default: []]
      if seen.contains(signature) {
        removed += 1
      } else {
        retained.append(action)
        seen.insert(signature)
        signatures[action.stableClass] = seen
      }
    }
    let validation =
      validateDiamonds
      ? validateIndependentDiamonds(
        actions: retained, node: node, definition: definition,
        configuration: configuration
      )
      : (validated: 0, nonCommuting: 0)
    return Reduction(
      actions: retained, removedCount: removed,
      validatedDiamondCount: validation.validated,
      nonCommutingDiamondCount: validation.nonCommuting
    )
  }

  private static func isSafeEquivalenceCandidate(_ action: SearchAction) -> Bool {
    if case .result(_, _, .wrongOperation) = action { return true }
    return false
  }

  private static func validateIndependentDiamonds(
    actions: [SearchAction],
    node: PlaybackSearchNode,
    definition: PlaybackSearchModelDefinition,
    configuration: PlaybackSearchConfiguration
  ) -> (validated: Int, nonCommuting: Int) {
    let candidates = actions.filter {
      switch $0 {
      case .runtimeFact(let fact, .current):
        return isFair(fact)
      case .seekPrerequisite, .seekAggregateReady, .recoveryPrerequisite,
        .trackPrerequisite, .recoveryAggregateReady, .trackAggregateReady,
        .queueOffer, .queueConsume:
        return true
      default:
        return false
      }
    }
    var validated = 0
    var nonCommuting = 0
    for firstIndex in candidates.indices {
      for secondIndex in candidates.indices where secondIndex > firstIndex {
        let first = candidates[firstIndex]
        let second = candidates[secondIndex]
        let afterFirst = apply(action: first, to: node, configuration: configuration)
        let afterSecond = apply(action: second, to: node, configuration: configuration)
        let secondRemainsEnabled = definition.enabledActions(
          for: afterFirst.node, configuration: configuration
        ).contains(second)
        let firstRemainsEnabled = definition.enabledActions(
          for: afterSecond.node, configuration: configuration
        ).contains(first)
        guard secondRemainsEnabled, firstRemainsEnabled else { continue }
        let firstThenSecond = apply(
          action: second, to: afterFirst.node, configuration: configuration
        )
        let secondThenFirst = apply(
          action: first, to: afterSecond.node, configuration: configuration
        )
        validated += 1
        let sameState =
          PlaybackSearchCanonicalizer.key(for: firstThenSecond.node)
          == PlaybackSearchCanonicalizer.key(for: secondThenFirst.node)
        let sameObservations =
          Set(
            (afterFirst.violations + firstThenSecond.violations).map(\.name)
          ) == Set((afterSecond.violations + secondThenFirst.violations).map(\.name))
        if !sameState || !sameObservations { nonCommuting += 1 }
      }
    }
    return (validated, nonCommuting)
  }
}
