import Foundation
import Testing
@testable import IlliquidNativePlayback

@Suite("Fixed ring buffer storage")
struct FixedRingBufferTests {
    @Test(arguments: [1, 2, 3, 12, 48, 64, 96, 192, 193])
    func mixedOperationsMatchAnArrayModel(capacity: Int) {
        var ring = FixedRingBuffer<Int>(capacity: capacity)
        var model: [Int] = []
        for value in 0..<capacity {
            ring.append(value)
            model.append(value)
        }

        var seed = UInt64(capacity) &+ 0xA17E_630D
        for step in 0..<4_000 {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let value = capacity + step
            switch (seed >> 32) % 7 {
            case 0, 1, 2:
                if model.count == capacity {
                    removeFirstMatchesModel(&ring, &model)
                }
                ring.append(value)
                model.append(value)
            case 3:
                if model.count == capacity {
                    removeFirstMatchesModel(&ring, &model)
                }
                ring.prepend(value)
                model.insert(value, at: 0)
            case 4, 5:
                if !model.isEmpty {
                    removeFirstMatchesModel(&ring, &model)
                }
            default:
                ring.removeAll(keepingCapacity: step.isMultiple(of: 2))
                model.removeAll()
            }
            #expect(ring.count == model.count)
            #expect(ring.isEmpty == model.isEmpty)
        }

        let remaining = drain(&ring)
        #expect(remaining == model)
        #expect(ring.count == 0)
        #expect(ring.isEmpty)
    }

    @Test(arguments: [1, 2, 3, 12, 48, 64, 96, 192, 193])
    func wrappedStorageCanBeClearedAndRefilled(capacity: Int) {
        for keepingCapacity in [false, true] {
            var ring = FixedRingBuffer<Int>(capacity: capacity)
            var model: [Int] = []
            for cycle in 0..<6 {
                for value in 0..<capacity {
                    ring.append(value)
                    model.append(value)
                }
                for step in 0..<(capacity * 3 + 7) {
                    removeFirstMatchesModel(&ring, &model)
                    let value = capacity + cycle * 1_000 + step
                    if step.isMultiple(of: 3) {
                        ring.prepend(value)
                        model.insert(value, at: 0)
                    } else {
                        ring.append(value)
                        model.append(value)
                    }
                }

                var snapshot = ring
                let contents = drain(&snapshot)
                #expect(contents == model)
                #expect(ring.count == capacity)
                ring.removeAll(keepingCapacity: keepingCapacity)
                model.removeAll()
                #expect(ring.count == 0)
                #expect(ring.isEmpty)
                ring.removeAll(keepingCapacity: keepingCapacity)
                #expect(ring.isEmpty)
            }
        }
    }

    @Test
    func optionalNilPayloadsRemainDistinctFromEmptySlots() {
        var ring = FixedRingBuffer<Int?>(capacity: 3)
        ring.append(nil)
        ring.append(7)
        ring.prepend(nil)
        #expect(ring.count == 3)
        #expect(!ring.isEmpty)

        let first = ring.removeFirst()
        let second = ring.removeFirst()
        let third = ring.removeFirst()
        #expect(first == nil)
        #expect(second == nil)
        #expect(third == 7)
        #expect(ring.isEmpty)

        ring.append(11)
        ring.append(nil)
        ring.prepend(13)
        let wrappedValues = drain(&ring)
        let expected: [Int?] = [13, 11, nil]
        #expect(wrappedValues == expected)

        ring.append(nil)
        ring.removeAll(keepingCapacity: false)
        ring.append(nil)
        #expect(ring.count == 1)
        let refilled = ring.removeFirst()
        #expect(refilled == nil)
        #expect(ring.isEmpty)
    }

    @Test
    func copiesKeepIndependentContentsAfterMutationAndClear() {
        var original = FixedRingBuffer<Int>(capacity: 3)
        for value in [1, 2, 3] { original.append(value) }
        let initial = original.removeFirst()
        #expect(initial == 1)
        original.append(4)

        var modified = original
        let removed = modified.removeFirst()
        #expect(removed == 2)
        modified.prepend(9)

        var cleared = original
        cleared.removeAll(keepingCapacity: false)
        cleared.append(8)

        let originalValues = drain(&original)
        let modifiedValues = drain(&modified)
        let clearedValues = drain(&cleared)
        #expect(originalValues == [2, 3, 4])
        #expect(modifiedValues == [9, 3, 4])
        #expect(clearedValues == [8])
    }

    @Test
    func referencePayloadsFollowPopClearCopyAndDestructionLifetimes() {
        for keepingCapacity in [false, true] {
            var ring = FixedRingBuffer<Payload>(capacity: 3)
            let popped = appendPayload(1, to: &ring)
            let second = appendPayload(2, to: &ring)
            let third = appendPayload(3, to: &ring)

            var returned: Payload? = ring.removeFirst()
            #expect(returned?.value == 1)
            withExtendedLifetime(returned) { #expect(popped.isAlive) }
            returned = nil
            #expect(!popped.isAlive)

            let wrapped = appendPayload(4, to: &ring)
            #expect(second.isAlive && third.isAlive && wrapped.isAlive)
            ring.removeAll(keepingCapacity: keepingCapacity)
            #expect(!second.isAlive && !third.isAlive && !wrapped.isAlive)
            #expect(ring.isEmpty)

            let refilled = appendPayload(5, to: &ring)
            ring.removeAll(keepingCapacity: keepingCapacity)
            #expect(!refilled.isAlive)
        }

        var original = FixedRingBuffer<Payload>(capacity: 1)
        let shared = appendPayload(6, to: &original)
        var copy = original
        original.removeAll()
        #expect(shared.isAlive)
        copy.removeAll()
        #expect(!shared.isAlive)

        let destroyed: WeakPayload = {
            var ring = FixedRingBuffer<Payload>(capacity: 2)
            return appendPayload(7, to: &ring)
        }()
        #expect(!destroyed.isAlive)
    }

    private func removeFirstMatchesModel(
        _ ring: inout FixedRingBuffer<Int>,
        _ model: inout [Int]
    ) {
        let actual = ring.removeFirst()
        let expected = model.removeFirst()
        #expect(actual == expected)
    }

    private func drain<Element>(_ ring: inout FixedRingBuffer<Element>) -> [Element] {
        var result: [Element] = []
        while !ring.isEmpty { result.append(ring.removeFirst()) }
        return result
    }

    private func appendPayload(
        _ value: Int,
        to ring: inout FixedRingBuffer<Payload>
    ) -> WeakPayload {
        let payload = Payload(value)
        let probe = WeakPayload(payload)
        ring.append(payload)
        return probe
    }

    private final class Payload {
        let value: Int
        init(_ value: Int) { self.value = value }
    }

    private final class WeakPayload {
        private weak var payload: Payload?
        var isAlive: Bool { payload != nil }
        init(_ payload: Payload) { self.payload = payload }
    }
}
