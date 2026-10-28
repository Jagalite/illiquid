import Testing
@testable import IlliquidNativePlayback

@Suite("Fixed ring buffer indexing")
struct FixedRingBufferIndexTests {
    @Test(arguments: [1, 2, 3, 7, 48, 64, 96, 97, 192])
    func fullCapacityOperationsPreserveOrderFromEveryHeadPosition(capacity: Int) {
        var ring = FixedRingBuffer<Int>(capacity: capacity)

        for offset in 0..<capacity {
            let values = (0..<capacity).map { offset * capacity + $0 }
            for value in values { ring.append(value) }
            #expect(ring.count == capacity)
            #expect(drain(&ring) == values)
            #expect(ring.isEmpty)

            for value in values { ring.prepend(value) }
            #expect(ring.count == capacity)
            #expect(drain(&ring) == Array(values.reversed()))
            #expect(ring.isEmpty)

            // A complete fill/drain returns to the same head position. Move
            // one slot before the next cycle to exercise every wrap boundary.
            ring.append(-1)
            #expect(ring.removeFirst() == -1)
        }
    }

    @Test(arguments: [1, 2, 3, 7, 48, 64, 96, 97, 192])
    func mixedOperationsMatchAnIndependentArrayModel(capacity: Int) {
        var ring = FixedRingBuffer<Int>(capacity: capacity)
        var model: [Int] = []
        var random = UInt64(capacity)
        var value = 0

        for step in 0..<4_096 {
            random = random &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let operation = Int((random >> 32) % 10)
            switch operation {
            case 0:
                ring.removeAll(keepingCapacity: step.isMultiple(of: 2))
                model.removeAll()
            case 1...3 where model.count < capacity:
                ring.append(value)
                model.append(value)
                value += 1
            case 4...6 where model.count < capacity:
                ring.prepend(value)
                model.insert(value, at: 0)
                value += 1
            default:
                if !model.isEmpty {
                    let expected = model.removeFirst()
                    #expect(ring.removeFirst() == expected)
                }
            }

            #expect(ring.count == model.count)
            #expect(ring.isEmpty == model.isEmpty)
            if step.isMultiple(of: 127) {
                var snapshot = ring
                #expect(drain(&snapshot) == model)
                #expect(ring.count == model.count)
            }
        }
        #expect(drain(&ring) == model)
    }

    @Test(arguments: [1, 2, 3, 7, 48, 64, 96, 97, 192])
    func copiedRingsRemainIndependentAfterWrapAndMutation(capacity: Int) {
        var original = FixedRingBuffer<Int>(capacity: capacity)
        for value in 0..<capacity { original.append(value) }
        #expect(original.removeFirst() == 0)
        original.append(capacity)
        let expected = Array(1...capacity)

        var edited = original
        var snapshot = original
        #expect(edited.removeFirst() == 1)
        edited.prepend(-1)
        original.removeAll()
        original.append(-2)

        #expect(drain(&original) == [-2])
        #expect(drain(&edited) == [-1] + expected.dropFirst())
        #expect(drain(&snapshot) == expected)
    }

    @Test func removingAWrappedElementTransfersThenReleasesItsReference() {
        var ring = FixedRingBuffer<Payload>(capacity: 3)
        advanceEmptyHead(&ring)
        var payload: Payload? = Payload()
        weak var observed = payload
        ring.append(payload!)
        payload = nil
        #expect(observed != nil)

        var removed: Payload? = ring.removeFirst()
        #expect(removed === observed)
        #expect(ring.isEmpty)
        removed = nil
        #expect(observed == nil)
    }

    @Test(arguments: [false, true])
    func clearingAWrappedRingReleasesBothSegmentsAndAllowsReuse(keepingCapacity: Bool) {
        var ring = FixedRingBuffer<Payload>(capacity: 3)
        advanceEmptyHead(&ring)
        let references = fillWithObservedPayloads(&ring, count: 3)
        #expect(references.allSatisfy { $0.value != nil })

        ring.removeAll(keepingCapacity: keepingCapacity)
        #expect(ring.isEmpty)
        #expect(references.allSatisfy { $0.value == nil })

        let reusedReferences = fillWithObservedPayloads(&ring, count: 3)
        #expect(ring.count == 3)
        while !ring.isEmpty { _ = ring.removeFirst() }
        #expect(reusedReferences.allSatisfy { $0.value == nil })
    }

    @Test func aSnapshotRetainsPayloadsUntilItsOwnEntriesAreRemoved() {
        var original = FixedRingBuffer<Payload>(capacity: 3)
        advanceEmptyHead(&original)
        let references = fillWithObservedPayloads(&original, count: 3)
        var snapshot = original

        original.removeAll()
        #expect(references.allSatisfy { $0.value != nil })
        #expect(snapshot.count == 3)
        snapshot.removeAll()
        #expect(references.allSatisfy { $0.value == nil })
    }

    private func drain(_ ring: inout FixedRingBuffer<Int>) -> [Int] {
        var values: [Int] = []
        while !ring.isEmpty { values.append(ring.removeFirst()) }
        return values
    }

    private final class Payload {}

    private final class WeakPayload {
        weak var value: Payload?
        init(_ value: Payload) { self.value = value }
    }

    private func advanceEmptyHead(_ ring: inout FixedRingBuffer<Payload>) {
        for _ in 0..<2 {
            ring.append(Payload())
            _ = ring.removeFirst()
        }
    }

    private func fillWithObservedPayloads(
        _ ring: inout FixedRingBuffer<Payload>, count: Int
    ) -> [WeakPayload] {
        var references: [WeakPayload] = []
        for _ in 0..<count {
            let payload = Payload()
            references.append(WeakPayload(payload))
            ring.append(payload)
        }
        return references
    }
}
