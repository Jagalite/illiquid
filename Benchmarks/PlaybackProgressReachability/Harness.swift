import Foundation
import IlliquidPlaybackCore
@testable import IlliquidPlaybackStateSpace

// Both variants link separately optimized production modules. Graph construction,
// metadata, full-report serialization and warm-up stay outside analyzer timings.
private let workloadNames = [
    "real-seek", "real-eof-drain", "real-stop-shutdown",
    "synthetic-chain-forward", "synthetic-chain-reverse", "synthetic-sparse",
    "synthetic-dense", "synthetic-all-settled", "synthetic-no-settled",
    "synthetic-no-fair", "synthetic-partial-settled", "end-to-end-stop-shutdown",
]

private struct Failure: Error, CustomStringConvertible {
    let description: String
}

private func configuration(depth: Int) -> PlaybackSearchConfiguration {
    .init(profile: "progress-benchmark", depthLimit: depth, generationLimit: 1,
          pendingEffectLimit: 3, lateResultLimit: 1, failureLimit: 1,
          duplicateLimit: 1, interruptLimit: 1, stateLimit: 2_000,
          edgeLimit: 20_000, porMode: .disabled, timeLimitSeconds: nil)
}

private func explore(_ model: PlaybackSearchModel, seed: String, depth: Int)
    throws -> PlaybackSearchResult {
    let result = try PlaybackStateSpaceExplorer().run(
        model: model, seedProfile: seed, configuration: configuration(depth: depth))
    guard result.failures.isEmpty, result.summary.termination != .timeBudgetReached else {
        throw Failure(description: "Explorer fixture failed or hit a wall-clock cutoff: \(model.rawValue)")
    }
    return result
}

private func node(_ lifecycle: PlaybackLifecyclePhase = .shuttingDown,
                  externalWait: Bool = false, cutoff: Bool = false) -> PlaybackSearchNode {
    .init(model: .stopShutdown, coreState: PlaybackCoreState(lifecycle: lifecycle),
          environment: .stopShutdown(StopShutdownSearchEnvironment()),
          ghost: .init(externalWait: externalWait ? .effectResult : nil),
          depth: cutoff ? 32 : 0)
}

private func synthetic(_ name: String, nodes: [PlaybackSearchNode],
                       edges: [PlaybackSearchGraph.Edge]) -> PlaybackSearchResult {
    let summary = PlaybackSearchSummary(
        model: .stopShutdown,
        modelVersion: PlaybackSearchModelDefinition(model: .stopShutdown).modelVersion,
        seedProfile: name,
        configuration: .validation(depthLimit: 32).withTimeLimitSeconds(nil),
        termination: .completeWithinBounds, stateCount: nodes.count, edgeCount: edges.count,
        productionTransitionCount: 0, gateRejectionCount: 0, peakFrontier: 0,
        deepestCompletedLayer: 0, reducedEdgeCount: 0, validatedDiamondCount: 0,
        nonCommutingDiamondCount: 0, canonicalDigest: "synthetic:\(name)")
    return .init(summary: summary, oracle: .production, failures: [],
                 graph: .init(edges: edges), nodes: nodes,
                 predecessors: Array(repeating: nil, count: nodes.count))
}

private func edge(_ from: Int, _ to: Int, fair: Bool = true) -> PlaybackSearchGraph.Edge {
    .init(from: from, to: to, actionClass: fair ? "synthetic-fair" : "synthetic-unfair",
          isFairProgress: fair)
}

private func fixture(_ name: String) throws -> PlaybackSearchResult {
    switch name {
    case "real-seek":
        return try explore(.seek, seed: "ready-playing", depth: 4)
    case "real-eof-drain":
        return try explore(.eofDrain, seed: "playing-av", depth: 4)
    case "real-stop-shutdown", "end-to-end-stop-shutdown":
        return try explore(.stopShutdown, seed: "opening", depth: 5)
    case "synthetic-chain-forward", "synthetic-chain-reverse":
        let nodes = (0..<512).map { _ in node() } + [node(.terminated)]
        var edges = (0..<512).map { edge($0, $0 + 1) }
        if name.hasSuffix("-reverse") { edges.reverse() }
        return synthetic(name, nodes: nodes, edges: edges)
    case "synthetic-sparse":
        let nodes = (0..<2_047).map { _ in node() } + [node(.terminated)]
        return synthetic(name, nodes: nodes, edges: (0..<2_047).map { edge($0, 2_047) })
    case "synthetic-dense":
        let nodes = (0..<256).map { _ in node() } + [node(.terminated)]
        var edges: [PlaybackSearchGraph.Edge] = []
        for from in 0..<256 {
            for offset in 1...16 { edges.append(edge(from, (from + offset) % 256)) }
        }
        edges.append(edge(255, 256))
        return synthetic(name, nodes: nodes, edges: edges)
    case "synthetic-all-settled":
        return synthetic(name, nodes: (0..<2_048).map { _ in node(.terminated) },
                         edges: (0..<2_048).map { edge($0, $0) })
    case "synthetic-no-settled":
        return synthetic(name, nodes: (0..<2_048).map { _ in node() },
                         edges: (0..<2_048).map { edge($0, $0) })
    case "synthetic-partial-settled":
        // One transaction reaches a terminal immediately; the remaining
        // transactions stay in disconnected closed SCCs. The initial scan is
        // already a fixed point despite having unresolved transactions.
        let nodes = (0..<2_047).map { _ in node() } + [node(.terminated)]
        let edges = [edge(0, 2_047)] + (1..<2_047).map { edge($0, $0) }
        return synthetic(name, nodes: nodes, edges: edges)
    case "synthetic-no-fair":
        let nodes = (0..<2_047).map { _ in node() } + [node(.terminated)]
        return synthetic(name, nodes: nodes,
                         edges: (0..<2_047).map { edge($0, 2_047, fair: false) })
    default:
        throw Failure(description: "Unknown workload: \(name)")
    }
}

