import CPresenceHeap
import Foundation
@testable import IlliquidApp

private struct Workload {
    let total: Int
    let local: Int
    let mixedEligibility: Bool
    var root = "/library/target"

    static let cases: [String: Workload] = [
        "empty": .init(total: 0, local: 0, mixedEligibility: false),
        "small-32-8": .init(total: 32, local: 8, mixedEligibility: false),
        "repair-1000-100": .init(total: 1_000, local: 100, mixedEligibility: false),
        "repair-10000-100": .init(total: 10_000, local: 100, mixedEligibility: false),
        "repair-100000-100": .init(total: 100_000, local: 100, mixedEligibility: false),
        "repair-100000-10000": .init(total: 100_000, local: 10_000, mixedEligibility: false),
        "mixed-100000-100": .init(total: 100_000, local: 100, mixedEligibility: true),
        "whole-tree-100000": .init(total: 100_000, local: 100_000, mixedEligibility: false),
        "filesystem-root-10000": .init(total: 10_000, local: 10_000,
                                         mixedEligibility: false, root: "/"),
    ]
}

private struct Lookup {
    let path: String
    let value: Bool
    let reusable: Bool
    let local: Bool
}

@MainActor
private struct Fixture {
    let scanner: PresenceSnapshotBenchmarkScanner
    let root: String
    let lookups: [Lookup]
    let reusableTotal: Int
    let reusableLocal: Int
}

// The input dictionaries leave this scope before any allocation sample. Holding
// an extra copy would make the candidate's first publication copy its table too.
@MainActor @inline(never)
private func makeFixture(_ workload: Workload, seed: UInt64) -> Fixture {
    var results: [String: Bool] = [:]
    var summaries: [String: SourceMediaPresenceCursor.Summary] = [:]
    var lookups: [Lookup] = []
    results.reserveCapacity(workload.total + 1)
    summaries.reserveCapacity(workload.total)
    lookups.reserveCapacity(workload.total)
    var reusableTotal = 0
    var reusableLocal = 0
    for index in 0..<workload.total {
        let local = index < workload.local
        let base = local ? "/library/target" : "/library/target-neighbor"
        let path = base + "/Group-\((index + Int(seed % 19)) % 19)/Folder-\(index)"
        let complete = !workload.mixedEligibility || (index + Int(seed % 17)) % 17 != 3
        let readable = !workload.mixedEligibility || (index + Int(seed % 23)) % 23 != 5
        // Incomplete traversal may already establish a positive media result.
        let value = !complete || !readable || (index + Int(seed % 2)).isMultiple(of: 2)
        results[path] = value
        summaries[path] = .init(hasDirectMedia: value, children: [],
                                isComplete: complete, isReadable: readable)
        let reusable = complete && readable
        reusableTotal += reusable ? 1 : 0
        reusableLocal += reusable && local ? 1 : 0
        lookups.append(.init(path: path, value: value, reusable: reusable, local: local))
    }
    return Fixture(scanner: PresenceSnapshotBenchmarkScanner(results: results, summaries: summaries),
                   root: workload.root, lookups: lookups,
                   reusableTotal: reusableTotal, reusableLocal: reusableLocal)
}

@MainActor @inline(never)
private func snapshotCycle(_ fixture: Fixture) -> UInt64 {
    let snapshot = fixture.scanner.snapshot(in: fixture.root)
    return withExtendedLifetime(snapshot) { UInt64(snapshot.count) }
}

