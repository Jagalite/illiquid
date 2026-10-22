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

    @Test(arguments: [1, 2, 4])
    func backgroundBurstsRespectCapacityAndExecuteEachJobOnce(capacity: Int) async throws {
        let executor = SourcePreparationExecutor(capacity: capacity, timeout: 5)
        let probe = SourcePreparationWorkProbe()
        let results = try await withThrowingTaskGroup(of: Int.self) { group in
            for id in 0..<48 {
                group.addTask {
                    try await executor.performWhenAvailable { check in
                        probe.enter(id)
                        defer { probe.leave(id) }
                        Thread.sleep(forTimeInterval: 0.001)
                        try check()
                        return id
                    }
                }
            }
            var results: [Int] = []
            for try await result in group { results.append(result) }
            return results
        }
        #expect(results.sorted() == Array(0..<48))
        #expect(probe.started.sorted() == Array(0..<48))
        #expect(probe.finished.sorted() == Array(0..<48))
        #expect(probe.peak <= max(1, capacity - 1))
        #expect(probe.running == 0)
        #expect(executor.activeCount == 0)
    }

    @Test func cancellingASaturatedQueueReclaimsTheEntireLogicalBudget() async throws {
        let executor = SourcePreparationExecutor(capacity: 1, timeout: 5)
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let blocker = Task {
            try await executor.perform { _ in
                entered.signal()
                guard release.wait(timeout: .now() + 10) == .success else {
                    throw SourcePreparationTestFailure.gateTimedOut
                }
                return -1
            }
        }
        try #require(await SourcePreparationTestWait.semaphore(entered))

        let probe = SourcePreparationWorkProbe()
        let queued = (0..<128).map { id in
            Task {
                let outcome = await SourcePreparationOutcome.capture {
                    try await executor.performWhenAvailable { _ in
                        probe.enter(id)
                        defer { probe.leave(id) }
                        return id
                    }
                }
                probe.record(outcome)
                return outcome
            }
        }
        // The physical worker is blocked. Exactly half of the requests can
        // enter the documented 64-request background budget; the rest fail
        // fast. No knowledge of the executor's queue representation is needed.
        let saturated = await SourcePreparationTestWait.until { probe.busy == 64 }
        for task in queued { task.cancel() }
        var cancelled = 0, busy = 0
        for task in queued {
            switch await task.value {
            case .cancelled: cancelled += 1
            case .busy: busy += 1
            case let other: Issue.record("Unexpected saturated-queue outcome: \(other)")
            }
        }
        #expect(saturated)
        #expect(busy == 64)
        #expect(cancelled == 64)
        #expect(probe.started.isEmpty)
        #expect(executor.activeCount == 1)

        // Repeat saturation without releasing the blocked OS call. Cancellation
        // must have reclaimed all logical slots, independently of physical work.
        let secondProbe = SourcePreparationWorkProbe()
        let replacement = (0..<128).map { id in
            Task {
                let outcome = await SourcePreparationOutcome.capture {
                    try await executor.performWhenAvailable { _ in
                        secondProbe.enter(id)
                        defer { secondProbe.leave(id) }
                        return id
                    }
                }
                secondProbe.record(outcome)
                return outcome
            }
        }
        let resaturated = await SourcePreparationTestWait.until { secondProbe.busy == 64 }
        release.signal()
        #expect(try await blocker.value == -1)
        var successes: [Int] = []
        var secondBusy = 0
        for task in replacement {
            switch await task.value {
            case let .success(id): successes.append(id)
            case .busy: secondBusy += 1
            case let other: Issue.record("Unexpected replacement-queue outcome: \(other)")
            }
        }
        #expect(resaturated)
        #expect(secondBusy == 64)
        #expect(successes.count == 64)
        #expect(Set(successes).count == 64)
        #expect(secondProbe.started.sorted() == successes.sorted())
        #expect(secondProbe.finished.sorted() == successes.sorted())
        #expect(executor.activeCount == 0)
    }

    @Test func queuedTimeoutsReleaseAdmissionWithoutStartingTheirWork() async throws {
        let executor = SourcePreparationExecutor(capacity: 1, timeout: 0.1)
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let blocker = Task {
            await SourcePreparationOutcome.capture {
                try await executor.perform { _ in
                    entered.signal()
                    guard release.wait(timeout: .now() + 5) == .success else {
                        throw SourcePreparationTestFailure.gateTimedOut
                    }
                    return -1
                }
            }
        }
        try #require(await SourcePreparationTestWait.semaphore(entered))
        let probe = SourcePreparationWorkProbe()
        for _ in 0..<2 {
            let results = await withTaskGroup(of: SourcePreparationOutcome.self) { group in
                for id in 0..<64 {
                    group.addTask {
                        await SourcePreparationOutcome.capture {
                            try await executor.performWhenAvailable { _ in
                                probe.enter(id)
                                defer { probe.leave(id) }
                                return id
                            }
                        }
                    }
                }
                var outcomes: [SourcePreparationOutcome] = []
                for await outcome in group { outcomes.append(outcome) }
                return outcomes
            }
            #expect(results.count == 64)
            #expect(results.allSatisfy { $0 == .timedOut })
            #expect(executor.activeCount == 1)
            #expect(probe.started.isEmpty)
        }
        #expect(await blocker.value == .timedOut)
        release.signal()
        try #require(await SourcePreparationTestWait.until { executor.activeCount == 0 })
        #expect(try await executor.performWhenAvailable { _ in 7 } == 7)
    }

    @Test func queuedBackgroundWorkPreservesTheInteractiveSlotAtHigherCapacity() async throws {
        let executor = SourcePreparationExecutor(capacity: 4, timeout: 5)
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        defer { for _ in 0..<3 { release.signal() } }
        let holders = (0..<3).map { id in
            Task {
                try await executor.performWhenAvailable { _ in
                    entered.signal()
                    guard release.wait(timeout: .now() + 10) == .success else {
                        throw SourcePreparationTestFailure.gateTimedOut
                    }
                    return id
                }
            }
        }
        for _ in 0..<3 { try #require(await SourcePreparationTestWait.semaphore(entered)) }
        let probe = SourcePreparationWorkProbe()
        let waiters = (0..<62).map { id in
            Task {
                let outcome = await SourcePreparationOutcome.capture {
                    try await executor.performWhenAvailable { _ in
                        probe.enter(id)
                        defer { probe.leave(id) }
                        return id
                    }
                }
                probe.record(outcome)
                return outcome
            }
        }
        // Three active background callers plus 61 waiters fill the budget.
        let saturated = await SourcePreparationTestWait.until { probe.busy == 1 }
        #expect(saturated)
        #expect(probe.started.isEmpty)
        #expect(executor.activeCount == 3)
        let interactive = try await executor.perform { _ in executor.activeCount }
        #expect(interactive == 4)
        #expect(executor.activeCount == 3)
        for task in waiters { task.cancel() }
        for task in waiters {
            let outcome = await task.value
            #expect(outcome == .busy || outcome == .cancelled)
        }
        #expect(probe.started.isEmpty)
        for _ in 0..<3 { release.signal() }
        for (id, task) in holders.enumerated() { #expect(try await task.value == id) }
        #expect(executor.activeCount == 0)
    }

    @Test(arguments: [false, true])
    func retiredQueuedRequestsReleaseCapturedWorkBeforeThePhysicalHolderExits(cancel: Bool) async throws {
        let executor = SourcePreparationExecutor(capacity: 1, timeout: cancel ? 5 : 0.1)
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let attempted = DispatchSemaphore(value: 0), captureReleased = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let blocker = Task {
            await SourcePreparationOutcome.capture {
                try await executor.perform { _ in
                    entered.signal()
                    guard release.wait(timeout: .now() + 10) == .success else {
                        throw SourcePreparationTestFailure.gateTimedOut
                    }
                    return -1
                }
            }
        }
        try #require(await SourcePreparationTestWait.semaphore(entered))
        let queued = Task { [lifetime = SourcePreparationCaptureLifetime(released: captureReleased)] in
            attempted.signal()
            return await SourcePreparationOutcome.capture {
                try await executor.performWhenAvailable { _ in
                    withExtendedLifetime(lifetime) {
                        Issue.record("Retired queued work must not execute")
                        return 1
                    }
                }
            }
        }
        try #require(await SourcePreparationTestWait.semaphore(attempted))
        if cancel {
            // Let the attempted call suspend behind the holder before retiring
            // it. The timeout variant also exercises cleanup without a cancel.
            try await Task.sleep(for: .milliseconds(20))
            queued.cancel()
        }
        #expect(await queued.value == (cancel ? .cancelled : .timedOut))
        #expect(executor.activeCount == 1)
        #expect(await SourcePreparationTestWait.semaphore(captureReleased))
        release.signal()
        _ = await blocker.value
        try #require(await SourcePreparationTestWait.until { executor.activeCount == 0 })
    }

    @Test func admissionDelayCountsAgainstTheExecutingRequestsDeadline() async throws {
        let executor = SourcePreparationExecutor(capacity: 1, timeout: 1)
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let workEntered = DispatchSemaphore(value: 0), workRelease = DispatchSemaphore(value: 0)
        let queuedAttempted = DispatchSemaphore(value: 0)
        defer { release.signal(); workRelease.signal() }
        let blocker = Task {
            try await executor.perform { _ in
                entered.signal()
                guard release.wait(timeout: .now() + 5) == .success else {
                    throw SourcePreparationTestFailure.gateTimedOut
                }
                return 0
            }
        }
        try #require(await SourcePreparationTestWait.semaphore(entered))
        let queued = Task {
            queuedAttempted.signal()
            return await SourcePreparationOutcome.capture {
                try await executor.performWhenAvailable { _ in
                    workEntered.signal()
                    guard workRelease.wait(timeout: .now() + 5) == .success else {
                        throw SourcePreparationTestFailure.gateTimedOut
                    }
                    return 1
                }
            }
        }
        try #require(await SourcePreparationTestWait.semaphore(queuedAttempted))
        try await Task.sleep(for: .milliseconds(650))
        release.signal()
        #expect(try await blocker.value == 0)
        try #require(await SourcePreparationTestWait.semaphore(workEntered))
        let workStart = ContinuousClock.now
        #expect(await queued.value == .timedOut)
        // Normally about 350 ms remain. A fresh one-second deadline at handoff
        // is observably different; leave generous headroom for CI scheduling.
        #expect(workStart.duration(to: .now) < .milliseconds(750))
        #expect(executor.activeCount == 1)
        workRelease.signal()
        try #require(await SourcePreparationTestWait.until { executor.activeCount == 0 })
    }

    @Test func cancellationRacingWithHandoffNeitherDuplicatesWorkNorLeaksCapacity() async throws {
        for id in 0..<32 {
            let executor = SourcePreparationExecutor(capacity: 1, timeout: 2)
            let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
            defer { release.signal() }
            let blocker = Task {
                try await executor.perform { _ in
                    entered.signal()
                    guard release.wait(timeout: .now() + 5) == .success else {
                        throw SourcePreparationTestFailure.gateTimedOut
                    }
                    return -1
                }
            }
            try #require(await SourcePreparationTestWait.semaphore(entered))
            let probe = SourcePreparationWorkProbe()
            let queued = Task {
                await SourcePreparationOutcome.capture {
                    try await executor.performWhenAvailable { check in
                        probe.enter(id)
                        defer { probe.leave(id) }
                        try check()
                        return id
                    }
                }
            }
            await Task.yield()
            DispatchQueue.global().async { release.signal() }
            queued.cancel()
            let result = await queued.value
            #expect(result == .cancelled || result == .success(id))
            #expect(try await blocker.value == -1)
            try #require(await SourcePreparationTestWait.until { executor.activeCount == 0 })
            #expect(probe.started.count <= 1)
            #expect(probe.started == probe.finished)
            #expect(try await executor.performWhenAvailable { _ in id + 100 } == id + 100)
        }
    }

}

private enum SourcePreparationTestFailure: Error { case gateTimedOut }

private final class SourcePreparationCaptureLifetime: @unchecked Sendable {
    private let released: DispatchSemaphore
    init(released: DispatchSemaphore) { self.released = released }
    deinit { released.signal() }
}

private enum SourcePreparationOutcome: Equatable, Sendable {
    case success(Int), busy, timedOut, cancelled, unexpected(String)

    static func capture(_ operation: () async throws -> Int) async -> Self {
        do { return .success(try await operation()) }
        catch is CancellationError { return .cancelled }
        catch SourcePreparationExecutor.Failure.busy { return .busy }
        catch SourcePreparationExecutor.Failure.timedOut { return .timedOut }
        catch { return .unexpected(String(describing: error)) }
    }
}

private final class SourcePreparationWorkProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var starts: [Int] = [], completions: [Int] = []
    private var active = 0, highWatermark = 0, busyCount = 0

    func enter(_ id: Int) {
        lock.withLock {
            starts.append(id)
            active += 1
            highWatermark = max(highWatermark, active)
        }
    }
    func leave(_ id: Int) {
        lock.withLock { completions.append(id); active -= 1 }
    }
    func record(_ outcome: SourcePreparationOutcome) {
        if outcome == .busy { lock.withLock { busyCount += 1 } }
    }
    var started: [Int] { lock.withLock { starts } }
    var finished: [Int] { lock.withLock { completions } }
    var running: Int { lock.withLock { active } }
    var peak: Int { lock.withLock { highWatermark } }
    var busy: Int { lock.withLock { busyCount } }
}

private enum SourcePreparationTestWait {
    static func semaphore(_ semaphore: DispatchSemaphore) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: semaphore.wait(timeout: .now() + 3) == .success)
            }
        }
    }

    static func until(_ condition: @Sendable () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline {
            do { try await Task.sleep(for: .milliseconds(1)) }
            catch { return false }
        }
        return condition()
    }
}
