import Dispatch
import Foundation
import IlliquidCore
@testable import IlliquidApp
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

private let cases = ["precomputed_episodes", "unprepared_episodes", "mixed_library",
                     "movies_control", "cached_projection_control"]

private struct Fixture {
    let input: SourceTreeProjectionInput

    init(name: String, size: Int) {
        let root = URL(fileURLWithPath: "/Volumes/Display Name Benchmark", isDirectory: true)
        var entries: [SourceTreeEntry] = []
        for index in 0..<size {
            let season = index / 24 % 6
            let episode = index % 24 + 1
            let path: String
            let kind = name == "movies_control" ? 0 : name == "mixed_library" ? index % 6 : 5
            switch kind {
            case 0:
                path = "Movies/Movie \(index) (2020).mkv"
            case 1:
                let day = index % 28 + 1
                path = "News/News - 2024-03-\(day < 10 ? "0" : "")\(day) - Headlines \(index).mkv"
            case 2:
                path = "Clips/Uncatalogued clip \(index).mkv"
            case 3:
                path = "Extras/Behind the scenes \(index).mkv"
            default:
                let show = index.isMultiple(of: 5) ? "世界の物語" : "Show \(index / 144 % 8)"
                let range = index.isMultiple(of: 7) ? "-E\(episode + 1)" : ""
                path = "\(show) (2020)/Season \(season)/\(show).S\(season)E\(episode)\(range) - Episode \(index).mkv"
            }
            let url = root.appendingPathComponent(path, isDirectory: false)
            var entry = SourceTreeEntry(url: url, kind: .media,
                dateAdded: Date(timeIntervalSince1970: Double(1_700_000_000 + index)),
                creationDate: Date(timeIntervalSince1970: Double(1_600_000_000 + index)),
                visibilityPath: SourceVisibilityPath.normalized(url))
            if name != "unprepared_episodes" {
                var recognized = MediaNameRecognition.recognize(relativePath: url.path)
                if index.isMultiple(of: 4) { recognized.metadataSources = [".plexmatch"] }
                entry.recognizedMedia = recognized
                if name == "movies_control" { precondition(recognized.kind == .movie) }
                if name == "precomputed_episodes" || name == "cached_projection_control" {
                    precondition(recognized.kind == .episode && recognized.airDate == nil)
                }
            }
            entries.append(entry)
        }
        // The production default sorts by descending creation date. All dates
        // are distinct; source order still differs from projected order.
        var visibility = SourceVisibilityConfiguration.default
        visibility.viewMode = .media
        input = SourceTreeProjectionInput(items: [.init(kind: .folder, url: root)],
            visibility: visibility, roots: [root], directoryContents: [:], directoryErrors: [:],
            recursiveMediaEntries: entries, expandedFolderIDs: [],
            sortConfiguration: .init(name: .off, dateCreated: .descending, type: .off))
    }
}

private func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

// Byte arrays preserve Unicode normalization and embedded NUL differences that
// Swift String equality alone could hide. All result fields are represented.
private struct MediaTrace: Codable {
    let kind: String
    let title: [UInt8]
    let year: Int?
    let season: Int?
    let episode: Int?
    let lastEpisode: Int?
    let airDate: [UInt8]?
    let episodeTitle: [UInt8]?
    let edition: [UInt8]?
    let catalogIDs: [[UInt8]]
    let variant: [UInt8]?
    let metadataSources: [[UInt8]]
    let displayName: [UInt8]
    let seriesTitle: [UInt8]
    let section: [UInt8]

    init(_ value: RecognizedMediaName) {
        kind = value.kind.rawValue; title = bytes(value.title); year = value.year
        season = value.season; episode = value.episode; lastEpisode = value.lastEpisode
        airDate = value.airDate.map(bytes); episodeTitle = value.episodeTitle.map(bytes)
        edition = value.edition.map(bytes); catalogIDs = value.catalogIDs.map(bytes)
        variant = value.variant.map(bytes); metadataSources = value.metadataSources.map(bytes)
        displayName = bytes(value.displayName); seriesTitle = bytes(value.seriesTitle)
        section = bytes(value.section)
    }
}

private struct MatchTrace: Codable {
    let kind: String
    let id: [UInt8]?
    let colorIndex: Int?
    init(_ match: SourceVisibilityHideMatch) {
        switch match {
        case .manual: kind = "manual"; id = nil; colorIndex = nil
        case .noMedia: kind = "noMedia"; id = nil; colorIndex = nil
        case let .regex(value): kind = "regex"; id = bytes(value.id); colorIndex = value.colorIndex
        }
    }
}

private struct RowTrace: Codable {
    let id: [UInt8]
    let folderID: [UInt8]
    let url: [UInt8]
    let displayName: [UInt8]
    let contextLabel: [UInt8]?
    let recognizedMedia: MediaTrace?
    let visibilityPath: [UInt8]?
    let depth: Int
    let ancestorIDs: [[UInt8]]
    let kind: String
    let isRoot: Bool?
    let dateAddedBits: UInt64?
    let message: [UInt8]?
    let visibilityMatches: [MatchTrace]?
    let visibilityInherited: Bool?
    let containsSupportedMedia: Bool?

