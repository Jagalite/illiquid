import Dispatch
import Foundation
@testable import IlliquidApp

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

private enum BenchmarkFailure: Error, CustomStringConvertible {
    case invalid(String)

    var description: String {
        switch self { case .invalid(let message): return message }
    }
}

private enum Workload: String, CaseIterable, Encodable {
    case flat_media_4096
    case flat_nonmedia_4096
    case nested_mixed_4096
    case directory_only_512
    case cached_repair
    case small_32
}

/// The oracle comes from fixture definitions, not the scanner's output or its
/// directory-enumerator stack. Playable status is specified independently of
/// production extension recognition.
private struct FixtureDefinition {
    struct File {
        let path: String
        let playable: Bool
    }

    var directories: [String] = []
    var files: [File] = []
    var cachedDirectories: Set<String> = []

    init(_ workload: Workload) {
        switch workload {
        case .flat_media_4096:
            for index in 0..<4096 {
                files.append(File(path: Self.name(index, extension: index % 2 == 0 ? "MKV" : "mkv"),
                                  playable: true))
            }
        case .flat_nonmedia_4096:
            for index in 0..<4096 {
                files.append(File(path: Self.name(index, extension: Self.nonmediaExtension(index)),
                                  playable: false))
            }
        case .nested_mixed_4096:
            for show in 0..<8 {
                let parent = "Show-\(show)"
                directories.append(parent)
                for season in 0..<8 {
                    let directory = parent + "/Season-\(season)"
                    directories.append(directory)
                    for index in 0..<64 {
                        // Two seasons per show contain no playable files.
                        let playable = season % 4 != 0 && index % 4 == 0
                        let name = Self.name(index,
                            extension: playable ? "MKV" : Self.nonmediaExtension(index))
                        files.append(File(path: directory + "/" + name, playable: playable))
                    }
                }
            }
        case .directory_only_512:
            for parentIndex in 0..<16 {
                let parent = "Parent-\(parentIndex)"
                directories.append(parent)
                for child in 0..<31 { directories.append(parent + "/Child-\(child)") }
            }
        case .cached_repair:
            for sibling in 0..<64 {
                let directory = "Sibling-\(sibling)"
                directories.append(directory)
                cachedDirectories.insert(directory)
                for index in 0..<32 {
                    let playable = sibling % 2 == 0 && index % 4 == 0
                    let name = Self.name(index,
                        extension: playable ? "MKV" : Self.nonmediaExtension(index))
                    files.append(File(path: directory + "/" + name, playable: playable))
                }
            }
        case .small_32:
            for index in 0..<32 {
                let playable = index % 4 == 0
                files.append(File(path: Self.name(index,
                    extension: playable ? "MKV" : Self.nonmediaExtension(index)), playable: playable))
            }
        }
    }

    private static func name(_ index: Int, extension suffix: String) -> String {
        let names = ["Episode #1 100%", "Café", "Cafe\u{301}", "动画 🎬",
                     "literal%2Fname", "name with spaces", "[1080p]", "ampersand & plus+"]
        return "\(index)-\(names[index % names.count]).\(suffix)"
    }

    private static func nonmediaExtension(_ index: Int) -> String {
        let extensions = ["txt", "srt", "ass", "vtt", "nfo", "jpg", "png", "json"]
        return extensions[index % extensions.count]
    }
}

private struct ExpectedSummary: Equatable {
    var hasDirectMedia = false
    var children: Set<String> = []
    var isComplete = true
    var isReadable = true
}

private struct PreparedFixture {
    let workload: Workload
    let root: URL
    let rootID: String
    let cache: [String: Bool]
    let expectedResults: [String: Bool]
    let expectedSummaries: [String: ExpectedSummary]
    let expectedVisitedEntries: Int

