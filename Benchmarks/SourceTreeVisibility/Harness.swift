import Foundation
import IlliquidCore

// This driver lives beside the unchanged production sources in an isolated
// IlliquidApp target. No replacement actor, matcher, row builder or sorter is used.
private struct Fixture {
    let inputs: [SourceTreeProjectionInput]
    let queries: [String]
    let previews: [Bool]
    let cold: Bool

    init(size: Int, scenario: String) {
        let root = URL(fileURLWithPath: "/Volumes/Benchmark Library/Series α", isDirectory: true)
        var entries = (0..<size).map { index -> SourceTreeEntry in
            let suffix = index % 5 == 0 ? " Trailer" : ""
            let name = "Show \(index / 100).S01E\(index % 100 + 1) - Episode \(index + 1)\(suffix).mkv"
            let url = root.appendingPathComponent(name, isDirectory: false)
            var entry = SourceTreeEntry(
                url: url, kind: .media,
                dateAdded: Date(timeIntervalSince1970: Double(1_700_000_000 + index)),
                creationDate: Date(timeIntervalSince1970: Double(1_600_000_000 + index)),
                visibilityPath: SourceVisibilityPath.normalized(url))
            // The normal metadata-reading recursive loader supplies recognition.
            // Populate it before timing so the media case does not exaggerate
            // the gain by repeating filename recognition only in the baseline.
            entry.recognizedMedia = MediaNameRecognition.recognize(relativePath: url.path)
            return entry
        }
        // Stable Fisher-Yates order avoids sorted input and platform RNG state.
        var random: UInt64 = 0x726f_7773_6361_6368
        if entries.count > 1 {
            for index in stride(from: entries.count - 1, through: 1, by: -1) {
                random = random &* 6_364_136_223_846_793_005 &+ 1
                entries.swapAt(index, Int(random % UInt64(index + 1)))
            }
        }
        let paths = Set(entries.prefix(max(1, size / 10)).compactMap(\.visibilityPath))
        let revealedPaths = Set(entries.filter { $0.url.lastPathComponent.contains("Trailer") }
            .prefix(max(1, size / 20)).compactMap(\.visibilityPath))
        let rootID = SourceTreeIdentity.folderID(for: root)
        let ascending = SourceTreeSortConfiguration(name: .ascending, dateCreated: .off, type: .off)
        let descending = SourceTreeSortConfiguration(name: .descending, dateCreated: .off, type: .off)
        var first = SourceVisibilityConfiguration.default
        var second = first
        var secondSort = ascending
        var queries = ["", ""]
        var previews = [false, false]
        let rule = SourceVisibilityRegexRule(id: "trailers", pattern: "Trailer", colorIndex: 2, isEnabled: true)
        switch scenario {
        case "tree_rules", "files_rules", "media_rules":
            if scenario == "files_rules" { first.viewMode = .filesOnly }
            if scenario == "media_rules" { first.viewMode = .media }
            first.regexRules = [rule]
            first.regexRules[0].isEnabled = false
            second = first
            second.regexRules[0].isEnabled = true
        case "tree_show_hidden":
            first.manuallyHiddenPaths = paths
            second = first
            second.showsHiddenItems = true
        case "tree_manual_hide":
            second.manuallyHiddenPaths = paths
        case "tree_always_show":
            first.regexRules = [rule]
            second = first
            second.alwaysShownPaths = revealedPaths
        case "same_input_search":
            queries = ["Episode 1", "Episode 2"]
        case "preview_only":
            first.regexRules = [rule]
            second = first
            previews = [false, true]
        case "cold_tree":
            break
        case "changed_sort":
            secondSort = descending
        default:
            preconditionFailure("Unknown scenario")
        }
        func input(_ visibility: SourceVisibilityConfiguration,
                   _ sort: SourceTreeSortConfiguration) -> SourceTreeProjectionInput {
            SourceTreeProjectionInput(
                items: [.init(kind: .folder, url: root)], visibility: visibility, roots: [root],
                directoryContents: [rootID: entries], directoryErrors: [:],
                recursiveMediaEntries: entries, expandedFolderIDs: [], sortConfiguration: sort)
        }
        inputs = [input(first, ascending), input(second, secondSort)]
        self.queries = queries
        self.previews = previews
        cold = scenario == "cold_tree"
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
    let tree_build_count: Int?
    let visibility_build_count: Int?
}

private enum HarnessFailure: Error { case invalidArguments }

@main
private struct SourceTreeBenchmark {
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count == 5, ["measure", "diagnose"].contains(args[1]),
              let size = Int(args[3]), size > 0,
              let iterations = Int(args[4]), iterations >= 2, iterations % 2 == 0
        else { throw HarnessFailure.invalidArguments }
        let mode = args[1], scenario = args[2]
        let fixture = Fixture(size: size, scenario: scenario)
        var filter = SourceBrowserFilter()
        // Initialize process-global Foundation paths and the actor cache before
        // measuring a hot projection. Cold means an unpopulated actor only.
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
        var coldTreeCount = 0, coldVisibilityCount = 0
        for iteration in 0..<iterations {
            let step = (iteration + 1) % 2
            if fixture.cold { filter = SourceBrowserFilter() }
            let start = mode == "measure" ? DispatchTime.now().uptimeNanoseconds : 0
            let projected = await filter.project(
                input: fixture.inputs[step], revealsRulePreview: fixture.previews[step], query: fixture.queries[step])
            let duration = mode == "measure" ? DispatchTime.now().uptimeNanoseconds - start : 0
            guard let projected else { throw CancellationError() }
            if mode == "measure" { durations.append(duration) }
            // This materializes observable output and catches stale projections.
            // It is deliberately after the timer and is identical in both builds.
            receipts.append(Receipt(projected))
            if mode == "diagnose", fixture.cold {
                coldTreeCount += await filter.treeBuildCount
                coldVisibilityCount += await filter.visibilityBuildCount
            }
        }
        let treeCount: Int? = mode == "diagnose"
            ? (fixture.cold ? coldTreeCount : await filter.treeBuildCount) : nil
        let visibilityCount: Int? = mode == "diagnose"
            ? (fixture.cold ? coldVisibilityCount : await filter.visibilityBuildCount) : nil
        let record = Measurement(mode: mode, case: scenario, size: size, iterations: iterations,
                                 elapsed_ns: durations.reduce(0, +), durations_ns: durations, receipts: receipts,
                                 tree_build_count: treeCount, visibility_build_count: visibilityCount)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        print(String(decoding: try encoder.encode(record), as: UTF8.self))
    }
}
