import Foundation
import Testing
@testable import IlliquidNativePlayback

@Suite("Media read-ahead admission and retirement", .serialized)
struct MediaReadAheadGateEOFTests {
    // Dedicated queues keep blocking condition waits off Swift's task executor.
    // Completion timeouts detect deadlocks; readiness uses the gate handshake.
    private final class Result: @unchecked Sendable {
        private let lock = NSLock()
        private let done = DispatchGroup()
        private var value: Bool?

        init(_ operation: @escaping @Sendable () -> Bool) {
            done.enter()
            DispatchQueue(label: "read-ahead-test.\(UUID().uuidString)").async { [self] in
                let result = operation()
                lock.lock()
                value = result
                lock.unlock()
                done.leave()
            }
        }

        func completed(timeout: TimeInterval = 5) -> Bool? {
            guard done.wait(timeout: .now() + timeout) == .success else { return nil }
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    private func reader(
        _ gate: MediaReadAheadGate,
        until timestamp: TimeInterval?,
        generation: Int
    ) -> Result {
        Result { gate.wait(until: timestamp, generation: generation) }
    }

    private func finish(_ gate: MediaReadAheadGate, _ readers: [Result]) {
        gate.close()
        for reader in readers {
            _ = reader.completed()
        }
    }

    @Test func progressWithoutAReaderIsRetainedForLaterAdmission() {
        let gate = MediaReadAheadGate(lookahead: 5)
        gate.reset(generation: 7, position: 10)
        gate.update(position: 40)
        #expect(gate.currentPosition == 40)

        let waiting = reader(gate, until: 45, generation: 7)
        defer { finish(gate, [waiting]) }
        #expect(waiting.completed() == true)
    }

    @Test func timestampBeyondLookaheadBlocksUntilTheInclusiveBoundary() throws {
        let gate = MediaReadAheadGate(lookahead: 5)
        gate.reset(generation: 7, position: 14)
        let waiting = reader(gate, until: 20, generation: 7)
        defer { finish(gate, [waiting]) }

        try #require(gate.waitForBlockedReader(timeout: 5))
        gate.update(position: 15)
        #expect(waiting.completed() == true)
        #expect(gate.currentPosition == 15)
    }

    @Test func negativeLookaheadIsClampedToZero() throws {
        let gate = MediaReadAheadGate(lookahead: -10)
        gate.reset(generation: 3, position: 10)
        let atPosition = reader(gate, until: 10, generation: 3)
        defer { finish(gate, [atPosition]) }
        #expect(atPosition.completed() == true)

        let future = reader(gate, until: 10.5, generation: 3)
        defer { finish(gate, [future]) }
        try #require(gate.waitForBlockedReader(timeout: 5))
        gate.update(position: 10.5)
        #expect(future.completed() == true)
    }

    @Test func backwardEqualAndNonfiniteUpdatesDoNotMoveTheClock() {
        let gate = MediaReadAheadGate(lookahead: 0)
        defer { gate.close() }
        gate.reset(generation: 1, position: 12.5)

        for position in [12.5, 12, -100, Double.nan, .infinity, -.infinity] {
            gate.update(position: position)
            #expect(gate.currentPosition == 12.5)
        }
        gate.update(position: 13)
        gate.update(position: 12.75)
        #expect(gate.currentPosition == 13)
    }

    @Test func resetSanitizesPositionAndCanMoveTheClockBackward() {
        let gate = MediaReadAheadGate()
        defer { gate.close() }

        for position in [-1, -Double.infinity, .infinity, .nan] {
            gate.reset(generation: 1, position: 100)
            gate.reset(generation: 2, position: position)
            #expect(gate.currentPosition == 0)
        }
        gate.reset(generation: 3, position: 100)
        gate.reset(generation: 3, position: 7.25)
        #expect(gate.currentPosition == 7.25)
    }

    @Test func eofOnlyProgressIsRecordedAndGenerationChangeRetiresTheReader() throws {
        let gate = MediaReadAheadGate(lookahead: 0)
        gate.reset(generation: 4, position: 0)
        let eof = reader(gate, until: nil, generation: 4)
        defer { finish(gate, [eof]) }

        try #require(gate.waitForBlockedReader(timeout: 5))
        for position in [1.0, 10, 10_000] {
            gate.update(position: position)
        }
        #expect(gate.currentPosition == 10_000)

        // An unchanged generation does not make EOF admissible.
        gate.reset(generation: 4, position: 20_000)
        #expect(eof.completed(timeout: 0) == nil)
        gate.reset(generation: 5, position: 0)
        #expect(eof.completed() == false)

        gate.update(position: 50)
        let current = reader(gate, until: 60, generation: 5)
        defer { finish(gate, [current]) }
        try #require(gate.waitForBlockedReader(timeout: 5))
        gate.update(position: 60)
        #expect(current.completed() == true)
    }

    @Test func sameGenerationResetCanAdmitATimestampedReader() throws {
        let gate = MediaReadAheadGate(lookahead: 2)
        gate.reset(generation: 9, position: 0)
        let waiting = reader(gate, until: 100, generation: 9)
        defer { finish(gate, [waiting]) }

        try #require(gate.waitForBlockedReader(timeout: 5))
        gate.reset(generation: 9, position: 98)
        #expect(waiting.completed() == true)
    }

    @Test(arguments: [false, true])
    func generationChangeRetiresBlockedWork(eof: Bool) throws {
        let gate = MediaReadAheadGate(lookahead: 0)
        gate.reset(generation: 1, position: 0)
        let waiting = reader(gate, until: eof ? nil : 100, generation: 1)
        defer { finish(gate, [waiting]) }

        try #require(gate.waitForBlockedReader(timeout: 5))
        gate.reset(generation: 2, position: 200)
        #expect(waiting.completed() == false)

        let stale = reader(gate, until: eof ? nil : 0, generation: 1)
        defer { finish(gate, [stale]) }
        #expect(stale.completed() == false)
    }

    @Test func retiringOneTimedReaderDoesNotDisableTheNextNotification() throws {
        let gate = MediaReadAheadGate(lookahead: 0)
        let first = reader(gate, until: 10, generation: 0)
        defer { finish(gate, [first]) }

        try #require(gate.waitForBlockedReader(timeout: 5))
        gate.update(position: 10)
        #expect(first.completed() == true)

        // Completion guarantees that the first registration has retired.
        let next = reader(gate, until: 20, generation: 0)
        defer { finish(gate, [next]) }
        try #require(gate.waitForBlockedReader(timeout: 5))
        gate.update(position: 20)
        #expect(next.completed() == true)
    }

    @Test(arguments: [false, true])
    func closeRetiresBlockedWorkAndResetDoesNotReopen(eof: Bool) throws {
        let gate = MediaReadAheadGate(lookahead: 0)
        let waiting = reader(gate, until: eof ? nil : 100, generation: 0)
        defer { finish(gate, [waiting]) }

        try #require(gate.waitForBlockedReader(timeout: 5))
        gate.close()
        #expect(waiting.completed() == false)

        gate.reset(generation: 1, position: 1_000)
        gate.update(position: 2_000)
        let afterReset = reader(gate, until: eof ? nil : 0, generation: 1)
        defer { finish(gate, [afterReset]) }
        #expect(afterReset.completed() == false)
        #expect(!gate.waitForBlockedReader(timeout: 0))
    }

    @Test func blockedReaderObservationTracksAdmissionAndRetirement() throws {
        let gate = MediaReadAheadGate(lookahead: 0)
        #expect(!gate.waitForBlockedReader(timeout: 0))

        let waiting = reader(gate, until: 1, generation: 0)
        defer { finish(gate, [waiting]) }
        try #require(gate.waitForBlockedReader(timeout: 5))
        #expect(gate.waitForBlockedReader(timeout: 0))

        gate.update(position: 1)
        #expect(waiting.completed() == true)
        #expect(!gate.waitForBlockedReader(timeout: 0))
    }

    @Test func nonfiniteTimestampAdmissionSemanticsRemainUnchanged() throws {
        let gate = MediaReadAheadGate(lookahead: 0)
        let nan = reader(gate, until: .nan, generation: 0)
        defer { finish(gate, [nan]) }
        #expect(nan.completed() == true)

        let negativeInfinity = reader(gate, until: -.infinity, generation: 0)
        defer { finish(gate, [negativeInfinity]) }
        #expect(negativeInfinity.completed() == true)

        // Positive infinity remains a timestamped wait until invalidation.
        let positiveInfinity = reader(gate, until: .infinity, generation: 0)
        defer { finish(gate, [positiveInfinity]) }
        try #require(gate.waitForBlockedReader(timeout: 5))
        gate.close()
        #expect(positiveInfinity.completed() == false)
    }
}
