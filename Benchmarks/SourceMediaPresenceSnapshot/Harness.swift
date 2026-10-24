import CMemoryProbe
import Foundation
@testable import IlliquidApp

private struct Workload {
    enum Summaries {
        case complete
        case mixed
        case incomplete
    }

    let inputCount: Int
    let descendantCount: Int
    let root: String
    let summaries: Summaries

    init(name: String) throws {
        switch name {
        case "empty":
            self.init(0, descendants: 0)
        case "narrow-1000":
            self.init(1_000, descendants: 16)
        case "narrow-10000":
            self.init(10_000, descendants: 32)
        case "narrow-100000":
            self.init(100_000, descendants: 32)
        case "mixed-100000":
            self.init(100_000, descendants: 32, summaries: .mixed)
        case "whole-root-10000":
            self.init(10_000, descendants: 10_000)
        case "filesystem-root-10000":
            self.init(10_000, descendants: 10_000, root: "/")
        case "no-reuse-10000":
            self.init(10_000, descendants: 10_000, summaries: .incomplete)
        default:
            throw HarnessError.invalidArguments("Unknown case: \(name)")
        }
    }

    private init(_ inputCount: Int, descendants: Int,
                 root: String = "/Media/Target", summaries: Summaries = .complete) {
        self.inputCount = inputCount
        descendantCount = descendants
        self.root = root
        self.summaries = summaries
    }
}

private enum HarnessError: Error {
    case invalidArguments(String)
    case unexpectedOutput(String)
}

private struct MemorySample {
    let heap: UInt64
    let rss: UInt64

    init() {
        heap = memory_probe_heap_bytes()
        rss = memory_probe_rss_bytes()
    }
}

// Populate the caller's dictionaries in place. A fixture object retaining a
// second copy of results would force an unrelated copy on every publication.
private func prepare(
    _ workload: Workload,
    results: inout [String: Bool],
    summaries: inout [String: SourceMediaPresenceCursor.Summary]
) {
    results.reserveCapacity(workload.inputCount)
    summaries.reserveCapacity(workload.inputCount)
    let prefix = workload.root == "/" ? "/" : workload.root + "/"
    for index in 0..<workload.inputCount {
        let path = index < workload.descendantCount
            ? prefix + "Folder-\(index)"
            : "/Media/Unrelated/Folder-\(index)"
        let complete: Bool
        let readable: Bool
        switch workload.summaries {
        case .complete:
            complete = true
            readable = true
        case .mixed:
            complete = index % 10 != 4
            readable = index % 10 != 9
        case .incomplete:
            complete = false
            readable = true
        }
        results[path] = index % 7 != 0
        summaries[path] = .init(hasDirectMedia: index % 7 != 0, children: [],
                                isComplete: complete, isReadable: readable)
    }
    // invalidate(paths:) removes the changed root's result and summary. The
    // measured publication inserts it after its children have been repaired.
    precondition(results[workload.root] == nil && summaries[workload.root] == nil)
}

@inline(never)
private func baselineSnapshot(
    results: [String: Bool],
    summaries: [String: SourceMediaPresenceCursor.Summary]
) -> [String: Bool] {
    // BEGIN BASELINE FILTER
    return results.filter { entry in
        summaries[entry.key]?.isComplete == true
            && summaries[entry.key]?.isReadable == true
    }
    // END BASELINE FILTER
}

// Dictionary iteration order is process-randomized. Sum per-entry hashes to
// compare complete scoped key/value sets without allocating sorted key arrays.
private func scopedReceipt(_ snapshot: [String: Bool], root: String) -> (Int, UInt64) {
    let prefix = root == "/" ? "/" : root + "/"
    var count = 0
    var checksum: UInt64 = 0
    for (path, value) in snapshot where path == root || path.hasPrefix(prefix) {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in path.utf8 {
            hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }
        hash = (hash ^ (value ? 1 : 0)) &* 1_099_511_628_211
        count += 1
        checksum &+= hash
    }
    return (count, checksum)
}

