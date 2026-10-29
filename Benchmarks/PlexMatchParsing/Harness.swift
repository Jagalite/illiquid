import Foundation
import Dispatch
@testable import IlliquidCore

private struct Fixture: Decodable {
    let name: String
    let text: String
    let paths: [String]
}
private struct Inputs: Decodable {
    let workloads: [Fixture]
    let tokens: [String]
}
private enum Failure: Error { case arguments, fixture }

private func optional<T>(_ value: T?) -> Any { value.map { $0 as Any } ?? NSNull() }

private func record(_ hint: MediaMetadataHints?) -> Any {
    guard let hint else { return NSNull() }
    let content: String?
    switch hint.content {
    case .movie: content = "movie"
    case .show: content = "show"
    case .episode: content = "episode"
    case nil: content = nil
    }
    return [
        "content": optional(content), "title": optional(hint.title), "year": optional(hint.year),
        "season": optional(hint.season), "episode": optional(hint.episode),
        "lastEpisode": optional(hint.lastEpisode), "episodeTitle": optional(hint.episodeTitle),
        "catalogIDs": hint.catalogIDs, "sources": hint.sources,
    ] as [String: Any]
}

private func observation(_ text: String, paths: [String]) -> Any {
    guard let parsed = PlexMatchHints.parse(text) else { return NSNull() }
    return [
        "metadata": record(parsed.metadata),
        "lookups": paths.map { path in
            [
                "path": path,
                "raw": record(parsed.episodeHint(for: path, inheritsDescendantMappings: true)),
                "merged": record(parsed.hints(for: path)),
                "defaultSeason": record(parsed.hints(for: path, defaultSeason: 9)),
                "localOnly": record(parsed.hints(for: path, inheritsDescendantMappings: false)),
            ] as [String: Any]
        },
    ] as [String: Any]
}

// Inputs come from a runtime file and the complete parser lives in a separately
// optimized module. Each parse's observable result contributes to the checksum.
@inline(never)
private func parseOnce(_ fixture: Fixture) -> UInt64 {
    guard let parsed = PlexMatchHints.parse(fixture.text) else { return 11 }
    let hint = parsed.episodeHint(for: fixture.paths.first ?? "__missing__.mkv",
                                 inheritsDescendantMappings: true)
    var checksum = UInt64(parsed.metadata.title?.utf8.count ?? 0)
    checksum = checksum &* 31 &+ UInt64((hint?.season ?? -1) + 1)
    checksum = checksum &* 31 &+ UInt64((hint?.episode ?? -1) + 1)
    checksum = checksum &* 31 &+ UInt64((hint?.lastEpisode ?? -1) + 1)
    return checksum
}

@inline(never)
private func batch(_ fixture: Fixture, iterations: Int) -> UInt64 {
    var checksum: UInt64 = 0
    for _ in 0..<iterations {
        checksum &+= autoreleasepool { parseOnce(fixture) }
    }
    return checksum
}

@main
private enum Main {
    static func main() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count >= 2 else { throw Failure.arguments }
        let inputs = try JSONDecoder().decode(Inputs.self, from: Data(contentsOf:
            URL(fileURLWithPath: args[1])))
        if args[0] == "verify", args.count == 2 {
            let cases: [[String: Any]] = inputs.workloads.map { fixture in
                ["name": fixture.name, "result": observation(fixture.text,
                    paths: fixture.paths + ["__missing__.mkv", "child/__missing__.mkv"])]
            }
            let corpus: [[String: Any]] = inputs.tokens.map { token in
                let path = "child/café 🎬.mkv"
                let mapping = "ep: \(token): \(path)"
                return [
                    "token": token,
                    "onlyMapping": observation(mapping, paths: [path]),
                    "withMetadata": observation("title: Corpus\nseason: 7\n" + mapping, paths: [path]),
                    "replacement": observation("title: Corpus\nep: S04E06-E08: \(path)\n" + mapping,
                                               paths: [path]),
                ]
            }
            emit(["workloads": cases, "tokens": corpus, "tokenCount": inputs.tokens.count,
                  "corpusParses": inputs.tokens.count * 3])
            return
        }
        guard args[0] == "benchmark", args.count == 4,
              let iterations = Int(args[3]), iterations > 0,
              let fixture = inputs.workloads.first(where: { $0.name == args[2] })
        else { throw Failure.arguments }
        let warmupIterations = min(iterations, 16)
        let warmup = batch(fixture, iterations: warmupIterations)
        let start = DispatchTime.now().uptimeNanoseconds
        let checksum = batch(fixture, iterations: iterations)
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        emit(["workload": fixture.name, "iterations": iterations, "elapsed_ns": elapsed,
              "checksum": String(checksum), "input_bytes": fixture.text.utf8.count,
              "warmup_iterations": warmupIterations, "warmup_checksum": String(warmup)])
    }

    private static func emit(_ value: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: value, options: .sortedKeys)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([10]))
    }
}
