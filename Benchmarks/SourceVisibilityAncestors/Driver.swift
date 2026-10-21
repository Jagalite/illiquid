import Foundation
@testable import IlliquidApp

private struct Fixture: Sendable {
    let name: String
    let paths: [String]
    let rows: [SourceTreeDisplayRow]
    let roots: [URL]
    let configuration: SourceVisibilityConfiguration
}

private struct Outcome: Sendable {
    var evaluations: [SourceVisibilityEvaluation] = []
    var projection: SourceBrowserProjection?

    var count: Int { projection?.rows.count ?? evaluations.count }
    var hiddenCount: Int {
        projection?.hiddenCount ?? evaluations.reduce(0) { $0 + ($1.hiddenMatches.isEmpty ? 0 : 1) }
    }
}

@main
struct AncestorBenchmark {
    static let cases = [
        "shared_one_rule", "shared_eight_rules", "deep_shared", "nearest_hidden",
        "unique_parents", "manual_only", "no_rules", "tree_control", "unicode", "small_library",
    ]

    private static func fixture(_ name: String, small: Bool = false) -> Fixture {
        precondition(cases.contains(name))
        let count = name == "small_library" ? 100 : small ? (name == "unique_parents" ? 1300 : 80) :
            (name == "deep_shared" ? 2500 : (name == "unique_parents" ? 2000 : 5000))
        let groups = name == "unique_parents" ? count : (small || name == "small_library" ? 4 : 50)
        let depth = name == "deep_shared" ? 10 : 3
        let root = URL(fileURLWithPath: "/Volumes/Library", isDirectory: true)
        let patterns = [
            #"(?i)(^|/)(sample|trailer)[^/]*\.mkv$"#,
            #"(?i)(^|/)Extras$"#,
            #"(?i)(^|/)Proof$"#,
            #"(?i)behind[ ._-]the[ ._-]scenes"#,
            #"(?i)\.(txt|nfo|srt)$"#,
            #"(^|/)\.cache(/|$)"#,
            #"(?i)(^|/)temp(/|$)"#,
            #"(?i)unwanted[ ._-]release"#,
        ]
        var configuration = SourceVisibilityConfiguration.default
        configuration.viewMode = name == "tree_control" ? .tree : .filesOnly
        configuration.showsHiddenItems = true
        if name != "manual_only" && name != "no_rules" {
            let ruleCount = name == "shared_one_rule" || name == "small_library" ? 1 : 8
            configuration.regexRules = Array(patterns.prefix(ruleCount))
                .enumerated().map { index, pattern in
                    SourceVisibilityRegexRule(id: "rule-\(index)", pattern: pattern,
                                              colorIndex: index % 6, isEnabled: true)
                }
        }
        if name == "unicode" {
            configuration.regexRules.append(SourceVisibilityRegexRule(
                id: "composed", pattern: "Café", colorIndex: 1, isEnabled: true))
            configuration.regexRules.append(SourceVisibilityRegexRule(
                id: "decomposed", pattern: "Cafe\u{301}", colorIndex: 2, isEnabled: true))
        }
        var paths: [String] = []
        var rows: [SourceTreeDisplayRow] = []
        for index in 0..<count {
            let group = index % groups
            var parent = root.path + "/Collection-\(group)"
            for level in 0..<depth { parent += "/Level-\(level)" }
            if name == "nearest_hidden" { parent += "/Extras" }
            if name == "unicode" {
                parent += (index / groups) % 2 == 0 ? "/Café 日本語 %2F" : "/Cafe\u{301} 日本語 %2F"
            }
            if name == "manual_only", group % 5 == 0 {
                configuration.manuallyHiddenPaths.insert(parent)
            }
            let leaf = index % 29 == 0 ? "Sample-\(index).mkv" : "Episode-\(index).mkv"
            let path = parent + "/" + leaf
            paths.append(path)
            rows.append(SourceTreeDisplayRow(
                id: "media:\(path)", folderID: parent,
                url: URL(fileURLWithPath: path, isDirectory: false), displayName: leaf,
                visibilityPath: path, depth: 0, ancestorIDs: [], kind: .media(dateAdded: nil)))
        }
        return Fixture(name: name, paths: paths, rows: rows, roots: [root], configuration: configuration)
    }

