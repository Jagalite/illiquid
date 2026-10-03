import Foundation

struct VideoFrameCapacitySnapshot: Equatable, Sendable {
    let capacity: Int
    let inUse: Int
    let peakInUse: Int
    let waitingAcquisitions: Int
}

/// Bounds decoded-frame pipeline ownership before a software output surface is
/// checked out. The queue alone cannot provide that guarantee because decoding
/// allocates the next frame before `BoundedQueue.push` can apply backpressure.
final class VideoFrameCapacityGate: @unchecked Sendable {
    private let condition = NSCondition()
    private let capacity: Int
    private var inUse = 0
    private var peakInUse = 0
    private var waitingAcquisitions = 0
    private var closed = false

    init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    func acquire(
        while shouldContinue: () -> Bool
    ) -> VideoFrameCapacityPermit? {
        condition.lock()
        defer { condition.unlock() }

        while inUse >= capacity, !closed {
            guard shouldContinue() else { return nil }
            waitingAcquisitions += 1
            condition.wait()
            waitingAcquisitions -= 1
        }
        guard !closed, shouldContinue() else { return nil }
        inUse += 1
        peakInUse = max(peakInUse, inUse)
        return VideoFrameCapacityPermit(gate: self)
    }

    var snapshot: VideoFrameCapacitySnapshot {
        condition.withLock {
            VideoFrameCapacitySnapshot(
                capacity: capacity,
                inUse: inUse,
                peakInUse: peakInUse,
                waitingAcquisitions: waitingAcquisitions
            )
        }
    }

    func close() {
        condition.withLock {
            closed = true
            condition.broadcast()
        }
    }

    fileprivate func release() {
        condition.withLock {
            precondition(inUse > 0)
            inUse -= 1
            condition.broadcast()
        }
    }
}

final class VideoFrameCapacityPermit: @unchecked Sendable {
    private let gate: VideoFrameCapacityGate

    fileprivate init(gate: VideoFrameCapacityGate) {
        self.gate = gate
    }

    deinit { gate.release() }
}

private extension NSCondition {
    func withLock<Result>(_ body: () -> Result) -> Result {
        lock()
        defer { unlock() }
        return body()
    }
}
