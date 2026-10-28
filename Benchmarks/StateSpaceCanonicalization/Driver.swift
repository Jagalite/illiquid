import Foundation
import IlliquidPlaybackCore
import IlliquidPlaybackStateSpace

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

private func cpuNanoseconds() -> UInt64 {
  var value = timespec()
  precondition(clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &value) == 0)
  return UInt64(value.tv_sec) * 1_000_000_000 + UInt64(value.tv_nsec)
}

private struct Semantics: Codable, Equatable {
  let summary: PlaybackSearchSummary
  let failures: [PlaybackSearchFailure]
  let graphDigest: String
  let predecessorDigest: String
  let orderedStateDigests: [String]
}

private struct Observation: Codable {
  let wallNanoseconds: UInt64
  let cpuNanoseconds: UInt64
  let semantics: Semantics
}

private func digest<T: Encodable>(_ value: T) throws -> String {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys]
  let data = try encoder.encode(value)
  var hash: UInt64 = 14_695_981_039_346_656_037
  for byte in data {
    hash ^= UInt64(byte)
    hash &*= 1_099_511_628_211
  }
  return String(hash, radix: 16)
}

@main
struct StateSpaceBenchmark {
  static func main() throws {
    let arguments = Array(CommandLine.arguments.dropFirst())
    precondition(arguments.count == 5, "Usage: benchmark MODEL SEED DEPTH POR PROFILE")
    guard let model = PlaybackSearchModel(rawValue: arguments[0]),
      let depth = Int(arguments[2]),
      let por = PlaybackSearchPORMode(rawValue: arguments[3])
    else { preconditionFailure("Invalid benchmark arguments") }
    // Time limits would change the explored work when a variant runs faster.
    // Keep identical finite bounds and require both variants to complete them.
    let configuration: PlaybackSearchConfiguration
    switch arguments[4] {
    case "validation":
      configuration = .validation(depthLimit: depth, porMode: por).withTimeLimitSeconds(nil)
    case "pr":
      precondition(depth == PlaybackSearchConfiguration.pr.depthLimit)
      configuration = PlaybackSearchConfiguration.pr.withPORMode(por).withTimeLimitSeconds(nil)
    default:
      preconditionFailure("Unknown benchmark profile")
    }
    let wallStart = DispatchTime.now().uptimeNanoseconds
    let cpuStart = cpuNanoseconds()
    let result = try PlaybackStateSpaceExplorer().run(
      model: model, seedProfile: arguments[1], configuration: configuration
    )
    let cpu = cpuNanoseconds() - cpuStart
    let wall = DispatchTime.now().uptimeNanoseconds - wallStart
    precondition(result.summary.termination == .completeWithinBounds,
      "A capped run is not a comparable benchmark")
    precondition(result.failures.isEmpty, "The production search reported an invariant failure")
    // Check graph topology, predecessor choices and state order as well as the
    // public reachability summary. All verification is outside the timed region.
    let semantics = Semantics(
      summary: result.summary,
      failures: result.failures,
      graphDigest: try digest(result.graph),
      predecessorDigest: try digest(result.predecessors),
      orderedStateDigests: result.nodes.map {
        PlaybackSearchCanonicalizer.digest(PlaybackSearchCanonicalizer.key(for: $0))
      }
    )
    let observation = Observation(wallNanoseconds: wall, cpuNanoseconds: cpu, semantics: semantics)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    print(String(decoding: try encoder.encode(observation), as: UTF8.self))
  }
}
