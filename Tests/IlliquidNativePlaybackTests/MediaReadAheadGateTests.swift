import Foundation
import Testing
@testable import IlliquidNativePlayback

private final class ReadAheadResultBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func store(_ value: Value) {
        lock.lock()
        self.value = value
        lock.unlock()
    }
    func load() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private final class ReadAheadWorker: @unchecked Sendable {
    let name: String
    private let started = DispatchSemaphore(value: 0)
    private let finished = DispatchGroup()
    private let resultBox = ReadAheadResultBox<Bool?>(nil)

    init(_ name: String, body: @escaping @Sendable () -> Bool) {
        self.name = name
        finished.enter()
        Thread.detachNewThread { [self] in
            started.signal()
            resultBox.store(body())
            finished.leave()
        }
    }

    var result: Bool? { resultBox.load() }
    var isFinished: Bool { finished.wait(timeout: .now()) == .success }
    func waitUntilStarted() -> Bool { started.wait(timeout: .now() + 5) == .success }
    func join(until deadline: DispatchTime = .now() + 5) -> Bool {
        finished.wait(timeout: deadline) == .success
    }
}

private func readAheadReader(
    _ gate: MediaReadAheadGate,
    timestamp: TimeInterval?,
    generation: Int = 0,
    name: String = "reader"
) -> ReadAheadWorker {
    ReadAheadWorker(name) { gate.wait(until: timestamp, generation: generation) }
}

private func closeAndJoin(_ gate: MediaReadAheadGate, workers: [ReadAheadWorker]) {
    gate.close()
    let deadline = DispatchTime.now() + 5
    for worker in workers {
        #expect(worker.join(until: deadline), "\(worker.name) did not stop during cleanup")
    }
}

private func expectFinished(_ worker: ReadAheadWorker, result: Bool) throws {
    try #require(worker.join(), "\(worker.name) did not finish")
    #expect(worker.result == result, "Unexpected result from \(worker.name)")
}

/// Run even immediate admissions on a worker so a regression cannot hang the
/// test thread inside the gate.
private func expectAdmission(
    _ gate: MediaReadAheadGate,
    timestamp: TimeInterval?,
    generation: Int = 0,
    result: Bool = true
) throws {
    let worker = readAheadReader(gate, timestamp: timestamp, generation: generation)
    defer {
        if !worker.isFinished { closeAndJoin(gate, workers: [worker]) }
    }
    try expectFinished(worker, result: result)
}

@Suite("Media read-ahead gate", .serialized)
struct MediaReadAheadGateTests {
    @Test func immediatelyAdmitsEligibleTimestamps() throws {
        let gate = MediaReadAheadGate(lookahead: 30)
        defer { gate.close() }
        for timestamp in [-10.0, 0, 10, 30] {
            try expectAdmission(gate, timestamp: timestamp)
        }
        #expect(gate.currentPosition == 0)
        gate.update(position: 10)
        try expectAdmission(gate, timestamp: 40)
    }

    @Test func updatesIgnoreNonfiniteAndNonincreasingPositions() {
        let gate = MediaReadAheadGate()
        defer { gate.close() }
        gate.update(position: 7.5)
        for position in [7.5, 7, -10, Double.nan, .infinity, -.infinity] {
            gate.update(position: position)
            #expect(gate.currentPosition == 7.5)
        }
        gate.update(position: 8)
        #expect(gate.currentPosition == 8)
    }

    @Test func resetSanitizesPositionsAndRejectsOldGenerations() throws {
        let gate = MediaReadAheadGate(lookahead: 0)
        defer { gate.close() }
        for (index, position) in [Double.nan, .infinity, -.infinity, -10].enumerated() {
            let generation = index + 1
            gate.reset(generation: generation, position: position)
            #expect(gate.currentPosition == 0)
            try expectAdmission(gate, timestamp: 0, generation: generation)
            try expectAdmission(gate, timestamp: 0, generation: generation - 1, result: false)
        }
        gate.reset(generation: 99, position: 12.5)
        #expect(gate.currentPosition == 12.5)
        try expectAdmission(gate, timestamp: 12.5, generation: 99)
    }

