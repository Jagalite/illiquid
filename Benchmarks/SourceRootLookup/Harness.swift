import Foundation
import IlliquidCore
@testable import IlliquidApp

// The isolated library contains verbatim production declarations. This driver
// calls their public/internal entry points; it does not reproduce root lookup.
private struct Fixture {
    let roots: [URL]
    let paths: [String]
    let configuration: SourceVisibilityConfiguration
    let input: SourceTreeProjectionInput

    init(rootCount: Int, scenario: String, rows: Int, depth: Int) {
        let rootPaths: [String]
        if scenario == "relative-nested" {
            let nested = ["/root-lookup/Library", "/root-lookup/Library/Shows",
                          "/root-lookup/Library/Shows/Season 01"]
            rootPaths = Array(nested.prefix(rootCount))
                + (0..<max(0, rootCount - nested.count)).map { "/unrelated/Collection \($0)" }
        } else {
            rootPaths = (0..<rootCount).map { "/root-lookup/Collection \($0) Café" }
        }
        roots = rootPaths.map { URL(fileURLWithPath: $0, isDirectory: true) }
        let middle = (0..<depth).map { "Directory \($0)" }.joined(separator: "/")
        paths = (0..<(scenario == "cold-single" ? 1 : 64)).map { index in
            let root = rootPaths[(index * 17) % rootPaths.count]
            switch scenario {
            case "relative-miss":
                // A lexical prefix alone must never establish containment.
                return root + "-sibling/" + middle + "/Episode \(index).mkv"
            case "relative-nested":
                switch index % 4 {
                case 0: return "/root-lookup/Library/Shows/Season 01/Episode \(index).mkv"
                case 1: return "/root-lookup/Library/Shows/Season 010/Episode \(index).mkv"
                case 2: return rootPaths[min(2, rootPaths.count - 1)]
                default: return "/root-lookup/Library/Movies/Feature \(index).mkv"
                }
            case "cold-relative":
                return index % 4 == 0 ? "/outside/Feature \(index).mkv"
                    : root + "/" + middle + "/Episode \(index).mkv"
            case "cold-single":
                return rootPaths.last! + "/" + middle + "/Episode \(index).mkv"
            case "relative-hit":
                return root + "/" + middle + "/Episode \(index).mkv"
            default:
                return root + "/Season \(index % 4)/Hidden/Episode \(index).mkv"
            }
        }
        var visibility = SourceVisibilityConfiguration.default
        visibility.viewMode = .filesOnly
        if scenario == "ancestry" || scenario == "flat-projection" {
            visibility.manuallyHiddenPaths = Set(rootPaths.map { $0 + "/Season 1" })
            visibility.regexRules = [
                .init(id: "hidden", pattern: "Hidden", colorIndex: 2, isEnabled: true),
                .init(id: "episode", pattern: "Episode [02468]", colorIndex: 3, isEnabled: true),
            ]
            // Preserve every row and annotation in the complete parity receipt.
            visibility.showsHiddenItems = true
        }
        configuration = visibility
        let entries = (0..<rows).map { index -> SourceTreeEntry in
            let root = rootPaths[(index * 17) % rootPaths.count]
            let path = root + "/Season \(index % 4)/"
                + (index % 3 == 0 ? "Hidden/" : "") + "Episode \(index).mkv"
            return SourceTreeEntry(url: URL(fileURLWithPath: path, isDirectory: false),
                kind: .media, dateAdded: Date(timeIntervalSince1970: Double(1_700_000_000 + index)),
                creationDate: nil, visibilityPath: path)
        }
        input = SourceTreeProjectionInput(
            items: roots.map { .init(kind: .folder, url: $0) },
            visibility: visibility, roots: roots, directoryContents: [:], directoryErrors: [:],
            recursiveMediaEntries: entries, expandedFolderIDs: [],
            sortConfiguration: .init(name: .off, dateCreated: .off, type: .off))
    }
}

private struct RuleReceipt: Codable {
    let id: String
    let colorIndex: Int
    init(_ match: SourceVisibilityRegexMatch) { id = match.id; colorIndex = match.colorIndex }
}

private struct HideReceipt: Codable {
    let kind: String
    let rule: RuleReceipt?
    init(_ match: SourceVisibilityHideMatch) {
        switch match {
        case .manual: kind = "manual"; rule = nil
        case .noMedia: kind = "noMedia"; rule = nil
        case let .regex(value): kind = "regex"; rule = RuleReceipt(value)
        }
    }
}

private struct EvaluationReceipt: Codable {
    let hidden: [HideReceipt]
    let regex: [RuleReceipt]
    init(_ value: SourceVisibilityEvaluation) {
        hidden = value.hiddenMatches.map(HideReceipt.init)
        regex = value.regexMatches.map(RuleReceipt.init)
    }
}

