import Dispatch
import Foundation
import IlliquidCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

private let caseNames = [
    "key-ascii", "key-unicode", "key-relative", "key-escaped", "key-long", "key-long-ascii",
    "key-rejected", "same-file", "lookup-100", "lookup-1000", "lookup-10000",
    "deduplicate-1000", "deduplicate-10000", "normalize-control",
]

private func mediaURL(_ index: Int) -> URL {
    URL(fileURLWithPath: "/Volumes/Media/Series/Season 01/Episode \(index).mkv", isDirectory: false)
}

private struct Workload {
    let name: String
    let urls: [URL]
    let aliases: [URL]
    let items: [FolderPlaylistItem]
    let expectedItems: [FolderPlaylistItem]
    let playlist: FolderPlaylist?
    let operationsPerIteration: Int

    init(_ name: String) {
        precondition(caseNames.contains(name), "unknown case: \(name)")
        self.name = name
        let base = URL(fileURLWithPath: "/Volumes/Media/Series/Season 01/", isDirectory: true)
        if name.hasPrefix("lookup-") || name.hasPrefix("deduplicate-") {
            let count = Int(name.split(separator: "-").last!)!
            let entries = (0..<count).map {
                FolderPlaylistItem(url: mediaURL($0), dateAdded: Date(timeIntervalSince1970: Double($0)))
            }
            expectedItems = entries
            items = name.hasPrefix("deduplicate-") ? entries + Array(entries.prefix(count / 10)) : entries
            playlist = name.hasPrefix("lookup-") ? FolderPlaylist(folderURL: base, items: entries) : nil
            urls = [entries.last!.url, base.appendingPathComponent("Missing.mkv", isDirectory: false)]
            aliases = []
            operationsPerIteration = name.hasPrefix("lookup-") ? urls.count : 1
            return
        }
        items = []
        expectedItems = []
        playlist = nil
        urls = (0..<128).map { index in
            switch name {
            case "key-unicode":
                return URL(fileURLWithPath: "/Volumes/Media/Cafe\u{0301}/日本語/🎞️ Episode \(index).mkv", isDirectory: false)
            case "key-relative":
                return URL(string: "../Season%2001/Episode%20\(index).mkv", relativeTo: base)!
            case "key-escaped":
                return URL(string: "file:///Volumes/Media/100%25/A%252FB/Episode%20\(index)%20%23%3F.mkv")!
            case "key-long-ascii":
                let prefix = String(repeating: "Archive Collection Season/", count: 12)
                return URL(fileURLWithPath: "/Volumes/Media/\(prefix)Episode \(index).mkv", isDirectory: false)
            case "key-long":
                let prefix = String(repeating: "Archive Cafe\u{0301} 日本語/", count: 12)
                return URL(fileURLWithPath: "/Volumes/Media/\(prefix)Episode \(index).mkv", isDirectory: false)
            case "key-rejected":
                let values = [
                    "https://example.invalid/Episode\(index).mkv", "file:relative\(index).mkv",
                    "file://media-server.example/Movies/Episode\(index).mkv",
                    "file://user@localhost/Movies/Episode\(index).mkv",
                    "file://localhost:1234/Movies/Episode\(index).mkv",
                ]
                return URL(string: values[index % values.count])!
            default:
                return mediaURL(index)
            }
        }
        aliases = name == "same-file" ? (0..<128).map {
            URL(string: "../Season%2001/Episode%20\($0 + ($0 % 2)).mkv", relativeTo: base)!
        } : []
        operationsPerIteration = urls.count
    }

    // normalize is unchanged: compare exact bytes with its original path-only
    // result. String equality alone would hide differences in Unicode spelling.
    func verify() -> String {
        var receipt: UInt64 = 14_695_981_039_346_656_037
        func record(_ value: String?) {
            for byte in [value == nil ? UInt8(0) : UInt8(1)] + Array((value ?? "").utf8) + [0xFF] {
                receipt = (receipt ^ UInt64(byte)) &* 1_099_511_628_211
            }
        }
        for url in urls {
            let expected = NormalizedFileURL.normalize(url)?.path
            let actual = NormalizedFileURL.persistenceKey(for: url)
            precondition(actual.map { Array($0.utf8) } == expected.map { Array($0.utf8) },
                         "key mismatch for \(url.absoluteString)")
            record(actual)
        }
        if name == "same-file" {
            for (url, alias) in zip(urls, aliases) {
                let left = NormalizedFileURL.normalize(url)?.path
                let right = NormalizedFileURL.normalize(alias)?.path
                let expected = left != nil && right != nil && left == right
                let actual = NormalizedFileURL.representsSameFile(url, alias)
                precondition(actual == expected)
                record(String(actual))
            }
        }
        if let playlist {
            precondition(playlist.index(of: urls[0]) == playlist.count - 1)
            precondition(playlist.index(of: urls[1]) == nil)
            record(String(playlist.count - 1))
        }
        if name.hasPrefix("deduplicate-") {
            let actual = PlaylistMutation.deduplicated(items)
            precondition(actual == expectedItems, "deduplication changed order or metadata")
            for item in actual { record(item.url.absoluteString) }
        }
        return String(receipt, radix: 16)
    }

    @inline(never)
    func perform() -> Int {
        if let playlist {
            return urls.reduce(0) { $0 &+ (playlist.index(of: $1) ?? -1) }
        }
        if name.hasPrefix("deduplicate-") {
            return PlaylistMutation.deduplicated(items).count
        }
        if name == "same-file" {
            var count = 0
            for (url, alias) in zip(urls, aliases) {
                count &+= NormalizedFileURL.representsSameFile(url, alias) ? 1 : 0
            }
            return count
        }
        if name == "normalize-control" {
            return urls.reduce(0) { $0 &+ (NormalizedFileURL.normalize($1)?.path.utf8.count ?? 0) }
        }
        return urls.reduce(0) { $0 &+ (NormalizedFileURL.persistenceKey(for: $1)?.utf8.count ?? 0) }
    }
}

@main
private enum Main {
    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments == ["--list"] {
            print(String(data: try JSONSerialization.data(withJSONObject: caseNames), encoding: .utf8)!)
            return
        }
        precondition(arguments.count == 2, "usage: benchmark CASE ITERATIONS")
        let iterations = Int(arguments[1])!
        precondition(iterations > 0)
        let workload = Workload(arguments[0])
        let receipt = workload.verify()
        var sink = 0
        for _ in 0..<min(iterations, 3) { sink &+= workload.perform() }
        let cpuStart = clock()
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<iterations { sink &+= workload.perform() }
        let wallNanoseconds = DispatchTime.now().uptimeNanoseconds - start
        let cpuNanoseconds = Double(clock() - cpuStart) * 1_000_000_000 / Double(CLOCKS_PER_SEC)
        precondition(workload.verify() == receipt)
        let result: [String: Any] = [
            "case": workload.name, "iterations": iterations,
            "operations_per_iteration": workload.operationsPerIteration,
            "wall_ns": wallNanoseconds, "cpu_ns": cpuNanoseconds,
            "receipt": receipt, "sink": sink,
        ]
        print(String(data: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), encoding: .utf8)!)
    }
}
