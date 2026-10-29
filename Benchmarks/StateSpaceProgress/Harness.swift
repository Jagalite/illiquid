import Dispatch
import Foundation
import IlliquidPlaybackCore
@testable import IlliquidPlaybackStateSpace

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

private struct HarnessError: Error, CustomStringConvertible {
  let description: String
  init(_ value: String) { description = value }
}

private struct Workload: Encodable, Sendable {
  let id: String
  let kind: String
  let model: PlaybackSearchModel?
  let seed: String?
}

private struct Fixture {
  let workload: Workload
  let result: PlaybackSearchResult
  let expected: ReportReceipt?
}

private struct ReportReceipt: Codable, Equatable {
  let terminalStates: Int
  let stableIntentionalWaitStates: Int
  let externalWaitStates: Int
  let unmeasuredCutoffStates: Int
  let transactionStates: Int
  let settledTransactionStates: Int
  let stuckStates: [Int]
  let closedNonterminalSCCs: [[Int]]
  let maximumObligationRank: Int

  init(_ report: PlaybackProgressReport) {
    terminalStates = report.terminalStates
    stableIntentionalWaitStates = report.stableIntentionalWaitStates
    externalWaitStates = report.externalWaitStates
    unmeasuredCutoffStates = report.unmeasuredCutoffStates
    transactionStates = report.transactionStates
    settledTransactionStates = report.settledTransactionStates
    stuckStates = report.stuckStates
    // Preserve Tarjan component order, normalize only each Set's member order.
    closedNonterminalSCCs = report.closedNonterminalSCCs.map { $0.sorted() }
    maximumObligationRank = report.maximumObligationRank
  }

  init(
    terminal: Int, transactions: Int, settled: Int,
    stuck: [Int] = [], closed: [[Int]] = [], stable: Int = 0, rank: Int = 1
  ) {
    terminalStates = terminal
    stableIntentionalWaitStates = stable
    externalWaitStates = 0
    unmeasuredCutoffStates = 0
    transactionStates = transactions
    settledTransactionStates = settled
    stuckStates = stuck
    closedNonterminalSCCs = closed
    maximumObligationRank = rank
  }
}

private struct NodeReceipt: Encodable {
  let canonicalKey: PlaybackSearchStateKey
  let depth: Int
  let nextSequence: UInt64
}

private struct VerificationReceipt: Encodable {
  let schemaVersion: Int
  let workload: Workload
  let summary: PlaybackSearchSummary
  let oracle: PlaybackSearchOracle
  let failures: [PlaybackSearchFailure]
  let graph: PlaybackSearchGraph
  let nodes: [NodeReceipt]
  let predecessors: [PlaybackSearchPredecessor?]
  let report: ReportReceipt
  let independentExpectedReport: ReportReceipt?
}

private struct Consumption: Codable, Equatable {
  var analyses: UInt64 = 0
  var states: UInt64 = 0
  var edges: UInt64 = 0
  var terminalStates: UInt64 = 0
  var intentionalWaitStates: UInt64 = 0
  var externalWaitStates: UInt64 = 0
  var cutoffStates: UInt64 = 0
  var transactionStates: UInt64 = 0
  var settledTransactionStates: UInt64 = 0
  var stuckStates: UInt64 = 0
  var closedComponents: UInt64 = 0
  var obligationRank: UInt64 = 0
  var reportChecksum: UInt64 = 0

