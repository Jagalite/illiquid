import Foundation
import CReadAheadMetrics
@testable import IlliquidNativePlayback

private struct ReaderObservation: Sendable {
    let admitted: Bool
    let cpu: Int64
    let voluntary: Int64?
    let involuntary: Int64?
}

private final class ReaderResult: @unchecked Sendable {
    private let lock = NSLock()
    private var observation: ReaderObservation?

    func publish(_ value: ReaderObservation) {
        lock.lock()
        observation = value
        lock.unlock()
    }

    func read() -> ReaderObservation {
        lock.lock()
        defer { lock.unlock() }
        return observation!
    }
}

private func check(_ metrics: ReadAheadMetrics) {
    precondition(metrics.error_code == 0, "Metrics query failed: \(metrics.error_code)")
}

@main
private struct ReadAheadBenchmark {
    static func main() throws {
        let arguments = CommandLine.arguments
        precondition(arguments.count == 4, "Usage: benchmark SCENARIO RATE DURATION")
        let scenario = arguments[1]
        precondition(["eof-update", "eof-idle", "timed-update"].contains(scenario))
        guard let rate = Int(arguments[2]), (1...1_000).contains(rate),
              let duration = Double(arguments[3]), duration.isFinite,
              duration > 0, duration <= 300 else {
            fatalError("Invalid rate or duration")
        }
        let ticks = max(1, Int(ceil(Double(rate) * duration)))
        let finalPosition = Double(ticks) / Double(rate)
        let timed = scenario == "timed-update"
        let gate = MediaReadAheadGate(lookahead: 0)
        let result = ReaderResult()
        let completion = DispatchSemaphore(value: 0)

        // Both snapshots execute synchronously on this one physical thread.
        let worker = Thread {
            let before = read_ahead_thread_metrics()
            check(before)
            let admitted = gate.wait(until: timed ? finalPosition : nil, generation: 0)
            let after = read_ahead_thread_metrics()
            check(after)
            precondition(before.switches_available == after.switches_available)
            result.publish(ReaderObservation(
                admitted: admitted,
                cpu: after.cpu_nanoseconds - before.cpu_nanoseconds,
                voluntary: after.switches_available == 1
                    ? after.voluntary_switches - before.voluntary_switches : nil,
                involuntary: after.switches_available == 1
                    ? after.involuntary_switches - before.involuntary_switches : nil
            ))
            completion.signal()
        }
        worker.start()
        precondition(gate.waitForBlockedReader(timeout: 5), "Reader did not block")

        let processBefore = read_ahead_process_metrics()
        check(processBefore)
        let start = read_ahead_monotonic_nanoseconds()
        precondition(start >= 0)
        var oversleptTicks = 0
        for tick in 1...ticks {
            // Absolute deadlines avoid accumulating drift across ticks.
            let deadline = start + Int64(Double(tick) * 1_000_000_000 / Double(rate))
            precondition(read_ahead_sleep_until(deadline) == 0, "Pacing failed")
            let now = read_ahead_monotonic_nanoseconds()
            precondition(now >= 0)
            if now - deadline > 1_000_000_000 / Int64(rate) { oversleptTicks += 1 }
            if scenario != "eof-idle" {
                gate.update(position: Double(tick) / Double(rate))
            }
        }
        // A timed reader must return due to the final update, before close.
        if !timed { gate.close() }
        guard completion.wait(timeout: .now() + 5) == .success else {
            gate.close()
            fatalError("Reader did not complete")
        }
        let end = read_ahead_monotonic_nanoseconds()
        precondition(end >= start)
        let processAfter = read_ahead_process_metrics()
        check(processAfter)
        let reader = result.read()
        gate.close()
        precondition(reader.admitted == timed)

        var output: [String: Any] = [
            "scenario": scenario,
            "rate": rate,
            "requested_duration_seconds": duration,
            "ticks": ticks,
            "final_position": gate.currentPosition,
            "admitted": reader.admitted,
            "elapsed_nanoseconds": end - start,
            "overslept_ticks": oversleptTicks,
            "reader_cpu_nanoseconds": reader.cpu,
            "process_cpu_nanoseconds":
                processAfter.cpu_nanoseconds - processBefore.cpu_nanoseconds,
            "process_voluntary_switches":
                processAfter.voluntary_switches - processBefore.voluntary_switches,
            "process_involuntary_switches":
                processAfter.involuntary_switches - processBefore.involuntary_switches
        ]
        if let voluntary = reader.voluntary, let involuntary = reader.involuntary {
            output["reader_voluntary_switches"] = voluntary
            output["reader_involuntary_switches"] = involuntary
        } else {
            output["reader_voluntary_switches"] = NSNull()
            output["reader_involuntary_switches"] = NSNull()
        }
        let data = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
