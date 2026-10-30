import IlliquidPlaybackCore
import Testing

@testable import IlliquidPlaybackStateSpace

@Suite("Playback fair-progress reachability")
struct PlaybackProgressReachabilityTests {
  private enum Role: CaseIterable, Equatable {
    case terminal, stable, external, cutoff, work
  }

  @Test
  func emptyUnseededAndFullySettledGraphs() {
    check([], [])
    check([.work], [])
    check([.work, .work], [edge(0, 1), edge(1, 0)])
    check([.terminal, .stable, .external], [
      edge(0, 1), edge(1, 2, fair: false), edge(2, 2),
    ])
  }

  @Test
  func everySettledClassificationSeedsFairPredecessors() {
    check([.work, .work, .work, .terminal, .stable, .external], [
      edge(0, 3), edge(1, 4), edge(2, 5),
    ])
  }

  @Test
  func cutoffNodesCanCarryFairPathsButDoNotSeedThem() {
    check([.work, .cutoff, .work, .terminal], [
      edge(0, 1), edge(1, 2), edge(2, 3),
    ])
    check([.work, .cutoff, .work], [
      edge(0, 1), edge(1, 0), edge(1, 2), edge(2, 2),
    ])
  }

  @Test
  func unfairBridgesCyclesDuplicateEdgesAndSelfLoops() {
    check([.work, .work, .terminal], [
      edge(0, 1), edge(1, 2, fair: false), edge(1, 1),
    ])
    check([.work, .work, .terminal], [
      edge(0, 1), edge(1, 0), edge(1, 2),
    ])
    check([.work, .terminal], [
      edge(0, 0), edge(0, 0), edge(0, 1), edge(0, 1),
    ])
  }

  @Test
  func edgeOrderDoesNotChangeADeepFairChain() {
    let roles = Array(repeating: Role.work, count: 31) + [.terminal]
    let edges = (0..<31).map { edge($0, $0 + 1) }
    check(roles, edges)
    check(roles, Array(edges.reversed()))
    check(roles, edges.filter { $0.from.isMultiple(of: 2) }
      + edges.filter { !$0.from.isMultiple(of: 2) })
  }

