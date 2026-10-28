import Foundation
import Testing
@testable import IlliquidNativePlayback

@Suite("Read-ahead admission and lifetime", .serialized)
struct MediaReadAheadGateTests {
    private final class Result<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Value
        init(_ value: Value) { self.value = value }
        func set(_ value: Value) { lock.withLock { self.value = value } }
        func get() -> Value { lock.withLock { value } }
    }

    private final class Reader: @unchecked Sendable {
        let done = DispatchGroup()
        let result = Result<Bool?>(nil)

        init(_ gate: MediaReadAheadGate, timestamp: TimeInterval?, generation: Int = 0) {
            done.enter()
            DispatchQueue(label: "read-ahead.reader.\(UUID())").async { [self] in
                result.set(gate.wait(until: timestamp, generation: generation))
                done.leave()
            }
        }

        func finished(after seconds: TimeInterval = 2) -> Bool {
            done.wait(timeout: .now() + seconds) == .success
        }
    }

    @Test func eligibleAndInvalidGenerationCallsDoNotBlock() {
        let gate = MediaReadAheadGate(lookahead: 10)
        #expect(gate.wait(until: 10, generation: 0))
        #expect(gate.wait(until: -10, generation: 0))
        #expect(gate.wait(until: .nan, generation: 0))
        #expect(gate.wait(until: -.infinity, generation: 0))
        #expect(!gate.wait(until: nil, generation: 1))
        gate.close()
        #expect(!gate.wait(until: 0, generation: 0))
        #expect(!gate.wait(until: nil, generation: 0))
    }

    @Test func positionAdvancesMonotonicallyUntilReset() {
        let gate = MediaReadAheadGate(lookahead: -10)
        for position in [5.0, 4, .nan, .infinity, -.infinity, -1] {
            gate.update(position: position)
        }
        #expect(gate.currentPosition == 5)
        #expect(gate.wait(until: 5, generation: 0))
        gate.reset(generation: 1, position: -4)
        #expect(gate.currentPosition == 0)
        gate.reset(generation: 2, position: .nan)
        #expect(gate.currentPosition == 0)
        gate.reset(generation: 3, position: .infinity)
        #expect(gate.currentPosition == 0)
    }

    @Test func exactLookaheadBoundaryReleasesReader() throws {
        let gate = MediaReadAheadGate(lookahead: 10)
        let reader = Reader(gate, timestamp: 40)
        defer { gate.close(); _ = reader.finished() }
        try #require(gate.waitForBlockedReader(timeout: 2))
        // Use a representable value whose addition remains below the boundary.
        gate.update(position: 29.999)
        #expect(!reader.finished(after: 0.01))
        gate.update(position: 30)
        try #require(reader.finished())
        #expect(reader.result.get() == true)
    }

    @Test func roundedSumUsesTheOriginalAdmissionBoundary() throws {
        let gate = MediaReadAheadGate(lookahead: 10)
        let reader = Reader(gate, timestamp: 40)
        defer { gate.close(); _ = reader.finished() }
        try #require(gate.waitForBlockedReader(timeout: 2))
        let position = Double(30).nextDown
        #expect(position < 40 - 10)
        #expect(position + 10 == 40)
        gate.update(position: position)
        try #require(reader.finished())
        #expect(reader.result.get() == true)
    }

    @Test func eofIgnoresProgressAndSameGenerationReset() throws {
        let gate = MediaReadAheadGate()
        let reader = Reader(gate, timestamp: nil)
        defer { gate.close(); _ = reader.finished() }
        try #require(gate.waitForBlockedReader(timeout: 2))
        for step in 1...240 { gate.update(position: Double(step) / 4) }
        gate.reset(generation: 0, position: 600)
        #expect(!reader.finished(after: 0.01))
        gate.reset(generation: 1, position: 5)
        try #require(reader.finished())
        #expect(reader.result.get() == false)
    }

    @Test func sameGenerationResetRecomputesEligibility() throws {
        let gate = MediaReadAheadGate(lookahead: 10)
        gate.update(position: 20)
        let reader = Reader(gate, timestamp: 50)
        defer { gate.close(); _ = reader.finished() }
        try #require(gate.waitForBlockedReader(timeout: 2))
        gate.reset(generation: 0, position: 5)
        gate.update(position: 39)
        #expect(!reader.finished(after: 0.01))
        gate.reset(generation: 0, position: 40)
        try #require(reader.finished())
        #expect(reader.result.get() == true)
    }

    @Test func independentDeadlinesAndEOFRemainIndependent() throws {
        let gate = MediaReadAheadGate(lookahead: 10)
        let first = Reader(gate, timestamp: 40)
        let second = Reader(gate, timestamp: 80)
        let eof = Reader(gate, timestamp: nil)
        defer { gate.close(); for reader in [first, second, eof] { _ = reader.finished() } }
        try #require(gate.waitForBlockedReader(timeout: 2))
        gate.update(position: 30)
        try #require(first.finished())
        #expect(first.result.get() == true)
        #expect(!second.finished(after: 0.01))
        #expect(!eof.finished(after: 0.01))
        gate.update(position: 70)
        try #require(second.finished())
        #expect(second.result.get() == true)
        #expect(!eof.finished(after: 0.01))
        gate.close()
        try #require(eof.finished())
        #expect(eof.result.get() == false)
    }

    @Test func consecutiveUpdatesDoNotLoseLaterDeadlines() throws {
        // The second update may arrive before readers signaled by the first
        // can re-acquire the condition lock and register their next threshold.
        for _ in 0..<40 {
            let gate = MediaReadAheadGate(lookahead: 0)
            let readers = [Reader(gate, timestamp: 1), Reader(gate, timestamp: 2)]
            defer { gate.close(); for reader in readers { _ = reader.finished() } }
            try #require(gate.waitForBlockedReader(timeout: 2))
            gate.update(position: 1)
            gate.update(position: 2)
            for reader in readers {
                try #require(reader.finished())
                #expect(reader.result.get() == true)
            }
        }
    }

    @Test func seekRejectsOldWaitersAndAdmitsNewGeneration() throws {
        for iteration in 0..<20 {
            let gate = MediaReadAheadGate(lookahead: 10)
            let old = Reader(gate, timestamp: iteration.isMultiple(of: 2) ? nil : 100)
            defer { gate.close(); _ = old.finished() }
            try #require(gate.waitForBlockedReader(timeout: 2))
            gate.reset(generation: 1, position: 0)
            let current = Reader(gate, timestamp: 50, generation: 1)
            defer { gate.close(); _ = current.finished() }
            gate.update(position: 40)
            try #require(old.finished())
            try #require(current.finished())
            #expect(old.result.get() == false)
            #expect(current.result.get() == true)
        }
    }

    @Test func resetThenProgressCannotStrandRearmedReader() throws {
        for _ in 0..<40 {
            let gate = MediaReadAheadGate(lookahead: 0)
            let reader = Reader(gate, timestamp: 50)
            defer { gate.close(); _ = reader.finished() }
            try #require(gate.waitForBlockedReader(timeout: 2))
            gate.reset(generation: 0, position: 10)
            gate.update(position: 50)
            try #require(reader.finished())
            #expect(reader.result.get() == true)
        }
    }

    @Test func overflowedFrontierKeepsOriginalComparisonSemantics() throws {
        let gate = MediaReadAheadGate(lookahead: .greatestFiniteMagnitude)
        let reader = Reader(gate, timestamp: .infinity)
        defer { gate.close(); _ = reader.finished() }
        try #require(gate.waitForBlockedReader(timeout: 2))
        gate.update(position: .greatestFiniteMagnitude)
        try #require(reader.finished())
        #expect(reader.result.get() == true)
    }

    @Test func infiniteTimestampStillWaitsAgainstFiniteFrontier() throws {
        let gate = MediaReadAheadGate(lookahead: 0)
        let reader = Reader(gate, timestamp: .infinity)
        defer { gate.close(); _ = reader.finished() }
        try #require(gate.waitForBlockedReader(timeout: 2))
        gate.update(position: .greatestFiniteMagnitude)
        #expect(!reader.finished(after: 0.01))
        gate.close()
        try #require(reader.finished())
        #expect(reader.result.get() == false)
    }

    @Test func closeReleasesAllKindsOfWaiter() throws {
        let gate = MediaReadAheadGate()
        let readers = (0..<8).map { index in
            Reader(gate, timestamp: index.isMultiple(of: 2) ? nil : 10_000)
        }
        defer { gate.close(); for reader in readers { _ = reader.finished() } }
        try #require(gate.waitForBlockedReader(timeout: 2))
        gate.close()
        for reader in readers {
            try #require(reader.finished())
            #expect(reader.result.get() == false)
        }
    }

    @Test func diagnosticObserversAreReleasedByReaderAndClose() throws {
        for closeWithoutReader in [false, true] {
            let gate = MediaReadAheadGate()
            let started = DispatchSemaphore(value: 0)
            let done = DispatchGroup()
            let results = (0..<4).map { _ in Result(false) }
            for result in results {
                done.enter()
                DispatchQueue(label: "read-ahead.observer.\(UUID())").async {
                    started.signal()
                    result.set(gate.waitForBlockedReader(timeout: 2))
                    done.leave()
                }
            }
            defer { gate.close(); _ = done.wait(timeout: .now() + 3) }
            for _ in results { try #require(started.wait(timeout: .now() + 2) == .success) }
            let reader: Reader?
            if closeWithoutReader { reader = nil; gate.close() }
            else { reader = Reader(gate, timestamp: nil) }
            defer { gate.close(); _ = reader?.finished() }
            try #require(done.wait(timeout: .now() + 3) == .success)
            for result in results { #expect(result.get() == !closeWithoutReader) }
        }
    }

    @Test func diagnosticObserverTimeoutDoesNotAffectLaterReader() throws {
        let gate = MediaReadAheadGate(lookahead: 0)
        #expect(!gate.waitForBlockedReader(timeout: 0.001))
        let reader = Reader(gate, timestamp: 1)
        defer { gate.close(); _ = reader.finished() }
        try #require(gate.waitForBlockedReader(timeout: 2))
        gate.update(position: 1)
        try #require(reader.finished())
        #expect(reader.result.get() == true)
    }
}
