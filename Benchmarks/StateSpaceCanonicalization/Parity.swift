import Foundation
import IlliquidPlaybackStateSpace

private enum VerificationError: Error {
  case failed(String)
}

private func encodedReceipt<T: Encodable>(_ value: T) throws -> String {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
  return try encoder.encode(value).base64EncodedString()
}

private struct SearchReceipt: Encodable {
  let summary: PlaybackSearchSummary
  let progress: PlaybackProgressReport
  let graphJSONBase64: String
  let predecessorsJSONBase64: String
  let orderedStateDigestsJSONBase64: String
}

private struct ArtifactReceipt: Encodable {
  let model: PlaybackSearchModel
  let actionClass: String
  let artifactJSONBase64: String
  let originalSteps: Int
  let minimizedSteps: Int
  let replayTransitions: Int
  let reproducedFailure: Bool
}

private struct InventoryEntry: Encodable {
  let model: PlaybackSearchModel
  let seeds: [String]
}

@main
struct StateSpaceParity {
  static func main() throws {
    let explorer = PlaybackStateSpaceExplorer()
    var searches: [SearchReceipt] = []
    var inventory: [InventoryEntry] = []
    for model in PlaybackSearchModel.allCases {
      let definition = PlaybackSearchModelDefinition(model: model)
      let seeds = definition.inventory.seedProfiles
      inventory.append(InventoryEntry(model: model, seeds: seeds))
      guard let seed = seeds.first else {
        throw VerificationError.failed("Empty model inventory")
      }
      for mode in [PlaybackSearchPORMode.disabled, .conservative, .validation] {
        let result = try explorer.run(
          model: model, seedProfile: seed,
          configuration: .validation(depthLimit: 3, porMode: mode)
            .withTimeLimitSeconds(nil)
        )
        guard result.summary.termination == .completeWithinBounds,
          result.failures.isEmpty
        else { throw VerificationError.failed("Validation search did not pass") }
        searches.append(
          SearchReceipt(
            summary: result.summary,
            progress: PlaybackProgressAnalyzer.analyze(result),
            graphJSONBase64: try encodedReceipt(result.graph),
            predecessorsJSONBase64: try encodedReceipt(result.predecessors),
            orderedStateDigestsJSONBase64: try encodedReceipt(result.nodes.map {
              PlaybackSearchCanonicalizer.digest(PlaybackSearchCanonicalizer.key(for: $0))
            })
          ))
      }
    }

    var artifacts: [ArtifactReceipt] = []
    let cases: [(PlaybackSearchModel, String, String)] = [
      (.seek, "ready-playing", "command.seekExact"),
      (.trackSubtitles, "automatic", "command.selectAudio"),
      (.stopShutdown, "opening", "command.shutdown"),
    ]
    for (model, seed, actionClass) in cases {
      let result = try explorer.run(
        model: model, seedProfile: seed,
        configuration: .validation(depthLimit: 2).withTimeLimitSeconds(nil),
        oracle: .failOnActionClass(actionClass, invariantName: "benchmarkInjectedFailure")
      )
      guard let failure = result.failures.first(where: {
        $0.invariantName == "benchmarkInjectedFailure"
      }) else { throw VerificationError.failed("Injected failure was not detected") }
      let artifact = try PlaybackSearchArtifactBuilder.build(
        result: result, failure: failure,
        sourceRevision: "same-input-comparison", dirty: false
      )
      let replay = try PlaybackSearchArtifactReplayer.replay(artifact)
      guard replay.reproducedFailure else {
        throw VerificationError.failed("Counterexample did not replay")
      }
      artifacts.append(
        ArtifactReceipt(
          model: model, actionClass: actionClass,
          artifactJSONBase64: try encodedReceipt(artifact),
          originalSteps: artifact.originalTrace.count,
          minimizedSteps: artifact.minimizedTrace.count,
          replayTransitions: replay.productionTransitionCount,
          reproducedFailure: replay.reproducedFailure
        ))
    }

    struct Report: Encodable {
      let inventory: [InventoryEntry]
      let searches: [SearchReceipt]
      let artifacts: [ArtifactReceipt]
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(
      Report(inventory: inventory, searches: searches, artifacts: artifacts)
    )
    print(String(decoding: data, as: UTF8.self))
  }
}
