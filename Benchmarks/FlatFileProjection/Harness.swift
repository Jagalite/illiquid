import Foundation
import IlliquidCore
@testable import IlliquidApp
#if os(Linux)
import Glibc
#else
import Darwin
#endif
#if ALLOCATION_METER
import CAllocationMeter
#endif

// The measured entry point is the complete production rows() implementation in
// a separate library target. All fixture construction and receipts are untimed.
private struct Fixture {
    let input: SourceTreeProjectionInput
    let expectedCount: Int

    init(size: Int, scenario: String, sortOrder: String) {
        let media = scenario.hasSuffix("-media")
        let roots = ["Series α", "日本語", "Films café", "Releases 2026"].map {
            URL(fileURLWithPath: "/Volumes/Projection Study/" + $0, isDirectory: true)
        }
        var entries = (0..<size).map { index -> SourceTreeEntry in
            let root = roots[index % roots.count]
            let name = "Programme \(index / 100).S01E\(index % 100 + 1).Épisode \(index).1080p.{imdb-tt\(10000 + index)}.mkv"
            let url = root.appendingPathComponent("Season 01", isDirectory: true)
                .appendingPathComponent(name, isDirectory: false)
            var entry = SourceTreeEntry(url: url, kind: .media,
                dateAdded: index % 7 == 0 ? nil : Date(timeIntervalSince1970: Double(1_700_000_000 + index)),
                creationDate: Date(timeIntervalSince1970: Double(1_600_000_000 + index)),
                visibilityPath: SourceVisibilityPath.normalized(url))
            if media {
                var recognition = MediaNameRecognition.recognize(relativePath: url.path)
                recognition.metadataSources = index % 3 == 0 ? ["NFO", "PlexMatch"] : []
                entry.recognizedMedia = recognition
            }
            return entry
        }
        var random: UInt64 = 0x666c_6174_726f_7773
        for index in stride(from: entries.count - 1, through: 1, by: -1) {
            random = random &* 6_364_136_223_846_793_005 &+ 1
            entries.swapAt(index, Int(random % UInt64(index + 1)))
        }
        var items = roots.map { SourceTabItem(kind: .folder, url: $0) }
        var sourceRoots = roots
        var additionalCount = 0
        if scenario.hasPrefix("mixed-") {
            // Explicit overlaps and repeated explicit identities exercise the
            // merge path; new files remain present, including in media mode.
            items += entries.prefix(max(1, size / 10)).map { .init(kind: .file, url: $0.url) }
            items.append(.init(kind: .file, url: entries[0].url))
            for index in 0..<5 {
                let url = roots[index % roots.count].appendingPathComponent("Extra \(index) (2020).mkv")
                items.append(.init(kind: .file, url: url))
                if index == 0 { items.append(.init(kind: .file, url: url)) }
            }
            additionalCount = 5
        } else if scenario.hasPrefix("explicit-") {
            // Media mode loads explicit-file metadata. Files Only scans roots
            // without explicit files, so a file-only tab has no loaded entries.
            sourceRoots = []
            items = entries.map { .init(kind: .file, url: $0.url) }
            items += Array(items.prefix(3))
            if !media { entries = [] }
        }
        var visibility = SourceVisibilityConfiguration.default
        visibility.viewMode = media ? .media : .filesOnly
        input = SourceTreeProjectionInput(items: items, visibility: visibility,
            roots: sourceRoots, directoryContents: [:], directoryErrors: [:],
            recursiveMediaEntries: entries, expandedFolderIDs: [],
            sortConfiguration: .init(name: sortOrder == "name" ? .ascending : .off,
                dateCreated: sortOrder == "date" ? .descending : .off, type: .off))
        expectedCount = size + additionalCount
    }
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

@inline(never)
private func consume(_ rows: [SourceTreeDisplayRow]) -> Int {
    rows.count &* 31 &+ (rows.first?.id.utf8.count ?? 0)
        &+ (rows.last?.displayName.utf8.count ?? 0)
}

@main
private enum FlatFileProjectionBenchmark {
    static func main() throws {
        let arguments = CommandLine.arguments
        precondition(arguments.count >= 4)
        let mode = arguments[1], scenario = arguments[2], size = Int(arguments[3])!
        precondition(size > 0 && ["folders-files", "folders-media", "mixed-files", "mixed-media",
                                 "explicit-files", "explicit-media"].contains(scenario))
        let sortArgument = mode == "verify" ? 4 : 5
        precondition(arguments.count == sortArgument || arguments.count == sortArgument + 1)
        let sortOrder = arguments.count > sortArgument ? arguments[sortArgument] : "name"
        precondition(["name", "date", "off"].contains(sortOrder))
        let fixture = Fixture(size: size, scenario: scenario, sortOrder: sortOrder)
        var output: [String: Any] = ["mode": mode, "case": scenario, "size": size,
            "sort": sortOrder, "entry_stride_bytes": MemoryLayout<SourceTreeEntry>.stride,
            "index_stride_bytes": MemoryLayout<Int>.stride]
        #if ALLOCATION_METER
        output["allocation_instrumented"] = true
        #else
        output["allocation_instrumented"] = false
        #endif
        if mode == "verify" {
            let rows = fixture.input.rows()
            precondition(rows.count == fixture.expectedCount)
            precondition(Set(rows.map(\.id)).count == rows.count)
            output["rows"] = rows.map(rowTrace)
        } else {
            precondition(mode == "measure" && [5, 6].contains(arguments.count))
            let iterations = Int(arguments[4])!
            precondition(iterations > 0)
            var checksum = 0
            for _ in 0..<2 { checksum &+= consume(fixture.input.rows()) }
            var wall: [UInt64] = [], cpu: [Double] = []
            wall.reserveCapacity(iterations)
            cpu.reserveCapacity(iterations)
            #if ALLOCATION_METER
            var allocationRequests: [UInt64] = [], allocationBytes: [UInt64] = []
            allocationRequests.reserveCapacity(iterations)
            allocationBytes.reserveCapacity(iterations)
            #endif
            for _ in 0..<iterations {
                let cpuStart = clock()
                let start = DispatchTime.now().uptimeNanoseconds
                #if ALLOCATION_METER
                meter_begin()
                #endif
                let rows = fixture.input.rows()
                #if ALLOCATION_METER
                meter_end()
                #endif
                let elapsed = DispatchTime.now().uptimeNanoseconds - start
                let cpuElapsed = Double(clock() - cpuStart) / Double(CLOCKS_PER_SEC) * 1_000_000_000
                // Consumption and returned-row destruction are outside timing.
                precondition(rows.count == fixture.expectedCount)
                checksum &+= consume(rows)
                wall.append(elapsed)
                cpu.append(cpuElapsed)
                #if ALLOCATION_METER
                allocationRequests.append(meter_requests())
                allocationBytes.append(meter_bytes())
                #endif
            }
            output["iterations"] = iterations
            output["wall_ns"] = wall
            output["cpu_ns"] = cpu
            output["checksum"] = checksum
            output["output_count"] = fixture.expectedCount
            #if ALLOCATION_METER
            output["allocation_requests"] = allocationRequests
            output["allocation_requested_bytes"] = allocationBytes
            #endif
        }
        let data = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
