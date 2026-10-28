import Dispatch
import Foundation
import IlliquidCore

private struct Workload: Codable {
    let id: String
    let api: String
    let count: Int
    let scenario: String
}

private struct HarnessFailure: Error, CustomStringConvertible {
    let description: String
}

private func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw HarnessFailure(description: message) }
}

private func emit<Value: Encodable>(_ value: Value) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    print(String(decoding: try encoder.encode(value), as: UTF8.self))
}

private let scenarios = [
    "short-ascii", "long-ascii", "escaped-ascii", "dot-ascii",
    "localhost-ascii", "relative-ascii", "unicode-early", "unicode-late",
    "unicode-long-early", "unicode-long-late", "remote-rejected", "authority-rejected",
]

private var workloads: [Workload] {
    var result = scenarios.map { Workload(id: "key-" + $0, api: "key", count: 64, scenario: $0) }
    result += ["short-ascii", "escaped-ascii", "unicode-long-late"].map {
        Workload(id: "normalize-" + $0, api: "normalize", count: 64, scenario: $0)
    }
    for count in [1, 32, 1_000] {
        for scenario in ["first", "last", "miss"] {
            result.append(Workload(id: "folder-\(count)-\(scenario)", api: "folder",
                                   count: count, scenario: scenario))
        }
    }
    result.append(Workload(id: "folder-1000-unicode-last", api: "folder",
                           count: 1_000, scenario: "unicode-last"))
    return result
}

private func urls(for scenario: String) throws -> [URL] {
    let long = String(repeating: "LongFolder0123456789/", count: 24)
    let base = URL(fileURLWithPath: "/tmp/IlliquidResearch/base/", isDirectory: true)
    return try (0..<64).map { index in
        let leaf = "Clip-\(index)-\(index * 7 % 67).mkv"
        let value: URL?
        switch scenario {
        case "short-ascii":
            value = URL(fileURLWithPath: "/tmp/IlliquidResearch/\(leaf)", isDirectory: false)
        case "long-ascii":
            value = URL(fileURLWithPath: "/tmp/\(long)\(leaf)", isDirectory: false)
        case "escaped-ascii":
            value = URL(string: "file:///tmp/Illiquid%20Research/percent%2525%23tag%3F\(index)/\(leaf)")
        case "dot-ascii":
            value = URL(string: "file:///tmp/IlliquidResearch/Season/.././\(index)/\(leaf)")
        case "localhost-ascii":
            value = URL(string: "file://LOCALHOST/tmp/IlliquidResearch/\(index)/\(leaf)")
        case "relative-ascii":
            value = URL(string: "../season-\(index % 4)/\(leaf)", relativeTo: base)
        case "unicode-early":
            value = URL(fileURLWithPath: "/Caf\u{00E9}/IlliquidResearch/\(leaf)", isDirectory: false)
        case "unicode-late":
            value = URL(fileURLWithPath: "/tmp/IlliquidResearch/\(leaf)-Cafe\u{0301}", isDirectory: false)
        case "unicode-long-early":
            value = URL(fileURLWithPath: "/Caf\u{00E9}/\(long)\(leaf)", isDirectory: false)
        case "unicode-long-late":
            value = URL(fileURLWithPath: "/tmp/\(long)\(leaf)-Cafe\u{0301}", isDirectory: false)
        case "remote-rejected":
            value = URL(string: "https://example.invalid/IlliquidResearch/\(leaf)")
        case "authority-rejected":
            value = URL(string: "file://media.example.invalid/IlliquidResearch/\(leaf)")
        default:
            throw HarnessFailure(description: "Unknown URL scenario: \(scenario)")
        }
        guard let value else { throw HarnessFailure(description: "Fixture URL construction failed") }
        return value
    }
}

private struct FolderFixture {
    let playlist: FolderPlaylist
    let queries: [URL]
    let expected: [Int?]
    let labels: [Int]
}

