import Foundation

/// Serializes writes off the caller's executor and retains only the newest
/// pending value. Flush waits for actual storage completion, including errors.
public final class CoalescingPersistenceWriter<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private let queue: DispatchQueue
    private let delay: TimeInterval
    private let write: @Sendable (Value) throws -> Void
    private var pending: Value?
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
        lock.lock()
        pending = value
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
            guard let value = pending else {
                scheduled = false
                lock.unlock()
                return
            }
            pending = nil
            lock.unlock()
            result = Result { try write(value) }
        }
    }
}
