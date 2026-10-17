import Dispatch
import Foundation
import IlliquidCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#else
#error("This benchmark requires a POSIX process CPU clock")
#endif

enum QueryKind {
    case first, middle, last, missing, aliases, invalid, invalidItems
}

struct CaseDefinition {
    let name: String
    let count: Int
    let kind: QueryKind
}

let definitions: [CaseDefinition] = [
    .init(name: "empty", count: 0, kind: .missing),
    .init(name: "singleton-hit", count: 1, kind: .first),
    .init(name: "singleton-miss", count: 1, kind: .missing),
    .init(name: "last-2", count: 2, kind: .last),
    .init(name: "miss-2", count: 2, kind: .missing),
    .init(name: "last-16", count: 16, kind: .last),
    .init(name: "miss-16", count: 16, kind: .missing),
    .init(name: "last-250", count: 250, kind: .last),
    .init(name: "miss-250", count: 250, kind: .missing),
    .init(name: "last-1000", count: 1000, kind: .last),
    .init(name: "miss-1000", count: 1000, kind: .missing),
    .init(name: "first-1000", count: 1000, kind: .first),
    .init(name: "middle-1000", count: 1000, kind: .middle),
    .init(name: "long-path-1000", count: 1000, kind: .last),
    .init(name: "unicode-relative-1000", count: 1000, kind: .aliases),
    .init(name: "invalid-query-1000", count: 1000, kind: .invalid),
    .init(name: "invalid-items-1", count: 1, kind: .invalidItems),
    .init(name: "invalid-items-16", count: 16, kind: .invalidItems),
]

struct StoredItem: Encodable {
    let url: URL
    let externalSubtitleURLs: [URL] = []
    let dateAdded: Date? = nil
}

struct Fixture {
    let playlist: FolderPlaylist
    let queries: [URL]

    init(_ definition: CaseDefinition) throws {
        let parent = definition.name.contains("long-path")
            ? "/Benchmark/" + String(repeating: "A fairly long collection directory/", count: 12)
            : definition.kind == .aliases ? "/Benchmark/Café/" : "/Benchmark/Media/"
        let folder = URL(fileURLWithPath: parent, isDirectory: true)
        let stem = definition.kind == .aliases ? "Épisode" : "Episode"
        let urls = (0..<definition.count).reversed().map {
            folder.appendingPathComponent("\(stem) \($0 + 1).mkv")
        }
        let items: [FolderPlaylistItem]
        if definition.kind == .invalidItems {
            let payload = urls.map { url in
                StoredItem(url: URL(string: url.absoluteString.replacingOccurrences(
                    of: "file:///", with: "file://untrusted.example/"
                ))!)
            }
            // Codable restoration can bypass the normalizing initializer.
            items = try JSONDecoder().decode([FolderPlaylistItem].self, from: JSONEncoder().encode(payload))
        } else {
            items = urls.map { FolderPlaylistItem(url: $0) }
        }
        let playlist = FolderPlaylist(folderURL: folder, items: items)
        self.playlist = playlist
        let candidates: [URL]
        switch definition.kind {
        case .first:
            candidates = [playlist.items[0].url]
        case .middle:
            candidates = [playlist.items[playlist.count / 2].url]
        case .last:
            candidates = [playlist.items.last!.url]
        case .missing:
            candidates = [folder.appendingPathComponent("Episode \(definition.count + 1).mkv")]
        case .aliases:
            let target = playlist.items.last!.url
            let base = folder.appendingPathComponent("Unneeded", isDirectory: true)
            let relative = URL(string: "../E\u{0301}pisode \(definition.count).mkv", relativeTo: base)!
            let localhost = URL(string: target.absoluteString.replacingOccurrences(
                of: "file:///", with: "file://LOCALHOST/"
            ))!
            candidates = [relative, localhost, target]
        case .invalid:
            let target = playlist.items.last!.url.absoluteString
            candidates = [
                URL(string: target.replacingOccurrences(of: "file:///", with: "file://untrusted.example/"))!,
                URL(string: target.replacingOccurrences(of: "file:///", with: "https://media.example/"))!,
                URL(string: target.replacingOccurrences(of: "file:///", with: "file://localhost:1234/"))!,
                URL(string: "file:relative.mkv")!,
            ]
        case .invalidItems:
            candidates = [folder.appendingPathComponent("Episode 1.mkv")]
        }
        // One timed invocation performs a batch so empty/first-hit measurements
        // are not solely the granularity and overhead of two clock readings.
        queries = (0..<32).map { candidates[$0 % candidates.count] }
    }
}

