import Foundation

/// stat on mounted storage can block inside the OS. Keep it off cache actors,
/// bound physical work to one call, and let callers cancel/expire independently.
final class ThumbnailBlockingReader<Value: Sendable>: @unchecked Sendable {
    private final class Reply: @unchecked Sendable {
        private let lock = NSLock()
        private let expiresAt: ContinuousClock.Instant
        private let now: @Sendable () -> ContinuousClock.Instant
        init(timeout: Double, now: @escaping @Sendable () -> ContinuousClock.Instant) {
            self.now = now
            expiresAt = now().advanced(by: .seconds(timeout))
        }
        private var finished = false
        private var continuation: CheckedContinuation<Value?, Never>?
        private var deadline: DispatchWorkItem?
        var isFinished: Bool { lock.withLock { finished } }
        func install(_ value: CheckedContinuation<Value?, Never>) {
            let ended = lock.withLock {
                if finished { return true }
                continuation = value
                return false
            }
            if ended { value.resume(returning: nil) }
        }
        func setDeadline(_ value: DispatchWorkItem) {
            lock.withLock { if finished { value.cancel() } else { deadline = value } }
        }
        func finish(_ key: Value?) {
            let reply = lock.withLock { () -> CheckedContinuation<Value?, Never>? in
                guard !finished else { return nil }
                finished = true
                deadline?.cancel(); deadline = nil
                defer { continuation = nil }
                return continuation
            }
            // The dispatch timer is only a wakeup mechanism. Queue contention
            // must not turn a late native result into an on-time response.
            reply?.resume(returning: now() < expiresAt ? key : nil)
        }
    }
    private let lock = NSLock()
    private var busy = false
    private let queue = DispatchQueue(label: "com.illiquid.thumbnail-file-identity", qos: .utility)
    private let timeout: Double
    private let now: @Sendable () -> ContinuousClock.Instant
    init(timeout: Double = 3, now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }) {
        self.timeout = timeout
        self.now = now
    }
    func read(_ operation: @escaping @Sendable () -> Value?) async -> Value? {
        let reply = Reply(timeout: timeout, now: now)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                reply.install(continuation)
                guard !reply.isFinished else { return }
                let admitted = lock.withLock {
                    guard !busy else { return false }
                    busy = true
                    return true
                }
                guard admitted else { reply.finish(nil); return }
                let deadline = DispatchWorkItem { [weak reply] in reply?.finish(nil) }
                reply.setDeadline(deadline)
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: deadline)
                queue.async {
                    let value = reply.isFinished ? nil : operation()
                    self.lock.withLock { self.busy = false }
                    reply.finish(value)
                }
            }
        } onCancel: { reply.finish(nil) }
    }
}
