import Foundation

enum BoundedQueueResult<Element> {
    case value(Element)
    case closed
}

enum BoundedQueuePushResult: Equatable, Sendable {
    case pushed
    case wouldBlock
    case closed
}

struct BoundedQueueCost: Equatable, Sendable {
    var bytes: Int
    var durationMicroseconds: Int64

    init(bytes: Int = 0, durationMicroseconds: Int64 = 0) {
        self.bytes = max(bytes, 0)
        self.durationMicroseconds = max(durationMicroseconds, 0)
    }
}

struct BoundedQueueBudgetSnapshot: Equatable, Sendable {
    let items: Int
    let bytes: Int
    let durationMicroseconds: Int64
}

struct BoundedQueueContentionSnapshot: Equatable, Sendable {
    let waitingProducers: Int
    let peakWaitingProducers: Int
    let producerWaits: Int
    let producerWaitSeconds: Double
}

/// A bounded FIFO with blocking backpressure. Closing wakes every producer and
/// consumer, while removeAll invalidates queued work without changing lifetime.
final class BoundedQueue<Element>: @unchecked Sendable {
    private struct Entry {
        let element: Element
        let cost: BoundedQueueCost
    }

    private let condition = NSCondition()
    private let capacity: Int
    private let byteCapacity: Int
    private let durationCapacityMicroseconds: Int64
    private let cost: @Sendable (Element) -> BoundedQueueCost
    private var storage: FixedRingBuffer<Entry>
    private var storedBytes = 0
    private var storedDurationMicroseconds: Int64 = 0
    private var closed = false
    private var invalidationRevision: UInt64 = 0
    private var waitingProducerCount = 0
    private var peakWaitingProducerCount = 0
    private var producerWaitCount = 0
    private var producerWaitSeconds = 0.0
    private var capacityChangeHandler: (@Sendable () -> Void)?

    init(
        capacity: Int,
        byteCapacity: Int = .max,
        durationCapacityMicroseconds: Int64 = .max,
        cost: @escaping @Sendable (Element) -> BoundedQueueCost = { _ in BoundedQueueCost() }
    ) {
        precondition(capacity > 0)
        precondition(byteCapacity > 0)
        precondition(durationCapacityMicroseconds > 0)
        self.capacity = capacity
        storage = FixedRingBuffer(capacity: capacity)
        self.byteCapacity = byteCapacity
        self.durationCapacityMicroseconds = durationCapacityMicroseconds
        self.cost = cost
    }

    var count: Int {
        condition.withLock { storage.count }
    }

    var budgetSnapshot: BoundedQueueBudgetSnapshot {
        condition.withLock {
            BoundedQueueBudgetSnapshot(
                items: storage.count,
                bytes: storedBytes,
                durationMicroseconds: storedDurationMicroseconds
            )
        }
    }

    var contentionSnapshot: BoundedQueueContentionSnapshot {
        condition.withLock {
            BoundedQueueContentionSnapshot(
                waitingProducers: waitingProducerCount,
                peakWaitingProducers: peakWaitingProducerCount,
                producerWaits: producerWaitCount,
                producerWaitSeconds: producerWaitSeconds
            )
        }
    }

    @discardableResult
    func push(_ element: Element) -> Bool {
        let elementCost = cost(element)
        condition.lock()
        defer { condition.unlock() }
        let arrivalRevision = invalidationRevision

        while wouldExceedBudget(adding: elementCost), !storage.isEmpty, !closed {
            waitingProducerCount += 1
            peakWaitingProducerCount = max(
                peakWaitingProducerCount,
                waitingProducerCount
            )
            producerWaitCount += 1
            let waitStarted = ProcessInfo.processInfo.systemUptime
            condition.broadcast()
            condition.wait()
            producerWaitSeconds += max(
                0,
                ProcessInfo.processInfo.systemUptime - waitStarted
            )
            waitingProducerCount -= 1
            condition.broadcast()
        }
        guard !closed, arrivalRevision == invalidationRevision else { return false }
        storage.append(Entry(element: element, cost: elementCost))
        storedBytes += elementCost.bytes
        storedDurationMicroseconds += elementCost.durationMicroseconds
        condition.broadcast()
        return true
    }

    /// Attempts an immediate enqueue without putting the calling producer to
    /// sleep. This lets a multiplexing producer keep feeding independent
    /// streams when one destination is full.
    func tryPush(_ element: Element) -> BoundedQueuePushResult {
        let elementCost = cost(element)
        return condition.withLock {
            guard !closed else { return .closed }
            guard !wouldExceedBudget(adding: elementCost) || storage.isEmpty else {
                return .wouldBlock
            }
            storage.append(Entry(element: element, cost: elementCost))
            storedBytes += elementCost.bytes
            storedDurationMicroseconds += elementCost.durationMicroseconds
            condition.broadcast()
            return .pushed
        }
    }

