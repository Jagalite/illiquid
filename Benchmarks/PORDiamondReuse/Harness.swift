import Dispatch
import Foundation
import IlliquidPlaybackCore
@testable import IlliquidPlaybackStateSpace

#if os(Linux)
import Glibc
#else
import Darwin
#endif

private enum Failure: Error { case message(String) }

private let measurementCases = [
  "seek_8", "eof_7", "preroll_5", "two", "one", "zero",
  "validation_disabled", "search_seek_d3", "search_preroll_d3",
]

private func configuration(_ depth: Int = 2) -> PlaybackSearchConfiguration {
  PlaybackSearchConfiguration.validation(
    depthLimit: depth, porMode: .validation
  ).withTimeLimitSeconds(nil)
}

private func diamondCandidates(_ actions: [SearchAction]) -> [SearchAction] {
  actions.filter {
    switch $0 {
    case .runtimeFact(let fact, .current): return isFair(fact)
    case .seekPrerequisite, .seekAggregateReady, .recoveryPrerequisite,
      .trackPrerequisite, .recoveryAggregateReady, .trackAggregateReady,
      .queueOffer, .queueConsume:
      return true
    default: return false
    }
  }
}

private struct ReductionFixture {
  let name: String
  let definition: PlaybackSearchModelDefinition
  let configuration: PlaybackSearchConfiguration
  let node: PlaybackSearchNode
  let actions: [SearchAction]
  let candidateCount: Int
  let validateDiamonds: Bool
}

private struct SearchFixture {
  let name: String
  let model: PlaybackSearchModel
  let profile: String
  let configuration: PlaybackSearchConfiguration
}

private enum Workload {
  case reduction(ReductionFixture)
  case search(SearchFixture)
  var warmupIterations: Int {
    if case .search = self { return 1 }
    return 8
  }
}

private func makeReductionFixture(_ name: String) throws -> ReductionFixture {
  let model: PlaybackSearchModel
  let profile: String
  switch name {
  case "eof_7":
    model = .eofDrain; profile = "draining-av"
  case "preroll_5":
    model = .prerollBuffering; profile = "playing-av"
  case "seek_8", "two", "one", "zero", "validation_disabled",
    "seek_reversed", "seek_duplicated":
    model = .seek; profile = "ready-playing"
  default: throw Failure.message("Unknown reduction workload: \(name)")
  }
  let definition = PlaybackSearchModelDefinition(model: model)
  let config = configuration()
  var node = try definition.makeSeed(profile: profile)
  if model == .seek {
    // The special seek-in-flight seed uses an aggregate prerequisite.
    // Reach a real seek from ready-playing to expose all eight prerequisites.
    node = apply(action: .command(.seekExact), to: node, configuration: config).node
  }
  var actions = definition.enabledActions(for: node, configuration: config)
  let eligible = diamondCandidates(actions)
  switch name {
  case "two": actions = Array(eligible.prefix(2))
  case "one": actions = Array(eligible.prefix(1))
  case "zero": actions = []
  case "seek_reversed": actions.reverse()
  case "seek_duplicated": actions = eligible + eligible
  default: break
  }
  let count = diamondCandidates(actions).count
  switch name {
  case "seek_8", "validation_disabled", "seek_reversed": precondition(count == 8)
  case "eof_7": precondition(count == 7)
  case "preroll_5": precondition(count == 5)
  case "two": precondition(count == 2)
  case "one": precondition(count == 1)
  case "zero": precondition(count == 0)
  case "seek_duplicated": precondition(count == 16)
  default: break
  }
  return ReductionFixture(
    name: name, definition: definition, configuration: config, node: node,
    actions: actions, candidateCount: count, validateDiamonds: name != "validation_disabled"
  )
}

private func makeWorkload(_ name: String) throws -> Workload {
  switch name {
  case "search_seek_d3":
    return .search(SearchFixture(
      name: name, model: .seek, profile: "ready-playing", configuration: configuration(3)
    ))
  case "search_preroll_d3":
    return .search(SearchFixture(
      name: name, model: .prerollBuffering, profile: "playing-av", configuration: configuration(3)
    ))
  default: return .reduction(try makeReductionFixture(name))
  }
}

