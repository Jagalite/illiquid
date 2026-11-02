import IlliquidPlaybackModel
import Statelessness

/// Progress summary recorded in qualification records.
public struct PlaybackProgressReport: Codable, Hashable, Sendable {
  public let terminalStates: Int
  public let stableIntentionalWaitStates: Int
  public let externalWaitStates: Int
  public let unmeasuredCutoffStates: Int
  public let transactionStates: Int
  public let settledTransactionStates: Int
  public let stuckStates: [Int]
  public let closedNonterminalSCCs: [Set<Int>]
  public let maximumObligationRank: Int
}

/// Playback progress predicates for Statelessness progress analysis (S3).
///
/// Illiquid defines terminal, wait, transaction and obligation-rank semantics
/// and edge fairness. Statelessness owns strongly connected components,
/// reverse reachability and closed-component detection. A node is unmeasured
/// when its outgoing edges are not all known (a depth frontier, interrupted or
/// unexpanded node, or rejected successor). Unmeasured nodes are never proof
/// of deadlock or of progress. Fair-path reachability and rank decrease are
/// bounded evidence, not a proof that every scheduler run completes.
public enum PlaybackProgressPolicy {
  public static func kind(_ node: PlaybackSearchNode) -> ProgressKind {
    if node.coreState.lifecycle == .terminated { return .terminal }
    if hasDeclaredExternalWait(node) { return .externalWait }
    if isStable(node) { return .intentionalWait }
    if isTransaction(node) { return .transaction }
    return .other
  }

  public static func rank(_ node: PlaybackSearchNode) -> UInt64 {
    UInt64(obligationRank(node))
  }

  public static func isFair(_ edge: PlaybackGraphEdge) -> Bool {
    edge.outputs.first?.isFairProgress ?? false
  }

  public static func analyze(_ report: PlaybackGraphReport) throws -> ProgressReport {
    try analyzeProgress(
      graph(report),
      kind: { kind(report.nodes[$0].state.node) },
      rank: { rank(report.nodes[$0].state.node) })
  }

  /// The progress graph of a report. When a graph byte budget ended the
  /// search, `edgesRetained` is false although every edge evaluated before
  /// the cutoff is retained. The graph is then built from those edges with the
  /// same rules as `ProgressGraph(report:fair:)`, and every node not
  /// completely expanded is unmeasured.
  public static func graph(_ report: PlaybackGraphReport) throws -> ProgressGraph {
    if report.edgesRetained { return try ProgressGraph(report: report, fair: isFair) }
    var measured = report.nodes.map { $0.expansion == .complete }
    var edges: [ProgressEdge] = []
    for edge in report.edges {
      var target = edge.target
      var hops = 0
      while case .reduced(let representative) = target,
        report.edges.indices.contains(representative), hops <= report.edges.count
      {
        target = report.edges[representative].target
        hops += 1
      }
      switch target {
      case .admitted(let node), .duplicate(let node):
        edges.append(ProgressEdge(source: edge.source, target: node, fair: isFair(edge)))
      default:
        measured[edge.source] = false
      }
    }
    return try ProgressGraph(nodeCount: report.nodes.count, edges: edges, measured: measured)
  }

  public static var reductionPredicates: ReductionProgressPredicates<
    PlaybackModelState, SearchAction, PlaybackModelObservation
  > {
    ReductionProgressPredicates(
      fair: isFair, kind: { kind($0.node) }, rank: { rank($0.node) })
  }

  /// The qualification record's summary of a Statelessness progress report.
  public static func summary(_ report: ProgressReport) -> PlaybackProgressReport {
    PlaybackProgressReport(
      terminalStates: report.terminalStates,
      stableIntentionalWaitStates: report.stableIntentionalWaitStates,
      externalWaitStates: report.externalWaitStates,
      unmeasuredCutoffStates: report.unmeasuredStates,
      transactionStates: report.transactionStates,
      settledTransactionStates: report.settledTransactionStates,
      stuckStates: report.stuckStates,
      closedNonterminalSCCs: report.closedNonterminalComponents.map(Set.init),
      maximumObligationRank: Int(clamping: report.maximumRank))
  }

  static func isStable(_ node: PlaybackSearchNode) -> Bool {
    guard node.coreState.lifecycle == .running else { return false }
    guard let session = node.coreState.activeSession else { return true }
    return [.playing, .paused, .ended, .stopped, .failed, .ready].contains(session.phase)
  }

  static func isTransaction(_ node: PlaybackSearchNode) -> Bool {
    if node.coreState.lifecycle == .shuttingDown { return true }
    guard let session = node.coreState.activeSession else { return false }
    return session.seek != nil || session.tracks.phase != .idle || session.phase == .draining
      || session.phase == .opening || session.phase == .prerolling || session.phase == .seeking
      || !session.recovery.consumedVideoFallbackLineages.isEmpty
  }

  static func hasDeclaredExternalWait(_ node: PlaybackSearchNode) -> Bool {
    if node.ghost.externalWait != nil || node.coreState.externalWaitReason != nil { return true }
    if !node.coreState.outstandingEffects.isEmpty { return true }
    guard let session = node.coreState.activeSession else { return false }
    if session.phase == .buffering { return true }
    if session.phase == .draining,
      !session.drain.observed.isSuperset(of: session.drain.required)
    {
      return true
    }
    if session.phase == .prerolling, !session.synchronization.startupAcknowledged {
      return true
    }
    return false
  }

  static func obligationRank(_ node: PlaybackSearchNode) -> Int {
    guard let session = node.coreState.activeSession else {
      return node.coreState.lifecycle == .shuttingDown
        ? node.coreState.outstandingEffects.count + 1 : 0
    }
    var rank = node.coreState.outstandingEffects.count
    rank += session.drain.required.subtracting(session.drain.observed).count
    if session.seek != nil { rank += 2 }
    if session.tracks.phase != .idle { rank += 2 }
    if !session.synchronization.startupAcknowledged { rank += 1 }
    return rank
  }
}