    init(root fixtureRoot: URL, workload: Workload) throws {
        self.workload = workload
        root = fixtureRoot.appendingPathComponent(workload.rawValue, isDirectory: true)
        rootID = SourceTreeIdentity.folderID(for: root)
        let definition = FixtureDefinition(workload)
        var summaries: [String: ExpectedSummary] = ["": ExpectedSummary()]
        var presence: [String: Bool] = ["": false]
        for directory in definition.directories {
            guard summaries[directory] == nil, summaries[parent(of: directory)] != nil else {
                throw BenchmarkFailure.invalid("Invalid directory definition: \(directory)")
            }
            summaries[directory] = ExpectedSummary()
            summaries[parent(of: directory)]?.children.insert(directory)
            presence[directory] = false
        }
        for file in definition.files where file.playable {
            var directory = parent(of: file.path)
            guard summaries[directory] != nil else {
                throw BenchmarkFailure.invalid("Missing fixture parent: \(file.path)")
            }
            summaries[directory]?.hasDirectMedia = true
            while true {
                presence[directory] = true
                if directory.isEmpty { break }
                directory = parent(of: directory)
            }
        }

        let rootID = self.rootID
        func absolute(_ path: String) -> String { path.isEmpty ? rootID : rootID + "/" + path }
        func inCachedSubtree(_ path: String, includingRoot: Bool) -> Bool {
            definition.cachedDirectories.contains { cached in
                (includingRoot && path == cached) || path.hasPrefix(cached + "/")
            }
        }
        cache = Dictionary(uniqueKeysWithValues: definition.cachedDirectories.map {
            (absolute($0), presence[$0] == true)
        })
        expectedResults = Dictionary(uniqueKeysWithValues: presence.compactMap { path, value in
            inCachedSubtree(path, includingRoot: true) ? nil : (absolute(path), value)
        })
        expectedSummaries = Dictionary(uniqueKeysWithValues: summaries.compactMap { path, value in
            guard !inCachedSubtree(path, includingRoot: true) else { return nil }
            var value = value
            value.children = Set(value.children.map(absolute))
            return (absolute(path), value)
        })
        // The cached directory entry itself is visited, but none of its files
        // or descendants are visited. The traversal root is not an entry.
        expectedVisitedEntries = definition.directories.filter {
            !inCachedSubtree($0, includingRoot: false)
        }.count + definition.files.filter {
            !inCachedSubtree($0.path, includingRoot: true)
        }.count
    }
}

private func parent(of path: String) -> String {
    guard let slash = path.lastIndex(of: "/") else { return "" }
    return String(path[..<slash])
}

private struct ScanSnapshot {
    var results: [String: Bool] = [:]
    var summaries: [String: SourceMediaPresenceCursor.Summary] = [:]
    var visitedEntries = 0
    var batchCount = 0
}

@inline(never)
private func scan(_ fixture: PreparedFixture, maximumEntries: Int = 256,
                  timeBudget: Double = 3600) throws -> ScanSnapshot {
    let cursor = SourceMediaPresenceCursor(root: fixture.root, cachedResults: fixture.cache)
    var snapshot = ScanSnapshot()
    while snapshot.batchCount <= fixture.expectedVisitedEntries + 1 {
        let batch = try cursor.nextBatch(maximumEntries: maximumEntries, timeBudget: timeBudget)
        guard batch.visitedEntries <= maximumEntries else {
            throw BenchmarkFailure.invalid("Traversal exceeded its entry limit")
        }
        snapshot.results.merge(batch.results) { _, new in new }
        snapshot.summaries.merge(batch.summaries) { _, new in new }
        snapshot.visitedEntries += batch.visitedEntries
        snapshot.batchCount += 1
        if batch.isComplete { return snapshot }
    }
    throw BenchmarkFailure.invalid("Traversal failed to complete: \(fixture.workload.rawValue)")
}

private func validate(_ snapshot: ScanSnapshot, against fixture: PreparedFixture) throws {
    // Check the original absolute namespace before projecting relative receipts;
    // stripping a root first could conceal /tmp versus /private/tmp mistakes.
    func requireNamespace(_ path: String) throws {
        guard path == fixture.rootID || path.hasPrefix(fixture.rootID + "/") else {
            throw BenchmarkFailure.invalid("Unexpected absolute scan key: \(path)")
        }
    }
    for path in snapshot.results.keys { try requireNamespace(path) }
    for (path, summary) in snapshot.summaries {
        try requireNamespace(path)
        for child in summary.children { try requireNamespace(child) }
    }
    guard snapshot.visitedEntries == fixture.expectedVisitedEntries,
          snapshot.results == fixture.expectedResults,
          snapshot.summaries.count == fixture.expectedSummaries.count else {
        throw BenchmarkFailure.invalid("Traversal differs from fixture oracle: \(fixture.workload.rawValue)")
    }
    for (path, expected) in fixture.expectedSummaries {
        guard let actual = snapshot.summaries[path],
              actual.hasDirectMedia == expected.hasDirectMedia,
              actual.children == expected.children,
              actual.isComplete == expected.isComplete,
              actual.isReadable == expected.isReadable else {
            throw BenchmarkFailure.invalid("Directory summary differs from fixture oracle: \(path)")
        }
    }
}

