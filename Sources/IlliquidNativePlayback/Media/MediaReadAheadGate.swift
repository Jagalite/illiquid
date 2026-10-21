import Foundation

/// Playback-relative input backpressure. A nil timestamp represents EOF and
/// waits for a seek or close, rather than periodically waking a finished reader.
final class MediaReadAheadGate: @unchecked Sendable {
    private let condition = NSCondition()
    private let lookahead: TimeInterval
    private var generation = 0
    private var position: TimeInterval = 0
    private var closed = false
    private var waitingReaders = 0
    private var waitingObservers = 0
    private var earliestWaitingTimestamp: TimeInterval?

    init(lookahead: TimeInterval = 30) { self.lookahead = max(0, lookahead) }

    func update(position: TimeInterval) {
        guard position.isFinite else { return }
        condition.lock()
        if position > self.position {
            self.position = position
            if let earliestWaitingTimestamp,
               earliestWaitingTimestamp <= position + lookahead {
                // Signaled readers remain runnable if another update arrives
                // first. Those still blocked re-register under this same lock.
                self.earliestWaitingTimestamp = nil
                condition.broadcast()
            }
        }
        condition.unlock()
    }

    var currentPosition: TimeInterval {
        condition.lock()
        defer { condition.unlock() }
        return position
    }

    func reset(generation: Int, position: TimeInterval) {
        condition.lock()
        self.generation = generation
        self.position = position.isFinite ? max(0, position) : 0
        earliestWaitingTimestamp = nil
        condition.broadcast()
        condition.unlock()
    }

    @discardableResult
    func wait(until timestamp: TimeInterval?, generation: Int) -> Bool {
        condition.lock()
        var registeredReader = false
        defer {
            if registeredReader { waitingReaders -= 1 }
            condition.unlock()
        }
        while !closed, self.generation == generation,
              timestamp == nil || timestamp! > position + lookahead {
            if !registeredReader {
                registeredReader = true
                waitingReaders += 1
                if waitingObservers > 0 { condition.broadcast() }
            }
            if let timestamp {
                earliestWaitingTimestamp = min(
                    earliestWaitingTimestamp ?? timestamp, timestamp
                )
            }
            condition.wait()
        }
        return !closed && self.generation == generation
    }

    func waitForBlockedReader(timeout: TimeInterval) -> Bool {
        condition.lock()
        waitingObservers += 1
        defer {
            waitingObservers -= 1
            condition.unlock()
        }
        let deadline = Date().addingTimeInterval(timeout)
        while waitingReaders == 0, !closed {
            guard condition.wait(until: deadline) else { break }
        }
        return waitingReaders > 0
    }

    func close() {
        condition.lock()
        closed = true
        earliestWaitingTimestamp = nil
        condition.broadcast()
        condition.unlock()
    }
}