private func run(variant: String, caseName: String, iterations: Int) throws -> [String: Any] {
    let workload = try Workload(name: caseName)
    var results: [String: Bool] = [:]
    var summaries: [String: SourceMediaPresenceCursor.Summary] = [:]
    prepare(workload, results: &results, summaries: &summaries)

    // Initialize clock/probe paths before the first sample. No snapshot or
    // publication is warmed up: the first iteration is the memory experiment.
    _ = DispatchTime.now().uptimeNanoseconds
    _ = MemorySample()
    _ = memory_probe_peak_rss_bytes()

    var firstBefore: MemorySample?
    var firstSnapshot: MemorySample?
    var firstPublication: MemorySample?
    var firstCount = 0
    var firstCapacity = 0
    var expectedReceipt: (Int, UInt64)?
    var snapshotNanoseconds: UInt64 = 0
    var publicationNanoseconds: UInt64 = 0

    return try withExtendedLifetime(summaries) {
        for iteration in 0..<iterations {
            // Later timing iterations reuse the mutable result dictionary.
            // Root removal and receipt validation are outside both timers.
            results.removeValue(forKey: workload.root)
            let before = MemorySample()
            let snapshotStart = DispatchTime.now().uptimeNanoseconds
            let snapshot = variant == "baseline"
                ? baselineSnapshot(results: results, summaries: summaries)
                : SourceMediaPresenceCursor.reusableResults(
                    for: workload.root, results: results, summaries: summaries)
            snapshotNanoseconds &+= DispatchTime.now().uptimeNanoseconds - snapshotStart
            let afterSnapshot = MemorySample()

            let afterPublication = withExtendedLifetime(snapshot) {
                let publicationStart = DispatchTime.now().uptimeNanoseconds
                results[workload.root] = true
                publicationNanoseconds &+= DispatchTime.now().uptimeNanoseconds - publicationStart
                // Extend the mutated dictionary only after publication, so the
                // probe itself does not force an extra copy-on-write owner.
                return withExtendedLifetime(results) { MemorySample() }
            }
            guard results[workload.root] == true,
                  results.count == workload.inputCount + 1,
                  snapshot[workload.root] == nil else {
                throw HarnessError.unexpectedOutput("Snapshot/publication value semantics changed")
            }
            let receipt = scopedReceipt(snapshot, root: workload.root)
            if let expectedReceipt {
                guard receipt == expectedReceipt else {
                    throw HarnessError.unexpectedOutput("Scoped output changed between iterations")
                }
            } else {
                expectedReceipt = receipt
            }
            if iteration == 0 {
                firstBefore = before
                firstSnapshot = afterSnapshot
                firstPublication = afterPublication
                firstCount = snapshot.count
                firstCapacity = snapshot.capacity
            }
        }

        let before = firstBefore!
        let snapshot = firstSnapshot!
        let publication = firstPublication!
        let receipt = expectedReceipt!
        return [
            "case": caseName,
            "variant": variant,
            "input_count": workload.inputCount,
            "requested_descendant_count": workload.descendantCount,
            "snapshot_count": firstCount,
            "snapshot_capacity": firstCapacity,
            "scoped_count": receipt.0,
            "scoped_checksum": String(receipt.1),
            "heap_before": before.heap,
            "heap_after_snapshot": snapshot.heap,
            "heap_after_publication": publication.heap,
            "rss_before": before.rss,
            "rss_after_snapshot": snapshot.rss,
            "rss_after_publication": publication.rss,
            "peak_rss": memory_probe_peak_rss_bytes(),
            "snapshot_nanoseconds": snapshotNanoseconds,
            "publication_nanoseconds": publicationNanoseconds,
            "iterations": iterations,
            "memory_sample_iteration": 1,
        ]
    }
}

let arguments = CommandLine.arguments
guard arguments.count == 4,
      ["baseline", "candidate"].contains(arguments[1]),
      let iterations = Int(arguments[3]), iterations > 0 else {
    throw HarnessError.invalidArguments("Usage: harness <baseline|candidate> <case-name> <iterations>")
}
let output = try run(variant: arguments[1], caseName: arguments[2], iterations: iterations)
let encoded = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
FileHandle.standardOutput.write(encoded)
FileHandle.standardOutput.write(Data([0x0A]))