private struct VisibilityReceipt: Codable {
    let inherited: Bool
    let matches: [HideReceipt]
    init(_ value: SourceRowVisibility) {
        inherited = value.isInherited
        matches = value.matches.map(HideReceipt.init)
    }
}

private struct RowReceipt: Codable {
    let id: String
    let folderID: String
    let url: String
    let displayName: String
    let contextLabel: String?
    let visibilityPath: String?
    let depth: Int
    let ancestorIDs: [String]
    let kind: String
    let isRoot: Bool?
    let dateAddedBits: String?
    let message: String?
    let visibility: VisibilityReceipt?
    let containsSupportedMedia: Bool?

    init(_ row: SourceTreeDisplayRow) {
        // The files-only fixture must not silently drop newly produced metadata.
        precondition(row.recognizedMedia == nil)
        id = row.id; folderID = row.folderID; url = row.url.absoluteString
        displayName = row.displayName; contextLabel = row.contextLabel
        visibilityPath = row.visibilityPath; depth = row.depth; ancestorIDs = row.ancestorIDs
        visibility = row.visibility.map(VisibilityReceipt.init)
        containsSupportedMedia = row.containsSupportedMedia
        switch row.kind {
        case let .folder(value): kind = "folder"; isRoot = value; dateAddedBits = nil; message = nil
        case let .media(date):
            kind = "media"; isRoot = nil
            dateAddedBits = date.map { String($0.timeIntervalSince1970.bitPattern) }; message = nil
        case let .message(value): kind = "message"; isRoot = nil; dateAddedBits = nil; message = value
        case .mediaSection: kind = "mediaSection"; isRoot = nil; dateAddedBits = nil; message = nil
        }
    }
}

private struct ProjectionReceipt: Codable {
    let rows: [RowReceipt]
    let hiddenCount: Int
    let regexCounts: [String: Int]
    let thumbnails: [String]
    let mediaPaths: [String]
    init(_ projection: SourceBrowserProjection) {
        rows = projection.rows.map(RowReceipt.init)
        hiddenCount = projection.hiddenCount; regexCounts = projection.regexCounts
        thumbnails = projection.thumbnailCandidates.map(\.absoluteString)
        mediaPaths = projection.mediaPaths.sorted()
    }
}

private struct ParityReceipt: Codable {
    let roots: [String]
    let paths: [String]
    let relatives: [String]
    let evaluations: [EvaluationReceipt]
    let projection: ProjectionReceipt
}

private struct EdgeReceipt: Codable {
    let roots: [String]
    let paths: [String]
    let relatives: [String]
    let evaluations: [EvaluationReceipt]
}

private struct StableDigest {
    private(set) var value: UInt64 = 14_695_981_039_346_656_037
    mutating func add(_ bytes: Data) {
        for byte in bytes { value = (value ^ UInt64(byte)) &* 1_099_511_628_211 }
    }
}

private struct Measurement: Codable {
    let scenario: String
    let root_count: Int
    let row_count: Int
    let depth: Int
    let query_count: Int
    let iterations: Int
    let elapsed_ns: UInt64
    let durations_ns: [UInt64]
    let checksum: String
}

private enum HarnessFailure: Error { case arguments }

@main
private struct SourceRootBenchmark {
    static let cases = ["relative-hit", "relative-miss", "relative-nested", "cold-relative", "cold-single",
                        "ancestry", "flat-projection"]

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static func printJSON<T: Encodable>(_ value: T) throws {
        print(String(decoding: try encoder().encode(value), as: UTF8.self))
    }

