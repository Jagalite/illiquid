import Foundation
import Dispatch

// Untimed mechanism verification only. The runner changes exactly one line in
// a copied gate: private let condition = NSCondition() becomes
// let condition = ProbeCondition(). Timed binaries use the unmodified source.
final class ProbeCondition: @unchecked Sendable {
    private let backing = NSCondition()
    private var broadcasts = 0
    private var waits = 0
    private var returns = 0
    private var readers = 0
    private var observers = 0

    func lock() { backing.lock() }
    func unlock() { backing.unlock() }
    func broadcast() { broadcasts += 1; backing.broadcast() }
    func wait() {
        waits += 1
        readers += 1
        backing.wait()
        readers -= 1
        returns += 1
    }
    func wait(until deadline: Date) -> Bool {
        observers += 1
        defer { observers -= 1 }
        return backing.wait(until: deadline)
    }
    func snapshot() -> Snapshot {
        backing.lock()
        defer { backing.unlock() }
        return Snapshot(broadcasts: broadcasts, waits: waits, returns: returns,
                        readers: readers, observers: observers)
    }

    struct Snapshot: Codable {
        let broadcasts: Int
        let waits: Int
        let returns: Int
        let readers: Int
        let observers: Int
    }
}

private final class Task: @unchecked Sendable {
    private let lock = NSLock()
    private let done = DispatchGroup()
    private var value: Bool?
    init(_ body: @escaping @Sendable () -> Bool) {
        done.enter()
        Thread.detachNewThread { [self] in
            let result = body()
            lock.lock(); value = result; lock.unlock()
            done.leave()
        }
    }
    func result() -> Bool? { lock.lock(); defer { lock.unlock() }; return value }
    func join() -> Bool { done.wait(timeout: .now() + 5) == .success }
}

private struct Receipt: Codable {
    let name: String
    let before: ProbeCondition.Snapshot
    let after: ProbeCondition.Snapshot
    let updates: Int
}

@main
struct Probe {
    private static func require(_ value: Bool, _ message: String) throws {
        if !value { throw NSError(domain: message, code: 1) }
    }

    private static func awaitWaiters(
        _ gate: MediaReadAheadGate, readers: Int, observers: Int? = nil
    ) -> Bool {
        let deadline = Date().addingTimeInterval(5)
        repeat {
            let snapshot = gate.condition.snapshot()
            if snapshot.readers == readers,
               observers == nil || snapshot.observers == observers! { return true }
            Thread.sleep(forTimeInterval: 0.001)
        } while Date() < deadline
        return false
    }

    private static func cleanup(_ gate: MediaReadAheadGate, _ tasks: [Task]) {
        gate.close()
        for task in tasks { precondition(task.join(), "Worker failed to stop") }
    }

    private static func paced(_ name: String, timestamp: TimeInterval?, candidate: Bool) throws -> Receipt {
        let gate = MediaReadAheadGate()
        let reader = Task { gate.wait(until: timestamp, generation: 0) }
        defer { cleanup(gate, [reader]) }
        try require(awaitWaiters(gate, readers: 1), "Reader did not block")
        let before = gate.condition.snapshot()
        for index in 1...24 {
            Thread.sleep(forTimeInterval: 0.010)
            gate.update(position: Double(index) / 100)
        }
        let after = gate.condition.snapshot()
        try require(reader.result() == nil && after.readers == 1, "Ineligible reader completed")
        try require(gate.currentPosition == 0.24, "Position updates were lost")
        let broadcasts = after.broadcasts - before.broadcasts
        try require(candidate ? broadcasts == 0 : broadcasts >= 24,
                    "Unexpected update broadcast count")
        // Wait returns are observed, never required to be zero: the OS may
        // wake a condition spuriously without any gate notification.
        gate.close()
        try require(reader.join() && reader.result() == false, "Close failed")
        return Receipt(name: name, before: before, after: after, updates: 24)
    }

    private static func observerFirst() throws -> Receipt {
        let gate = MediaReadAheadGate()
        let observer = Task { gate.waitForBlockedReader(timeout: 5) }
        var tasks = [observer]
        defer { cleanup(gate, tasks) }
        try require(awaitWaiters(gate, readers: 0, observers: 1), "Observer did not block")
        let before = gate.condition.snapshot()
        let reader = Task { gate.wait(until: nil, generation: 0) }
        tasks.append(reader)
        try require(observer.join() && observer.result() == true, "Observer missed first reader")
        try require(awaitWaiters(gate, readers: 1, observers: 0), "EOF reader not parked")
        return Receipt(name: "observer-before-reader", before: before,
                       after: gate.condition.snapshot(), updates: 0)
    }

    private static func multipleReaders(candidate: Bool) throws -> Receipt {
        let gate = MediaReadAheadGate()
        let first = Task { gate.wait(until: 31, generation: 0) }
        let second = Task { gate.wait(until: 32, generation: 0) }
        let eof = Task { gate.wait(until: nil, generation: 0) }
        let tasks = [first, second, eof]
        defer { cleanup(gate, tasks) }
        try require(awaitWaiters(gate, readers: 3), "Mixed readers did not all block")
        let before = gate.condition.snapshot()
        Thread.sleep(forTimeInterval: 0.050)
        let after = gate.condition.snapshot()
        if candidate {
            try require(after.broadcasts == before.broadcasts, "Readers woke one another")
        }
        // Advance twice without waiting for the first broadcast's readers to
        // resume. Then reset within the same generation and invalidate EOF.
        gate.update(position: 1)
        gate.update(position: 2)
        try require(first.join() && first.result() == true, "First threshold missed")
        try require(second.join() && second.result() == true, "Second threshold missed")
        try require(eof.result() == nil, "Progress released EOF")
        try require(awaitWaiters(gate, readers: 1), "EOF waiter was lost")
        gate.reset(generation: 0, position: 0)
        try require(awaitWaiters(gate, readers: 1), "Same-generation reset lost EOF")
        try require(eof.result() == nil, "Same-generation reset retired EOF")
        gate.reset(generation: 1, position: 0)
        try require(eof.join() && eof.result() == false, "Reset failed to retire EOF")
        return Receipt(name: "mixed-reader-idle-and-progress", before: before,
                       after: after, updates: 0)
    }

    static func main() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        precondition(args.count == 2 && args[0] == "--variant")
        precondition(args[1] == "baseline" || args[1] == "candidate")
        let candidate = args[1] == "candidate"
        let cases = try [
            paced("eof", timestamp: nil, candidate: candidate),
            paced("distant-timestamp", timestamp: 600, candidate: candidate),
            observerFirst(),
            multipleReaders(candidate: candidate),
        ]
        struct Report: Codable {
            let variant: String
            let passed: Bool
            let cases: [Receipt]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Report(variant: args[1], passed: true, cases: cases))
        print(String(decoding: data, as: UTF8.self))
    }
}
