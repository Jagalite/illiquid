import Foundation
import Dispatch
import IlliquidCore
@testable import IlliquidApp
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// Production SourceBrowserFilter and SourceVisibilityMatcher are compiled in a
// separate module. Fixture setup, trace encoding, output consumption and actor
// destruction are outside the timed awaited projection.
private struct Fixture: Sendable {
    static let cases: Set<String> = [
        "tree_manual_hide", "tree_always_show", "files_manual_ancestor",
        "disabled_regex", "invalid_regex", "regex_nonmatch", "regex_match", "default_empty",
    ]
    let rows: [SourceTreeDisplayRow]
    let roots: [URL]
    let configuration: SourceVisibilityConfiguration

    init(size: Int, scenario: String) {
        let mainRoot = URL(fileURLWithPath: "/Volumes/Benchmark Library/映像 é", isDirectory: true)
        let roots = [
            mainRoot,
            mainRoot.appendingPathComponent("Nested 日本", isDirectory: true),
            URL(fileURLWithPath: "/Volumes/Other Library/Ω", isDirectory: true),
            URL(fileURLWithPath: "/Volumes/Archive/Shows", isDirectory: true),
        ]
        var recognition = MediaNameRecognition.recognize(
            relativePath: "Series 日本 (2024)/Season 1/Series 日本.S01E02E03 - Story {tvdb-4321} [1080p].mkv"
        )
        recognition.metadataSources = ["filename", "series.nfo"]
        let rows = (0..<size).map { index -> SourceTreeDisplayRow in
            let root = index % 31 == 0
                ? URL(fileURLWithPath: "/Volumes/Outside/映像", isDirectory: true)
                : roots[(index / 4) % roots.count]
            let branch = index % 4 == 0 ? "Hidden" : "Visible"
            let parent = root.appendingPathComponent(
                "\(branch)/Series \(index % 11)/Season 1", isDirectory: true
            )
            let suffix = index % 7 == 0 ? " Trailer" : ""
            let name = "Episode \(index + 1)\(suffix).mkv"
            let url = parent.appendingPathComponent(name, isDirectory: false)
            let path = SourceVisibilityPath.normalized(url)!
            let added: Date? = index % 3 == 0
                ? nil : Date(timeIntervalSince1970: Double(1_700_000_000 + index) + 0.25)
            return SourceTreeDisplayRow(
                id: "media:\(path)", folderID: parent.path, url: url,
                displayName: name, contextLabel: "Series \(index % 11) · 日本",
                recognizedMedia: index % 3 == 0 ? recognition : nil,
                visibilityPath: path, depth: 0, ancestorIDs: [],
                kind: .media(dateAdded: added),
                containsSupportedMedia: index % 11 == 0 ? true : nil
            )
        }
        let manualPaths = Set(rows.enumerated().compactMap {
            $0.offset % 5 == 0 ? $0.element.visibilityPath : nil
        })
        var configuration = SourceVisibilityConfiguration.default
        switch scenario {
        case "tree_manual_hide":
            configuration.manuallyHiddenPaths = manualPaths
        case "tree_always_show":
            configuration.alwaysShownPaths = manualPaths
        case "files_manual_ancestor":
            configuration.viewMode = .filesOnly
            configuration.manuallyHiddenPaths = Set(roots.map {
                $0.appendingPathComponent("Hidden", isDirectory: true).path
            })
        case "disabled_regex":
            // Manual paths make the filter evaluate visibility. Disabled-only
            // configurations already skip per-row matcher evaluation upstream.
            configuration.manuallyHiddenPaths = manualPaths
            configuration.regexRules = [
                .init(id: "disabled", pattern: ".*", colorIndex: 1, isEnabled: false),
            ]
        case "invalid_regex":
            configuration.manuallyHiddenPaths = manualPaths
            // Direct, unnormalized input exercises the matcher's defensive path.
            configuration.regexRules = [
                .init(id: "invalid", pattern: "[", colorIndex: 2, isEnabled: true),
            ]
        case "regex_nonmatch":
            configuration.manuallyHiddenPaths = manualPaths
            configuration.regexRules = [
                .init(id: "nonmatch", pattern: "__Never_Matches_This_Library__",
                      colorIndex: 3, isEnabled: true),
            ]
        case "regex_match":
            configuration.manuallyHiddenPaths = manualPaths
            configuration.alwaysShownPaths = Set(rows.enumerated().compactMap {
                $0.offset % 6 == 0 ? $0.element.visibilityPath : nil
            })
            configuration.regexRules = [
                .init(id: "trailers", pattern: "Trailer", colorIndex: 2, isEnabled: true),
                .init(id: "episodes", pattern: #"Episode [0-9]*[02468](?: Trailer)?\.mkv$"#,
                      colorIndex: 4, isEnabled: true),
            ]
        case "default_empty":
            break
        default:
            preconditionFailure("Unknown workload")
        }
        self.rows = rows
        self.roots = roots
        self.configuration = configuration
    }
}

