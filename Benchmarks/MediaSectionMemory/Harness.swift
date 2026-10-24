import Foundation
import IlliquidCore
@testable import IlliquidApp
#if os(Linux)
import Glibc
#else
import Darwin
#endif

// The actor, rows, metadata recognition and projection come from production
// sources. Fixtures precede the RSS sample; complete trace construction,
// expected-output loading, comparison and JSON encoding all follow it.
private struct Fixture {
    let input: SourceTreeProjectionInput
    let query: String
    let expectedFiles: Int

    init(size: Int, scenario: String) {
        let root = URL(fileURLWithPath: "/Volumes/Media Section Benchmark", isDirectory: true)
        // Each case-variant pair folds to one section. Distinct groups have
        // unambiguous localized ordering; normalization edge cases live in tests.
        let spellings = ["Étoile", "éTOILE", "Straße", "STRASSE", "Σίγμα", "σίΓΜΑ",
                         "東京物語", "東京物語"]
        var entries = (0..<size).map { index -> SourceTreeEntry in
            let name: String
            if scenario == "movies" {
                name = "Movie \(index) (2020).mkv"
            } else {
                let group = scenario == "unique_sections" ? index : (index / 20) % 50
                let title = scenario == "unicode_groups" ? spellings[index % spellings.count] : "Show \(group / 5)"
                let show = scenario == "unique_sections" ? "Distinct Show \(index)" : title
                let season = scenario == "unicode_groups" || scenario == "unique_sections" ? 1 : group % 5 + 1
                let marker = index % 100 == 0 ? " selected-marker" : ""
                name = "\(show).S\(season)E\(index % 20 + 1) - Episode \(index)\(marker).mkv"
            }
            let url = root.appendingPathComponent(name, isDirectory: false)
            var entry = SourceTreeEntry(
                url: url, kind: .media,
                dateAdded: Date(timeIntervalSince1970: Double(1_700_000_000 + index)),
                creationDate: Date(timeIntervalSince1970: Double(1_600_000_000 + index)),
                visibilityPath: SourceVisibilityPath.normalized(url))
            entry.recognizedMedia = MediaNameRecognition.recognize(relativePath: url.path)
            precondition(entry.recognizedMedia?.kind == (scenario == "movies" ? .movie : .episode))
            return entry
        }
        var state: UInt64 = 0x6d65_6469_612d_7365
        if size > 1 {
            for index in stride(from: size - 1, through: 1, by: -1) {
                state = state &* 6_364_136_223_846_793_005 &+ 1
                entries.swapAt(index, Int(state % UInt64(index + 1)))
            }
        }
        var visibility = SourceVisibilityConfiguration.default
        visibility.viewMode = scenario == "files_control" ? .filesOnly
            : scenario == "tree_control" ? .tree : .media
        query = scenario == "broad_search" ? "Episode"
            : scenario == "narrow_search" ? "selected-marker" : ""
        expectedFiles = scenario == "narrow_search" ? (size + 99) / 100 : size
        input = SourceTreeProjectionInput(
            items: [.init(kind: .folder, url: root)], visibility: visibility, roots: [root],
            directoryContents: [SourceTreeIdentity.folderID(for: root): entries], directoryErrors: [:],
            recursiveMediaEntries: entries, expandedFolderIDs: [SourceTreeIdentity.folderID(for: root)],
            sortConfiguration: .init(name: .off, dateCreated: .off, type: .off))
    }
}

private struct MediaTrace: Codable, Equatable {
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

private struct VisibilityMatchTrace: Codable, Equatable {
    let kind: String
    let id: String?
    let colorIndex: Int?

    init(_ match: SourceVisibilityHideMatch) {
        switch match {
        case .manual: kind = "manual"; id = nil; colorIndex = nil
        case .noMedia: kind = "noMedia"; id = nil; colorIndex = nil
        case let .regex(rule): kind = "regex"; id = rule.id; colorIndex = rule.colorIndex
        }
    }
}

private struct RowTrace: Codable, Equatable {
    let id: String
    let folderID: String
    let url: String
    let displayName: String
    let contextLabel: String?
    let recognizedMedia: MediaTrace?
    let visibilityPath: String?
    let depth: Int
    let ancestorIDs: [String]
    let kind: String
    let isRoot: Bool?
    let dateAddedBits: String?
    let message: String?
    let visibilityMatches: [VisibilityMatchTrace]?
    let visibilityInherited: Bool?
    let containsSupportedMedia: Bool?

    init(_ row: SourceTreeDisplayRow) {
        id = row.id; folderID = row.folderID; url = row.url.absoluteString
        displayName = row.displayName; contextLabel = row.contextLabel
        recognizedMedia = row.recognizedMedia.map(MediaTrace.init)
        visibilityPath = row.visibilityPath; depth = row.depth; ancestorIDs = row.ancestorIDs
        switch row.kind {
        case let .folder(root):
            kind = "folder"; isRoot = root; dateAddedBits = nil; message = nil
        case let .media(date):
            kind = "media"; isRoot = nil
            dateAddedBits = date.map { String($0.timeIntervalSince1970.bitPattern) }; message = nil
        case let .message(value):
            kind = "message"; isRoot = nil; dateAddedBits = nil; message = value
        case .mediaSection:
            kind = "mediaSection"; isRoot = nil; dateAddedBits = nil; message = nil
        }
        visibilityMatches = row.visibility.map { $0.matches.map(VisibilityMatchTrace.init) }
        visibilityInherited = row.visibility?.isInherited
        containsSupportedMedia = row.containsSupportedMedia
    }
}

private struct ProjectionTrace: Codable, Equatable {
    let rows: [RowTrace]
    let hiddenCount: Int
    let regexCounts: [String: Int]
    let thumbnailCandidates: [String]
    let mediaPaths: [String]

