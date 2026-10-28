import Dispatch
import Foundation
import IlliquidCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

private struct Workload: Codable, Equatable {
    let count: Int
    let scenario: String
    var id: String { "\(count)-\(scenario)" }
}

private func workloads() -> [Workload] {
    var result: [Workload] = [
        .init(count: 0, scenario: "empty"),
        .init(count: 0, scenario: "stale-appended"),
        .init(count: 1, scenario: "empty"),
        .init(count: 1, scenario: "unchanged"),
    ]
    for count in [32, 1_000, 10_000, 100_000] {
        for scenario in ["empty", "unchanged", "reverse", "stale-appended", "duplicates"] {
            result.append(.init(count: count, scenario: scenario))
        }
    }
    return result
}

private func pooled<Value>(_ body: () -> Value) -> Value {
    #if canImport(ObjectiveC)
    return autoreleasepool(invoking: body)
    #else
    return body()
    #endif
}

private struct Fixture {
    let items: [FolderPlaylistItem]
    let ids: [String]
    let uniqueCount: Int

    init(_ workload: Workload) {
        let count = workload.count
        func path(_ index: Int) -> String {
            "/Volumes/Media/Café/Season 01/Episode "
                + String(format: "%06d", index) + ".mkv"
        }
        let labels: [Int]
        let saved: [Int]
        switch workload.scenario {
        case "duplicates":
            let unique = max(1, count / 2)
            labels = (0..<count).map { $0 % unique }
            saved = (0..<unique).reversed().flatMap { [$0, $0] }
            uniqueCount = min(count, unique)
        case "stale-appended":
            labels = Array((count / 4..<(count / 4 + count)).reversed())
            saved = Array(0..<(count * 3 / 4))
            uniqueCount = count
        default:
            labels = Array((0..<count).reversed())
            saved = workload.scenario == "reverse" ? Array(labels.reversed()) : labels
            uniqueCount = count
        }
        let subtitles = [URL(fileURLWithPath: "/Volumes/Media/shared.en.srt")]
        items = labels.enumerated().map { offset, label in
            FolderPlaylistItem(
                url: URL(fileURLWithPath: path(label)),
                externalSubtitleURLs: subtitles,
                dateAdded: Date(timeIntervalSince1970: Double(offset))
            )
        }
        switch workload.scenario {
        case "empty":
            ids = []
        case "stale-appended":
            ids = ["/Volumes/Media/removed-before.mkv"] + saved.map(path)
                + ["/Volumes/Media/removed-after.mkv"]
        case "duplicates":
            ids = saved.map(path) + ["/Volumes/Media/removed.mkv"]
        default:
            ids = saved.map(path)
        }
    }
}

// The actual production API lives in a separately compiled dynamic module.
// No cross-module optimization or @inlinable entry points are used.
@inline(never)
private func project(_ fixture: Fixture) -> [String] {
    #if CANDIDATE
    return PlaylistMutation.restoringIDs(fixture.items, ids: fixture.ids)
    #else
    return PlaylistMutation.restoringOrder(fixture.items, ids: fixture.ids).map(\.id)
    #endif
}

private func cpuNanoseconds() -> UInt64 {
    var value = timespec()
    precondition(clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &value) == 0)
    return UInt64(value.tv_sec) * 1_000_000_000 + UInt64(value.tv_nsec)
}

private func checksumComponent(_ ids: [String]) -> UInt64 {
    (UInt64(ids.count) &* 0x9E37_79B9_7F4A_7C15)
        ^ UInt64(ids.first?.utf8.count ?? 0)
        ^ (UInt64(ids.last?.utf8.count ?? 0) &* 31)
}

// Dispose of each returned array and drain its autoreleases inside the timed
// call, preventing a loop from retaining temporaries across checkpoints.
@inline(never)
private func constructAndRelease(_ fixture: Fixture) -> UInt64 {
    pooled { checksumComponent(project(fixture)) }
}

