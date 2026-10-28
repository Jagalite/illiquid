import Dispatch
import Foundation
import IlliquidCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

private struct Workload: Codable {
    let id: String
    let count: Int
    let anchor: String
}

private struct Fixture {
    let workload: Workload
    let playlist: [FolderPlaylistItem]
    let current: URL?

    init(_ workload: Workload) {
        self.workload = workload
        playlist = (0..<workload.count).map { index in
            FolderPlaylistItem(url: URL(fileURLWithPath:
                "/synthetic/neighborhood/series-\(index / 100)/episode-\(index).mkv"))
        }
        switch workload.anchor {
        case "nil": current = nil
        case "first": current = playlist.first?.url
        case "middle": current = playlist[playlist.count / 2].url
        case "last": current = playlist.last?.url
        case "missing": current = URL(fileURLWithPath: "/synthetic/neighborhood/missing.mkv")
        default: preconditionFailure("Unknown anchor")
        }
    }
}

private struct Distance: Codable {
    let url: String
    let distance: Int
}

private struct Canonical: Codable {
    let workload: Workload
    let current: String?
    let urls: [String]
    let distances: [Distance]
    let consumedValue: UInt64
    let urlStride: Int
}

private struct Measurement: Codable {
    let workload: Workload
    let iterations: Int
    let elapsedNanoseconds: UInt64
    let cpuNanoseconds: UInt64
    let nanosecondsPerCall: Double
    let cpuNanosecondsPerCall: Double
    let checksum: UInt64
    let consumedValue: UInt64
    let urlCount: Int
    let distanceCount: Int
    let urlStride: Int
}

// Both variants cross the same non-inlined call boundary. The candidate body is
// the production helper; the baseline body contains extracted production blocks.
@inline(never)
private func construct(_ playlist: [FolderPlaylistItem], _ current: URL?)
    -> ThumbnailPlaylistNeighborhood {
    ThumbnailPlaylistNeighborhood(playlist: playlist, current: current)
}

// Consume every returned URL through the distance table. Exact URL order and
// dictionary contents are compared separately, outside the timed region.
@inline(never)
private func consume(_ value: ThumbnailPlaylistNeighborhood) -> UInt64 {
    var result = UInt64(value.urls.count * 31 + value.distances.count)
    for url in value.urls {
        result = (result &* 1_000_003) &+ UInt64((value.distances[url] ?? -1) + 1)
    }
    return result
}

private func cpuNanoseconds() -> UInt64 {
    var time = timespec()
    precondition(clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &time) == 0)
    return UInt64(time.tv_sec) * 1_000_000_000 + UInt64(time.tv_nsec)
}

private func writeJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(value)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([10]))
}

@main
private enum NeighborhoodBenchmark {
    static func main() throws {
        let workloads = [32, 2_048, 100_000].flatMap { count in
            ["nil", "first", "middle", "last", "missing"].map { anchor in
                Workload(id: "n\(count)-\(anchor)", count: count, anchor: anchor)
            }
        }
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments == ["--list"] {
            try writeJSON(workloads)
            return
        }
        guard arguments.count >= 2,
              let workload = workloads.first(where: { $0.id == arguments[1] }) else {
            fatalError("Usage: --list | verify WORKLOAD | measure WORKLOAD ITERATIONS")
        }
        let fixture = Fixture(workload)
        let expected = construct(fixture.playlist, fixture.current)
        let consumedValue = consume(expected)
        if arguments[0] == "verify" {
            try writeJSON(Canonical(
                workload: workload, current: fixture.current?.absoluteString,
                urls: expected.urls.map(\.absoluteString),
                distances: expected.distances.map {
                    Distance(url: $0.key.absoluteString, distance: $0.value)
                }.sorted { $0.url < $1.url },
                consumedValue: consumedValue, urlStride: MemoryLayout<URL>.stride
            ))
            return
        }
        guard arguments[0] == "measure", arguments.count == 3,
              let iterations = Int(arguments[2]), iterations > 0 else {
            fatalError("Expected a positive iteration count")
        }
        var warmup: UInt64 = 0
        for _ in 0..<8 {
            warmup &+= consume(construct(fixture.playlist, fixture.current))
        }
        precondition(warmup == consumedValue &* 8)
        var checksum: UInt64 = 0
        let cpuStart = cpuNanoseconds()
        let start = DispatchTime.now().uptimeNanoseconds
        for index in 0..<iterations {
            checksum &+= consume(construct(fixture.playlist, fixture.current)) &+ UInt64(index)
        }
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        let cpuElapsed = cpuNanoseconds() - cpuStart
        let expectedChecksum = consumedValue &* UInt64(iterations)
            &+ (UInt64(iterations) &* UInt64(iterations - 1) / 2)
        precondition(checksum == expectedChecksum)
        try writeJSON(Measurement(
            workload: workload, iterations: iterations,
            elapsedNanoseconds: elapsed, cpuNanoseconds: cpuElapsed,
            nanosecondsPerCall: Double(elapsed) / Double(iterations),
            cpuNanosecondsPerCall: Double(cpuElapsed) / Double(iterations),
            checksum: checksum, consumedValue: consumedValue,
            urlCount: expected.urls.count, distanceCount: expected.distances.count,
            urlStride: MemoryLayout<URL>.stride
        ))
    }
}
