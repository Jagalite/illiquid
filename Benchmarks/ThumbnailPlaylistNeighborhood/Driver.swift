import Foundation
import Darwin
import IlliquidCore
@testable import IlliquidApp

private func cpuNanoseconds() -> UInt64 {
    var value = timespec()
    precondition(clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &value) == 0)
    return UInt64(value.tv_sec) * 1_000_000_000 + UInt64(value.tv_nsec)
}

@inline(never)
private func checksum(_ result: ThumbnailPlaylistNeighborhood) -> Int {
    result.urls.count * 31 + result.distances.count * 7
        + result.distances.values.reduce(0, +)
}

@main
enum Driver {
    static func main() throws {
        let arguments = CommandLine.arguments
        precondition(arguments.count == 4)
        let count = Int(arguments[1])!
        let position = arguments[2]
        let iterations = Int(arguments[3])!
        precondition(count >= 0 && iterations > 0)
        // Input construction and URL normalization are outside the timed region.
        let playlist = (0..<count).map {
            FolderPlaylistItem(url: URL(fileURLWithPath: "/media/library/video-\($0).mkv"))
        }
        let current: URL?
        switch position {
        case "none": current = nil
        case "missing": current = URL(fileURLWithPath: "/media/missing.mkv")
        case "front": current = playlist.first?.url
        case "middle": current = playlist.isEmpty ? nil : playlist[count / 2].url
        case "tail": current = playlist.last?.url
        default: fatalError("Unknown query position")
        }
        let expected = ThumbnailPlaylistNeighborhood(playlist: playlist, current: current)
        let expectedChecksum = checksum(expected)
        for _ in 0..<3 {
            precondition(checksum(ThumbnailPlaylistNeighborhood(
                playlist: playlist, current: current)) == expectedChecksum)
        }

        var total = 0
        let cpuStart = cpuNanoseconds()
        let wallStart = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<iterations {
            let result = ThumbnailPlaylistNeighborhood(playlist: playlist, current: current)
            total &+= checksum(result)
        }
        let wall = DispatchTime.now().uptimeNanoseconds - wallStart
        let cpu = cpuNanoseconds() - cpuStart
        precondition(total == expectedChecksum * iterations)
        let receipt: [String: Any] = [
            "urls": expected.urls.map(\.absoluteString),
            "distances": Dictionary(uniqueKeysWithValues: expected.distances.map {
                ($0.key.absoluteString, $0.value)
            }),
        ]
        let output: [String: Any] = [
            "count": count, "position": position, "iterations": iterations,
            "wall_ns": wall, "cpu_ns": cpu, "checksum": total,
            "checksum_per_iteration": expectedChecksum, "receipt": receipt,
            "url_stride_bytes": MemoryLayout<URL>.stride,
        ]
        let data = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
