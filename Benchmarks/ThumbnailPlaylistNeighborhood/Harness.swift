import Darwin
import Dispatch
import Foundation
import IlliquidCore
import NeighborhoodProbe

private typealias Plan = (urls: [URL], distances: [URL: Int])

private func playlist(_ count: Int) -> [FolderPlaylistItem] {
    (0..<count).map { index in
        FolderPlaylistItem(url: URL(fileURLWithPath: "/synthetic/series/episode-\(index).mkv"))
    }
}

private func selection(_ items: [FolderPlaylistItem], scenario: String) -> URL? {
    switch scenario {
    case "nil": return nil
    case "missing": return URL(fileURLWithPath: "/synthetic/series/missing.mkv")
    case "first": return items.first?.url
    case "middle": return items.isEmpty ? nil : items[items.count / 2].url
    case "last": return items.last?.url
    default: fatalError("Unknown scenario: \(scenario)")
    }
}

private func serialized(_ result: Plan) -> [String: Any] {
    [
        "urls": result.urls.map(\.absoluteString),
        "distances": result.distances.map { (url: $0.key.absoluteString, distance: $0.value) }
            .sorted { $0.url < $1.url }
            .map { ["url": $0.url, "distance": $0.distance] as [String: Any] },
    ]
}

private func witness(_ result: Plan) -> UInt64 {
    UInt64(result.urls.count * 31 + result.distances.count * 17
        + result.distances.values.reduce(0, +))
}

private func cpuNanoseconds() -> UInt64 {
    var usage = rusage()
    precondition(getrusage(RUSAGE_SELF, &usage) == 0)
    return UInt64(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) * 1_000_000_000
        + UInt64(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) * 1_000
}

private func verify() throws -> [String: Any] {
    var rows: [[String: Any]] = []
    for count in [0, 1, 2, 8, 9, 10, 32] {
        let items = playlist(count)
        for scenario in ["nil", "missing", "first", "middle", "last"] {
            rows.append([
                "case": "\(count)/\(scenario)",
                "result": serialized(makeNeighborhood(items, current: selection(items, scenario: scenario))),
            ])
        }
    }
    let distinct = playlist(6)
    let duplicates = [distinct[0], distinct[1], distinct[2], distinct[0],
                      distinct[3], distinct[4], distinct[0]]
    rows.append(["case": "duplicate-current",
                 "result": serialized(makeNeighborhood(duplicates, current: distinct[0].url))])
    rows.append(["case": "duplicate-neighbor",
                 "result": serialized(makeNeighborhood(duplicates, current: distinct[3].url))])
    struct RawItem: Encodable {
        let url: URL
        let externalSubtitleURLs: [URL] = []
        let dateAdded: Date? = nil
    }
    let alias = URL(string: "file:///synthetic/season/../episode.mkv")!
    let remote = URL(string: "https://example.invalid/video.mkv")!
    let raw = try JSONDecoder().decode([FolderPlaylistItem].self,
        from: JSONEncoder().encode([RawItem(url: alias), RawItem(url: remote)]))
    for current in [alias, remote, URL(fileURLWithPath: "/synthetic/episode.mkv")] {
        rows.append(["case": "raw/\(current.absoluteString)",
                     "result": serialized(makeNeighborhood(raw, current: current))])
    }
    return ["rows": rows, "urlStride": MemoryLayout<URL>.stride]
}

private func measure(count: Int, scenario: String, iterations: Int) -> [String: Any] {
    let items = autoreleasepool { playlist(count) }
    let current = selection(items, scenario: scenario)
    let warm = makeNeighborhood(items, current: current)
    let expectedWitness = witness(warm)
    var checksum: UInt64 = 0

    // The probe is a separately compiled dynamic module. Its public function
    // is opaque to this driver, so repeated unchanged inputs still call it.
    let startCPU = cpuNanoseconds()
    let startWall = DispatchTime.now().uptimeNanoseconds
    autoreleasepool {
        for _ in 0..<iterations {
            checksum &+= witness(makeNeighborhood(items, current: current))
        }
    }
    let wall = DispatchTime.now().uptimeNanoseconds - startWall
    let cpu = cpuNanoseconds() - startCPU
    precondition(checksum == expectedWitness &* UInt64(iterations))
    let final = makeNeighborhood(items, current: current)
    precondition(final.urls == warm.urls && final.distances == warm.distances)
    return [
        "inputCount": count, "scenario": scenario, "iterations": iterations,
        "elapsedNanoseconds": wall, "cpuNanoseconds": cpu,
        "checksum": checksum, "witness": expectedWitness,
        "result": serialized(final), "urlStride": MemoryLayout<URL>.stride,
    ]
}

@main
struct NeighborhoodHarness {
    static func main() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        let result: [String: Any]
        switch args.first {
        case "verify":
            result = try verify()
        case "measure":
            guard args.count == 4, let count = Int(args[1]), count >= 0,
                  let iterations = Int(args[3]), iterations > 0 else {
                fatalError("measure COUNT SCENARIO ITERATIONS")
            }
            result = measure(count: count, scenario: args[2], iterations: iterations)
        default:
            fatalError("Expected verify or measure")
        }
        let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