@inline(never)
private func reduce(_ fixture: ReductionFixture) -> PlaybackPartialOrderReducer.Reduction {
  PlaybackPartialOrderReducer.reduce(
    actions: fixture.actions, node: fixture.node, definition: fixture.definition,
    configuration: fixture.configuration, validateDiamonds: fixture.validateDiamonds
  )
}

@inline(never)
private func search(_ fixture: SearchFixture) throws -> PlaybackSearchResult {
  try PlaybackStateSpaceExplorer().run(
    model: fixture.model, seedProfile: fixture.profile, configuration: fixture.configuration
  )
}

private struct Counts: Codable, Equatable {
  var inputActionCount = 0
  var diamondCandidateCount = 0
  var outputActionCount = 0
  var removedCount = 0
  var validatedDiamondCount = 0
  var nonCommutingDiamondCount = 0
  var stateCount = 0
  var edgeCount = 0
  var productionTransitionCount = 0
  var gateRejectionCount = 0
  var peakFrontier = 0
  var deepestCompletedLayer = 0
  var modelVersion = 0
  var canonicalDigest = ""
  var termination = ""

  init() {}
  init(_ reduction: PlaybackPartialOrderReducer.Reduction, fixture: ReductionFixture) {
    inputActionCount = fixture.actions.count
    diamondCandidateCount = fixture.candidateCount
    outputActionCount = reduction.actions.count
    removedCount = reduction.removedCount
    validatedDiamondCount = reduction.validatedDiamondCount
    nonCommutingDiamondCount = reduction.nonCommutingDiamondCount
  }
  init(_ summary: PlaybackSearchSummary) {
    removedCount = summary.reducedEdgeCount
    validatedDiamondCount = summary.validatedDiamondCount
    nonCommutingDiamondCount = summary.nonCommutingDiamondCount
    stateCount = summary.stateCount
    edgeCount = summary.edgeCount
    productionTransitionCount = summary.productionTransitionCount
    gateRejectionCount = summary.gateRejectionCount
    peakFrontier = summary.peakFrontier
    deepestCompletedLayer = summary.deepestCompletedLayer
    modelVersion = Int(summary.modelVersion)
    canonicalDigest = summary.canonicalDigest
    termination = summary.termination.rawValue
  }
}

private func feed(_ value: UInt64, into checksum: inout UInt64) {
  checksum = (checksum ^ value) &* 1_099_511_628_211
}

private func feed(_ value: String, into checksum: inout UInt64) {
  for byte in value.utf8 { feed(UInt64(byte), into: &checksum) }
  feed(255, into: &checksum)
}

private func feed(_ counts: Counts, into checksum: inout UInt64) {
  feed(UInt64(counts.inputActionCount), into: &checksum)
  feed(UInt64(counts.diamondCandidateCount), into: &checksum)
  feed(UInt64(counts.outputActionCount), into: &checksum)
  feed(UInt64(counts.removedCount), into: &checksum)
  feed(UInt64(counts.validatedDiamondCount), into: &checksum)
  feed(UInt64(counts.nonCommutingDiamondCount), into: &checksum)
  feed(UInt64(counts.stateCount), into: &checksum)
  feed(UInt64(counts.edgeCount), into: &checksum)
  feed(UInt64(counts.productionTransitionCount), into: &checksum)
  feed(UInt64(counts.gateRejectionCount), into: &checksum)
  feed(UInt64(counts.peakFrontier), into: &checksum)
  feed(UInt64(counts.deepestCompletedLayer), into: &checksum)
  feed(UInt64(counts.modelVersion), into: &checksum)
  feed(counts.canonicalDigest, into: &checksum)
  feed(counts.termination, into: &checksum)
}

