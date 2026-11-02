import Foundation
import URLBaseline
import URLCandidate
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

private let cases = [
    "keys-tiny-ascii", "keys-ascii-256", "keys-long-ascii-256", "keys-aliases-256",
    "keys-unicode-256", "keys-late-unicode-256", "keys-mixed-256", "keys-rejected-256",
    "playlist-empty", "playlist-single-hit", "playlist-small-last",
    "playlist-first-1000", "playlist-middle-1000", "playlist-last-1000", "playlist-miss-1000",
    "playlist-unicode-last-256", "playlist-rejected-query-256",
]

private func cpuNanoseconds() -> UInt64 {
    var value = timespec()
    precondition(clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &value) == 0)
    return UInt64(value.tv_sec) * 1_000_000_000 + UInt64(value.tv_nsec)
}

private func json(_ value: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
}

private func withBatchPool<Result>(_ body: () -> Result) -> Result {
    #if canImport(ObjectiveC)
    return autoreleasepool(invoking: body)
    #else
    return body()
    #endif
}

private func urls(_ name: String, count: Int) -> [URL] {
    if name == "keys-tiny-ascii" {
        return ["/", "/a", "/a.mkv"].map { URL(fileURLWithPath: $0, isDirectory: $0 == "/") }
    }
    return (0..<count).map { index in
        let stem = String(format: "Episode %04d", index)
        let longFolder = "/Volumes/Media Library/TV Shows/Archive/2020/Show With A Long Release Title (2020) {tvdb-123456}/Season 01/"
        if name.contains("rejected"), name.hasPrefix("keys") {
            let spellings = [
                "file://archive.example/Movies/\(index).mkv",
                "file://user@localhost/Movies/\(index).mkv",
                "file://localhost:1234/Movies/\(index).mkv",
                "https://example.invalid/Movies/\(index).mkv",
                "file:relative-\(index).mkv",
            ]
            return URL(string: spellings[index % spellings.count])!
        }
        if name == "keys-late-unicode-256" {
            return URL(fileURLWithPath: longFolder + stem + " 東京.mkv", isDirectory: false)
        }
        if name.contains("unicode") || (name == "keys-mixed-256" && index.isMultiple(of: 2)) {
            return URL(fileURLWithPath: "/Volumes/メディア/Cafe\u{301}/劇場版/\(stem).mkv", isDirectory: false)
        }
        if name == "keys-long-ascii-256" {
            return URL(fileURLWithPath: longFolder + "Show With A Long Release Title (2020) - \(stem) - WEB-DL 1080p x264.mkv", isDirectory: false)
        }
        if name == "keys-aliases-256" {
            return URL(string: "file://LOCALHOST/tmp/Library/Show/Season/../\(stem.replacingOccurrences(of: " ", with: "%20")).mkv?source=alias#chapter")!
        }
        return URL(fileURLWithPath: "/tmp/Library/Show/Season 01/\(stem).mkv", isDirectory: false)
    }
}

@inline(never)
private func runKeys(_ values: [URL], rounds: Int, key: (URL) -> String?) -> Int {
    var checksum = 0
    for _ in 0..<rounds {
        for value in values { checksum += key(value)?.utf8.count ?? 1 }
    }
    return checksum
}

@inline(never)
private func runLookups(_ queries: [URL], rounds: Int, lookup: (URL) -> Int?) -> Int {
    var checksum = 0
    for _ in 0..<rounds {
        for query in queries { checksum += lookup(query).map { $0 + 1 } ?? 0 }
    }
    return checksum
}

private struct Subject {
    let unit: String
    let operationsPerRound: Int
    let expectedChecksumPerRound: Int
    let receipt: () -> [String: Any]
    let execute: (Int) -> Int
}

