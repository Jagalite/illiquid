import Dispatch
import Foundation

// Compile this unchanged harness with the exact production observation metrics
// region. No replacement ledger or benchmark-only storage enters timed work.
private enum Scenario: String, CaseIterable {
    case steady1 = "steady-1", steady4 = "steady-4", steady16 = "steady-16"
    case batch16 = "batch-16", retained64 = "retained-64"
    case snapshotOnly = "snapshot-only", control

    var batchSize: Int {
        switch self {
        case .steady1: 1
        case .steady4, .retained64: 4
        default: 16
        }
    }
    var publishes: Bool { self != .batch16 && self != .snapshotOnly && self != .control }
    var unit: String {
        self == .snapshotOnly ? "snapshot_reads" : self == .control ? "control_iterations" : "requests"
    }
}

private let sources = RuntimeObservationSource.allCases
private let checksumSeed: UInt64 = 0xcbf29ce484222325

// A deterministic workload, not a measured source-frequency distribution:
// 126 audio, 95 video, 31 clock, and one of each other source per 256 requests.
private func sourceIndex(_ index: Int) -> Int {
    switch index & 255 {
    case 0: 3
    case 1: 4
    case 2: 5
    case 3: 6
    default: index & 7 == 0 ? 0 : index & 1 == 0 ? 1 : 2
    }
}

private func requestTime(_ index: Int) -> UInt64 { 1_000_000 + UInt64(index) * 1_000 }
private func fold(_ checksum: UInt64, _ value: UInt64) -> UInt64 {
    (checksum ^ value) &* 0x100000001b3
}

// Read the previous publication AFTER mutating the ledger. The dictionary
// baseline must preserve its backing storage while the next request arrives,
// just as NativePlaybackRuntime.lastObservationMetrics does. Reading one source
// and one scalar keeps the lifetime check small; full validation is untimed.
@inline(never)
private func readPublished(_ snapshot: RuntimeObservationMetricsSnapshot, ordinal: Int) -> UInt64 {
    UInt64(snapshot.requestsBySource[.subtitlePacket] ?? 0)
        &+ UInt64(snapshot.deliveredObservations) &* 257 &+ UInt64(ordinal)
}

@inline(never)
private func controlValue(_ ordinal: Int) -> UInt64 { UInt64(ordinal) &* 257 &+ 1 }

private struct Result {
    var final: RuntimeObservationMetricsSnapshot
    var published: RuntimeObservationMetricsSnapshot
    var retained: [RuntimeObservationMetricsSnapshot]
    var checksum: UInt64
    var snapshotReads: Int
}

@inline(never)
private func run(_ scenario: Scenario, iterations: Int) -> Result {
    var ledger = RuntimeObservationMetricsLedger()
    var published = RuntimeObservationMetricsSnapshot()
    var retained = scenario == .retained64
        ? Array(repeating: RuntimeObservationMetricsSnapshot(), count: 64) : []
    var checksum = checksumSeed
    var snapshotReads = 0

    if scenario == .control {
        for index in 0..<iterations { checksum = fold(checksum, controlValue(index)) }
    } else if scenario == .snapshotOnly {
        for index in sources.indices {
            ledger.recordRequest(.init(source: sources[index], urgency: index >= 4 ? .urgent : .routine),
                                 at: requestTime(index), scheduled: index == 0)
        }
        ledger.recordDelivery(at: requestTime(6) + 250, isFollowUp: false)
        for index in 0..<iterations {
            checksum = fold(checksum, readPublished(ledger.snapshot, ordinal: index))
            snapshotReads += 1
        }
    } else {
        var start = 0
        var delivery = 0
        while start < iterations {
            let end = min(iterations, start + scenario.batchSize)
            for index in start..<end {
                let source = sourceIndex(index)
                ledger.recordRequest(.init(source: sources[source], urgency: source >= 4 ? .urgent : .routine),
                                     at: requestTime(index), scheduled: index == start)
            }
            if scenario.publishes {
                checksum = fold(checksum, readPublished(published, ordinal: delivery))
                snapshotReads += 1
            }
            if scenario == .retained64 {
                checksum = fold(checksum, readPublished(retained[delivery & 63], ordinal: delivery))
                snapshotReads += 1
            }
            ledger.recordDelivery(at: requestTime(end - 1) + 250, isFollowUp: delivery & 15 == 15)
            // Replacing before recordRequest would incorrectly benchmark only
            // unshared dictionary mutations. Replacement happens after delivery.
            if scenario.publishes { published = ledger.snapshot }
            if scenario == .retained64 { retained[delivery & 63] = published }
            start = end
            delivery += 1
        }
    }
    return Result(final: ledger.snapshot, published: published, retained: retained,
                  checksum: checksum, snapshotReads: snapshotReads)
}

