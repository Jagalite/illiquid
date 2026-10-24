import CSourcePresenceHeap
import Dispatch
import Foundation

// SnapshotSubject embeds the scanner's actual snapshot-construction block.
// Summary is copied verbatim from SourceMediaPresenceCursor, and the candidate
// helper is an unchanged copy of its complete production file. See run.py and
// each run's sources/ and manifest.json for the exact compilation inputs.

private struct Fixture {
    let subject: SnapshotSubject
    let folders: Int
    let relevant: Int
    let scenario: String
    let root: String

    init(folders: Int, scenario: String) {
        precondition(folders > 0)
        self.folders = folders
        self.scenario = scenario
        switch scenario {
        case "empty": relevant = 0; root = "/Library/Repair"
        case "narrow8": relevant = min(8, folders); root = "/Library/Repair"
        case "narrow256": relevant = min(256, folders); root = "/Library/Repair"
        case "library": relevant = folders; root = "/Library"
        case "root": relevant = folders; root = "/"
        default: preconditionFailure("Unknown scenario: \(scenario)")
        }
        var results: [String: Bool] = [:]
        var summaries: [String: SourceMediaPresenceCursor.Summary] = [:]
        results.reserveCapacity(folders)
        summaries.reserveCapacity(folders)
        for index in 0..<folders {
            let path = Self.path(index, relevant: relevant)
            results[path] = Self.value(index)
            // Exercise missing, incomplete and unreadable summaries as well as
            // reusable true AND false presence results in every fixture.
            if !index.isMultiple(of: 17) {
                summaries[path] = .init(
                    hasDirectMedia: Self.value(index), children: [],
                    isComplete: !index.isMultiple(of: 7),
                    isReadable: !index.isMultiple(of: 13)
                )
            }
        }
        subject = SnapshotSubject(results: results, summaries: summaries)
    }

    private static func path(_ index: Int, relevant: Int) -> String {
        // Prefix collisions are deliberately outside the repaired subtree.
        let parent = index < relevant ? "/Library/Repair"
            : (index.isMultiple(of: 11) ? "/Library/Repair-extra" : "/Library/Other")
        return "\(parent)/Series-\(index)/Season"
    }

    private static func value(_ index: Int) -> Bool { !index.isMultiple(of: 3) }
    private static func eligible(_ index: Int) -> Bool {
        !index.isMultiple(of: 17) && !index.isMultiple(of: 7) && !index.isMultiple(of: 13)
    }

    // This oracle uses fixture membership and integer eligibility rules, not
    // the production containment predicate or its summaries lookup closure.
    func verify(_ snapshot: [String: Bool]) -> Verification {
        var count = 0, trueCount = 0, falseCount = 0
        var relevantCount = 0, relevantTrue = 0, relevantFalse = 0
        var digest: UInt64 = 14_695_981_039_346_656_037
        for index in 0..<folders {
            let key = Self.path(index, relevant: relevant)
            let usable = Self.eligible(index)
            let isRelevant = index < relevant
            let included = usable && (snapshotVariant == "baseline" || isRelevant)
            if included {
                precondition(snapshot[key] == Self.value(index), "Wrong result for \(key)")
                count += 1
                if Self.value(index) { trueCount += 1 } else { falseCount += 1 }
            } else {
                precondition(snapshot[key] == nil, "Unexpected result for \(key)")
            }
            if usable && isRelevant {
                relevantCount += 1
                if Self.value(index) { relevantTrue += 1 } else { relevantFalse += 1 }
                for byte in key.utf8 { digest = (digest ^ UInt64(byte)) &* 1_099_511_628_211 }
                digest = (digest ^ (Self.value(index) ? 1 : 0)) &* 1_099_511_628_211
            }
        }
        precondition(snapshot.count == count, "Extra entries escaped complete fixture verification")
        return Verification(snapshotCount: count, snapshotTrue: trueCount, snapshotFalse: falseCount,
                            relevantCount: relevantCount, relevantTrue: relevantTrue,
                            relevantFalse: relevantFalse, relevantDigest: String(digest, radix: 16))
    }
}

private struct Verification: Codable {
    let snapshotCount: Int
    let snapshotTrue: Int
    let snapshotFalse: Int
    let relevantCount: Int
    let relevantTrue: Int
    let relevantFalse: Int
    let relevantDigest: String
}

private struct Observation: Codable {
    let variant: String
    let mode: String
    let scenario: String
    let folders: Int
    let relevantFixtureFolders: Int
    let root: String
    let verification: Verification
    let sourceResultsCount: Int
    let sourceSummariesCount: Int
    let snapshotCapacity: Int
    let heapMetric: String
    let heapBeforeBytes: UInt64?
    let heapWithSnapshotBytes: UInt64?
    let retainedAllocatorDeltaBytes: Int64?
    let iterations: Int
    let constructionWallNanoseconds: UInt64?
    let constructionCPUNanoseconds: UInt64?
    let consumedCountAndCapacity: UInt64?
}

