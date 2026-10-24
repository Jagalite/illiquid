import CWorkHeap
import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw NSError(domain: "OperationWorkLifetime", code: 1,
        userInfo: [NSLocalizedDescriptionKey: message]) }
}

@MainActor private func waitUntil(_ predicate: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(60))
    while !predicate() {
        try require(ContinuousClock.now < deadline, "Task/lifetime barrier timed out")
        await Task.yield()
    }
}

@MainActor private func exercise(_ owner: BenchmarkRuntime, scenario: String, cycles: Int) async throws -> Int {
    for index in 1...cycles {
        owner.arm(UInt64(index), physical: scenario == "physicalStop")
        if scenario == "cancel" { owner.cancelCurrent() }
        if scenario == "complete" {
            try await waitUntil { owner.lifetime.count == index }
        }
    }
    let beforeSettling = owner.trackedTasks
    if scenario == "physicalStop" {
        try await waitUntil { owner.physicalStop.waitingCount == cycles }
        try require(owner.trackedTasks == cycles, "Pending physical stops left shutdown inventory")
        owner.physicalStop.release()
    }
    try await waitUntil { owner.lifetime.count == cycles }
    // Closure teardown precedes the sample. This brief common quiet interval
    // also lets executor bookkeeping finish after the final actor callback.
    try await Task.sleep(for: .milliseconds(5))
    return beforeSettling
}

@MainActor private func check(_ owner: BenchmarkRuntime, scenario: String, cycles: Int, candidate: Bool) throws {
    let superseded = scenario == "supersede" || scenario == "physicalStop"
    let expectedHandles = !candidate && superseded ? cycles - 1 : 0
    try require(owner.trackedTasks == expectedHandles, "Unexpected settled task-handle count")
    try require(owner.ledgerCount == 0 && owner.deadlineCount == 0, "Completed ledger/deadline retained")
    try require(owner.failed == 0, "Unexpected failed terminal result")
    try require(owner.success == (superseded ? 1 : scenario == "complete" ? cycles : 0), "Wrong success count")
    try require(owner.cancelled == (superseded ? cycles - 1 : scenario == "cancel" ? cycles : 0), "Wrong cancellation count")
    let expectedCallbacks = scenario == "physicalStop" ? 0
        : candidate ? (scenario == "cancel" ? 0 : scenario == "supersede" ? 1 : cycles) : cycles
    try require(owner.callbacks == expectedCallbacks, "Wrong live/stale success-callback count")
    try require(owner.staleCallbacks == (!candidate && scenario != "physicalStop"
        ? (scenario == "supersede" ? cycles - 1 : scenario == "cancel" ? cycles : 0) : 0),
        "Unexpected stale success callback")
}

@MainActor private func run(scenario: String, cycles: Int, candidate: Bool) async throws -> [String: Any] {
    let owner = BenchmarkRuntime()
    _ = work_lifetime_heap_bytes()
    let before = work_lifetime_heap_bytes()
    let cpu = work_lifetime_cpu_nanoseconds()
    let start = DispatchTime.now().uptimeNanoseconds
    let pendingHandles = try await exercise(owner, scenario: scenario, cycles: cycles)
    let elapsed = DispatchTime.now().uptimeNanoseconds - start
    let cpuElapsed = work_lifetime_cpu_nanoseconds() - cpu
    let retained = withExtendedLifetime(owner) { work_lifetime_heap_bytes() }
    // All result receipts below use bounded counters, never an O(cycles) event
    // array or another retained collection of Task handles.
    try check(owner, scenario: scenario, cycles: cycles, candidate: candidate)
    let handles = owner.trackedTasks
    owner.clearResearchRegistry()
    let released = work_lifetime_heap_bytes()
    return ["scenario": scenario, "cycles": cycles,
        "handles_before_settling": pendingHandles, "completed_handles_retained": handles,
        "completed_closure_lifetimes": owner.lifetime.count,
        "allocator_before_bytes": before, "allocator_retained_bytes": retained,
        "allocator_after_registry_clear_bytes": released,
        "retained_allocator_delta_bytes": Int64(retained) - Int64(before),
        "released_allocator_delta_bytes": Int64(released) - Int64(before),
        "reclaimed_registry_bytes": Int64(retained) - Int64(released),
        "loop_wall_nanoseconds": elapsed, "loop_cpu_nanoseconds": cpuElapsed,
        "success": owner.success, "cancelled": owner.cancelled, "failed": owner.failed,
        "result_digest": String(owner.resultDigest),
        "success_callbacks": owner.callbacks, "stale_success_callbacks": owner.staleCallbacks,
        "polls": owner.presentation.polls,
        "heap_metric": String(cString: work_lifetime_heap_metric())]
}

