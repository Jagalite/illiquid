import Foundation
import IlliquidCore
@testable import IlliquidApp
#if os(Linux)
import Glibc
#else
import Darwin
#endif

// Production matcher and row builder execute in the separate IlliquidApp
// target. Fixture preparation, warmup and complete parity receipts are untimed.
// Synthetic paths are lexical only: no user files or filesystem walks are used.
private struct BenchmarkCase: Sendable {
    let name: String
    let rootCount: Int
    let kind: String
    var operationsPerIteration: Int {
        kind == "relative" || kind == "evaluate" ? 64 : 1
    }

    var record: [String: Any] {
        let detail: String
        switch kind {
        case "relative":
            detail = "64 prepared-matcher queries; mixed early/middle/late roots, exact roots, sibling prefixes and misses"
        case "evaluate":
            detail = "64 prepared-matcher ancestor evaluations with three regex rules and manual/always-shown paths"
        case "construct_relative":
            detail = "Construct one matcher with no regex rules, query eight mixed paths, then release it"
        default:
            detail = "Complete filesOnly rows() for 10,000 shuffled entries, including name sorting and matcher construction"
        }
        return ["name": name, "root_count": rootCount, "kind": kind,
                "operations_per_iteration": operationsPerIteration,
                "description": detail, "stress": rootCount == 256,
                "unit": kind == "relative" || kind == "evaluate" ? "query" :
                    kind == "rows" ? "10000-row listing" : "construction plus eight queries"]
    }
}

private let benchmarkCases: [BenchmarkCase] =
    [0, 1, 8, 64, 256].map { BenchmarkCase(name: "relative_r\($0)", rootCount: $0, kind: "relative") }
    + [1, 8, 64, 256].map { BenchmarkCase(name: "evaluate_r\($0)", rootCount: $0, kind: "evaluate") }
    + [1, 64].map { BenchmarkCase(name: "construct_relative_r\($0)", rootCount: $0, kind: "construct_relative") }
    + [1, 8, 64].map { BenchmarkCase(name: "rows_r\($0)", rootCount: $0, kind: "rows") }

private func makeRoots(_ count: Int) -> [URL] {
    (0..<count).map { index in
        let suffix: String
        switch index % 8 {
        case 0: suffix = "Series α\(index)"
        case 1: suffix = "Series α\(index - 1)/Season 01"
        case 2: suffix = "日本語 \(index)"
        case 3: suffix = "Cafe\u{301} \(index)"
        default: suffix = "Library \(index)"
        }
        return URL(fileURLWithPath: "/Volumes/Root Matching/" + suffix, isDirectory: true)
    }
}

private struct MatcherFixture {
    let roots: [URL]
    let paths: [String]
    let configuration: SourceVisibilityConfiguration
    let matcher: SourceVisibilityMatcher

    init(rootCount: Int, rules: Bool) {
        let roots = makeRoots(rootCount)
        let rootPaths = roots.compactMap(SourceVisibilityPath.normalized)
        let first = rootPaths.first ?? "/Volumes/Root Matching/No Roots"
        let middle = rootPaths.isEmpty ? first : rootPaths[rootPaths.count / 2]
        let last = rootPaths.last ?? first
        let paths = (0..<64).map { index in
            switch index % 8 {
            case 0: return first + "/Season A/Episode \(index).mkv"
            case 1: return middle + "/Nested/Trailer \(index).mkv"
            case 2: return last + "/Private/Keep \(index).mkv"
            case 3: return "/Volumes/Outside/Unwatched/Feature \(index).mkv"
            case 4: return first
            case 5: return last + "-sibling/Sub/Feature \(index).mkv"
            case 6: return middle + "/深い/第二/Épisode \(index).mkv"
            default: return first + "/Hidden/Feature \(index).mkv"
            }
        }
        var configuration = SourceVisibilityConfiguration.default
        configuration.viewMode = .filesOnly
        if rules {
            configuration.regexRules = [
                .init(id: "trailers", pattern: "Trailer", colorIndex: 2, isEnabled: true),
                .init(id: "hidden", pattern: "(^|/)Hidden(/|$)", colorIndex: 4, isEnabled: true),
                .init(id: "root", pattern: "^Series", colorIndex: 1, isEnabled: true),
            ]
            configuration.manuallyHiddenPaths = [last + "/Private"]
            configuration.alwaysShownPaths = [paths[2]]
        }
        self.roots = roots
        self.paths = paths
        self.configuration = configuration
        matcher = SourceVisibilityMatcher(configuration: configuration, roots: roots)
    }
}

