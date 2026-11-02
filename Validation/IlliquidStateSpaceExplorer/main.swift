import CryptoKit
import Darwin
import Foundation
import IlliquidPlaybackStateSpace

struct Arguments {
  var profile = "pr"
  var model: PlaybackSearchModel?
  var seed: String?
  var allSeeds = false
  var shardIndex = 0
  var shardCount = 1
  var porMode: PlaybackSearchPORMode?
  var output = "Artifacts/PlaybackStateSpace"
  var baseline: String?
  var resume = false
  var provenance: String?
  var maxGraphBytes: UInt64? = 3 * 1024 * 1024 * 1024
  var replay: String?
  var convertLegacy: String?
  /// Overrides the profile's per-seed time budget; nil keeps the profile's.
  var timeLimit: Double??
}

func fail(_ message: String, code: Int32 = 64) -> Never {
  fputs(message + "\n", stderr)
  exit(code)
}

func parseArguments() -> Arguments {
  var result = Arguments()
  var index = 1
  let arguments = CommandLine.arguments
  while index < arguments.count {
    let argument = arguments[index]
    func value() -> String {
      index += 1
      guard index < arguments.count else { fail("missing value for \(argument)") }
      return arguments[index]
    }
    switch argument {
    case "--profile": result.profile = value()
    case "--model":
      let raw = value()
      guard let model = PlaybackSearchModel(rawValue: raw) else { fail("unknown model: \(raw)") }
      result.model = model
    case "--seed": result.seed = value()
    case "--all-seeds": result.allSeeds = true
    case "--shard-index": result.shardIndex = Int(value()) ?? -1
    case "--shard-count": result.shardCount = Int(value()) ?? 0
    case "--por":
      let raw = value()
      result.porMode =
        switch raw {
        case "off": .disabled
        case "on": .conservative
        case "validation": .validation
        default: fail("unknown POR mode: \(raw)")
        }
    case "--output": result.output = value()
    case "--baseline": result.baseline = value()
    case "--resume": result.resume = true
    case "--provenance": result.provenance = value()
    case "--max-graph-bytes":
      let raw = value()
      if raw == "none" {
        result.maxGraphBytes = nil
      } else if let bytes = UInt64(raw) {
        result.maxGraphBytes = bytes
      } else {
        fail("invalid byte count: \(raw)")
      }
    case "--time-limit":
      let raw = value()
      if raw == "none" {
        result.timeLimit = .some(nil)
      } else if let seconds = Double(raw), seconds.isFinite, seconds >= 0 {
        result.timeLimit = .some(seconds)
      } else {
        fail("invalid time limit: \(raw)")
      }
    case "--replay": result.replay = value()
    case "--convert-legacy": result.convertLegacy = value()
    case "--help", "-h":
      print(
        """
        IlliquidStateSpaceExplorer (Statelessness \(PlaybackVerificationEngine.revision))
          --profile pr|nightly|qualification|validation
          [--model MODEL] [--seed SEED] [--all-seeds]
          [--shard-index N --shard-count N]
          [--por off|on|validation] [--baseline FILE] [--output DIRECTORY] [--resume]
          [--provenance FILE] [--max-graph-bytes N|none] [--time-limit SECONDS|none]
          --replay ARTIFACT
          --convert-legacy LEGACY_ARTIFACT --output DIRECTORY
        """)
      exit(0)
    default: fail("unknown argument: \(argument)")
    }
    index += 1
  }
  guard result.shardCount > 0, result.shardIndex >= 0, result.shardIndex < result.shardCount
  else { fail("invalid deterministic shard selection") }
  return result
}

func configuration(_ name: String) -> PlaybackSearchConfiguration {
  switch name {
  case "pr": return .pr
  case "nightly": return .nightly
  case "qualification": return .qualification
  case "validation": return .validation()
  default: fail("unknown profile: \(name)")
  }
}

func sha256(_ data: some DataProtocol) -> String {
  SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

let arguments = parseArguments()
let fileManager = FileManager.default
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]

// Fresh-process replay of a Statelessness artifact.
if let path = arguments.replay {
  let artifact = try PlaybackVerificationArtifacts.decode(
    Array(try Data(contentsOf: URL(fileURLWithPath: path))))
  let replay = try PlaybackArtifactReplayer.replay(artifact)
  print(
    "replay \(path): original \(replay.originalComplete ? "exact" : "DIVERGED"), "
      + "minimized \(replay.minimizedComplete ? "exact" : "DIVERGED"), "
      + "target \(artifact.target.property) \(replay.targetReproduced ? "reproduced" : "MISSING"), "
      + "\(replay.productionTransitionCount) production transitions")
  exit(replay.reproduced ? 0 : 1)
}

let outputURL = URL(fileURLWithPath: arguments.output, isDirectory: true)
try fileManager.createDirectory(at: outputURL, withIntermediateDirectories: true)

// Conversion of a schema-1 artifact from the retired explorer.
if let path = arguments.convertLegacy {
  let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
  let digest = sha256(bytes)
  let artifact = try PlaybackLegacyArtifactConverter.convert(Array(bytes), sha256: digest)
  let destination = outputURL.appendingPathComponent(
    "converted-\(digest.prefix(16)).json")
  try Data(try PlaybackVerificationArtifacts.encode(artifact)).write(
    to: destination, options: .withoutOverwriting)
  print(
    "converted \(path) -> \(destination.path); unpreserved: "
      + artifact.unpreservedFields.joined(separator: ", "))
  exit(0)
}

