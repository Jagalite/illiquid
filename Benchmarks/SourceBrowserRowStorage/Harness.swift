import CSourceBrowserRowStorage
import Dispatch
import Foundation
import IlliquidCore
@testable import IlliquidApp

// Fixtures use the actual production row, matcher, projection, and actor types.
// Inputs, metadata recognition, warming, and semantic serialization are outside
// the timed calls and the retained-allocation measurement interval.
private enum Scenario: String, CaseIterable {
    case tree, files, folders
    case noMatch = "no_match"
    case hideFirst = "hide_first", hideMiddle = "hide_middle", hideLast = "hide_last"
    case hideMost = "hide_most", hideAll = "hide_all"
    case annotateFirst = "annotate_first", annotateMiddle = "annotate_middle"
    case annotateLast = "annotate_last"
    case preannotated, resetAnnotations = "reset_annotations"
    case search, media, cacheHit = "cache_hit"
}

private struct Fixture: Sendable {
    let rows: [SourceTreeDisplayRow]
    let configuration: SourceVisibilityConfiguration
    let roots: [URL]
    let preview: Bool
    let query: String
    let expectedRows: Int
    let expectedHidden: Int

    init(scenario: Scenario, count: Int) {
        precondition(count > 0)
        let root = URL(fileURLWithPath: "/Volumes/Row Storage Library α", isDirectory: true)
        let folderRows = scenario == .folders
        let names = ["Episode", "Café", "雪", "Cafe\u{301}", "🎬"]
        let media = scenario == .media ? [
            "Show A (2020)/Season 01/S01E01 - First.mkv",
            "Show B (2021)/Season 02/S02E02 - Second.mkv",
            "A Movie (2024).mkv",
            "Extras/Interview-featurette.mkv",
        ].map { MediaNameRecognition.recognize(relativePath: $0) } : []
        let manual = SourceRowVisibility(matches: [.manual], isInherited: false)
        var values = (0..<count).map { index in
            let marker = index.isMultiple(of: 5) ? " needle" : ""
            let name = "\(names[index % names.count])-\(index)\(marker)"
            let url = root.appendingPathComponent(name + (folderRows ? "" : ".mkv"),
                                                 isDirectory: folderRows)
            return SourceTreeDisplayRow(
                id: "entry-\(index)", folderID: root.path, url: url,
                displayName: name, contextLabel: index.isMultiple(of: 3) ? "Library · \(index % 7)" : nil,
                recognizedMedia: media.isEmpty ? nil : media[index % media.count],
                visibilityPath: url.path, depth: 0, ancestorIDs: [],
                kind: folderRows ? .folder(isRoot: false)
                    : .media(dateAdded: index.isMultiple(of: 2) ? Date(timeIntervalSince1970: Double(1_700_000_000 + index)) : nil),
                visibility: nil, containsSupportedMedia: folderRows && index.isMultiple(of: 2) ? true : nil
            )
        }
        var configuration = SourceVisibilityConfiguration.default
        var preview = false
        var query = ""
        var expectedRows = count
        var expectedHidden = 0
        switch scenario {
        case .tree, .cacheHit:
            break
        case .files:
            configuration.viewMode = .filesOnly
        case .folders:
            configuration.viewMode = .foldersOnly
        case .noMatch:
            configuration.regexRules = [.init(id: "never", pattern: "^never-matches-this-fixture$",
                colorIndex: 3, isEnabled: true)]
        case .hideFirst, .hideMiddle, .hideLast, .annotateFirst, .annotateMiddle, .annotateLast:
            let index = switch scenario {
            case .hideFirst, .annotateFirst: 0
            case .hideMiddle, .annotateMiddle: count / 2
            default: count - 1
            }
            configuration.manuallyHiddenPaths = [values[index].visibilityPath!]
            preview = [.annotateFirst, .annotateMiddle, .annotateLast].contains(scenario)
            expectedRows = count - (preview ? 0 : 1)
            expectedHidden = 1
        case .hideMost, .hideAll:
            let hidden = scenario == .hideAll ? count : count * 99 / 100
            configuration.manuallyHiddenPaths = Set(values.prefix(hidden).compactMap(\.visibilityPath))
            expectedRows = count - hidden
            expectedHidden = hidden
        case .preannotated:
            configuration.manuallyHiddenPaths = Set(values.compactMap(\.visibilityPath))
            preview = true
            expectedHidden = count
            for index in values.indices { values[index].visibility = manual }
        case .resetAnnotations:
            for index in values.indices { values[index].visibility = manual }
        case .search:
            query = "needle"
            expectedRows = (count + 4) / 5
        case .media:
            configuration.viewMode = .media
            expectedRows = count + Set(values.compactMap { $0.recognizedMedia?.section }).count
        }
        self.rows = values
        self.configuration = configuration
        self.roots = [root]
        self.preview = preview
        self.query = query
        self.expectedRows = expectedRows
        self.expectedHidden = expectedHidden
    }