// Independent array/count arithmetic oracle. It does not invoke production
// recordRequest, recordDelivery, totalRequests, or counter subscripts.
private struct ExpectedSnapshot {
    var counts = Array(repeating: 0, count: 7)
    var scheduled = 0, coalesced = 0, delivered = 0, followUps = 0
    var maximumDelay: UInt64 = 0, maximumUrgentDelay: UInt64 = 0

    func read(_ ordinal: Int) -> UInt64 {
        UInt64(counts[3]) &+ UInt64(delivered) &* 257 &+ UInt64(ordinal)
    }
}

private struct ExpectedResult {
    var final = ExpectedSnapshot(), published = ExpectedSnapshot()
    var retained: [ExpectedSnapshot] = []
    var checksum = checksumSeed
    var snapshotReads = 0
}

private func expected(_ scenario: Scenario, iterations: Int) -> ExpectedResult {
    var result = ExpectedResult()
    if scenario == .control {
        for index in 0..<iterations {
            result.checksum = fold(result.checksum, UInt64(index) &* 257 &+ 1)
        }
        return result
    }
    if scenario == .snapshotOnly {
        result.final.counts = Array(repeating: 1, count: 7)
        result.final.scheduled = 1
        result.final.coalesced = 6
        result.final.delivered = 1
        result.final.maximumDelay = 6_250
        result.final.maximumUrgentDelay = 2_250
        for index in 0..<iterations {
            result.checksum = fold(result.checksum, result.final.read(index))
        }
        result.snapshotReads = iterations
        return result
    }
    if scenario == .retained64 {
        result.retained = Array(repeating: ExpectedSnapshot(), count: 64)
    }
    var start = 0
    var delivery = 0
    while start < iterations {
        let end = min(iterations, start + scenario.batchSize)
        var firstUrgent: Int?
        for index in start..<end {
            let source = sourceIndex(index)
            result.final.counts[source] += 1
            if source >= 4, firstUrgent == nil { firstUrgent = index }
        }
        result.final.scheduled += 1
        result.final.coalesced += end - start - 1
        if scenario.publishes {
            result.checksum = fold(result.checksum, result.published.read(delivery))
            result.snapshotReads += 1
        }
        if scenario == .retained64 {
            result.checksum = fold(result.checksum, result.retained[delivery & 63].read(delivery))
            result.snapshotReads += 1
        }
        result.final.delivered += 1
        if delivery & 15 == 15 { result.final.followUps += 1 }
        result.final.maximumDelay = max(result.final.maximumDelay, UInt64(end - start - 1) * 1_000 + 250)
        if let firstUrgent {
            result.final.maximumUrgentDelay = max(result.final.maximumUrgentDelay,
                                                  UInt64(end - 1 - firstUrgent) * 1_000 + 250)
        }
        if scenario.publishes { result.published = result.final }
        if scenario == .retained64 { result.retained[delivery & 63] = result.published }
        start = end
        delivery += 1
    }
    return result
}

private func check(_ actual: RuntimeObservationMetricsSnapshot, _ expected: ExpectedSnapshot) {
    for index in sources.indices {
        let count: Int? = expected.counts[index] == 0 ? nil : expected.counts[index]
        precondition(actual.requestsBySource[sources[index]] == count, "Source count/presence differs")
    }
    precondition(actual.totalRequests == expected.counts.reduce(0, +), "Total differs")
    precondition(actual.scheduledDeliveries == expected.scheduled, "Scheduled differs")
    precondition(actual.coalescedRequests == expected.coalesced, "Coalesced differs")
    precondition(actual.deliveredObservations == expected.delivered, "Deliveries differ")
    precondition(actual.followUpDeliveries == expected.followUps, "Follow-ups differ")
    precondition(actual.maximumDelayNanoseconds == expected.maximumDelay, "Delay differs")
    precondition(actual.maximumUrgentDelayNanoseconds == expected.maximumUrgentDelay, "Urgent delay differs")
}