private func makeRowInput(rootCount: Int, count: Int = 10_000) -> SourceTreeProjectionInput {
    let roots = makeRoots(rootCount)
    precondition(!roots.isEmpty)
    var entries = (0..<count).map { index -> SourceTreeEntry in
        let root = roots[index % roots.count]
        let base: URL
        if index % 10 == 0 {
            base = URL(fileURLWithPath: "/Volumes/Outside/Unwatched", isDirectory: true)
        } else if index % 17 == 0 {
            base = URL(fileURLWithPath: root.path + "-sibling", isDirectory: true)
        } else {
            base = root
        }
        let url = base.appendingPathComponent("Section \(index % 19)", isDirectory: true)
            .appendingPathComponent("Season 01", isDirectory: true)
            .appendingPathComponent("Clip \(index) Épisode.mkv", isDirectory: false)
        return SourceTreeEntry(url: url, kind: .media,
            dateAdded: index % 7 == 0 ? nil : Date(timeIntervalSince1970: Double(1_700_000_000 + index)),
            creationDate: Date(timeIntervalSince1970: Double(1_600_000_000 + index)),
            visibilityPath: SourceVisibilityPath.normalized(url))
    }
    var random: UInt64 = 0x726f_6f74_6d61_7463
    if entries.count > 1 {
        for index in stride(from: entries.count - 1, through: 1, by: -1) {
            random = random &* 6_364_136_223_846_793_005 &+ 1
            entries.swapAt(index, Int(random % UInt64(index + 1)))
        }
    }
    var visibility = SourceVisibilityConfiguration.default
    visibility.viewMode = .filesOnly
    return SourceTreeProjectionInput(items: roots.map { .init(kind: .folder, url: $0) },
        visibility: visibility, roots: roots, directoryContents: [:], directoryErrors: [:],
        recursiveMediaEntries: entries, expandedFolderIDs: [],
        sortConfiguration: .init(name: .ascending, dateCreated: .off, type: .off))
}

private func nullable<T>(_ value: T?) -> Any { value.map { $0 as Any } ?? NSNull() }

private func recognitionTrace(_ media: RecognizedMediaName) -> [String: Any] {
    ["kind": media.kind.rawValue, "title": media.title, "year": nullable(media.year),
     "season": nullable(media.season), "episode": nullable(media.episode),
     "lastEpisode": nullable(media.lastEpisode), "airDate": nullable(media.airDate),
     "episodeTitle": nullable(media.episodeTitle), "edition": nullable(media.edition),
     "catalogIDs": media.catalogIDs, "variant": nullable(media.variant),
     "metadataSources": media.metadataSources]
}

private func matchTrace(_ match: SourceVisibilityHideMatch) -> [String: Any] {
    switch match {
    case .manual: ["kind": "manual"]
    case .noMedia: ["kind": "noMedia"]
    case let .regex(value): ["kind": "regex", "id": value.id, "colorIndex": value.colorIndex]
    }
}

private func rowTrace(_ row: SourceTreeDisplayRow) -> [String: Any] {
    let kind: [String: Any]
    switch row.kind {
    case let .folder(isRoot): kind = ["name": "folder", "isRoot": isRoot]
    case let .media(date):
        kind = ["name": "media", "dateAddedBits": nullable(date.map {
            String($0.timeIntervalSinceReferenceDate.bitPattern)
        })]
    case let .message(message): kind = ["name": "message", "message": message]
    case .mediaSection: kind = ["name": "mediaSection"]
    }
    return ["id": row.id, "folderID": row.folderID,
            "url": ["absolute": row.url.absoluteString, "relative": row.url.relativeString,
                    "base": nullable(row.url.baseURL?.absoluteString)],
            "displayName": row.displayName, "contextLabel": nullable(row.contextLabel),
            "recognizedMedia": nullable(row.recognizedMedia.map(recognitionTrace)),
            "visibilityPath": nullable(row.visibilityPath), "depth": row.depth,
            "ancestorIDs": row.ancestorIDs, "kind": kind,
            "visibility": nullable(row.visibility.map {
                ["matches": $0.matches.map(matchTrace), "isInherited": $0.isInherited] as [String: Any]
            }), "containsSupportedMedia": nullable(row.containsSupportedMedia)]
}

private func evaluationTrace(_ value: SourceVisibilityEvaluation) -> [String: Any] {
    ["hiddenMatches": value.hiddenMatches.map(matchTrace),
     "regexMatches": value.regexMatches.map { ["id": $0.id, "colorIndex": $0.colorIndex] as [String: Any] }]
}

