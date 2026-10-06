import Foundation

/// stat on mounted storage can block inside the OS. Keep it off cache actors,
/// bound physical work to one call, and let callers cancel/expire independently.
final class ThumbnailBlockingReader<Value: Sendable>: @unchecked Sendable {
    private final class Reply: @unchecked Sendable {
        private let lock = NSLock()
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
            reply?.resume(returning: key)
        }
    }
    private let lock = NSLock()
    private var busy = false
    private let queue = DispatchQueue(label: "com.illiquid.thumbnail-file-identity", qos: .utility)
    private let timeout: Double
    init(timeout: Double = 3) { self.timeout = timeout }
    func read(_ operation: @escaping @Sendable () -> Value?) async -> Value? {
        let reply = Reply()
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
