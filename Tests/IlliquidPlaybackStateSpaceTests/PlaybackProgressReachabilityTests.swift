import IlliquidPlaybackCore
import Testing

@testable import IlliquidPlaybackStateSpace

@Suite("Playback progress fair reachability")
struct PlaybackProgressReachabilityTests {
  @Test
  func emptyAndAlreadySettledGraphsHaveNoTransactionWork() {
    let empty = PlaybackProgressAnalyzer.analyze(makeResult(states: [], edges: []))
    #expect(empty == PlaybackProgressReport(
      terminalStates: 0, stableIntentionalWaitStates: 0, externalWaitStates: 0,
      unmeasuredCutoffStates: 0, transactionStates: 0, settledTransactionStates: 0,
      stuckStates: [], closedNonterminalSCCs: [], maximumObligationRank: 0
    ))

    let settled = PlaybackProgressAnalyzer.analyze(makeResult(
      states: [.terminal, .stable, .external],
      edges: [edge(0, 1), edge(1, 2), edge(2, 0)]
    ))
    #expect(settled == PlaybackProgressReport(
      terminalStates: 1, stableIntentionalWaitStates: 1, externalWaitStates: 1,
      unmeasuredCutoffStates: 0, transactionStates: 0, settledTransactionStates: 0,
      stuckStates: [], closedNonterminalSCCs: [], maximumObligationRank: 1
    ))
  }

  @Test
  func fairReachabilityIsBackwardAndIndependentOfEdgeOrder() {
    let edges = [
      edge(0, 1), edge(1, 2), edge(2, 3),
      edge(1, 2), edge(1, 1), edge(4, 4),
      // Reaching a state FROM a terminal is not a path TO settlement.
      edge(3, 4),
    ]
    let expected = PlaybackProgressReport(
      terminalStates: 1, stableIntentionalWaitStates: 0, externalWaitStates: 0,
      unmeasuredCutoffStates: 0, transactionStates: 4, settledTransactionStates: 3,
      stuckStates: [], closedNonterminalSCCs: [Set([4])], maximumObligationRank: 1
    )
    for order in [edges, Array(edges.reversed()), Array(edges.dropFirst(2)) + Array(edges.prefix(2))] {
      let report = PlaybackProgressAnalyzer.analyze(makeResult(
        states: [.transaction, .transaction, .transaction, .terminal, .transaction],
        edges: order
      ))
      #expect(report == expected)
    }
  }

  @Test
  func unfairEdgesAndDepthCutoffsDoNotSeedSettlement() {
    let result = makeResult(
      states: [.transaction, .transaction, .terminal, .cutoff, .stuck],
      edges: [
        edge(0, 1), edge(1, 1), edge(1, 2, fair: false),
        edge(0, 3), edge(4, 2),
      ]
    )
    #expect(PlaybackProgressAnalyzer.analyze(result) == PlaybackProgressReport(
      terminalStates: 1, stableIntentionalWaitStates: 0, externalWaitStates: 0,
      unmeasuredCutoffStates: 1, transactionStates: 2, settledTransactionStates: 0,
      stuckStates: [4], closedNonterminalSCCs: [], maximumObligationRank: 1
    ))
  }

  @Test
  func fairCyclesWithoutSettlementKeepTheirClosedComponent() {
    let result = makeResult(
      states: [.transaction, .transaction],
      edges: [edge(0, 1), edge(1, 0), edge(0, 0), edge(1, 0)]
    )
    #expect(PlaybackProgressAnalyzer.analyze(result) == PlaybackProgressReport(
      terminalStates: 0, stableIntentionalWaitStates: 0, externalWaitStates: 0,
      unmeasuredCutoffStates: 0, transactionStates: 2, settledTransactionStates: 0,
      stuckStates: [], closedNonterminalSCCs: [Set([0, 1])], maximumObligationRank: 1
    ))
  }

  @Test
  func terminalStableAndDeclaredExternalWaitsAllSeedSettlement() {
    let result = makeResult(
      states: [
        .transaction, .transaction, .transaction, .terminal,
        .stable, .external, .cutoff, .transaction,
      ],
      edges: [edge(0, 3), edge(1, 4), edge(2, 5), edge(7, 6)]
    )
    #expect(PlaybackProgressAnalyzer.analyze(result) == PlaybackProgressReport(
      terminalStates: 1, stableIntentionalWaitStates: 1, externalWaitStates: 1,
      unmeasuredCutoffStates: 1, transactionStates: 4, settledTransactionStates: 3,
      stuckStates: [], closedNonterminalSCCs: [], maximumObligationRank: 1
    ))
  }

  @Test
  func fairPathsMayPassThroughNontransactionStatesWithoutReclassifyingThem() {
    let result = makeResult(
      states: [.transaction, .cutoff, .stuck, .terminal],
      edges: [edge(0, 1), edge(1, 2), edge(2, 3)]
    )
    #expect(PlaybackProgressAnalyzer.analyze(result) == PlaybackProgressReport(
      terminalStates: 1, stableIntentionalWaitStates: 0, externalWaitStates: 0,
      unmeasuredCutoffStates: 1, transactionStates: 1, settledTransactionStates: 1,
      stuckStates: [2], closedNonterminalSCCs: [], maximumObligationRank: 1
    ))
  }

  @Test
  func exhaustiveFourStateGraphsAgreeWithForwardPathSearch() {
    // Each transaction has a fair self-loop to keep its classification fixed.
    // Enumerate all 512 fair/unfair assignments to the other outgoing edges.
    let links = (0..<3).flatMap { from in
      (0..<4).filter { $0 != from }.map { (from, $0) }
    }
    for mask in 0..<(1 << links.count) {
      var edges = (0..<3).map { edge($0, $0) }
      for (index, link) in links.enumerated() {
        edges.append(edge(link.0, link.1, fair: mask & (1 << index) != 0))
      }
      edges.append(edge(3, 0, fair: false))
      let expected = (0..<3).count(where: { reachesTerminal(from: $0, edges: edges) })
      for order in [edges, Array(edges.reversed())] {
        let report = PlaybackProgressAnalyzer.analyze(makeResult(
          states: [.transaction, .transaction, .transaction, .terminal], edges: order
        ))
        #expect(report.transactionStates == 3)
        #expect(report.settledTransactionStates == expected)
      }
    }
  }

  private func reachesTerminal(from start: Int, edges: [PlaybackSearchGraph.Edge]) -> Bool {
    // Independent source-to-target search: follow outgoing fair paths from each
    // transaction, rather than propagating a shared set backwards from terminal.
    var pending = [start]
    var visited: Set<Int> = []
    while let current = pending.popLast() {
      if current == 3 { return true }
      guard visited.insert(current).inserted else { continue }
      pending.append(contentsOf: edges.filter { $0.from == current && $0.isFairProgress }.map(\.to))
    }
    return false
  }

  private enum State {
    case transaction, terminal, stable, external, cutoff, stuck
  }

  private func edge(_ from: Int, _ to: Int, fair: Bool = true) -> PlaybackSearchGraph.Edge {
    .init(from: from, to: to, actionClass: "fixture", isFairProgress: fair)
  }

  private func makeResult(states: [State], edges: [PlaybackSearchGraph.Edge]) -> PlaybackSearchResult {
    let nodes = states.map { kind -> PlaybackSearchNode in
      var state = PlaybackCoreState()
      var depth = 0
      switch kind {
      case .transaction:
        state.lifecycle = .shuttingDown
      case .terminal:
        state.lifecycle = .terminated
      case .stable:
        break
      case .external:
        state.lifecycle = .shuttingDown
        state.externalWaitReason = .shutdownCancellationFailed
      case .cutoff:
        state.lifecycle = .terminated
        depth = 4
      case .stuck:
        state.lifecycle = .invariantFailed
      }
      return PlaybackSearchNode(
        model: .stopShutdown, coreState: state,
        environment: .stopShutdown(StopShutdownSearchEnvironment()), depth: depth
      )
    }
    return PlaybackSearchResult(
      summary: PlaybackSearchSummary(
        model: .stopShutdown, modelVersion: 1, seedProfile: "manual-progress-graph",
        configuration: .validation(depthLimit: 4), termination: .completeWithinBounds,
        stateCount: nodes.count, edgeCount: edges.count, productionTransitionCount: 0,
        gateRejectionCount: 0, peakFrontier: 0, deepestCompletedLayer: 0,
        reducedEdgeCount: 0, validatedDiamondCount: 0, nonCommutingDiamondCount: 0,
        canonicalDigest: "manual-progress-graph"
      ),
      oracle: .production, failures: [], graph: PlaybackSearchGraph(edges: edges),
      nodes: nodes, predecessors: Array(repeating: nil, count: nodes.count)
    )
  }
}
