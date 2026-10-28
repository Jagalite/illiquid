import Foundation
import IlliquidCore
#if os(Linux)
import Glibc
#else
import Darwin
#endif
@testable import IlliquidApp

// The component is the actual projection actor, matcher, row builder and models.
private struct Fixture {
    let inputs: [SourceTreeProjectionInput]
    let queries = ["", ""]
    let previews = [false, false]
    let cold = false

    init(size: Int, scenario: String) {
        let root = URL(fileURLWithPath: "/Volumes/Visibility Bench/Library", isDirectory: true)
        let depth: Int
        switch scenario {
        case "siblings_depth6", "hidden_near", "hidden_far", "no_rules": depth = 6
        case "groups_depth3", "interleaved_depth3", "unique_parent_depth3", "media_depth3": depth = 3
        case "root_children", "tree_direct": depth = 0
        default: preconditionFailure("Unknown scenario")
        }
        var entries: [SourceTreeEntry] = []
        for index in 0..<size {
            let group: Int
            switch scenario {
            case "groups_depth3": group = index / 25
            case "interleaved_depth3": group = index % 8
            case "unique_parent_depth3": group = index
            case "media_depth3": group = index / 100
            default: group = 0
            }
            var directory = root
            for level in 0..<depth {
                let name = (scenario == "hidden_near" && level == depth - 1)
                    || (scenario == "hidden_far" && level == 0)
                    ? "Suppressed"
                    : (level == 0 ? "Group \(group)" : "Level \(level)")
                directory.appendPathComponent(name, isDirectory: true)
            }
            let suffix = index.isMultiple(of: 11) ? " Trailer" : ""
            let name = "Show \(group).S01E\(index % 100 + 1) - Episode \(index + 1)\(suffix).mkv"
            let url = directory.appendingPathComponent(name, isDirectory: false)
            var entry = SourceTreeEntry(
                url: url, kind: .media,
                dateAdded: Date(timeIntervalSince1970: Double(1_700_000_000 + index)),
                creationDate: Date(timeIntervalSince1970: Double(1_600_000_000 + index)),
                visibilityPath: SourceVisibilityPath.normalized(url))
            // Normal recursive scans prepare this metadata before projection.
            entry.recognizedMedia = MediaNameRecognition.recognize(relativePath: url.path)
            entries.append(entry)
        }
        var first = SourceVisibilityConfiguration.default
        first.viewMode = scenario == "tree_direct" ? .tree
            : (scenario == "media_depth3" ? .media : .filesOnly)
        if scenario != "no_rules" {
            first.regexRules = [
                .init(id: "trailers", pattern: "Trailer", colorIndex: 1, isEnabled: true),
                .init(id: "samples", pattern: "(^|/)Sample[0-9]*$", colorIndex: 2, isEnabled: true),
                .init(id: "bonus", pattern: "(^|/)Bonus$", colorIndex: 3, isEnabled: true),
                .init(id: "suppressed", pattern: "(^|/)Suppressed$", colorIndex: 4, isEnabled: true),
            ]
        }
        var second = first
        second.showsHiddenItems = true
        let rootID = SourceTreeIdentity.folderID(for: root)
        // Preserve authored grouped/interleaved order. Name sorting is a separate
        // user setting; the miss controls model an order that mixes directories.
        let sort = SourceTreeSortConfiguration(name: .off, dateCreated: .off, type: .off)
        func input(_ visibility: SourceVisibilityConfiguration) -> SourceTreeProjectionInput {
            SourceTreeProjectionInput(
                items: [.init(kind: .folder, url: root)], visibility: visibility, roots: [root],
                directoryContents: [rootID: entries], directoryErrors: [:],
                recursiveMediaEntries: entries, expandedFolderIDs: [rootID], sortConfiguration: sort)
        }
        inputs = [input(first), input(second)]
    }
}

private func cpuNanoseconds() -> UInt64 {
    var time = timespec()
    precondition(clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &time) == 0)
    return UInt64(time.tv_sec) * 1_000_000_000 + UInt64(time.tv_nsec)
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
    let cpu_ns: UInt64
    let cpu_durations_ns: [UInt64]
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
        var cpuDurations: [UInt64] = []
        var receipts: [Receipt] = []
        var coldTreeCount = 0, coldVisibilityCount = 0
        for iteration in 0..<iterations {
            let step = (iteration + 1) % 2
            if fixture.cold { filter = SourceBrowserFilter() }
            let cpuStart = mode == "measure" ? cpuNanoseconds() : 0
            let start = mode == "measure" ? DispatchTime.now().uptimeNanoseconds : 0
            let projected = await filter.project(
                input: fixture.inputs[step], revealsRulePreview: fixture.previews[step], query: fixture.queries[step])
            let duration = mode == "measure" ? DispatchTime.now().uptimeNanoseconds - start : 0
            guard let projected else { throw CancellationError() }
            if mode == "measure" {
                durations.append(duration)
                cpuDurations.append(cpuNanoseconds() - cpuStart)
            }
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
                                 elapsed_ns: durations.reduce(0, +), durations_ns: durations,
                                 cpu_ns: cpuDurations.reduce(0, +), cpu_durations_ns: cpuDurations, receipts: receipts,
                                 tree_build_count: treeCount, visibility_build_count: visibilityCount)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        print(String(decoding: try encoder.encode(record), as: UTF8.self))
    }
}
