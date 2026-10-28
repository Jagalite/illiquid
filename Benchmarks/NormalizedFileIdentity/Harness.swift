import Foundation
import IlliquidCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

struct Workload: Codable, Sendable {
    let id: String
    let operation: String
    let count: Int
    var operationsPerPass: Int { operation == "keys" ? count : 1 }
}

let workloads = [
    Workload(id: "keys-ascii", operation: "keys", count: 256),
    Workload(id: "keys-unicode-fallback", operation: "keys", count: 256),
    Workload(id: "keys-escaped", operation: "keys", count: 256),
    Workload(id: "keys-invalid-control", operation: "keys", count: 256),
    Workload(id: "lookup-last-100", operation: "lookup", count: 100),
    Workload(id: "lookup-last-10000", operation: "lookup", count: 10_000),
    Workload(id: "lookup-missing-10000", operation: "lookup", count: 10_000),
    Workload(id: "deduplicate-unique-1000", operation: "deduplicate", count: 1_000),
    Workload(id: "deduplicate-repeated-1000", operation: "deduplicate", count: 1_000),
]

struct Fixture {
    let workload: Workload
    let urls: [URL]
    let items: [FolderPlaylistItem]
    let folder: FolderPlaylist?
    let query: URL?

    init(_ workload: Workload) {
        self.workload = workload
        let root = URL(fileURLWithPath: "/Volumes/Media/Series", isDirectory: true)
        urls = (0..<workload.count).map { index in
            switch workload.id {
            case "keys-unicode-fallback":
                return URL(fileURLWithPath:
                    "/Volumes/Me\u{0301}dia/字幕/Cafe\u{0301}/E\u{0301}pisode \(index) 👩🏽‍🚀.mkv",
                    isDirectory: false)
            case "keys-escaped":
                return URL(string:
                    "file://localhost/Volumes/Media/Season%20One/../Feature%20\(index)%20%23%25.mkv")!
            case "keys-invalid-control":
                return URL(string: index.isMultiple(of: 2)
                    ? "file://media-server.example/Movies/Feature\(index).mkv"
                    : "https://media.example/Feature\(index).mkv")!
            default:
                let number = workload.id == "deduplicate-repeated-1000" ? index / 2 : index
                return root.appendingPathComponent("Episode \(number).mkv", isDirectory: false)
            }
        }
        if workload.operation == "keys" {
            items = []
            folder = nil
            query = nil
        } else {
            items = urls.enumerated().map { index, url in
                FolderPlaylistItem(url: url, dateAdded: Date(timeIntervalSince1970: Double(index)))
            }
            if workload.operation == "lookup" {
                let playlist = FolderPlaylist(folderURL: root, items: items)
                folder = playlist
                query = workload.id.contains("missing")
                    ? root.appendingPathComponent("Missing.mkv", isDirectory: false)
                    : playlist.items.last!.url
            } else {
                folder = nil
                query = nil
            }
        }
    }

    // The same driver links against separately compiled production modules.
    // No input construction or sorting is included in this operation.
    @inline(never)
    func execute() -> UInt64 {
        switch workload.operation {
        case "keys":
            var checksum: UInt64 = 0
            for url in urls {
                if let key = NormalizedFileURL.persistenceKey(for: url) {
                    checksum &+= UInt64(key.utf8.count) + 1
                }
            }
            return checksum
        case "lookup":
            return UInt64((folder!.index(of: query!) ?? -1) + 1)
        case "deduplicate":
            return UInt64(PlaylistMutation.deduplicated(items).count)
        default:
            fatalError("Unknown operation")
        }
    }

    func verification() throws -> [String: Any] {
        let input = urls.map { Data($0.absoluteString.utf8).base64EncodedString() }
        let result: Any
        switch workload.operation {
        case "keys":
            result = urls.map { url -> Any in
                guard let key = NormalizedFileURL.persistenceKey(for: url) else { return NSNull() }
                return Data(key.utf8).base64EncodedString()
            }
        case "lookup":
            let index = folder!.index(of: query!)
            let expected = workload.id.contains("missing") ? nil : workload.count - 1
            precondition(index == expected)
            result = index.map { $0 as Any } ?? NSNull()
        case "deduplicate":
            let output = PlaylistMutation.deduplicated(items)
            let expected = workload.id.contains("repeated") ? workload.count / 2 : workload.count
            precondition(output.count == expected)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            result = try encoder.encode(output).base64EncodedString()
        default:
            fatalError("Unknown operation")
        }
        return ["id": workload.id, "inputs": input, "result": result, "checksumPerPass": execute()]
    }
}

func pooled<T>(_ body: () throws -> T) rethrows -> T {
    #if canImport(ObjectiveC)
    return try autoreleasepool(invoking: body)
    #else
    return try body()
    #endif
}

func cpuNanoseconds() -> UInt64 {
    var stamp = timespec()
    precondition(clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &stamp) == 0)
    return UInt64(stamp.tv_sec) * 1_000_000_000 + UInt64(stamp.tv_nsec)
}

func emit(_ object: Any) throws {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([10]))
}

@main
struct Main {
    static func main() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        if args == ["--list"] {
            let data = try JSONEncoder().encode(workloads)
            FileHandle.standardOutput.write(data)
            return
        }
        if args == ["--verify"] {
            try emit(workloads.map { workload in try pooled { try Fixture(workload).verification() } })
            return
        }
        guard args.count == 2, let passes = Int(args[1]), passes > 0,
              let workload = workloads.first(where: { $0.id == args[0] }) else {
            fatalError("Usage: Harness --list | --verify | WORKLOAD PASSES")
        }
        let fixture = Fixture(workload)
        let expectedPerPass = pooled { fixture.execute() }
        // Warm the same complete operation once; all fixtures remain immutable.
        let warmup = pooled { fixture.execute() }
        precondition(warmup == expectedPerPass)
        var checksum: UInt64 = 0
        let cpuStart = cpuNanoseconds()
        let wallStart = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<passes {
            checksum &+= pooled { fixture.execute() }
        }
        let wall = DispatchTime.now().uptimeNanoseconds - wallStart
        let cpu = cpuNanoseconds() - cpuStart
        precondition(checksum == expectedPerPass &* UInt64(passes))
        let operations = passes * workload.operationsPerPass
        try emit([
            "id": workload.id, "passes": passes, "operations": operations,
            "wall_ns": wall, "cpu_ns": cpu, "checksum": checksum,
            "checksum_per_pass": expectedPerPass,
            "wall_ns_per_operation": Double(wall) / Double(operations),
            "cpu_ns_per_operation": Double(cpu) / Double(operations),
        ])
    }
}
