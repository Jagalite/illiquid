import Foundation
import Testing
@testable import IlliquidCore

@Suite("Bounded source preparation", .serialized)
struct SourcePreparationExecutorTests {
    @Test func healthyBackgroundBurstsWakeOnCompletionRatherThanPollingIntoTheirDeadline() async throws {
        let executor = SourcePreparationExecutor(capacity: 2, timeout: 2)
        let start = ContinuousClock.now
        let count = try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<32 {
                group.addTask {
                    try await executor.performWhenAvailable { check in
                        Thread.sleep(forTimeInterval: 0.001)
                        try check()
                        return 1
                    }
                }
            }
            var total = 0
            for try await value in group { total += value }
            return total
        }
        #expect(count == 32)
        #expect(executor.activeCount == 0)
        print("STORAGE_HEALTHY_BURST count=\(count) wall=\(start.duration(to: .now))")
    }
    @Test func stalledBackgroundScanLeavesAnInteractiveSlotAndCancellationDoesNotFreeIt() async throws {
        let executor = SourcePreparationExecutor(capacity: 2, timeout: 2)
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let scan = Task {
            try await executor.performWhenAvailable { _ in
                entered.signal(); release.wait(); return 1
            }
        }
        let started = await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: entered.wait(timeout: .now() + 1)) }
        }
        #expect(started == .success)
        let queued = Task { try await executor.performWhenAvailable { _ in 2 } }
        try await Task.sleep(for: .milliseconds(40))
        #expect(executor.activeCount == 1)
        let clock = ContinuousClock.now
        #expect(try await executor.perform { _ in 3 } == 3)
        print("STORAGE_INTERACTIVE_WHILE_SCAN_STALLED \(clock.duration(to: .now))")
        scan.cancel()
        await #expect(throws: CancellationError.self) { try await scan.value }
        #expect(executor.activeCount == 1)
        queued.cancel()
        await #expect(throws: CancellationError.self) { try await queued.value }
        release.signal()
    }
    @Test func cancellationReturnsBeforeBlockedWorkAndRetainsPhysicalAdmission() async throws {
        let executor = SourcePreparationExecutor(capacity: 1, timeout: 5)
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let first = Task {
            await executor.result { check in
                entered.signal()
                release.wait()
                try check()
                return 1
            }
        }
        let enteredResult = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: entered.wait(timeout: .now() + 3))
            }
        }
        #expect(enteredResult == .success)
        first.cancel()
        let result = await first.value
        if case let .failure(error) = result { #expect(error is CancellationError) }
        else { Issue.record("Cancellation must retire the waiter before the OS operation exits") }
        #expect(executor.activeCount == 1)
        let rejected = await executor.result { _ in 2 }
        if case let .failure(error) = rejected {
            #expect(error as? SourcePreparationExecutor.Failure == .busy)
        } else { Issue.record("A retired waiter must not create another physical worker") }
        release.signal()
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while executor.activeCount != 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(executor.activeCount == 0)
        #expect(try await executor.perform { _ in 3 } == 3)
    }

    @Test func deadlineKeepsStalledWorkBoundedAndRunsOffTheMainThread() async throws {
        let executor = SourcePreparationExecutor(capacity: 1, timeout: 0.05)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let result = await executor.result { _ in
            #expect(!Thread.isMainThread)
            release.wait()
            return 1
        }
        if case let .failure(error) = result {
            #expect(error as? SourcePreparationExecutor.Failure == .timedOut)
        } else { Issue.record("Expected a bounded wait for stalled metadata") }
        #expect(executor.activeCount == 1)
    }
    @Test func backgroundWaitersShareThePhysicalLimitAndKeepOneDeadline() async throws {
        let executor = SourcePreparationExecutor(capacity: 1, timeout: 0.15)
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let first = Task {
            try await executor.perform { _ in
                entered.signal()
                release.wait()
                return 1
            }
        }
        let didEnter = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: entered.wait(timeout: .now() + 2))
            }
        }
        #expect(didEnter == .success)
        let cancelled = Task { try await executor.performWhenAvailable { _ in 2 } }
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        await #expect(throws: SourcePreparationExecutor.Failure.timedOut) {
            try await executor.performWhenAvailable { _ in
                Issue.record("No extra worker may start while the original OS call is blocked")
                return 3
            }
        }
        #expect(executor.activeCount == 1)
        release.signal()
        _ = try? await first.value
        #expect(try await executor.performWhenAvailable { _ in 4 } == 4)
    }

}
