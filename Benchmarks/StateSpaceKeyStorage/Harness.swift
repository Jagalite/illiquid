import CSearchMemory
import Foundation
import IlliquidPlaybackCore
import IlliquidPlaybackStateSpace

private struct Memory: Codable {
  let liveAllocatorBytes: UInt64
  let currentRSSBytes: UInt64
  let physicalFootprintBytes: UInt64
  let peakRSSBytes: UInt64

  init() {
    let sample = search_memory_snapshot()
    liveAllocatorBytes = sample.live_allocator_bytes
    currentRSSBytes = sample.current_rss_bytes
    physicalFootprintBytes = sample.physical_footprint_bytes
    peakRSSBytes = sample.peak_rss_bytes
  }
}

private struct ProgressSample: Codable {
  let depth: Int
  let stateCount: Int
  let edgeCount: Int
  let memory: Memory
}

// Explorer invokes its progress callback synchronously. The lock also makes
// the Sendable capture safe if callback delivery changes in a future revision.
private final class ProgressSamples: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [ProgressSample] = []

  init() { values.reserveCapacity(32) }

  func append(_ progress: PlaybackStateSpaceExplorer.Progress) {
    let memory = Memory()
    lock.lock()
    defer { lock.unlock() }
    values.append(ProgressSample(
      depth: progress.depth, stateCount: progress.stateCount,
      edgeCount: progress.edgeCount, memory: memory))
  }

  func snapshot() -> [ProgressSample] {
    lock.lock()
    defer { lock.unlock() }
    return values
  }
}

// Codable transports every public node field. Equality is typed: Set and
// Dictionary iteration order is ignored, while all Array order is preserved.
private struct NodeReceipt: Codable, Equatable {
  let model: PlaybackSearchModel
  let seedProfile: String
  let coreState: PlaybackCoreState
  let environment: PlaybackModelEnvironment
  let lateResults: [RetainedEffectResult]
  let ghost: PlaybackSearchGhost
  let nextSequence: UInt64
  let depth: Int

  init(_ node: PlaybackSearchNode) {
    model = node.model
    seedProfile = node.seedProfile
    coreState = node.coreState
    environment = node.environment
    lateResults = node.lateResults
    ghost = node.ghost
    nextSequence = node.nextSequence
    depth = node.depth
  }
}

private struct ResultReceipt: Codable, Equatable {
  let summary: PlaybackSearchSummary
  let oracle: PlaybackSearchOracle
  let failures: [PlaybackSearchFailure]
  let graph: PlaybackSearchGraph
  let predecessors: [PlaybackSearchPredecessor?]
  let nodeCount: Int
  let replayArtifact: PlaybackSearchArtifact?
  let replayReproducedFailure: Bool?
  let replayProductionTransitions: Int?
}

private struct Observation: Codable {
  let allocatorMetric: String
  let keySizeBytes: Int
  let keyStrideBytes: Int
  let beforeSearch: Memory
  let progress: [ProgressSample]
  let afterSearchWithResultAlive: Memory
  let searchWallNanoseconds: UInt64
  let searchCPUNanoseconds: UInt64
  let summary: PlaybackSearchSummary
  let failureCount: Int
}

private enum HarnessError: Error {
  case argument(String)
  case mismatch(String)
}

private func encoder() -> JSONEncoder {
  let result = JSONEncoder()
  result.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
  return result
}

private func emit<T: Encodable>(_ value: T) throws {
  var data = try encoder().encode(value)
  data.append(10)
  try FileHandle.standardOutput.write(contentsOf: data)
}

private final class LineReader {
  private let stream: FileHandle
  private var buffer = Data()
  private var ended = false

  init(_ path: String) throws { stream = try FileHandle(forReadingFrom: URL(fileURLWithPath: path)) }
  deinit { try? stream.close() }

  func next() throws -> Data? {
    while true {
      if let newline = buffer.firstIndex(of: 10) {
        let line = Data(buffer[..<newline])
        buffer.removeSubrange(...newline)
        return line
      }
      if ended {
        guard !buffer.isEmpty else { return nil }
        let line = buffer
        buffer = Data()
        return line
      }
      if let chunk = try stream.read(upToCount: 65_536), !chunk.isEmpty {
        buffer.append(chunk)
      } else {
        ended = true
      }
    }
  }
}

private func compare(_ first: String, _ second: String) throws {
  let decoder = JSONDecoder()
  func structure(_ prefix: String) throws -> ResultReceipt {
    try decoder.decode(ResultReceipt.self, from: Data(contentsOf:
      URL(fileURLWithPath: prefix + ".result.json")))
  }
  let lhs = try structure(first)
  let rhs = try structure(second)
  guard lhs == rhs else { throw HarnessError.mismatch("result structure, graph, failures, predecessors, or replay") }
  let firstNodes = try LineReader(first + ".nodes.jsonl")
  let secondNodes = try LineReader(second + ".nodes.jsonl")
  for index in 0..<lhs.nodeCount {
    guard let firstLine = try firstNodes.next(), let secondLine = try secondNodes.next() else {
      throw HarnessError.mismatch("node stream ended at \(index)")
    }
    let firstNode = try decoder.decode(NodeReceipt.self, from: firstLine)
    let secondNode = try decoder.decode(NodeReceipt.self, from: secondLine)
    guard firstNode == secondNode else { throw HarnessError.mismatch("full node \(index)") }
  }
  guard try firstNodes.next() == nil, try secondNodes.next() == nil else {
    throw HarnessError.mismatch("trailing nodes")
  }
  try emit(["comparedNodes": lhs.nodeCount, "comparedEdges": lhs.graph.edges.count,
            "comparedPredecessors": lhs.predecessors.count, "comparedFailures": lhs.failures.count])
}