private func folder(for workload: Workload) throws -> FolderFixture {
    let unicode = workload.scenario == "unicode-last"
    let parent = "/tmp/IlliquidResearch/" + (unicode ? "Caf\u{00E9}" : "Movies")
    let directory = URL(fileURLWithPath: parent, isDirectory: true)
    func name(_ index: Int) -> String {
        let digits = String(index)
        return "Episode-" + String(repeating: "0", count: 5 - digits.count) + digits + ".mkv"
    }
    let items = (0..<workload.count).reversed().map { index in
        FolderPlaylistItem(
            url: URL(fileURLWithPath: parent + "/" + name(index), isDirectory: false),
            dateAdded: Date(timeIntervalSince1970: Double(index)))
    }
    let playlist = FolderPlaylist(folderURL: directory, items: items)
    let labels = playlist.items.map { Int($0.dateAdded!.timeIntervalSince1970) }
    try require(labels == Array(0..<workload.count), "Unexpected independently labeled folder ordering")
    let index: Int? = workload.scenario == "miss" ? nil
        : (workload.scenario == "first" ? 0 : workload.count - 1)
    let filename = index.map(name) ?? "Missing-99999.mkv"
    let queryParent = unicode ? parent.decomposedStringWithCanonicalMapping : parent
    let queryBase = URL(fileURLWithPath: queryParent, isDirectory: true)
    let direct = URL(fileURLWithPath: queryParent + "/" + filename, isDirectory: false)
    let queries: [URL] = try (0..<64).map { offset in
        let value: URL?
        switch offset % 4 {
        case 0: value = direct
        case 1:
            value = URL(string: direct.absoluteString.replacingOccurrences(of: "file:///", with: "file://localhost/"))
        case 2: value = URL(string: "./" + filename, relativeTo: queryBase)
        default:
            value = URL(fileURLWithPath: queryParent + "/Unused/../" + filename, isDirectory: false)
        }
        guard let value else { throw HarnessFailure(description: "Folder query construction failed") }
        return value
    }
    return FolderFixture(playlist: playlist, queries: queries,
                         expected: Array(repeating: index, count: queries.count), labels: labels)
}

private struct URLReceipt: Encodable {
    let id: String
    let construction: String
    let input: String
    let base: String?
    let constructorFailed: Bool
    let absoluteURL: String?
    let key: String?
    let keyUTF8: [UInt8]?
    let normalizedPathUTF8: [UInt8]?
}

private struct FolderReceipt: Encodable {
    let workload: Workload
    let itemURLs: [String]
    let sortedLabels: [Int]
    let queryURLs: [String]
    let expectedIndices: [Int?]
    let actualIndices: [Int?]
}

private struct Verification: Encodable {
    let schemaVersion = 1
    let receipts: [URLReceipt]
    let folderReceipts: [FolderReceipt]
}

private func verify() throws -> Verification {
    let receipts = try NormalizedFileURLCorpus.make().map { fixture in
        let key = fixture.url.flatMap { NormalizedFileURL.persistenceKey(for: $0) }
        let normalized = fixture.url.flatMap { NormalizedFileURL.normalize($0)?.path }
        let keyBytes = key.map { Array($0.utf8) }
        let normalizedBytes = normalized.map { Array($0.utf8) }
        try require(keyBytes == normalizedBytes, "Key/normalize byte mismatch: \(fixture.id)")
        return URLReceipt(id: fixture.id, construction: fixture.construction,
                          input: fixture.input, base: fixture.base,
                          constructorFailed: fixture.url == nil,
                          absoluteURL: fixture.url?.absoluteURL.absoluteString,
                          key: key, keyUTF8: keyBytes, normalizedPathUTF8: normalizedBytes)
    }
    let folders = try workloads.filter { $0.api == "folder" }.map { workload in
        let fixture = try folder(for: workload)
        let actual = fixture.queries.map { fixture.playlist.index(of: $0) }
        try require(actual == fixture.expected, "Folder lookup mismatch: \(workload.id)")
        return FolderReceipt(workload: workload, itemURLs: fixture.playlist.items.map { $0.url.absoluteString },
                             sortedLabels: fixture.labels, queryURLs: fixture.queries.map(\.absoluteString),
                             expectedIndices: fixture.expected, actualIndices: actual)
    }
    return Verification(receipts: receipts, folderReceipts: folders)
}

