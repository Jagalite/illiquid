import Foundation

// BenchmarkScanner and SourceMediaPresenceCursor.Summary are generated from
// the checked production sources by run.py. No propagation algorithm lives here.
private typealias Summary = SourceMediaPresenceCursor.Summary

private struct Fixture {
    let name: String
    let roots: [String]
    let summaries: [String: Summary]
    let buffered: [String: Summary]
    let initial: [String: Bool]
    let shape: String
    let depth: Int
    let rootChildren: Int

    var metadata: [String: Any] {
        ["case": name, "shape": shape, "depth": depth,
         "root_children": rootChildren, "batch_keys": buffered.count,
         "summaries": summaries.count, "initial_results": initial.count]
    }
}

private struct Generator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9e3779b97f4a7c15
        var value = state
        value = (value ^ (value >> 30)) &* 0xbf58476d1ce4e5b9
        value = (value ^ (value >> 27)) &* 0x94d049bb133111eb
        return value ^ (value >> 31)
    }
}

private func summary(_ children: Set<String> = [], media: Bool = false,
                     complete: Bool = true, readable: Bool = true) -> Summary {
    Summary(hasDirectMedia: media, children: children,
            isComplete: complete, isReadable: readable)
}

private func wide(_ count: Int, batch: Int, kind: String, seed: UInt64) -> Fixture {
    let root = "/media"
    let children = (0..<count).map { root + "/Folder-\($0)" }
    var generator = Generator(state: seed)
    let shuffled = children.shuffled(using: &generator)
    let changed = Array(shuffled.prefix(batch - 1))
    let mixed = kind == "unknown"
    var summaries = [root: summary(Set(children), media: kind == "direct",
                                   complete: !mixed)]
    var initial: [String: Bool] = [:]
    for (index, child) in children.enumerated() {
        summaries[child] = summary(readable: !mixed || index % 7 != 0)
        if !mixed || index % 7 != 0 { initial[child] = false }
    }
    for (index, child) in changed.enumerated() {
        initial[child] = nil
        if kind == "positive", index % 8 == 0 {
            summaries[child] = summary(media: true)
        }
    }
    var buffered = [root: summaries[root]!]
    for child in changed { buffered[child] = summaries[child]! }
    return Fixture(name: "wide-\(kind)-\(count)-b\(batch)", roots: [root],
                   summaries: summaries, buffered: buffered, initial: initial,
                   shape: kind, depth: 1, rootChildren: count)
}

private func deep(_ depth: Int, single: Bool, unicode: Bool = false) -> Fixture {
    var paths = [unicode ? "/映画" : "/media"]
    for index in 1...depth {
        paths.append(paths.last! + (unicode ? "/Cafe\u{301}-\(index)" : "/d\(index)"))
    }
    var summaries: [String: Summary] = [:]
    for index in paths.indices {
        summaries[paths[index]] = summary(
            index + 1 < paths.count ? [paths[index + 1]] : [],
            media: single && index == paths.count - 1)
    }
    var initial = single ? Dictionary(uniqueKeysWithValues: paths.map { ($0, false) }) : [:]
    if single { initial[paths.last!] = nil }
    let buffered = single ? [paths.last!: summaries[paths.last!]!] : summaries
    return Fixture(name: "deep-\(single ? "single" : "full")-\(depth)\(unicode ? "-unicode" : "")",
                   roots: [paths[0]], summaries: summaries, buffered: buffered,
                   initial: initial, shape: single ? "single-leaf-repair" : "complete-chain",
                   depth: depth, rootChildren: 1)
}

private func repair(_ count: Int, rootOnly: Bool) -> Fixture {
    let root = "/media"
    let children = (0..<count).map { root + "/Cached-\($0)" }
    var summaries = [root: summary(Set(children), media: rootOnly)]
    var initial: [String: Bool] = [:]
    for child in children {
        summaries[child] = summary()
        initial[child] = false
    }
    let changed = rootOnly ? root : children[count / 2]
    summaries[changed] = rootOnly ? summaries[root] : summary(media: true)
    initial[changed] = nil
    return Fixture(name: "repair-\(rootOnly ? "root" : "cached-sibling")-\(count)",
                   roots: [root], summaries: summaries,
                   buffered: [changed: summaries[changed]!], initial: initial,
                   shape: rootOnly ? "direct-media-repair" : "cached-sibling-repair",
                   depth: 1, rootChildren: count)
}

