import Dispatch
import Foundation
#if os(Linux)
import Glibc
#else
import Darwin
#endif

private enum BenchmarkError: Error, CustomStringConvertible {
    case invalid(String)
    var description: String {
        switch self { case .invalid(let text): return text }
    }
}

private enum Scenario: String, Sendable {
    case eof, future, active, idle
    case multiEOF = "multi-eof"
}

private struct Configuration: Sendable {
    let scenario: Scenario
    let updates: Int
    let intervalMicroseconds: UInt64
    let readers: Int
    let generation = 7
    let lookahead: Double = 30
    let positionStep: Double = 1.0 / 120.0
    let futureTimestamp: Double = 1_200

    init(arguments: [String]) throws {
        var options: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let key = arguments[index]
            guard ["--scenario", "--updates", "--interval-us", "--readers"].contains(key),
                  index + 1 < arguments.count, options[key] == nil else {
                throw BenchmarkError.invalid(
                    "usage: Driver --scenario eof|future|active|idle|multi-eof "
                        + "[--updates N] [--interval-us U] [--readers N]"
                )
            }
            options[key] = arguments[index + 1]
            index += 2
        }
        guard let scenario = Scenario(rawValue: options["--scenario"] ?? "eof") else {
            throw BenchmarkError.invalid("Unknown scenario")
        }
        self.scenario = scenario
        guard let updates = Int(options["--updates"] ?? (scenario == .multiEOF ? "24" : "240")),
              (1...10_000_000).contains(updates) else {
            throw BenchmarkError.invalid("updates must be in 1...10000000")
        }
        self.updates = updates
        guard let interval = UInt64(options["--interval-us"] ?? "8333"), interval <= 1_000_000 else {
            throw BenchmarkError.invalid("interval-us must be in 0...1000000")
        }
        intervalMicroseconds = interval
        let defaultReaders = scenario == .idle ? 0 : (scenario == .multiEOF ? 4 : 1)
        guard let readers = Int(options["--readers"] ?? String(defaultReaders)),
              (0...32).contains(readers),
              (scenario == .idle ? readers == 0 : readers > 0),
              (scenario != .active || readers == 1) else {
            throw BenchmarkError.invalid("idle needs zero readers; active needs one; other scenarios need 1...32")
        }
        self.readers = readers
        if scenario == .future, Double(updates) * positionStep + lookahead >= futureTimestamp {
            throw BenchmarkError.invalid("future scenario must stay strictly below its release threshold")
        }
        #if !GATE_WAKE_COUNTS
        guard readers <= 1 else {
            throw BenchmarkError.invalid("Multiple-reader setup requires the operation-count executable")
        }
        #endif
    }
}

private struct ReaderReceipt: Sendable {
    let reader: Int
    let waitReturns: Int
    let admissions: Int
    let rejections: Int
    let lastResult: Bool

    var json: [String: Any] {
        [
            "reader": reader, "wait_returns": waitReturns,
            "admissions": admissions, "rejections": rejections,
            "last_result": lastResult,
        ]
    }
}

private final class Receipts: @unchecked Sendable {
    private let lock = Foundation.NSLock()
    private var values: [ReaderReceipt] = []

    func append(_ value: ReaderReceipt) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    func snapshot() -> [ReaderReceipt] {
        lock.lock()
        defer { lock.unlock() }
        return values.sorted { $0.reader < $1.reader }
    }
}

private struct ProcessUsage {
    let cpuNanoseconds: UInt64
    let voluntaryContextSwitches: Int64
    let involuntaryContextSwitches: Int64

    static func capture() throws -> Self {
        var clock = timespec()
        guard clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &clock) == 0 else {
            throw BenchmarkError.invalid("clock_gettime failed")
        }
        var usage = rusage()
        #if os(Linux)
        let resource = RUSAGE_SELF.rawValue
        #else
        let resource = RUSAGE_SELF
        #endif
        guard getrusage(resource, &usage) == 0 else {
            throw BenchmarkError.invalid("getrusage failed")
        }
        return Self(
            cpuNanoseconds: UInt64(clock.tv_sec) * 1_000_000_000 + UInt64(clock.tv_nsec),
            voluntaryContextSwitches: Int64(usage.ru_nvcsw),
            involuntaryContextSwitches: Int64(usage.ru_nivcsw)
        )
    }
}

