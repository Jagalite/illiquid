import Foundation

// Compile this file only in the separate operation-count executable. The
// unmodified gate resolves its unqualified NSCondition name to this wrapper.
// The timing executable does not compile this file and uses Foundation's class.
// Every counter is read or written while the original condition lock is held;
// instrumentation never signals, broadcasts, or introduces another wait.
struct GateConditionCounts: Sendable {
    var broadcasts: UInt64 = 0
    var signals: UInt64 = 0
    var waitCalls: UInt64 = 0
    var waitReturns: UInt64 = 0
    var diagnosticWaitCalls: UInt64 = 0
    var diagnosticWaitReturns: UInt64 = 0
    var activeReaders = 0
    var activeDiagnostics = 0

    func delta(since earlier: Self) -> [String: UInt64] {
        [
            "broadcasts": broadcasts - earlier.broadcasts,
            "signals": signals - earlier.signals,
            "wait_calls": waitCalls - earlier.waitCalls,
            "wait_returns": waitReturns - earlier.waitReturns,
            "diagnostic_wait_calls": diagnosticWaitCalls - earlier.diagnosticWaitCalls,
            "diagnostic_wait_returns": diagnosticWaitReturns - earlier.diagnosticWaitReturns,
        ]
    }
}

private final class GateConditionRegistry: @unchecked Sendable {
    private let lock = Foundation.NSLock()
    private var conditions: [NSCondition] = []

    func register(_ condition: NSCondition) {
        lock.lock()
        conditions.append(condition)
        lock.unlock()
    }

    func latestCondition() -> NSCondition {
        lock.lock()
        defer { lock.unlock() }
        precondition(!conditions.isEmpty, "Create a gate before reading its counters")
        return conditions[conditions.count - 1]
    }
}

enum GateConditionInstrumentation {
    private static let registry = GateConditionRegistry()

    fileprivate static func register(_ condition: NSCondition) {
        registry.register(condition)
    }

    static func snapshot() -> GateConditionCounts {
        currentCondition.snapshot()
    }

    static var currentCondition: NSCondition {
        registry.latestCondition()
    }
}

final class NSCondition: @unchecked Sendable {
    private let underlying = Foundation.NSCondition()
    private var counts = GateConditionCounts()

    init() {
        GateConditionInstrumentation.register(self)
    }

    func lock() { underlying.lock() }
    func unlock() { underlying.unlock() }

    func broadcast() {
        counts.broadcasts += 1
        underlying.broadcast()
    }

    func signal() {
        counts.signals += 1
        underlying.signal()
    }

    func wait() {
        counts.waitCalls += 1
        counts.activeReaders += 1
        underlying.wait()
        counts.activeReaders -= 1
        counts.waitReturns += 1
    }

    func wait(until limit: Date) -> Bool {
        counts.diagnosticWaitCalls += 1
        counts.activeDiagnostics += 1
        let result = underlying.wait(until: limit)
        counts.activeDiagnostics -= 1
        counts.diagnosticWaitReturns += 1
        return result
    }

    func snapshot() -> GateConditionCounts {
        lock()
        defer { unlock() }
        return counts
    }
}
