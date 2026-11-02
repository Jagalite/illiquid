import Foundation

/// Bounds events waiting to reach MainActor, before the sidebar's debounce
/// buffer can admit them. A watch session owns one delivery and closes it on
/// stop; a replacement session never reuses an old delivery's pending work.
final class SourceFilesystemEventDelivery: @unchecked Sendable {
    typealias Handler = @MainActor @Sendable ([SourceFilesystemEvent]) -> Void

    private let lock = NSLock()
    private let handler: Handler
    // All mutable state below is protected by lock. Neither scheduling nor the
    // client handler runs while holding it.
    private var pending: SourceFilesystemEventBuffer
    private var deliveryScheduled = false
    private var closed = false

    init(maximumCount: Int = 4096, handler: @escaping Handler) {
        pending = SourceFilesystemEventBuffer(maximumCount: maximumCount)
        self.handler = handler
    }

    func send(_ events: [SourceFilesystemEvent]) {
        let shouldSchedule = lock.withLock {
            guard !closed, !events.isEmpty else { return false }
            pending.append(contentsOf: events)
            guard !deliveryScheduled else { return false }
            deliveryScheduled = true
            return true
        }
        guard shouldSchedule else { return }
        // Capture only the delivery, never an individual callback's array.
        // A stopped or released owner need not wait for MainActor to run this
        // task before its pending paths can be released.
        Task { @MainActor [weak self] in
            self?.deliver()
        }
    }

    /// Permanently rejects future input and releases queued events. A delivery
    /// that has already started may finish; monitor close and delivery both
    /// execute on MainActor, so stop cannot interleave with that handler.
    func close() {
        lock.withLock {
            closed = true
            pending.removeAll()
        }
    }

    @MainActor private func deliver() {
        let events = lock.withLock {
            deliveryScheduled = false
            return pending.take()
        }
        guard !events.isEmpty else { return }
        handler(events)
    }
}
