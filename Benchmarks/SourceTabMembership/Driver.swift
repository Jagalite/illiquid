import Dispatch
import Foundation
@testable import IlliquidApp
import IlliquidCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

private struct Workload {
    let name: String
    let tab: SourceTab
    let queries: [URL]
}

private struct StoredItem: Encodable {
    let kind: String
    let path: String
}

private struct URLReceipt: Encodable {
    let absolute: String
    let relative: String
    let base: String?

    init(_ url: URL) {
        absolute = url.absoluteString
        relative = url.relativeString
        base = url.baseURL?.absoluteString
    }
}

private struct BehaviorReceipt: Encodable {
    let workload: String
    let items: [SourceTabItem]
    let queries: [URLReceipt]
    let booleans: [Bool]
}

private struct Measurement: Encodable {
    let workload: String
    let seed: Int
    let item_count: Int
    let iterations: Int
    let queries_per_iteration: Int
    let wall_ns: UInt64
    let cpu_ns: UInt64
    let checksum: UInt64
    let booleans: [Bool]
}

// The seed comes from argv. URL and tab construction is always outside timers.
private func workloads(seed: Int) throws -> [Workload] {
    let root = "/tmp/illiquid-membership-\(seed)"
    func file(_ index: Int) -> SourceTabItem {
        SourceTabItem(kind: .file, url: URL(fileURLWithPath: "\(root)/files/episode-\(index).mkv"))
    }
    func folder(_ index: Int) -> SourceTabItem {
        SourceTabItem(kind: .folder, url: URL(fileURLWithPath: "\(root)/roots/root-\(index)", isDirectory: true))
    }
    func fileQuery(_ index: Int) -> URL {
        URL(fileURLWithPath: "\(root)/files/episode-\(index).mkv")
    }
    func folderQuery(_ index: Int) -> URL {
        URL(fileURLWithPath: "\(root)/roots/root-\(index)/season/episode.mkv")
    }
    func make(_ name: String, _ items: [SourceTabItem], _ candidates: [URL]) -> Workload {
        precondition(!candidates.isEmpty)
        return Workload(name: name, tab: SourceTab(id: name, items: items),
                        queries: (0..<16).map { candidates[$0 % candidates.count] })
    }
    var result = [make("empty", [], [fileQuery(0)])]
    for count in [1, 64, 1_000] {
        let files = (0..<count).map(file)
        let folders = (0..<count).map(folder)
        let hit = count == 1 ? "hit" : "last"
        result.append(make("files-\(count)-\(hit)", files, [fileQuery(count - 1)]))
        result.append(make("files-\(count)-miss", files, [fileQuery(count)]))
        result.append(make("folders-\(count)-\(hit)", folders, [folderQuery(count - 1)]))
        result.append(make("folders-\(count)-miss", folders, [folderQuery(count)]))
        if count == 1_000 {
            result.append(make("files-1000-first", files, [fileQuery(0)]))
            result.append(make("folders-1000-first", folders, [folderQuery(0)]))
        }
    }
    let mixed = (0..<128).map { $0.isMultiple(of: 2) ? file($0) : folder($0) }
    result.append(make("mixed-128", mixed,
                       [folderQuery(127), fileQuery(126), fileQuery(128), fileQuery(0)]))

    let unicode = (0..<64).map { index in
        SourceTabItem(kind: .file,
                      url: URL(fileURLWithPath: "\(root)/Café/Épisode-\(index).mkv"))
    }
    let relativeBase = URL(fileURLWithPath: "\(root)/Cafe\u{0301}/unused/", isDirectory: true)
    result.append(make("unicode-relative-64", unicode, [
        URL(fileURLWithPath: "\(root)/Cafe\u{0301}/E\u{0301}pisode-63.mkv"),
        URL(string: "../E\u{0301}pisode-63.mkv", relativeTo: relativeBase)!,
        URL(fileURLWithPath: "\(root)/Café/Épisode-missing.mkv"),
    ]))

    // Codable can bypass SourceTabItem.init(kind:url:); retain raw stored paths.
    let rawItems = (0..<64).map { index in
        StoredItem(kind: index.isMultiple(of: 2) ? "file" : "folder",
                   path: index.isMultiple(of: 2)
                       ? "\(root)/Cafe\u{0301}//unused/../Épisode-\(index).mkv"
                       : "\(root)/Cafe\u{0301}//root-\(index)/../root-\(index)/.")
    }
    let decoded = try JSONDecoder().decode([SourceTabItem].self,
                                           from: JSONEncoder().encode(rawItems))
    result.append(make("decoded-noncanonical-64", decoded, [
        URL(fileURLWithPath: "\(root)/Café/root-63/episode.mkv"),
        URL(fileURLWithPath: "\(root)/Café/Épisode-62.mkv"),
        URL(fileURLWithPath: "\(root)/Café/root-missing/episode.mkv"),
    ]))

    let files = (0..<64).map(file)
    let folders = (0..<64).map(folder)
    result.append(make("nonfile-files-64", files,
                       [URL(string: "https://media.example\(fileQuery(63).path)")!]))
    result.append(make("nonfile-folders-64", folders,
                       [URL(string: "https://media.example\(folderQuery(63).path)")!]))
    func unsupported(_ path: String) -> [URL] {
        ["file://remote.example", "file://localhost:1234", "file://user@localhost"]
            .map { URL(string: $0 + path)! }
    }
    result.append(make("unsupported-files-64", files, unsupported(fileQuery(63).path)))
    result.append(make("unsupported-folders-64", folders, unsupported(folderQuery(63).path)))
    precondition(result.count == 22)
    return result
}

