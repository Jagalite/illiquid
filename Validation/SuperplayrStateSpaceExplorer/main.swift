import Darwin
import Foundation
import SuperplayrPlaybackStateSpace

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
}

func parseArguments() -> Arguments {
  var result = Arguments()
  var index = 1
  let arguments = CommandLine.arguments
  while index < arguments.count {
    let argument = arguments[index]
    func value() -> String {
      index += 1
      guard index < arguments.count else {
        fputs("missing value for \(argument)\n", stderr)
        exit(64)
      }
      return arguments[index]
    }
    switch argument {
    case "--profile": result.profile = value()
    case "--model":
      let raw = value()
      guard let model = PlaybackSearchModel(rawValue: raw) else {
        fputs("unknown model: \(raw)\n", stderr)
        exit(64)
      }
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
        default:
          {
            fputs("unknown POR mode: \(raw)\n", stderr)
            exit(64)
          }()
        }
    case "--output": result.output = value()
    case "--baseline": result.baseline = value()
    case "--resume": result.resume = true
    case "--help", "-h":
      print(
        """
        SuperplayrStateSpaceExplorer
          --profile pr|nightly|qualification|validation
          [--model MODEL] [--seed SEED] [--all-seeds]
          [--shard-index N --shard-count N]
          [--por off|on|validation] [--baseline FILE] [--output DIRECTORY] [--resume]
        """)
      exit(0)
    default:
      fputs("unknown argument: \(argument)\n", stderr)
      exit(64)
    }
    index += 1
  }
  guard result.shardCount > 0,
    result.shardIndex >= 0,
    result.shardIndex < result.shardCount
  else {
    fputs("invalid deterministic shard selection\n", stderr)
    exit(64)
  }
  return result
}

func configuration(_ name: String) -> PlaybackSearchConfiguration {
  switch name {
  case "pr": return PlaybackSearchConfiguration.pr
  case "nightly": return PlaybackSearchConfiguration.nightly
  case "qualification": return PlaybackSearchConfiguration.qualification
  case "validation": return PlaybackSearchConfiguration.validation()
  default:
    fputs("unknown profile: \(name)\n", stderr)
    exit(64)
  }
}

let arguments = parseArguments()
var searchConfiguration = configuration(arguments.profile)
if let porMode = arguments.porMode {
  searchConfiguration = searchConfiguration.withPORMode(porMode)
}
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

let fileManager = FileManager.default
let outputURL = URL(fileURLWithPath: arguments.output, isDirectory: true)
try fileManager.createDirectory(at: outputURL, withIntermediateDirectories: true)
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
let sourceRevision = ProcessInfo.processInfo.environment["SUPERPLAYR_SOURCE_REVISION"] ?? "unknown"
let dirty = ProcessInfo.processInfo.environment["SUPERPLAYR_SOURCE_DIRTY"] == "1"
let trendBaseline = try arguments.baseline.map {
  try JSONDecoder().decode(
    PlaybackSearchTrendBaseline.self,
    from: Data(contentsOf: URL(fileURLWithPath: $0))
  )
}
var records: [PlaybackSearchQualificationRecord] = []
var didFail = false
var hitCap = false

for (model, seed) in jobs {
  let summaryPath = outputURL.appendingPathComponent("\(model.rawValue)-\(seed)-summary.json")
  if arguments.resume,
    let data = try? Data(contentsOf: summaryPath),
    let resumed = try? JSONDecoder().decode(PlaybackSearchQualificationRecord.self, from: data),
    resumed.summary.modelVersion == PlaybackSearchModelDefinition(model: model).modelVersion,
    resumed.summary.configuration == searchConfiguration,
    resumed.sourceRevision == sourceRevision,
    resumed.sourceDirty == dirty,
    resumed.summary.termination == .completeWithinBounds
  {
    records.append(resumed)
    print(
      "\(model.rawValue)/\(seed): resumed \(resumed.summary.termination.rawValue), "
        + "\(resumed.summary.stateCount) states, \(resumed.summary.edgeCount) edges")
    if resumed.summary.termination != .completeWithinBounds { hitCap = true }
    if !resumed.failureArtifactPaths.isEmpty || !resumed.progress.stuckStates.isEmpty
      || !resumed.progress.closedNonterminalSCCs.isEmpty
      || !resumed.trendViolations.isEmpty
      || resumed.summary.nonCommutingDiamondCount > 0
    {
      didFail = true
    }
    continue
  }
  let result = try PlaybackStateSpaceExplorer().run(
    model: model, seedProfile: seed, configuration: searchConfiguration,
    progressHandler: { progress in
      fputs(
        "[state-space-progress] \(progress.model.rawValue)/\(progress.seedProfile) "
          + "depth=\(progress.depth) states=\(progress.stateCount) "
          + "edges=\(progress.edgeCount) frontier=\(progress.frontierCount)\n",
        stderr
      )
    }
  )
  let progress = PlaybackProgressAnalyzer.analyze(result)
  let trendViolations =
    trendBaseline.map {
      PlaybackSearchTrendEvaluator.evaluate(result.summary, against: $0)
    } ?? []
  var artifactPaths: [String] = []
  for (failureIndex, failure) in result.failures.enumerated() {
    let artifact = try PlaybackSearchArtifactBuilder.build(
      result: result, failure: failure,
      sourceRevision: sourceRevision, dirty: dirty
    )
    let name = "\(model.rawValue)-\(seed)-failure-\(failureIndex).json"
    let path = outputURL.appendingPathComponent(name)
    try PlaybackSearchArtifactCodec.encode(artifact).write(to: path, options: .atomic)
    artifactPaths.append(path.path)
  }
  let record = PlaybackSearchQualificationRecord(
    summary: result.summary, progress: progress,
    failureArtifactPaths: artifactPaths, trendViolations: trendViolations,
    sourceRevision: sourceRevision, sourceDirty: dirty
  )
  records.append(record)
  try encoder.encode(record).write(to: summaryPath, options: .atomic)
  print(
    "\(model.rawValue)/\(seed): \(result.summary.termination.rawValue), "
      + "\(result.summary.stateCount) states, \(result.summary.edgeCount) edges, "
      + "\(result.failures.count) failures, \(trendViolations.count) trend violations, "
      + "\(progress.unmeasuredCutoffStates) cutoff")
  if !result.failures.isEmpty || !progress.stuckStates.isEmpty
    || !progress.closedNonterminalSCCs.isEmpty || !trendViolations.isEmpty
    || result.summary.nonCommutingDiamondCount > 0
  {
    didFail = true
  }
  if result.summary.termination != .completeWithinBounds { hitCap = true }
}

let manifest = outputURL.appendingPathComponent(
  "manifest-shard-\(arguments.shardIndex)-of-\(arguments.shardCount).json"
)
try encoder.encode(records).write(to: manifest, options: .atomic)
if didFail { exit(1) }
if hitCap { exit(2) }