@MainActor private func qualifications(candidate: Bool) async throws -> [[String: Any]] {
    var results: [[String: Any]] = []
    for scenario in ["supersede", "complete", "cancel", "physicalStop"] {
        results.append(try await run(scenario: scenario, cycles: 32, candidate: candidate))
    }
    let sleeping = BenchmarkRuntime()
    sleeping.presentation.ready = false
    sleeping.arm(1)
    try await waitUntil { sleeping.presentation.polls == 1 }
    sleeping.cancelCurrent()
    try await waitUntil { sleeping.lifetime.count == 1 }
    try require(sleeping.presentation.polls == (candidate ? 1 : 300), "Cancelled poller did not terminate as expected")
    try require(sleeping.callbacks == 0 && sleeping.cancelled == 1 && sleeping.success == 0
        && sleeping.trackedTasks == 0, "Cancelled sleeping work produced an effect/callback")
    results.append(["scenario": "cancelSleeping", "polls": sleeping.presentation.polls,
        "cancelled": sleeping.cancelled, "completed_handles_retained": sleeping.trackedTasks])
    let reentrant = BenchmarkRuntime()
    reentrant.arm(1)
    reentrant.onCancelled = { [weak reentrant] in
        reentrant?.onCancelled = nil
        reentrant?.arm(3)
    }
    reentrant.arm(2)
    try await waitUntil { reentrant.lifetime.count == 3 }
    try require(reentrant.success == 1 && reentrant.cancelled == 2, "Reentrant terminal outcomes changed")
    try require(reentrant.trackedTasks == (candidate ? 0 : 2), "Reentrant work registration was not fenced")
    try require(reentrant.deadlineCount == (candidate ? 0 : 1), "Reentrant deadline admission was not fenced")
    try require(reentrant.callbacks == (candidate ? 1 : 3), "Reentrant stale callback count incorrect")
    try require(reentrant.staleCallbacks == (candidate ? 0 : 2) && reentrant.ledgerCount == 0,
        "Reentrant callback authority or ledger cleanup failed")
    results.append(["scenario": "reentrant", "success": reentrant.success,
        "cancelled": reentrant.cancelled, "callbacks": reentrant.callbacks,
        "completed_handles_retained": reentrant.trackedTasks, "deadline_count": reentrant.deadlineCount])
    reentrant.clearResearchRegistry()
    return results
}

@main private enum Main {
    @MainActor static func main() async throws {
        let arguments = CommandLine.arguments
        #if WORK_LIFETIME_CANDIDATE
        let candidate = true
        #else
        let candidate = false
        #endif
        try require(String(cString: work_lifetime_heap_metric()) != "unsupported", "Allocator measurement unavailable")
        if arguments.count == 2 && arguments[1] == "verify" {
            print(String(decoding: try JSONSerialization.data(withJSONObject: await qualifications(candidate: candidate),
                options: [.sortedKeys]), as: UTF8.self))
            return
        }
        try require(arguments.count == 3, "Usage: harness SCENARIO CYCLES | verify")
        guard let cycles = Int(arguments[2]), cycles > 0,
              ["supersede", "complete", "cancel", "physicalStop"].contains(arguments[1]) else {
            throw NSError(domain: "OperationWorkLifetime", code: 2)
        }
        _ = try await run(scenario: "complete", cycles: 4, candidate: candidate)
        let result = try await run(scenario: arguments[1], cycles: cycles, candidate: candidate)
        print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
    }
}
