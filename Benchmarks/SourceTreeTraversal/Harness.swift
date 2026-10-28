import Darwin
import Foundation
@testable import IlliquidApp

private struct Scenario: Codable, Sendable {
    let name: String
    let description: String
}

private let scenarios = [
    Scenario(name: "wide_collapsed_10000", description: "One flattened root with 10000 collapsed child folders"),
    Scenario(name: "library_9600", description: "40 categories, 10 shows each, 4 seasons per show, 6 files per season"),
    Scenario(name: "balanced_tree", description: "Four children per folder for five levels, two files per leaf"),
    Scenario(name: "deep_chain_128", description: "128 nested folders with one file at every level; depth stress"),
    Scenario(name: "deep_chain_512", description: "512 nested folders with one file at every level; depth stress"),
    Scenario(name: "flat_files_10000", description: "10000 explicit media files; traversal-set control")
]

private struct Fixture {
    let input: SourceTreeProjectionInput
    let expectedCount: Int
}

private func fixture(_ name: String) -> Fixture {
    let root = URL(fileURLWithPath: "/tmp/illiquid-traversal/Library", isDirectory: true)
    var directories: [String: [SourceTreeEntry]] = [:]
    var expanded = Set<String>()
    var presence: [String: Bool] = [:]
    var expectedCount = 0

    func entry(_ url: URL, folder: Bool) -> SourceTreeEntry {
        SourceTreeEntry(url: url, kind: folder ? .folder : .media,
                        dateAdded: nil, creationDate: nil,
                        visibilityPath: url.path)
    }

    func setContents(_ folder: URL, _ entries: [SourceTreeEntry]) {
        let id = SourceTreeIdentity.folderID(for: folder)
        directories[id] = entries
        expanded.insert(id)
        presence[id] = true
    }

    var items = [SourceTabItem(kind: .folder, url: root)]
    switch name {
    case "wide_collapsed_10000":
        setContents(root, (0..<10_000).map {
            entry(root.appendingPathComponent("Folder-\($0)", isDirectory: true), folder: true)
        })
        expectedCount = 10_000
    case "library_9600":
        var categories: [SourceTreeEntry] = []
        for categoryIndex in 0..<40 {
            let category = root.appendingPathComponent("Category-\(categoryIndex)", isDirectory: true)
            categories.append(entry(category, folder: true))
            var shows: [SourceTreeEntry] = []
            for showIndex in 0..<10 {
                let show = category.appendingPathComponent("Show-\(showIndex)", isDirectory: true)
                shows.append(entry(show, folder: true))
                var seasons: [SourceTreeEntry] = []
                for seasonIndex in 0..<4 {
                    let season = show.appendingPathComponent("Season-\(seasonIndex)", isDirectory: true)
                    seasons.append(entry(season, folder: true))
                    setContents(season, (0..<6).map {
                        entry(season.appendingPathComponent("Episode-\($0).mkv"), folder: false)
                    })
                }
                setContents(show, seasons)
            }
            setContents(category, shows)
        }
        setContents(root, categories)
        expectedCount = 40 + 400 + 1_600 + 9_600
    case "balanced_tree":
        func populate(_ folder: URL, depth: Int) {
            if depth == 5 {
                setContents(folder, (0..<2).map {
                    entry(folder.appendingPathComponent("Video-\($0).mkv"), folder: false)
                })
                expectedCount += 2
                return
            }
            var children: [SourceTreeEntry] = []
            for index in 0..<4 {
                let child = folder.appendingPathComponent("Folder-\(index)", isDirectory: true)
                children.append(entry(child, folder: true))
                expectedCount += 1
                populate(child, depth: depth + 1)
            }
            setContents(folder, children)
        }
        populate(root, depth: 0)
    case "deep_chain_128", "deep_chain_512":
        let depth = name == "deep_chain_128" ? 128 : 512
        var folder = root
        for level in 0...depth {
            var entries = [entry(folder.appendingPathComponent("Video-\(level).mkv"), folder: false)]
            if level < depth {
                let child = folder.appendingPathComponent("d", isDirectory: true)
                entries.append(entry(child, folder: true))
                setContents(folder, entries)
                folder = child
            } else {
                setContents(folder, entries)
            }
        }
        expectedCount = depth * 2 + 1
    case "flat_files_10000":
        items = (0..<10_000).map {
            SourceTabItem(kind: .file, url: root.appendingPathComponent("Video-\($0).mkv"))
        }
        expectedCount = 10_000
    default:
        fatalError("Unknown scenario: \(name)")
    }

    var visibility = SourceVisibilityConfiguration.default
    visibility.viewMode = .tree
    let input = SourceTreeProjectionInput(
        items: items, visibility: visibility, roots: [root],
        directoryContents: directories, directoryErrors: [:],
        recursiveMediaEntries: [], expandedFolderIDs: expanded,
        sortConfiguration: .init(name: .off, dateCreated: .off, type: .off),
        mediaPresence: presence
    )
    return Fixture(input: input, expectedCount: expectedCount)
}

private struct RowReceipt: Codable {
    let id: String
    let folderID: String
    let url: String
    let displayName: String
    let contextLabel: String?
    let visibilityPath: String?
    let depth: Int
    let ancestorIDs: [String]
    let kind: String
    let isRoot: Bool?
    let message: String?
    let dateAdded: Double?
    let containsSupportedMedia: Bool?

