import Dispatch
import Foundation
import IlliquidCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
@testable import IlliquidApp

private struct Fixture: Decodable {
    let name: String
    let roots: [String]
    let files: [String]
    let readsMetadata: Bool
    let expectedCount: Int?
}

private func boxed<T>(_ value: T?) -> Any { value.map { $0 as Any } ?? NSNull() }

private func metadataReceipt(_ value: RecognizedMediaName) -> [String: Any] {
    [
        "kind": value.kind.rawValue, "title": value.title,
        "year": boxed(value.year), "season": boxed(value.season),
        "episode": boxed(value.episode), "last_episode": boxed(value.lastEpisode),
        "air_date": boxed(value.airDate), "episode_title": boxed(value.episodeTitle),
        "edition": boxed(value.edition), "catalog_ids": value.catalogIDs,
        "variant": boxed(value.variant), "metadata_sources": value.metadataSources,
    ]
}

private func receipt(_ entries: [SourceTreeEntry]) throws -> Data {
    let rows: [[String: Any]] = entries.map { entry in
        [
            "url": entry.url.absoluteString,
            "kind": entry.kind == .media ? "media" : "folder",
            "visibility_path": boxed(entry.visibilityPath),
            "date_added_bits": boxed(entry.dateAdded.map { String($0.timeIntervalSinceReferenceDate.bitPattern) }),
            "creation_date_bits": boxed(entry.creationDate.map { String($0.timeIntervalSinceReferenceDate.bitPattern) }),
            "recognized_media": boxed(entry.recognizedMedia.map(metadataReceipt)),
        ]
    }
    return try JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys])
}

private func cpuNanoseconds() -> UInt64 {
    var value = timespec()
    precondition(clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &value) == 0)
    return UInt64(value.tv_sec) * 1_000_000_000 + UInt64(value.tv_nsec)
}

@main
private enum Main {
    static func main() throws {
        precondition(CommandLine.arguments.count == 5,
            "usage: RecursiveMediaScanBenchmark diagnose|measure fixture.json receipt.json iterations")
        let mode = CommandLine.arguments[1]
        precondition(mode == "diagnose" || mode == "measure")
        let fixture = try JSONDecoder().decode(Fixture.self,
            from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])))
        let receiptURL = URL(fileURLWithPath: CommandLine.arguments[3])
        let iterations = Int(CommandLine.arguments[4])!
        precondition(iterations > 0)
        let roots = fixture.roots.map { URL(fileURLWithPath: $0, isDirectory: true) }
        let files = fixture.files.map { URL(fileURLWithPath: $0, isDirectory: false) }
        func read() -> [SourceTreeEntry] {
            SourceRecursiveMediaLoader.read(roots, files: files, readsMetadata: fixture.readsMetadata)
        }

        // Input decoding, warm-up and every complete receipt comparison are
        // outside both clocks. The timed operation is the production scan.
        let warm = read()
        if let expected = fixture.expectedCount { precondition(warm.count == expected) }
        let warmReceipt = try receipt(warm)
        if mode == "diagnose" {
            try warmReceipt.write(to: receiptURL)
        } else {
            let expected = try Data(contentsOf: receiptURL)
            precondition(warmReceipt == expected, "warm-up differs from retained receipt")
        }

        var wall: [UInt64] = []
        var cpu: [UInt64] = []
        if mode == "measure" {
            for _ in 0..<iterations {
                let cpuStart = cpuNanoseconds()
                let wallStart = DispatchTime.now().uptimeNanoseconds
                let entries = read()
                let wallElapsed = DispatchTime.now().uptimeNanoseconds - wallStart
                let cpuElapsed = cpuNanoseconds() - cpuStart
                wall.append(wallElapsed)
                cpu.append(cpuElapsed)
                let actualReceipt = try receipt(entries)
                precondition(actualReceipt == warmReceipt, "timed scan differs from retained receipt")
            }
        }
        let output: [String: Any] = [
            "case": fixture.name, "count": warm.count,
            "recognized_count": warm.filter { $0.recognizedMedia != nil }.count,
            "iterations": mode == "measure" ? iterations : 0,
            "wall_ns": wall, "cpu_ns": cpu, "receipt_bytes": warmReceipt.count,
        ]
        print(String(data: try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]), encoding: .utf8)!)
    }
}
