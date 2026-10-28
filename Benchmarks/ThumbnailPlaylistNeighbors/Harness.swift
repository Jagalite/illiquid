import Dispatch
import Foundation
import IlliquidCore
@testable import IlliquidApp
#if os(Linux)
import Glibc
#else
import Darwin
#endif
#if ALLOCATION_METER
import CAllocationMeter
#endif

// The actual production helper and FolderPlaylistItem live in separately
// compiled modules. No URL construction, normalization, serialization, or
// fixture-oracle work belongs to the measured projection loop.
@main
struct NeighborBenchmark {
    static func cpuNanoseconds() -> UInt64 {
        var value = timespec()
        precondition(clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &value) == 0)
        return UInt64(value.tv_sec) * 1_000_000_000 + UInt64(value.tv_nsec)
    }

    @inline(never)
    static func project(_ playlist: [FolderPlaylistItem], current: URL?) -> ThumbnailPlaylistNeighbors {
        ThumbnailPlaylistNeighbors(playlist: playlist, current: current)
    }

    static func token(urlCount: Int, distances: [URL: Int]) -> UInt64 {
        UInt64(urlCount) &* 31 &+ UInt64(distances.count) &* 127
            &+ distances.values.reduce(UInt64(0)) { $0 &+ UInt64($1) }
    }

    @inline(never)
    static func run(_ playlist: [FolderPlaylistItem], current: URL?, iterations: Int) -> UInt64 {
        var checksum: UInt64 = 0
        for _ in 0..<iterations {
            let result = project(playlist, current: current)
            // Small scalar consumption keeps every result observable, without
            // deriving paths or hashing strings inside the timed interval.
            checksum &+= token(urlCount: result.urls.count, distances: result.distances)
        }
        return checksum
    }

    static func main() throws {
        let arguments = CommandLine.arguments
        precondition(arguments.count == 5,
                     "usage: NeighborBenchmark verify|timing|allocations COUNT SCENARIO ITERATIONS")
        let mode = arguments[1], count = Int(arguments[2])!, scenario = arguments[3]
        let iterations = Int(arguments[4])!
        precondition(count >= 0 && iterations > 0)
        #if ALLOCATION_METER
        precondition(mode == "verify" || mode == "allocations")
        #else
        precondition(mode == "verify" || mode == "timing")
        #endif

        var playlist: [FolderPlaylistItem] = []
        playlist.reserveCapacity(count)
        for index in 0..<count {
            playlist.append(FolderPlaylistItem(
                url: URL(fileURLWithPath: "/Media/Playlist/Episode-\(index).mkv"),
                dateAdded: Date(timeIntervalSince1970: Double(index))))
        }
        let knownAnchor: Int?
        switch scenario {
        case "nil", "miss": knownAnchor = nil
        case "first": precondition(count > 0); knownAnchor = 0
        case "middle": precondition(count > 0); knownAnchor = count / 2
        case "last": precondition(count > 0); knownAnchor = count - 1
        default: fatalError("unknown scenario")
        }
        let current: URL? = scenario == "nil" ? nil
            : knownAnchor.map { playlist[$0].url }
                ?? URL(fileURLWithPath: "/Media/Playlist/Missing.mkv")

        // Fixture arithmetic supplies the oracle, independently of either
        // implementation's search and slice. Generated URLs are unique.
        var expectedURLs: [URL] = []
        var expectedDistances: [URL: Int] = [:]
        if let anchor = knownAnchor {
            for offset in -4...4 {
                let index = anchor + offset
                if index >= 0 && index < count {
                    let url = playlist[index].url
                    expectedURLs.append(url)
                    expectedDistances[url] = abs(offset)
                }
            }
        }
        func verify() {
            let result = project(playlist, current: current)
            precondition(result.urls == expectedURLs && result.distances == expectedDistances,
                         "Projection differs from independently generated fixture")
            precondition(result.urls.map(\.absoluteString) == expectedURLs.map(\.absoluteString),
                         "URL representations changed")
        }
        verify()
        let expectedToken = token(urlCount: expectedURLs.count, distances: expectedDistances)
        var output: [String: Any] = [
            "mode": mode, "count": count, "scenario": scenario, "iterations": iterations,
            "url_stride_bytes": MemoryLayout<URL>.stride,
            "playlist_item_stride_bytes": MemoryLayout<FolderPlaylistItem>.stride,
            "oracle_equal": true,
            "receipt": [
                "urls": expectedURLs.map(\.absoluteString),
                "distances": Dictionary(uniqueKeysWithValues: expectedDistances.map {
                    ($0.key.absoluteString, $0.value)
                }),
            ],
        ]
        if mode != "verify" {
            let warmup = 3
            precondition(run(playlist, current: current, iterations: warmup)
                         == expectedToken &* UInt64(warmup))
            let checksum: UInt64
            #if ALLOCATION_METER
            meter_begin()
            checksum = run(playlist, current: current, iterations: iterations)
            meter_end()
            output["allocation_requests"] = meter_requests()
            output["allocation_requested_bytes"] = meter_bytes()
            #else
            let cpuStart = cpuNanoseconds()
            let wallStart = DispatchTime.now().uptimeNanoseconds
            checksum = run(playlist, current: current, iterations: iterations)
            let wallElapsed = DispatchTime.now().uptimeNanoseconds - wallStart
            let cpuElapsed = cpuNanoseconds() - cpuStart
            output["elapsed_ns"] = wallElapsed
            output["cpu_ns"] = cpuElapsed
            #endif
            precondition(checksum == expectedToken &* UInt64(iterations), "Loop checksum mismatch")
            verify()
            output["warmup"] = warmup
            output["checksum"] = checksum
        }
        let encoded = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
        print(String(decoding: encoded, as: UTF8.self))
    }
}
