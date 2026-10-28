import Testing
@testable import IlliquidNativePlayback

private typealias Identity = VideoFrameIdentityHistory.FrameIdentity

private struct IdentityValue: Equatable {
    let surfaceID: UInt32?
    let bufferID: UInt
    let timeBits: UInt64
    let generation: Int
    init(_ value: Identity) {
        surfaceID = value.surfaceID; bufferID = value.bufferID
        timeBits = value.time.bitPattern; generation = value.generation
    }
}

private func expectIdentity(_ actual: Identity?, _ expected: Identity?, _ context: String = "") {
    #expect(actual.map(IdentityValue.init) == expected.map(IdentityValue.init), "\(context)")
}

private func expectTime(_ actual: Double?, _ expected: Double?, _ context: String = "") {
    #expect(actual?.bitPattern == expected?.bitPattern, "\(context)")
}

private func frame(_ index: Int, time: Double? = nil, generation: Int = 0) -> Identity {
    Identity(surfaceID: UInt32(index), bufferID: UInt(index + 1),
             time: time ?? Double(index), generation: generation)
}

/// Frozen array behavior, kept deliberately independent of the circular storage.
private struct ReferenceHistory {
    var values: [Identity] = []
    mutating func append(_ value: Identity) {
        if values.count == 128 { values.removeFirst() }
        values.append(value)
    }
    mutating func removeAll() { values.removeAll(keepingCapacity: true) }
    func identity(surfaceID: UInt32?, bufferID: UInt) -> Identity? {
        if let surfaceID { return values.last { $0.surfaceID == surfaceID } }
        return values.last { $0.bufferID == bufferID }
    }
    func adjacentTime(to frame: Identity, direction: Int) -> Double? {
        let candidates = values.filter { $0.generation == frame.generation }
        if direction > 0 {
            return candidates.filter { $0.time > frame.time + 0.000001 }
                .min { $0.time < $1.time }?.time
        }
        return candidates.filter { $0.time < frame.time - 0.000001 }
            .max { $0.time < $1.time }?.time
    }
}

@Suite("Video frame identity history")
struct VideoFrameIdentityHistoryTests {
    @Test(arguments: [0, 1, 127, 128, 129, 256, 513])
    func boundedHistoryKeepsExactlyTheNewest128(count: Int) {
        var history = VideoFrameIdentityHistory()
        for index in 0..<count { history.append(frame(index)) }
        for index in 0..<count {
            let expected: Identity? = index >= max(0, count - 128) ? frame(index) : nil
            expectIdentity(history.identity(surfaceID: UInt32(index), bufferID: UInt.max), expected)
            expectIdentity(history.identity(surfaceID: nil, bufferID: UInt(index + 1)), expected)
        }
        expectIdentity(history.identity(surfaceID: UInt32.max, bufferID: UInt.max), nil)
        expectIdentity(history.identity(surfaceID: nil, bufferID: UInt.max), nil)
        if count == 0 {
            expectTime(history.adjacentTime(to: frame(0), direction: 1), nil)
            expectTime(history.adjacentTime(to: frame(0), direction: -1), nil)
        } else {
            expectTime(history.adjacentTime(to: frame(count - 1), direction: 1), nil)
            expectTime(history.adjacentTime(to: frame(max(0, count - 128)), direction: -1), nil)
        }
    }

    @Test func newestReuseWinsAndSurfaceQueriesNeverFallBackToBuffer() {
        var history = VideoFrameIdentityHistory()
        let a = Identity(surfaceID: 7, bufferID: 1, time: 1, generation: 1)
        let b = Identity(surfaceID: 7, bufferID: 2, time: 2, generation: 2)
        let c = Identity(surfaceID: 8, bufferID: 1, time: 3, generation: 3)
        for value in [a, b, c] { history.append(value) }
        expectIdentity(history.identity(surfaceID: 7, bufferID: 1), b)
        expectIdentity(history.identity(surfaceID: nil, bufferID: 1), c)
        expectIdentity(history.identity(surfaceID: 999, bufferID: 1), nil)
        expectIdentity(history.identity(surfaceID: 7, bufferID: UInt.max), b)
        let d = Identity(surfaceID: 7, bufferID: 1, time: 4, generation: 4)
        let e = Identity(surfaceID: nil, bufferID: 1, time: 5, generation: 5)
        history.append(d); history.append(d); history.append(e)
        expectIdentity(history.identity(surfaceID: 7, bufferID: 1), d)
        expectIdentity(history.identity(surfaceID: nil, bufferID: 1), e)
        expectIdentity(history.identity(surfaceID: nil, bufferID: 2), b)
    }

