import Dispatch
import Foundation
import IlliquidCore
@testable import IlliquidApp

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

@_silgen_name("illiquid_live_allocated_bytes")
private func liveAllocatedBytes() -> UInt64

@inline(__always)
private func pooled<T>(_ body: () throws -> T) rethrows -> T {
    #if canImport(Darwin)
    return try autoreleasepool(invoking: body)
    #else
    return try body()
    #endif
}

private struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ text: String) { description = text }
}

private struct Fixture {
    let playlist: [FolderPlaylistItem]
    let current: URL?
    let expectedURLs: [URL]
    let expectedDistances: [URL: Int]

    init(count: Int, position: String) throws {
        let playlist = (0..<count).map {
            FolderPlaylistItem(url: URL(fileURLWithPath: "/Media/Episode-\($0).mkv"))
        }
        self.playlist = playlist
        let anchor: Int?
        switch position {
        case "none": anchor = nil; current = nil
        case "missing": anchor = nil; current = URL(fileURLWithPath: "/Media/missing.mkv")
        case "head", "middle", "tail":
            guard count > 0 else { throw Failure("An anchor requires a nonempty playlist") }
            let index = position == "head" ? 0 : (position == "middle" ? count / 2 : count - 1)
            anchor = index
            current = playlist[index].url
        default: throw Failure("Unknown position")
        }
        if let anchor {
            // An index-distance oracle, independent of the production search.
            let indices = playlist.indices.filter { abs($0 - anchor) <= 4 }
            expectedURLs = indices.map { playlist[$0].url }
            expectedDistances = Dictionary(uniqueKeysWithValues: indices.map {
                (playlist[$0].url, abs($0 - anchor))
            })
        } else {
            expectedURLs = []
            expectedDistances = [:]
        }
    }
}

@inline(never)
private func produce(_ fixture: Fixture) -> ThumbnailPlaylistNeighborhood {
    pooled { ThumbnailPlaylistNeighborhood(playlist: fixture.playlist, current: fixture.current) }
}

private func validate(_ result: ThumbnailPlaylistNeighborhood, _ fixture: Fixture) throws {
    guard result.urls == fixture.expectedURLs, result.distances == fixture.expectedDistances else {
        throw Failure("Neighborhood differs from the independent index-distance oracle")
    }
}

@inline(never)
private func consume(_ result: ThumbnailPlaylistNeighborhood) -> UInt64 {
    var checksum = UInt64(result.urls.count * 31 + result.distances.count)
    for value in result.distances.values { checksum &+= UInt64(value) }
    return checksum
}

private func cpuNanoseconds() -> UInt64 {
    var value = timespec()
    precondition(clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &value) == 0)
    return UInt64(value.tv_sec) * 1_000_000_000 + UInt64(value.tv_nsec)
}

private func receipt(_ result: ThumbnailPlaylistNeighborhood) -> [String: Any] {
    [
        "urls": result.urls.map(\.absoluteString),
        "distances": Dictionary(uniqueKeysWithValues: result.distances.map { ($0.key.absoluteString, $0.value) }),
        "output_url_count": result.urls.count,
        "output_url_capacity": result.urls.capacity,
    ]
}

@inline(never)
private func warm(_ fixture: Fixture) throws {
    try pooled {
        let result = produce(fixture)
        try validate(result, fixture)
        _ = consume(result)
        _ = liveAllocatedBytes()
    }
}

@inline(never)
private func inventory(_ fixture: Fixture) throws -> [String: Any] {
    // This is a separate allocation experiment, not part of timed execution.
    // legacyProjection is generated from the exact old scheduler map statement.
    pooled { withExtendedLifetime(legacyProjection(fixture.playlist)) {} }
    let memory = pooled { () -> [String: Any] in
        let before = liveAllocatedBytes()
        let projected = legacyProjection(fixture.playlist)
        let after = withExtendedLifetime(projected) { liveAllocatedBytes() }
        return withExtendedLifetime(projected) {
            [
                "legacy_projection_count": projected.count,
                "legacy_projection_capacity": projected.capacity,
                "url_stride_bytes": MemoryLayout<URL>.stride,
                "legacy_projection_payload_bytes": projected.capacity * MemoryLayout<URL>.stride,
                "legacy_projection_live_allocator_delta_bytes": Int64(after) - Int64(before),
            ]
        }
    }
    let output = produce(fixture)
    try validate(output, fixture)
    return memory.merging(receipt(output)) { _, new in new }
}

@main
private struct Driver {
    static func main() {
        do {
            let args = CommandLine.arguments
            guard args.count == 5, let count = Int(args[2]), count >= 0,
                  let iterations = Int(args[4]), iterations > 0 else {
                throw Failure("Usage: Driver <measure|inventory> <count> <none|missing|head|middle|tail> <iterations>")
            }
            let fixture = try pooled { try Fixture(count: count, position: args[3]) }
            try warm(fixture)
            var row: [String: Any] = [
                "count": count, "position": args[3], "iterations": iterations,
            ]
            if args[1] == "inventory" {
                row.merge(try inventory(fixture)) { _, new in new }
            } else if args[1] == "measure" {
                let expected = consume(produce(fixture))
                var checksum: UInt64 = 0
                let cpuStart = cpuNanoseconds()
                let wallStart = DispatchTime.now().uptimeNanoseconds
                for _ in 0..<iterations {
                    checksum &+= consume(produce(fixture))
                }
                let wall = DispatchTime.now().uptimeNanoseconds - wallStart
                let cpu = cpuNanoseconds() - cpuStart
                let result = produce(fixture)
                try validate(result, fixture)
                guard checksum == expected &* UInt64(iterations) else {
                    throw Failure("Timed output checksum differs from the verified result")
                }
                row.merge(receipt(result)) { _, new in new }
                row["wall_ns"] = wall
                row["cpu_ns"] = cpu
                row["checksum"] = checksum
            } else {
                throw Failure("Unknown mode")
            }
            withExtendedLifetime(fixture) {}
            let data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([10]))
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(1)
        }
    }
}