@main
private struct Driver {
    static func main() {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            let result: [String: Any]
            if arguments == ["--check"] {
                #if GATE_WAKE_COUNTS
                result = try qualify()
                #else
                throw BenchmarkError.invalid("--check requires the operation-count executable")
                #endif
            } else {
                let configuration = try Configuration(arguments: arguments)
                result = try run(configuration)
            }
            let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([10]))
        } catch {
            FileHandle.standardError.write(Data("MediaReadAheadGate benchmark failed: \(error)\n".utf8))
            exit(1)
        }
    }

    private static func run(_ config: Configuration) throws -> [String: Any] {
        let gate = MediaReadAheadGate(lookahead: config.lookahead)
        gate.reset(generation: config.generation, position: 0)
        let readersFinished = DispatchGroup()
        let readersStarted = DispatchSemaphore(value: 0)
        let admittedStep = DispatchSemaphore(value: 0)
        let receipts = Receipts()
        defer {
            gate.close()
            _ = readersFinished.wait(timeout: .now() + 5)
        }

        for reader in 0..<config.readers {
            readersFinished.enter()
            let thread = Thread {
                defer { readersFinished.leave() }
                readersStarted.signal()
                if config.scenario == .active {
                    var admissions = 0
                    var rejections = 0
                    var lastResult = false
                    for step in 1...config.updates {
                        lastResult = gate.wait(
                            until: config.lookahead + Double(step) * config.positionStep,
                            generation: config.generation
                        )
                        if lastResult { admissions += 1 } else { rejections += 1 }
                        admittedStep.signal()
                        if !lastResult { break }
                    }
                    receipts.append(ReaderReceipt(
                        reader: reader, waitReturns: admissions + rejections,
                        admissions: admissions, rejections: rejections, lastResult: lastResult
                    ))
                } else {
                    let result = gate.wait(
                        until: config.scenario == .future ? config.futureTimestamp : nil,
                        generation: config.generation
                    )
                    receipts.append(ReaderReceipt(
                        reader: reader, waitReturns: 1,
                        admissions: result ? 1 : 0, rejections: result ? 0 : 1,
                        lastResult: result
                    ))
                }
            }
            thread.name = "illiquid-gate-benchmark-\(reader)"
            thread.start()
        }
        for _ in 0..<config.readers {
            guard readersStarted.wait(timeout: .now() + 5) == .success else {
                throw BenchmarkError.invalid("Reader thread did not start")
            }
        }
        if config.readers > 0 {
            guard gate.waitForBlockedReader(timeout: 5) else {
                throw BenchmarkError.invalid("Reader did not block before measurement")
            }
        }

        #if GATE_WAKE_COUNTS
        // The ordinary public diagnostic only promises one blocked reader.
        // Reading the shadow condition verifies all readers reached a real
        // condition wait, without sending a synchronization broadcast.
        let setupDeadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
        while GateConditionInstrumentation.snapshot().activeReaders < config.readers {
            guard DispatchTime.now().uptimeNanoseconds < setupDeadline else {
                throw BenchmarkError.invalid("Not all readers reached the condition wait")
            }
            Thread.sleep(forTimeInterval: 0.001)
        }
        let countsBefore = GateConditionInstrumentation.snapshot()
        #endif

        let usageBefore = try ProcessUsage.capture()
        let start = DispatchTime.now().uptimeNanoseconds
        let intervalNanoseconds = config.intervalMicroseconds * 1_000
        for step in 1...config.updates {
            if intervalNanoseconds > 0 {
                sleep(until: start + UInt64(step) * intervalNanoseconds)
            }
            gate.update(position: Double(step) * config.positionStep)
            if config.scenario == .active {
                guard admittedStep.wait(timeout: .now() + 5) == .success else {
                    throw BenchmarkError.invalid("A threshold crossing did not admit its reader")
                }
            }
        }
        let end = DispatchTime.now().uptimeNanoseconds
        let usageAfter = try ProcessUsage.capture()
        #if GATE_WAKE_COUNTS
        let countsAfter = GateConditionInstrumentation.snapshot()
        #endif

        let unexpectedEarlyCompletion = config.scenario != .active && config.scenario != .idle
            && !receipts.snapshot().isEmpty
        gate.close()
        guard readersFinished.wait(timeout: .now() + 5) == .success else {
            throw BenchmarkError.invalid("Closing the gate did not release every reader")
        }
        let results = receipts.snapshot()
        let admissions = results.reduce(0) { $0 + $1.admissions }
        let rejections = results.reduce(0) { $0 + $1.rejections }
        let afterCloseAdmitted = gate.wait(until: 0, generation: config.generation)
        guard !unexpectedEarlyCompletion, results.count == config.readers,
              !afterCloseAdmitted,
              admissions == (config.scenario == .active ? config.updates : 0),
              rejections == (config.scenario == .active || config.scenario == .idle ? 0 : config.readers) else {
            throw BenchmarkError.invalid("Behavior receipt did not match the scenario's expected admissions")
        }
        let receipt: [String: Any] = [
            "final_position": gate.currentPosition,
            "completed_readers": results.count,
            "admissions": admissions, "rejections": rejections,
            "unexpected_early_completion": unexpectedEarlyCompletion,
            "after_close_admitted": afterCloseAdmitted,
            "results": results.map(\.json),
        ]
        var row: [String: Any] = [
            "scenario": config.scenario.rawValue,
            "updates": config.updates,
            "interval_us": config.intervalMicroseconds,
            "readers": config.readers,
            "elapsed_ns": end - start,
            "cpu_ns": usageAfter.cpuNanoseconds - usageBefore.cpuNanoseconds,
            "voluntary_context_switches": usageAfter.voluntaryContextSwitches - usageBefore.voluntaryContextSwitches,
            "involuntary_context_switches": usageAfter.involuntaryContextSwitches - usageBefore.involuntaryContextSwitches,
            "receipt": receipt,
            "measurement_scope": "Paced gate updates only; setup, counters, close and reader joins excluded. Process CPU includes the pacing/controller thread.",
            "interpretation": "Component experiment; counters demonstrate wake avoidance. Process CPU/context switches are scheduler-sensitive and do not establish playback CPU or battery impact.",
        ]
        #if GATE_WAKE_COUNTS
        row["instrumented"] = true
        row["counts"] = countsAfter.delta(since: countsBefore)
        row["instrumentation_note"] = "CountingCondition is compiled only in this separate executable. Use the uninstrumented executable for process CPU/context-switch comparisons."
        #else
        row["instrumented"] = false
        #endif
        return row
    }

    private static func sleep(until deadline: UInt64) {
        let now = DispatchTime.now().uptimeNanoseconds
        if now < deadline {
            Thread.sleep(forTimeInterval: Double(deadline - now) / 1_000_000_000)
        }
    }

    #if GATE_WAKE_COUNTS
    private static func waitForCondition(
        _ condition: NSCondition,
        description: String,
        _ predicate: (GateConditionCounts) -> Bool
    ) throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
        while !predicate(condition.snapshot()) {
            guard DispatchTime.now().uptimeNanoseconds < deadline else {
                throw BenchmarkError.invalid("Qualification timed out: \(description)")
            }
            Thread.sleep(forTimeInterval: 0.0005)
        }
    }

    // Counter-derived handshakes belong exclusively to this executable. They
    // establish that a thread has entered the actual condition wait, which a
    // semaphore signaled immediately before calling gate.wait cannot prove.
    private static func qualify() throws -> [String: Any] {
        var checks = 0
        var semanticReceipts: [[String: Any]] = []
        var observations: [[String: Any]] = []
        func check(_ value: Bool, _ message: String) throws {
            checks += 1
            guard value else { throw BenchmarkError.invalid("Qualification: \(message)") }
        }

        // Every diagnostic observer is already inside its timed wait before
        // the reader arrives. This specifically exercises observer notification.
        do {
            let gate = MediaReadAheadGate(lookahead: 30)
            gate.reset(generation: 7, position: 0)
            let condition = GateConditionInstrumentation.currentCondition
            let observers = DispatchGroup()
            let readerFinished = DispatchGroup()
            let observerResults = Receipts()
            let readerResults = Receipts()
            defer {
                gate.close()
                _ = observers.wait(timeout: .now() + 5)
                _ = readerFinished.wait(timeout: .now() + 5)
            }
            for observer in 0..<4 {
                observers.enter()
                Thread {
                    let result = gate.waitForBlockedReader(timeout: 5)
                    observerResults.append(.init(
                        reader: observer, waitReturns: 1, admissions: result ? 1 : 0,
                        rejections: result ? 0 : 1, lastResult: result
                    ))
                    observers.leave()
                }.start()
            }
            try waitForCondition(condition, description: "four diagnostic observers preblocked") {
                $0.activeDiagnostics == 4
            }
            readerFinished.enter()
            Thread {
                let result = gate.wait(until: 120, generation: 7)
                readerResults.append(.init(
                    reader: 0, waitReturns: 1, admissions: result ? 1 : 0,
                    rejections: result ? 0 : 1, lastResult: result
                ))
                readerFinished.leave()
            }.start()
            try check(observers.wait(timeout: .now() + 5) == .success, "preblocked diagnostic observers wake")
            try check(observerResults.snapshot().count == 4, "all diagnostic observer results recorded")
            try check(observerResults.snapshot().allSatisfy(\.lastResult), "all diagnostic observers see the blocked reader")
            try waitForCondition(condition, description: "reader remains blocked after observers return") {
                $0.activeReaders == 1 && $0.activeDiagnostics == 0
            }
            gate.close()
            try check(readerFinished.wait(timeout: .now() + 5) == .success, "diagnostic case closes its reader")
            try check(readerResults.snapshot().map(\.lastResult) == [false], "closed reader is rejected")
            semanticReceipts.append([
                "case": "observers-before-reader", "observers": 4,
                "observer_results": observerResults.snapshot().map(\.lastResult),
                "reader_results": readerResults.snapshot().map(\.lastResult),
            ])
        }

        // Distinct deadlines and EOF share one condition. Setups and each
        // subsequent crossing wait for the exact remaining blocked-reader count.
        do {
            let gate = MediaReadAheadGate(lookahead: 30)
            gate.reset(generation: 7, position: 0)
            let condition = GateConditionInstrumentation.currentCondition
            let group = DispatchGroup()
            let results = Receipts()
            let timestamps: [Double?] = [35, 40, 50, nil]
            let completions = timestamps.map { _ in DispatchSemaphore(value: 0) }
            defer {
                gate.close()
                _ = group.wait(timeout: .now() + 5)
            }
            for reader in timestamps.indices {
                group.enter()
                let timestamp = timestamps[reader]
                let completion = completions[reader]
                Thread {
                    let result = gate.wait(until: timestamp, generation: 7)
                    results.append(.init(
                        reader: reader, waitReturns: 1, admissions: result ? 1 : 0,
                        rejections: result ? 0 : 1, lastResult: result
                    ))
                    completion.signal()
                    group.leave()
                }.start()
            }
            try waitForCondition(condition, description: "all mixed-deadline readers preblocked") {
                $0.activeReaders == 4
            }
            let countsBefore = condition.snapshot()
            Thread.sleep(forTimeInterval: 0.03)
            let countsAfter = condition.snapshot()
            // Record self-generated wake cycles without treating their absence
            // as a baseline semantic requirement. The baseline is expected to
            // broadcast repeatedly here; both versions must preserve deadlines.
            observations.append([
                "case": "mixed-waiters-without-updates",
                "hold_seconds": 0.03,
                "counts": countsAfter.delta(since: countsBefore),
            ])
            try check(results.snapshot().isEmpty, "no mixed reader admitted before a deadline")
            for (reader, position) in [5.0, 10.0, 20.0].enumerated() {
                gate.update(position: position)
                try check(completions[reader].wait(timeout: .now() + 5) == .success, "deadline \(reader) admits its reader")
                try waitForCondition(condition, description: "remaining readers block after deadline \(reader)") {
                    $0.activeReaders == 3 - reader
                }
                let snapshot = results.snapshot()
                try check(snapshot.count == reader + 1, "only crossed deadlines return")
                try check(snapshot.allSatisfy(\.lastResult), "crossed deadlines preserve generation")
            }
            gate.reset(generation: 8, position: 0)
            try check(group.wait(timeout: .now() + 5) == .success, "generation reset releases EOF")
            try check(results.snapshot().map(\.lastResult) == [true, true, true, false], "mixed-reader outcomes match")
            semanticReceipts.append([
                "case": "mixed-deadlines-and-eof", "positions": [5, 10, 20],
                "results": results.snapshot().map(\.lastResult),
            ])
        }

        // The update immediately follows a same-generation backward reset. A
        // signaled reader may not reacquire the mutex and re-register between
        // those operations; every repetition must still observe current state.
        for repetition in 0..<32 {
            let gate = MediaReadAheadGate(lookahead: 30)
            gate.reset(generation: 7, position: 20)
            let condition = GateConditionInstrumentation.currentCondition
            let results = Receipts()
            let completion = DispatchGroup()
            completion.enter()
            defer {
                gate.close()
                _ = completion.wait(timeout: .now() + 5)
            }
            Thread {
                let result = gate.wait(until: 100, generation: 7)
                results.append(.init(
                    reader: 0, waitReturns: 1, admissions: result ? 1 : 0,
                    rejections: result ? 0 : 1, lastResult: result
                ))
                completion.leave()
            }.start()
            try waitForCondition(condition, description: "reset-race reader preblocked") {
                $0.activeReaders == 1
            }
            gate.reset(generation: 7, position: 0)
            gate.update(position: 70)
            try check(completion.wait(timeout: .now() + 5) == .success, "reset/update repetition \(repetition) completes")
            try check(results.snapshot().map(\.lastResult) == [true], "reset/update repetition preserves admission")
        }
        semanticReceipts.append([
            "case": "same-generation-backward-reset-immediate-crossing",
            "repetitions": 32, "all_admitted": true,
        ])
        return [
            "mode": "qualification", "instrumented": true,
            "passed": true, "checks": checks,
            "receipt": ["cases": semanticReceipts],
            "observations": observations,
            "interpretation": "Semantic receipts must match baseline and candidate. No-update wake counts are observations, not baseline correctness assertions. Handshake and hold timings are not performance evidence.",
        ]
    }
    #endif
}
