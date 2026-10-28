import Foundation
@testable import IlliquidPlaybackStateSpace
#if os(Linux)
import Glibc
#else
import Darwin
#endif

@main
struct ProgressAnalysisBenchmark {
  static func cpuNanoseconds() -> UInt64 {
    var value = timespec()
    precondition(clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &value) == 0)
    return UInt64(value.tv_sec) * 1_000_000_000 + UInt64(value.tv_nsec)
  }

  static func emit(_ value: [String: Any]) throws {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))
  }

  static func reportValue(_ value: PlaybackProgressReport) -> [String: Any] {
    [
      "terminal": value.terminalStates,
      "stable": value.stableIntentionalWaitStates,
      "external_wait": value.externalWaitStates,
      "cutoff": value.unmeasuredCutoffStates,
      "transactions": value.transactionStates,
      "settled_transactions": value.settledTransactionStates,
      "stuck": value.stuckStates,
      "closed_components": value.closedNonterminalSCCs.map { $0.sorted() },
      "maximum_rank": value.maximumObligationRank,
    ]
  }

  static func fingerprint(_ value: Any) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in data {
      hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211
    }
    return String(hash, radix: 16)
  }

  // Construction, oracle comparison, warmup, and final equality are outside
  // the timed region. Each iteration consumes its result; the previous
  // iteration's result is released when replaced.
  static func measure<Value: Equatable>(
    iterations: Int, expected: Value, operation: () -> Value, consume: (Value) -> UInt64
  ) -> (wall: UInt64, cpu: UInt64, checksum: UInt64) {
    var result = operation()
    precondition(result == expected)
    var checksum: UInt64 = 0
    let cpuStart = cpuNanoseconds()
    let start = DispatchTime.now().uptimeNanoseconds
    for _ in 0..<iterations {
      result = operation()
      checksum &+= consume(result)
    }
    let wall = DispatchTime.now().uptimeNanoseconds - start
    let cpu = cpuNanoseconds() - cpuStart
    precondition(result == expected, "Complete result differs from pinned analyzer")
    return (wall, cpu, checksum)
  }

  static func benchmark<Value: Equatable>(
    caseID: String, pairs: Int, targetMilliseconds: Double, expected: Value,
    fingerprint: String, baseline: () -> Value, candidate: () -> Value,
    consume: (Value) -> UInt64
  ) throws {
    precondition(baseline() == expected && candidate() == expected)
    let a = measure(iterations: 1, expected: expected, operation: baseline, consume: consume)
    let b = measure(iterations: 1, expected: expected, operation: candidate, consume: consume)
    let iterations = max(1, min(100_000,
      Int(ceil(targetMilliseconds * 1_000_000 / Double(max(1, max(a.wall, b.wall)))))))
    try emit([
      "kind": "calibration", "case": caseID, "iterations": iterations,
      "baseline_ns": a.wall, "candidate_ns": b.wall,
    ])
    for pair in 0..<pairs {
      let order = pair % 2 == 0 ? ["baseline", "candidate"] : ["candidate", "baseline"]
      for (sequence, variant) in order.enumerated() {
        let measured: (wall: UInt64, cpu: UInt64, checksum: UInt64)
        if variant == "baseline" {
          measured = measure(iterations: iterations, expected: expected,
                             operation: baseline, consume: consume)
        } else {
          measured = measure(iterations: iterations, expected: expected,
                             operation: candidate, consume: consume)
        }
        try emit([
          "kind": "measurement", "case": caseID, "pair": pair, "sequence": sequence,
          "variant": variant, "iterations": iterations,
          "elapsed_ns": measured.wall, "cpu_ns": measured.cpu,
          "checksum": measured.checksum, "fingerprint": fingerprint,
          "oracle_equal": true,
        ])
      }
    }
  }

  static func syntheticEdges(kind: String, count: Int) -> [PlaybackSearchGraph.Edge] {
    func edge(_ from: Int, _ to: Int) -> PlaybackSearchGraph.Edge {
      .init(from: from, to: to, actionClass: "synthetic", isFairProgress: from % 2 == 0)
    }
    switch kind {
    case "empty", "isolated":
      return []
    case "cycles":
      // Small disconnected SCCs avoid attributing a recursion-limit change.
      return (0..<count).flatMap { index in
        [edge(index, (index / 8) * 8 + (index + 1) % 8), edge(index, index)]
      }
    case "dense":
      return (0..<count).flatMap { from in (0..<count).map { edge(from, $0) } }
    default:
      fatalError("unknown synthetic graph")
    }
  }

  static func main() throws {
    let arguments = CommandLine.arguments
    precondition(arguments.count == 4, "usage: ProgressAnalysisBenchmark case pairs target-ms")
    let caseID = arguments[1]
    let fields = caseID.split(separator: "/").map(String.init)
    precondition(fields.count == 3)
    let pairs = Int(arguments[2])!
    let targetMilliseconds = Double(arguments[3])!
    precondition(pairs >= 2 && pairs % 2 == 0 && targetMilliseconds > 0)
    let amount = Int(fields[2])!
    let result: PlaybackSearchResult?
    let edges: [PlaybackSearchGraph.Edge]
    let nodeCount: Int
    var fixture: [String: Any] = ["kind": "fixture", "case": caseID]
    if let model = PlaybackSearchModel(rawValue: fields[1]) {
      let seed = PlaybackSearchModelDefinition(model: model).inventory.seedProfiles[0]
      let explored = try PlaybackStateSpaceExplorer().run(
        model: model, seedProfile: seed,
        configuration: .validation(depthLimit: amount).withTimeLimitSeconds(nil)
      )
      precondition(explored.failures.isEmpty, "Production explorer reported invariant failures")
      result = explored
      edges = explored.graph.edges
      nodeCount = explored.nodes.count
      let expected = ReferencePlaybackProgressAnalyzer.analyze(explored)
      precondition(PlaybackProgressAnalyzer.analyze(explored) == expected)
      fixture["source"] = "production-explorer"
      fixture["seed"] = seed
      fixture["depth"] = amount
      fixture["model_version"] = explored.summary.modelVersion
      fixture["termination"] = explored.summary.termination.rawValue
      fixture["canonical_digest"] = explored.summary.canonicalDigest
      fixture["progress"] = reportValue(expected)
    } else {
      precondition(fields[0] == "scc")
      result = nil
      nodeCount = amount
      edges = syntheticEdges(kind: fields[1], count: amount)
      fixture["source"] = "synthetic-control"
    }
    fixture["states"] = nodeCount
    fixture["edges"] = edges.count
    try emit(fixture)

    if fields[0] == "analyze" {
      let input = result!
      let expected = ReferencePlaybackProgressAnalyzer.analyze(input)
      try benchmark(
        caseID: caseID, pairs: pairs, targetMilliseconds: targetMilliseconds,
        expected: expected, fingerprint: fingerprint(reportValue(expected)),
        baseline: { ReferencePlaybackProgressAnalyzer.analyze(input) },
        candidate: { PlaybackProgressAnalyzer.analyze(input) },
        consume: { UInt64($0.terminalStates + $0.externalWaitStates + $0.stuckStates.count
          + $0.closedNonterminalSCCs.count + $0.settledTransactionStates) }
      )
    } else {
      precondition(fields[0] == "scc")
      let expected = ReferencePlaybackProgressAnalyzer.stronglyConnectedComponents(
        nodeCount: nodeCount, edges: edges
      )
      try benchmark(
        caseID: caseID, pairs: pairs, targetMilliseconds: targetMilliseconds,
        expected: expected, fingerprint: fingerprint(expected.map { $0.sorted() }),
        baseline: {
          ReferencePlaybackProgressAnalyzer.stronglyConnectedComponents(nodeCount: nodeCount, edges: edges)
        },
        candidate: {
          PlaybackProgressAnalyzer.stronglyConnectedComponents(nodeCount: nodeCount, edges: edges)
        },
        consume: { UInt64($0.count + ($0.first?.count ?? 0) + ($0.last?.count ?? 0)) }
      )
    }
  }
}