// Swift Set iteration is intentionally unordered. Normalize only that
// representation; retain every report field and every stuck/SCC member.
private func reportJSON(_ report: PlaybackProgressReport) -> [String: Any] {
    [
        "terminal_states": report.terminalStates,
        "stable_intentional_wait_states": report.stableIntentionalWaitStates,
        "external_wait_states": report.externalWaitStates,
        "unmeasured_cutoff_states": report.unmeasuredCutoffStates,
        "transaction_states": report.transactionStates,
        "settled_transaction_states": report.settledTransactionStates,
        "stuck_states": report.stuckStates,
        "closed_nonterminal_sccs": report.closedNonterminalSCCs.map { $0.sorted() }
            .sorted { $0.lexicographicallyPrecedes($1) },
        "maximum_obligation_rank": report.maximumObligationRank,
    ]
}

private struct Fingerprint {
    var value: UInt64 = 14_695_981_039_346_656_037

    mutating func add(_ value: Int) {
        add(String(value))
    }

    mutating func add(_ text: String) {
        for byte in text.utf8 { value = (value ^ UInt64(byte)) &* 1_099_511_628_211 }
        value = (value ^ 255) &* 1_099_511_628_211
    }
}

private func metadata(_ result: PlaybackSearchResult) throws -> [String: Any] {
    var fingerprint = Fingerprint()
    for node in result.nodes {
        fingerprint.add(PlaybackSearchCanonicalizer.digest(PlaybackSearchCanonicalizer.key(for: node)))
        fingerprint.add(node.depth)
    }
    for edge in result.graph.edges {
        fingerprint.add(edge.from)
        fingerprint.add(edge.to)
        fingerprint.add(edge.isFairProgress ? 1 : 0)
        fingerprint.add(edge.actionClass)
    }
    return [
        "nodes": result.nodes.count,
        "edges": result.graph.edges.count,
        "fair_edges": result.graph.edges.filter(\.isFairProgress).count,
        "ordered_graph_fingerprint": String(fingerprint.value),
        "summary": try JSONSerialization.jsonObject(with: JSONEncoder().encode(result.summary)),
        "failure_count": result.failures.count,
    ]
}

private struct Generator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state >> 32
    }
}

private func randomFixture(seed: UInt64, reversed: Bool) -> PlaybackSearchResult {
    var generator = Generator(state: seed)
    let count = 1 + Int(seed % 23)
    let nodes = (0..<count).map { _ -> PlaybackSearchNode in
        switch generator.next() % 6 {
        case 0: node(.terminated)
        case 1: node(.running)
        case 2: node(externalWait: true)
        case 3: node(cutoff: true)
        case 4: node(.invariantFailed)
        default: node()
        }
    }
    var edges: [PlaybackSearchGraph.Edge] = []
    for index in 0..<(count * 3) {
        let next = edge(Int(generator.next() % UInt64(count)),
                        Int(generator.next() % UInt64(count)),
                        fair: generator.next() % 4 != 0)
        edges.append(next)
        if index % 5 == 0 { edges.append(next) }
    }
    if reversed { edges.reverse() }
    return synthetic("random-\(seed)-\(reversed ? "reversed" : "original")",
                     nodes: nodes, edges: edges)
}

