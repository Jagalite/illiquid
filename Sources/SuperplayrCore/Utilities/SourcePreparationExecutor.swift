import Foundation

/// Filesystem preparation can outlive logical cancellation when an OS read
/// stalls. Admission remains occupied until the physical work exits. No queue
/// of blocked workers accumulates behind a bad mount. Background browser reads
/// may wait asynchronously with a separate bounded waiter budget.
public final class SourcePreparationExecutor: @unchecked Sendable {
    public static let shared = SourcePreparationExecutor()
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.platinum.source-preparation", qos: .userInitiated, attributes: .concurrent)
    private let capacity: Int
    private let timeout: TimeInterval
    private var running = 0
    private var waiting = 0
    private let maximumWaiters = 64

    public enum Failure: Error, LocalizedError {
        case busy, timedOut
        public var errorDescription: String? {
            switch self {
            case .busy: "File access is still waiting on previous requests. Reconnect the drive, then retry."
            case .timedOut: "File access timed out. Reconnect the drive, then retry."
            }
        }
    }

    init(capacity: Int = 2, timeout: TimeInterval = 12) {
        self.capacity = max(1, capacity)
        self.timeout = max(0.001, timeout)
    }

    var activeCount: Int { lock.withLock { running } }

    public func result<Value: Sendable>(
        _ work: @escaping @Sendable (@Sendable () throws -> Void) throws -> Value
    ) async -> Result<Value, Error> {
        do { return .success(try await perform(work)) }
        catch { return .failure(error) }
    }

    public func perform<Value: Sendable>(
        _ work: @escaping @Sendable (@Sendable () throws -> Void) throws -> Value
    ) async throws -> Value {
        try await perform(work, timeout: timeout)
    }

    /// Background directory expansions may arrive together. Wait without creating
    /// OS workers, within one logical deadline and at most 64 admitted waiters.
    /// Interactive source opens retain the fail-fast `perform` contract.
    public func performWhenAvailable<Value: Sendable>(
        _ work: @escaping @Sendable (@Sendable () throws -> Void) throws -> Value
    ) async throws -> Value {
        guard lock.withLock({
            guard waiting < maximumWaiters else { return false }
            waiting += 1
            return true
        }) else { throw Failure.busy }
        defer { lock.withLock { waiting -= 1 } }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var backoff: TimeInterval = 0.025
        while true {
            try Task.checkCancellation()
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw Failure.timedOut }
            do { return try await perform(work, timeout: remaining) }
            catch Failure.busy {
                try await Task.sleep(for: .seconds(min(backoff, remaining)))
                backoff = min(backoff * 2, 0.25)
            }
        }
    }

    private func perform<Value: Sendable>(
        _ work: @escaping @Sendable (@Sendable () throws -> Void) throws -> Value,
        timeout: TimeInterval
    ) async throws -> Value {
        let request = Request<Value>()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                request.install(continuation)
                guard lock.withLock({
                    guard running < capacity else { return false }
                    running += 1
                    return true
                }) else {
                    request.finish(.failure(Failure.busy))
                    return
                }
                request.startDeadline(after: timeout)
                queue.async { [self] in
                    let result = Result {
                        try request.checkCancellation()
                        return try work { try request.checkCancellation() }
                    }
                    lock.withLock { running -= 1 }
                    request.finish(result)
                }
            }
        } onCancel: {
            request.finish(.failure(CancellationError()))
        }
    }

    private final class Request<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Value, Error>?
        private var result: Result<Value, Error>?
        private var timer: DispatchSourceTimer?

        func install(_ continuation: CheckedContinuation<Value, Error>) {
            let completed = lock.withLock { () -> Result<Value, Error>? in
                if let result { return result }
                self.continuation = continuation
                return nil
            }
            if let completed { continuation.resume(with: completed) }
        }

        func startDeadline(after timeout: TimeInterval) {
            lock.withLock {
                guard result == nil else { return }
                let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
                timer.schedule(deadline: .now() + timeout)
                timer.setEventHandler { [weak self] in self?.finish(.failure(Failure.timedOut)) }
                self.timer = timer
                timer.resume()
            }
        }

        func checkCancellation() throws {
            if lock.withLock({ result != nil }) { throw CancellationError() }
        }

        func finish(_ result: Result<Value, Error>) {
            let pending = lock.withLock { () -> CheckedContinuation<Value, Error>? in
                guard self.result == nil else { return nil }
                self.result = result
                timer?.cancel()
                timer = nil
                defer { continuation = nil }
                return continuation
            }
            pending?.resume(with: result)
        }
    }
}
