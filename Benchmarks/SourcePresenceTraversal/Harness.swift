import Dispatch
import Foundation
@testable import IlliquidApp
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// Real filesystem traversal through the complete production cursor. Fixture
// creation and canonical output collection are deliberately outside timing.
private struct Scenario: Sendable {
    let name: String
    let description: String
    let small: Bool

    var expectedVisitedEntries: Int? {
        switch name {
        case "empty": 0
        case "small-media-24": 24
        case "flat-media-4096", "flat-nonmedia-4096": 4096
        case "mixed-library-4096": 4136
        case "directory-heavy-2048": 2176
        case "cached-directories-64": 64
        case "unicode-files-1024": 1032
        default: nil // Package classification is platform-dependent.
        }
    }
}

private let scenarios: [Scenario] = [
    .init(name: "empty", description: "Empty directory control", small: true),
    .init(name: "small-media-24", description: "One season with 24 media files", small: true),
    .init(name: "flat-media-4096", description: "4096 supported media files", small: false),
    .init(name: "flat-nonmedia-4096", description: "4096 unsupported files and subtitle sidecars", small: false),
    .init(name: "mixed-library-4096", description: "8 shows, 4 seasons each, 128 mixed files per season", small: false),
    .init(name: "directory-heavy-2048", description: "128 parent directories with 16 empty children each", small: false),
    .init(name: "cached-directories-64", description: "64 cached positive/negative subtrees, 32 files each", small: true),
    .init(name: "unicode-files-1024", description: "8 Unicode directories with 128 mixed files each", small: false),
    .init(name: "excluded-and-escaped", description: "Hidden entries, packages, links and escaped-looking names", small: true),
]

private let unicodeFolders = ["Caf\u{00E9}", "Cafe\u{0301}-decomposed", "日本語", "한국어", "🎬 Movies",
                              "100% Complete", "literal%20space", "Hash#Question?"]

private enum HarnessError: Error {
    case invalidArguments(String)
    case invalidFixture(String)
    case differentCompletion(String)
}

private func createDirectory(_ url: URL) throws {
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
}

private func createFile(_ folder: URL, _ name: String) throws {
    try Data().write(to: folder.appendingPathComponent(name, isDirectory: false))
}

private func prepare(_ fixtures: URL) throws {
    if FileManager.default.fileExists(atPath: fixtures.path),
       !(try FileManager.default.contentsOfDirectory(atPath: fixtures.path)).isEmpty {
        throw HarnessError.invalidFixture("Refusing to overwrite nonempty fixture directory")
    }
    try createDirectory(fixtures)
    for scenario in scenarios {
        let root = fixtures.appendingPathComponent(scenario.name, isDirectory: true)
        try createDirectory(root)
        switch scenario.name {
        case "empty": break
        case "small-media-24", "flat-media-4096":
            let count = scenario.small ? 24 : 4096
            for index in 0..<count {
                try createFile(root, "Episode-\(index).\(index.isMultiple(of: 2) ? "mkv" : "MP4")")
            }
        case "flat-nonmedia-4096":
            let extensions = ["txt", "jpg", "nfo", "srt", "ass", "json", "png", "md"]
            for index in 0..<4096 { try createFile(root, "Asset-\(index).\(extensions[index % extensions.count])") }
        case "mixed-library-4096":
            let extensions = ["mkv", "MP4", "avi", "mov", "m4v", "srt", "nfo", "jpg"]
            for show in 0..<8 {
                for season in 0..<4 {
                    let folder = root.appendingPathComponent("Show-\(show)/Season-\(season)", isDirectory: true)
                    try createDirectory(folder)
                    for index in 0..<128 { try createFile(folder, "Episode-\(index).\(extensions[index % extensions.count])") }
                }
            }
        case "directory-heavy-2048":
            for parent in 0..<128 {
                for child in 0..<16 {
                    try createDirectory(root.appendingPathComponent("Parent-\(parent)/Child-\(child)", isDirectory: true))
                }
            }
        case "cached-directories-64":
            for index in 0..<64 {
                let folder = root.appendingPathComponent("Cached-\(index)", isDirectory: true)
                try createDirectory(folder)
                for file in 0..<32 {
                    try createFile(folder, "Entry-\(file).\(index.isMultiple(of: 2) ? "mkv" : "txt")")
                }
            }
        case "unicode-files-1024":
            for name in unicodeFolders {
                let folder = root.appendingPathComponent(name, isDirectory: true)
                try createDirectory(folder)
                for index in 0..<128 {
                    try createFile(folder, "エピソード-\(index)-🎞️.\(index.isMultiple(of: 3) ? "txt" : "mkv")")
                }
            }
        case "excluded-and-escaped":
            for name in ["Visible %20#?", ".hidden-folder", "Bundle.app", "Empty"] {
                try createDirectory(root.appendingPathComponent(name, isDirectory: true))
            }
            try createFile(root, ".hidden.mkv")
            try createFile(root, "note.txt")
            try createFile(root.appendingPathComponent("Visible %20#?"), "Movie%2Fmkv.MKV")
            try createFile(root.appendingPathComponent(".hidden-folder"), "Hidden.mkv")
            try createFile(root.appendingPathComponent("Bundle.app"), "Bundled.mp4")
            try FileManager.default.createSymbolicLink(
                at: root.appendingPathComponent("directory-link"),
                withDestinationURL: root.appendingPathComponent("Visible %20#?", isDirectory: true))
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("loop"), withDestinationURL: root)
        default: throw HarnessError.invalidFixture(scenario.name)
        }
    }
}

