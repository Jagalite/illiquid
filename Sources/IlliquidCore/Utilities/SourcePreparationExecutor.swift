import Foundation

/// Filesystem preparation can outlive logical cancellation when an OS read
/// stalls. Admission remains occupied until the physical work exits. No queue
/// of blocked workers accumulates behind a bad mount. Background browser reads
/// may wait asynchronously with a separate bounded waiter budget.
public final class SourcePreparationExecutor: @unchecked Sendable {
    public static let shared = SourcePreparationExecutor()
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.illiquid.source-preparation", qos: .userInitiated, attributes: .concurrent)
    private let capacity: Int
    private let timeout: TimeInterval
    private var running = 0
    private var backgroundRunning = 0
    private var backgroundRequests: Set<ObjectIdentifier> = []
    private var pendingBackground: [BackgroundWork] = []
    private let maximumWaiters = 64

    private struct BackgroundWork: Sendable {
        let id: ObjectIdentifier
        let start: @Sendable () -> Void
    }

    private enum Admission {
        case finished, busy, start, queued
    }

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
        try await perform(work, timeout: timeout, background: true)
    }

    private func perform<Value: Sendable>(
        _ work: @escaping @Sendable (@Sendable () throws -> Void) throws -> Value,
        timeout: TimeInterval,
        background: Bool = false
    ) async throws -> Value {
        let deadline = DispatchTime.now() + timeout
        let onFinish: (@Sendable (ObjectIdentifier) -> Void)?
        if background {
            onFinish = { [weak self] id in self?.retireBackgroundRequest(id) }
        } else {
            onFinish = nil
        }
        let request = Request<Value>(onFinish: onFinish)
        let backgroundID = background ? ObjectIdentifier(request) : nil
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                request.install(continuation)
                let start: @Sendable () -> Void = { [self] in
                    queue.async { [self] in
                        let result = Result {
                            try request.checkCancellation()
                            // Timer delivery can lag behind a physical handoff.
                            // Expired queued work must not enter the OS call.
                            guard DispatchTime.now() < deadline else { throw Failure.timedOut }
                            return try work { try request.checkCancellation() }
                        }
                        let next = lock.withLock {
                            running -= 1
                            if background { backgroundRunning -= 1 }
                            return admitNextBackground()
                        }
                        request.finish(result)
                        next?.start()
                    }
                }
                let admission = lock.withLock { () -> Admission in
                    // Request.finish invokes onFinish only after releasing its
                    // own lock. This one-way lock order also closes the race
                    // where cancellation finishes before registration.
                    guard !request.isFinished else { return .finished }
                    if let backgroundID {
                        guard backgroundRequests.count < maximumWaiters else { return .busy }
                        backgroundRequests.insert(backgroundID)
                        guard canStartBackground else {
                            // Arm before publishing the job: a completing
                            // worker can promote it as soon as this lock exits.
                            request.startDeadline(at: deadline)
                            pendingBackground.append(BackgroundWork(id: backgroundID, start: start))
                            return .queued
                        }
                        backgroundRunning += 1
                    } else if running >= capacity {
                        return .busy
                    }
                    running += 1
                    return .start
                }
                switch admission {
                case .finished:
                    break
                case .busy:
                    request.finish(.failure(Failure.busy))
                case .start:
                    request.startDeadline(at: deadline)
                    start()
                case .queued:
                    // The original deadline covers queueing and execution;
                    // admission never installs another continuation or timer.
                    break
                }
            }
        } onCancel: {
            request.finish(.failure(CancellationError()))
        }
    }

    /// Called with the executor lock held. Keep one physical slot available for
    /// an interactive open while background scans wait on another volume.
    private var canStartBackground: Bool {
        running < capacity && backgroundRunning < max(1, capacity - 1)
    }

    /// One physical completion frees at most one slot. Reserve it before
    /// dispatching the next job so other callers cannot take the same slot.
    /// Called only with the executor lock held; the returned job starts outside.
    private func admitNextBackground() -> BackgroundWork? {
        guard canStartBackground, !pendingBackground.isEmpty else { return nil }
        let next = pendingBackground.removeFirst()
        running += 1
        backgroundRunning += 1
        return next
    }

    private func retireBackgroundRequest(_ id: ObjectIdentifier) {
        let retired = lock.withLock { () -> BackgroundWork? in
            guard backgroundRequests.remove(id) != nil else { return nil }
            guard let index = pendingBackground.firstIndex(where: { $0.id == id }) else { return nil }
            return pendingBackground.remove(at: index)
        }
        // Release captured work outside the scheduler lock, including when a
        // queued request times out behind a physically blocked filesystem call.
        withExtendedLifetime(retired) {}
    }

    private final class Request<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private let onFinish: (@Sendable (ObjectIdentifier) -> Void)?
        private var continuation: CheckedContinuation<Value, Error>?
        private var result: Result<Value, Error>?
        private var timer: DispatchSourceTimer?

        init(onFinish: (@Sendable (ObjectIdentifier) -> Void)? = nil) {
            self.onFinish = onFinish
        }

        var isFinished: Bool { lock.withLock { result != nil } }

        func install(_ continuation: CheckedContinuation<Value, Error>) {
            let completed = lock.withLock { () -> Result<Value, Error>? in
                if let result { return result }
                self.continuation = continuation
                return nil
            }
            if let completed { continuation.resume(with: completed) }
        }

        func startDeadline(at deadline: DispatchTime) {
            lock.withLock {
                guard result == nil else { return }
                let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
                timer.schedule(deadline: deadline)
                timer.setEventHandler { [weak self] in self?.finish(.failure(Failure.timedOut)) }
                self.timer = timer
                timer.resume()
            }
        }

        func checkCancellation() throws {
            if lock.withLock({ result != nil }) { throw CancellationError() }
        }

        func finish(_ result: Result<Value, Error>) {
            let completion = lock.withLock { () -> (Bool, CheckedContinuation<Value, Error>?) in
                guard self.result == nil else { return (false, nil) }
                self.result = result
                timer?.cancel()
                timer = nil
                defer { continuation = nil }
                return (true, continuation)
            }
            guard completion.0 else { return }
            onFinish?(ObjectIdentifier(self))
            completion.1?.resume(with: result)
        }
    }
}
