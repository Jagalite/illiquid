import IlliquidPlaybackCore

public enum PlaybackProgressClassification: String, Codable, Hashable, Sendable {
  case terminal
  case stableIntentionalWait
  case declaredExternalWait
  case transactionProgress
  case stuck
  case unmeasuredCutoff
}

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

public enum PlaybackProgressAnalyzer {
  public static func analyze(_ result: PlaybackSearchResult) -> PlaybackProgressReport {
    let outgoing = Dictionary(grouping: result.graph.edges, by: \.from)
    var classifications: [PlaybackProgressClassification] = []
    var ranks: [Int] = []
    for (index, node) in result.nodes.enumerated() {
      let rank = obligationRank(node)
      ranks.append(rank)
      if node.depth >= result.summary.configuration.depthLimit {
        classifications.append(.unmeasuredCutoff)
      } else if node.coreState.lifecycle == .terminated {
        classifications.append(.terminal)
      } else if hasDeclaredExternalWait(node) {
        classifications.append(.declaredExternalWait)
      } else if isStable(node) {
        classifications.append(.stableIntentionalWait)
      } else if isTransaction(node),
        outgoing[index, default: []].contains(where: \.isFairProgress)
      {
        classifications.append(.transactionProgress)
      } else {
        classifications.append(.stuck)
      }
    }

    let settled = Set(
      classifications.indices.filter {
        classifications[$0] == .terminal || classifications[$0] == .stableIntentionalWait
          || classifications[$0] == .declaredExternalWait
      })
    var canSettle = settled
    var changed = true
    while changed {
      changed = false
      for edge in result.graph.edges where edge.isFairProgress && canSettle.contains(edge.to) {
        if canSettle.insert(edge.from).inserted { changed = true }
      }
    }

    let components = stronglyConnectedComponents(
      nodeCount: result.nodes.count, outgoing: outgoing
    )
    let closedNonterminal = components.filter { component in
      guard
        component.contains(where: {
          classifications[$0] == .transactionProgress || classifications[$0] == .stuck
        })
      else { return false }
      let outgoingEdges = component.flatMap { outgoing[$0, default: []] }
      let hasExit = outgoingEdges.contains { !component.contains($0.to) }
      let hasFairDecrease = outgoingEdges.contains {
        $0.isFairProgress && ranks[$0.to] < ranks[$0.from]
      }
      return !hasExit && !hasFairDecrease
    }
    let transactionIndices = classifications.indices.filter {
      classifications[$0] == .transactionProgress
    }
    return PlaybackProgressReport(
      terminalStates: classifications.count(where: { $0 == .terminal }),
      stableIntentionalWaitStates: classifications.count(where: { $0 == .stableIntentionalWait }),
      externalWaitStates: classifications.count(where: { $0 == .declaredExternalWait }),
      unmeasuredCutoffStates: classifications.count(where: { $0 == .unmeasuredCutoff }),
      transactionStates: transactionIndices.count,
      settledTransactionStates: transactionIndices.count(where: { canSettle.contains($0) }),
      stuckStates: classifications.indices.filter { classifications[$0] == .stuck },
      closedNonterminalSCCs: closedNonterminal,
      maximumObligationRank: ranks.max() ?? 0
    )
  }

  public static func stronglyConnectedComponents(
    nodeCount: Int,
    edges: [PlaybackSearchGraph.Edge]
  ) -> [Set<Int>] {
    stronglyConnectedComponents(
      nodeCount: nodeCount, outgoing: Dictionary(grouping: edges, by: \.from)
    )
  }

  private static func stronglyConnectedComponents(
    nodeCount: Int,
    outgoing: [Int: [PlaybackSearchGraph.Edge]]
  ) -> [Set<Int>] {
    // The analyzer already groups these edges for classification. Reuse that
    // index, retaining the original successor order for deterministic reports.
    var nextIndex = 0
    var indices = [Int](repeating: -1, count: nodeCount)
    var lowLinks = Array(repeating: 0, count: nodeCount)
    var stack: [Int] = []
    // Search vertices are dense indices in 0..<nodeCount.
    var onStack = [Bool](repeating: false, count: nodeCount)
    var components: [Set<Int>] = []

    func visit(_ vertex: Int) {
      indices[vertex] = nextIndex
      lowLinks[vertex] = nextIndex
      nextIndex += 1
      stack.append(vertex)
      onStack[vertex] = true
      for edge in outgoing[vertex, default: []] {
        let successor = edge.to
        if indices[successor] == -1 {
          visit(successor)
          lowLinks[vertex] = min(lowLinks[vertex], lowLinks[successor])
        } else if onStack[successor] {
          lowLinks[vertex] = min(lowLinks[vertex], indices[successor])
        }
      }
      guard lowLinks[vertex] == indices[vertex] else { return }
      var component: Set<Int> = []
      while let member = stack.popLast() {
        onStack[member] = false
        component.insert(member)
        if member == vertex { break }
      }
      components.append(component)
    }

    for vertex in 0..<nodeCount where indices[vertex] == -1 { visit(vertex) }
    return components
  }

  private static func isStable(_ node: PlaybackSearchNode) -> Bool {
    guard node.coreState.lifecycle == .running else { return false }
    guard let session = node.coreState.activeSession else { return true }
    return [.playing, .paused, .ended, .stopped, .failed, .ready].contains(session.phase)
  }

  private static func isTransaction(_ node: PlaybackSearchNode) -> Bool {
    if node.coreState.lifecycle == .shuttingDown { return true }
    guard let session = node.coreState.activeSession else { return false }
    return session.seek != nil || session.tracks.phase != .idle || session.phase == .draining
      || session.phase == .opening || session.phase == .prerolling || session.phase == .seeking
      || !session.recovery.consumedVideoFallbackLineages.isEmpty
  }

  private static func hasDeclaredExternalWait(_ node: PlaybackSearchNode) -> Bool {
    if node.ghost.externalWait != nil || node.coreState.externalWaitReason != nil { return true }
    if !node.coreState.outstandingEffects.isEmpty { return true }
    guard let session = node.coreState.activeSession else { return false }
    if session.phase == .buffering { return true }
    if session.phase == .draining,
      !session.drain.observed.isSuperset(of: session.drain.required)
    {
      return true
    }
    if session.phase == .prerolling,
      !session.synchronization.startupAcknowledged
    {
      return true
    }
    return false
  }

  private static func obligationRank(_ node: PlaybackSearchNode) -> Int {
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
