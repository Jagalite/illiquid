import Foundation

/// Bounds the worker-to-main-actor backlog for one watcher generation.
/// All state is protected by lock. The caller schedules a delivery only when
/// enqueue returns true, then calls take on that delivery's main-actor turn.
final class SourceFilesystemEventMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: SourceFilesystemEventBuffer
    private var deliveryPending = false
    private var stopped = false

    init(maximumCount: Int = 4096) {
        buffer = SourceFilesystemEventBuffer(maximumCount: maximumCount)
    }

    /// Coalesce pending callbacks without capturing their arrays in more tasks.
    /// Overflow uses the existing all-root event-loss recovery policy.
    func enqueue(_ events: [SourceFilesystemEvent]) -> Bool {
        lock.withLock {
            guard !stopped, !events.isEmpty else { return false }
            buffer.append(contentsOf: events)
            guard !deliveryPending else { return false }
            deliveryPending = true
            return true
        }
    }

    func take() -> [SourceFilesystemEvent] {
        lock.withLock {
            // Admission and wakeup ownership change atomically: an event racing
            // this drain either joins its batch or schedules the next delivery.
            deliveryPending = false
            return buffer.take()
        }
    }

    /// Terminal for this generation. Release paths even if its queued task
    /// cannot run yet; a restart gets a new mailbox.
    func stop() {
        lock.withLock {
            stopped = true
            buffer.removeAll()
        }
    }
}