    init(_ row: SourceTreeDisplayRow) {
        // All fixtures use tree view without metadata/visibility annotations.
        precondition(row.recognizedMedia == nil && row.visibility == nil)
        id = row.id
        folderID = row.folderID
        url = row.url.absoluteString
        displayName = row.displayName
        contextLabel = row.contextLabel
        visibilityPath = row.visibilityPath
        depth = row.depth
        ancestorIDs = row.ancestorIDs
        containsSupportedMedia = row.containsSupportedMedia
        switch row.kind {
        case .folder(let root):
            kind = "folder"; isRoot = root; message = nil; dateAdded = nil
        case .media(let date):
            kind = "media"; isRoot = nil; message = nil
            dateAdded = date?.timeIntervalSince1970
        case .message(let value):
            kind = "message"; isRoot = nil; message = value; dateAdded = nil
        case .mediaSection:
            fatalError("Tree-view fixture unexpectedly produced a media section")
        }
    }
}

private func encoded<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
}

private func emit<T: Encodable>(_ value: T) throws {
    FileHandle.standardOutput.write(try encoded(value))
    FileHandle.standardOutput.write(Data([10]))
}

private func fingerprint(_ rows: [SourceTreeDisplayRow]) throws -> String {
    var value: UInt64 = 14_695_981_039_346_656_037
    // Stream row receipts so verification does not materialize one enormous
    // JSON buffer before a timing sample, especially for deep ancestor lists.
    for row in rows {
        for byte in try encoded(RowReceipt(row)) {
            value = (value ^ UInt64(byte)) &* 1_099_511_628_211
        }
        value = (value ^ 10) &* 1_099_511_628_211
    }
    return String(value, radix: 16)
}

private struct Sample: Codable {
    let scenario: String
    let iterations: Int
    let count: Int
    let elapsed_ns: UInt64
    let cpu_ns: Double
    let checksum: String
    let observedRows: UInt64
}

private func sample(_ name: String, iterations: Int) throws {
    precondition(iterations > 0)
    let value = fixture(name)
    // The warmup and full output receipt are outside the timed region.
    let checksum: String = try {
        let rows = value.input.rows()
        precondition(rows.count == value.expectedCount)
        return try fingerprint(rows)
    }()
    var elapsed: UInt64 = 0
    var cpu: Double = 0
    var observedRows: UInt64 = 0
    for _ in 0..<iterations {
        let cpuStart = clock()
        let start = DispatchTime.now().uptimeNanoseconds
        let rows = value.input.rows()
        let stop = DispatchTime.now().uptimeNanoseconds
        let cpuStop = clock()
        elapsed += stop - start
        cpu += Double(cpuStop - cpuStart) * 1_000_000_000 / Double(CLOCKS_PER_SEC)
        precondition(rows.count == value.expectedCount)
        observedRows &+= UInt64(rows.count)
        // Keep construction observable, and destroy each output after timing.
        withExtendedLifetime(rows) {}
    }
    precondition(observedRows == UInt64(iterations) * UInt64(value.expectedCount))
    try emit(Sample(scenario: name, iterations: iterations, count: value.expectedCount,
                    elapsed_ns: elapsed, cpu_ns: cpu, checksum: checksum,
                    observedRows: observedRows))
}

private func peakRSS() -> Int64 {
    var usage = rusage()
    precondition(getrusage(RUSAGE_SELF, &usage) == 0)
    // Darwin reports ru_maxrss in bytes, unlike Linux.
    return Int64(usage.ru_maxrss)
}

private func liveHeap() -> UInt64 {
    var statistics = malloc_statistics_t()
    malloc_zone_statistics(nil, &statistics)
    return UInt64(statistics.size_in_use)
}

private struct MemorySample: Codable {
    let scenario: String
    let count: Int
    let peak_rss_before_bytes: Int64
    let peak_rss_after_bytes: Int64
    let peak_rss_growth_bytes: Int64
    let live_heap_before_bytes: UInt64
    let live_heap_after_bytes: UInt64
    let live_heap_growth_bytes: Int64
    let checksum: String
}

private func memory(_ name: String) throws {
    let value = fixture(name)
    // Resolve the measurement APIs before the baseline snapshot. There is no
    // rows() warmup: process lifetime high-water marks cannot be reset.
    _ = peakRSS()
    _ = liveHeap()
    let heapBefore = liveHeap()
    let rssBefore = peakRSS()
    let rows = value.input.rows()
    precondition(rows.count == value.expectedCount)
    let rssAfter = peakRSS()
    let heapAfter = liveHeap()
    let checksum = try fingerprint(rows)
    withExtendedLifetime(value) {
        withExtendedLifetime(rows) {}
    }
    try emit(MemorySample(
        scenario: name, count: rows.count,
        peak_rss_before_bytes: rssBefore, peak_rss_after_bytes: rssAfter,
        peak_rss_growth_bytes: max(0, rssAfter - rssBefore),
        live_heap_before_bytes: heapBefore, live_heap_after_bytes: heapAfter,
        live_heap_growth_bytes: Int64(heapAfter) - Int64(heapBefore),
        checksum: checksum
    ))
}

@main
struct TraversalBenchmark {
    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        switch arguments.first {
        case "list":
            try emit(scenarios)
        case "verify":
            var receipts: [String: [RowReceipt]] = [:]
            for scenario in scenarios {
                let value = fixture(scenario.name)
                let rows = value.input.rows()
                precondition(rows.count == value.expectedCount)
                receipts[scenario.name] = rows.map(RowReceipt.init)
            }
            try emit(receipts)
        case "sample":
            precondition(arguments.count == 3)
            try sample(arguments[1], iterations: Int(arguments[2])!)
        case "memory":
            precondition(arguments.count == 2)
            try memory(arguments[1])
        default:
            fatalError("Usage: TraversalBenchmark list|verify|sample CASE ITERATIONS|memory CASE")
        }
    }
}