private struct StableDigest {
    private(set) var value: UInt64 = 14_695_981_039_346_656_037

    mutating func add(_ word: UInt64) {
        var remaining = word
        for _ in 0..<8 {
            value = (value ^ (remaining & 255)) &* 1_099_511_628_211
            remaining >>= 8
        }
    }

    mutating func add(_ bytes: Data) {
        add(UInt64(bytes.count))
        for byte in bytes { value = (value ^ UInt64(byte)) &* 1_099_511_628_211 }
    }

    mutating func add(_ text: String) {
        add(UInt64(text.utf8.count))
        for byte in text.utf8 { value = (value ^ UInt64(byte)) &* 1_099_511_628_211 }
    }

    var hex: String { String(value, radix: 16) }
}

private struct RuleCount: Equatable, Sendable {
    let id: String
    let count: Int

    var json: [String: Any] { ["id": id, "count": count] }
}

private struct Summary: Equatable, Sendable {
    let checksum: String
    let outputRows: Int
    let hiddenCount: Int
    let mediaPaths: Int
    let thumbnails: Int
    let ruleCounts: [RuleCount]

    var json: [String: Any] {
        [
            "checksum": checksum, "output_rows": outputRows, "hidden_count": hiddenCount,
            "media_paths": mediaPaths, "thumbnails": thumbnails,
            "rule_counts": ruleCounts.map(\.json),
        ]
    }
}

private func nullable<T>(_ value: T?) -> Any {
    if let value { return value }
    return NSNull()
}

private func matchTrace(_ match: SourceVisibilityHideMatch) -> [String: Any] {
    switch match {
    case .manual:
        return ["kind": "manual"]
    case .noMedia:
        return ["kind": "noMedia"]
    case let .regex(rule):
        return ["kind": "regex", "id": rule.id, "color_index": rule.colorIndex]
    }
}

private func visibilityTrace(_ visibility: SourceRowVisibility?) -> Any {
    guard let visibility else { return NSNull() }
    return [
        "is_inherited": visibility.isInherited,
        "matches": visibility.matches.map(matchTrace),
    ] as [String: Any]
}

private func recognitionTrace(_ media: RecognizedMediaName?) -> Any {
    guard let media else { return NSNull() }
    return [
        "kind": media.kind.rawValue, "title": media.title, "year": nullable(media.year),
        "season": nullable(media.season), "episode": nullable(media.episode),
        "last_episode": nullable(media.lastEpisode), "air_date": nullable(media.airDate),
        "episode_title": nullable(media.episodeTitle), "edition": nullable(media.edition),
        "variant": nullable(media.variant), "catalog_ids": media.catalogIDs,
        "metadata_sources": media.metadataSources,
    ] as [String: Any]
}

private func rowTrace(_ row: SourceTreeDisplayRow) -> [String: Any] {
    let kind: [String: Any]
    switch row.kind {
    case let .folder(isRoot):
        kind = ["name": "folder", "is_root": isRoot]
    case let .media(dateAdded):
        // Preserve exact Double values, without decimal/JSON-number rounding.
        kind = ["name": "media", "date_added_bits": nullable(
            dateAdded.map { String($0.timeIntervalSince1970.bitPattern) }
        )]
    case let .message(message):
        kind = ["name": "message", "message": message]
    case .mediaSection:
        kind = ["name": "mediaSection"]
    }
    return [
        "id": row.id, "folder_id": row.folderID, "url": row.url.absoluteString,
        "display_name": row.displayName, "context_label": nullable(row.contextLabel),
        "recognized_media": recognitionTrace(row.recognizedMedia),
        "visibility_path": nullable(row.visibilityPath), "depth": row.depth,
        "ancestor_ids": row.ancestorIDs, "kind": kind,
        "visibility": visibilityTrace(row.visibility),
        "contains_supported_media": nullable(row.containsSupportedMedia),
    ]
}

private func projectionTrace(_ projection: SourceBrowserProjection) -> [String: Any] {
    [
        "rows": projection.rows.map(rowTrace),
        "hidden_count": projection.hiddenCount,
        "regex_counts": projection.regexCounts.keys.sorted().map {
            RuleCount(id: $0, count: projection.regexCounts[$0]!).json
        },
        "thumbnail_candidates": projection.thumbnailCandidates.map(\.absoluteString),
        "media_paths": projection.mediaPaths.sorted(),
    ]
}

private func canonicalJSON(_ value: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
}

private func summarize(
    _ projection: SourceBrowserProjection, trace: [String: Any]
) throws -> Summary {
    var digest = StableDigest()
    digest.add(try canonicalJSON(trace))
    return Summary(
        checksum: digest.hex, outputRows: projection.rows.count, hiddenCount: projection.hiddenCount,
        mediaPaths: projection.mediaPaths.count, thumbnails: projection.thumbnailCandidates.count,
        ruleCounts: projection.regexCounts.keys.sorted().map {
            RuleCount(id: $0, count: projection.regexCounts[$0]!)
        }
    )
}

