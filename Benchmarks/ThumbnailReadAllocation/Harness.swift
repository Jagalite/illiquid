import CThumbnailReadMetrics
import Dispatch
import Foundation
import ThumbnailReadProjection

// No ImageIO, cache actor, playback decoder, or GPU work runs in this component
// harness. Both variants call the complete extracted production read function.
@inline(never)
private func read(_ url: URL) -> Data? {
    #if canImport(ObjectiveC)
    return autoreleasepool { NativeThumbnailDiskCache.readEncodedImage(at: url) }
    #else
    return NativeThumbnailDiskCache.readEncodedImage(at: url)
    #endif
}

@inline(never)
private func warmUp(_ url: URL) {
    _ = read(url)
    _ = thumbnail_heap_bytes()
    _ = thumbnail_resident_bytes()
    _ = thumbnail_cpu_nanoseconds()
    _ = DispatchTime.now().uptimeNanoseconds
}

@inline(never)
private func check(_ url: URL, expectedCount: Int) throws -> [String: Any] {
    let result = read(url)
    let rejected = expectedCount < 0 || expectedCount > NativeThumbnailDiskCache.maximumEncodedImageBytes
    if rejected {
        precondition(result == nil, "An unavailable or oversized input was accepted")
        return ["expected_bytes": expectedCount, "rejected": true, "exact_bytes_equal": true]
    }
    let expected = try Data(contentsOf: url)
    precondition(expected.count == expectedCount)
    precondition(result == expected, "The complete returned byte sequence changed")
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in result! { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
    return ["expected_bytes": expectedCount, "returned_bytes": result!.count,
            "rejected": false, "exact_bytes_equal": true, "fnv1a64": String(hash, radix: 16)]
}

@inline(never)
private func heldSnapshot(_ url: URL) -> (heap: UInt64, resident: UInt64, count: Int) {
    let held = read(url)
    let heap = withExtendedLifetime(held) { thumbnail_heap_bytes() }
    let resident = withExtendedLifetime(held) { thumbnail_resident_bytes() }
    // No Data escapes this out-of-line function. Its return gives the outer
    // measurement a release boundary without relying on local ARC scheduling.
    return (heap, resident, held?.count ?? -1)
}

@inline(never)
private func measureMemory(_ url: URL, expectedCount: Int) -> [String: Any] {
    let heapMetric = String(cString: thumbnail_heap_metric())
    let residentMetric = String(cString: thumbnail_resident_metric())
    precondition(heapMetric != "unsupported", "Live allocator metric unavailable")
    precondition(residentMetric != "unsupported", "Current resident metric unavailable")
    let heapBefore = thumbnail_heap_bytes()
    let residentBefore = thumbnail_resident_bytes()
    let held = heldSnapshot(url)
    let heapReleased = thumbnail_heap_bytes()
    let residentReleased = thumbnail_resident_bytes()
    precondition(held.count == (expectedCount > NativeThumbnailDiskCache.maximumEncodedImageBytes ? -1 : expectedCount))
    precondition(residentBefore > 0 && held.resident > 0 && residentReleased > 0,
                 "Current resident sampler failed")
    return [
        "heap_metric": heapMetric, "resident_metric": residentMetric,
        "heap_before_bytes": heapBefore, "heap_held_bytes": held.heap,
        "heap_released_bytes": heapReleased,
        "heap_held_delta_bytes": Int64(held.heap) - Int64(heapBefore),
        "heap_released_delta_bytes": Int64(heapReleased) - Int64(heapBefore),
        "resident_before_bytes": residentBefore, "resident_held_bytes": held.resident,
        "resident_released_bytes": residentReleased,
        "resident_held_delta_bytes": Int64(held.resident) - Int64(residentBefore),
        "resident_released_delta_bytes": Int64(residentReleased) - Int64(residentBefore)
    ]
}

@inline(never)
private func measureLoop(_ url: URL, iterations: Int, allocations: Bool) -> [String: Any] {
    var checksum: UInt64 = 0
    #if ALLOCATIONS
    precondition(allocations)
    meter_begin()
    #else
    precondition(!allocations)
    let cpuStart = thumbnail_cpu_nanoseconds()
    precondition(cpuStart > 0, "Process CPU clock unavailable")
    let wallStart = DispatchTime.now().uptimeNanoseconds
    #endif
    for _ in 0..<iterations {
        let value = read(url)
        checksum &+= UInt64(value?.count ?? 1)
        checksum &+= UInt64(value?.last ?? 0)
    }
    #if ALLOCATIONS
    meter_end()
    return ["iterations": iterations, "checksum": checksum,
            "allocation_requests": meter_requests(), "allocation_requested_bytes": meter_bytes()]
    #else
    let wall = DispatchTime.now().uptimeNanoseconds - wallStart
    let cpuEnd = thumbnail_cpu_nanoseconds()
    precondition(cpuEnd >= cpuStart, "Process CPU clock failed or moved backwards")
    let cpu = cpuEnd - cpuStart
    return ["iterations": iterations, "checksum": checksum,
            "wall_nanoseconds": wall, "cpu_nanoseconds": cpu]
    #endif
}

@main
private struct Driver {
    static func main() throws {
        let args = CommandLine.arguments
        precondition(args.count == 5, "Usage: MODE PATH EXPECTED_BYTES ITERATIONS")
        let mode = args[1]
        let url = URL(fileURLWithPath: args[2])
        let expectedCount = Int(args[3])!
        let iterations = Int(args[4])!
        precondition(iterations > 0)
        var output: [String: Any] = ["schema": 1, "mode": mode]
        if mode != "verify" {
            warmUp(url)
            switch mode {
            case "memory": output.merge(measureMemory(url, expectedCount: expectedCount)) { _, new in new }
            case "timing", "allocations":
                output.merge(measureLoop(url, iterations: iterations, allocations: mode == "allocations")) { _, new in new }
            default: preconditionFailure("Unknown benchmark mode")
            }
        }
        // Full-byte comparisons and hashing run after every memory/time sample.
        output["receipt"] = try check(url, expectedCount: expectedCount)
        let encoded = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
        print(String(decoding: encoded, as: UTF8.self))
    }
}
