import Foundation
import ThumbnailRanking

@main
struct RankingDriver {
    static func main() throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 5,
              let discoveredCount = Int(arguments[1]), discoveredCount > 0,
              let exclusionCount = Int(arguments[2]), exclusionCount >= 0,
              ["none", "present"].contains(arguments[3]),
              let iterations = Int(arguments[4]), iterations >= 0 else {
            fatalError("Usage: driver DISCOVERED_COUNT EXCLUSIONS none|present ITERATIONS")
        }
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let discovered = (0..<discoveredCount).map {
            URL(fileURLWithPath: "/media/series-\($0 % 16)/episode-\($0).mkv")
        }
        let visible = Set(discovered.prefix(32))
        let neighbors = Array(discovered.prefix(9))
        let distances = Dictionary(uniqueKeysWithValues: neighbors.enumerated().map { ($0.element, $0.offset) })
        let recent = Dictionary(uniqueKeysWithValues: discovered.prefix(128).enumerated().map {
            ($0.element, now.addingTimeInterval(-Double($0.offset % 11) * 86400))
        })
        // Match runPass's overlapping groups and metadata bounds. All setup is
        // outside timing; production ranking performs first-occurrence deduplication.
        let urls = [discovered[0]]
            + visible.sorted { $0.path < $1.path }
            + discovered
            + neighbors
            + recent.keys.sorted { $0.path < $1.path }
        let candidates = urls.map {
            ThumbnailPolicy.Candidate(url: $0, lastUsed: recent[$0],
                isVisible: visible.contains($0), neighborDistance: distances[$0])
        }
        var preferences = ThumbnailPreferences()
        if exclusionCount > 0 {
            preferences.excludedFolderPaths = ["/media/series-15"]
                + (1..<exclusionCount).map { "/other-library/excluded-\($0)" }
        }
        let folder = arguments[3] == "none" ? nil : URL(fileURLWithPath: "/media/series-0")
        func ranked() -> [URL] {
            ThumbnailPolicy.ranked(candidates, current: discovered[0], folder: folder,
                now: now, preferences: preferences, maximumCount: candidates.count)
        }

        let expected = ranked()
        if iterations == 0 {
            let receipt: [String: Any] = [
                "discovered_count": discoveredCount,
                "candidate_count": candidates.count,
                "unique_count": Set(urls).count,
                "result_count": expected.count,
                "folder": arguments[3],
                "exclusions": exclusionCount,
                "ordered_urls": expected.map(\.absoluteString),
            ]
            print(String(decoding: try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys]),
                         as: UTF8.self))
            return
        }
        for _ in 0..<4 { precondition(ranked().count == expected.count) }
        var checksum = 0
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<iterations {
            // ranked is in a separately compiled, non-inlinable production
            // module. Observing the count keeps the opaque call and avoids
            // adding URL/path formatting to the timed operation.
            checksum &+= ranked().count
        }
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        precondition(checksum == expected.count * iterations)
        let receipt: [String: Any] = [
            "iterations": iterations,
            "elapsed_ns": elapsed,
            "checksum": checksum,
            "result_count": expected.count,
        ]
        print(String(decoding: try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys]),
                     as: UTF8.self))
    }
}