    init(_ projection: SourceBrowserProjection) {
        rows = projection.rows.map(RowTrace.init)
        hiddenCount = projection.hiddenCount; regexCounts = projection.regexCounts
        thumbnailCandidates = projection.thumbnailCandidates.map(\.absoluteString)
        mediaPaths = projection.mediaPaths.sorted()
    }
}

private func cpuNanoseconds() -> UInt64 {
    var value = timespec()
    precondition(clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &value) == 0)
    return UInt64(value.tv_sec) * 1_000_000_000 + UInt64(value.tv_nsec)
}

private func peakResidentBytes() -> UInt64 {
    var usage = rusage()
    #if os(Linux)
    precondition(getrusage(Int32(RUSAGE_SELF.rawValue), &usage) == 0)
    return UInt64(usage.ru_maxrss) * 1024
    #else
    precondition(getrusage(RUSAGE_SELF, &usage) == 0)
    return UInt64(usage.ru_maxrss)
    #endif
}

@main
private struct MediaSectionMemoryBenchmark {
    static func main() async throws {
        let args = CommandLine.arguments
        precondition(args.count >= 4,
                     "verify CASE SIZE | measure CASE SIZE cold|refresh ITERATIONS EXPECTED_JSON")
        let mode = args[1], scenario = args[2]
        let scenarios = ["movies", "seasons", "unicode_groups", "unique_sections",
                         "broad_search", "narrow_search", "files_control", "tree_control"]
        precondition(scenarios.contains(scenario))
        guard let size = Int(args[3]), size > 0 else { fatalError("Invalid size") }
        let fixture = Fixture(size: size, scenario: scenario)
        let actor = SourceBrowserFilter()
        func project() async throws -> SourceBrowserProjection {
            guard let value = await actor.project(input: fixture.input, revealsRulePreview: false,
                                                 query: fixture.query) else { throw CancellationError() }
            return value
        }
        if mode == "verify" {
            precondition(args.count == 4)
            let initial = ProjectionTrace(try await project())
            validate(initial, expectedFiles: fixture.expectedFiles)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            print(String(decoding: try encoder.encode(initial), as: UTF8.self))
            return
        }
        precondition(mode == "measure" && args.count == 7)
        let measurement = args[4]
        precondition(measurement == "cold" || measurement == "refresh")
        guard let iterations = Int(args[5]), iterations > 0 else { fatalError("Invalid iterations") }
        precondition(measurement != "cold" || iterations == 1)
        // Retain the preceding projection while its replacement is computed,
        // as a caller displaying the current rows would. No trace is made here.
        var final: SourceBrowserProjection?
        if measurement == "refresh" { final = try await project() }
        var checksum: UInt64 = 0
        let before = peakResidentBytes()
        let cpuStart = cpuNanoseconds()
        let wallStart = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<iterations {
            let next = try await project()
            withExtendedLifetime(final) {}
            checksum &+= UInt64(next.rows.count)
            checksum &+= UInt64(next.rows.first?.id.utf8.count ?? 0)
            checksum &+= UInt64(next.rows.last?.id.utf8.count ?? 0)
            final = next
        }
        // Capture before allocating any complete trace or reading its oracle.
        let after = peakResidentBytes()
        let elapsed = DispatchTime.now().uptimeNanoseconds - wallStart
        let cpu = cpuNanoseconds() - cpuStart
        guard let final else { fatalError("Missing projection") }
        let trace = ProjectionTrace(final)
        validate(trace, expectedFiles: fixture.expectedFiles)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var encoded = try encoder.encode(trace)
        encoded.append(0x0a) // Match verify's print terminator, without text normalization.
        let expected = try Data(contentsOf: URL(fileURLWithPath: args[6]))
        precondition(encoded == expected, "Complete final UTF-8 output differs from baseline")
        let treeBuilds = await actor.treeBuildCount
        let visibilityBuilds = await actor.visibilityBuildCount
        precondition(treeBuilds == 1 && visibilityBuilds == 1, "Measured projection rebuilt its input cache")
        let result: [String: Any] = [
            "case": scenario, "size": size, "measurement": measurement,
            "iterations": iterations, "priming_projections": measurement == "refresh" ? 1 : 0,
            "elapsed_ns": elapsed, "cpu_ns": cpu, "checksum": checksum,
            "process_peak_rss_before_bytes": before, "process_peak_rss_after_bytes": after,
            "process_peak_rss_growth_bytes": after - before,
            "row_stride_bytes": MemoryLayout<SourceTreeDisplayRow>.stride,
            "index_stride_bytes": MemoryLayout<Int>.stride,
            "rows": final.rows.count, "sections": final.rows.filter { $0.kind == .mediaSection }.count,
            "tree_build_count": treeBuilds, "visibility_build_count": visibilityBuilds,
            "complete_output_verified": true,
            "complete_output_byte_verified": true,
        ]
        print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
    }

    private static func validate(_ trace: ProjectionTrace, expectedFiles: Int) {
        precondition(trace.rows.filter { $0.kind == "media" }.count == expectedFiles)
        precondition(Set(trace.rows.map(\.id)).count == trace.rows.count)
        precondition(trace.mediaPaths.count == expectedFiles)
        precondition(trace.thumbnailCandidates.count == min(2048, expectedFiles))
        precondition(trace.hiddenCount == 0 && trace.regexCounts.isEmpty)
    }
}
