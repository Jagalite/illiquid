import Testing
@testable import IlliquidNativePlayback

@Suite("Submitted video frame identity history")
struct VideoFrameIdentityHistoryTests {
    private typealias Identity = VideoFrameIdentityHistory.Identity

    @Test func emptyHistoryAndRepeatedFlushesHaveNoMatches() {
        var history = VideoFrameIdentityHistory()
        #expect(history.count == 0)
        #expect(history.identity(surfaceID: nil, bufferID: 1) == nil)
        #expect(history.identity(surfaceID: 1, bufferID: 1) == nil)
        #expect(history.adjacentTime(to: frame(0), direction: 1) == nil)
        #expect(history.adjacentTime(to: frame(0), direction: 0) == nil)
        history.removeAll()
        history.removeAll()
        #expect(history.count == 0)
    }

    @Test func onlyTheLatest128SubmissionsSurviveRepeatedWraps() {
        var history = VideoFrameIdentityHistory()
        let total = 128 * 3 + 17
        for index in 0..<total {
            history.append(frame(Double(index), surface: UInt32(index + 1), buffer: UInt(index + 1)))
            #expect(history.count == min(index + 1, 128))
        }
        for index in 0..<total {
            let expected = index < total - 128 ? nil
                : frame(Double(index), surface: UInt32(index + 1), buffer: UInt(index + 1))
            #expect(history.identity(surfaceID: UInt32(index + 1), bufferID: 0) == expected)
            #expect(history.identity(surfaceID: nil, bufferID: UInt(index + 1)) == expected)
        }
    }

    @Test func newestMatchingIdentityWinsAcrossWrapAndGenerationChanges() {
        var history = VideoFrameIdentityHistory()
        for index in 0..<126 {
            history.append(frame(Double(index), surface: 90, buffer: 90))
        }
        let old = frame(100, surface: 1, buffer: 10, generation: 1)
        let other = frame(10, surface: 2, buffer: 20, generation: 2)
        let newestSurface = frame(1, surface: 1, buffer: 30, generation: 3)
        let newestBuffer = frame(-10, surface: nil, buffer: 20, generation: 4)
        for value in [old, other, newestSurface, newestBuffer] { history.append(value) }

        #expect(history.identity(surfaceID: 1, bufferID: 20) == newestSurface)
        #expect(history.identity(surfaceID: 2, bufferID: 20) == other)
        #expect(history.identity(surfaceID: nil, bufferID: 20) == newestBuffer)
        #expect(history.identity(surfaceID: nil, bufferID: 30) == newestSurface)
        #expect(history.identity(surfaceID: 999, bufferID: 20) == nil)
        #expect(history.identity(surfaceID: nil, bufferID: 999) == nil)
    }

    @Test func adjacencyUsesTimestampExtremaWithinTheGenerationAndStrictTolerance() {
        var history = VideoFrameIdentityHistory()
        let query = frame(5, generation: 3)
        for time in [8, 5, 7, 3, 10, 5 + 0.0000005, 5 - 0.0000005,
                     5 + 0.000001, 5 - 0.000001, 7, 3] {
            history.append(frame(time, generation: 3))
        }
        history.append(frame(5.1, generation: 4))
        history.append(frame(4.9, generation: 4))

        #expect(history.adjacentTime(to: query, direction: 1) == 7)
        #expect(history.adjacentTime(to: query, direction: 99) == 7)
        #expect(history.adjacentTime(to: query, direction: -1) == 3)
        #expect(history.adjacentTime(to: query, direction: 0) == 3)
        #expect(history.adjacentTime(to: frame(5, generation: 99), direction: 1) == nil)
        #expect(history.adjacentTime(to: frame(10, generation: 3), direction: 1) == nil)
        #expect(history.adjacentTime(to: frame(3, generation: 3), direction: -1) == nil)
    }

    @Test func adjacencyPreservesSignedZeroTieOrderAfterWrapping() {
        var history = VideoFrameIdentityHistory()
        for _ in 0..<127 { history.append(frame(200, generation: 9)) }
        history.append(frame(-Double.zero))
        history.append(frame(Double.zero))

        #expect(history.adjacentTime(to: frame(-1), direction: 1)?.bitPattern == (-Double.zero).bitPattern)
        #expect(history.adjacentTime(to: frame(1), direction: -1)?.bitPattern == (-Double.zero).bitPattern)
    }