    func project(using filter: SourceBrowserFilter) async -> SourceBrowserProjection {
        guard let projection = await filter.projectForRowStorageBenchmark(self) else {
            preconditionFailure("Unexpected cancellation in a benchmark process")
        }
        return projection
    }
}

// Drain Objective-C temporaries on the same executor that creates them. The
// production projection is synchronous inside its actor, so this benchmark-only
// wrapper can scope a pool without spanning an await. Returned Swift values stay
// owned by the caller. Linux uses the identical call without an Objective-C pool.
private func withDrainedAutoreleasePool<Value>(
    _ body: () throws -> Value
) rethrows -> Value {
    #if canImport(ObjectiveC)
    return try autoreleasepool(invoking: body)
    #else
    return try body()
    #endif
}

private extension SourceBrowserFilter {
    func projectForRowStorageBenchmark(_ fixture: Fixture) -> SourceBrowserProjection? {
        withDrainedAutoreleasePool {
            project(rows: fixture.rows, configuration: fixture.configuration,
                    roots: fixture.roots, revealsRulePreview: fixture.preview, query: fixture.query)
        }
    }
}

// These records include every stored row field and every projection field.
// Complete JSON can be byte-compared across variants; compact observations carry
// its size and a deterministic checksum. Do not treat the checksum as a proof
// replacing the runner's complete semantic-output comparison.
private struct VisibilityMatch: Encodable {
    let kind: String
    var id: String? = nil
    var colorIndex: Int? = nil

    init(_ match: SourceVisibilityHideMatch) {
        switch match {
        case .manual: kind = "manual"
        case .noMedia: kind = "noMedia"
        case .regex(let rule): kind = "regex"; id = rule.id; colorIndex = rule.colorIndex
        }
    }
}

private struct Visibility: Encodable {
    let matches: [VisibilityMatch]
    let isInherited: Bool
    init(_ value: SourceRowVisibility) {
        matches = value.matches.map(VisibilityMatch.init)
        isInherited = value.isInherited
    }
}

private struct Recognition: Encodable {
    let kind: String
    let title: String
    let year: Int?
    let season: Int?
    let episode: Int?
    let lastEpisode: Int?
    let airDate: String?
    let episodeTitle: String?
    let edition: String?
    let catalogIDs: [String]
    let variant: String?
    let metadataSources: [String]

    init(_ value: RecognizedMediaName) {
        kind = value.kind.rawValue; title = value.title; year = value.year
        season = value.season; episode = value.episode; lastEpisode = value.lastEpisode
        airDate = value.airDate; episodeTitle = value.episodeTitle; edition = value.edition
        catalogIDs = value.catalogIDs; variant = value.variant; metadataSources = value.metadataSources
    }
}

