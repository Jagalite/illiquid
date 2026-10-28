/// Fixed-capacity storage. Callers own synchronization and admission policy.
struct FixedRingBuffer<Element> {
    private var slots: [Element?]
    private var head = 0
    private(set) var count = 0
    var isEmpty: Bool { count == 0 }

    init(capacity: Int) {
        precondition(capacity > 0)
        slots = Array(repeating: nil, count: capacity)
    }

    mutating func append(_ value: Element) {
        precondition(count < slots.count)
        // The tail can wrap only once. Compare before adding so even the
        // intermediate index stays within the ring's capacity.
        let distanceToEnd = slots.count - head
        let tail = count < distanceToEnd ? head + count : count - distanceToEnd
        slots[tail] = value
        count += 1
    }

    mutating func prepend(_ value: Element) {
        precondition(count < slots.count)
        head = head == 0 ? slots.count - 1 : head - 1
        slots[head] = value
        count += 1
    }

    mutating func removeFirst() -> Element {
        precondition(count > 0)
        let value = slots[head]!
        slots[head] = nil
        head = head == slots.count - 1 ? 0 : head + 1
        count -= 1
        return value
    }

    mutating func removeAll(keepingCapacity: Bool = true) {
        // The capacity belongs to the queue's lifetime, even after close.
        while !isEmpty { _ = removeFirst() }
        head = 0
    }
}