@inline(never)
func run(_ fixture: Fixture) -> [Int?] {
    fixture.queries.map { fixture.playlist.index(of: $0) }
}

struct URLReceipt: Encodable {
    let absoluteString: String
    let relativeString: String
    let baseURL: String?
    let baseURLRelativeString: String?
    let hasDirectoryPath: Bool

    init(_ url: URL) {
        absoluteString = url.absoluteString
        relativeString = url.relativeString
        baseURL = url.baseURL?.absoluteString
        baseURLRelativeString = url.baseURL?.relativeString
        hasDirectoryPath = url.hasDirectoryPath
    }
}

struct OutputReceipt: Encodable {
    let indices: [Int?]
    let queryURLs: [URLReceipt]
    let itemURLs: [URLReceipt]
}

struct Measurement: Encodable {
    let elapsedNanoseconds: UInt64
    let cpuElapsedTicks: UInt64
    let clockTicksPerSecond: UInt64
    let iterations: Int
    let operationsPerIteration: Int
    let itemCount: Int
    let locale: String
    let output: OutputReceipt
}

let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys]
if CommandLine.arguments == [CommandLine.arguments[0], "--list"] {
    FileHandle.standardOutput.write(try encoder.encode(definitions.map(\.name)))
    FileHandle.standardOutput.write(Data([10]))
} else {
    guard CommandLine.arguments.count == 3,
          let definition = definitions.first(where: { $0.name == CommandLine.arguments[1] }),
          let iterations = Int(CommandLine.arguments[2]), iterations > 0
    else {
        fatalError("Usage: folder-playlist-lookup-probe CASE POSITIVE_ITERATIONS (or --list)")
    }
    let fixture = try Fixture(definition)
    // Preserve the original predicate as an independent, untimed oracle.
    let expected = fixture.queries.map { query in
        fixture.playlist.items.firstIndex { NormalizedFileURL.representsSameFile($0.url, query) }
    }
    let warmup = run(fixture)
    precondition(warmup == expected, "Warmup disagrees with original lookup predicate")
    var lastResult = warmup
    var elapsed: UInt64 = 0
    var cpuElapsedTicks: UInt64 = 0
    let invalidClock = clock_t(truncatingIfNeeded: -1)
    for _ in 0..<iterations {
        let cpuStart = clock()
        let start = DispatchTime.now().uptimeNanoseconds
        let result = run(fixture)
        let finish = DispatchTime.now().uptimeNanoseconds
        let cpuFinish = clock()
        precondition(cpuStart != invalidClock && cpuFinish != invalidClock && cpuFinish >= cpuStart,
                     "Process CPU clock unavailable or wrapped")
        elapsed += finish - start
        cpuElapsedTicks += UInt64(cpuFinish - cpuStart)
        precondition(result == expected, "Lookup disagrees with original predicate")
        lastResult = result
    }
    let measurement = Measurement(
        elapsedNanoseconds: elapsed,
        cpuElapsedTicks: cpuElapsedTicks,
        clockTicksPerSecond: UInt64(CLOCKS_PER_SEC),
        iterations: iterations,
        operationsPerIteration: fixture.queries.count,
        itemCount: fixture.playlist.count,
        locale: Locale.current.identifier,
        output: OutputReceipt(
            indices: lastResult,
            queryURLs: fixture.queries.map(URLReceipt.init),
            itemURLs: fixture.playlist.items.map { URLReceipt($0.url) }
        )
    )
    FileHandle.standardOutput.write(try encoder.encode(measurement))
    FileHandle.standardOutput.write(Data([10]))
}