private struct ResultReceipt: Encodable {
    let path: String
    let hasMedia: Bool
}

private struct SummaryReceipt: Encodable {
    let path: String
    let hasDirectMedia: Bool
    let children: [String]
    let isComplete: Bool
    let isReadable: Bool
}

private struct TraceReceipt: Encodable {
    let maximumEntries: Int
    let timeBudgetSeconds: Double
    let visitedEntries: Int
    let batchCount: Int?
    let results: [ResultReceipt]
    let summaries: [SummaryReceipt]

    init(_ snapshot: ScanSnapshot, fixture: PreparedFixture, maximumEntries: Int,
         timeBudget: Double, includeBatchCount: Bool) {
        self.maximumEntries = maximumEntries
        timeBudgetSeconds = timeBudget
        visitedEntries = snapshot.visitedEntries
        batchCount = includeBatchCount ? snapshot.batchCount : nil
        func relative(_ path: String) -> String {
            path == fixture.rootID ? "." : String(path.dropFirst(fixture.rootID.count + 1))
        }
        results = snapshot.results.map { ResultReceipt(path: relative($0.key), hasMedia: $0.value) }
            .sorted { $0.path < $1.path }
        summaries = snapshot.summaries.map { path, summary in
            SummaryReceipt(path: relative(path), hasDirectMedia: summary.hasDirectMedia,
                           children: summary.children.map(relative).sorted(),
                           isComplete: summary.isComplete, isReadable: summary.isReadable)
        }.sorted { $0.path < $1.path }
    }
}

private struct WorkloadReceipt: Encodable {
    let workload: Workload
    let expectedVisitedEntries: Int
    let traces: [TraceReceipt]
}

private struct VerificationReceipt: Encodable {
    let schemaVersion = 1
    let workloads: [WorkloadReceipt]
}

private struct PreparationReceipt: Encodable {
    let prepared = true
    let workloads = Workload.allCases
}

private func prepare(_ root: URL) throws {
    let manager = FileManager.default
    if let attributes = try? manager.attributesOfItem(atPath: root.path) {
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              try manager.contentsOfDirectory(atPath: root.path).isEmpty else {
            throw BenchmarkFailure.invalid("prepare requires a new or empty nonsymlink directory")
        }
    } else {
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
    }
    for workload in Workload.allCases {
        let directory = root.appendingPathComponent(workload.rawValue, isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: false)
        let definition = FixtureDefinition(workload)
        for path in definition.directories {
            try manager.createDirectory(at: directory.appendingPathComponent(path, isDirectory: true),
                                        withIntermediateDirectories: false)
        }
        for file in definition.files {
            try Data().write(to: directory.appendingPathComponent(file.path, isDirectory: false),
                             options: .withoutOverwriting)
        }
    }
    try emit(PreparationReceipt())
}

private func verify(_ root: URL) throws {
    var receipts: [WorkloadReceipt] = []
    for workload in Workload.allCases {
        let fixture = try PreparedFixture(root: root, workload: workload)
        var traces: [TraceReceipt] = []
        for maximumEntries in [1, 7, 256] {
            let snapshot = try withIterationPool { try scan(fixture, maximumEntries: maximumEntries) }
            try validate(snapshot, against: fixture)
            traces.append(TraceReceipt(snapshot, fixture: fixture, maximumEntries: maximumEntries,
                                       timeBudget: 3600, includeBatchCount: true))
        }
        let snapshot = try withIterationPool { try scan(fixture, timeBudget: 0.02) }
        try validate(snapshot, against: fixture)
        // Faster implementations may fit more entries into a production slice.
        // The final maps and visited-entry totals remain exact parity oracles.
        traces.append(TraceReceipt(snapshot, fixture: fixture, maximumEntries: 256,
                                   timeBudget: 0.02, includeBatchCount: false))
        receipts.append(WorkloadReceipt(workload: workload,
            expectedVisitedEntries: fixture.expectedVisitedEntries, traces: traces))
    }
    try emit(VerificationReceipt(workloads: receipts))
}

