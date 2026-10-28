import Testing
@testable import IlliquidNativePlayback

@Suite("Fixed ring buffer wrapping and ownership")
struct FixedRingBufferTests {
    @Test(arguments: [1, 2, 3, 7, 12, 48, 64, 96, 128, 192])
    func mixedOperationsMatchArray(capacity: Int) {
        var ring = FixedRingBuffer<Int>(capacity: capacity)
        var expected: [Int] = []

        // Fill the buffer, then wrap its head and tail several times while
        // keeping it full. Include non-power-of-two production capacities.
        for value in 0..<capacity {
            ring.append(value)
            expected.append(value)
        }
        for value in capacity..<(capacity * 5) {
            #expect(ring.removeFirst() == expected.removeFirst())
            ring.append(value)
            expected.append(value)
            #expect(ring.count == expected.count)
        }

        var random: UInt64 = 0xA17E_2026
        for value in 0..<2_000 {
            random = random &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            switch (random >> 32) % 8 {
            case 0, 1:
                if expected.count < capacity {
                    ring.append(value)
                    expected.append(value)
                }
            case 2, 3:
                if expected.count < capacity {
                    ring.prepend(value)
                    expected.insert(value, at: 0)
                }
            case 4, 5:
                if !expected.isEmpty {
                    #expect(ring.removeFirst() == expected.removeFirst())
                }
            case 6:
                ring.removeAll()
                expected.removeAll()
            default:
                break
            }
            #expect(ring.count == expected.count)
            #expect(ring.isEmpty == expected.isEmpty)
        }
        let remaining = drain(&ring)
        #expect(remaining == expected)
        #expect(ring.count == 0)
        #expect(ring.isEmpty)

        // Empty resets are idempotent, and the queue's fixed capacity is
        // usable again for either spelling of the reset API.
        ring.removeAll()
        ring.removeAll(keepingCapacity: false)
        for value in 0..<capacity { ring.prepend(value) }
        let refilled = drain(&ring)
        #expect(refilled == Array((0..<capacity).reversed()))
    }

