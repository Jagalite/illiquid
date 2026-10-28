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
        // head and count are each bounded by the capacity, so one wrap is enough.
        var index = head + count
        if index >= slots.count { index -= slots.count }
        slots[index] = value
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
        head += 1
        if head == slots.count { head = 0 }
        count -= 1
        return value
    }

    mutating func removeAll(keepingCapacity: Bool = true) {
        // The capacity belongs to the queue's lifetime, even after close.
        while !isEmpty { _ = removeFirst() }
        head = 0
    }
}
