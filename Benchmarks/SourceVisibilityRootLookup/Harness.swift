import Dispatch
import Foundation
import IlliquidCore
@testable import IlliquidApp
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// Production matcher, row construction, sorting, and browser actor are imported
// from a separately compiled module. All fixtures are in-memory URLs and values.
private enum Mode: String, Sendable { case projection, lookup, initialization }
private struct Scenario: Sendable {
    let name: String
    let description: String
    let mode: Mode
    let roots: Int
    let inputs: Int
}

private let scenarios: [Scenario] = [
    .init(name: "projection-files-8-roots-1024", description: "Cold files-only projection; 8 disjoint roots, 1024 entries, one visibility rule", mode: .projection, roots: 8, inputs: 1024),
    .init(name: "projection-files-32-roots-1024", description: "Cold files-only projection; 32 disjoint roots, 1024 entries, one visibility rule", mode: .projection, roots: 32, inputs: 1024),
    .init(name: "projection-files-unicode-32-roots-1024", description: "Cold files-only projection; 32 long Unicode roots, 1024 entries, one visibility rule", mode: .projection, roots: 32, inputs: 1024),
    .init(name: "matcher-one-root-1024", description: "Reused matcher; one root and 1024 relative-path lookups", mode: .lookup, roots: 1, inputs: 1024),
    .init(name: "matcher-nested-broad-first-1024", description: "Reused matcher; 32 nested roots in broad-first order, 1024 lookups", mode: .lookup, roots: 32, inputs: 1024),
    .init(name: "matcher-nested-deep-first-1024", description: "Reused matcher; 32 nested roots in deep-first order, 1024 lookups", mode: .lookup, roots: 32, inputs: 1024),
    .init(name: "matcher-no-match-32-roots-1024", description: "Reused matcher; 32 disjoint roots, 1024 unmatched paths", mode: .lookup, roots: 32, inputs: 1024),
    .init(name: "matcher-init-only-32-roots", description: "Construct and replace a matcher with 32 roots and no rules; final lookup is outside timing", mode: .initialization, roots: 32, inputs: 0),
    .init(name: "projection-no-rules-empty-32-roots", description: "Cold tree-mode projection; 32 roots, no rows or visibility rules", mode: .projection, roots: 32, inputs: 0),
    .init(name: "projection-no-rules-one-row-32-roots", description: "Cold tree-mode projection; 32 roots, one explicit file, no visibility rules", mode: .projection, roots: 32, inputs: 1),
    .init(name: "projection-files-one-row-32-roots", description: "Cold files-only projection; 32 roots, one entry and one visibility rule", mode: .projection, roots: 32, inputs: 1),
    .init(name: "projection-files-one-root-1024", description: "Cold files-only projection; one root, 1024 entries and one visibility rule", mode: .projection, roots: 1, inputs: 1024),
]

private struct Fixture: Sendable {
    let scenario: Scenario
    let roots: [URL]
    let paths: [String]
    let configuration: SourceVisibilityConfiguration
    let input: SourceTreeProjectionInput

    init(_ scenario: Scenario) {
        self.scenario = scenario
        let nested = scenario.name.contains("nested")
        var rootPaths = (0..<scenario.roots).map { index -> String in
            if nested {
                return "/Volumes/Benchmark Library" + (0...index).map { "/Level-\($0)" }.joined()
            }
            if scenario.name.contains("unicode") {
                return "/Volumes/メディア Collection/\(String(repeating: "Café 日本語 👩🏽‍💻 ", count: 3))/Root-\(index)"
            }
            return "/Volumes/Benchmark Library/Root-\(index)"
        }
        let deepest = rootPaths.last!
        if scenario.name.contains("deep-first") { rootPaths.reverse() }
        roots = rootPaths.map { URL(fileURLWithPath: $0, isDirectory: true) }
        paths = (0..<scenario.inputs).map { index in
            let root = scenario.name.contains("no-match") ? "/Unwatched/Root-\(index % 32)"
                : nested ? deepest : rootPaths[index % rootPaths.count]
            let trailer = index % 16 == 15 ? " Trailer" : ""
            return root + "/Season-\(index % 4)/Episode-\(index)\(trailer).mkv"
        }
        var configuration = SourceVisibilityConfiguration.default
        let treeControl = scenario.name.contains("projection-no-rules")
        if scenario.mode == .projection && !treeControl {
            configuration.viewMode = .filesOnly
            configuration.regexRules = [.init(id: "trailers", pattern: "Trailer", colorIndex: 2, isEnabled: true)]
        }
        self.configuration = configuration
        let entries = paths.enumerated().map { index, path in
            let url = URL(fileURLWithPath: path, isDirectory: false)
            return SourceTreeEntry(url: url, kind: .media,
                dateAdded: Date(timeIntervalSince1970: Double(1_700_000_000 + index)),
                creationDate: nil, visibilityPath: SourceVisibilityPath.normalized(url))
        }
        let items: [SourceTabItem] = treeControl
            ? paths.map { .init(kind: .file, url: URL(fileURLWithPath: $0, isDirectory: false)) }
            : roots.map { .init(kind: .folder, url: $0) }
        input = SourceTreeProjectionInput(items: items, visibility: configuration, roots: roots,
            directoryContents: [:], directoryErrors: [:], recursiveMediaEntries: entries,
            expandedFolderIDs: [], sortConfiguration: .init(name: .ascending, dateCreated: .off, type: .off))
    }
}