    @Test func nonfiniteTimesMatchTheExistingArrayReduction() {
        var history = VideoFrameIdentityHistory()
        var oracle = ArrayOracle()
        for time in [Double.nan, .infinity, -.infinity, 1, -1, -Double.zero, 0] {
            let value = frame(time)
            history.append(value)
            oracle.append(value)
        }
        for time in [Double.nan, .infinity, -.infinity, -2, -1, 0, 1, 2] {
            for direction in [-1, 0, 1] {
                let query = frame(time)
                #expect(history.adjacentTime(to: query, direction: direction)?.bitPattern
                    == oracle.adjacentTime(to: query, direction: direction)?.bitPattern)
            }
        }
    }

    @Test func flushAfterWrappingClearsAllMatchesAndRefillsInSubmissionOrder() {
        var history = VideoFrameIdentityHistory()
        for index in 0..<200 {
            history.append(frame(Double(index), surface: 7, buffer: 7))
        }
        history.removeAll()
        #expect(history.count == 0)
        #expect(history.identity(surfaceID: 7, bufferID: 7) == nil)
        #expect(history.adjacentTime(to: frame(0), direction: 1) == nil)
        let first = frame(20, surface: 8, buffer: 8)
        let last = frame(10, surface: 8, buffer: 8)
        history.append(first)
        history.append(last)
        #expect(history.count == 2)
        #expect(history.identity(surfaceID: 8, bufferID: 8) == last)
        #expect(history.identity(surfaceID: nil, bufferID: 7) == nil)
        #expect(history.adjacentTime(to: last, direction: 1) == first.time)
    }

    @Test(arguments: [UInt64(1), 42, 0xDEAD_BEEF_CAFE_1234])
    func mixedOperationsMatchAnIndependentBoundedArray(seed: UInt64) {
        var history = VideoFrameIdentityHistory()
        var oracle = ArrayOracle()
        var random = Random(seed: seed)
        for step in 0..<4_000 {
            let operation = step < 128 * 3 ? 1 : random.index(32)
            if operation == 0 {
                history.removeAll()
                oracle.entries.removeAll()
            } else if operation < 25 {
                let value = frame(Double(random.index(401) - 200) / 10,
                    surface: random.index(3) == 0 ? nil : UInt32(random.index(16)),
                    buffer: UInt(random.index(16)), generation: random.index(4))
                history.append(value)
                oracle.append(value)
            }
            let surface = random.index(3) == 0 ? nil : UInt32(random.index(18))
            let buffer = UInt(random.index(18))
            let query = frame(Double(random.index(401) - 200) / 10, generation: random.index(5))
            let direction = random.index(3) - 1
            #expect(history.count == oracle.entries.count, "seed \(seed), step \(step)")
            #expect(history.identity(surfaceID: surface, bufferID: buffer)
                == oracle.identity(surfaceID: surface, bufferID: buffer), "seed \(seed), step \(step)")
            #expect(history.adjacentTime(to: query, direction: direction)?.bitPattern
                == oracle.adjacentTime(to: query, direction: direction)?.bitPattern,
                "seed \(seed), step \(step)")
        }
    }

    private func frame(_ time: Double, surface: UInt32? = nil, buffer: UInt = 1,
                       generation: Int = 0) -> Identity {
        Identity(surfaceID: surface, bufferID: buffer, time: time, generation: generation)
    }

    /// The old presenter representation and its queries, independent of ring
    /// indexing and the candidate's imperative timestamp reduction.
    private struct ArrayOracle {
        var entries: [Identity] = []

        mutating func append(_ value: Identity) {
            if entries.count == 128 { entries.removeFirst() }
            entries.append(value)
        }

        func identity(surfaceID: UInt32?, bufferID: UInt) -> Identity? {
            entries.last {
                if let surfaceID { return $0.surfaceID == surfaceID }
                return $0.bufferID == bufferID
            }
        }

        func adjacentTime(to frame: Identity, direction: Int) -> Double? {
            let times = entries.lazy.filter { $0.generation == frame.generation }.map(\.time)
            return direction > 0
                ? times.filter { $0 > frame.time + 0.000001 }.min()
                : times.filter { $0 < frame.time - 0.000001 }.max()
        }
    }

    private struct Random {
        var seed: UInt64

        mutating func index(_ upperBound: Int) -> Int {
            seed &+= 0x9E37_79B9_7F4A_7C15
            var value = seed
            value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
            value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
            value ^= value >> 31
            return Int(value % UInt64(upperBound))
        }
    }
}
