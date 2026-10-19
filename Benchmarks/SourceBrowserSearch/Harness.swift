import Foundation
@testable import IlliquidApp
@testable import IlliquidCore
#if os(Linux)
import Glibc
#else
import Darwin
#endif
#if ALLOCATION_METER
import CAllocationMeter
#endif

/// Complete search and cached actor projection, using production row values.
/// Fixture construction, the old-source oracle, warmup, and full result checks
/// are outside the timed region. The production module is compiled separately.
@main
struct SourceSearchBenchmark {
    static func cpuNanoseconds() -> UInt64 {
        var value = timespec()
        precondition(clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &value) == 0)
        return UInt64(value.tv_sec) * 1_000_000_000 + UInt64(value.tv_nsec)
    }

    static func fixture(count: Int, depth: Int, kind: String) -> [SourceTreeDisplayRow] {
        var rows: [SourceTreeDisplayRow] = []
        rows.reserveCapacity(count + ((count + 99) / 100) * depth)
        let recognition = MediaNameRecognition.recognize(
            relativePath: "/library/Example Show (2020)/Season 01/Example.Show.S01E01.mkv"
        )
        var ancestors: [String] = []
        var parentPath = ""
        for index in 0..<count {
            let group = index / 100
            if index % 100 == 0 {
                ancestors = []
                parentPath = "/Volumes/Media/group-\(group)"
                for level in 0..<depth {
                    if level > 0 { parentPath += "/level-\(level)" }
                    let path = parentPath
                    let id = "folder:\(path)"
                    rows.append(SourceTreeDisplayRow(
                        id: id, folderID: path, url: URL(fileURLWithPath: path),
                        displayName: "Collection \(group) level \(level)", depth: level,
                        ancestorIDs: ancestors, kind: .folder(isRoot: level == 0)
                    ))
                    ancestors.append(id)
                }
            }
            let file = "\(parentPath)/Episode-\(index).raw-tag.mkv"
            let name = kind == "unicode" ? "Épisode 日本語 \(index)"
                : "Episode \(index)" + (index % 100 == 99 ? " selected-marker" : "")
            rows.append(SourceTreeDisplayRow(
                id: "media:\(file)", folderID: parentPath,
                url: URL(fileURLWithPath: file), displayName: name,
                contextLabel: kind == "metadata" ? "Library context" : nil,
                recognizedMedia: kind == "metadata" ? recognition : nil,
                depth: depth, ancestorIDs: ancestors, kind: .media(dateAdded: nil)
            ))
        }
        return rows
    }

    static func fingerprint(_ rows: [SourceTreeDisplayRow]) -> String {
        // Stable FNV-1a receipt (not Swift's randomized Hasher). Exact row
        // equality against the original source is checked separately below.
        var value: UInt64 = 14_695_981_039_346_656_037
        func append(_ text: String) {
            for byte in text.utf8 { value = (value ^ UInt64(byte)) &* 1_099_511_628_211 }
            value = (value ^ 0xff) &* 1_099_511_628_211
        }
        for row in rows {
            append(row.id)
            append(row.url.absoluteString)
            append(row.displayName)
            for id in row.ancestorIDs { append(id) }
        }
        return String(value, radix: 16)
    }

    static func main() async throws {
        let arguments = CommandLine.arguments
        precondition(arguments.count == 7,
                     "usage: SearchBenchmark operation count depth kind iterations warmup")
        let operation = arguments[1]
        let count = Int(arguments[2])!
        let depth = Int(arguments[3])!
        let kind = arguments[4]
        let iterations = Int(arguments[5])!
        let warmup = Int(arguments[6])!
        precondition(count > 0 && depth >= 0 && iterations > 0 && warmup >= 0)
        precondition(operation == "search" || operation == "project")
        let query: String
        switch kind {
        case "broad": query = "episode"
        case "sparse": query = "selected-marker"
        case "none": query = "not-present-anywhere"
        case "blank": query = " \n\t"
        case "unicode": query = "ÉPISODE"
        case "metadata": query = "raw-tag"
        default: fatalError("unknown fixture kind")
        }
        let rows = fixture(count: count, depth: depth, kind: kind)
        let expectedRows = BaselineSourceBrowserSearch.search(rows, query: query)
        precondition(SourceBrowserFilter.search(rows, query: query) == expectedRows)
        let expectedProjection = SourceBrowserProjection(rows: expectedRows, hiddenCount: 0, regexCounts: [:])
        let actor = SourceBrowserFilter()
        if operation == "project" {
            // Prime the unchanged visibility cache. The measured query still
            // performs its normal result/thumbnail/path projection work.
            let primed = await actor.project(rows: rows, configuration: .default,
                                             roots: [], revealsRulePreview: false, query: "")
            precondition(primed?.rows == rows)
        }

        var checksum: UInt64 = 0
        var finalRows: [SourceTreeDisplayRow] = []
        var finalProjection: SourceBrowserProjection?
        for _ in 0..<warmup {
            if operation == "search" {
                finalRows = SourceBrowserFilter.search(rows, query: query)
            } else {
                finalProjection = await actor.project(rows: rows, configuration: .default,
                    roots: [], revealsRulePreview: false, query: query)
                finalRows = finalProjection!.rows
            }
            checksum &+= UInt64(finalRows.count)
        }
        finalRows = []
        finalProjection = nil

        #if ALLOCATION_METER
        meter_begin()
        #endif
        let cpuStart = cpuNanoseconds()
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<iterations {
            if operation == "search" {
                finalRows = SourceBrowserFilter.search(rows, query: query)
            } else {
                finalProjection = await actor.project(rows: rows, configuration: .default,
                    roots: [], revealsRulePreview: false, query: query)
                finalRows = finalProjection!.rows
            }
            // Consume the result at the separately compiled call boundary.
            // Full equality and stable receipts are checked outside timing.
            checksum &+= UInt64(finalRows.count)
            checksum &+= UInt64(finalRows.first?.id.utf8.count ?? 0)
            checksum &+= UInt64(finalRows.last?.id.utf8.count ?? 0)
        }
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        let cpu = cpuNanoseconds() - cpuStart
        #if ALLOCATION_METER
        meter_end()
        #endif

        precondition(finalRows == expectedRows, "Full row result differs from pinned source")
        if operation == "project" {
            precondition(finalProjection?.thumbnailCandidates == expectedProjection.thumbnailCandidates)
            precondition(finalProjection?.mediaPaths == expectedProjection.mediaPaths)
            precondition(finalProjection?.hiddenCount == 0 && finalProjection?.regexCounts == [:])
            let visibilityBuildCount = await actor.visibilityBuildCount
            precondition(visibilityBuildCount == 1)
        }
        var result: [String: Any] = [
            "operation": operation, "media_count": count, "depth": depth, "kind": kind,
            "input_rows": rows.count, "output_rows": finalRows.count,
            "iterations": iterations, "warmup": warmup,
            "elapsed_ns": elapsed, "cpu_ns": cpu, "checksum": checksum,
            "fingerprint": fingerprint(finalRows), "oracle_equal": true,
        ]
        #if ALLOCATION_METER
        result["allocation_requests"] = meter_requests()
        result["allocation_requested_bytes"] = meter_bytes()
        result["allocation_instrumented"] = true
        #else
        result["allocation_instrumented"] = false
        #endif
        let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