private func writeReceipts(_ result: PlaybackSearchResult, prefix: String, replay: Bool) throws {
  let json = encoder()
  var artifact: PlaybackSearchArtifact?
  var reproduced: Bool?
  var replayTransitions: Int?
  if replay {
    guard let failure = result.failures.first else { throw HarnessError.mismatch("injected oracle did not fail") }
    let built = try PlaybackSearchArtifactBuilder.build(
      result: result, failure: failure, sourceRevision: "paired-exact-source-benchmark", dirty: false)
    let outcome = try PlaybackSearchArtifactReplayer.replay(built)
    guard outcome.reproducedFailure else { throw HarnessError.mismatch("artifact replay did not reproduce failure") }
    artifact = built
    reproduced = outcome.reproducedFailure
    replayTransitions = outcome.productionTransitionCount
  }
  let receipt = ResultReceipt(
    summary: result.summary, oracle: result.oracle, failures: result.failures,
    graph: result.graph, predecessors: result.predecessors, nodeCount: result.nodes.count,
    replayArtifact: artifact, replayReproducedFailure: reproduced,
    replayProductionTransitions: replayTransitions)
  try json.encode(receipt).write(to: URL(fileURLWithPath: prefix + ".result.json"))
  let nodesURL = URL(fileURLWithPath: prefix + ".nodes.jsonl")
  guard FileManager.default.createFile(atPath: nodesURL.path, contents: nil) else {
    throw HarnessError.argument("cannot create node receipt")
  }
  let stream = try FileHandle(forWritingTo: nodesURL)
  defer { try? stream.close() }
  for node in result.nodes {
    var line = try json.encode(NodeReceipt(node))
    line.append(10)
    try stream.write(contentsOf: line)
  }
}

@main
private enum StateSpaceKeyStorageBenchmark {
  static func main() throws {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments.first == "--compare", arguments.count == 3 {
      try compare(arguments[1], arguments[2])
      return
    }
    guard arguments.count == 6, let model = PlaybackSearchModel(rawValue: arguments[0]),
      let cap = Int(arguments[2]), cap > 0, let depth = Int(arguments[3]), depth >= 0
    else { throw HarnessError.argument("MODEL SEED CAP DEPTH RECEIPT_PREFIX ORACLE(production|stop)") }
    let seed = arguments[1]
    let prefix = arguments[4]
    let replay = arguments[5] == "stop"
    guard replay || arguments[5] == "production" else { throw HarnessError.argument("unknown oracle") }
    let configuration = PlaybackSearchConfiguration(
      profile: "state-space-key-storage", depthLimit: depth, generationLimit: 2,
      pendingEffectLimit: 4, lateResultLimit: 2, failureLimit: 1,
      duplicateLimit: 1, interruptLimit: 1, stateLimit: cap,
      edgeLimit: max(cap * 20, 10_000), porMode: .disabled, timeLimitSeconds: nil)
    let oracle: PlaybackSearchOracle = replay
      ? .failOnActionClass("command.stop", invariantName: "benchmark.replay.stop") : .production
    let samples = ProgressSamples()
    _ = Memory()
    _ = search_cpu_nanoseconds()
    let before = Memory()
    let cpuStart = search_cpu_nanoseconds()
    let wallStart = DispatchTime.now().uptimeNanoseconds
    let result = try PlaybackStateSpaceExplorer().run(
      model: model, seedProfile: seed, configuration: configuration, oracle: oracle,
      progressHandler: { samples.append($0) })
    let wall = DispatchTime.now().uptimeNanoseconds - wallStart
    let cpu = search_cpu_nanoseconds() - cpuStart
    // Snapshot the whole-search high-water mark before any JSON, receipt, or
    // replay allocation; the final digest and local-container teardown are included.
    let after = withExtendedLifetime(result) { Memory() }
    let observation = Observation(
      allocatorMetric: String(cString: search_allocator_metric()),
      keySizeBytes: MemoryLayout<PlaybackSearchStateKey>.size,
      keyStrideBytes: MemoryLayout<PlaybackSearchStateKey>.stride,
      beforeSearch: before, progress: samples.snapshot(), afterSearchWithResultAlive: after,
      searchWallNanoseconds: wall, searchCPUNanoseconds: cpu,
      summary: result.summary, failureCount: result.failures.count)
    try writeReceipts(result, prefix: prefix, replay: replay)
    try emit(observation)
  }
}