private func cachedResults(_ scenario: Scenario, root: URL) -> [String: Bool] {
    guard scenario.name == "cached-directories-64" else { return [:] }
    let rootPath = SourceTreeIdentity.folderID(for: root)
    return Dictionary(uniqueKeysWithValues: (0..<64).map { index in
        let path = URL(fileURLWithPath: rootPath, isDirectory: true)
            .appendingPathComponent("Cached-\(index)").path
        return (path, index.isMultiple(of: 2))
    })
}

private struct ScanCounts: Equatable {
    var visited = 0
    var batches = 0
    var checksum: UInt64 = 0
}

// Only scalar observations survive each batch. Keeping historical Batch values
// here would retain the cursor's child sets and distort copy-on-write costs.
@inline(never)
private func scan(root: URL, cache: [String: Bool]) throws -> ScanCounts {
    let cursor = SourceMediaPresenceCursor(root: root, cachedResults: cache)
    var counts = ScanCounts()
    while true {
        let batch = try cursor.nextBatch(maximumEntries: 256, timeBudget: 3600)
        precondition(batch.visitedEntries <= 256)
        counts.visited += batch.visitedEntries
        counts.batches += 1
        counts.checksum &+= UInt64(batch.visitedEntries) &* 31
            &+ UInt64(batch.results.count) &* 17 &+ UInt64(batch.summaries.count) &* 7
            &+ (batch.isComplete ? 1 : 0)
        if batch.isComplete { return counts }
        precondition(counts.batches < 100_000, "Cursor failed to complete")
    }
}

private func orderedKeys<T>(_ values: [String: T]) -> [String] {
    values.keys.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
}

private func resultRows(_ results: [String: Bool]) -> [[String: Any]] {
    orderedKeys(results).map { ["path": $0, "has_media": results[$0]!] }
}

private func summaryRows(_ summaries: [String: SourceMediaPresenceCursor.Summary]) -> [[String: Any]] {
    orderedKeys(summaries).map { path in
        let value = summaries[path]!
        return ["path": path, "has_direct_media": value.hasDirectMedia,
                "children": value.children.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) },
                "is_complete": value.isComplete, "is_readable": value.isReadable]
    }
}

private func json(_ value: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
}

private func capture(root: URL, cache: [String: Bool], entryBudget: Int,
                     timeBudget: TimeInterval, trace: Bool) throws -> [String: Any] {
    let cursor = SourceMediaPresenceCursor(root: root, cachedResults: cache)
    var results: [String: Bool] = [:]
    var summaries: [String: SourceMediaPresenceCursor.Summary] = [:]
    var batches: [[String: Any]] = []
    var visited = 0
    var batchCount = 0
    while true {
        let batch = try cursor.nextBatch(maximumEntries: entryBudget, timeBudget: timeBudget)
        precondition(batch.visitedEntries <= max(1, entryBudget))
        results.merge(batch.results) { _, new in new }
        summaries.merge(batch.summaries) { _, new in new }
        visited += batch.visitedEntries
        batchCount += 1
        if trace {
            batches.append(["visited_entries": batch.visitedEntries, "is_complete": batch.isComplete,
                            "results": resultRows(batch.results), "summaries": summaryRows(batch.summaries)])
        }
        if batch.isComplete { break }
        precondition(batchCount < 100_000, "Cursor failed to complete")
    }
    var output: [String: Any] = ["visited_entries": visited, "results": resultRows(results),
                                 "summaries": summaryRows(summaries)]
    if trace { output["batches"] = batches }
    return output
}