    // A new matcher/cache is created for every pass, as in a real visibility
    // rebuild. Fixture generation and result serialization are outside timing.
    private static func run(_ fixture: Fixture, operation: String) async -> Outcome {
        if operation == "project" {
            let filter = SourceBrowserFilter()
            let projection = await filter.project(
                rows: fixture.rows, configuration: fixture.configuration,
                roots: fixture.roots, revealsRulePreview: false, query: "")
            precondition(projection != nil)
            return Outcome(projection: projection)
        }
        precondition(operation == "matcher")
        var matcher = SourceVisibilityMatcher(configuration: fixture.configuration, roots: fixture.roots)
        var evaluations: [SourceVisibilityEvaluation] = []
        evaluations.reserveCapacity(fixture.paths.count)
        for path in fixture.paths {
            evaluations.append(fixture.configuration.viewMode.scansRecursively
                ? matcher.evaluateIncludingAncestors(normalizedPath: path)
                : matcher.evaluate(normalizedPath: path))
        }
        return Outcome(evaluations: evaluations)
    }

    private static func match(_ value: SourceVisibilityRegexMatch) -> [String: Any] {
        ["id": value.id, "color": value.colorIndex]
    }

    private static func hidden(_ value: SourceVisibilityHideMatch) -> [String: Any] {
        switch value {
        case .manual: ["kind": "manual"]
        case .noMedia: ["kind": "noMedia"]
        case .regex(let value): ["kind": "regex", "match": match(value)]
        }
    }

    private static func evaluation(_ value: SourceVisibilityEvaluation) -> [String: Any] {
        ["hidden": value.hiddenMatches.map(hidden), "regex": value.regexMatches.map(match)]
    }

    private static func receipt(_ outcome: Outcome) -> [String: Any] {
        guard let projection = outcome.projection else {
            return ["evaluations": outcome.evaluations.map(evaluation)]
        }
        return [
            "rows": projection.rows.map { row -> [String: Any] in
                ["id": row.id, "url": row.url.absoluteString, "displayName": row.displayName,
                 "folderID": row.folderID, "depth": row.depth, "ancestors": row.ancestorIDs,
                 "visibilityPath": row.visibilityPath ?? "",
                 "hidden": row.visibility?.matches.map(hidden) ?? [],
                 "inherited": row.visibility?.isInherited ?? false]
            },
            "hiddenCount": projection.hiddenCount, "regexCounts": projection.regexCounts,
            "thumbnailCandidates": projection.thumbnailCandidates.map(\.absoluteString),
            "mediaPaths": projection.mediaPaths.sorted(),
        ]
    }

    private static func canonicalJSON(_ result: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
    }

    private static func emit(_ result: Any) throws {
        let data = try canonicalJSON(result)
        print(String(decoding: data, as: UTF8.self))
    }

    static func main() async throws {
        let args = CommandLine.arguments
        if args.count == 2 && args[1] == "parity" {
            var records: [[String: Any]] = []
            for name in cases {
                let input = fixture(name, small: true)
                for operation in ["matcher", "project"] {
                    let result = await run(input, operation: operation)
                    records.append(["case": name, "operation": operation,
                                    "input_count": input.rows.count, "receipt": receipt(result)])
                }
            }
            try emit(records)
            return
        }
        precondition(args.count == 4, "usage: benchmark parity | CASE OPERATION ITERATIONS")
        let input = fixture(args[1])
        let operation = args[2]
        let iterations = Int(args[3])!
        precondition(iterations > 0)
        let expected = await run(input, operation: operation)
        let expectedReceipt = try canonicalJSON(receipt(expected))
        var result = Outcome()
        var checksum = 0
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<iterations {
            result = await run(input, operation: operation)
            checksum &+= result.count
        }
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        let actual = receipt(result)
        // NSDictionary's bridging comparison can reject identical Swift Int
        // values on Linux. Compare the complete JSON representation instead;
        // both serializations remain outside the measured interval.
        let actualReceipt = try canonicalJSON(actual)
        precondition(actualReceipt == expectedReceipt)
        try emit(["case": input.name, "operation": operation, "input_count": input.rows.count,
                  "iterations": iterations, "elapsed_ns": elapsed, "checksum": checksum,
                  "receipt": actual])
    }
}