var searchConfiguration = configuration(arguments.profile)
if let porMode = arguments.porMode {
  searchConfiguration = searchConfiguration.withPORMode(porMode)
}
if let timeLimit = arguments.timeLimit {
  searchConfiguration = searchConfiguration.withTimeLimitSeconds(timeLimit)
}
let provenance: PlaybackVerificationProvenance =
  try arguments.provenance.map {
    try JSONDecoder().decode(
      PlaybackVerificationProvenance.self, from: Data(contentsOf: URL(fileURLWithPath: $0)))
  }
  ?? PlaybackVerificationProvenance(
    sourceRevision: ProcessInfo.processInfo.environment["ILLIQUID_SOURCE_REVISION"]
      ?? "unknown",
    sourceDirty: ProcessInfo.processInfo.environment["ILLIQUID_SOURCE_DIRTY"] != "0")
let models = arguments.model.map { [$0] } ?? PlaybackSearchModel.allCases
var jobs: [(PlaybackSearchModel, String)] = []
for model in models {
  let seeds = PlaybackSearchModelDefinition(model: model).inventory.seedProfiles
  if let seed = arguments.seed {
    jobs.append((model, seed))
  } else if arguments.allSeeds || arguments.profile != "pr" {
    jobs += seeds.map { (model, $0) }
  } else if let first = seeds.first {
    jobs.append((model, first))
  }
}
jobs = jobs.enumerated().filter {
  $0.offset % arguments.shardCount == arguments.shardIndex
}.map(\.element)

let trendBaseline = try arguments.baseline.map {
  try JSONDecoder().decode(
    PlaybackSearchTrendBaseline.self, from: Data(contentsOf: URL(fileURLWithPath: $0)))
}
var records: [PlaybackVerificationRecord] = []
var didFail = false
var incomplete = false

for (model, seed) in jobs {
  let summaryPath = outputURL.appendingPathComponent("\(model.rawValue)-\(seed)-summary.json")
  // Resume only an identical, finished run: same engine, model, properties,
  // codec, whole effective configuration, source identity and graph budget.
  if arguments.resume,
    let data = try? Data(contentsOf: summaryPath),
    let resumed = try? JSONDecoder().decode(PlaybackVerificationRecord.self, from: data),
    resumed.summary.engineRevision == PlaybackVerificationEngine.revision,
    resumed.summary.modelVersion == PlaybackSearchModelDefinition(model: model).modelVersion,
    resumed.summary.propertiesVersion == PlaybackModelCodec.propertiesVersion,
    resumed.summary.codecVersion == PlaybackModelCodec.codecVersion,
    resumed.summary.reductionPolicyVersion == PlaybackReductionPolicy.version,
    resumed.summary.configuration == searchConfiguration,
    resumed.maxGraphBytes == arguments.maxGraphBytes,
    resumed.provenance == provenance,
    resumed.summary.completeWithinBounds
  {
    // Trend acceptance always uses the baseline supplied to this run.
    let current = resumed.reevaluated(against: trendBaseline)
    records.append(current)
    try encoder.encode(current).write(to: summaryPath, options: .atomic)
    print(
      "\(model.rawValue)/\(seed): resumed \(current.summary.termination), "
        + "\(current.trendViolations.count) trend violations")
    if !current.clean { didFail = true }
    continue
  }
  let started = ContinuousClock.now
  let run = try PlaybackVerifier.run(
    model: model, seedProfile: seed, configuration: searchConfiguration,
    maxGraphBytes: arguments.maxGraphBytes,
    progressHandler: { progress in
      fputs(
        "[state-space-progress] \(progress.model.rawValue)/\(progress.seedProfile) "
          + "depth=\(progress.depth) states=\(progress.stateCount) "
          + "edges=\(progress.edgeCount)\n", stderr)
    })
  let trendViolations =
    trendBaseline.map { PlaybackSearchTrendEvaluator.evaluate(run.summary, against: $0) } ?? []
  var artifactPaths: [String] = []
  let built = try PlaybackVerificationArtifacts.build(run: run, provenance: provenance)
  for (index, artifact) in built.artifacts.enumerated() {
    let path = outputURL.appendingPathComponent("\(model.rawValue)-\(seed)-failure-\(index).json")
    try Data(try PlaybackVerificationArtifacts.encode(artifact)).write(to: path, options: .atomic)
    artifactPaths.append(path.path)
  }
  let record = PlaybackVerificationRecord(
    summary: run.summary, progress: PlaybackProgressPolicy.summary(run.progress),
    progressGraphComplete: run.progress.graphComplete,
    failureArtifactPaths: artifactPaths, unretainedFindings: built.unretained,
    trendViolations: trendViolations, provenance: provenance,
    maxGraphBytes: arguments.maxGraphBytes,
    elapsedSeconds: {
      let elapsed = ContinuousClock.now - started
      return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }())
  records.append(record)
  try encoder.encode(record).write(to: summaryPath, options: .atomic)
  print(
    "\(model.rawValue)/\(seed): \(run.summary.termination) [\(run.summary.coverage)], "
      + "\(run.summary.stateCount) states, \(run.summary.edgeCount) edges, "
      + "\(run.summary.findingCount) findings, \(trendViolations.count) trend violations, "
      + "\(run.progress.unmeasuredStates) unmeasured")
  if !record.clean { didFail = true }
  if !run.summary.completeWithinBounds { incomplete = true }
}

let manifest = outputURL.appendingPathComponent(
  "manifest-shard-\(arguments.shardIndex)-of-\(arguments.shardCount).json")
try encoder.encode(records).write(to: manifest, options: .atomic)
if didFail { exit(1) }
if incomplete { exit(2) }