private func processCPUTime() -> UInt64 {
  var value = timespec()
  precondition(clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &value) == 0)
  return UInt64(value.tv_sec) * 1_000_000_000 + UInt64(value.tv_nsec)
}

private struct LoopResult: Encodable {
  let elapsedNanoseconds: UInt64
  let cpuNanoseconds: UInt64
  let checksum: String
  let counts: Counts
}

@inline(never)
private func run(_ workload: Workload, iterations: Int) throws -> LoopResult {
  var checksum: UInt64 = 14_695_981_039_346_656_037
  var counts = Counts()
  let cpuStart = processCPUTime()
  let start = DispatchTime.now().uptimeNanoseconds
  for _ in 0..<iterations {
    switch workload {
    case .reduction(let fixture):
      let result = reduce(fixture)
      counts = Counts(result, fixture: fixture)
      feed(counts, into: &checksum)
      // Consume complete ordered action classes. Untimed receipts compare enum payloads too.
      for action in result.actions { feed(action.stableClass, into: &checksum) }
    case .search(let fixture):
      // Includes seed construction and the complete real explorer call.
      let result = try search(fixture)
      counts = Counts(result.summary)
      feed(counts, into: &checksum)
    }
  }
  let elapsed = DispatchTime.now().uptimeNanoseconds - start
  let cpu = processCPUTime() - cpuStart
  return LoopResult(elapsedNanoseconds: elapsed, cpuNanoseconds: cpu,
                    checksum: String(checksum, radix: 16), counts: counts)
}

private struct ReductionReceipt: Encodable {
  let name: String
  let configuration: PlaybackSearchConfiguration
  let validateDiamonds: Bool
  let inputKey: PlaybackSearchStateKey
  let inputActions: [SearchAction]
  let outputActions: [SearchAction]
  let counts: Counts

  init(_ fixture: ReductionFixture) {
    let before = PlaybackSearchCanonicalizer.key(for: fixture.node)
    let result = reduce(fixture)
    precondition(PlaybackSearchCanonicalizer.key(for: fixture.node) == before)
    name = fixture.name
    configuration = fixture.configuration
    validateDiamonds = fixture.validateDiamonds
    inputKey = before
    inputActions = fixture.actions
    outputActions = result.actions
    counts = Counts(result, fixture: fixture)
    if !fixture.validateDiamonds || fixture.candidateCount <= 1 {
      precondition(result.validatedDiamondCount == 0)
      precondition(result.nonCommutingDiamondCount == 0)
    }
    if fixture.name == "two" {
      precondition(result.validatedDiamondCount == 1)
      precondition(result.nonCommutingDiamondCount == 0)
    }
    if ["seek_8", "eof_7", "preroll_5"].contains(fixture.name) {
      precondition(result.validatedDiamondCount > 0)
    }
  }
}

private struct SearchReceipt: Encodable {
  let name: String
  let summary: PlaybackSearchSummary
  let oracle: PlaybackSearchOracle
  let failures: [PlaybackSearchFailure]
  let graph: PlaybackSearchGraph
  let keys: [PlaybackSearchStateKey]
  let nodeDepths: [Int]
  let nodeSequences: [UInt64]
  let predecessors: [PlaybackSearchPredecessor?]

  init(_ fixture: SearchFixture) throws {
    let result = try search(fixture)
    precondition(result.summary.termination == .completeWithinBounds)
    name = fixture.name
    summary = result.summary
    oracle = result.oracle
    failures = result.failures
    graph = result.graph
    keys = result.nodes.map { PlaybackSearchCanonicalizer.key(for: $0) }
    nodeDepths = result.nodes.map(\.depth)
    nodeSequences = result.nodes.map(\.nextSequence)
    predecessors = result.predecessors
    precondition(keys.count == summary.stateCount)
    precondition(graph.edges.count == summary.edgeCount)
    precondition(predecessors.count == keys.count)
  }
}

private struct Verification: Encodable {
  let schema = 1
  let reductions: [ReductionReceipt]
  let searches: [SearchReceipt]
}