private struct Row: Encodable {
    let id: String
    let folderID: String
    let url: String
    let displayName: String
    let contextLabel: String?
    let recognizedMedia: Recognition?
    let visibilityPath: String?
    let depth: Int
    let ancestorIDs: [String]
    let kind: String
    let isRoot: Bool?
    let dateAdded: TimeInterval?
    let message: String?
    let visibility: Visibility?
    let containsSupportedMedia: Bool?

    init(_ value: SourceTreeDisplayRow) {
        id = value.id; folderID = value.folderID; url = value.url.absoluteString
        displayName = value.displayName; contextLabel = value.contextLabel
        recognizedMedia = value.recognizedMedia.map(Recognition.init)
        visibilityPath = value.visibilityPath; depth = value.depth; ancestorIDs = value.ancestorIDs
        switch value.kind {
        case .folder(let root): kind = "folder"; isRoot = root; dateAdded = nil; message = nil
        case .media(let date): kind = "media"; isRoot = nil; dateAdded = date?.timeIntervalSince1970; message = nil
        case .message(let text): kind = "message"; isRoot = nil; dateAdded = nil; message = text
        case .mediaSection: kind = "mediaSection"; isRoot = nil; dateAdded = nil; message = nil
        }
        visibility = value.visibility.map(Visibility.init)
        containsSupportedMedia = value.containsSupportedMedia
    }
}

private struct Semantics: Encodable {
    let rows: [Row]
    let hiddenCount: Int
    let regexCounts: [String: Int]
    let thumbnailCandidates: [String]
    let mediaPaths: [String]

    init(_ value: SourceBrowserProjection) {
        rows = value.rows.map(Row.init); hiddenCount = value.hiddenCount
        regexCounts = value.regexCounts
        thumbnailCandidates = value.thumbnailCandidates.map(\.absoluteString)
        mediaPaths = value.mediaPaths.sorted()
    }
}

private struct Checks: Encodable {
    let output_row_count: Int
    let hidden_count: Int
    let regex_counts: [String: Int]
    let thumbnail_candidate_count: Int
    let media_path_count: Int
    let matches_input_rows: Bool
    let semantic_byte_count: Int
    let semantic_fnv1a64: String
}

private struct Measurement: Encodable {
    let schema = 1
    let mode = "measure"
    let scenario: String
    let count: Int
    let iterations: Int
    let allocator_metric: String
    let allocator_before_fixture_bytes: UInt64
    let allocator_before_projection_bytes: UInt64
    let allocator_after_projection_bytes: UInt64
    let retained_fixture_delta_bytes: Int64
    let retained_projection_delta_bytes: Int64
    let loop_wall_nanoseconds: UInt64
    let loop_cpu_nanoseconds: UInt64
    let input_row_capacity: Int
    let output_row_capacity: Int
    let row_stride_bytes: Int
    let shares_input_storage: Bool
    let tree_build_count: Int
    let visibility_build_count: Int
    let checks: Checks
}

private func encoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return encoder
}

@inline(never)
private func warmUp(_ scenario: Scenario) async throws {
    let fixture = withDrainedAutoreleasePool { Fixture(scenario: scenario, count: 32) }
    let filter = SourceBrowserFilter()
    let projection = await fixture.project(using: filter)
    _ = try withDrainedAutoreleasePool { try encoder().encode(Semantics(projection)) }
    _ = source_browser_heap_bytes()
    _ = source_browser_cpu_nanoseconds()
    _ = DispatchTime.now().uptimeNanoseconds
}