private struct Counts: Equatable, Sendable {
    var rows = 0
    var hidden = 0
    var mediaPaths = 0
    var thumbnails = 0
    var regexMatches = 0
    var relativeBytes = 0
    var checksum: UInt64 = 0

    mutating func add(_ other: Counts) {
        rows += other.rows; hidden += other.hidden; mediaPaths += other.mediaPaths
        thumbnails += other.thumbnails; regexMatches += other.regexMatches
        relativeBytes += other.relativeBytes; checksum &+= other.checksum
    }

    var record: [String: Any] {
        ["rows": rows, "hidden": hidden, "media_paths": mediaPaths, "thumbnails": thumbnails,
         "regex_matches": regexMatches, "relative_utf8_bytes": relativeBytes]
    }
}

@inline(never)
private func lookup(_ matcher: SourceVisibilityMatcher, paths: [String]) -> Counts {
    var result = Counts()
    for path in paths {
        let relative = matcher.relativePath(normalizedPath: path)
        let bytes = relative.utf8.count
        result.relativeBytes += bytes
        result.checksum &+= UInt64(bytes) &* 31 &+ UInt64(relative.utf8.first ?? 0)
    }
    return result
}

@inline(never)
private func makeMatcher(_ fixture: Fixture) -> SourceVisibilityMatcher {
    SourceVisibilityMatcher(configuration: fixture.configuration, roots: fixture.roots)
}

private func project(_ fixture: Fixture) async throws -> SourceBrowserProjection {
    let filter = SourceBrowserFilter()
    guard let projection = await filter.project(input: fixture.input, revealsRulePreview: false, query: "")
    else { throw CancellationError() }
    return projection
}

private func projectionCounts(_ fixture: Fixture) async throws -> Counts {
    let value = try await project(fixture)
    let matches = value.regexCounts.values.reduce(0, +)
    return Counts(rows: value.rows.count, hidden: value.hiddenCount, mediaPaths: value.mediaPaths.count,
        thumbnails: value.thumbnailCandidates.count, regexMatches: matches,
        checksum: UInt64(value.rows.count) &* 31 &+ UInt64(value.hiddenCount) &* 17
            &+ UInt64(value.mediaPaths.count) &* 7 &+ UInt64(matches) &* 3
            &+ UInt64(value.thumbnailCandidates.count))
}

private func cpuNanoseconds() -> UInt64 {
    var value = timespec()
    precondition(clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &value) == 0)
    return UInt64(value.tv_sec) * 1_000_000_000 + UInt64(value.tv_nsec)
}