  mutating func consume(
    _ report: PlaybackProgressReport, states nodeCount: Int, edges edgeCount: Int
  ) {
    analyses &+= 1
    states &+= UInt64(nodeCount)
    edges &+= UInt64(edgeCount)
    terminalStates &+= UInt64(report.terminalStates)
    intentionalWaitStates &+= UInt64(report.stableIntentionalWaitStates)
    externalWaitStates &+= UInt64(report.externalWaitStates)
    cutoffStates &+= UInt64(report.unmeasuredCutoffStates)
    transactionStates &+= UInt64(report.transactionStates)
    settledTransactionStates &+= UInt64(report.settledTransactionStates)
    stuckStates &+= UInt64(report.stuckStates.count)
    closedComponents &+= UInt64(report.closedNonterminalSCCs.count)
    obligationRank &+= UInt64(report.maximumObligationRank)
    // Consume IDs without adding a sort to the timed path. Full report parity
    // is checked separately; this checksum is only an optimization barrier.
    var checksum: UInt64 = 0
    for index in report.stuckStates {
      checksum &+= UInt64(index + 1) &* 1_099_511_628_211
    }
    for component in report.closedNonterminalSCCs {
      var members: UInt64 = UInt64(component.count) &* 0x9e3779b97f4a7c15
      for index in component {
        members &+= UInt64(index + 1) &* 1_099_511_628_211
      }
      checksum &+= members
    }
    reportChecksum &+= checksum
  }

  func repeated(_ count: Int) -> Consumption {
    let n = UInt64(count)
    return Consumption(
      analyses: analyses &* n, states: states &* n, edges: edges &* n,
      terminalStates: terminalStates &* n,
      intentionalWaitStates: intentionalWaitStates &* n,
      externalWaitStates: externalWaitStates &* n,
      cutoffStates: cutoffStates &* n,
      transactionStates: transactionStates &* n,
      settledTransactionStates: settledTransactionStates &* n,
      stuckStates: stuckStates &* n,
      closedComponents: closedComponents &* n,
      obligationRank: obligationRank &* n,
      reportChecksum: reportChecksum &* n
    )
  }
}

private struct TimingReceipt: Encodable {
  let schemaVersion: Int
  let workload: String
  let kind: String
  let iterations: Int
  let analysesPerIteration: Int
  let warmupIterations: Int
  let elapsedNanoseconds: UInt64
  let searchSummary: PlaybackSearchSummary
  let report: ReportReceipt
  let warmup: Consumption
  let measured: Consumption
}

@main
private enum Harness {
  private static let workloads: [Workload] = [
    .init(id: "native-seek", kind: "production-search-graph",
          model: .seek, seed: "ready-playing"),
    .init(id: "native-eof-drain", kind: "production-search-graph",
          model: .eofDrain, seed: "draining-av"),
    .init(id: "native-recovery", kind: "production-search-graph",
          model: .recovery, seed: "recovery-in-flight"),
    .init(id: "native-track-subtitles", kind: "production-search-graph",
          model: .trackSubtitles, seed: "embedded-selected"),
    .init(id: "native-stop-shutdown", kind: "production-search-graph",
          model: .stopShutdown, seed: "opening"),
    .init(id: "native-preroll-buffering", kind: "production-search-graph",
          model: .prerollBuffering, seed: "partial-av"),
    .init(id: "synthetic-chain-256", kind: "synthetic-scaling-graph",
          model: nil, seed: nil),
    .init(id: "synthetic-chain-1024", kind: "synthetic-scaling-graph",
          model: nil, seed: nil),
    .init(id: "synthetic-chain-4096", kind: "synthetic-scaling-graph",
          model: nil, seed: nil),
    .init(id: "synthetic-layered-64x32", kind: "synthetic-scaling-graph",
          model: nil, seed: nil),
    .init(id: "synthetic-unfair-control", kind: "synthetic-control-graph",
          model: nil, seed: nil),
    .init(id: "synthetic-all-settled", kind: "synthetic-control-graph",
          model: nil, seed: nil),
    .init(id: "synthetic-no-settled", kind: "synthetic-control-graph",
          model: nil, seed: nil),
  ]

  static func main() {
    do {
      try execute(Array(CommandLine.arguments.dropFirst()))
    } catch {
      FileHandle.standardError.write(Data("progress benchmark: \(error)\n".utf8))
      exit(1)
    }
  }