@inline(never)
private func measure(_ scenario: Scenario, count: Int, iterations: Int,
                     semanticOutput: String?) async throws -> Measurement {
    try await warmUp(scenario)
    let metric = String(cString: source_browser_heap_metric())
    precondition(metric != "unsupported", "Retained allocator metric unavailable")
    let beforeFixture = source_browser_heap_bytes()
    let fixture = withDrainedAutoreleasePool { Fixture(scenario: scenario, count: count) }
    var filter = SourceBrowserFilter()
    if scenario == .cacheHit { _ = await fixture.project(using: filter) }
    var projection: SourceBrowserProjection?
    let beforeProjection = source_browser_heap_bytes()
    var wall: UInt64 = 0, cpu: UInt64 = 0
    for iteration in 0..<iterations {
        if iteration > 0 && scenario != .cacheHit {
            // Clear the previous result and create a fresh actor outside timing.
            // Only the final actor/result are live at the retained sample.
            projection = nil
            filter = SourceBrowserFilter()
        }
        let wallStart = DispatchTime.now().uptimeNanoseconds
        let cpuStart = source_browser_cpu_nanoseconds()
        projection = await fixture.project(using: filter)
        cpu += source_browser_cpu_nanoseconds() - cpuStart
        wall += DispatchTime.now().uptimeNanoseconds - wallStart
    }
    let retained = withExtendedLifetime((fixture, filter, projection)) { source_browser_heap_bytes() }
    let result = projection!

    // Nothing below contributes to the allocation/timing claims above.
    precondition(result.rows.count == fixture.expectedRows)
    precondition(result.hiddenCount == fixture.expectedHidden)
    let shared = fixture.rows.withUnsafeBufferPointer { input in
        result.rows.withUnsafeBufferPointer { output in input.baseAddress == output.baseAddress }
    }
    let complete = try encoder().encode(Semantics(result))
    var checksum: UInt64 = 14_695_981_039_346_656_037
    for byte in complete { checksum = (checksum ^ UInt64(byte)) &* 1_099_511_628_211 }
    if let semanticOutput { try complete.write(to: URL(fileURLWithPath: semanticOutput)) }
    let checks = Checks(output_row_count: result.rows.count, hidden_count: result.hiddenCount,
        regex_counts: result.regexCounts, thumbnail_candidate_count: result.thumbnailCandidates.count,
        media_path_count: result.mediaPaths.count, matches_input_rows: result.rows == fixture.rows,
        semantic_byte_count: complete.count, semantic_fnv1a64: String(checksum))
    return Measurement(scenario: scenario.rawValue, count: count, iterations: iterations,
        allocator_metric: metric, allocator_before_fixture_bytes: beforeFixture,
        allocator_before_projection_bytes: beforeProjection, allocator_after_projection_bytes: retained,
        retained_fixture_delta_bytes: Int64(retained) - Int64(beforeFixture),
        retained_projection_delta_bytes: Int64(retained) - Int64(beforeProjection),
        loop_wall_nanoseconds: wall, loop_cpu_nanoseconds: cpu,
        input_row_capacity: fixture.rows.capacity, output_row_capacity: result.rows.capacity,
        row_stride_bytes: MemoryLayout<SourceTreeDisplayRow>.stride, shares_input_storage: shared,
        tree_build_count: await filter.treeBuildCount,
        visibility_build_count: await filter.visibilityBuildCount, checks: checks)
}

@main
private struct SourceBrowserRowStorageHarness {
    static func main() async throws {
        var scenario = Scenario.tree, count = 1_000, iterations = 1
        var semanticOutput: String?
        var arguments = Array(CommandLine.arguments.dropFirst())
        while !arguments.isEmpty {
            let key = arguments.removeFirst()
            guard !arguments.isEmpty else { fatalError("Missing value for \(key)") }
            let value = arguments.removeFirst()
            switch key {
            case "--case":
                guard let parsed = Scenario(rawValue: value) else { fatalError("Unknown scenario: \(value)") }
                scenario = parsed
            case "--count": count = Int(value) ?? 0
            case "--iterations": iterations = Int(value) ?? 0
            case "--semantic-output": semanticOutput = value
            default: fatalError("Unknown argument: \(key)")
            }
        }
        precondition(count > 0 && count <= 1_000_000 && iterations > 0 && iterations <= 10_000)
        let measurement = try await measure(scenario, count: count, iterations: iterations,
                                             semanticOutput: semanticOutput)
        print(String(decoding: try encoder().encode(measurement), as: UTF8.self))
    }
}
