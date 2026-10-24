import CVisibilityHeap
import Foundation
import IlliquidCore
@testable import IlliquidApp

private struct Fixture: Sendable {
    let rows: [SourceTreeDisplayRow]
    let input: SourceTreeProjectionInput?
    let configuration: SourceVisibilityConfiguration
    let root: URL
    let preview: Bool

    init(size: Int, scenario: String) {
        let root = URL(fileURLWithPath: "/Volumes/Visibility Library/Series α", isDirectory: true)
        self.root = root
        var configuration = SourceVisibilityConfiguration.default
        if scenario == "nonmatching_rule" {
            configuration.regexRules = [.init(id: "absent", pattern: "WillNeverMatch", colorIndex: 2, isEnabled: true)]
        } else if scenario == "hide_half" || scenario == "preview" {
            configuration.regexRules = [.init(id: "hidden", pattern: "Hidden", colorIndex: 2, isEnabled: true)]
        }
        let values = (0..<size).map { index -> SourceTreeDisplayRow in
            let name = String(format: "%06d", index) + (index.isMultiple(of: 2) ? " Hidden" : " Visible")
            let url = root.appendingPathComponent(name + ".mkv", isDirectory: false)
            return SourceTreeDisplayRow(id: "media:" + url.path, folderID: root.path,
                url: url, displayName: name, contextLabel: "Season 01", visibilityPath: url.path,
                depth: 0, ancestorIDs: [], kind: .media(dateAdded: Date(timeIntervalSince1970: Double(index))))
        }
        if ["hide_last", "preview_last"].contains(scenario), let last = values.last {
            configuration.manuallyHiddenPaths = [last.visibilityPath!]
        } else if scenario == "hide_penultimate", values.count > 1 {
            configuration.manuallyHiddenPaths = [values[values.count - 2].visibilityPath!]
        } else if scenario == "keep_one" {
            configuration.manuallyHiddenPaths = Set(values.dropLast().compactMap(\.visibilityPath))
        }
        if scenario == "tree_input" {
            let entries = values.map { row in
                SourceTreeEntry(url: row.url, kind: .media, dateAdded: nil,
                                creationDate: nil, visibilityPath: row.visibilityPath)
            }
            input = SourceTreeProjectionInput(items: [.init(kind: .folder, url: root)],
                visibility: configuration, roots: [root], directoryContents: [root.path: entries],
                directoryErrors: [:], recursiveMediaEntries: [], expandedFolderIDs: [],
                sortConfiguration: .init(name: .ascending, dateCreated: .off, type: .off))
            rows = []
        } else {
            rows = values
            input = nil
        }
        self.configuration = configuration
        preview = scenario == "preview" || scenario == "preview_last"
    }
}

private struct HeldProjection {
    let filter: SourceBrowserFilter
    let projection: SourceBrowserProjection
}

private enum Failure: Error { case arguments, cancelled, unsupportedMetric }

@inline(never)
private func project(_ fixture: Fixture) async throws -> HeldProjection {
    let filter = SourceBrowserFilter()
    let result: SourceBrowserProjection?
    if let input = fixture.input {
        result = await filter.project(input: input, revealsRulePreview: fixture.preview, query: "")
    } else {
        result = await filter.project(rows: fixture.rows, configuration: fixture.configuration,
            roots: [fixture.root], revealsRulePreview: fixture.preview, query: "")
    }
    guard let result else { throw Failure.cancelled }
    return HeldProjection(filter: filter, projection: result)
}

// Complete, length-delimited UTF-8 value encoding. Constructed only after the
// retained-allocation and timing samples. Verification compares every byte.
private struct Snapshot {
    var data = Data()
    mutating func add(_ value: UInt64) {
        var word = value.littleEndian
        withUnsafeBytes(of: &word) { data.append(contentsOf: $0) }
    }
    mutating func add(_ text: String) {
        add(UInt64(text.utf8.count)); data.append(contentsOf: text.utf8)
    }
    mutating func add(_ text: String?) {
        add(text == nil ? UInt64(0) : UInt64(1))
        if let text { add(text) }
    }
    mutating func add(_ number: Int?) { add(number.map(String.init)) }
    init(_ projection: SourceBrowserProjection) {
        add(UInt64(projection.rows.count))
        for row in projection.rows {
            add(row.id); add(row.folderID); add(row.url.absoluteString)
            add(row.displayName); add(row.contextLabel); add(row.visibilityPath)
            add(UInt64(row.depth)); add(UInt64(row.ancestorIDs.count))
            for ancestor in row.ancestorIDs { add(ancestor) }
            switch row.kind {
            case let .folder(isRoot): add("folder"); add(isRoot ? UInt64(1) : UInt64(0))
            case let .media(dateAdded): add("media"); add(dateAdded.map { String($0.timeIntervalSince1970.bitPattern) })
            case let .message(message): add("message"); add(message)
            case .mediaSection: add("mediaSection")
            }
            if let visibility = row.visibility {
                add(UInt64(1)); add(visibility.isInherited ? UInt64(1) : UInt64(0))
                add(UInt64(visibility.matches.count))
                for match in visibility.matches {
                    switch match {
                    case .manual: add("manual")
                    case .noMedia: add("noMedia")
                    case let .regex(rule): add("regex"); add(rule.id); add(UInt64(rule.colorIndex))
                    }
                }
            } else { add(UInt64(0)) }
            add(row.containsSupportedMedia.map { $0 ? "true" : "false" })
            if let media = row.recognizedMedia {
                add(UInt64(1)); add(media.kind.rawValue); add(media.title)
                add(media.year); add(media.season); add(media.episode); add(media.lastEpisode)
                add(media.airDate); add(media.episodeTitle); add(media.edition); add(media.variant)
                add(UInt64(media.catalogIDs.count)); for id in media.catalogIDs { add(id) }
                add(UInt64(media.metadataSources.count)); for source in media.metadataSources { add(source) }
            } else { add(UInt64(0)) }
        }
        add(UInt64(projection.hiddenCount)); add(UInt64(projection.regexCounts.count))
        for key in projection.regexCounts.keys.sorted() { add(key); add(UInt64(projection.regexCounts[key]!)) }
        add(UInt64(projection.thumbnailCandidates.count))
        for url in projection.thumbnailCandidates { add(url.absoluteString) }
        add(UInt64(projection.mediaPaths.count)); for path in projection.mediaPaths.sorted() { add(path) }
    }
    var checksum: String {
        String(data.reduce(UInt64(14_695_981_039_346_656_037)) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }, radix: 16)
    }
}

