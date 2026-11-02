import Testing
@testable import IlliquidNativePlayback

@Suite("Fixed ring buffer")
struct FixedRingBufferTests {
    @Test(arguments: [1, 2, 3, 12, 48, 64, 96, 192])
    func appendWrapsWithoutChangingFIFOOrder(capacity: Int) {
        var ring = FixedRingBuffer<Int>(capacity: capacity)
        #expect(ring.count == 0)
        #expect(ring.isEmpty)
        for value in 0..<capacity { ring.append(value) }

        // Keep the queue full across repeated laps, forcing the append index
        // to cross the physical end while the logical head is nonzero.
        for value in capacity..<(capacity * 9) {
            #expect(ring.removeFirst() == value - capacity)
            ring.append(value)
            #expect(ring.count == capacity)
            #expect(!ring.isEmpty)
        }
        for expected in (capacity * 8)..<(capacity * 9) {
            #expect(ring.removeFirst() == expected)
        }
        #expect(ring.count == 0)
        #expect(ring.isEmpty)
    }

    @Test(arguments: [1, 2, 3, 12, 48, 64, 96, 192])
    func prependWrapsAndRetainsFrontOrder(capacity: Int) {
        var ring = FixedRingBuffer<Int>(capacity: capacity)
        for round in 0..<4 {
            let values = (round * capacity)..<((round + 1) * capacity)
            for (offset, value) in values.enumerated() {
                ring.prepend(value)
                #expect(ring.count == offset + 1)
            }
            for expected in values.reversed() {
                #expect(ring.removeFirst() == expected)
            }
            #expect(ring.isEmpty)
        }
    }

    @Test(arguments: [1, 2, 3, 12, 48, 64, 96, 192])
    func mixedOperationsMatchArrayOracle(capacity: Int) {
        var ring = FixedRingBuffer<Int>(capacity: capacity)
        var expected = Array(0..<capacity)
        for value in expected { ring.append(value) }
        var random = UInt64(capacity) &+ 0x9e3779b97f4a7c15

        for step in 0..<4_096 {
            random = random &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let choice = Int((random >> 32) & 255)
            let value = capacity + step
            if choice == 0 {
                ring.removeAll(keepingCapacity: step.isMultiple(of: 2))
                expected.removeAll()
            } else if !expected.isEmpty && (expected.count == capacity || choice < 96) {
                #expect(ring.removeFirst() == expected.removeFirst())
            } else if choice.isMultiple(of: 2) {
                ring.append(value)
                expected.append(value)
            } else {
                ring.prepend(value)
                expected.insert(value, at: 0)
            }
            #expect(ring.count == expected.count)
            #expect(ring.isEmpty == expected.isEmpty)
        }
        while !expected.isEmpty {
            #expect(ring.removeFirst() == expected.removeFirst())
        }
        #expect(ring.isEmpty)
    }

    @Test func optionalNilIsAPayloadRatherThanAnEmptySlot() {
        var ring = FixedRingBuffer<Int?>(capacity: 3)
        ring.append(nil)
        ring.append(42)
        #expect(ring.count == 2)
        #expect(ring.removeFirst() == nil)
        ring.prepend(nil)
        ring.append(99)
        #expect(ring.count == 3)
        #expect(ring.removeFirst() == nil)
        #expect(ring.removeFirst() == 42)
        #expect(ring.removeFirst() == 99)
        ring.append(nil)
        ring.prepend(nil)
        #expect(ring.removeFirst() == nil)
        #expect(ring.removeFirst() == nil)
        #expect(ring.isEmpty)
    }

    @Test func copiesMutateIndependentlyAfterWraparound() {
        var original = FixedRingBuffer<Int>(capacity: 3)
        for value in 1...3 { original.append(value) }
        #expect(original.removeFirst() == 1)
        original.append(4)
        var copy = original

        #expect(original.removeFirst() == 2)
        original.append(5)
        #expect(copy.removeFirst() == 2)
        copy.prepend(9)
        for expected in [3, 4, 5] { #expect(original.removeFirst() == expected) }
        for expected in [9, 3, 4] { #expect(copy.removeFirst() == expected) }
        #expect(original.isEmpty)
        #expect(copy.isEmpty)
    }

    @Test func removedPayloadLivesOnlyAsLongAsTheReturnedValue() {
        var ring = FixedRingBuffer<Payload>(capacity: 3)
        weak var reference: Payload?
        do {
            let payload = Payload()
            reference = payload
            ring.append(payload)
        }
        #expect(reference != nil)
        var removed: Payload? = ring.removeFirst()
        #expect(removed === reference)
        #expect(ring.isEmpty)
        removed = nil

        // Keep the ring alive so releasing the entire backing array cannot
        // conceal a payload retained in the vacated slot.
        withExtendedLifetime(ring) {
            #expect(reference == nil)
        }
    }

    @Test func removeAllReleasesWrappedReferencePayloads() {
        for keepCapacity in [true, false] {
            var ring = FixedRingBuffer<Payload>(capacity: 3)
            var references: [WeakPayload] = []
            for _ in 0..<3 {
                let payload = Payload()
                references.append(WeakPayload(payload))
                ring.append(payload)
            }
            #expect(references.allSatisfy { $0.value != nil })
            _ = ring.removeFirst()
            #expect(references[0].value == nil)
            do {
                let payload = Payload()
                references.append(WeakPayload(payload))
                ring.append(payload)
            }
            #expect(references.dropFirst().allSatisfy { $0.value != nil })

            ring.removeAll(keepingCapacity: keepCapacity)
            #expect(ring.count == 0)
            #expect(ring.isEmpty)
            withExtendedLifetime(ring) {
                #expect(references.allSatisfy { $0.value == nil })
            }
        }
    }

    @Test(arguments: [1, 2, 3, 12, 48, 64, 96, 192])
    func removeAllFalsePreservesTheQueuesFixedCapacity(capacity: Int) {
        var ring = FixedRingBuffer<Int>(capacity: capacity)
        for value in 0..<capacity { ring.append(value) }
        ring.removeAll(keepingCapacity: false)
        #expect(ring.count == 0)
        #expect(ring.isEmpty)

        var expected: [Int] = []
        for value in 0..<capacity {
            if value.isMultiple(of: 2) {
                ring.append(value)
                expected.append(value)
            } else {
                ring.prepend(value)
                expected.insert(value, at: 0)
            }
        }
        #expect(ring.count == capacity)
        for value in expected { #expect(ring.removeFirst() == value) }
        ring.removeAll(keepingCapacity: false)
        ring.append(-1)
        #expect(ring.removeFirst() == -1)
        #expect(ring.isEmpty)
    }

    private final class Payload {}

    private final class WeakPayload {
        weak var value: Payload?
        init(_ value: Payload) { self.value = value }
    }
}