    static func main() async throws {
        let args = CommandLine.arguments
        if args.count == 2, args[1] == "edges" {
            try printJSON(edgeReceipts())
            return
        }
        guard args.count == 7, ["measure", "parity"].contains(args[1]), cases.contains(args[2]),
              let count = Int(args[3]), count > 0,
              let rows = Int(args[4]), rows > 0,
              let depth = Int(args[5]), depth >= 0,
              let iterations = Int(args[6]), iterations > 0 else { throw HarnessFailure.arguments }
        let scenario = args[2]
        let fixture = Fixture(rootCount: count, scenario: scenario, rows: rows, depth: depth)
        let matcher = SourceVisibilityMatcher(configuration: fixture.configuration, roots: fixture.roots)
        if args[1] == "parity" {
            let filter = SourceBrowserFilter()
            guard let projection = await filter.project(input: fixture.input,
                revealsRulePreview: false, query: "") else { throw CancellationError() }
            try printJSON(ParityReceipt(roots: fixture.roots.map(\.absoluteString), paths: fixture.paths,
                relatives: fixture.paths.map { matcher.relativePath(normalizedPath: $0) },
                evaluations: fixture.paths.map { EvaluationReceipt(matcher.evaluateIncludingAncestors(normalizedPath: $0)) },
                projection: ProjectionReceipt(projection)))
            return
        }

        // Warm Foundation and all consumed paths. The timed projection still
        // uses a new actor for each iteration so its tree/visibility caches miss.
        for path in fixture.paths { _ = matcher.relativePath(normalizedPath: path) }
        _ = matcher.evaluateIncludingAncestors(normalizedPath: fixture.paths[0])
        _ = await SourceBrowserFilter().project(input: fixture.input, revealsRulePreview: false, query: "")
        var strings = Array(repeating: "", count: fixture.paths.count)
        var evaluations = Array(repeating: SourceVisibilityEvaluation(hiddenMatches: [], regexMatches: []),
                                count: fixture.paths.count)
        var durations: [UInt64] = []
        durations.reserveCapacity(iterations)
        var hash = StableDigest()
        let receiptEncoder = encoder()
        for _ in 0..<iterations {
            switch scenario {
            case "flat-projection":
                let filter = SourceBrowserFilter()
                let started = DispatchTime.now().uptimeNanoseconds
                let projection = await filter.project(input: fixture.input, revealsRulePreview: false, query: "")
                let elapsed = DispatchTime.now().uptimeNanoseconds - started
                guard let projection else { throw CancellationError() }
                durations.append(elapsed)
                hash.add(try receiptEncoder.encode(ProjectionReceipt(projection)))
                withExtendedLifetime(filter) {}
            case "ancestry":
                let started = DispatchTime.now().uptimeNanoseconds
                for index in fixture.paths.indices {
                    evaluations[index] = matcher.evaluateIncludingAncestors(normalizedPath: fixture.paths[index])
                }
                durations.append(DispatchTime.now().uptimeNanoseconds - started)
                hash.add(try receiptEncoder.encode(evaluations.map(EvaluationReceipt.init)))
            default:
                let started = DispatchTime.now().uptimeNanoseconds
                let active = scenario.hasPrefix("cold-")
                    ? SourceVisibilityMatcher(configuration: fixture.configuration, roots: fixture.roots) : matcher
                for index in fixture.paths.indices {
                    strings[index] = active.relativePath(normalizedPath: fixture.paths[index])
                }
                durations.append(DispatchTime.now().uptimeNanoseconds - started)
                hash.add(try receiptEncoder.encode(strings))
                withExtendedLifetime(active) {}
            }
        }
        try printJSON(Measurement(scenario: scenario, root_count: count, row_count: rows, depth: depth,
            query_count: fixture.paths.count, iterations: iterations, elapsed_ns: durations.reduce(0, +),
            durations_ns: durations, checksum: String(hash.value, radix: 16)))
    }

    static func edgeReceipts() -> [EdgeReceipt] {
        let sets = [
            [String](), ["/"], ["/library"],
            ["/library", "/library/Shows", "/library/Shows/Season 01"],
            ["/library/Café", "/library/映画", "/library/👩🏽‍💻"],
            ["/", "/\u{301}", "/\u{301}/\u{301}"],
            ["/a", "/a\u{600}", "/a\u{600}/\u{301}"],
            ["/library", "/library/\u{301}", "/library/\u{301}/\u{600}"],
            ["/library", "/library/\u{200d}", "/library/\u{200d}/\u{fe0f}"],
        ]
        var result: [EdgeReceipt] = []
        for original in sets {
            for padding in [0, 8] {
                for reversed in [false, true] {
                    let paths = ["", "/", "/outside/Movie.mkv", "/library-extra/Movie.mkv",
                                 "/library/Cafe\u{301}", "/library/Cafe\u{301}/e\u{301}pisode.mkv"]
                        + original.flatMap { [$0, $0 + "/Film.mkv", $0 + "/\u{301}/Film.mkv",
                                              $0 + "/\u{600}/\u{301}/Film.mkv", $0 + "-extra/Film.mkv"] }
                    var roots = original + (0..<padding).map { "/padding/\($0)" }
                    if reversed { roots.reverse() }
                    let urls = roots.map { URL(fileURLWithPath: $0, isDirectory: true) }
                    var configuration = SourceVisibilityConfiguration.default
                    configuration.manuallyHiddenPaths = Set(original.prefix(1))
                    configuration.regexRules = [.init(id: "film", pattern: "Film", colorIndex: 2, isEnabled: true)]
                    let matcher = SourceVisibilityMatcher(configuration: configuration, roots: urls)
                    result.append(EdgeReceipt(roots: urls.map(\.absoluteString), paths: paths,
                        relatives: paths.map { matcher.relativePath(normalizedPath: $0) },
                        evaluations: paths.map { EvaluationReceipt(matcher.evaluateIncludingAncestors(normalizedPath: $0)) }))
                }
            }
        }
        return result
    }
}