private struct Observation: Encodable {
    let scenario: String
    let size: Int
    let heap_metric: String
    let heap_before: UInt64
    let heap_live: UInt64
    let retained_allocator_delta_bytes: Int64
    let wall_nanoseconds: UInt64
    let cpu_nanoseconds: UInt64
    let row_stride: Int
    let input_row_capacity: Int?
    let output_row_capacity: Int
    let output_rows: Int
    let hidden_count: Int
    let regex_counts: [String: Int]
    let thumbnail_count: Int
    let media_path_count: Int
    let input_output_share_rows: Bool?
    let snapshot_bytes: Int
    let snapshot_checksum: String
}

@main private struct VisibilityStorageBenchmark {
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count == 4 || args.count == 5,
              ["measure", "verify"].contains(args[1]), let size = Int(args[3]), size >= 0,
              ["unchanged", "nonmatching_rule", "hide_half", "hide_last", "preview", "tree_input",
               "hide_penultimate", "preview_last", "keep_one"].contains(args[2])
        else { throw Failure.arguments }
        let metric = String(cString: visibility_heap_metric())
        guard metric != "unsupported" else { throw Failure.unsupportedMetric }
        // Warm actor, Foundation, matcher and diagnostic paths with independent
        // tiny fixtures; retain none of these objects across the measured call.
        for _ in 0..<3 {
            let warm = try await project(Fixture(size: 8, scenario: args[2]))
            _ = Snapshot(warm.projection).checksum
            _ = withExtendedLifetime(warm) { visibility_heap_bytes() }
        }
        let fixture = Fixture(size: size, scenario: args[2])
        let heapBefore = visibility_heap_bytes()
        let cpuBefore = visibility_cpu_nanoseconds()
        let wallBefore = DispatchTime.now().uptimeNanoseconds
        let held = try await project(fixture)
        let wall = DispatchTime.now().uptimeNanoseconds - wallBefore
        let cpu = visibility_cpu_nanoseconds() - cpuBefore
        let live = withExtendedLifetime((fixture, held)) { visibility_heap_bytes() }
        let result = held.projection
        let shares: Bool? = fixture.input == nil && size > 0 ? fixture.rows.withUnsafeBufferPointer { input in
            result.rows.withUnsafeBufferPointer { output in input.baseAddress == output.baseAddress }
        } : nil
        let snapshot = Snapshot(result)
        if args[1] == "verify" {
            guard args.count == 5 else { throw Failure.arguments }
            try snapshot.data.write(to: URL(fileURLWithPath: args[4]))
        }
        let observation = Observation(scenario: args[2], size: size, heap_metric: metric,
            heap_before: heapBefore, heap_live: live,
            retained_allocator_delta_bytes: Int64(live) - Int64(heapBefore),
            wall_nanoseconds: wall, cpu_nanoseconds: cpu, row_stride: MemoryLayout<SourceTreeDisplayRow>.stride,
            input_row_capacity: fixture.input == nil ? fixture.rows.capacity : nil,
            output_row_capacity: result.rows.capacity,
            output_rows: result.rows.count, hidden_count: result.hiddenCount,
            regex_counts: result.regexCounts, thumbnail_count: result.thumbnailCandidates.count,
            media_path_count: result.mediaPaths.count, input_output_share_rows: shares,
            snapshot_bytes: snapshot.data.count, snapshot_checksum: snapshot.checksum)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let output = try withExtendedLifetime((fixture, held)) { try encoder.encode(observation) }
        print(String(decoding: output, as: UTF8.self))
    }
}