private func consume(_ projection: SourceBrowserProjection) throws -> Summary {
    // Every field of every returned row and projection is read. This complete
    // snapshot/encoding is intentionally outside the projection timers.
    try summarize(projection, trace: projectionTrace(projection))
}

private enum HarnessFailure: Error {
    case invalidArguments
    case clockUnavailable
    case inconsistentOutput
    case unexpectedCacheUse
}

private func cpuNanoseconds() throws -> UInt64 {
    var value = timespec()
    guard clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &value) == 0 else {
        throw HarnessFailure.clockUnavailable
    }
    return UInt64(value.tv_sec) * 1_000_000_000 + UInt64(value.tv_nsec)
}

private struct Sample: Sendable {
    let wall: UInt64
    let cpu: UInt64
    let summary: Summary
}

private func measure(_ fixture: Fixture) async throws -> Sample {
    let filter = SourceBrowserFilter()
    let cpuStart = try cpuNanoseconds()
    let wallStart = DispatchTime.now().uptimeNanoseconds
    let projected = await filter.project(
        rows: fixture.rows, configuration: fixture.configuration, roots: fixture.roots,
        revealsRulePreview: false, query: ""
    )
    let wall = DispatchTime.now().uptimeNanoseconds - wallStart
    let cpu = try cpuNanoseconds() - cpuStart
    guard let projected else { throw CancellationError() }
    let summary = try consume(projected)
    guard await filter.visibilityBuildCount == 1, await filter.treeBuildCount == 0 else {
        throw HarnessFailure.unexpectedCacheUse
    }
    // The actor and returned projection remain alive until all sampling and
    // output consumption finish; their destruction is outside the timers.
    withExtendedLifetime((filter, projected)) {}
    return Sample(wall: wall, cpu: cpu, summary: summary)
}

private func warmup(_ fixture: Fixture) async throws -> Summary {
    let filter = SourceBrowserFilter()
    guard let projected = await filter.project(
        rows: fixture.rows, configuration: fixture.configuration, roots: fixture.roots,
        revealsRulePreview: false, query: ""
    ) else { throw CancellationError() }
    return try consume(projected)
}

@main
private struct SourceVisibilityRegexBenchmark {
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count >= 4, ["verify", "measure"].contains(args[1]),
              Fixture.cases.contains(args[2]), let size = Int(args[3]), size >= 0,
              size <= 1_000_000 else { throw HarnessFailure.invalidArguments }
        let mode = args[1], scenario = args[2]
        let fixture = Fixture(size: size, scenario: scenario)

        if mode == "verify" {
            guard args.count == 4 else { throw HarnessFailure.invalidArguments }
            let filter = SourceBrowserFilter()
            guard let projected = await filter.project(
                rows: fixture.rows, configuration: fixture.configuration, roots: fixture.roots,
                revealsRulePreview: false, query: ""
            ) else { throw CancellationError() }
            let trace = projectionTrace(projected)
            let summary = try summarize(projected, trace: trace)
            var result = summary.json
            result["mode"] = mode
            result["case"] = scenario
            result["size"] = size
            result["projection"] = trace
            print(String(decoding: try canonicalJSON(result), as: UTF8.self))
            return
        }

        guard args.count == 5, let iterations = Int(args[4]), iterations > 0 else {
            throw HarnessFailure.invalidArguments
        }
        // Warm process-global Foundation/runtime paths without warming any
        // measured actor's visibility cache.
        let expected = try await warmup(fixture)
        guard try await warmup(fixture) == expected else {
            throw HarnessFailure.inconsistentOutput
        }
        var wallSamples: [UInt64] = []
        var cpuSamples: [UInt64] = []
        wallSamples.reserveCapacity(iterations)
        cpuSamples.reserveCapacity(iterations)
        var combined = StableDigest()
        for _ in 0..<iterations {
            let sample = try await measure(fixture)
            guard sample.summary == expected else { throw HarnessFailure.inconsistentOutput }
            wallSamples.append(sample.wall)
            cpuSamples.append(sample.cpu)
            combined.add(sample.summary.checksum)
        }
        var result = expected.json
        result["mode"] = mode
        result["case"] = scenario
        result["size"] = size
        result["iterations"] = iterations
        result["wall_ns"] = wallSamples.reduce(0, +)
        result["cpu_ns"] = cpuSamples.reduce(0, +)
        result["wall_samples_ns"] = wallSamples
        result["cpu_samples_ns"] = cpuSamples
        result["combined_checksum"] = combined.hex
        result["warmup_checksum"] = expected.checksum
        print(String(decoding: try canonicalJSON(result), as: UTF8.self))
    }
}
