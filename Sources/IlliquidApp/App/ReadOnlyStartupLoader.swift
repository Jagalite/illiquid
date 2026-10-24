import Foundation

/// Coalesces one read-only startup operation. Finishing releases the startup
/// snapshot after its owner adopts it, while allowing existing readers to return.
/// Stopping also rejects late results; shutdown need not wait for a blocked read.
@MainActor
final class ReadOnlyStartupLoader<Value: Sendable> {
    private let read: @Sendable () async -> Value
    private var task: Task<Value, Never>?
    private var cached: Value?
    private enum State {
        case active, finished, stopped
    }
    private var state = State.active

    init(read: @escaping @Sendable () async -> Value) { self.read = read }

    func load() async -> Value? {
        guard state == .active else { return nil }
        if let cached { return cached }
        let pending: Task<Value, Never>
        if let task { pending = task }
        else {
            pending = Task { await read() }
            task = pending
        }
        let value = await pending.value
        guard state != .stopped else { return nil }
        if state == .active {
            cached = value
            task = nil
        }
        return value
    }

    /// The shared owner has been published. Existing readers still receive
    /// their result, but no late reader may repopulate the cache or start a read.
    func finish() {
        guard state == .active else { return }
        state = .finished
        cached = nil
        task = nil
    }

    func stop() {
        state = .stopped
        cached = nil
        task?.cancel()
        task = nil
    }
}