    @Test func negativeLookaheadBecomesZero() throws {
        let gate = MediaReadAheadGate(lookahead: -5)
        let reader = readAheadReader(gate, timestamp: 1)
        defer { closeAndJoin(gate, workers: [reader]) }
        try #require(reader.waitUntilStarted())
        try #require(gate.waitForBlockedReader(timeout: 5))
        gate.update(position: Double(1).nextDown)
        #expect(reader.result == nil)
        gate.update(position: 1)
        try expectFinished(reader, result: true)
    }

    @Test func exactLookaheadBoundaryReleasesReader() throws {
        let gate = MediaReadAheadGate(lookahead: 10)
        let reader = readAheadReader(gate, timestamp: 40)
        defer { closeAndJoin(gate, workers: [reader]) }
        try #require(reader.waitUntilStarted())
        try #require(gate.waitForBlockedReader(timeout: 5))
        // A representable gap that remains below 40 after adding 10.
        gate.update(position: 29)
        #expect(reader.result == nil)
        gate.update(position: 30)
        try expectFinished(reader, result: true)
    }

    @Test func eofIgnoresProgressUntilGenerationReset() throws {
        let gate = MediaReadAheadGate(lookahead: 10)
        let reader = readAheadReader(gate, timestamp: nil, name: "EOF reader")
        defer { closeAndJoin(gate, workers: [reader]) }
        try #require(reader.waitUntilStarted())
        try #require(gate.waitForBlockedReader(timeout: 5))
        for position in [1.0, 30, 300, Double.greatestFiniteMagnitude] {
            gate.update(position: position)
            #expect(reader.result == nil)
        }
        gate.reset(generation: 1, position: 5)
        try expectFinished(reader, result: false)
        try expectAdmission(gate, timestamp: 15, generation: 1)
    }

