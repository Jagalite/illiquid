import Foundation
import IlliquidCore
@testable import IlliquidApp

// This driver imports the unchanged production sources from an isolated
// IlliquidApp library. No replacement actor, matcher, row builder or sorter is used.
private struct Fixture {
    let inputs: [SourceTreeProjectionInput]
    let queries = ["", ""]
    let previews: [Bool]

    init(size: Int, scenario: String) {
        let rootPath = scenario.hasSuffix("_ascii")
            ? "/Volumes/Benchmark Library/Series" : "/Volumes/Benchmark Library/Series α"
        let root = URL(fileURLWithPath: rootPath, isDirectory: true)
        let nested = scenario.contains("nested")
        let rootID = SourceTreeIdentity.folderID(for: root)
        var directoryContents: [String: [SourceTreeEntry]] = [rootID: []]
        var expanded: Set<String> = []
        var folders: [URL] = []
        var media: [SourceTreeEntry] = []
        var seenFolders: Set<String> = []

        func folderEntry(_ url: URL) -> SourceTreeEntry {
            .init(url: url, kind: .folder, dateAdded: nil, creationDate: nil,
                  visibilityPath: SourceVisibilityPath.normalized(url))
        }
        for index in 0..<size {
            let parent: URL
            if nested {
                let show = root.appendingPathComponent("Show \(index / 100)", isDirectory: true)
                let season = show.appendingPathComponent("Season \(index / 50 % 2 + 1)", isDirectory: true)
                for (url, parentURL) in [(show, root), (season, show)] {
                    let id = SourceTreeIdentity.folderID(for: url)
                    if seenFolders.insert(id).inserted {
                        directoryContents[SourceTreeIdentity.folderID(for: parentURL), default: []].append(folderEntry(url))
                        directoryContents[id] = []
                        expanded.insert(id)
                    }
                }
                if !folders.contains(season) { folders.append(season) }
                parent = season
            } else {
                parent = root
            }
            let suffix = index % 5 == 0 ? " Trailer" : ""
            let name = "Show \(index / 100).S01E\(index % 100 + 1) - Episode \(index + 1)\(suffix).mkv"
            let url = parent.appendingPathComponent(name, isDirectory: false)
            var entry = SourceTreeEntry(
                url: url, kind: .media,
                dateAdded: Date(timeIntervalSince1970: Double(1_700_000_000 + index)),
                creationDate: nil, visibilityPath: SourceVisibilityPath.normalized(url))
            // Discovery supplies recognition; keep it outside projection timing.
            entry.recognizedMedia = MediaNameRecognition.recognize(relativePath: url.path)
            media.append(entry)
            directoryContents[SourceTreeIdentity.folderID(for: parent), default: []].append(entry)
        }
        // Deterministic unsorted discovery order, shared by both variants.
        var random: UInt64 = 0x7669_7369_6269_6c65
        if media.count > 1 {
            for index in stride(from: media.count - 1, through: 1, by: -1) {
                random = random &* 6_364_136_223_846_793_005 &+ 1
                media.swapAt(index, Int(random % UInt64(index + 1)))
            }
        }
        let firstPaths = Set(media.enumerated().compactMap { index, entry in
            index % 10 == 0 ? entry.visibilityPath : nil
        })
        let secondPaths = Set(media.enumerated().compactMap { index, entry in
            index % 10 == 1 ? entry.visibilityPath : nil
        })
        var first = SourceVisibilityConfiguration.default
        if scenario.hasPrefix("files_") { first.viewMode = .filesOnly }
        if scenario.hasPrefix("media_") { first.viewMode = .media }
        var second = first
        var previews = [false, false]
        let rule = SourceVisibilityRegexRule(id: "trailers", pattern: "Trailer",
                                            colorIndex: 2, isEnabled: true)
        switch scenario {
        case "tree_manual", "tree_manual_ascii", "tree_disabled_manual":
            first.manuallyHiddenPaths = firstPaths
            second.manuallyHiddenPaths = secondPaths
            if scenario == "tree_disabled_manual" {
                first.regexRules = [rule]
                first.regexRules[0].isEnabled = false
                second.regexRules = first.regexRules
            }
        case "tree_preview":
            first.manuallyHiddenPaths = firstPaths
            second = first
            previews = [false, true]
        case "tree_always_show":
            first.alwaysShownPaths = firstPaths
            second.alwaysShownPaths = secondPaths
        case "tree_nested_manual", "files_nested_manual", "media_nested_manual":
            first.manuallyHiddenPaths = firstPaths.union(
                folders.enumerated().compactMap { index, url in
                    index % 5 == 0 ? SourceVisibilityPath.normalized(url) : nil
                })
            second.manuallyHiddenPaths = secondPaths.union(
                folders.enumerated().compactMap { index, url in
                    index % 5 == 1 ? SourceVisibilityPath.normalized(url) : nil
                })
        case "tree_invalid":
            first.regexRules = [.init(id: "invalid", pattern: "[",
                                     colorIndex: 0, isEnabled: true)]
            second = first
            second.showsHiddenItems = true
        case "tree_disabled_control":
            first.regexRules = [rule]
            first.regexRules[0].isEnabled = false
            second = first
            second.showsHiddenItems = true
        case "tree_default_control":
            second.showsHiddenItems = true
        case "tree_regex_control", "files_nested_regex_control":
            first.regexRules = [rule]
            second = first
            second.showsHiddenItems = true
        default:
            preconditionFailure("Unknown scenario: \(scenario)")
        }
        let sorting = SourceTreeSortConfiguration(name: .ascending, dateCreated: .off, type: .off)
        func input(_ visibility: SourceVisibilityConfiguration) -> SourceTreeProjectionInput {
            .init(items: [.init(kind: .folder, url: root)], visibility: visibility, roots: [root],
                  directoryContents: directoryContents, directoryErrors: [:],
                  recursiveMediaEntries: media, expandedFolderIDs: expanded,
                  sortConfiguration: sorting)
        }
        inputs = [input(first), input(second)]
        self.previews = previews
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

    mutating func add(_ text: String) {
        add(UInt64(text.utf8.count))
        for byte in text.utf8 { value = (value ^ UInt64(byte)) &* 1_099_511_628_211 }
    }

    mutating func add(_ text: String?) {
        add(text == nil ? UInt64(0) : UInt64(1))
        if let text { add(text) }
    }

    mutating func add(_ number: Int?) {
        add(number.map(String.init))
    }

    mutating func add(_ visibility: SourceRowVisibility?) {
        guard let visibility else { add(UInt64(0)); return }
        add(UInt64(1))
        add(visibility.isInherited ? UInt64(1) : UInt64(0))
        add(UInt64(visibility.matches.count))
        for match in visibility.matches {
            switch match {
            case .manual: add("manual")
            case .noMedia: add("noMedia")
            case let .regex(rule): add("regex"); add(rule.id); add(UInt64(rule.colorIndex))
            }
        }
    }
}

private struct RuleCount: Codable, Equatable {
    let id: String
    let count: Int
}

private struct Receipt: Codable, Equatable {
    let rows: Int
    let hidden: Int
    let mediaPaths: Int
    let thumbnails: Int
    let rules: [RuleCount]
    let checksum: String