@MainActor
private func measured(_ fixture: Fixture, iterations: Int) async throws -> [String: Any] {
    let scenario = fixture.scenario
    var result: [String: Any] = ["case": scenario.name, "iterations": iterations, "operations": iterations,
        "warmup_iterations": 1, "input_roots": fixture.roots.count, "inputs_per_iteration": scenario.inputs]
    if scenario.mode == .initialization {
        let probe = fixture.roots[0].path + "/probe.mkv"
        let expected = makeMatcher(fixture).relativePath(normalizedPath: probe)
        var latest: SourceVisibilityMatcher?
        var checksum: UInt64 = 0
        let cpuStart = cpuNanoseconds(), wallStart = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<iterations {
            // Only the latest value survives. Previous matcher destruction is
            // timed; the final value is checked and released after the timer.
            latest = makeMatcher(fixture)
            checksum &+= 1
        }
        let elapsed = DispatchTime.now().uptimeNanoseconds - wallStart
        let cpu = cpuNanoseconds() - cpuStart
        precondition(checksum == UInt64(iterations))
        precondition(latest!.relativePath(normalizedPath: probe).utf8.elementsEqual(expected.utf8))
        result.merge(["unit": "matcher initialization", "checksum": checksum, "warmup_checksum": UInt64(1),
            "elapsed_ns": elapsed, "cpu_ns": cpu, "probe_utf8": Array(expected.utf8),
            "output_counts": ["initialized_matchers": iterations],
            "warmup_counts": ["initialized_matchers": 1]]) { _, new in new }
        return result
    }

    // Initialization belongs outside reused-matcher timings and inside every
    // complete projection, which creates a fresh actor and both real matchers.
    let matcher = scenario.mode == .lookup ? makeMatcher(fixture) : nil
    let warmup: Counts
    if let matcher { warmup = lookup(matcher, paths: fixture.paths) }
    else { warmup = try await projectionCounts(fixture) }
    if scenario.mode == .projection {
        let expectedHidden = fixture.configuration.regexRules.isEmpty ? 0 : scenario.inputs / 16
        precondition(warmup.rows == scenario.inputs - expectedHidden && warmup.hidden == expectedHidden)
        precondition(warmup.mediaPaths == warmup.rows && warmup.thumbnails == warmup.rows)
        precondition(warmup.regexMatches == expectedHidden)
    }
    var total = Counts()
    let cpuStart = cpuNanoseconds(), wallStart = DispatchTime.now().uptimeNanoseconds
    for _ in 0..<iterations {
        if let matcher { total.add(lookup(matcher, paths: fixture.paths)) }
        else { total.add(try await projectionCounts(fixture)) }
    }
    let elapsed = DispatchTime.now().uptimeNanoseconds - wallStart
    let cpu = cpuNanoseconds() - cpuStart
    var expected = Counts()
    for _ in 0..<iterations { expected.add(warmup) }
    precondition(total == expected)
    result.merge(["unit": scenario.mode == .lookup ? "batch of relative-path lookups" : "complete cold projection",
        "checksum": total.checksum, "warmup_checksum": warmup.checksum,
        "elapsed_ns": elapsed, "cpu_ns": cpu, "output_counts": total.record,
        "warmup_counts": warmup.record]) { _, new in new }
    return result
}

private func nullable<T>(_ value: T?) -> Any { value.map { $0 as Any } ?? NSNull() }
private func byteOrdered(_ values: Set<String>) -> [String] {
    values.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
}
private func regexRecord(_ match: SourceVisibilityRegexMatch) -> [String: Any] {
    ["id": match.id, "color_index": match.colorIndex]
}
private func hideRecord(_ match: SourceVisibilityHideMatch) -> [String: Any] {
    switch match {
    case .manual: ["kind": "manual"]
    case .noMedia: ["kind": "no_media"]
    case let .regex(rule): ["kind": "regex", "rule": regexRecord(rule)]
    }
}
private func evaluationRecord(_ value: SourceVisibilityEvaluation) -> [String: Any] {
    ["hidden_matches": value.hiddenMatches.map(hideRecord), "regex_matches": value.regexMatches.map(regexRecord)]
}
private func recognitionRecord(_ value: RecognizedMediaName?) -> Any {
    guard let value else { return NSNull() }
    return ["kind": value.kind.rawValue, "title": value.title, "year": nullable(value.year),
        "season": nullable(value.season), "episode": nullable(value.episode), "last_episode": nullable(value.lastEpisode),
        "air_date": nullable(value.airDate), "episode_title": nullable(value.episodeTitle), "edition": nullable(value.edition),
        "catalog_ids": value.catalogIDs, "variant": nullable(value.variant), "metadata_sources": value.metadataSources] as [String: Any]
}
private func projectionRecord(_ value: SourceBrowserProjection) -> [String: Any] {
    let rows: [[String: Any]] = value.rows.map { row in
        let kind: [String: Any]
        switch row.kind {
        case let .folder(isRoot): kind = ["kind": "folder", "is_root": isRoot]
        case let .media(date): kind = ["kind": "media", "date_bits": nullable(date.map { String($0.timeIntervalSince1970.bitPattern) })]
        case let .message(message): kind = ["kind": "message", "message": message]
        case .mediaSection: kind = ["kind": "media_section"]
        }
        let visibility: Any = row.visibility.map { value -> Any in ["is_inherited": value.isInherited,
            "matches": value.matches.map(hideRecord)] as [String: Any] } ?? NSNull()
        return ["id": row.id, "folder_id": row.folderID, "url": row.url.absoluteString,
            "display_name": row.displayName, "context_label": nullable(row.contextLabel),
            "recognized_media": recognitionRecord(row.recognizedMedia), "visibility_path": nullable(row.visibilityPath),
            "depth": row.depth, "ancestors": row.ancestorIDs, "kind": kind,
            "visibility": visibility, "contains_supported_media": nullable(row.containsSupportedMedia)]
    }
    return ["rows": rows, "hidden_count": value.hiddenCount,
        "regex_counts": value.regexCounts.keys.sorted().map { ["id": $0, "count": value.regexCounts[$0]!] as [String: Any] },
        "thumbnail_candidates": value.thumbnailCandidates.map(\.absoluteString), "media_paths": byteOrdered(value.mediaPaths)]
}

