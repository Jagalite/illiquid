import Foundation
import Dispatch
import IlliquidCore
@testable import IlliquidApp

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// This executable is deliberately a separate client of IlliquidApp. The runner
// builds that module without cross-module optimization; construction of either
// implementation remains an opaque call in the measured loop.
private func fixtureURL(_ index: Int) -> URL {
    URL(
        fileURLWithPath: "/illiquid-thumbnail-neighbors-fixture/video-\(index).mkv",
        isDirectory: false
    )
}

private func processCPUTime() -> UInt64 {
    var stamp = timespec()
    precondition(clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &stamp) == 0)
    return UInt64(stamp.tv_sec) * 1_000_000_000 + UInt64(stamp.tv_nsec)
}

private func consume(_ result: ThumbnailPlaylistNeighbors, current: URL?) -> Int {
    // A small, deterministic use of every result prevents unused-call removal.
    // The complete ordered URLs and distance map are compared outside timing.
    let distance = current.flatMap { result.distances[$0] } ?? 13
    return result.urls.count * 131 + result.distances.count * 17 + distance + 1
}

private enum ProbeError: Error {
    case invalidArguments
    case invalidPosition
}

private func run() throws {
    let arguments = CommandLine.arguments
    guard arguments.count == 5,
          arguments[1] == "measure",
          let count = Int(arguments[2]), (1...1_000_000).contains(count),
          let iterations = Int(arguments[4]), (1...1_000_000).contains(iterations)
    else { throw ProbeError.invalidArguments }
    let position = arguments[3]
    let items = (0..<count).map { FolderPlaylistItem(url: fixtureURL($0)) }
    let current: URL?
    switch position {
    case "nil": current = nil
    case "first": current = fixtureURL(0)
    case "middle": current = fixtureURL(count / 2)
    case "last": current = fixtureURL(count - 1)
    case "missing": current = fixtureURL(count)
    default: throw ProbeError.invalidPosition
    }
    // The query is built independently, never copied from items[index].url.
    // Construction, warmups, and output verification are outside measurement.
    let reference = ThumbnailPlaylistNeighbors(items: items, current: current)
    let unitChecksum = consume(reference, current: current)
    var warmupChecksum = 0
    for _ in 0..<10 {
        warmupChecksum &+= consume(
            ThumbnailPlaylistNeighbors(items: items, current: current),
            current: current
        )
    }
    precondition(warmupChecksum == unitChecksum * 10)

    var checksum = 0
    let cpuStart = processCPUTime()
    let wallStart = DispatchTime.now().uptimeNanoseconds
    for _ in 0..<iterations {
        let result = ThumbnailPlaylistNeighbors(items: items, current: current)
        checksum &+= consume(result, current: current)
    }
    let wallNanoseconds = DispatchTime.now().uptimeNanoseconds - wallStart
    let cpuNanoseconds = processCPUTime() - cpuStart
    precondition(checksum == unitChecksum * iterations)

    let actual = ThumbnailPlaylistNeighbors(items: items, current: current)
    precondition(actual.urls == reference.urls)
    precondition(actual.distances == reference.distances)
    let distances = Dictionary(uniqueKeysWithValues:
        actual.distances.map { ($0.key.absoluteString, $0.value) })
    let row: [String: Any] = [
        "count": count,
        "position": position,
        "iterations": iterations,
        "wall_ns": wallNanoseconds,
        "cpu_ns": cpuNanoseconds,
        "checksum": checksum,
        "url_stride": MemoryLayout<URL>.stride,
        "urls": actual.urls.map(\.absoluteString),
        "distances": distances,
    ]
    let data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([10]))
}

do {
    try run()
} catch {
    let message = "Probe failed: \(error). Usage: Probe measure COUNT POSITION ITERATIONS\n"
    FileHandle.standardError.write(Data(message.utf8))
    exit(1)
}