private func verify() throws -> Verification {
  var reductions: [ReductionReceipt] = []
  var searches: [SearchReceipt] = []
  for name in measurementCases {
    switch try makeWorkload(name) {
    case .reduction(let fixture): reductions.append(ReductionReceipt(fixture))
    case .search(let fixture): searches.append(try SearchReceipt(fixture))
    }
  }
  for name in ["seek_reversed", "seek_duplicated"] {
    reductions.append(ReductionReceipt(try makeReductionFixture(name)))
  }
  // Every advertised production seed, not just the reached nodes measured above.
  for model in PlaybackSearchModel.allCases {
    let definition = PlaybackSearchModelDefinition(model: model)
    for profile in definition.inventory.seedProfiles {
      let node = try definition.makeSeed(profile: profile)
      let config = configuration()
      let actions = definition.enabledActions(for: node, configuration: config)
      reductions.append(ReductionReceipt(ReductionFixture(
        name: "seed:\(model.rawValue)/\(profile)", definition: definition,
        configuration: config, node: node, actions: actions,
        candidateCount: diamondCandidates(actions).count, validateDiamonds: true
      )))
    }
  }
  searches.append(try SearchReceipt(SearchFixture(
    name: "verify_eof_d2", model: .eofDrain, profile: "draining-av",
    configuration: configuration(2)
  )))
  searches.append(try SearchReceipt(SearchFixture(
    name: "verify_shutdown_d3", model: .stopShutdown, profile: "opening",
    configuration: configuration(3)
  )))
  return Verification(reductions: reductions, searches: searches)
}

// Normalize only Set-backed fields in encoded environment/ghost values.
// Every other array's order and all complete enum payloads are preserved.
private func normalizedJSON(_ value: Any, field: String? = nil) -> Any {
  if let object = value as? [String: Any] {
    return object.reduce(into: [String: Any]()) { result, entry in
      result[entry.key] = normalizedJSON(entry.value, field: entry.key)
    }
  }
  if let array = value as? [Any] {
    if field == "prerequisites" || field == "duplicateClasses" {
      guard let strings = array as? [String] else {
        preconditionFailure("Unexpected non-string Set representation: \(field ?? "")")
      }
      return strings.sorted()
    }
    return array.map { normalizedJSON($0) }
  }
  return value
}

private func jsonObject<T: Encodable>(_ value: T) throws -> Any {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
  return try JSONSerialization.jsonObject(with: encoder.encode(value))
}

private func emitObject(_ value: Any) throws {
  let bytes = try JSONSerialization.data(
    withJSONObject: normalizedJSON(value), options: [.sortedKeys, .withoutEscapingSlashes]
  )
  print(String(decoding: bytes, as: UTF8.self))
}

@main
private enum Main {
  static func main() throws {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments == ["verify"] {
      let verification = try verify()
      try emitObject(jsonObject(verification))
      return
    }
    guard arguments.count == 3, arguments[0] == "measure",
      measurementCases.contains(arguments[1]),
      let iterations = Int(arguments[2]), iterations > 0
    else { throw Failure.message("Usage: benchmark verify | measure WORKLOAD ITERATIONS") }
    let workload = try makeWorkload(arguments[1])
    let warmup = try run(workload, iterations: workload.warmupIterations)
    let measured = try run(workload, iterations: iterations)
    precondition(measured.counts == warmup.counts)

    // Serialize and flatten only after timing ends.
    var row = try jsonObject(measured) as! [String: Any]
    let counts = row.removeValue(forKey: "counts") as! [String: Any]
    row.merge(counts) { _, new in new }
    row["workload"] = arguments[1]
    row["iterations"] = iterations
    row["warmupIterations"] = workload.warmupIterations
    row["warmupChecksum"] = warmup.checksum
    row["warmupElapsedNanoseconds"] = warmup.elapsedNanoseconds
    row["warmupCPUNanoseconds"] = warmup.cpuNanoseconds
    try emitObject(row)
  }
}