    @Test func closeReleasesFiniteAndEOFReadersAndDoesNotReopen() throws {
        let gate = MediaReadAheadGate(lookahead: 10)
        let workers = [
            readAheadReader(gate, timestamp: 1_000, name: "finite reader"),
            readAheadReader(gate, timestamp: nil, name: "EOF reader"),
        ]
        defer { closeAndJoin(gate, workers: workers) }
        for worker in workers { try #require(worker.waitUntilStarted()) }
        try #require(gate.waitForBlockedReader(timeout: 5))
        gate.close()
        for worker in workers { try expectFinished(worker, result: false) }
        try expectAdmission(gate, timestamp: nil, result: false)
        gate.reset(generation: 1, position: 10)
        try expectAdmission(gate, timestamp: 0, generation: 1, result: false)
    }

    @Test func sameGenerationResetRechecksNewPosition() throws {
        let gate = MediaReadAheadGate(lookahead: 5)
        gate.reset(generation: 7, position: 10)
        let reader = readAheadReader(gate, timestamp: 30, generation: 7)
        defer { closeAndJoin(gate, workers: [reader]) }
        try #require(reader.waitUntilStarted())
        try #require(gate.waitForBlockedReader(timeout: 5))
        gate.reset(generation: 7, position: 0)
        #expect(gate.currentPosition == 0)
        #expect(reader.result == nil)
        gate.update(position: 24)
        #expect(reader.result == nil)
        gate.reset(generation: 7, position: 25)
        try expectFinished(reader, result: true)
    }

    @Test func differentDeadlinesAndEOFStayIndependent() throws {
        let gate = MediaReadAheadGate(lookahead: 10)
        let early = readAheadReader(gate, timestamp: 40, name: "early reader")
        let later = readAheadReader(gate, timestamp: 50, name: "later reader")
        let eof = readAheadReader(gate, timestamp: nil, name: "EOF reader")
        let workers = [early, later, eof]
        defer { closeAndJoin(gate, workers: workers) }
        for worker in workers { try #require(worker.waitUntilStarted()) }
        try #require(gate.waitForBlockedReader(timeout: 5))
        gate.update(position: 30)
        try expectFinished(early, result: true)
        #expect(later.result == nil)
        #expect(eof.result == nil)
        gate.update(position: 40)
        try expectFinished(later, result: true)
        #expect(eof.result == nil)
        gate.reset(generation: 1, position: 0)
        try expectFinished(eof, result: false)
    }

    @Test func sameDeadlineReleasesAllReaders() throws {
        let gate = MediaReadAheadGate(lookahead: 10)
        let workers = (0..<8).map { index in
            readAheadReader(gate, timestamp: 40, name: "reader \(index)")
        }
        defer { closeAndJoin(gate, workers: workers) }
        for worker in workers { try #require(worker.waitUntilStarted()) }
        try #require(gate.waitForBlockedReader(timeout: 5))
        gate.update(position: 30)
        for worker in workers { try expectFinished(worker, result: true) }
    }

    @Test func arrivalsConcurrentWithBroadcastsDoNotMissProgress() throws {
        for iteration in 0..<32 {
            let gate = MediaReadAheadGate(lookahead: 0)
            let releaseLater = DispatchSemaphore(value: 0)
            let early = readAheadReader(gate, timestamp: 1, name: "early \(iteration)")
            let later = ReadAheadWorker("arrival \(iteration)") {
                guard releaseLater.wait(timeout: .now() + 5) == .success else { return false }
                return gate.wait(until: 2, generation: 0)
            }
            defer {
                releaseLater.signal()
                closeAndJoin(gate, workers: [early, later])
            }
            try #require(early.waitUntilStarted())
            try #require(later.waitUntilStarted())
            try #require(gate.waitForBlockedReader(timeout: 5))
            // Arrival may register before, between, or after these updates,
            // while the earlier reader can still be resuming from a broadcast.
            releaseLater.signal()
            gate.update(position: 1)
            gate.update(position: 2)
            try expectFinished(early, result: true)
            try expectFinished(later, result: true)
        }
    }

    @Test func blockedReaderNotifiesObservers() throws {
        let gate = MediaReadAheadGate()
        var workers: [ReadAheadWorker] = []
        defer { closeAndJoin(gate, workers: workers) }
        for index in 0..<3 {
            workers.append(ReadAheadWorker("observer \(index)") {
                gate.waitForBlockedReader(timeout: 5)
            })
        }
        for observer in workers {
            try #require(observer.waitUntilStarted())
            #expect(observer.result == nil)
        }
        let reader = readAheadReader(gate, timestamp: 100, name: "observed reader")
        workers.append(reader)
        try #require(reader.waitUntilStarted())
        for observer in workers.dropLast() { try expectFinished(observer, result: true) }
        gate.close()
        try expectFinished(reader, result: false)
    }

    @Test func closeReleasesObserverWithoutReader() throws {
        let gate = MediaReadAheadGate()
        let observer = ReadAheadWorker("observer") {
            gate.waitForBlockedReader(timeout: 5)
        }
        defer { closeAndJoin(gate, workers: [observer]) }
        try #require(observer.waitUntilStarted())
        gate.close()
        try expectFinished(observer, result: false)
    }

    @Test func infiniteTimestampAdmitsOnlyWhenHorizonReachesIt() throws {
        do {
            let gate = MediaReadAheadGate(lookahead: 10)
            defer { gate.close() }
            try expectAdmission(gate, timestamp: .nan)
            try expectAdmission(gate, timestamp: -.infinity)
            let reader = readAheadReader(gate, timestamp: .infinity)
            defer { closeAndJoin(gate, workers: [reader]) }
            try #require(reader.waitUntilStarted())
            try #require(gate.waitForBlockedReader(timeout: 5))
            gate.update(position: Double.greatestFiniteMagnitude)
            #expect(reader.result == nil)
            gate.close()
            try expectFinished(reader, result: false)
        }
        do {
            let gate = MediaReadAheadGate(lookahead: Double.greatestFiniteMagnitude)
            let reader = readAheadReader(gate, timestamp: .infinity)
            defer { closeAndJoin(gate, workers: [reader]) }
            try #require(reader.waitUntilStarted())
            try #require(gate.waitForBlockedReader(timeout: 5))
            // Two finite operands can produce an infinite horizon.
            gate.update(position: Double.greatestFiniteMagnitude)
            try expectFinished(reader, result: true)
        }
        do {
            let gate = MediaReadAheadGate(lookahead: .infinity)
            defer { gate.close() }
            try expectAdmission(gate, timestamp: .infinity)
        }
    }
}