private func verify(_ fixture: Fixture, actual: [String]) -> [String: Any] {
    let expected = pooled {
        PlaylistMutation.restoringOrder(fixture.items, ids: fixture.ids).map(\.id)
    }
    precondition(actual == expected, "Complete identity order differs")
    precondition(actual.count == fixture.uniqueCount, "Wrong identity count")
    precondition(zip(actual, expected).allSatisfy { pair in
        pair.0.utf8.elementsEqual(pair.1.utf8)
    }, "Identity spelling differs")
    var hash: UInt64 = 14_695_981_039_346_656_037
    for id in actual {
        for byte in id.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
        hash = hash &* 1_099_511_628_211
    }
    return [
        "complete_array_equality": true,
        "utf8_equality": true,
        "count": actual.count,
        "fnv1a64": String(hash, radix: 16),
    ]
}

private func measure(_ fixture: Fixture, iterations: Int) -> [String: Any] {
    let expectedChecksum = constructAndRelease(fixture)
    _ = cpuNanoseconds()
    _ = DispatchTime.now().uptimeNanoseconds
    var checksum: UInt64 = 0
    let cpuStart = cpuNanoseconds()
    let wallStart = DispatchTime.now().uptimeNanoseconds
    for _ in 0..<iterations { checksum &+= constructAndRelease(fixture) }
    let wallEnd = DispatchTime.now().uptimeNanoseconds
    let cpuEnd = cpuNanoseconds()
    precondition(checksum == expectedChecksum &* UInt64(iterations))
    return [
        "iterations": iterations,
        "checksum": checksum,
        "wall_nanoseconds": wallEnd - wallStart,
        "cpu_nanoseconds": cpuEnd - cpuStart,
    ]
}

#if canImport(Darwin)
private func measureMemory(_ fixture: Fixture) -> (fields: [String: UInt64], result: [String]) {
    // Do not warm up or compute reference results before this interval.
    precondition(playlist_projection_memory_begin() == 0, "Cannot start memory sampler")
    let result = pooled { project(fixture) }
    withExtendedLifetime((fixture, result)) { playlist_projection_memory_end() }
    let baseline = playlist_projection_memory_value(0)
    let peak = playlist_projection_memory_value(1)
    let fields: [String: UInt64] = [
        "baseline_live_bytes": baseline,
        "sampled_peak_live_bytes": peak,
        "sampled_peak_extra_bytes": peak >= baseline ? peak - baseline : 0,
        "final_live_bytes": playlist_projection_memory_value(2),
        "sample_count": playlist_projection_memory_value(3),
        "sampling_window_ns": playlist_projection_memory_value(4),
        "maximum_sample_gap_ns": playlist_projection_memory_value(5),
        "peak_rss_before_bytes": playlist_projection_memory_value(6),
        "peak_rss_after_bytes": playlist_projection_memory_value(7),
        "requested_interval_ns": 200_000,
    ]
    return (fields, result)
}
#endif

@main
private enum Driver {
    static func main() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        if args == ["--list"] {
            print(String(decoding: try JSONEncoder().encode(workloads()), as: UTF8.self))
            return
        }
        precondition(args.count == 3, "MODE WORKLOAD ITERATIONS")
        let mode = args[0]
        guard let workload = workloads().first(where: { $0.id == args[1] }),
              let iterations = Int(args[2]), iterations > 0 else {
            preconditionFailure("Invalid arguments")
        }
        let fixture = pooled { Fixture(workload) }
        var output: [String: Any] = [
            "schema": 1, "mode": mode, "workload": workload.id,
            "input_count": workload.count, "scenario": workload.scenario,
        ]
        switch mode {
        case "verify":
            output["receipt"] = verify(fixture, actual: pooled { project(fixture) })
        case "timing":
            output.merge(measure(fixture, iterations: iterations)) { _, new in new }
            output["receipt"] = verify(fixture, actual: pooled { project(fixture) })
        case "memory":
            #if canImport(Darwin)
            let measured = measureMemory(fixture)
            output["memory"] = measured.fields
            // Verify the same returned array that was held during sampling.
            output["receipt"] = verify(fixture, actual: measured.result)
            #else
            preconditionFailure("Memory sampling requires Darwin")
            #endif
        default:
            preconditionFailure("Unknown mode")
        }
        let data = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
        withExtendedLifetime(fixture) {}
    }
}