// A cheap retained receipt, not a correctness oracle. Complete byte/output
// comparisons and warmup checks run outside the measured interval.
private func score(_ key: String?) -> UInt64 {
    guard let key else { return 1 }
    return UInt64(key.utf8.count) &* 257 &+ UInt64(key.utf8.last ?? 0) &+ 2
}

private func score(_ index: Int?) -> UInt64 { UInt64((index ?? -1) + 2) }

private func expectedChecksum(_ values: [UInt64], iterations: Int) -> UInt64 {
    var result = values.reduce(0, &+) &* UInt64(iterations / values.count)
    for index in 0..<(iterations % values.count) { result &+= values[index] }
    return result
}

private struct Timing: Encodable {
    let workload: Workload
    let iterations: Int
    let checksum: UInt64
    let expectedChecksum: UInt64
    let elapsedMilliseconds: Double
    let nanosecondsPerCall: Double
}

private func measure(_ workload: Workload, iterations: Int) throws -> Timing {
    var checksum: UInt64 = 0
    let expected: UInt64
    let elapsed: UInt64
    if workload.api == "folder" {
        let fixture = try folder(for: workload)
        let warmup = fixture.queries.map { fixture.playlist.index(of: $0) }
        try require(warmup == fixture.expected, "Folder warmup mismatch: \(workload.id)")
        expected = expectedChecksum(fixture.expected.map { score($0) }, iterations: iterations)
        let started = DispatchTime.now().uptimeNanoseconds
        for index in 0..<iterations {
            checksum &+= score(fixture.playlist.index(of: fixture.queries[index % fixture.queries.count]))
        }
        elapsed = DispatchTime.now().uptimeNanoseconds - started
    } else {
        let input = try urls(for: workload.scenario)
        let oracle = input.map { NormalizedFileURL.normalize($0)?.path }
        let warmup = input.map {
            workload.api == "normalize" ? NormalizedFileURL.normalize($0)?.path
                : NormalizedFileURL.persistenceKey(for: $0)
        }
        try require(warmup.map { $0.map { Array($0.utf8) } } == oracle.map { $0.map { Array($0.utf8) } },
                    "Key warmup mismatch: \(workload.id)")
        expected = expectedChecksum(oracle.map { score($0) }, iterations: iterations)
        let started = DispatchTime.now().uptimeNanoseconds
        if workload.api == "normalize" {
            for index in 0..<iterations {
                checksum &+= score(NormalizedFileURL.normalize(input[index % input.count])?.path)
            }
        } else {
            for index in 0..<iterations {
                checksum &+= score(NormalizedFileURL.persistenceKey(for: input[index % input.count]))
            }
        }
        elapsed = DispatchTime.now().uptimeNanoseconds - started
    }
    try require(checksum == expected, "Timed checksum mismatch: \(workload.id)")
    return Timing(workload: workload, iterations: iterations, checksum: checksum,
                  expectedChecksum: expected, elapsedMilliseconds: Double(elapsed) / 1_000_000,
                  nanosecondsPerCall: Double(elapsed) / Double(iterations))
}

@main private enum NormalizedFileURLHarness {
    static func main() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        if args == ["--list"] { try emit(workloads); return }
        if args == ["--verify"] { try emit(verify()); return }
        guard args.count == 2, let iterations = Int(args[1]), iterations > 0,
              let workload = workloads.first(where: { $0.id == args[0] }) else {
            throw HarnessFailure(description: "Usage: --list | --verify | <workload> <positive-call-count>")
        }
        try emit(measure(workload, iterations: iterations))
    }
}