    @Test func adjacentTimesRespectGenerationStrictToleranceAndNonmonotonicInsertion() {
        var history = VideoFrameIdentityHistory()
        let query = frame(50, time: 2, generation: 7)
        for (index, time) in [10.0, 1, 3, 5, 3, 2].enumerated() {
            history.append(frame(index, time: time, generation: 7))
        }
        history.append(frame(20, time: 2.000002, generation: 8))
        history.append(frame(21, time: 1.999998, generation: 8))
        expectTime(history.adjacentTime(to: query, direction: 1), 3)
        expectTime(history.adjacentTime(to: query, direction: -1), 1)
        let upper = 2.0 + 0.000001, lower = 2.0 - 0.000001
        for (index, time) in [upper, lower, upper.nextDown, lower.nextUp].enumerated() {
            history.append(frame(30 + index, time: time, generation: 7))
        }
        expectTime(history.adjacentTime(to: query, direction: 1), 3)
        expectTime(history.adjacentTime(to: query, direction: 0), 1)
        history.append(frame(40, time: upper.nextUp, generation: 7))
        history.append(frame(41, time: lower.nextDown, generation: 7))
        expectTime(history.adjacentTime(to: query, direction: Int.max), upper.nextUp)
        expectTime(history.adjacentTime(to: query, direction: Int.min), lower.nextDown)
        expectTime(history.adjacentTime(to: frame(50, time: 2, generation: 999), direction: 1), nil)
    }

    @Test(arguments: [false, true])
    func equalZeroTimesKeepChronologicalTieOrderAcrossWrap(negativeFirst: Bool) {
        var history = VideoFrameIdentityHistory()
        for index in 0..<127 { history.append(frame(index, generation: 99)) }
        let first: Double = negativeFirst ? -0.0 : 0.0
        let second: Double = negativeFirst ? 0.0 : -0.0
        history.append(frame(500, time: first, generation: 1))
        history.append(frame(501, time: second, generation: 1))
        expectTime(history.adjacentTime(to: frame(600, time: -1, generation: 1), direction: 1), first)
        expectTime(history.adjacentTime(to: frame(600, time: 1, generation: 1), direction: -1), first)
        for zero in [0.0, -0.0] {
            expectTime(history.adjacentTime(to: frame(600, time: zero, generation: 1), direction: 1), nil)
            expectTime(history.adjacentTime(to: frame(600, time: zero, generation: 1), direction: 0), nil)
        }
    }

    @Test func nonfiniteTimesRetainComparisonAndLookupBehavior() {
        var history = VideoFrameIdentityHistory()
        var reference = ReferenceHistory()
        let nan = Double(bitPattern: 0x7ff8_0000_0000_002a)
        let times: [Double] = [nan, -.infinity, -2, -0.0, 0.0, 2, .infinity]
        for (index, time) in times.enumerated() {
            let value = frame(index, time: time, generation: 3)
            history.append(value); reference.append(value)
            expectIdentity(history.identity(surfaceID: UInt32(index), bufferID: 0), value)
        }
        for time in [nan, Double.nan, -.infinity, .infinity, -0.0, 0.0] {
            let query = frame(20, time: time, generation: 3)
            for direction in [-1, 0, 1] {
                expectTime(history.adjacentTime(to: query, direction: direction),
                           reference.adjacentTime(to: query, direction: direction))
            }
        }
        expectTime(history.adjacentTime(to: frame(20, time: .infinity, generation: 3), direction: -1), 2)
        expectTime(history.adjacentTime(to: frame(20, time: -.infinity, generation: 3), direction: 1), -2)
        expectTime(history.adjacentTime(to: frame(20, time: nan, generation: 3), direction: 1), nil)
    }