    @discardableResult
    func pushFirst(_ element: Element) -> Bool {
        let elementCost = cost(element)
        condition.lock()
        defer { condition.unlock() }
        let arrivalRevision = invalidationRevision

        while wouldExceedBudget(adding: elementCost), !storage.isEmpty, !closed {
            waitingProducerCount += 1
            peakWaitingProducerCount = max(
                peakWaitingProducerCount,
                waitingProducerCount
            )
            producerWaitCount += 1
            let waitStarted = ProcessInfo.processInfo.systemUptime
            condition.broadcast()
            condition.wait()
            producerWaitSeconds += max(
                0,
                ProcessInfo.processInfo.systemUptime - waitStarted
            )
            waitingProducerCount -= 1
            condition.broadcast()
        }
        guard !closed, arrivalRevision == invalidationRevision else { return false }
        storage.prepend(Entry(element: element, cost: elementCost))
        storedBytes += elementCost.bytes
        storedDurationMicroseconds += elementCost.durationMicroseconds
        condition.broadcast()
        return true
    }

    func pop() -> BoundedQueueResult<Element> {
        condition.lock()
        while storage.isEmpty, !closed {
            condition.wait()
        }
        guard !storage.isEmpty else {
            condition.unlock()
            return .closed
        }
        let entry = storage.removeFirst()
        storedBytes -= entry.cost.bytes
        storedDurationMicroseconds -= entry.cost.durationMicroseconds
        condition.broadcast()
        let handler = capacityChangeHandler
        condition.unlock()
        handler?()
        return .value(entry.element)
    }

    func removeAll() {
        let handler = condition.withLock { () -> (@Sendable () -> Void)? in
            invalidationRevision &+= 1
            storage.removeAll(keepingCapacity: true)
            storedBytes = 0
            storedDurationMicroseconds = 0
            condition.broadcast()
            return capacityChangeHandler
        }
        handler?()
    }

    /// Test and diagnostic coordination for proving that control work can
    /// invalidate a producer already blocked on data capacity. This observes
    /// queue-owned state instead of guessing the interleaving with a sleep.
    func waitForBlockedProducer(timeout: TimeInterval) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while waitingProducerCount == 0, !closed {
            guard condition.wait(until: deadline) else { break }
        }
        return waitingProducerCount > 0
    }

    func close() {
        let handler = condition.withLock { () -> (@Sendable () -> Void)? in
            closed = true
            invalidationRevision &+= 1
            storage.removeAll()
            storedBytes = 0
            storedDurationMicroseconds = 0
            condition.broadcast()
            return capacityChangeHandler
        }
        handler?()
    }

    /// The callback must not synchronously call back into this queue. It is
    /// invoked after a pop, removal, or close makes producer progress possible.
    func setCapacityChangeHandler(_ handler: (@Sendable () -> Void)?) {
        condition.withLock { capacityChangeHandler = handler }
    }

    private func wouldExceedBudget(adding cost: BoundedQueueCost) -> Bool {
        storage.count >= capacity
            || storedBytes > byteCapacity - min(cost.bytes, byteCapacity)
            || storedDurationMicroseconds
                > durationCapacityMicroseconds
                    - min(cost.durationMicroseconds, durationCapacityMicroseconds)
    }
}

/// Revisioned cross-queue wakeup used by a producer that can make progress on
/// any of several bounded destinations. The revision prevents missed wakeups
/// between a nonblocking drain attempt and the following wait.
final class BoundedQueueCapacitySignal<Key: Hashable & Sendable>: @unchecked Sendable {
    private let condition = NSCondition()
    private var revisions: [Key: UInt64] = [:]
    private var waitingKeys: Set<Key> = []

    var currentRevisions: [Key: UInt64] {
        condition.withLock { revisions }
    }

    func notify(_ key: Key) {
        condition.withLock {
            revisions[key, default: 0] &+= 1
            if waitingKeys.contains(key) { condition.broadcast() }
        }
    }

    @discardableResult
    func waitForChange(
        in keys: Set<Key>,
        after observedRevisions: [Key: UInt64],
        timeout: TimeInterval
    ) -> Bool {
        guard !keys.isEmpty else { return false }
        condition.lock()
        defer { condition.unlock() }
        let didChange = {
            keys.contains { key in
                self.revisions[key, default: 0]
                    != observedRevisions[key, default: 0]
            }
        }
        guard !didChange() else { return true }
        waitingKeys.formUnion(keys)
        defer { waitingKeys.subtract(keys) }
        let deadline = Date().addingTimeInterval(timeout)
        while !didChange() {
            guard condition.wait(until: deadline) else { break }
        }
        return didChange()
    }
}

struct BoundedInterleavingRouterSnapshot: Equatable, Sendable {
    let pendingItems: Int
    let pendingBytes: Int
    let pendingDurationMicroseconds: Int64
    let peakPendingItems: Int
    let deferredItems: Int
    let capacityWaits: Int
    let capacityWaitSeconds: Double
}

/// A single-producer, bounded staging layer for interleaved streams. Per-key
/// FIFO order is preserved while independent destinations may advance around
/// a full queue. It never drops an element and never owns more than its stated
/// item/byte/duration budget plus one accepted oversize element.
final class BoundedInterleavingRouter<Key: Hashable & Sendable, Element> {
    private struct Pending {
        let key: Key
        let element: Element
        let cost: BoundedQueueCost
    }

