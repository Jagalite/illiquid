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

    /// Transfers startup ownership to one shared model, then retires this
    /// loader's cached snapshot. The publisher must synchronously install the
    /// model returned by `existing`; publication and retirement never suspend.
    /// Shutdown takes priority over returning even an already published model.
    func loadShared<Shared>(
        existing: () -> Shared?,
        isShutdown: () -> Bool,
        publish: (Value) -> Shared
    ) async -> Shared? {
        guard !isShutdown() else { return nil }
        if let shared = existing() { return shared }
        let startup = await load()
        guard !isShutdown() else { return nil }
        // An earlier waiter can publish and stop the loader before this one
        // resumes. Its shared model remains valid even when load() returns nil.
        if let shared = existing() { return shared }
        guard let startup else { return nil }
        let shared = publish(startup)
        stop()
        return shared
    }

    func stop() {
        stopped = true
        cached = nil
        task?.cancel()
        task = nil
    }
}