@inline(never)
private func withIterationPool<T>(_ body: () throws -> T) rethrows -> T {
    #if canImport(Darwin)
    return try autoreleasepool(invoking: body)
    #else
    return try body()
    #endif
}

private func processCPUNanoseconds() throws -> UInt64 {
    var value = timespec()
    guard clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &value) == 0,
          value.tv_sec >= 0, value.tv_nsec >= 0 else {
        throw BenchmarkFailure.invalid("Could not read process CPU clock")
    }
    return UInt64(value.tv_sec) * 1_000_000_000 + UInt64(value.tv_nsec)
}

private struct MeasurementReceipt: Encodable {
    let workload: Workload
    let iterations: Int
    let elapsedNanoseconds: UInt64
    let cpuNanoseconds: UInt64
    let checksum: UInt64
    let visitedEntries: UInt64
}

private func measure(_ root: URL, workload: Workload, iterations: Int) throws {
    let fixture = try PreparedFixture(root: root, workload: workload)
    // The fixture oracle, warmup traversals, and full validation stay outside
    // the clocks. Each timed traversal retains complete merged output, while
    // draining temporary Foundation objects on Darwin inside the measured work.
    for _ in 0..<2 {
        let warmup = try withIterationPool { try scan(fixture) }
        try validate(warmup, against: fixture)
    }
    var last: ScanSnapshot?
    var checksum: UInt64 = 14_695_981_039_346_656_037
    var visitedEntries: UInt64 = 0
    let cpuStart = try processCPUNanoseconds()
    let wallStart = DispatchTime.now().uptimeNanoseconds
    for _ in 0..<iterations {
        try withIterationPool {
            let snapshot = try scan(fixture)
            visitedEntries += UInt64(snapshot.visitedEntries)
            checksum = (checksum ^ UInt64(snapshot.visitedEntries)) &* 1_099_511_628_211
            checksum = (checksum ^ UInt64(snapshot.results.count)) &* 1_099_511_628_211
            checksum = (checksum ^ UInt64(snapshot.summaries.count)) &* 1_099_511_628_211
            last = snapshot
        }
    }
    let elapsedNanoseconds = DispatchTime.now().uptimeNanoseconds - wallStart
    let cpuNanoseconds = try processCPUNanoseconds() - cpuStart
    guard let last, visitedEntries == UInt64(fixture.expectedVisitedEntries) * UInt64(iterations) else {
        throw BenchmarkFailure.invalid("Timed traversal count differs from fixture oracle")
    }
    try validate(last, against: fixture)
    try emit(MeasurementReceipt(workload: workload, iterations: iterations,
        elapsedNanoseconds: elapsedNanoseconds, cpuNanoseconds: cpuNanoseconds,
        checksum: checksum, visitedEntries: visitedEntries))
}

private func emit<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    print(String(decoding: try encoder.encode(value), as: UTF8.self))
}

@main
private struct SourcePresenceTraversalBenchmark {
    static func main() throws {
        let arguments = CommandLine.arguments
        guard arguments.count >= 3, arguments[2].hasPrefix("/") else {
            throw BenchmarkFailure.invalid(
                "Usage: prepare|verify <absolute-fixture-root> OR measure <absolute-fixture-root> <workload> <iterations>")
        }
        let root = URL(fileURLWithPath: arguments[2], isDirectory: true).absoluteURL.standardized
        guard root.path != "/" else { throw BenchmarkFailure.invalid("Use a dedicated fixture directory") }
        switch arguments[1] {
        case "prepare" where arguments.count == 3:
            try prepare(root)
        case "verify" where arguments.count == 3:
            try verify(root)
        case "measure" where arguments.count == 5:
            guard let workload = Workload(rawValue: arguments[3]), let iterations = Int(arguments[4]),
                  (1...1_000_000).contains(iterations) else {
                throw BenchmarkFailure.invalid("Unknown workload or iteration count outside 1...1000000")
            }
            try measure(root, workload: workload, iterations: iterations)
        default:
            throw BenchmarkFailure.invalid("Invalid benchmark command or argument count")
        }
    }
}
