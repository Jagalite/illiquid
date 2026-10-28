import Darwin
import Foundation
@testable import IlliquidApp

private struct Fixture {
    let roots: [URL]
    let paths: [String]
    let rows: [SourceTreeDisplayRow]
    let configurations: [SourceVisibilityConfiguration]
    let isProjection: Bool

    init(scenario: String, size: Int) {
        isProjection = scenario.hasPrefix("project-")
        let base = "/Volumes/Root Selection Study"
        let count: Int
        switch scenario {
        case "lookup-empty": count = 0
        case "lookup-eight", "lookup-miss", "lookup-unicode", "project-files-many": count = 8
        case "lookup-sixtyfour", "project-tree-many": count = 64
        case "lookup-nested": count = 8
        default: count = 1
        }
        let rootPaths: [String]
        if scenario == "lookup-nested" {
            rootPaths = (0..<count).map { depth in
                base + (0...depth).map { "/Level \($0)" }.joined()
            }
        } else if scenario == "lookup-unicode" {
            rootPaths = (0..<count).map { base + "/\u{00c9}missions \($0)/\u{1f3ac}" }
        } else {
            rootPaths = (0..<count).map { base + "/Library \($0)" }
        }
        // Nested roots are deliberately not ordered by specificity.
        let order = scenario == "lookup-nested" ? [2, 6, 0, 4, 7, 1, 5, 3] : Array(rootPaths.indices)
        roots = order.map { URL(fileURLWithPath: rootPaths[$0], isDirectory: true) }
        paths = (0..<size).map { index in
            if scenario == "lookup-exact" { return rootPaths[0] }
            var root = rootPaths.isEmpty ? base : rootPaths[index % rootPaths.count]
            if scenario == "lookup-miss" { root = base + "/Outside \(index % 8)" }
            if scenario == "lookup-unicode", index % 2 == 1 {
                root = root.replacingOccurrences(of: "\u{00c9}", with: "E\u{0301}")
            }
            let leaf = scenario == "lookup-unicode" ? "E\u{0301}pisode \u{1f469}\u{200d}\u{1f4bb} \(index).mkv" : "Episode \(index).mkv"
            return root + "/Series \(index % 29)/Season 01/" + leaf
        }
        rows = paths.enumerated().map { index, path in
            SourceTreeDisplayRow(
                id: "media:\(index)", folderID: "\(base)/folder",
                url: URL(fileURLWithPath: path, isDirectory: false),
                displayName: "Episode \(index)", visibilityPath: path,
                depth: 0, ancestorIDs: [], kind: .media(dateAdded: nil))
        }
        var configuration = SourceVisibilityConfiguration.default
        if scenario.hasPrefix("project-files") { configuration.viewMode = .filesOnly }
        if scenario != "project-no-rules" {
            configuration.regexRules = [
                .init(id: "miss", pattern: "^__does_not_match_A__$", colorIndex: 0, isEnabled: true),
            ]
        }
        var other = configuration
        if scenario == "project-no-rules" {
            other.showsHiddenItems = true
        } else {
            other.regexRules[0] = .init(
                id: "miss", pattern: "^__does_not_match_B__$", colorIndex: 0, isEnabled: true)
        }
        configurations = [configuration, other]
    }
}

private func wallTime() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

private func cpuTime() -> UInt64 {
    var value = timespec()
    precondition(clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &value) == 0)
    return UInt64(value.tv_sec) * 1_000_000_000 + UInt64(value.tv_nsec)
}

private func hideMatches(_ values: [SourceVisibilityHideMatch]) -> [String] {
    values.map {
        switch $0 {
        case .manual: return "manual"
        case .noMedia: return "noMedia"
        case .regex(let match): return "regex:\(match.id):\(match.colorIndex)"
        }
    }
}

private func evaluation(_ value: SourceVisibilityEvaluation) -> [String: Any] {
    ["hidden": hideMatches(value.hiddenMatches),
     "regex": value.regexMatches.map { "\($0.id):\($0.colorIndex)" }]
}