    init(_ row: SourceTreeDisplayRow) {
        id = bytes(row.id); folderID = bytes(row.folderID); url = bytes(row.url.absoluteString)
        displayName = bytes(row.displayName); contextLabel = row.contextLabel.map(bytes)
        recognizedMedia = row.recognizedMedia.map(MediaTrace.init)
        visibilityPath = row.visibilityPath.map(bytes); depth = row.depth
        ancestorIDs = row.ancestorIDs.map(bytes)
        switch row.kind {
        case let .folder(root): kind = "folder"; isRoot = root; dateAddedBits = nil; message = nil
        case let .media(date):
            kind = "media"; isRoot = nil; dateAddedBits = date?.timeIntervalSince1970.bitPattern; message = nil
        case let .message(text): kind = "message"; isRoot = nil; dateAddedBits = nil; message = bytes(text)
        case .mediaSection: kind = "mediaSection"; isRoot = nil; dateAddedBits = nil; message = nil
        }
        visibilityMatches = row.visibility.map { $0.matches.map(MatchTrace.init) }
        visibilityInherited = row.visibility?.isInherited
        containsSupportedMedia = row.containsSupportedMedia
    }
}

private struct Trace: Codable {
    let rows: [RowTrace]
    let hiddenCount: Int?
    let regexCounts: [String: Int]?
    let thumbnailCandidates: [[UInt8]]?
    let mediaPaths: [[UInt8]]?
    init(rows: [SourceTreeDisplayRow], projection: SourceBrowserProjection?) {
        self.rows = rows.map(RowTrace.init)
        hiddenCount = projection?.hiddenCount; regexCounts = projection?.regexCounts
        thumbnailCandidates = projection?.thumbnailCandidates.map { bytes($0.absoluteString) }
        mediaPaths = projection?.mediaPaths.map(bytes).sorted { $0.lexicographicallyPrecedes($1) }
    }
}

private func cpuNanoseconds() -> UInt64 {
    var value = timespec()
    precondition(clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &value) == 0)
    return UInt64(value.tv_sec) * 1_000_000_000 + UInt64(value.tv_nsec)
}

@main
private enum Harness {
    static func main() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count >= 3, ["verify", "measure"].contains(args[0]), cases.contains(args[1]),
              let size = Int(args[2]), size > 0 else { fatalError("verify CASE SIZE | measure CASE SIZE ITERATIONS EXPECTED") }
        let verification = args[0] == "verify"
        guard args.count == (verification ? 3 : 5) else { fatalError("Wrong argument count") }
        let iterations = verification ? 1 : Int(args[3]) ?? 0
        precondition(iterations > 0)
        let fixture = Fixture(name: args[1], size: size)
        let cached = args[1] == "cached_projection_control"
        let actor = SourceBrowserFilter()
        var finalRows: [SourceTreeDisplayRow] = []
        var finalProjection: SourceBrowserProjection?
        if cached {
            finalProjection = await actor.project(input: fixture.input, revealsRulePreview: false, query: "")
            precondition(finalProjection != nil)
        } else {
            finalRows = fixture.input.rows()
        }
        var checksum = 0
        let cpuStarted = cpuNanoseconds()
        let started = DispatchTime.now().uptimeNanoseconds
        if cached {
            for _ in 0..<iterations {
                guard let next = await actor.project(input: fixture.input, revealsRulePreview: false, query: "")
                else { fatalError("Unexpected cancellation") }
                withExtendedLifetime(finalProjection) {}
                checksum &+= next.rows.count
                finalProjection = next
            }
        } else {
            for _ in 0..<iterations {
                let next = fixture.input.rows()
                withExtendedLifetime(finalRows) {}
                checksum &+= next.count
                finalRows = next
            }
        }
        let elapsed = DispatchTime.now().uptimeNanoseconds - started
        let cpuElapsed = cpuNanoseconds() - cpuStarted
        if let finalProjection { finalRows = finalProjection.rows }
        precondition(finalRows.filter { if case .media = $0.kind { true } else { false } }.count == size)
        precondition(Set(finalRows.map(\.id)).count == finalRows.count)
        let treeBuilds = await actor.treeBuildCount
        let visibilityBuilds = await actor.visibilityBuildCount
        precondition(treeBuilds == (cached ? 1 : 0) && visibilityBuilds == (cached ? 1 : 0))
        let trace = Trace(rows: finalRows, projection: finalProjection)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(trace)
        data.append(0x0a)
        if verification {
            FileHandle.standardOutput.write(data)
        } else {
            let expected = try Data(contentsOf: URL(fileURLWithPath: args[4]))
            precondition(data == expected, "Complete row/projection output differs from baseline")
            let result: [String: Any] = [
                "case": args[1], "size": size, "iterations": iterations,
                "elapsed_ns": elapsed, "cpu_ns": cpuElapsed,
                "rows": finalRows.count, "checksum": checksum, "full_output_equal": true,
                "tree_builds": treeBuilds, "visibility_builds": visibilityBuilds,
            ]
            print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
        }
    }
}
