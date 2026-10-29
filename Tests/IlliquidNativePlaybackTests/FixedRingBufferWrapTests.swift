import Testing
@testable import IlliquidNativePlayback

@Suite("Fixed ring buffer wraparound")
struct FixedRingBufferWrapTests {
    @Test func mixedOperationsMatchAnArrayAcrossCapacities() {
        for capacity in [1, 2, 3, 5, 8, 12, 31, 32, 48, 64, 96, 128, 192] {
            var ring = FixedRingBuffer<Int>(capacity: capacity)
            var oracle: [Int] = []
            var random = Random(state: 0x91E1_0DA5_C79E_7B1D ^ UInt64(capacity))
            for value in 0..<capacity {
                ring.append(value)
                oracle.append(value)
            }
            for step in 0..<4_096 {
                let choice = random.next()
                if choice % 113 == 0 {
                    expectContents(ring, oracle)
                    ring.removeAll(keepingCapacity: (choice & 1) == 0)
                    oracle.removeAll()
                } else if oracle.isEmpty || (oracle.count < capacity && choice % 3 != 0) {
                    let value = capacity + step
                    if (choice & 1) == 0 {
                        ring.append(value)
                        oracle.append(value)
                    } else {
                        ring.prepend(value)
                        oracle.insert(value, at: 0)
                    }
                } else {
                    let actual = ring.removeFirst()
                    let expected = oracle.removeFirst()
                    #expect(actual == expected)
                }
                #expect(ring.count == oracle.count)
                #expect(ring.isEmpty == oracle.isEmpty)
                if step % 127 == 0 {
                    expectContents(ring, oracle)
                    #expect(ring.count == oracle.count)
                }
            }
            expectContents(ring, oracle)
            ring.removeAll(keepingCapacity: false)
            for value in 0..<capacity { ring.prepend(value) }
            expectContents(ring, Array((0..<capacity).reversed()))
        }
    }

    @Test func wrappedCopiesMutateIndependentlyAndSurviveClear() {
        var original = FixedRingBuffer<Int>(capacity: 5)
        for value in 0..<5 { original.append(value) }
        #expect(original.removeFirst() == 0)
        #expect(original.removeFirst() == 1)
        original.append(5)
        var copy = original
        original.prepend(-1)
        #expect(copy.removeFirst() == 2)
        copy.append(6)
        copy.prepend(-2)
        expectContents(original, [-1, 2, 3, 4, 5])
        expectContents(copy, [-2, 3, 4, 5, 6])
        original.removeAll(keepingCapacity: false)
        original.append(42)
        original.prepend(41)
        expectContents(original, [41, 42])
        expectContents(copy, [-2, 3, 4, 5, 6])
        copy.removeAll()
        copy.removeAll(keepingCapacity: false)
        for value in 10..<15 { copy.append(value) }
        expectContents(copy, [10, 11, 12, 13, 14])
        expectContents(original, [41, 42])
    }

    @Test func nilPayloadsRemainDistinctFromVacantSlots() {
        for capacity in [1, 2, 3, 8, 12, 96] {
            var ring = FixedRingBuffer<Int?>(capacity: capacity)
            for cycle in 0..<32 {
                var expected: [Int?] = []
                for index in 0..<capacity {
                    let value: Int? = index.isMultiple(of: 2) ? nil : cycle + index
                    ring.append(value)
                    expected.append(value)
                }
                for value in expected {
                    let actual = ring.removeFirst()
                    #expect(actual == value)
                }
                ring.prepend(nil)
                #expect(ring.count == 1)
                #expect(ring.removeFirst() == nil)
                #expect(ring.isEmpty)
            }
        }
    }

    @Test func copiesAndReturnedValuesRetainOnlyTheirOwnedPayloads() {
        let releases = ReleaseLog()
        var ring = FixedRingBuffer<Payload>(capacity: 5)
        for id in 0..<5 { ring.append(Payload(id, releases)) }
        var held: Payload? = ring.removeFirst()
        weak var observed: Payload? = held
        #expect(held?.id == 0)
        _ = ring.removeFirst()
        #expect(releases.ids == [1])
        ring.append(Payload(5, releases))
        ring.prepend(Payload(6, releases))
        var copy = ring
        ring.removeAll()
        #expect(ring.isEmpty)
        #expect(copy.count == 5)
        #expect(releases.ids == [1])
        withExtendedLifetime(held) {
            copy.removeAll(keepingCapacity: false)
            #expect(releases.ids == [1, 6, 2, 3, 4, 5])
            let callerStillOwnsPayload = observed != nil
            #expect(callerStillOwnsPayload)
        }
        held = nil
        #expect(observed == nil)
        #expect(releases.ids == [1, 6, 2, 3, 4, 5, 0])
        ring.append(Payload(7, releases))
        copy.prepend(Payload(8, releases))
        ring.removeAll(keepingCapacity: false)
        copy.removeAll()
        #expect(releases.ids == [1, 6, 2, 3, 4, 5, 0, 7, 8])
    }

    private func expectContents<Element: Equatable>(
        _ buffer: FixedRingBuffer<Element>, _ expected: [Element]
    ) {
        var snapshot = buffer
        #expect(snapshot.count == expected.count)
        guard snapshot.count == expected.count else { return }
        for value in expected {
            let actual = snapshot.removeFirst()
            #expect(actual == value)
        }
        #expect(snapshot.count == 0)
        #expect(snapshot.isEmpty)
    }

    private struct Random {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state >> 32
        }
    }
    private final class ReleaseLog {
        var ids: [Int] = []
    }
    private final class Payload {
        let id: Int
        let releases: ReleaseLog
        init(_ id: Int, _ releases: ReleaseLog) {
            self.id = id
            self.releases = releases
        }
        deinit { releases.ids.append(id) }
    }
}