    @Test func clearingWrappedStorageRemovesEveryOldIdentityBeforeRefill() {
        var history = VideoFrameIdentityHistory()
        for index in 0..<300 { history.append(frame(index)) }
        history.removeAll(); history.removeAll()
        for index in 0..<300 {
            expectIdentity(history.identity(surfaceID: UInt32(index), bufferID: 0), nil)
            expectIdentity(history.identity(surfaceID: nil, bufferID: UInt(index + 1)), nil)
        }
        expectTime(history.adjacentTime(to: frame(0), direction: 1), nil)
        for index in 0..<130 { history.append(frame(index, time: Double(index + 100), generation: 9)) }
        expectIdentity(history.identity(surfaceID: 0, bufferID: 1), nil)
        expectIdentity(history.identity(surfaceID: 1, bufferID: 2), nil)
        expectIdentity(history.identity(surfaceID: 2, bufferID: 0), frame(2, time: 102, generation: 9))
        expectIdentity(history.identity(surfaceID: 129, bufferID: 0), frame(129, time: 229, generation: 9))
        expectTime(history.adjacentTime(to: frame(5, time: 105, generation: 0), direction: 1), nil)
    }

    @Test func copiedSnapshotsRemainIndependentAcrossWrapClearAndRefill() {
        var history = VideoFrameIdentityHistory()
        for index in 0..<128 { history.append(frame(index)) }
        let snapshot = history
        history.append(frame(128))
        expectIdentity(history.identity(surfaceID: 0, bufferID: 0), nil)
        expectIdentity(snapshot.identity(surfaceID: 0, bufferID: 0), frame(0))
        expectIdentity(snapshot.identity(surfaceID: 128, bufferID: 0), nil)
        var fork = snapshot
        fork.append(frame(129))
        history.removeAll()
        history.append(frame(0, time: 900, generation: 42))
        expectIdentity(history.identity(surfaceID: 0, bufferID: 0), frame(0, time: 900, generation: 42))
        expectIdentity(snapshot.identity(surfaceID: 0, bufferID: 0), frame(0))
        expectIdentity(fork.identity(surfaceID: 0, bufferID: 0), nil)
        expectIdentity(fork.identity(surfaceID: 129, bufferID: 0), frame(129))
        fork.removeAll()
        expectIdentity(snapshot.identity(surfaceID: 127, bufferID: 0), frame(127))
        expectTime(snapshot.adjacentTime(to: frame(50), direction: 1), 51)
    }

    @Test(arguments: [UInt64(0), 1, 0x1234_5678_9abc_def0, UInt64.max])
    func seededMixedOperationsMatchArrayReference(seed: UInt64) {
        var random = HistoryRandom(state: seed)
        var history = VideoFrameIdentityHistory()
        var reference = ReferenceHistory()
        for step in 0..<4_096 {
            let operation = random.next() & 255
            if operation == 0 {
                history.removeAll(); reference.removeAll()
            } else if operation < 192 {
                let value = random.identity()
                history.append(value); reference.append(value)
            }
            let lookup = random.identity()
            let surface = random.next() % 2 == 0 ? lookup.surfaceID : nil
            expectIdentity(history.identity(surfaceID: surface, bufferID: lookup.bufferID),
                           reference.identity(surfaceID: surface, bufferID: lookup.bufferID),
                           "seed \(seed), step \(step), lookup")
            let query = random.identity()
            let direction = [-1, 0, 1][Int(random.next() % 3)]
            expectTime(history.adjacentTime(to: query, direction: direction),
                       reference.adjacentTime(to: query, direction: direction),
                       "seed \(seed), step \(step), adjacent")
        }
    }
}

private struct HistoryRandom {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9e37_79b9_7f4a_7c15
        var value = state
        value = (value ^ (value >> 30)) &* 0xbf58_476d_1ce4_e5b9
        value = (value ^ (value >> 27)) &* 0x94d0_49bb_1331_11eb
        return value ^ (value >> 31)
    }
    mutating func identity() -> Identity {
        let surfaceChoice = next() % 32
        let surface: UInt32? = surfaceChoice % 4 == 0 ? nil
            : surfaceChoice == 31 ? UInt32.max : UInt32(surfaceChoice)
        let bufferChoice = next() % 48
        let buffer: UInt = bufferChoice == 47 ? UInt.max : UInt(bufferChoice)
        let selector = next() % 16
        let time: Double
        switch selector {
        case 0: time = Double(bitPattern: 0x7ff8_0000_0000_0000 | (next() & 255))
        case 1: time = .infinity
        case 2: time = -.infinity
        case 3: time = -0.0
        case 4: time = 0.0
        default:
            time = Double(Int(next() % 401) - 200) / 10
                + [0.0, 0.000001, -0.000001][Int(next() % 3)]
        }
        return Identity(surfaceID: surface, bufferID: buffer, time: time, generation: Int(next() % 4))
    }
}