private func fixtures(seed: UInt64) -> [Fixture] {
    [wide(256, batch: 64, kind: "empty", seed: seed),
     wide(1_024, batch: 256, kind: "empty", seed: seed),
     wide(4_096, batch: 1_024, kind: "empty", seed: seed),
     wide(4_096, batch: 4_097, kind: "empty", seed: seed),
     wide(1_024, batch: 256, kind: "positive", seed: seed),
     wide(4_096, batch: 1_024, kind: "direct", seed: seed),
     wide(1_024, batch: 256, kind: "unknown", seed: seed),
     deep(64, single: false), deep(96, single: true),
     deep(48, single: false, unicode: true),
     repair(4_096, rootOnly: false), repair(1_024, rootOnly: true),
     Fixture(name: "tiny-root", roots: ["/media"],
             summaries: ["/media": summary()], buffered: ["/media": summary()],
             initial: [:], shape: "single-empty-root", depth: 0, rootChildren: 0)]
}

private func emit(_ value: Any) throws {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))
}

@main
private struct Driver {
    @MainActor
    static func main() throws {
        let arguments = CommandLine.arguments
        func option(_ name: String, _ fallback: String) -> String {
            guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else {
                return fallback
            }
            return arguments[index + 1]
        }
        let mode = option("--mode", "check")
        let seed = UInt64(option("--seed", "1"))!
        let ownership = option("--ownership", "shared")
        precondition(ownership == "shared" || ownership == "unique")
        let all = fixtures(seed: seed)
        if mode == "list" { try emit(all.map(\.metadata)); return }
        if mode == "check" {
            var rows: [[String: Any]] = []
            for fixture in all {
                let scanner = BenchmarkScanner(roots: fixture.roots, summaries: fixture.summaries)
                scanner.resetResults(fixture.initial, unique: ownership == "unique")
                scanner.publish(fixture.buffered)
                let first = scanner.results
                scanner.publish(fixture.buffered)
                precondition(first == scanner.results, "Publication must be idempotent")
                var row = fixture.metadata
                row["results"] = first
                rows.append(row)
            }
            try emit(rows)
            return
        }
        precondition(mode == "time")
        let name = option("--case", "")
        guard let fixture = all.first(where: { $0.name == name }) else {
            throw NSError(domain: "Unknown benchmark case: \(name)", code: 1)
        }
        let iterations = Int(option("--iterations", "1"))!
        let warmup = Int(option("--warmup", "2"))!
        precondition(iterations > 0 && warmup >= 0)
        let scanner = BenchmarkScanner(roots: fixture.roots, summaries: fixture.summaries)
        for _ in 0..<warmup {
            scanner.resetResults(fixture.initial, unique: ownership == "unique")
            scanner.publish(fixture.buffered)
        }
        var elapsed: UInt64 = 0
        for _ in 0..<iterations {
            // Fixture ownership deliberately survives in shared mode. The
            // first production setter's dictionary copy is inside the timer.
            scanner.resetResults(fixture.initial, unique: ownership == "unique")
            let start = DispatchTime.now().uptimeNanoseconds
            scanner.publish(fixture.buffered)
            elapsed &+= DispatchTime.now().uptimeNanoseconds - start
        }
        var row = fixture.metadata
        row["iterations"] = iterations
        row["warmup"] = warmup
        row["seed"] = seed
        row["ownership"] = ownership
        row["timed_nanoseconds"] = elapsed
        row["nanoseconds_per_publication"] = Double(elapsed) / Double(iterations)
        // Complete result serialization/verification is outside the timer.
        row["results"] = scanner.results
        try emit(row)
    }
}