    init(_ projection: SourceBrowserProjection) {
        var hash = StableDigest()
        for row in projection.rows {
            hash.add(row.id); hash.add(row.folderID); hash.add(row.url.absoluteString)
            hash.add(row.displayName); hash.add(row.contextLabel); hash.add(row.visibilityPath)
            hash.add(UInt64(row.depth)); hash.add(UInt64(row.ancestorIDs.count))
            for ancestor in row.ancestorIDs { hash.add(ancestor) }
            switch row.kind {
            case let .folder(isRoot): hash.add("folder"); hash.add(isRoot ? UInt64(1) : UInt64(0))
            case let .media(dateAdded):
                hash.add("media"); hash.add(dateAdded.map { String($0.timeIntervalSince1970.bitPattern) })
            case let .message(message): hash.add("message"); hash.add(message)
            case .mediaSection: hash.add("mediaSection")
            }
            hash.add(row.visibility)
            hash.add(row.containsSupportedMedia.map { $0 ? "true" : "false" })
            if let media = row.recognizedMedia {
                hash.add("recognized"); hash.add(media.kind.rawValue); hash.add(media.title)
                hash.add(media.year); hash.add(media.season); hash.add(media.episode); hash.add(media.lastEpisode)
                hash.add(media.airDate); hash.add(media.episodeTitle); hash.add(media.edition); hash.add(media.variant)
                hash.add(UInt64(media.catalogIDs.count))
                for id in media.catalogIDs { hash.add(id) }
                hash.add(UInt64(media.metadataSources.count))
                for source in media.metadataSources { hash.add(source) }
            } else { hash.add("unrecognized") }
        }
        for url in projection.thumbnailCandidates { hash.add(url.absoluteString) }
        for path in projection.mediaPaths.sorted() { hash.add(path) }
        rows = projection.rows.count
        hidden = projection.hiddenCount
        mediaPaths = projection.mediaPaths.count
        thumbnails = projection.thumbnailCandidates.count
        rules = projection.regexCounts.keys.sorted().map { RuleCount(id: $0, count: projection.regexCounts[$0]!) }
        checksum = String(hash.value, radix: 16)
    }
}

private struct Measurement: Codable {
    let mode: String
    let `case`: String
    let size: Int
    let iterations: Int
    let elapsed_ns: UInt64
    let durations_ns: [UInt64]
    let receipts: [Receipt]
    let tree_build_count: Int
    let visibility_build_count: Int
}

private enum HarnessFailure: Error { case invalidArguments }

@main
private struct ManualVisibilityBenchmark {
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count == 5, ["measure", "diagnose"].contains(args[1]),
              let size = Int(args[3]), size > 0,
              let iterations = Int(args[4]), iterations >= 2, iterations % 2 == 0
        else { throw HarnessFailure.invalidArguments }
        let mode = args[1], scenario = args[2]
        let fixture = Fixture(size: size, scenario: scenario)
        let filter = SourceBrowserFilter()
        // Initialize process-global Foundation paths and the actor cache before
        // measuring a hot projection.
        guard await filter.project(input: fixture.inputs[0], revealsRulePreview: fixture.previews[0],
                                   query: fixture.queries[0]) != nil
        else { throw CancellationError() }
        if mode == "measure" {
            for step in [1, 0] {
                guard await filter.project(input: fixture.inputs[step], revealsRulePreview: fixture.previews[step],
                                           query: fixture.queries[step]) != nil
                else { throw CancellationError() }
            }
        }
        var durations: [UInt64] = []
        var receipts: [Receipt] = []
        for iteration in 0..<iterations {
            let step = (iteration + 1) % 2
            let start = mode == "measure" ? DispatchTime.now().uptimeNanoseconds : 0
            let projected = await filter.project(
                input: fixture.inputs[step], revealsRulePreview: fixture.previews[step], query: fixture.queries[step])
            let duration = mode == "measure" ? DispatchTime.now().uptimeNanoseconds - start : 0
            guard let projected else { throw CancellationError() }
            if mode == "measure" { durations.append(duration) }
            // This materializes observable output and catches stale projections.
            // It is deliberately after the timer and is identical in both builds.
            receipts.append(Receipt(projected))
        }
        // Read counters after all timed calls so cache validation cannot affect durations.
        let treeCount = await filter.treeBuildCount
        let visibilityCount = await filter.visibilityBuildCount
        precondition(treeCount == 1, "Raw tree should be reused")
        let warmupCount = mode == "measure" ? 3 : 1
        precondition(visibilityCount == iterations + warmupCount,
                     "Every iteration must rebuild visibility")
        let record = Measurement(mode: mode, case: scenario, size: size, iterations: iterations,
                                 elapsed_ns: durations.reduce(0, +), durations_ns: durations, receipts: receipts,
                                 tree_build_count: treeCount, visibility_build_count: visibilityCount)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        print(String(decoding: try encoder.encode(record), as: UTF8.self))
    }
}