// This is the original predicate, retained only as an untimed behavior oracle.
private func originalContains(_ candidate: URL, in tab: SourceTab) -> Bool {
    tab.items.contains { item in
        switch item.kind {
        case .file:
            return NormalizedFileURL.representsSameFile(candidate, item.url)
        case .folder:
            let folder = item.url
            guard candidate.isFileURL, folder.isFileURL else { return false }
            let candidateComponents = (
                NormalizedFileURL.normalize(candidate) ?? candidate.absoluteURL.standardized
            ).pathComponents
            let folderComponents = (
                NormalizedFileURL.normalize(folder) ?? folder.absoluteURL.standardized
            ).pathComponents
            return candidateComponents.starts(with: folderComponents)
        }
    }
}

// Production is in a separately compiled module without cross-module optimization.
// Keep every invocation observable while reusing the result buffer outside timers.
@inline(never)
private func lookupBatch(_ fixture: Workload, into values: inout [Bool]) -> UInt64 {
    var checksum: UInt64 = 0
    for index in fixture.queries.indices {
        let found = SourceTabs.contains(fixture.queries[index], in: fixture.tab)
        values[index] = found
        checksum &+= found ? UInt64(index + 1) : 0
    }
    return checksum
}

private func processCPU() -> UInt64 {
    var value = timespec()
    precondition(clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &value) == 0,
                 "Process CPU clock is unavailable")
    return UInt64(value.tv_sec) * 1_000_000_000 + UInt64(value.tv_nsec)
}

@main
private enum Main {
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count >= 3, let seed = Int(args[2]) else {
            fatalError("Usage: probe list|verify SEED, or probe measure SEED CASE ITERATIONS")
        }
        let fixtures = try workloads(seed: seed)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data: Data
        switch args[1] {
        case "list":
            data = try encoder.encode(fixtures.map(\.name))
        case "verify":
            let receipts = fixtures.map { fixture in
                let expected = fixture.queries.map { originalContains($0, in: fixture.tab) }
                var values = [Bool](repeating: false, count: fixture.queries.count)
                _ = lookupBatch(fixture, into: &values)
                precondition(values == expected, "Production differs from original predicate: \(fixture.name)")
                return BehaviorReceipt(workload: fixture.name, items: fixture.tab.items,
                                       queries: fixture.queries.map(URLReceipt.init), booleans: values)
            }
            data = try encoder.encode(receipts)
        case "measure":
            guard args.count == 5, let iterations = Int(args[4]), iterations > 0,
                  let fixture = fixtures.first(where: { $0.name == args[3] }) else {
                fatalError("Unknown workload or invalid iteration count")
            }
            let expected = fixture.queries.map { originalContains($0, in: fixture.tab) }
            var values = [Bool](repeating: false, count: fixture.queries.count)
            let oneChecksum = lookupBatch(fixture, into: &values)
            precondition(values == expected, "Warmup changed membership")
            for _ in 0..<3 { _ = lookupBatch(fixture, into: &values) }
            var checksum: UInt64 = 0
            let cpuStart = processCPU()
            let start = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<iterations { checksum &+= lookupBatch(fixture, into: &values) }
            let wall = DispatchTime.now().uptimeNanoseconds - start
            let cpu = processCPU() - cpuStart
            precondition(values == expected && checksum == oneChecksum &* UInt64(iterations),
                         "Timed membership output changed")
            data = try encoder.encode(Measurement(
                workload: fixture.name, seed: seed, item_count: fixture.tab.items.count,
                iterations: iterations, queries_per_iteration: fixture.queries.count,
                wall_ns: wall, cpu_ns: cpu, checksum: checksum, booleans: values))
        default:
            fatalError("Unknown operation")
        }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([10]))
    }
}
