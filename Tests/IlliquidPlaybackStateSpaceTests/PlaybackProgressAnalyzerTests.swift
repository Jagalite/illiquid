import IlliquidPlaybackCore
import Testing
@testable import IlliquidPlaybackStateSpace

@Suite("Playback progress graph analysis")
struct PlaybackProgressAnalyzerTests {
  private func edge(_ from: Int, _ to: Int, fair: Bool = false) -> PlaybackSearchGraph.Edge {
    .init(from: from, to: to, actionClass: "test", isFairProgress: fair)
  }

  @Test
  func emptyAndIsolatedGraphsKeepVertexOrder() {
    #expect(PlaybackProgressAnalyzer.stronglyConnectedComponents(nodeCount: 0, edges: []).isEmpty)
    #expect(
      PlaybackProgressAnalyzer.stronglyConnectedComponents(nodeCount: 4, edges: [])
        == [Set([0]), Set([1]), Set([2]), Set([3])]
    )
  }

  @Test
  func cyclesParallelEdgesAndSelfLoopsKeepComponentOrder() {
    let edges = [
      edge(0, 1), edge(1, 2, fair: true), edge(2, 0), edge(2, 3),
      edge(3, 4), edge(4, 3, fair: true), edge(4, 5), edge(5, 5),
      edge(0, 1, fair: true),
    ]
    #expect(
      PlaybackProgressAnalyzer.stronglyConnectedComponents(nodeCount: 7, edges: edges)
        == [Set([5]), Set([3, 4]), Set([0, 1, 2]), Set([6])]
    )
    let cycle = (0..<128).map { edge($0, ($0 + 1) % 128) }
    #expect(
      PlaybackProgressAnalyzer.stronglyConnectedComponents(nodeCount: 128, edges: cycle)
        == [Set(0..<128)]
    )
  }

  @Test
  func edgesIntoCompletedComponentsDoNotMergeThem() {
    #expect(
      PlaybackProgressAnalyzer.stronglyConnectedComponents(
        nodeCount: 4, edges: [edge(0, 1), edge(2, 1), edge(3, 2)]
      ) == [Set([1]), Set([0]), Set([2]), Set([3])]
    )
  }

  @Test
  func allThreeVertexGraphsMatchIndependentReachability() {
    // Mutual reachability defines SCC membership without implementing Tarjan.
    for mask in 0..<(1 << 9) {
      var edges: [PlaybackSearchGraph.Edge] = []
      var reachable = Array(repeating: Array(repeating: false, count: 3), count: 3)
      for from in 0..<3 {
        reachable[from][from] = true
        for to in 0..<3 where mask & (1 << (from * 3 + to)) != 0 {
          edges.append(edge(from, to, fair: (from + to) % 2 == 0))
          reachable[from][to] = true
        }
      }
      for via in 0..<3 {
        for from in 0..<3 {
          for to in 0..<3 where reachable[from][via] && reachable[via][to] {
            reachable[from][to] = true
          }
        }
      }
      let expected = Set((0..<3).map { from in
        Set((0..<3).filter { reachable[from][$0] && reachable[$0][from] })
      })
      for orderedEdges in [edges, Array(edges.reversed())] {
        let actual = PlaybackProgressAnalyzer.stronglyConnectedComponents(
          nodeCount: 3, edges: orderedEdges
        )
        #expect(Set(actual) == expected, "Graph mask \(mask)")
        #expect(actual.reduce(0) { $0 + $1.count } == 3)
      }
    }
  }

  @Test
  func completeReportPreservesWaitCutoffAndFairProgressSemantics() {
    let configuration = PlaybackSearchConfiguration.validation(depthLimit: 2)
    let nodes = (0..<14).map { index -> PlaybackSearchNode in
      let lifecycle: PlaybackLifecyclePhase
      switch index {
      case 0, 8: lifecycle = .terminated
      case 1, 2: lifecycle = .running
      case 7, 11, 13: lifecycle = .invariantFailed
      default: lifecycle = .shuttingDown
      }
      return PlaybackSearchNode(
        model: .stopShutdown,
        coreState: PlaybackCoreState(lifecycle: lifecycle),
        environment: .stopShutdown(StopShutdownSearchEnvironment()),
        ghost: PlaybackSearchGhost(externalWait: index == 2 ? .effectResult : nil),
        depth: index == 8 ? configuration.depthLimit : 0
      )
    }
    let edges = [
      edge(3, 0, fair: true), edge(4, 3, fair: true),
      edge(5, 6, fair: true), edge(6, 5, fair: true), edge(7, 7),
      edge(9, 8, fair: true), edge(10, 0), edge(11, 1),
      edge(12, 13, fair: true), edge(13, 12),
    ]
    let result = PlaybackSearchResult(
      summary: PlaybackSearchSummary(
        model: .stopShutdown, modelVersion: 0, seedProfile: "synthetic-progress",
        configuration: configuration, termination: .completeWithinBounds,
        stateCount: nodes.count, edgeCount: edges.count,
        productionTransitionCount: 0, gateRejectionCount: 0, peakFrontier: 0,
        deepestCompletedLayer: 0, reducedEdgeCount: 0, validatedDiamondCount: 0,
        nonCommutingDiamondCount: 0, canonicalDigest: "synthetic"
      ),
      oracle: .production, failures: [], graph: PlaybackSearchGraph(edges: edges),
      nodes: nodes, predecessors: Array(repeating: nil, count: nodes.count)
    )
    #expect(
      PlaybackProgressAnalyzer.analyze(result) == PlaybackProgressReport(
        terminalStates: 1, stableIntentionalWaitStates: 1, externalWaitStates: 1,
        unmeasuredCutoffStates: 1, transactionStates: 6, settledTransactionStates: 2,
        stuckStates: [7, 10, 11, 13],
        closedNonterminalSCCs: [Set([5, 6]), Set([7])], maximumObligationRank: 1
      )
    )
  }
}
