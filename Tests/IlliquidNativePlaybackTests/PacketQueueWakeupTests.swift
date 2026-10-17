import Foundation
import Testing
@testable import IlliquidNativePlayback

@Suite("Playback queue wakeup and invalidation", .serialized)
struct PacketQueueWakeupTests {
    private final class ResultBox<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: T
        init(_ value: T) { self.value = value }
        func update(_ body: (inout T) -> Void) { lock.lock(); defer { lock.unlock() }; body(&value) }
        func read() -> T { lock.lock(); defer { lock.unlock() }; return value }
    }
    @Test func fullQueueDoesNotGenerateItsOwnCapacityWakeups() throws {
        let queue = BoundedQueue<Int>(capacity: 1)
        #expect(queue.push(0))
        let done = DispatchGroup()
        for value in 1...2 {
            done.enter()
            DispatchQueue(label: "queue-wakeup.producer.\(value)").async {
                #expect(!queue.push(value))
                done.leave()
            }
        }
        defer { queue.close(); _ = done.wait(timeout: .now() + 3) }
        let deadline = Date().addingTimeInterval(3)
        while queue.contentionSnapshot.waitingProducers < 2, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.001)
        }
        try #require(queue.contentionSnapshot.waitingProducers == 2)
        let before = queue.contentionSnapshot.producerWaits
        Thread.sleep(forTimeInterval: 0.030)
        let additional = queue.contentionSnapshot.producerWaits - before
        // A generous allowance for incidental/spurious wakeups, not a CPU-time gate.
        #expect(additional < 64)
        #expect(queue.count == 1)
        queue.close()
        #expect(done.wait(timeout: .now() + 3) == .success)
    }
    @Test(arguments: [false, true]) func invalidatedProducerDoesNotWaitForNewWork(prepend: Bool) throws {
        for iteration in 0..<4 {
            let queue = BoundedQueue<Int>(capacity: 1)
            #expect(queue.push(1))
            let result = ResultBox<Bool?>(nil)
            let done = DispatchSemaphore(value: 0)
            DispatchQueue(label: "queue-invalidation.\(iteration)").async {
                result.update { $0 = prepend ? queue.pushFirst(2) : queue.push(2) }
                done.signal()
            }
            defer { queue.close() }
            try #require(queue.waitForBlockedProducer(timeout: 3))
            queue.removeAll()
            #expect(queue.tryPush(3) == .pushed)
            // The only remaining item is NEW work. Old work must retire without
            // requiring the consumer to drain that new-generation item first.
            let retired = done.wait(timeout: .now() + 2) == .success
            #expect(retired)
            if !retired { queue.close(); _ = done.wait(timeout: .now() + 3) }
            #expect(result.read() == false)
            if retired, case let .value(value) = queue.pop() { #expect(value == 3) }
        }
    }
    @Test func diagnosticObserverIsNotLeftSleeping() throws {
        let queue = BoundedQueue<Int>(capacity: 1)
        #expect(queue.push(1))
        let observed = ResultBox(false)
        let observerDone = DispatchSemaphore(value: 0)
        let producerDone = DispatchSemaphore(value: 0)
        DispatchQueue(label: "queue-observer").async {
            observed.update { $0 = queue.waitForBlockedProducer(timeout: 3) }
            observerDone.signal()
        }
        DispatchQueue(label: "queue-observed-producer").async {
            #expect(!queue.push(2)); producerDone.signal()
        }
        defer { queue.close() }
        try #require(observerDone.wait(timeout: .now() + 4) == .success)
        #expect(observed.read())
        queue.close()
        #expect(producerDone.wait(timeout: .now() + 3) == .success)
    }
    @Test func closeReleasesEveryBlockedProducer() throws {
        let queue = BoundedQueue<Int>(capacity: 1)
        #expect(queue.push(0))
        let done = DispatchGroup()
        let rejected = ResultBox(0)
        for value in 1...8 {
            done.enter()
            DispatchQueue(label: "queue-close.\(value)").async {
                if !queue.push(value) { rejected.update { $0 += 1 } }
                done.leave()
            }
        }
        defer { queue.close() }
        try #require(queue.waitForBlockedProducer(timeout: 3))
        queue.close()
        #expect(done.wait(timeout: .now() + 3) == .success)
        #expect(rejected.read() == 8)
        #expect(queue.count == 0)
    }
    @Test func fifoAndBudgetRulesRemainUnchanged() {
        let queue = BoundedQueue<Int>(capacity: 3, byteCapacity: 10, cost: { .init(bytes: $0) })
        #expect(queue.tryPush(6) == .pushed)
        #expect(queue.tryPush(5) == .wouldBlock)
        #expect(queue.pushFirst(3))
        #expect(queue.budgetSnapshot.bytes == 9)
        if case let .value(value) = queue.pop() { #expect(value == 3) }
        if case let .value(value) = queue.pop() { #expect(value == 6) }
        #expect(queue.tryPush(50) == .pushed) // Existing empty-queue oversize exception.
        #expect(queue.tryPush(1) == .wouldBlock)
        queue.removeAll()
        #expect(queue.budgetSnapshot == .init(items: 0, bytes: 0, durationMicroseconds: 0))
        queue.close()
    }
    @Test func capacityCallbackRunsOutsideTheQueueLock() {
        let queue = BoundedQueue<Int>(capacity: 1)
        let calls = ResultBox(0)
        queue.setCapacityChangeHandler { _ = queue.count; calls.update { $0 += 1 } }
        #expect(queue.push(1)); _ = queue.pop(); queue.removeAll(); queue.close()
        #expect(calls.read() == 3)
        queue.setCapacityChangeHandler(nil)
    }
    @Test func clearedObjectsAreReleased() {
        final class Payload {}
        let queue = BoundedQueue<Payload>(capacity: 1)
        var value: Payload? = Payload()
        weak var retained = value
        #expect(queue.push(value!)); value = nil
        #expect(retained != nil); queue.removeAll(); #expect(retained == nil)
        queue.close()
    }
}
