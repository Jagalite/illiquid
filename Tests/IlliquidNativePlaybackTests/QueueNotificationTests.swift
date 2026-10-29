import Foundation
import Testing
@testable import IlliquidNativePlayback

@Suite("Playback queue notification liveness", .serialized)
struct QueueNotificationTests {
    private enum EnqueueMethod: String, CaseIterable, Sendable {
        case push
        case tryPush
        case pushFirst

        func enqueue(_ value: Int, into queue: BoundedQueue<Int>) -> Bool {
            switch self {
            case .push:
                return queue.push(value)
            case .tryPush:
                return queue.tryPush(value) == .pushed
            case .pushFirst:
                return queue.pushFirst(value)
            }
        }
    }

    private enum Budget: String, CaseIterable, Sendable {
        case items
        case bytes
        case duration
    }

    private struct Delivery: Sendable {
        let round: Int
        let value: Int
    }

    private final class Locked<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Value

        init(_ value: Value) { self.value = value }

        func update(_ body: (inout Value) -> Void) {
            lock.lock()
            defer { lock.unlock() }
            body(&value)
        }

        func read() -> Value {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    private enum TestFailure: Error {
        case unexpectedlyClosed
    }

    /// Only used when this test is the sole consumer and has established that
    /// the queue contains an item. Never enter a potentially blocking pop on
    /// the test thread while competing consumers are running.
    private func takeQueued(_ queue: BoundedQueue<Int>) throws -> Int {
        try #require(queue.count > 0)
        guard case let .value(value) = queue.pop() else {
            Issue.record("A nonempty queue unexpectedly closed")
            throw TestFailure.unexpectedlyClosed
        }
        return value
    }

    @Test(arguments: EnqueueMethod.allCases)
    private func repeatedBurstsReachEveryConsumer(method: EnqueueMethod) throws {
        let consumerCount = 4
        let rounds = 32
        let queue = BoundedQueue<Int>(capacity: consumerCount)
        let nextRound = DispatchSemaphore(value: 0)
        let ready = DispatchSemaphore(value: 0)
        let progress = DispatchSemaphore(value: 0)
        let workers = DispatchGroup()
        let deliveries = Locked<[Delivery]>([])

        for consumer in 0..<consumerCount {
            workers.enter()
            DispatchQueue(label: "queue-notification.consumer.\(consumer)").async {
                defer { workers.leave() }
                for round in 0..<rounds {
                    nextRound.wait()
                    ready.signal()
                    switch queue.pop() {
                    case let .value(value):
                        deliveries.update { $0.append(Delivery(round: round, value: value)) }
                        progress.signal()
                    case .closed:
                        progress.signal()
                        return
                    }
                }
            }
        }
        defer {
            queue.close()
            // Closing releases consumers in pop; releasing the gate also
            // retires consumers that have not entered their next pop yet.
            for _ in 0..<consumerCount { nextRound.signal() }
            #expect(workers.wait(timeout: .now() + 3) == .success)
        }

        for round in 0..<rounds {
            try #require(queue.count == 0)
            for _ in 0..<consumerCount { nextRound.signal() }
            for _ in 0..<consumerCount {
                try #require(ready.wait(timeout: .now() + 5) == .success)
            }

            // Also exercise consumers rechecking an empty queue after an
            // invalidation wakeup. Other rounds have no extra notification.
            if round % 8 == 7 { queue.removeAll() }

            let firstValue = round * consumerCount
            // The queue can hold the complete burst, so none of these enqueue
            // operations can block the test thread on producer capacity.
            for value in firstValue..<(firstValue + consumerCount) {
                try #require(method.enqueue(value, into: queue))
            }
            for _ in 0..<consumerCount {
                try #require(progress.wait(timeout: .now() + 5) == .success)
            }

            let observed = deliveries.read()
                .filter { $0.round == round }
                .map(\.value)
                .sorted()
            #expect(observed == Array(firstValue..<(firstValue + consumerCount)))
            #expect(queue.count == 0)
        }

        try #require(workers.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.read().count == rounds * consumerCount)
    }

    @Test(arguments: [EnqueueMethod.push, .pushFirst], Budget.allCases)
    private func releasingEachBudgetWakesItsProducer(
        method: EnqueueMethod,
        budget: Budget
    ) throws {
        let queue = BoundedQueue<Int>(
            capacity: budget == .items ? 2 : 3,
            byteCapacity: budget == .bytes ? 8 : Int.max,
            durationCapacityMicroseconds: budget == .duration ? 12 : Int64.max,
            cost: { _ in .init(bytes: 4, durationMicroseconds: 6) }
        )
        try #require(queue.tryPush(0) == .pushed)
        try #require(queue.tryPush(1) == .pushed)
        let producer = DispatchGroup()
        let accepted = Locked<Bool?>(nil)
        producer.enter()
        DispatchQueue(label: "queue-notification.budget-producer").async {
            defer { producer.leave() }
            let result = method.enqueue(2, into: queue)
            accepted.update { $0 = result }
        }
        defer {
            queue.close()
            #expect(producer.wait(timeout: .now() + 3) == .success)
        }

        try #require(queue.waitForBlockedProducer(timeout: 5))
        #expect(queue.budgetSnapshot == .init(items: 2, bytes: 8, durationMicroseconds: 12))

        // An item remains after this pop. Capacity release must wake the
        // producer even though the destination never became empty.
        let first = try takeQueued(queue)
        #expect(first == 0)
        try #require(producer.wait(timeout: .now() + 5) == .success)
        #expect(accepted.read() == true)
        #expect(queue.contentionSnapshot.waitingProducers == 0)
        #expect(queue.budgetSnapshot == .init(items: 2, bytes: 8, durationMicroseconds: 12))

        let expected = method == .pushFirst ? [2, 1] : [1, 2]
        var remaining: [Int] = []
        for _ in expected { remaining.append(try takeQueued(queue)) }
        #expect(remaining == expected)
        #expect(queue.budgetSnapshot == .init(items: 0, bytes: 0, durationMicroseconds: 0))
    }

    @Test(arguments: [EnqueueMethod.push, .pushFirst])
    private func contendingProducersAndConsumerKeepMakingProgress(
        method: EnqueueMethod
    ) throws {
        let producerCount = 6
        let queue = BoundedQueue<Int>(capacity: 1)
        try #require(queue.tryPush(-1) == .pushed)
        let workers = DispatchGroup()
        let accepted = Locked<[Int]>([])
        let received = Locked<[Int]>([])

        for value in 0..<producerCount {
            workers.enter()
            DispatchQueue(label: "queue-notification.producer.\(value)").async {
                defer { workers.leave() }
                if method.enqueue(value, into: queue) {
                    accepted.update { $0.append(value) }
                }
            }
        }
        defer {
            queue.close()
            #expect(workers.wait(timeout: .now() + 3) == .success)
        }

        // Observe queue-owned contention state, rather than assuming that a
        // scheduling delay means all producers have reached their wait.
        let deadline = Date().addingTimeInterval(5)
        while queue.contentionSnapshot.waitingProducers < producerCount, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.001)
        }
        try #require(queue.contentionSnapshot.waitingProducers == producerCount)

