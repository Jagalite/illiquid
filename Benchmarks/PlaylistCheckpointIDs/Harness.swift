import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

private struct Fixture {
    let items: [FolderPlaylistItem]
    let saved: [String]
}

private func fixture(_ count: Int, _ scenario: String) -> Fixture {
    let uniqueCount = scenario == "duplicates" ? max(1, count / 4) : count
    let subtitles = [URL(fileURLWithPath: "/Media/Subtitles/shared.en.srt")]
    let base = (0..<uniqueCount).map { index in
        FolderPlaylistItem(
            url: URL(fileURLWithPath:
                "/Media/長いフォルダー/Café/Season \(index % 7)/Episode \(index).mkv"),
            externalSubtitleURLs: subtitles,
            dateAdded: Date(timeIntervalSince1970: Double(index))
        )
    }
    var saved = scenario == "no-base" ? [] : base.map(\.id)
    var items = Array(base.reversed())
    if scenario == "edited" {
        items = items.enumerated().filter { $0.offset % 4 != 0 }.map(\.element)
        items += (0..<(count / 4)).map {
            FolderPlaylistItem(url: URL(fileURLWithPath: "/New/Episode \($0).mkv"))
        }
    } else if scenario == "duplicates" {
        items = (0..<count).map { base[(uniqueCount - 1) - ($0 % uniqueCount)] }
        saved += saved + ["/removed.mkv"]
    }
    return Fixture(items: items, saved: saved)
}

@inline(never)
private func baseline(_ fixture: Fixture) -> [String] {
    PlaylistMutation.restoringOrder(fixture.items, ids: fixture.saved).map(\.id)
}

@inline(never)
private func candidate(_ fixture: Fixture) -> [String] {
    PlaylistMutation.restoringIDs(fixture.items, ids: fixture.saved)
}

private func scoped<T>(_ work: () -> T) -> T {
    #if canImport(ObjectiveC)
    return autoreleasepool(invoking: work)
    #else
    return work()
    #endif
}

@inline(never)
private func checksum(_ values: [String]) -> UInt64 {
    var hash: UInt64 = 14_695_981_039_346_656_037
    for value in values {
        for byte in value.utf8 {
            hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }
        hash = (hash ^ 255) &* 1_099_511_628_211
    }
    return hash
}

private func peakRSS() -> UInt64 {
    var usage = rusage()
    #if canImport(Darwin)
    precondition(getrusage(RUSAGE_SELF, &usage) == 0)
    return UInt64(usage.ru_maxrss)
    #else
    precondition(getrusage(Int32(RUSAGE_SELF.rawValue), &usage) == 0)
    return UInt64(usage.ru_maxrss) * 1024
    #endif
}

@main
private enum Main {
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count == 6, let count = Int(args[3]), count > 0,
              let iterations = Int(args[5]), iterations > 0,
              ["parity", "timing", "memory"].contains(args[1]),
              ["baseline", "candidate"].contains(args[2]),
              ["unchanged", "edited", "duplicates", "no-base"].contains(args[4])
        else {
            fatalError("Usage: benchmark MODE VARIANT COUNT SCENARIO ITERATIONS")
        }
        let mode = args[1], variant = args[2], scenario = args[4]
        let input = scoped { fixture(count, scenario) }
        let operation = variant == "baseline" ? baseline : candidate
        var row: [String: Any] = [
            "mode": mode, "variant": variant, "requested_count": count,
            "input_count": input.items.count, "saved_count": input.saved.count,
            "scenario": scenario, "iterations": iterations,
        ]
        if mode == "parity" {
            let before = baseline(input), after = candidate(input)
            precondition(before.count == after.count)
            precondition(zip(before, after).allSatisfy { pair in
                pair.0.utf8.elementsEqual(pair.1.utf8)
            })
            row["checksum"] = String(checksum(before))
            row["result_count"] = before.count
            row["byte_equal"] = true
        } else if mode == "memory" {
            // First operation only: never run the other variant or warm up here.
            let before = peakRSS()
            let result = operation(input)
            let after = peakRSS()
            row["fixture_peak_rss_bytes"] = before
            row["peak_rss_bytes"] = after
            row["peak_growth_bytes"] = after - before
            row["checksum"] = String(checksum(result))
            row["result_count"] = result.count
            withExtendedLifetime(result) {}
        } else {
            let expected = scoped { checksum(operation(input)) }
            var elapsed: UInt64 = 0
            for _ in 0..<iterations {
                elapsed += scoped {
                    let start = DispatchTime.now().uptimeNanoseconds
                    let result = operation(input)
                    let end = DispatchTime.now().uptimeNanoseconds
                    // Consume all IDs after timing, before releasing this result.
                    precondition(checksum(result) == expected)
                    return end - start
                }
            }
            row["elapsed_ns"] = elapsed
            row["ns_per_operation"] = Double(elapsed) / Double(iterations)
            row["checksum"] = String(expected)
        }
        let data = try JSONSerialization.data(
            withJSONObject: row, options: [.sortedKeys]
        )
        print(String(decoding: data, as: UTF8.self))
    }
}