private func subject(_ name: String, baseline: Bool) -> Subject {
    precondition(cases.contains(name))
    if name.hasPrefix("keys") {
        let values = urls(name, count: 256)
        let key = baseline
            ? URLBaseline.NormalizedFileURL.persistenceKey(for:)
            : URLCandidate.NormalizedFileURL.persistenceKey(for:)
        let expected = values.reduce(0) { $0 + (key($1)?.utf8.count ?? 1) }
        return Subject(unit: "persistence key", operationsPerRound: values.count,
                       expectedChecksumPerRound: expected, receipt: {
            ["urls": values.map(\.absoluteString),
             "keyBytes": values.map { value -> Any in
                 key(value).map { Array($0.utf8) } as Any? ?? NSNull()
             }]
        }, execute: { runKeys(values, rounds: $0, key: key) })
    }

    let count: Int
    switch name {
    case "playlist-empty": count = 0
    case "playlist-single-hit": count = 1
    case "playlist-small-last": count = 8
    case "playlist-unicode-last-256", "playlist-rejected-query-256": count = 256
    default: count = 1000
    }
    let values = urls(name, count: count)
    let folder = values.first?.deletingLastPathComponent()
        ?? URL(fileURLWithPath: "/tmp/Library/Show/Season 01", isDirectory: true)
    let query: URL
    if name == "playlist-rejected-query-256" {
        query = URL(string: "file://archive.example/Movies/Missing.mkv")!
    } else if name == "playlist-empty" || name == "playlist-miss-1000" {
        query = URL(fileURLWithPath: "/tmp/Library/Show/Season 01/Missing.mkv", isDirectory: false)
    } else if name == "playlist-first-1000" {
        query = values[0]
    } else if name == "playlist-middle-1000" {
        query = values[count / 2]
    } else {
        query = values[count - 1]
    }
    // One production lookup is the operation unit. Fixture construction,
    // natural sorting, full receipts, and warmup are outside both timers.
    let queries = [query]
    let expectedIndex: Int?
    switch name {
    case "playlist-empty", "playlist-miss-1000", "playlist-rejected-query-256": expectedIndex = nil
    case "playlist-first-1000", "playlist-single-hit": expectedIndex = 0
    case "playlist-middle-1000": expectedIndex = 500
    default: expectedIndex = count - 1
    }
    let expected = expectedIndex.map { $0 + 1 } ?? 0
    if baseline {
        let playlist = URLBaseline.FolderPlaylist(folderURL: folder,
            items: values.map { URLBaseline.FolderPlaylistItem(url: $0) })
        precondition(playlist.index(of: query) == expectedIndex, "Baseline fixture does not have its advertised position")
        return Subject(unit: "playlist lookup", operationsPerRound: queries.count,
                       expectedChecksumPerRound: expected, receipt: {
            ["folder": playlist.folderURL.absoluteString,
             "items": playlist.items.map { ["url": $0.url.absoluteString, "idBytes": Array($0.id.utf8)] as [String: Any] },
             "queries": queries.map(\.absoluteString),
             "indices": queries.map { playlist.index(of: $0) as Any? ?? NSNull() }]
        }, execute: { rounds in
            runLookups(queries, rounds: rounds, lookup: { playlist.index(of: $0) })
        })
    }
    let playlist = URLCandidate.FolderPlaylist(folderURL: folder,
        items: values.map { URLCandidate.FolderPlaylistItem(url: $0) })
    precondition(playlist.index(of: query) == expectedIndex, "Candidate fixture does not have its advertised position")
    return Subject(unit: "playlist lookup", operationsPerRound: queries.count,
                   expectedChecksumPerRound: expected, receipt: {
        ["folder": playlist.folderURL.absoluteString,
         "items": playlist.items.map { ["url": $0.url.absoluteString, "idBytes": Array($0.id.utf8)] as [String: Any] },
         "queries": queries.map(\.absoluteString),
         "indices": queries.map { playlist.index(of: $0) as Any? ?? NSNull() }]
    }, execute: { rounds in
        runLookups(queries, rounds: rounds, lookup: { playlist.index(of: $0) })
    })
}

@main
struct Driver {
    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments == ["--list"] {
            print(String(decoding: try json(cases), as: UTF8.self))
            return
        }
        if arguments.count == 2, arguments[0] == "--receipt", cases.contains(arguments[1]) {
            let name = arguments[1]
            let result: [String: Any] = [
                "case": name,
                "baseline": subject(name, baseline: true).receipt(),
                "candidate": subject(name, baseline: false).receipt(),
            ]
            print(String(decoding: try json(result), as: UTF8.self))
            return
        }
        guard arguments.count == 3, ["baseline", "candidate"].contains(arguments[0]),
              cases.contains(arguments[1]), let rounds = Int(arguments[2]), (1...20_000_000).contains(rounds) else {
            throw NSError(domain: "FileIdentityKeys", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Usage: Driver baseline|candidate CASE ROUNDS; --list; --receipt CASE"])
        }
        let variant = arguments[0]
        let name = arguments[1]
        let value = subject(name, baseline: variant == "baseline")
        let before = try json(value.receipt())
        precondition(withBatchPool { value.execute(2) } == value.expectedChecksumPerRound * 2)
        let startCPU = cpuNanoseconds()
        let start = DispatchTime.now().uptimeNanoseconds
        let checksum = withBatchPool { value.execute(rounds) }
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        let elapsedCPU = cpuNanoseconds() - startCPU
        // Validate retained observations without including receipt generation or
        // validation in the measured interval. Cross-variant receipts are also
        // compared independently by run.py before any timing campaign.
        precondition(checksum == value.expectedChecksumPerRound * rounds)
        let after = try json(value.receipt())
        precondition(before == after)
        let result: [String: Any] = [
            "variant": variant, "case": name, "rounds": rounds, "unit": value.unit,
            "operationsPerRound": value.operationsPerRound,
            "operations": value.operationsPerRound * rounds,
            "wallNanoseconds": elapsed, "cpuNanoseconds": elapsedCPU,
            "checksum": checksum, "expectedChecksumPerRound": value.expectedChecksumPerRound,
        ]
        print(String(decoding: try json(result), as: UTF8.self))
    }
}