private func projection(_ value: SourceBrowserProjection) -> [String: Any] {
    let records: [[String: Any]] = value.rows.map { row in
        // The fixture contains media rows without recognition/annotations.
        // The complete existing regression suites cover the richer row types.
        precondition(row.recognizedMedia == nil && row.contextLabel == nil)
        var result: [String: Any] = [
            "id": row.id, "folder_id": row.folderID, "url": row.url.absoluteString,
            "name": row.displayName, "depth": row.depth, "ancestors": row.ancestorIDs,
            "visibility_path": row.visibilityPath as Any? ?? NSNull(),
            "supported_media": row.containsSupportedMedia as Any? ?? NSNull(),
        ]
        switch row.kind {
        case .media(let date): result["kind"] = "media"; result["date"] = date?.timeIntervalSince1970 as Any? ?? NSNull()
        case .folder(let isRoot): result["kind"] = "folder"; result["root"] = isRoot
        case .message(let message): result["kind"] = "message"; result["message"] = message
        case .mediaSection: result["kind"] = "section"
        }
        if let visibility = row.visibility {
            result["visibility"] = hideMatches(visibility.matches)
            result["inherited"] = visibility.isInherited
        } else {
            result["visibility"] = NSNull()
        }
        return result
    }
    return ["rows": records, "hidden_count": value.hiddenCount,
            "regex_counts": value.regexCounts, "media_paths": value.mediaPaths.sorted(),
            "thumbnails": value.thumbnailCandidates.map(\.absoluteString)]
}

private func encode(_ value: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
}

private func fingerprint(_ value: Any) throws -> String {
    let bytes = try encode(value)
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in bytes { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
    return String(hash, radix: 16)
}

@main
private struct SourceRootBenchmark {
    static func main() async throws {
        let args = CommandLine.arguments
        precondition(args.count == 5)
        let mode = args[1], scenario = args[2]
        precondition(mode == "verify" || mode == "measure")
        let size = Int(args[3])!, iterations = Int(args[4])!
        precondition(size > 0 && iterations > 0)
        let fixture = Fixture(scenario: scenario, size: size)
        var checksum: UInt64 = 0
        let elapsed: UInt64, cpu: UInt64
        let receipt: [String: Any]

        if fixture.isProjection {
            let filter = SourceBrowserFilter()
            // Warm Foundation/regex initialization and the actor before timing.
            for index in [0, 1] {
                _ = await filter.project(rows: fixture.rows, configuration: fixture.configurations[index],
                                         roots: fixture.roots, revealsRulePreview: false, query: "")
            }
            let startCPU = cpuTime(), start = wallTime()
            for index in 0..<iterations {
                guard let output = await filter.project(
                    rows: fixture.rows, configuration: fixture.configurations[index % 2],
                    roots: fixture.roots, revealsRulePreview: false, query: "")
                else { throw CancellationError() }
                checksum &+= UInt64(output.rows.count + output.hiddenCount
                                    + output.mediaPaths.count + output.thumbnailCandidates.count)
            }
            elapsed = wallTime() - start
            cpu = cpuTime() - startCPU
            let buildCount = await filter.visibilityBuildCount
            precondition(buildCount == iterations + 2)
            guard let output = await filter.project(
                rows: fixture.rows, configuration: fixture.configurations[(iterations - 1) % 2],
                roots: fixture.roots, revealsRulePreview: false, query: "")
            else { throw CancellationError() }
            receipt = projection(output)
        } else {
            let matcher = SourceVisibilityMatcher(configuration: fixture.configurations[0], roots: fixture.roots)
            for path in fixture.paths { _ = matcher.relativePath(normalizedPath: path) }
            let startCPU = cpuTime(), start = wallTime()
            for _ in 0..<iterations {
                for path in fixture.paths {
                    checksum &+= UInt64(matcher.relativePath(normalizedPath: path).utf8.count)
                }
            }
            elapsed = wallTime() - start
            cpu = cpuTime() - startCPU
            receipt = [
                "relative_paths": fixture.paths.map { matcher.relativePath(normalizedPath: $0) },
                "direct": fixture.paths.map { evaluation(matcher.evaluate(normalizedPath: $0)) },
                "ancestors": fixture.paths.map { evaluation(matcher.evaluateIncludingAncestors(normalizedPath: $0)) },
            ]
        }
        var output: [String: Any] = [
            "scenario": scenario, "size": size, "iterations": iterations,
            "operations": fixture.isProjection ? iterations : iterations * size,
            "wall_ns": elapsed, "cpu_ns": cpu, "checksum": String(checksum),
            "fingerprint": try fingerprint(receipt),
        ]
        if mode == "verify" { output["receipt"] = receipt }
        print(String(decoding: try encode(output), as: UTF8.self))
    }
}
