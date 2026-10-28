import Foundation
import IlliquidCore
@testable import IlliquidApp
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

private struct Scenario: Codable, Sendable {
    let id: String
    let count: Int
    let matchEvery: Int
    let errorEvery: Int
    var preserveExpansion = true
    var root = "/Media/Movies"
    var longUnicodePaths = false
    var retainedSnapshots = false
    var errorOnly = false
}

private let scenarios: [Scenario] = [
    .init(id: "empty", count: 0, matchEvery: 1, errorEvery: 0),
    .init(id: "singleton", count: 1, matchEvery: 1, errorEvery: 0),
    .init(id: "small-mixed-32", count: 32, matchEvery: 2, errorEvery: 7,
          preserveExpansion: false),
    .init(id: "narrow-256", count: 256, matchEvery: 16, errorEvery: 11),
    .init(id: "narrow-4096", count: 4096, matchEvery: 64, errorEvery: 11),
    .init(id: "missing-4096", count: 4096, matchEvery: 0, errorEvery: 11),
    .init(id: "all-4096", count: 4096, matchEvery: 1, errorEvery: 0, root: "/"),
    .init(id: "all-errors-1024", count: 1024, matchEvery: 1, errorEvery: 1),
    .init(id: "missing-all-errors-1024", count: 1024, matchEvery: 0, errorEvery: 1),
    .init(id: "unicode-long-256", count: 256, matchEvery: 4, errorEvery: 5,
          preserveExpansion: false, longUnicodePaths: true),
    .init(id: "retained-snapshot-4096", count: 4096, matchEvery: 64, errorEvery: 11,
          retainedSnapshots: true),
    .init(id: "prune-expansion-4096", count: 4096, matchEvery: 64, errorEvery: 11,
          preserveExpansion: false),
    .init(id: "error-only-32", count: 32, matchEvery: 2, errorEvery: 1, errorOnly: true),
]

private struct Fixture {
    let scenario: Scenario
    let rootURL: URL
    let contents: [(String, [SourceTreeEntry])]
    let errors: [(String, String)]
    let expansion: [String]
    let expectedContents: [String: [SourceTreeEntry]]
    let expectedErrors: [String: String]
    let expectedExpansion: Set<String>

    init(_ scenario: Scenario) {
        self.scenario = scenario
        rootURL = URL(fileURLWithPath: scenario.root, isDirectory: true)
        var contents: [(String, [SourceTreeEntry])] = []
        var errors: [(String, String)] = []
        var expansion: [String] = []
        for index in 0..<scenario.count {
            let matches = scenario.matchEvery > 0 && index % max(1, scenario.matchEvery) == 0
            // Include component-prefix siblings to catch overbroad invalidation.
            let parent = matches ? "/Media/Movies" : "/Media/Movies2"
            let suffix = scenario.longUnicodePaths
                ? "/Cafe\u{301}/第 1 話/100% Archive/" + String(repeating: "long-name-", count: 12)
                : "/Season"
            let key = parent + suffix + String(index)
            let hasError = scenario.errorEvery > 0 && index % max(1, scenario.errorEvery) == 0
            let entry = SourceTreeEntry(
                url: URL(fileURLWithPath: key + "/episode \(index).mkv"),
                kind: .media,
                dateAdded: Date(timeIntervalSince1970: Double(index)),
                creationDate: Date(timeIntervalSince1970: Double(index + 10)),
                visibilityPath: key + "/display"
            )
            if !scenario.errorOnly {
                contents.append((key, hasError ? [] : [entry]))
            }
            if hasError { errors.append((key, "unavailable-\(index)")) }
            expansion.append(key)
        }
        if scenario.count > 0 {
            expansion += ["/Media/Movies/Unloaded", "/Elsewhere/Unloaded"]
        }
        self.contents = contents
        self.errors = errors
        self.expansion = expansion
        let root = scenario.root
        // Independent removal contract. Setup and expected tables are not timed
        // and never share dictionary storage with the seeded production state.
        let removed: (String) -> Bool = {
            $0 == root || $0.hasPrefix(root == "/" ? "/" : root + "/")
        }
        expectedContents = Dictionary(uniqueKeysWithValues: contents.filter { !removed($0.0) })
        expectedErrors = Dictionary(uniqueKeysWithValues: errors.filter { !removed($0.0) })
        expectedExpansion = Set(scenario.preserveExpansion
            ? expansion : expansion.filter { !removed($0) })
    }

    @MainActor
    func verify(_ state: SourceTreeDirectoryState, expanded: Set<String>) {
        precondition(state.directoryContents == expectedContents, "cache values differ: \(scenario.id)")
        precondition(state.directoryErrors == expectedErrors, "error values differ: \(scenario.id)")
        precondition(expanded == expectedExpansion, "expansion differs: \(scenario.id)")
        precondition(state.directoryLoadTasks.isEmpty && state.loadingFolderIDs.isEmpty)
    }
}

private func cpuNanoseconds() -> UInt64 {
    var time = timespec()
    precondition(clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &time) == 0)
    return UInt64(time.tv_sec) * 1_000_000_000 + UInt64(time.tv_nsec)
}