  @Test
  func seededSmallGraphsMatchAnIndependentCompleteReportOracle() {
    for seed in 0..<96 {
      var state = UInt64(seed + 1)
      func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state >> 32
      }
      let count = seed % 12
      let roles = (0..<count).map { _ in
        Role.allCases[Int(next() % UInt64(Role.allCases.count))]
      }
      var edges: [PlaybackSearchGraph.Edge] = []
      if count > 0 {
        for _ in 0..<(count * 3) {
          edges.append(edge(
            Int(next() % UInt64(count)), Int(next() % UInt64(count)),
            fair: next() % 3 != 0
          ))
        }
      }
      check(roles, edges)
    }
  }

  private func edge(_ from: Int, _ to: Int, fair: Bool = true) -> PlaybackSearchGraph.Edge {
    .init(from: from, to: to, actionClass: "fixture", isFairProgress: fair)
  }

  private func rank(_ role: Role) -> Int {
    role == .work || role == .external ? 1 : 0
  }

  private func result(_ roles: [Role], _ edges: [PlaybackSearchGraph.Edge])
    -> PlaybackSearchResult
  {
    let configuration = PlaybackSearchConfiguration.validation(depthLimit: 4)
      .withTimeLimitSeconds(nil)
    let nodes = roles.map { role in
      let lifecycle: PlaybackLifecyclePhase
      switch role {
      case .terminal: lifecycle = .terminated
      case .external, .work: lifecycle = .shuttingDown
      case .stable, .cutoff: lifecycle = .running
      }
      return PlaybackSearchNode(
        model: .stopShutdown,
        coreState: PlaybackCoreState(
          lifecycle: lifecycle,
          externalWaitReason: role == .external ? .shutdownCancellationFailed : nil
        ),
        environment: .stopShutdown(StopShutdownSearchEnvironment()),
        depth: role == .cutoff ? configuration.depthLimit : 0
      )
    }
    let summary = PlaybackSearchSummary(
      model: .stopShutdown, modelVersion: 1, seedProfile: "reachability-fixture",
      configuration: configuration, termination: .completeWithinBounds,
      stateCount: nodes.count, edgeCount: edges.count, productionTransitionCount: 0,
      gateRejectionCount: 0, peakFrontier: 0, deepestCompletedLayer: 0,
      reducedEdgeCount: 0, validatedDiamondCount: 0, nonCommutingDiamondCount: 0,
      canonicalDigest: "fixture"
    )
    return PlaybackSearchResult(
      summary: summary, oracle: .production, failures: [],
      graph: PlaybackSearchGraph(edges: edges), nodes: nodes,
      predecessors: Array(repeating: nil, count: nodes.count)
    )
  }

  private func check(_ roles: [Role], _ edges: [PlaybackSearchGraph.Edge]) {
    let report = PlaybackProgressAnalyzer.analyze(result(roles, edges))
    let fairSources = Set(edges.filter(\.isFairProgress).map(\.from))
    let transactions = roles.indices.filter { roles[$0] == .work && fairSources.contains($0) }
    let stuck = roles.indices.filter { roles[$0] == .work && !fairSources.contains($0) }

    // Synchronous fixed-point rounds are deliberately independent of the
    // production reverse adjacency/worklist. Only the previous round can
    // justify adding a predecessor in the next round.
    var canSettle = Set(roles.indices.filter {
      roles[$0] == .terminal || roles[$0] == .stable || roles[$0] == .external
    })
    while true {
      let predecessors = edges.filter {
        $0.isFairProgress && canSettle.contains($0.to)
      }.map(\.from)
      let next = canSettle.union(predecessors)
      if next == canSettle { break }
      canSettle = next
    }

    // Small graphs permit an independent transitive-closure SCC oracle.
    // This also verifies that the reachability change leaves every other
    // report field and closed-component classification intact.
    var reachable = Array(
      repeating: Array(repeating: false, count: roles.count), count: roles.count
    )
    for vertex in roles.indices { reachable[vertex][vertex] = true }
    for edge in edges { reachable[edge.from][edge.to] = true }
    for intermediate in roles.indices {
      for from in roles.indices where reachable[from][intermediate] {
        for to in roles.indices where reachable[intermediate][to] {
          reachable[from][to] = true
        }
      }
    }
    var assigned: Set<Int> = []
    var closed: Set<Set<Int>> = []
    for vertex in roles.indices where !assigned.contains(vertex) {
      let component = Set(roles.indices.filter {
        reachable[vertex][$0] && reachable[$0][vertex]
      })
      assigned.formUnion(component)
      guard component.contains(where: { roles[$0] == .work }) else { continue }
      let outgoing = edges.filter { component.contains($0.from) }
      let hasExit = outgoing.contains { !component.contains($0.to) }
      let hasFairDecrease = outgoing.contains {
        $0.isFairProgress && rank(roles[$0.to]) < rank(roles[$0.from])
      }
      if !hasExit && !hasFairDecrease { closed.insert(component) }
    }

    #expect(report.terminalStates == roles.filter { $0 == .terminal }.count)
    #expect(report.stableIntentionalWaitStates == roles.filter { $0 == .stable }.count)
    #expect(report.externalWaitStates == roles.filter { $0 == .external }.count)
    #expect(report.unmeasuredCutoffStates == roles.filter { $0 == .cutoff }.count)
    #expect(report.transactionStates == transactions.count)
    #expect(report.settledTransactionStates == transactions.filter { canSettle.contains($0) }.count)
    #expect(report.stuckStates == stuck)
    #expect(Set(report.closedNonterminalSCCs) == closed)
    #expect(report.closedNonterminalSCCs.count == closed.count)
    #expect(report.maximumObligationRank == (roles.map(rank).max() ?? 0))
  }
}
