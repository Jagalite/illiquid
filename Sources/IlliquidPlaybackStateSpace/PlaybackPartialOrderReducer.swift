public enum PlaybackPartialOrderReducer {
  public struct Reduction: Sendable {
    public let actions: [SearchAction]
    public let removedCount: Int
    public let validatedDiamondCount: Int
    public let nonCommutingDiamondCount: Int
  }

  public static func reduce(
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