private func verify() throws -> [String: Any] {
    var cases: [[String: Any]] = []
    func record(_ name: String, _ result: PlaybackSearchResult) throws {
        cases.append(["name": name, "graph_metadata": try metadata(result),
                      "report": reportJSON(PlaybackProgressAnalyzer.analyze(result))])
    }
    for name in workloadNames {
        try record(name, fixture(name))
    }
    // Exercise every model's real reachable states at an independently small,
    // deterministic bound, in addition to the timed representative graphs.
    for model in PlaybackSearchModel.allCases {
        let seed = PlaybackSearchModelDefinition(model: model).inventory.seedProfiles[0]
        try record("validation-\(model.rawValue)",
                   explore(model, seed: seed, depth: 3))
    }
    try record("empty", synthetic("empty", nodes: [], edges: []))
    try record("single-terminal", synthetic("single-terminal", nodes: [node(.terminated)], edges: []))
    try record("single-stuck", synthetic("single-stuck", nodes: [node()], edges: []))
    for seed in UInt64(1)...64 {
        try record("random-\(seed)-original", randomFixture(seed: seed, reversed: false))
        try record("random-\(seed)-reversed", randomFixture(seed: seed, reversed: true))
    }
    return ["schema_version": 1, "mode": "verify", "cases": cases,
            "case_count": cases.count,
            "normalization": "Sort SCC members and SCC arrays; preserve every report field."]
}

private struct BatchResult {
    var checksum: UInt64 = 0
    var producedCount = 0

    mutating func consume(_ report: PlaybackProgressReport) {
        // Full reports are compared before timing. This bounded sink prevents
        // dead-result elimination without traversing SCCs in the timed region.
        checksum = checksum &* 1_099_511_628_211 &+ UInt64(report.terminalStates)
        checksum &+= UInt64(report.stableIntentionalWaitStates) &* 3
        checksum &+= UInt64(report.externalWaitStates) &* 5
        checksum &+= UInt64(report.unmeasuredCutoffStates) &* 7
        checksum &+= UInt64(report.transactionStates) &* 11
        checksum &+= UInt64(report.settledTransactionStates) &* 13
        checksum &+= UInt64(report.stuckStates.count) &* 17
        checksum &+= UInt64(report.closedNonterminalSCCs.count) &* 19
        checksum &+= UInt64(report.maximumObligationRank) &* 23
        producedCount += 1
    }
}

@inline(never)
private func analyzeBatch(_ result: PlaybackSearchResult, iterations: Int) -> BatchResult {
    var batch = BatchResult()
    for _ in 0..<iterations {
        batch.consume(PlaybackProgressAnalyzer.analyze(result))
    }
    return batch
}

@inline(never)
private func endToEndBatch(iterations: Int) throws -> BatchResult {
    var batch = BatchResult()
    for _ in 0..<iterations {
        let result = try explore(.stopShutdown, seed: "opening", depth: 5)
        batch.consume(PlaybackProgressAnalyzer.analyze(result))
        batch.checksum &+= UInt64(result.nodes.count) &* 29
        batch.checksum &+= UInt64(result.graph.edges.count) &* 31
    }
    return batch
}

@main
private struct ProgressReachabilityHarness {
    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments == ["list"] {
            try emit(["schema_version": 1, "workloads": workloadNames])
            return
        }
        if arguments == ["verify"] {
            try emit(verify())
            return
        }
        guard arguments.count == 3, arguments[0] == "benchmark",
              workloadNames.contains(arguments[1]), let iterations = Int(arguments[2]),
              iterations > 0, iterations <= 1_000_000 else {
            throw Failure(description: "Expected list, verify, or benchmark <workload> <iterations>")
        }
        let name = arguments[1]
        let graph = try fixture(name)
        let graphMetadata = try metadata(graph)
        let warmupIterations = 1
        let isEndToEnd = name.hasPrefix("end-to-end-")
        let warmup: BatchResult
        if isEndToEnd {
            warmup = try endToEndBatch(iterations: warmupIterations)
        } else {
            warmup = analyzeBatch(graph, iterations: warmupIterations)
        }
        let start = DispatchTime.now().uptimeNanoseconds
        let result: BatchResult
        if isEndToEnd {
            result = try endToEndBatch(iterations: iterations)
        } else {
            result = analyzeBatch(graph, iterations: iterations)
        }
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        precondition(result.producedCount == iterations)
        try emit([
            "schema_version": 1, "mode": "benchmark", "workload": name,
            "iterations": iterations, "operations": iterations, "elapsed_ns": elapsed,
            "checksum": String(result.checksum), "produced_count": result.producedCount,
            "warmup_iterations": warmupIterations, "warmup_checksum": String(warmup.checksum),
            "warmup_produced_count": warmup.producedCount, "graph_metadata": graphMetadata,
            "timing_scope": isEndToEnd ? "explore-and-analyze" : "analyze-prepared-graph",
        ])
    }

    private static func emit(_ value: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}