        workers.enter()
        DispatchQueue(label: "queue-notification.contended-consumer").async {
            defer { workers.leave() }
            for _ in 0...producerCount {
                switch queue.pop() {
                case let .value(value):
                    received.update { $0.append(value) }
                case .closed:
                    return
                }
            }
        }

        // The one-slot queue repeatedly wakes multiple producers. Producers
        // that lose the capacity race must safely wait again, while a
        // consumer that catches up must still receive subsequent work.
        try #require(workers.wait(timeout: .now() + 5) == .success)
        #expect(accepted.read().sorted() == Array(0..<producerCount))
        #expect(received.read().sorted() == [-1] + Array(0..<producerCount))
        #expect(queue.count == 0)
        #expect(queue.contentionSnapshot.waitingProducers == 0)
    }

    @Test
    private func closeReleasesEveryEmptyQueueConsumer() throws {
        let consumerCount = 6
        let queue = BoundedQueue<Int>(capacity: 1)
        let ready = DispatchSemaphore(value: 0)
        let workers = DispatchGroup()
        let closedResults = Locked(0)

        for consumer in 0..<consumerCount {
            workers.enter()
            DispatchQueue(label: "queue-notification.closing-consumer.\(consumer)").async {
                defer { workers.leave() }
                ready.signal()
                if case .closed = queue.pop() {
                    closedResults.update { $0 += 1 }
                }
            }
        }
        defer {
            queue.close()
            #expect(workers.wait(timeout: .now() + 3) == .success)
        }

        for _ in 0..<consumerCount {
            try #require(ready.wait(timeout: .now() + 5) == .success)
        }
        queue.close()
        try #require(workers.wait(timeout: .now() + 5) == .success)
        #expect(closedResults.read() == consumerCount)
        #expect(queue.tryPush(0) == .closed)
        #expect(queue.budgetSnapshot == .init(items: 0, bytes: 0, durationMicroseconds: 0))
    }
}