private func corpusConfiguration() -> SourceVisibilityConfiguration {
    var value = SourceVisibilityConfiguration.default
    value.viewMode = .filesOnly
    value.manuallyHiddenPaths = ["/Library/Manual", "/Library/Show/Season 02/Visible.mkv"]
    value.alwaysShownPaths = ["/Library/Show/Season 02/Trailer.mkv"]
    value.regexRules = [
        .init(id: "relative-season", pattern: "^Season 02/", colorIndex: 0, isEnabled: true),
        .init(id: "trailers", pattern: "Trailer", colorIndex: 1, isEnabled: true),
        .init(id: "unicode", pattern: "Café|Cafe\\u0301|日本語", colorIndex: 2, isEnabled: true),
        .init(id: "hidden-folder", pattern: "^Hidden(?:/|$)", colorIndex: 3, isEnabled: true),
        .init(id: "disabled", pattern: ".*", colorIndex: 4, isEnabled: false),
        .init(id: "invalid", pattern: "[", colorIndex: 5, isEnabled: true),
    ]
    return value
}

private func lookupRecord(_ matcher: SourceVisibilityMatcher, path: String) -> [String: Any] {
    let relative = matcher.relativePath(normalizedPath: path)
    let url = URL(fileURLWithPath: path, isDirectory: false)
    let viaURL = matcher.relativePath(for: url)
    return ["path": path, "path_utf8": Array(path.utf8), "relative": relative, "relative_utf8": Array(relative.utf8),
        "url_relative": viaURL, "url_relative_utf8": Array(viaURL.utf8),
        "direct": evaluationRecord(matcher.evaluate(normalizedPath: path)),
        "ancestors": evaluationRecord(matcher.evaluateIncludingAncestors(normalizedPath: path)),
        "url_direct": evaluationRecord(matcher.evaluate(url)),
        "url_ancestors": evaluationRecord(matcher.evaluateIncludingAncestors(url))]
}

