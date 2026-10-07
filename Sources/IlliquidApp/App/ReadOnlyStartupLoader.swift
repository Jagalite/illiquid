import Foundation

/// Coalesces one read-only startup operation. Stopping prevents late publication
/// and new work; shutdown need not wait for a non-interruptible preferences read.
@MainActor
final class ReadOnlyStartupLoader<Value: Sendable> {
    private let read: @Sendable () async -> Value
    private var task: Task<Value, Never>?
    private var cached: Value?
    private var stopped = false

    init(read: @escaping @Sendable () async -> Value) { self.read = read }

    func load() async -> Value? {
        guard !stopped else { return nil }
        if let cached { return cached }
        let pending: Task<Value, Never>
        if let task { pending = task }
        else {
            pending = Task { await read() }
            task = pending
        }
        let value = await pending.value
        guard !stopped else { return nil }
        cached = value
        task = nil
        return value
    }

    func stop() {
        stopped = true
        cached = nil
        task?.cancel()
        task = nil
    }
}
