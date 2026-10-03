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

    init(lookahead: TimeInterval = 30) { self.lookahead = max(0, lookahead) }

    func update(position: TimeInterval) {
        guard position.isFinite else { return }
        condition.lock()
        if position > self.position {
            self.position = position
            condition.broadcast()
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
        condition.broadcast()
        condition.unlock()
    }

    @discardableResult
    func wait(until timestamp: TimeInterval?, generation: Int) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        while !closed, self.generation == generation,
              timestamp == nil || timestamp! > position + lookahead {
            waitingReaders += 1
            condition.broadcast()
            condition.wait()
            waitingReaders -= 1
        }
        return !closed && self.generation == generation
    }

    func waitForBlockedReader(timeout: TimeInterval) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while waitingReaders == 0, !closed {
            guard condition.wait(until: deadline) else { break }
        }
        return waitingReaders > 0
    }

    func close() {
        condition.lock()
        closed = true
        condition.broadcast()
        condition.unlock()
    }
}