private func matcherTrace(roots: [URL], paths: [String],
                          configuration: SourceVisibilityConfiguration) -> [String: Any] {
    let matcher = SourceVisibilityMatcher(configuration: configuration, roots: roots)
    let values: [[String: Any]] = paths.map { path in
        let url = URL(fileURLWithPath: path, isDirectory: false)
        return ["path": path, "relative": matcher.relativePath(normalizedPath: path),
                "relativeURL": matcher.relativePath(for: url),
                "direct": evaluationTrace(matcher.evaluate(normalizedPath: path)),
                "ancestors": evaluationTrace(matcher.evaluateIncludingAncestors(normalizedPath: path)),
                "directURL": evaluationTrace(matcher.evaluate(url)),
                "ancestorsURL": evaluationTrace(matcher.evaluateIncludingAncestors(url))]
    }
    let remote = URL(string: "https://example.invalid/Library/Trailer.mkv")!
    return ["roots": roots.map(\.absoluteString), "paths": values,
            "remote": ["relative": matcher.relativePath(for: remote),
                       "direct": evaluationTrace(matcher.evaluate(remote)),
                       "ancestors": evaluationTrace(matcher.evaluateIncludingAncestors(remote))]]
}

private func verify() -> [String: Any] {
    var matcherReceipts: [[String: Any]] = []
    for count in [0, 1, 8, 64, 256] {
        for rules in [false, true] {
            let fixture = MatcherFixture(rootCount: count, rules: rules)
            matcherReceipts.append(["name": "roots\(count)-rules\(rules)",
                "trace": matcherTrace(roots: fixture.roots, paths: fixture.paths,
                                      configuration: fixture.configuration)])
        }
    }

    // Canonically equivalent root *keys* cannot coexist in the baseline's
    // Dictionary. Exercise NFC/NFD path spellings with only one key per root.
    let roots = [
        URL(fileURLWithPath: "/Archive/Films", isDirectory: true),
        URL(fileURLWithPath: "/Archive/Films/Season", isDirectory: true),
        URL(fileURLWithPath: "/Archive/FilmsExtra", isDirectory: true),
        URL(fileURLWithPath: "/Archive/Café", isDirectory: true),
        URL(fileURLWithPath: "/Archive/Other/Cafe\u{301}", isDirectory: true),
        URL(string: "https://example.invalid/Ignored")!,
    ]
    let paths = [
        "/Archive/Films", "/Archive/Films/Sub/movie.mkv",
        "/Archive/Films/Season/movie.mkv", "/Archive/Films/Season/Sub/movie.mkv",
        "/Archive/FilmsSibling/Sub/movie.mkv", "/Archive/FilmsExtra/Sub/movie.mkv",
        "/Archive/Café/Épisode.mkv", "/Archive/Cafe\u{301}/E\u{301}pisode.mkv",
        "/Archive/Other/Café/Épisode.mkv", "/Archive/Other/Cafe\u{301}/Épisode.mkv",
        "/Outside/Sub/movie.mkv", "/", "/Archive",
    ]
    let plain = SourceVisibilityMatcher(configuration: .default, roots: roots)
    precondition(plain.relativePath(normalizedPath: paths[1]) == "Sub/movie.mkv")
    precondition(plain.relativePath(normalizedPath: paths[2]) == "movie.mkv")
    precondition(plain.relativePath(normalizedPath: paths[3]) == "Sub/movie.mkv")
    precondition(plain.relativePath(normalizedPath: paths[4]) == "movie.mkv")

    var configured = SourceVisibilityConfiguration.default
    configured.viewMode = .filesOnly
    configured.manuallyHiddenPaths = ["/Archive/Films"]
    configured.alwaysShownPaths = ["/Archive/Films/Sub/movie.mkv"]
    configured.regexRules = [
        .init(id: "movie", pattern: "\\.mkv$", colorIndex: 0, isEnabled: true),
        .init(id: "folder", pattern: "^(Films|Café)", colorIndex: 3, isEnabled: true),
        .init(id: "disabled", pattern: ".*", colorIndex: 2, isEnabled: false),
        .init(id: "invalid", pattern: "[", colorIndex: 5, isEnabled: true),
    ]
    let manual = SourceVisibilityMatcher(configuration: configured, roots: roots)
    precondition(manual.evaluate(normalizedPath: paths[1]).hiddenMatches.isEmpty)
    let inherited = manual.evaluateIncludingAncestors(normalizedPath: paths[1])
    precondition(inherited.hiddenMatches.first == .manual)
    precondition(inherited.regexMatches.map(\.id) == ["movie", "folder"])

    var changed = configured
    changed.manuallyHiddenPaths = []
    changed.alwaysShownPaths = ["/Archive/Films"]
    changed.regexRules[0].isEnabled = false
    let rootSets = [
        ("boundaries", roots),
        ("reordered", Array(roots.reversed())),
        ("filesystem-root", [URL(fileURLWithPath: "/", isDirectory: true)] + roots),
        ("changed-roots", Array(roots.dropFirst(2))),
    ]
    for (name, set) in rootSets {
        for (index, configuration) in [SourceVisibilityConfiguration.default, configured, changed].enumerated() {
            matcherReceipts.append(["name": "\(name)-configuration\(index)",
                "trace": matcherTrace(roots: set, paths: paths, configuration: configuration)])
        }
    }

    let rowReceipts: [[String: Any]] = [1, 8, 64].map { rootCount in
        let rows = makeRowInput(rootCount: rootCount).rows()
        precondition(rows.count == 10_000)
        precondition(Set(rows.map(\.id)).count == rows.count)
        return ["root_count": rootCount, "rows": rows.map(rowTrace)]
    }
    return ["schema_version": 1, "matcher_receipts": matcherReceipts, "row_receipts": rowReceipts]
}