@MainActor
private func differential() async throws -> [String: Any] {
    let common = ["/", "/Library", "/Library/Show", "/Library/Show/Season 02",
        "/Library/Show/Season 02/Visible.mkv", "/Library/Show/Season 02/Trailer.mkv",
        "/Library/Show/Season 02/Hidden/Episode.mkv", "/Library/Manual/Episode.mkv",
        "/Library2/Episode.mkv", "/Library-old/Episode.mkv", "/Elsewhere/Other.mkv"]
    let nested = ["/", "/Library", "/Library/Show", "/Library/Show/Season 02"]
    var cases: [(String, [String], [String])] = [
        ("empty", [], common), ("filesystem-root", ["/"], common),
        ("nested-broad-first", nested, common), ("nested-deep-first", Array(nested.reversed()), common),
        ("prefix-siblings", ["/Library", "/Library2", "/Library-old"], common),
        ("ignored-remote-root", ["https://example.invalid/Library"], common),
        ("unicode", ["/Volumes/Café", "/Volumes/日本語", "/Volumes/👩🏽‍💻"],
            ["/Volumes/Café", "/Volumes/Cafe\u{301}/Saison e\u{301}/Épisode.mkv", "/Volumes/Café2/Episode.mkv",
             "/Volumes/日本語/動画/Trailer.mkv", "/Volumes/👩🏽‍💻/👨‍👩‍👧‍👦/Movie.mkv"]),
        ("escaped-looking", ["/100% #", "/literal%2F/path", "/Question?"],
            ["/100% #/literal%20space.mkv", "/literal%2F/path/%2E%2E/file.mkv",
             "/Question?/Hash#100%.mkv", "/literal/path/movie.mkv"]),
    ]
    var random: UInt64 = 0x726f_6f74_6c6f_6f6b
    func next() -> UInt64 { random = random &* 6_364_136_223_846_793_005 &+ 1; return random }
    let names = ["Movies", "Café", "Cafe\u{301}", "日本語", "👩🏽‍💻", "100% #"]
    for trial in 0..<16 {
        var roots = (0..<(1 + trial * 2)).map { index in "/Seed-\(trial)/\(names[Int(next() % UInt64(names.count))])-\(index)" }
        let paths = (0..<16).map { index -> String in
            let root = roots[Int(next() % UInt64(roots.count))]
            return index.isMultiple(of: 4) ? root + "-sibling/Movie.mkv"
                : root + "/Season 02/\(index.isMultiple(of: 3) ? "Trailer" : "Episode")-\(index).mkv"
        }
        if trial.isMultiple(of: 2) { roots.reverse() }
        cases.append(("seed-\(trial)", roots, paths))
    }
    let configuration = corpusConfiguration()
    let corpus: [[String: Any]] = cases.map { name, paths, queries in
        let roots = paths.map { $0.hasPrefix("https:") ? URL(string: $0)! : URL(fileURLWithPath: $0, isDirectory: true) }
        let matcher = SourceVisibilityMatcher(configuration: configuration, roots: roots)
        return ["case": name, "roots": roots.map(\.absoluteString), "queries": queries.map { lookupRecord(matcher, path: $0) }]
    }
    var workloads: [[String: Any]] = []
    for scenario in scenarios {
        let fixture = Fixture(scenario)
        if scenario.mode == .projection {
            let first = try await project(fixture)
            let second = try await project(fixture)
            let expectedHidden = fixture.configuration.regexRules.isEmpty ? 0 : scenario.inputs / 16
            precondition(first.rows.count == scenario.inputs - expectedHidden && first.hiddenCount == expectedHidden)
            precondition(first.mediaPaths.count == first.rows.count && first.thumbnailCandidates.count == first.rows.count)
            precondition(first.regexCounts.values.reduce(0, +) == expectedHidden)
            let firstRecord = projectionRecord(first), secondRecord = projectionRecord(second)
            let firstBytes = try json(firstRecord), secondBytes = try json(secondRecord)
            precondition(firstBytes == secondBytes)
            workloads.append(["case": scenario.name, "projection": firstRecord])
        } else {
            let matcher = makeMatcher(fixture)
            let paths = fixture.paths.isEmpty ? [fixture.roots[0].path + "/probe.mkv"] : fixture.paths
            workloads.append(["case": scenario.name, "relative_paths": paths.map { path in
                let value = matcher.relativePath(normalizedPath: path)
                return ["input": path, "relative": value, "utf8": Array(value.utf8)] as [String: Any]
            }])
        }
    }
    return ["corpus": corpus, "workloads": workloads]
}

private func json(_ value: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
}
private enum HarnessFailure: Error { case invalidArguments }

@main
private enum Harness {
    static func main() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        func value(_ flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        let output: Any
        if arguments.contains("--list") {
            output = scenarios.map { ["case": $0.name, "description": $0.description, "mode": $0.mode.rawValue,
                "input_roots": $0.roots, "inputs_per_iteration": $0.inputs] as [String: Any] }
        } else if arguments.contains("--differential") {
            output = try await differential()
        } else {
            guard let name = value("--case"), let scenario = scenarios.first(where: { $0.name == name }),
                  let raw = value("--iterations"), let iterations = Int(raw), (1...1_000_000).contains(iterations)
            else { throw HarnessFailure.invalidArguments }
            output = try await measured(Fixture(scenario), iterations: iterations)
        }
        FileHandle.standardOutput.write(try json(output))
        FileHandle.standardOutput.write(Data([10]))
    }
}