  private static func execute(_ arguments: [String]) throws {
    guard let mode = arguments.first else {
      throw HarnessError(
        "usage: harness list | verify WORKLOAD | benchmark WORKLOAD ITERATIONS"
      )
    }
    switch mode {
    case "list":
      guard arguments.count == 1 else {
        throw HarnessError("list takes no arguments")
      }
      struct ListReceipt: Encodable {
        let schemaVersion: Int
        let workloads: [Workload]
        let timingBoundary: String
      }
      try emit(
        ListReceipt(
          schemaVersion: 1, workloads: workloads,
          timingBoundary: "Full progress analyze only; graph construction, "
            + "search, canonicalization, parity, and JSON are outside timing."
        )
      )

    case "verify":
      guard arguments.count == 2 else {
        throw HarnessError("verify requires WORKLOAD")
      }
      let fixture = try makeFixture(arguments[1])
      let result = fixture.result
      let report = PlaybackProgressAnalyzer.analyze(result)
      try validate(report, fixture: fixture)
      try emit(
        VerificationReceipt(
          schemaVersion: 1, workload: fixture.workload,
          summary: result.summary, oracle: result.oracle,
          failures: result.failures, graph: result.graph,
          nodes: result.nodes.map {
            NodeReceipt(
              canonicalKey: PlaybackSearchCanonicalizer.key(for: $0),
              depth: $0.depth, nextSequence: $0.nextSequence
            )
          },
          predecessors: result.predecessors,
          report: ReportReceipt(report),
          independentExpectedReport: fixture.expected
        )
      )

    case "benchmark":
      guard arguments.count == 3,
        let iterations = Int(arguments[2]),
        iterations > 0, iterations <= 1_000_000
      else {
        throw HarnessError("benchmark requires WORKLOAD and positive ITERATIONS")
      }
      guard workloads.contains(where: { $0.id == arguments[1] }) else {
        throw HarnessError("unknown timing workload: \(arguments[1])")
      }
      // Construct production or synthetic graphs once, outside the timed work.
      let fixture = try makeFixture(arguments[1])
      let result = fixture.result
      let warmupReport = PlaybackProgressAnalyzer.analyze(result)
      try validate(warmupReport, fixture: fixture)
      var warmup = Consumption()
      warmup.consume(
        warmupReport, states: result.nodes.count, edges: result.graph.edges.count
      )

      let started = DispatchTime.now().uptimeNanoseconds
      let measured = runBatch(result, iterations: iterations)
      let elapsed = DispatchTime.now().uptimeNanoseconds - started

      guard elapsed > 0, measured == warmup.repeated(iterations) else {
        throw HarnessError("invalid timing or changed analysis consumption")
      }
      let finalReport = PlaybackProgressAnalyzer.analyze(result)
      try validate(finalReport, fixture: fixture)
      guard finalReport == warmupReport else {
        throw HarnessError("full analysis report changed across timed calls")
      }
      try emit(
        TimingReceipt(
          schemaVersion: 1, workload: fixture.workload.id,
          kind: fixture.workload.kind, iterations: iterations,
          analysesPerIteration: 1, warmupIterations: 1,
          elapsedNanoseconds: elapsed, searchSummary: result.summary,
          report: ReportReceipt(finalReport), warmup: warmup, measured: measured
        )
      )

    default:
      throw HarnessError("unknown mode: \(mode)")
    }
  }

  @inline(never)
  private static func runBatch(
    _ result: PlaybackSearchResult, iterations: Int
  ) -> Consumption {
    var consumed = Consumption()
    for _ in 0..<iterations {
      let report = PlaybackProgressAnalyzer.analyze(result)
      consumed.consume(
        report, states: result.nodes.count, edges: result.graph.edges.count
      )
    }
    return consumed
  }

