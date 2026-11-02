import Foundation
import Dispatch
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

private struct ResourceSnapshot {
    let wall: UInt64
    let cpu: Int64
    let voluntary: Int64
    let involuntary: Int64

    static func read() -> Self {
        var usage = rusage()
        #if canImport(Darwin)
        precondition(getrusage(RUSAGE_SELF, &usage) == 0)
        #else
        precondition(getrusage(Int32(RUSAGE_SELF.rawValue), &usage) == 0)
        #endif
        let cpu = (Int64(usage.ru_utime.tv_sec) + Int64(usage.ru_stime.tv_sec)) * 1_000_000_000
            + (Int64(usage.ru_utime.tv_usec) + Int64(usage.ru_stime.tv_usec)) * 1_000
        return Self(
            wall: DispatchTime.now().uptimeNanoseconds,
            cpu: cpu,
            voluntary: Int64(usage.ru_nvcsw),
            involuntary: Int64(usage.ru_nivcsw)
        )
    }
}

private final class WorkerResult: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool?
    func set(_ value: Bool) { lock.lock(); stored = value; lock.unlock() }
    func get() -> Bool? { lock.lock(); defer { lock.unlock() }; return stored }
}

@main
struct Driver {
    static func main() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        precondition(args.count == 2, "Usage: driver CASE ITERATIONS")
        let name = args[0]
        let iterations = Int(args[1])!
        precondition(iterations > 0)
        let paced = name.hasSuffix("-paced")
        let progress = name == "useful-progress"
        let immediate = name == "immediate-admission"
        let blocked = name.hasPrefix("eof-") || name.hasPrefix("gap-")
        precondition(blocked || progress || immediate || name == "no-reader")
        let gate = MediaReadAheadGate()
        let done = DispatchSemaphore(value: 0)
        let next = DispatchSemaphore(value: 0)
        let stepDone = DispatchSemaphore(value: 0)
        let result = WorkerResult()
        let warmup = paced ? 3 : (progress ? 32 : 1_000)

        if blocked {
            let timestamp: TimeInterval? = name.hasPrefix("eof-") ? nil : 600
            Thread.detachNewThread {
                result.set(gate.wait(until: timestamp, generation: 0))
                done.signal()
            }
            precondition(gate.waitForBlockedReader(timeout: 5))
        } else if progress {
            Thread.detachNewThread {
                var accepted = true
                for index in 1...(iterations + warmup) {
                    guard next.wait(timeout: .now() + 5) == .success else {
                        accepted = false
                        break
                    }
                    if !gate.wait(until: Double(index) + 30, generation: 0) {
                        accepted = false
                    }
                    stepDone.signal()
                }
                result.set(accepted)
                done.signal()
            }
        }

        var admissions = 0
        func operation(_ index: Int) {
            if progress {
                next.signal()
                precondition(gate.waitForBlockedReader(timeout: 5))
                gate.update(position: Double(index))
                precondition(stepDone.wait(timeout: .now() + 5) == .success)
            } else if immediate {
                if gate.wait(until: 30, generation: 0) { admissions += 1 }
            } else {
                if paced { Thread.sleep(forTimeInterval: 1.0 / 60.0) }
                // Even the burst case stays below the distant reader's horizon.
                let position = paced
                    ? Double(index) / 60.0
                    : Double(index) / Double(iterations + warmup) * 10
                gate.update(position: position)
            }
        }

        for index in 1...warmup { operation(index) }
        let before = ResourceSnapshot.read()
        for index in (warmup + 1)...(warmup + iterations) { operation(index) }
        let after = ResourceSnapshot.read()
        let finalPosition = gate.currentPosition

        gate.close()
        if blocked || progress {
            precondition(done.wait(timeout: .now() + 5) == .success)
            precondition(result.get() == progress, "Worker returned an unexpected result")
        }
        if immediate { precondition(admissions == warmup + iterations) }
        let row: [String: Any] = [
            "case": name,
            "iterations": iterations,
            "warmup": warmup,
            "nominal_paced_hz": paced ? 60 : 0,
            "wall_ns": after.wall - before.wall,
            "cpu_ns": after.cpu - before.cpu,
            "voluntary_context_switches": after.voluntary - before.voluntary,
            "involuntary_context_switches": after.involuntary - before.involuntary,
            "final_position": finalPosition,
            "admissions": admissions,
            "worker_result": result.get().map { $0 as Any } ?? NSNull(),
        ]
        let data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