    private let destinations: [Key: BoundedQueue<Element>]
    private let maximumPendingItems: Int
    private let maximumPendingBytes: Int
    private let maximumPendingDurationMicroseconds: Int64
    private let cost: (Element) -> BoundedQueueCost
    private let capacitySignal = BoundedQueueCapacitySignal<Key>()
    private var pending: [Pending] = []
    private var pendingBytes = 0
    private var pendingDurationMicroseconds: Int64 = 0
    private var peakPendingItems = 0
    private var deferredItems = 0
    private var capacityWaits = 0
    private var capacityWaitSeconds = 0.0

    init(
        destinations: [Key: BoundedQueue<Element>],
        maximumPendingItems: Int,
        maximumPendingBytes: Int,
        maximumPendingDurationMicroseconds: Int64,
        cost: @escaping (Element) -> BoundedQueueCost
    ) {
        precondition(!destinations.isEmpty)
        precondition(maximumPendingItems > 0)
        precondition(maximumPendingBytes > 0)
        precondition(maximumPendingDurationMicroseconds > 0)
        self.destinations = destinations
        self.maximumPendingItems = maximumPendingItems
        self.maximumPendingBytes = maximumPendingBytes
        self.maximumPendingDurationMicroseconds = maximumPendingDurationMicroseconds
        self.cost = cost
        let signal = capacitySignal
        for (key, destination) in destinations {
            destination.setCapacityChangeHandler { signal.notify(key) }
        }
    }

    var isEmpty: Bool { pending.isEmpty }

    var canAcceptAnotherElement: Bool {
        pending.isEmpty
            || (pending.count < maximumPendingItems
                && pendingBytes < maximumPendingBytes
                && pendingDurationMicroseconds < maximumPendingDurationMicroseconds)
    }

    var capacityRevisions: [Key: UInt64] { capacitySignal.currentRevisions }

    var snapshot: BoundedInterleavingRouterSnapshot {
        BoundedInterleavingRouterSnapshot(
            pendingItems: pending.count,
            pendingBytes: pendingBytes,
            pendingDurationMicroseconds: pendingDurationMicroseconds,
            peakPendingItems: peakPendingItems,
            deferredItems: deferredItems,
            capacityWaits: capacityWaits,
            capacityWaitSeconds: capacityWaitSeconds
        )
    }

    func pendingCount(for key: Key) -> Int {
        pending.reduce(into: 0) { count, entry in
            if entry.key == key { count += 1 }
        }
    }

    @discardableResult
    func route(
        _ element: Element,
        to key: Key,
        allowingBudgetOverflow: Bool = false
    ) -> BoundedQueuePushResult {
        guard let destination = destinations[key] else { return .closed }
        if !pending.contains(where: { $0.key == key }) {
            switch destination.tryPush(element) {
            case .pushed:
                return .pushed
            case .closed:
                return .closed
            case .wouldBlock:
                break
            }
        }
        guard allowingBudgetOverflow || canAcceptAnotherElement else {
            return .wouldBlock
        }
        appendPending(element, to: key)
        return .pushed
    }

    /// Drains every destination that currently has room. A blocked key does
    /// not prevent later keys from advancing, but entries for the same key
    /// never overtake one another.
    @discardableResult
    func drain() -> BoundedQueuePushResult {
        var blockedKeys: Set<Key> = []
        var index = 0
        while index < pending.count {
            let entry = pending[index]
            if blockedKeys.contains(entry.key) {
                index += 1
                continue
            }
            guard let destination = destinations[entry.key] else { return .closed }
            switch destination.tryPush(entry.element) {
            case .pushed:
                pending.remove(at: index)
                pendingBytes -= entry.cost.bytes
                pendingDurationMicroseconds -= entry.cost.durationMicroseconds
            case .wouldBlock:
                blockedKeys.insert(entry.key)
                index += 1
            case .closed:
                return .closed
            }
        }
        return .pushed
    }

    func removeAll() {
        pending.removeAll(keepingCapacity: true)
        pendingBytes = 0
        pendingDurationMicroseconds = 0
    }

    func waitForCapacityChange(
        after revisions: [Key: UInt64],
        timeout: TimeInterval
    ) {
        let pendingKeys = Set(pending.map(\.key))
        guard !pendingKeys.isEmpty else { return }
        capacityWaits += 1
        let start = ProcessInfo.processInfo.systemUptime
        _ = capacitySignal.waitForChange(
            in: pendingKeys,
            after: revisions,
            timeout: timeout
        )
        capacityWaitSeconds += max(0, ProcessInfo.processInfo.systemUptime - start)
    }

    private func appendPending(_ element: Element, to key: Key) {
        let elementCost = cost(element)
        pending.append(Pending(key: key, element: element, cost: elementCost))
        pendingBytes += elementCost.bytes
        pendingDurationMicroseconds += elementCost.durationMicroseconds
        peakPendingItems = max(peakPendingItems, pending.count)
        deferredItems += 1
    }
}

private extension NSCondition {
    func withLock<Result>(_ body: () -> Result) -> Result {
        lock()
        defer { unlock() }
        return body()
    }
}