  private static func makeFixture(_ id: String) throws -> Fixture {
    if id == "synthetic-failure" {
      let workload = Workload(
        id: id, kind: "production-search-synthetic-oracle",
        model: .seek, seed: "ready-playing"
      )
      let result = try PlaybackStateSpaceExplorer().run(
        model: .seek, seedProfile: "ready-playing",
        configuration: .validation(depthLimit: 2).withTimeLimitSeconds(nil),
        oracle: .failOnActionClass(
          "command.seekExact", invariantName: "syntheticSeekFailure"
        )
      )
      guard result.summary.termination == .completeWithinBounds,
        result.failures.contains(where: {
          $0.invariantName == "syntheticSeekFailure"
        })
      else { throw HarnessError("synthetic oracle did not complete and fail") }
      return Fixture(workload: workload, result: result, expected: nil)
    }
    guard let workload = workloads.first(where: { $0.id == id }) else {
      throw HarnessError("unknown workload: \(id)")
    }
    if let model = workload.model, let seed = workload.seed {
      let result = try PlaybackStateSpaceExplorer().run(
        model: model, seedProfile: seed,
        configuration: .validation(depthLimit: 4, porMode: .disabled)
          .withTimeLimitSeconds(nil)
      )
      guard result.summary.termination == .completeWithinBounds,
        result.failures.isEmpty
      else {
        throw HarnessError(
          "\(id) search did not complete without invariant failures: "
            + result.summary.termination.rawValue
        )
      }
      return Fixture(workload: workload, result: result, expected: nil)
    }
    return try syntheticFixture(workload)
  }

  private static func syntheticFixture(_ workload: Workload) throws -> Fixture {
    let depths: [Int]
    let terminalIndices: Set<Int>
    var edges: [PlaybackSearchGraph.Edge] = []
    let expected: ReportReceipt

    switch workload.id {
    case "synthetic-chain-256", "synthetic-chain-1024", "synthetic-chain-4096":
      guard let length = Int(workload.id.split(separator: "-").last ?? "") else {
        throw HarnessError("invalid synthetic chain length")
      }
      // Forward insertion is natural discovery order and forces the old global
      // fixed-point scan to advance only one predecessor per pass.
      depths = Array(0...length)
      terminalIndices = [length]
      for index in 0..<length {
        edges.append(.init(
          from: index, to: index + 1,
          actionClass: "synthetic.fair", isFairProgress: true
        ))
      }
      expected = ReportReceipt(
        terminal: 1, transactions: length, settled: length
      )

    case "synthetic-layered-64x32":
      let width = 64
      let layers = 32
      let sink = width * layers
      depths = (0..<sink).map { $0 / width } + [layers]
      terminalIndices = [sink]
      for layer in 0..<layers {
        for column in 0..<width {
          let from = layer * width + column
          if layer == layers - 1 {
            edges.append(.init(
              from: from, to: sink,
              actionClass: "synthetic.fair", isFairProgress: true
            ))
          } else {
            for nextColumn in [column, (column + 1) % width] {
              edges.append(.init(
                from: from, to: (layer + 1) * width + nextColumn,
                actionClass: "synthetic.fair", isFairProgress: true
              ))
            }
          }
        }
      }
      expected = ReportReceipt(
        terminal: 1, transactions: sink, settled: sink
      )

    case "synthetic-unfair-control":
      // A chain has an unfair break at 64 -> 65. A disconnected fair cycle
      // (129,130) cannot reach the terminal. Neither is allowed to settle.
      depths = Array(0...128) + [0, 0]
      terminalIndices = [128]
      for index in 0..<128 {
        edges.append(.init(
          from: index, to: index + 1,
          actionClass: index == 64 ? "synthetic.unfair" : "synthetic.fair",
          isFairProgress: index != 64
        ))
      }
      edges.append(.init(
        from: 129, to: 130,
        actionClass: "synthetic.fair-cycle", isFairProgress: true
      ))
      edges.append(.init(
        from: 130, to: 129,
        actionClass: "synthetic.fair-cycle", isFairProgress: true
      ))
      expected = ReportReceipt(
        terminal: 1, transactions: 129, settled: 63,
        stuck: [64], closed: [[129, 130]]
      )

    case "synthetic-all-settled":
      depths = Array(repeating: 0, count: 256)
      terminalIndices = []
      for index in 0..<255 {
        edges.append(.init(
          from: index, to: index + 1,
          actionClass: "synthetic.fair", isFairProgress: true
        ))
      }
      expected = ReportReceipt(
        terminal: 0, transactions: 0, settled: 0, stable: 256, rank: 0
      )

    case "synthetic-no-settled":
      depths = Array(repeating: 0, count: 256)
      terminalIndices = []
      for index in 0..<256 {
        edges.append(.init(
          from: index, to: (index + 1) % 256,
          actionClass: "synthetic.fair-cycle", isFairProgress: true
        ))
      }
      expected = ReportReceipt(
        terminal: 0, transactions: 256, settled: 0,
        closed: [Array(0..<256)]
      )

    default:
      throw HarnessError("unknown synthetic graph: \(workload.id)")
    }

    let nodes = depths.enumerated().map { index, depth in
      PlaybackSearchNode(
        model: .stopShutdown, seedProfile: workload.id,
        coreState: PlaybackCoreState(
          lifecycle: workload.id == "synthetic-all-settled"
            ? .running : (terminalIndices.contains(index) ? .terminated : .shuttingDown)
        ),
        environment: .stopShutdown(StopShutdownSearchEnvironment()),
        depth: depth
      )
    }
    let maximumDepth = depths.max() ?? 0
    let configuration = PlaybackSearchConfiguration.validation(
      depthLimit: maximumDepth + 1, porMode: .disabled
    ).withTimeLimitSeconds(nil)
    // This is an explicit analyzer fixture, not a claimed reachable search.
    let summary = PlaybackSearchSummary(
      model: .stopShutdown,
      modelVersion: PlaybackSearchModelDefinition(model: .stopShutdown).modelVersion,
      seedProfile: workload.id, configuration: configuration,
      termination: .completeWithinBounds,
      stateCount: nodes.count, edgeCount: edges.count,
      productionTransitionCount: 0, gateRejectionCount: 0,
      peakFrontier: 0, deepestCompletedLayer: 0,
      reducedEdgeCount: 0, validatedDiamondCount: 0,
      nonCommutingDiamondCount: 0,
      canonicalDigest: "synthetic-fixture:" + workload.id
    )
    let result = PlaybackSearchResult(
      summary: summary, oracle: .production, failures: [],
      graph: PlaybackSearchGraph(edges: edges), nodes: nodes,
      predecessors: Array(repeating: nil, count: nodes.count)
    )
    return Fixture(workload: workload, result: result, expected: expected)
  }