private func validate(_ actual: Result, _ expected: ExpectedResult) -> Int {
    precondition(actual.checksum == expected.checksum, "Published snapshot checksum differs")
    precondition(actual.snapshotReads == expected.snapshotReads, "Snapshot read count differs")
    precondition(actual.retained.count == expected.retained.count)
    check(actual.final, expected.final)
    check(actual.published, expected.published)
    for index in actual.retained.indices { check(actual.retained[index], expected.retained[index]) }
    return 2 + actual.retained.count
}

// The final receipt consumes every source and scalar after stopping the timer.
private func fullChecksum(_ result: Result) -> UInt64 {
    var checksum = result.checksum
    for source in sources {
        checksum = fold(checksum, UInt64(result.final.requestsBySource[source] ?? 0))
    }
    for value in [result.final.totalRequests, result.final.scheduledDeliveries,
                  result.final.coalescedRequests, result.final.deliveredObservations,
                  result.final.followUpDeliveries] {
        checksum = fold(checksum, UInt64(value))
    }
    checksum = fold(checksum, result.final.maximumDelayNanoseconds)
    return fold(checksum, result.final.maximumUrgentDelayNanoseconds)
}

@main
private struct ObservationMetricsBenchmark {
    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments == ["--list"] {
            print(Scenario.allCases.map(\.rawValue).joined(separator: "\n"))
            return
        }
        var name = "steady-4"
        var iterations = 200_000
        if arguments.count == 2, !arguments[0].hasPrefix("--") {
            name = arguments[0]
            iterations = Int(arguments[1]) ?? 0
        } else {
            var index = 0
            while index < arguments.count {
                guard index + 1 < arguments.count else { throw usage() }
                switch arguments[index] {
                case "--scenario": name = arguments[index + 1]
                case "--iterations": iterations = Int(arguments[index + 1]) ?? 0
                default: throw usage()
                }
                index += 2
            }
        }
        guard let scenario = Scenario(rawValue: name), (1...100_000_000).contains(iterations) else {
            throw usage()
        }
        precondition(sources.count == 7, "Update the fixture when observation sources change")
        let warmupIterations = min(iterations, 1_024)
        let warmup = run(scenario, iterations: warmupIterations)
        _ = validate(warmup, expected(scenario, iterations: warmupIterations))
        let oracle = expected(scenario, iterations: iterations)
        let started = DispatchTime.now().uptimeNanoseconds
        let result = run(scenario, iterations: iterations)
        let elapsed = DispatchTime.now().uptimeNanoseconds - started
        let checked = validate(result, oracle)
        let record: [String: Any] = [
            "scenario": scenario.rawValue, "operations": iterations, "operation_unit": scenario.unit,
            "elapsed_ns": elapsed, "checksum": String(fullChecksum(result), radix: 16),
            "snapshot_checksum_reads": result.snapshotReads, "snapshots_checked": checked,
            "snapshot_size": MemoryLayout<RuntimeObservationMetricsSnapshot>.size,
            "snapshot_stride": MemoryLayout<RuntimeObservationMetricsSnapshot>.stride,
            "ledger_size": MemoryLayout<RuntimeObservationMetricsLedger>.size,
            "ledger_stride": MemoryLayout<RuntimeObservationMetricsLedger>.stride,
            "warmup_operations": warmupIterations,
            "requests": result.final.totalRequests, "deliveries": result.final.deliveredObservations,
        ]
        let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }

    private static func usage() -> NSError {
        NSError(domain: "ObservationMetricsBenchmark", code: 1, userInfo: [
            NSLocalizedDescriptionKey:
                "Usage: benchmark --scenario <name> --iterations <1...100000000>; benchmark --list",
        ])
    }
}