@inline(never)
private func warmup() {
    let small = Fixture(folders: 16, scenario: "narrow8")
    let snapshot = small.subject.snapshot(under: small.root)
    source_presence_consume(UInt64(snapshot.count + snapshot.capacity))
    _ = source_presence_heap_bytes()
    _ = source_presence_cpu_nanoseconds()
    _ = DispatchTime.now().uptimeNanoseconds
    withExtendedLifetime((small, snapshot)) {}
}

@inline(never)
private func memory(_ fixture: Fixture, heapMetric: String) -> Observation {
    let before = source_presence_heap_bytes()
    let snapshot = fixture.subject.snapshot(under: fixture.root)
    let retained = source_presence_heap_bytes()
    // Verification and JSON encoding occur strictly AFTER the second reading.
    let verification = fixture.verify(snapshot)
    let observation = Observation(
        variant: snapshotVariant, mode: "memory", scenario: fixture.scenario,
        folders: fixture.folders, relevantFixtureFolders: fixture.relevant, root: fixture.root,
        verification: verification, sourceResultsCount: fixture.subject.results.count,
        sourceSummariesCount: fixture.subject.summaries.count, snapshotCapacity: snapshot.capacity,
        heapMetric: heapMetric, heapBeforeBytes: before, heapWithSnapshotBytes: retained,
        retainedAllocatorDeltaBytes: Int64(retained) - Int64(before), iterations: 1,
        constructionWallNanoseconds: nil, constructionCPUNanoseconds: nil,
        consumedCountAndCapacity: nil
    )
    withExtendedLifetime((fixture, snapshot)) {}
    return observation
}

@inline(never)
private func timed(_ fixture: Fixture, iterations: Int, heapMetric: String) -> Observation {
    precondition(iterations > 0)
    // Prime this fixture's collection paths before timing. Memory measurements
    // use independent processes and do not run this loop.
    for _ in 0..<3 {
        let snapshot = fixture.subject.snapshot(under: fixture.root)
        source_presence_consume(UInt64(snapshot.count + snapshot.capacity))
        withExtendedLifetime(snapshot) {}
    }
    var wall: UInt64 = 0, cpu: UInt64 = 0, consumed: UInt64 = 0
    for _ in 0..<iterations {
        let wallStart = DispatchTime.now().uptimeNanoseconds
        let cpuStart = source_presence_cpu_nanoseconds()
        let snapshot = fixture.subject.snapshot(under: fixture.root)
        let cpuEnd = source_presence_cpu_nanoseconds()
        let wallEnd = DispatchTime.now().uptimeNanoseconds
        cpu &+= cpuEnd - cpuStart
        wall &+= wallEnd - wallStart
        consumed &+= UInt64(snapshot.count + snapshot.capacity)
        // Lifetime extends beyond both clocks. Result destruction, fixture work,
        // semantic verification and encoding are outside the timed brackets.
        withExtendedLifetime(snapshot) {}
    }
    source_presence_consume(consumed)
    let finalSnapshot = fixture.subject.snapshot(under: fixture.root)
    let verification = fixture.verify(finalSnapshot)
    let observation = Observation(
        variant: snapshotVariant, mode: "timing", scenario: fixture.scenario,
        folders: fixture.folders, relevantFixtureFolders: fixture.relevant, root: fixture.root,
        verification: verification, sourceResultsCount: fixture.subject.results.count,
        sourceSummariesCount: fixture.subject.summaries.count, snapshotCapacity: finalSnapshot.capacity,
        heapMetric: heapMetric, heapBeforeBytes: nil, heapWithSnapshotBytes: nil,
        retainedAllocatorDeltaBytes: nil, iterations: iterations,
        constructionWallNanoseconds: wall, constructionCPUNanoseconds: cpu,
        consumedCountAndCapacity: consumed
    )
    withExtendedLifetime((fixture, finalSnapshot)) {}
    return observation
}

@main
private struct Main {
    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        precondition(arguments.count == 4, "Usage: SnapshotBenchmark memory|timing scenario folders iterations")
        let mode = arguments[0], scenario = arguments[1]
        let folders = Int(arguments[2])!, iterations = Int(arguments[3])!
        let metric = String(cString: source_presence_heap_metric())
        precondition(metric != "unsupported", "No supported retained allocator metric on this platform")
        warmup()
        let fixture = Fixture(folders: folders, scenario: scenario)
        let result: Observation
        switch mode {
        case "memory": result = memory(fixture, heapMetric: metric)
        case "timing": result = timed(fixture, iterations: iterations, heapMetric: metric)
        default: preconditionFailure("Unknown mode")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        print(String(decoding: try encoder.encode(result), as: UTF8.self))
        withExtendedLifetime(fixture) {}
    }
}
