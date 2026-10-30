import Foundation
import IlliquidCore
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

private func nanoseconds(_ clock: clockid_t) -> UInt64 {
    var stamp = timespec()
    precondition(clock_gettime(clock, &stamp) == 0)
    return UInt64(stamp.tv_sec) * 1_000_000_000 + UInt64(stamp.tv_nsec)
}

private struct PlaylistReceipt: Codable {
    let folderURL: URL
    let items: [FolderPlaylistItem]
    init(_ playlist: FolderPlaylist) {
        folderURL = playlist.folderURL
        items = playlist.items
    }
}

private struct Observation: Codable {
    let iterations: Int
    let wallNs: UInt64
    let cpuNs: UInt64
    let checksum: UInt64
    let receipt: PlaylistReceipt
}

@inline(never)
private func consume(_ url: URL) throws -> UInt64 {
    let playlist = try FolderPlaylistDiscovery.discover(in: url)
    return UInt64(playlist.count) &* 1_000_003
        &+ UInt64(playlist.items.last?.url.lastPathComponent.utf8.count ?? 0) &* 1_009
        &+ UInt64(playlist.items.last?.externalSubtitleURLs.count ?? 0)
}

private func output<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    FileHandle.standardOutput.write(try encoder.encode(value))
    FileHandle.standardOutput.write(Data([10]))
}

@main private enum Main {
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count >= 3 else { fatalError("verify DIRECTORY | bench DIRECTORY ITERATIONS") }
        let url = URL(fileURLWithPath: args[2], isDirectory: true)
        if args[1] == "verify" {
            try output(PlaylistReceipt(FolderPlaylistDiscovery.discover(in: url)))
            return
        }
        guard args[1] == "bench", args.count == 4, let iterations = Int(args[3]), iterations > 0 else {
            fatalError("Invalid benchmark arguments")
        }
        // Warm local filesystem and runtime caches before the timed scans.
        let expected = try consume(url)
        let secondWarmup = try consume(url)
        precondition(secondWarmup == expected)
        var checksum: UInt64 = 0
        let wallStart = nanoseconds(CLOCK_MONOTONIC)
        let cpuStart = nanoseconds(CLOCK_PROCESS_CPUTIME_ID)
        for _ in 0..<iterations {
            #if os(macOS)
            checksum &+= try autoreleasepool { try consume(url) }
            #else
            checksum &+= try consume(url)
            #endif
        }
        let cpu = nanoseconds(CLOCK_PROCESS_CPUTIME_ID) - cpuStart
        let wall = nanoseconds(CLOCK_MONOTONIC) - wallStart
        precondition(checksum == expected &* UInt64(iterations))
        // Full output receipt is computed after timing, against the same fixture.
        let receipt = PlaylistReceipt(try FolderPlaylistDiscovery.discover(in: url))
        try output(Observation(iterations: iterations, wallNs: wall, cpuNs: cpu,
                               checksum: checksum, receipt: receipt))
    }
}
