import IlliquidPlaybackCore
import Statelessness

/// Playback partial-order reduction policy for Statelessness (S4).
///
/// Illiquid owns which actions may be collapsed and what must be preserved.
/// Statelessness owns the reduction, the diamond validation and the
/// reduced-versus-unreduced comparison. The scope is unchanged from the
/// original reducer: only `wrongOperation` result mutations are eligible, and
/// diamonds are validated for fair current facts and environment steps.
public enum PlaybackReductionPolicy {
  /// Version 2 declares same-stream queue offer/consume pairs dependent.
  public static let version: UInt32 = 2

  /// The equivalence class of an eligible action, or nil.
  public static func eligibleClass(_ action: SearchAction) -> String? {
    if case .result(_, _, .wrongOperation) = action { return action.stableClass }
    return nil
  }

  /// The original reducer's signature, apart from the successor state: the
  /// production disposition, whether ingress was gate-rejected, and the
  /// violation names. Statelessness additionally requires equal Statelessness
  /// dispositions, identical checks, and model-equal successors, which
  /// replaces the original digest-only successor comparison.
  public static func projection(
    _ action: SearchAction,
    _ transition: Transition<PlaybackModelState, PlaybackModelObservation>,
    _ labels: [String]
  ) -> [UInt8] {
    let observation = transition.outputs.first
    let names = (observation?.violations ?? []).map(\.name).sorted().joined(separator: ",")
    let disposition = String(describing: observation?.transition?.disposition)
    let gate = observation?.kind == .ingressRejected
    return Array("\(names)|\(disposition)|\(gate)".utf8)
  }

  public static var reduction: EquivalenceReduction<
    PlaybackModelState, SearchAction, PlaybackModelObservation
  > {
    EquivalenceReduction(
      eligibleClass: { _, action in eligibleClass(action) },
      projection: projection)
  }

  /// Diamond candidates: fair current runtime facts and environment steps.
  public static func isDiamondCandidate(_ action: SearchAction) -> Bool {
    switch action {
    case .runtimeFact(let fact, .current): isFair(fact)
    case .seekPrerequisite, .seekAggregateReady, .recoveryPrerequisite,
      .trackPrerequisite, .recoveryAggregateReady, .trackAggregateReady,
      .queueOffer, .queueConsume:
      true
    default: false
    }
  }

  /// Pairs that are dependent by design and are never assumed independent: an
  /// offer and a consume on the same abstract queue do not commute at queue
  /// bounds (full → offer → consume ends `partial`, consume → offer ends
  /// `full`). Neither action is ever reduced, so no reduction relies on their
  /// independence. Their diamonds are reported separately and do not fail
  /// validation. Any other noncommuting candidate pair does.
  public static func isDeclaredDependent(_ first: SearchAction, _ second: SearchAction) -> Bool {
    switch (first, second) {
    case (.queueOffer(let a), .queueConsume(let b)), (.queueConsume(let a), .queueOffer(let b)):
      a == b
    default: false
    }
  }

  /// Validates enabled-action diamonds on every completely expanded node.
  /// Observations compare failed property identities only, as before.
  public static func validateDiamonds(
    model: PlaybackStatelessnessModel,
    report: PlaybackGraphReport
  ) throws -> DiamondReport<SearchAction> {
    try Statelessness.validateDiamonds(
      model, report: report,
      candidate: { _, action in isDiamondCandidate(action) },
      equalInputs: { $0 == $1 },
      projection: { _, _ in [] })
  }
}