private func differential(_ fixtures: URL) throws -> [[String: Any]] {
    var records: [[String: Any]] = []
    for scenario in scenarios {
        let root = fixtures.appendingPathComponent(scenario.name, isDirectory: true)
        let cache = cachedResults(scenario, root: root)
        let complete = try capture(root: root, cache: cache, entryBudget: 256, timeBudget: 3600, trace: false)
        if let expected = scenario.expectedVisitedEntries {
            precondition(complete["visited_entries"] as? Int == expected, "Unexpected fixture traversal")
        }
        // Default deadlines may change slice boundaries as the cursor gets
        // faster. Verify the same final result, not equal wall-clock slicing.
        let defaultBudget = try capture(root: root, cache: cache, entryBudget: 256, timeBudget: 0.02, trace: false)
        guard try json(complete) == json(defaultBudget) else {
            throw HarnessError.differentCompletion(scenario.name)
        }
        for budget in scenario.small ? [1, 7, 256] : [256] {
            let output = try capture(root: root, cache: cache, entryBudget: budget, timeBudget: 3600, trace: true)
            records.append(["case": scenario.name, "entry_budget": budget, "output": output])
        }
        records.append(["case": scenario.name, "default_deadline_final_output": complete])
    }
    let missing = fixtures.appendingPathComponent("missing-root", isDirectory: true)
    records.append(["case": "missing-root", "output": try capture(root: missing, cache: [:],
        entryBudget: 1, timeBudget: 3600, trace: true)])
    return records
}

private func processCPUNanoseconds() -> UInt64 {
    var value = timespec()
    precondition(clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &value) == 0)
    return UInt64(value.tv_sec) * 1_000_000_000 + UInt64(value.tv_nsec)
}

@main
private enum Harness {
    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        func value(_ flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        guard let fixturePath = value("--fixtures") else {
            throw HarnessError.invalidArguments("--fixtures is required")
        }
        let fixtures = URL(fileURLWithPath: fixturePath, isDirectory: true)
        let output: Any
        if arguments.contains("--list") {
            output = scenarios.map { ["case": $0.name, "description": $0.description, "entry_budget": 256] as [String: Any] }
        } else if arguments.contains("--prepare") {
            try prepare(fixtures)
            output = ["prepared": true, "cases": scenarios.count]
        } else if arguments.contains("--differential") {
            output = try differential(fixtures)
        } else {
            guard let name = value("--case"), let scenario = scenarios.first(where: { $0.name == name }),
                  let count = value("--iterations"), let iterations = Int(count), (1...1_000_000).contains(iterations)
            else { throw HarnessError.invalidArguments("Expected valid --case and --iterations") }
            let root = fixtures.appendingPathComponent(scenario.name, isDirectory: true)
            guard FileManager.default.fileExists(atPath: root.path) else { throw HarnessError.invalidFixture(root.path) }
            let cache = cachedResults(scenario, root: root)
            let warmup = try scan(root: root, cache: cache)
            if let expected = scenario.expectedVisitedEntries {
                precondition(warmup.visited == expected, "Unexpected fixture traversal")
            }
            var visited = 0
            var batches = 0
            var checksum: UInt64 = 0
            let cpuStart = processCPUNanoseconds()
            let wallStart = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<iterations {
                let counts = try scan(root: root, cache: cache)
                visited += counts.visited
                batches += counts.batches
                checksum &+= counts.checksum
            }
            let elapsed = DispatchTime.now().uptimeNanoseconds - wallStart
            let cpu = processCPUNanoseconds() - cpuStart
            precondition(visited == warmup.visited * iterations)
            precondition(batches == warmup.batches * iterations)
            precondition(checksum == warmup.checksum &* UInt64(iterations))
            output = ["case": name, "iterations": iterations, "operations": iterations,
                      "visited_entries": visited, "batches": batches, "checksum": checksum,
                      "elapsed_ns": elapsed, "cpu_ns": cpu, "warmup_iterations": 1,
                      "warmup_visited_entries": warmup.visited, "warmup_checksum": warmup.checksum]
        }
        FileHandle.standardOutput.write(try json(output))
        FileHandle.standardOutput.write(Data([10]))
    }
}