// Verify every input key, including false versus absent and unrelated paths.
// The returned receipt covers all reachable lookups and must match both builds.
@MainActor
private func verify(_ snapshot: [String: Bool], fixture: Fixture) -> UInt64 {
    let scoped = PresenceSnapshotBenchmarkScanner.isScoped
    precondition(snapshot.count == (scoped ? fixture.reusableLocal : fixture.reusableTotal))
    var receipt: UInt64 = 14_695_981_039_346_656_037
    for lookup in fixture.lookups {
        let expected: Bool? = lookup.reusable && (!scoped || lookup.local) ? lookup.value : nil
        precondition(snapshot[lookup.path] == expected)
        if lookup.local {
            for byte in lookup.path.utf8 { receipt = (receipt ^ UInt64(byte)) &* 1_099_511_628_211 }
            let value: UInt64 = snapshot[lookup.path].map { $0 ? 2 : 1 } ?? 0
            receipt = (receipt ^ value) &* 1_099_511_628_211
        }
    }
    precondition(snapshot[fixture.root] == nil)
    return receipt
}

private struct Measurement: Encodable {
    let workload: String
    let seed: UInt64
    let iterations: Int
    let sourceResults: Int
    let reachableResults: Int
    let snapshotEntries: Int
    let snapshotCapacity: Int
    let reachableLookupReceipt: UInt64
    let snapshotChecksum: UInt64
    let wallNanoseconds: UInt64
    let cpuNanoseconds: UInt64
    let allocatorMetric: String
    let heapBeforeSnapshotBytes: UInt64
    let heapWithSnapshotBytes: UInt64
    let heapAfterPublicationBytes: UInt64
    let heapAfterSnapshotReleaseBytes: UInt64
    let snapshotCreationDeltaBytes: Int64
    let liveSnapshotAndPublicationDeltaBytes: Int64
    let snapshotReleaseDeltaBytes: Int64
    let remainingPublicationDeltaBytes: Int64
}

@main
struct PresenceSnapshotBenchmark {
    @MainActor
    static func main() throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 4, let workload = Workload.cases[arguments[1]],
              let iterations = Int(arguments[2]), iterations > 0,
              let seed = UInt64(arguments[3]) else {
            fatalError("Usage: benchmark CASE ITERATIONS SEED")
        }
        let fixture = makeFixture(workload, seed: seed)
        for _ in 0..<2 { _ = snapshotCycle(fixture) }
        var checksum: UInt64 = 0
        let startCPU = presence_cpu_nanoseconds()
        let startWall = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<iterations { checksum &+= snapshotCycle(fixture) }
        let wall = DispatchTime.now().uptimeNanoseconds - startWall
        let cpu = presence_cpu_nanoseconds() - startCPU

        let before = presence_heap_bytes()
        var snapshot: [String: Bool]? = fixture.scanner.snapshot(in: fixture.root)
        let live = withExtendedLifetime(snapshot) { presence_heap_bytes() }
        // This models the first result published while a resumable cursor still
        // owns its cache. Source capacity was reserved for this one new key.
        fixture.scanner.publish(fixture.root, value: true)
        let published = withExtendedLifetime(snapshot) { presence_heap_bytes() }
        let entries = snapshot!.count
        let capacity = snapshot!.capacity
        let receipt = verify(snapshot!, fixture: fixture)
        precondition(checksum == UInt64(entries) * UInt64(iterations))
        snapshot = nil
        let released = presence_heap_bytes()
        let result = Measurement(
            workload: arguments[1], seed: seed, iterations: iterations,
            sourceResults: workload.total, reachableResults: workload.local,
            snapshotEntries: entries, snapshotCapacity: capacity,
            reachableLookupReceipt: receipt, snapshotChecksum: checksum,
            wallNanoseconds: wall, cpuNanoseconds: cpu,
            allocatorMetric: String(cString: presence_heap_metric()),
            heapBeforeSnapshotBytes: before, heapWithSnapshotBytes: live,
            heapAfterPublicationBytes: published, heapAfterSnapshotReleaseBytes: released,
            snapshotCreationDeltaBytes: Int64(live) - Int64(before),
            liveSnapshotAndPublicationDeltaBytes: Int64(published) - Int64(before),
            snapshotReleaseDeltaBytes: Int64(published) - Int64(released),
            remainingPublicationDeltaBytes: Int64(released) - Int64(before))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        print(String(decoding: try encoder.encode(result), as: UTF8.self))
        withExtendedLifetime(fixture) {}
    }
}
