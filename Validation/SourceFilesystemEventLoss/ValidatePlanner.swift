import Foundation

struct Receipt: Equatable {
    let directories: Set<String>
    let trees: Set<String>
    let roots: Set<String>

    init(_ plan: SourceFilesystemInvalidationPlan) {
        directories = plan.directoriesToReload
        trees = plan.treesToInvalidate
        roots = plan.rootsToRescan
    }

    init(_ plan: BaselineSourceFilesystemInvalidationPlan) {
        directories = plan.directoriesToReload
        trees = plan.treesToInvalidate
        roots = plan.rootsToRescan
    }
}

@main struct ValidatePlanner {
    static func main() throws {
        let rootSets: [[String]] = [
            [], ["/media/library"], ["/media/library", "/other"],
            ["/media/library", "/media/library/Season 1"],
            ["/media/library", "/media/library/../library"],
            ["/"], ["/", "/media/library"],
        ]
        let paths = [
            "/", "/Movie.mkv", "/media", "/media/library", "/media/library/Movie.mkv",
            "/media/library/Season 1", "/media/library/Season 1/Episode.mkv",
            "/media/library/.plexmatch", "/media/library/Movie.NFO", "/media/library2/Movie.mkv",
            "/other", "/other/Movie.mkv", "/outside", "/日本語/Movie.mkv",
        ]
        var singleCases = 0
        var parityCases = 0
        var lossCases = 0
        var batchCases = 0
        var assertions = 0
        var failures = 0
        func check(_ ok: Bool, _ description: String) {
            assertions += 1
            if !ok {
                failures += 1
                if failures <= 10 { print("FAIL: \(description)") }
            }
        }
        // Exclude known root-containment defects from baseline-parity assertions.
        // PRs #12/#17 own those changes; this harness isolates event-loss recovery.
        for rootPaths in rootSets {
            let roots = rootPaths.map { URL(fileURLWithPath: $0, isDirectory: true) }
            let canonical = Set(roots.map { $0.absoluteURL.standardized.path })
            for path in paths {
                for raw in UInt16(0)...UInt16(255) {
                    let event = SourceFilesystemEvent(path: path, flags: .init(rawValue: raw))
                    let actual = SourceFilesystemInvalidationPlanner.plan(events: [event], roots: roots)
                    singleCases += 1
                    check(actual.rootsToRescan.isSubset(of: canonical), "rescan escapes watched roots")
                    if event.flags.contains(.eventsDropped) {
                        lossCases += 1
                        check(actual == .init(rootsToRescan: canonical), "loss does not rescan all roots")
                    } else if path != "/" && !canonical.contains("/") {
                        parityCases += 1
                        let old = BaselineSourceFilesystemInvalidationPlanner.plan(
                            events: [.init(path: path, flags: .init(rawValue: raw))], roots: roots)
                        check(Receipt(actual) == Receipt(old), "ordinary baseline parity failed")
                    }
                }
            }
        }
        // Repeatable multi-event batches, including contradictory/coalesced flags.
        var seed: UInt64 = 0x11_11_2026
        func next(_ upper: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 32) % UInt64(upper))
        }
        for _ in 0..<5000 {
            let roots = rootSets[next(rootSets.count)].map { URL(fileURLWithPath: $0, isDirectory: true) }
            let canonical = Set(roots.map { $0.absoluteURL.standardized.path })
            let events = (0..<(1 + next(6))).map { _ in
                SourceFilesystemEvent(path: paths[next(paths.count)], flags: .init(rawValue: UInt16(next(256))))
            }
            let actual = SourceFilesystemInvalidationPlanner.plan(events: events, roots: roots)
            batchCases += 1
            check(actual == SourceFilesystemInvalidationPlanner.plan(events: Array(events.reversed()), roots: roots), "batch order changes plan")
            check(actual.rootsToRescan.isSubset(of: canonical), "batch rescan escapes watched roots")
            if events.contains(where: { $0.flags.contains(.eventsDropped) }) {
                check(actual == .init(rootsToRescan: canonical), "batch loses stream-wide recovery")
            } else if !canonical.contains("/") && !events.contains(where: { $0.path == "/" }) {
                parityCases += 1
                let old = BaselineSourceFilesystemInvalidationPlanner.plan(
                    events: events.map { .init(path: $0.path, flags: .init(rawValue: $0.flags.rawValue)) }, roots: roots)
                check(Receipt(actual) == Receipt(old), "batch baseline parity failed")
            }
        }
        let summary = [
            "single_event_cases": singleCases, "batch_cases": batchCases,
            "baseline_parity_cases": parityCases, "single_event_loss_cases": lossCases,
            "assertions": assertions, "failures": failures,
        ]
        let data = try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
        if failures != 0 { exit(1) }
    }
}
