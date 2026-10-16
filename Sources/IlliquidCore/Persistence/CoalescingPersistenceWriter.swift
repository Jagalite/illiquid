import Foundation

/// Serializes writes off the caller's executor and retains only the newest
/// pending value or snapshot factory. Flush waits for write callbacks and reports
/// their errors. The destination defines durability (UserDefaults.set is not fsync).
public final class CoalescingPersistenceWriter<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private let queue: DispatchQueue
    private let delay: TimeInterval
    private let write: @Sendable (Value) throws -> Void
    private enum Pending {
        case value(Value)
        case snapshot(@Sendable () -> Value)
    }
    private var pending: Pending?
    private var scheduled = false
    // Accessed only on queue.
    private var result: Result<Void, Error> = .success(())

    public init(
        label: String,
        delay: TimeInterval = 0.1,
        write: @escaping @Sendable (Value) throws -> Void
    ) {
        queue = DispatchQueue(label: label, qos: .utility)
        self.delay = max(0, delay)
        self.write = write
    }

    public func submit(_ value: Value) {
        enqueue(.value(value))
    }

    /// Coalesce the request before copying a large value-semantic store. The
    /// factory runs on the writer queue, outside the writer lock, immediately
    /// before a write callback. It must return a synchronized, immutable snapshot;
    /// never hold its owner lock during encoding/I/O or call flush from the factory.
    /// Captures stay alive until superseded or drained, just like submitted values.
    /// A flush includes every request submitted before its queue barrier; the
    /// snapshot may also include newer mutations that occurred before capture.
    public func submitSnapshot(_ snapshot: @escaping @Sendable () -> Value) {
        enqueue(.snapshot(snapshot))
    }

    private func enqueue(_ request: Pending) {
        lock.lock()
        pending = request
        let needsSchedule = !scheduled
        scheduled = true
        lock.unlock()
        if needsSchedule {
            queue.asyncAfter(deadline: .now() + delay) { self.drain() }
        }
    }

    public func flush() async -> Result<Void, Error> {
        await withCheckedContinuation { continuation in
            queue.async {
                self.drain()
                continuation.resume(returning: self.result)
            }
        }
    }

    /// For synchronous store clients and tests. Playback uses the async flush.
    public func flushSynchronously() -> Result<Void, Error> {
        queue.sync {
            drain()
            return result
        }
    }

    private func drain() {
        while true {
            lock.lock()
            guard let request = pending else {
                scheduled = false
                lock.unlock()
                return
            }
            pending = nil
            lock.unlock()
            result = Result {
                let value: Value
                switch request {
                case .value(let submitted): value = submitted
                case .snapshot(let snapshot): value = snapshot()
                }
                try write(value)
            }
        }
    }
}