  private static func validate(
    _ report: PlaybackProgressReport, fixture: Fixture
  ) throws {
    let result = fixture.result
    let classified = report.terminalStates + report.stableIntentionalWaitStates
      + report.externalWaitStates + report.unmeasuredCutoffStates
      + report.transactionStates + report.stuckStates.count
    guard classified == result.nodes.count,
      report.settledTransactionStates <= report.transactionStates
    else { throw HarnessError("inconsistent progress classification counts") }
    guard result.nodes.count == result.summary.stateCount,
      result.graph.edges.count == result.summary.edgeCount,
      result.predecessors.count == result.nodes.count
    else { throw HarnessError("inconsistent graph receipt counts") }
    if let expected = fixture.expected, ReportReceipt(report) != expected {
      throw HarnessError(
        "\(fixture.workload.id) differs from independent graph expectation"
      )
    }
  }

  private static func emit<Value: Encodable>(_ value: Value) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let encoded = try encoder.encode(value)
    let object = try JSONSerialization.jsonObject(with: encoded)
    let data = try JSONSerialization.data(
      withJSONObject: normalizeKnownSets(object),
      options: [.sortedKeys, .withoutEscapingSlashes]
    )
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([0x0a]))
  }

  private static func normalizeKnownSets(
    _ object: Any, field: String? = nil
  ) throws -> Any {
    if let dictionary = object as? [String: Any] {
      var normalized: [String: Any] = [:]
      for (key, value) in dictionary {
        normalized[key] = try normalizeKnownSets(value, field: key)
      }
      return normalized
    }
    if let array = object as? [Any] {
      if field == "prerequisites" || field == "duplicateClasses" {
        guard let strings = array as? [String] else {
          throw HarnessError("unexpected elements in Set field \(field ?? "")")
        }
        return strings.sorted()
      }
      return try array.map { try normalizeKnownSets($0) }
    }
    return object
  }
}