@inline(never)
private func consume(_ value: String) -> UInt64 {
    UInt64(value.utf8.count) &* 31
        &+ UInt64(value.utf8.first ?? 0) &+ UInt64(value.utf8.last ?? 0)
}

@inline(never)
private func consume(_ value: SourceVisibilityEvaluation) -> UInt64 {
    var result = UInt64(value.hiddenMatches.count)
    for match in value.hiddenMatches {
        switch match {
        case .manual: result = result &* 31 &+ 1
        case .noMedia: result = result &* 31 &+ 2
        case let .regex(rule): result = result &* 31 &+ consume(rule.id) &+ UInt64(rule.colorIndex)
        }
    }
    for rule in value.regexMatches {
        result = result &* 31 &+ consume(rule.id) &+ UInt64(rule.colorIndex)
    }
    return result
}

@inline(never)
private func consume(_ rows: [SourceTreeDisplayRow]) -> UInt64 {
    var result = UInt64(rows.count)
    for row in rows {
        result &+= consume(row.id)
        if let context = row.contextLabel { result &+= consume(context) }
    }
    return result
}

private func measure(_ testCase: BenchmarkCase, iterations: Int) -> [String: Any] {
    let fixture = MatcherFixture(rootCount: testCase.rootCount, rules: testCase.kind == "evaluate")
    let rowInput = testCase.kind == "rows" ? makeRowInput(rootCount: testCase.rootCount) : nil
    if let rowInput { precondition(rowInput.rows().count == 10_000) }
    func iteration() -> UInt64 {
        var result: UInt64 = 0
        switch testCase.kind {
        case "relative":
            for path in fixture.paths { result &+= consume(fixture.matcher.relativePath(normalizedPath: path)) }
        case "evaluate":
            for path in fixture.paths { result &+= consume(fixture.matcher.evaluateIncludingAncestors(normalizedPath: path)) }
        case "construct_relative":
            let matcher = SourceVisibilityMatcher(configuration: fixture.configuration, roots: fixture.roots)
            for path in fixture.paths.prefix(8) { result &+= consume(matcher.relativePath(normalizedPath: path)) }
        case "rows":
            result = consume(rowInput!.rows())
        default:
            preconditionFailure("Unknown workload")
        }
        return result
    }
    // Keep warmup observable, but separate its checksum and duration.
    var warmup: UInt64 = 0
    for _ in 0..<2 { warmup &+= iteration() }
    var checksum: UInt64 = 0
    let cpuStart = clock()
    let start = DispatchTime.now().uptimeNanoseconds
    for _ in 0..<iterations { checksum &+= iteration() }
    let wall = DispatchTime.now().uptimeNanoseconds - start
    let cpu = Double(clock() - cpuStart) / Double(CLOCKS_PER_SEC) * 1_000_000_000
    return ["case": testCase.name, "iterations": iterations,
            "operations_per_iteration": testCase.operationsPerIteration,
            "operation_count": iterations * testCase.operationsPerIteration,
            "wall_ns": wall, "cpu_ns": cpu, "checksum": String(checksum),
            "warmup_iterations": 2, "warmup_checksum": String(warmup)]
}

@main
private enum SourceRootMatchingBenchmark {
    static func main() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        let result: Any
        if args == ["cases"] {
            result = benchmarkCases.map(\.record)
        } else if args == ["verify"] {
            result = verify()
        } else {
            precondition(args.count == 3 && args[0] == "measure",
                         "Usage: cases | verify | measure CASE ITERATIONS")
            guard let selected = benchmarkCases.first(where: { $0.name == args[1] }),
                  let iterations = Int(args[2]), iterations > 0,
                  iterations <= 1_000_000 else { preconditionFailure("Invalid workload or iteration count") }
            result = measure(selected, iterations: iterations)
        }
        let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