    @Test func wrappedCopiesMutateIndependently() {
        var original = FixedRingBuffer<Int>(capacity: 5)
        for value in 0..<5 { original.append(value) }
        for value in 0..<3 { #expect(original.removeFirst() == value) }
        for value in 5..<8 { original.append(value) }
        // The full logical sequence [3, 4, 5, 6, 7] crosses the storage end.
        var copy = original

        #expect(copy.removeFirst() == 3)
        copy.prepend(99)
        #expect(original.removeFirst() == 3)
        original.append(8)

        var clearedCopy = original
        clearedCopy.removeAll(keepingCapacity: false)
        clearedCopy.append(-1)

        let copiedValues = drain(&copy)
        let originalValues = drain(&original)
        let clearedValues = drain(&clearedCopy)
        #expect(copiedValues == [99, 4, 5, 6, 7])
        #expect(originalValues == [4, 5, 6, 7, 8])
        #expect(clearedValues == [-1])
    }

    @Test func optionalNilIsAnElementRatherThanAnEmptySlot() {
        var ring = FixedRingBuffer<Int?>(capacity: 3)
        ring.append(nil)
        ring.prepend(7)
        ring.append(nil)
        #expect(ring.count == 3)
        #expect(ring.removeFirst() == 7)
        #expect(ring.removeFirst() == nil)
        ring.append(8)
        ring.prepend(nil)
        let actual = drain(&ring)
        #expect(actual == [nil, nil, 8])
        #expect(ring.isEmpty)
    }

    @Test func popTransfersTheLastPayloadReference() {
        var ring = FixedRingBuffer<Payload>(capacity: 2)
        var payload: Payload? = Payload()
        weak var weakPayload = payload
        ring.append(payload!)
        payload = nil
        #expect(weakPayload != nil)

        var returned: Payload? = ring.removeFirst()
        #expect(returned === weakPayload)
        #expect(ring.isEmpty)
        returned = nil
        #expect(weakPayload == nil)
    }

    @Test(arguments: [true, false])
    func clearingWrappedStorageReleasesPayloads(keepingCapacity: Bool) {
        var ring = FixedRingBuffer<Payload>(capacity: 3)
        var references: [WeakPayload] = []
        for _ in 0..<3 {
            let value = Payload()
            references.append(WeakPayload(value))
            ring.append(value)
        }
        _ = ring.removeFirst()
        _ = ring.removeFirst()
        #expect(references[0].value == nil)
        #expect(references[1].value == nil)
        for _ in 0..<2 {
            let value = Payload()
            references.append(WeakPayload(value))
            ring.append(value)
        }
        #expect(references.dropFirst(2).allSatisfy { $0.value != nil })
        ring.removeAll(keepingCapacity: keepingCapacity)
        #expect(references.allSatisfy { $0.value == nil })
        #expect(ring.count == 0)
        #expect(ring.isEmpty)
    }

    @Test func clearingACopyPreservesTheOriginalPayloadOwnership() {
        var original = FixedRingBuffer<Payload>(capacity: 1)
        var payload: Payload? = Payload()
        weak var weakPayload = payload
        original.append(payload!)
        payload = nil
        var copy = original
        copy.removeAll()
        #expect(weakPayload != nil)
        #expect(original.count == 1)
        original.removeAll()
        #expect(weakPayload == nil)
    }

    @Test func boundedQueuePrependWrapAndBudgetsRemainIntact() throws {
        let queue = BoundedQueue<Int>(
            capacity: 3,
            byteCapacity: 10,
            durationCapacityMicroseconds: 10,
            cost: { .init(bytes: $0, durationMicroseconds: Int64($0)) }
        )
        defer { queue.close() }

        #expect(queue.tryPush(3) == .pushed)
        #expect(queue.push(4))
        #expect(queue.pushFirst(2))
        #expect(queue.budgetSnapshot == .init(items: 3, bytes: 9, durationMicroseconds: 9))
        #expect(queue.tryPush(1) == .wouldBlock)
        let first = try pop(queue)
        #expect(first == 2)
        let second = try pop(queue)
        #expect(second == 3)

        #expect(queue.tryPush(5) == .pushed)
        #expect(queue.pushFirst(1))
        #expect(queue.budgetSnapshot == .init(items: 3, bytes: 10, durationMicroseconds: 10))
        for expected in [1, 4, 5] {
            let actual = try pop(queue)
            #expect(actual == expected)
        }
        #expect(queue.budgetSnapshot == .init(items: 0, bytes: 0, durationMicroseconds: 0))

        // The existing empty-queue oversize exception and invalidation
        // accounting must survive the storage implementation change.
        #expect(queue.tryPush(50) == .pushed)
        #expect(queue.tryPush(1) == .wouldBlock)
        queue.removeAll()
        #expect(queue.budgetSnapshot == .init(items: 0, bytes: 0, durationMicroseconds: 0))
        #expect(queue.pushFirst(2))
        let afterReset = try pop(queue)
        #expect(afterReset == 2)
        queue.close()
        #expect(queue.tryPush(1) == .closed)
        #expect(!queue.pushFirst(1))
    }

    private func drain<Element>(_ ring: inout FixedRingBuffer<Element>) -> [Element] {
        var result: [Element] = []
        while !ring.isEmpty { result.append(ring.removeFirst()) }
        return result
    }

    private func pop(_ queue: BoundedQueue<Int>) throws -> Int {
        // Fail before a blocking pop if a regression loses an expected item.
        try #require(queue.count > 0)
        switch queue.pop() {
        case let .value(value):
            return value
        case .closed:
            Issue.record("Unexpectedly closed queue")
            return -1
        }
    }

    private final class Payload {}

    private final class WeakPayload {
        weak var value: Payload?
        init(_ value: Payload) { self.value = value }
    }
}