private func sortedPaths<S: Sequence>(_ values: S) -> [String] where S.Element == String {
    values.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
}

@MainActor
private func snapshot(_ state: SourceTreeDirectoryState, expanded: Set<String>) -> [String: Any] {
    let contents: [[String: Any]] = sortedPaths(state.directoryContents.keys).map { key in
        let entries: [[String: Any]] = state.directoryContents[key]!.map { entry in
            precondition(entry.recognizedMedia == nil)
            return [
                "url_utf8": Array(entry.url.absoluteString.utf8),
                "kind": entry.kind == .media ? "media" : "folder",
                "date_added": entry.dateAdded.map { $0.timeIntervalSince1970 as Any } ?? NSNull(),
                "creation_date": entry.creationDate.map { $0.timeIntervalSince1970 as Any } ?? NSNull(),
                "visibility_utf8": entry.visibilityPath.map { Array($0.utf8) as Any } ?? NSNull(),
            ]
        }
        return ["key_utf8": Array(key.utf8), "entries": entries]
    }
    let errors: [[String: Any]] = sortedPaths(state.directoryErrors.keys).map {
        ["key_utf8": Array($0.utf8), "error_utf8": Array(state.directoryErrors[$0]!.utf8)]
    }
    return [
        "contents": contents,
        "errors": errors,
        "expansion_utf8": sortedPaths(expanded).map { Array($0.utf8) },
        "loading_utf8": sortedPaths(state.loadingFolderIDs).map { Array($0.utf8) },
        "task_keys_utf8": sortedPaths(state.directoryLoadTasks.keys).map { Array($0.utf8) },
    ]
}

@MainActor
private func invalidate(_ fixture: Fixture, measure: Bool) -> (UInt64, UInt64, Int) {
    let state = SourceTreeDirectoryState.benchmarkSeeded(
        contents: fixture.contents, errors: fixture.errors)
    var expanded = Set(fixture.expansion)
    // Only this explicitly labelled scenario retains table snapshots.
    let retainedContents = fixture.scenario.retainedSnapshots ? state.directoryContents : nil
    let retainedErrors = fixture.scenario.retainedSnapshots ? state.directoryErrors : nil
    let cpuStart = measure ? cpuNanoseconds() : 0
    let wallStart = measure ? DispatchTime.now().uptimeNanoseconds : 0
    state.invalidateCachedTree(
        beneath: fixture.rootURL,
        preserveExpansion: fixture.scenario.preserveExpansion,
        expandedFolderIDs: &expanded
    )
    let wall = measure ? DispatchTime.now().uptimeNanoseconds - wallStart : 0
    let cpu = measure ? cpuNanoseconds() - cpuStart : 0
    withExtendedLifetime((retainedContents, retainedErrors)) {}
    fixture.verify(state, expanded: expanded)
    if let retainedContents, let retainedErrors {
        precondition(retainedContents == Dictionary(uniqueKeysWithValues: fixture.contents))
        precondition(retainedErrors == Dictionary(uniqueKeysWithValues: fixture.errors))
    }
    let checksum = state.directoryContents.count + state.directoryErrors.count + expanded.count
    return (cpu, wall, checksum)
}

@main
private struct Driver {
    @MainActor
    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments == ["--list"] {
            let data = try JSONEncoder().encode(scenarios)
            print(String(decoding: data, as: UTF8.self))
            return
        }
        if arguments == ["--verify"] {
            var receipts: [String: Any] = [:]
            for scenario in scenarios {
                let fixture = Fixture(scenario)
                let state = SourceTreeDirectoryState.benchmarkSeeded(
                    contents: fixture.contents, errors: fixture.errors)
                var expanded = Set(fixture.expansion)
                state.invalidateCachedTree(beneath: fixture.rootURL,
                    preserveExpansion: scenario.preserveExpansion, expandedFolderIDs: &expanded)
                fixture.verify(state, expanded: expanded)
                receipts[scenario.id] = snapshot(state, expanded: expanded)
            }
            let data = try JSONSerialization.data(withJSONObject: receipts, options: [.sortedKeys])
            print(String(decoding: data, as: UTF8.self))
            return
        }
        guard arguments.count == 2,
              let scenario = scenarios.first(where: { $0.id == arguments[0] }),
              let iterations = Int(arguments[1]), iterations > 0 else {
            fatalError("Usage: directory-cache-benchmark --list | --verify | CASE ITERATIONS")
        }
        let fixture = Fixture(scenario)
        for _ in 0..<3 { _ = invalidate(fixture, measure: false) }
        var cpu: UInt64 = 0
        var wall: UInt64 = 0
        var checksum = 0
        for _ in 0..<iterations {
            let result = invalidate(fixture, measure: true)
            cpu += result.0
            wall += result.1
            checksum &+= result.2
        }
        let record: [String: Any] = [
            "id": scenario.id, "iterations": iterations,
            "cpuNanoseconds": cpu, "wallNanoseconds": wall, "checksum": checksum,
        ]
        let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
