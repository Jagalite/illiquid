import CoreGraphics
import Foundation
import OSLog

/// One native decode at a time, plus one replaceable pending request. Cancelling
/// a caller returns promptly, but the active slot stays occupied until C returns.
final class TimelineThumbnailWorker: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.superplayr.thumbnail", category: "worker")
    struct Input: Sendable {
        let url: URL
        let seconds: TimeInterval
        let size: CGSize
        var cacheRevision: UInt64 = 0
        var background = false
    }
    private final class Request {
        let id: UUID
        let input: Input
        let cancellation: FFmpegInputCancellationSignal
        var continuation: CheckedContinuation<CGImage?, Never>?
        var deadline: DispatchWorkItem?
        init(id: UUID, input: Input, cancellation: FFmpegInputCancellationSignal,
             continuation: CheckedContinuation<CGImage?, Never>) {
            self.id = id
            self.input = input
            self.cancellation = cancellation
            self.continuation = continuation
        }
    }

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.platinum.thumbnail-decode", qos: .utility)
    private let decode: @Sendable (Input, FFmpegInputCancellationSignal) -> CGImage?
    private let release: @Sendable () -> Void
    private let requestTimeout: TimeInterval
    private let prioritizesForeground: Bool
    private var active: Request?
    private var pending: Request?

    var pendingPosition: TimeInterval? {
        lock.withLock { pending?.input.seconds }
    }

    init(requestTimeout: TimeInterval = 1.5,
         prioritizesForeground: Bool = false,
         release: @escaping @Sendable () -> Void = {},
         decode: @escaping @Sendable (Input, FFmpegInputCancellationSignal) -> CGImage?) {
        self.release = release
        self.prioritizesForeground = prioritizesForeground
        self.requestTimeout = requestTimeout
        self.decode = decode
    }

    func image(for input: Input) async -> CGImage? {
        let id = UUID()
        let cancellation = FFmpegInputCancellationSignal()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                enqueue(Request(id: id, input: input, cancellation: cancellation,
                                continuation: continuation))
            }
        } onCancel: {
            cancellation.requestCancellation()
            self.cancel(id)
        }
    }

    private func enqueue(_ request: Request) {
        let deadline = DispatchWorkItem { [weak self, weak request] in
            guard let request, self?.cancel(request.id) == true else { return }
            Self.logger.notice("Thumbnail request reached its deadline, including queue wait")
        }
        request.deadline = deadline
        lock.lock()
        guard !request.cancellation.cancellationRequested else {
            lock.unlock()
            request.continuation?.resume(returning: nil)
            return
        }
        let oldPending = pending
        let oldPendingContinuation = oldPending?.continuation
        oldPending?.continuation = nil
        let oldActive = active
        let oldContinuation = oldActive?.continuation
        oldActive?.continuation = nil
        let startsWorker = active == nil
        if startsWorker { active = request } else { pending = request }
        lock.unlock()
        oldPending?.deadline?.cancel()
        oldPending?.cancellation.requestCancellation()
        oldPendingContinuation?.resume(returning: nil)
        oldActive?.deadline?.cancel()
        oldActive?.cancellation.requestCancellation()
        oldContinuation?.resume(returning: nil)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + requestTimeout, execute: deadline)
        if startsWorker { schedule(request) }
    }

    @discardableResult
    private func cancel(_ id: UUID) -> Bool {
        lock.lock()
        let request: Request?
        if active?.id == id {
            request = active
        } else if pending?.id == id {
            request = pending
            pending = nil
        } else {
            request = nil
        }
        let continuation = request?.continuation
        request?.continuation = nil
        lock.unlock()
        request?.deadline?.cancel()
        request?.cancellation.requestCancellation()
        continuation?.resume(returning: nil)
        return continuation != nil
    }

    func cancelAll(releasingResources: Bool = false) {
        lock.lock()
        let requests = [active, pending].compactMap { $0 }
        let continuations = requests.compactMap { $0.continuation }
        for request in requests { request.continuation = nil }
        pending = nil
        // Keep active ownership until its native call has actually returned.
        lock.unlock()
        for request in requests {
            request.deadline?.cancel()
            request.cancellation.requestCancellation()
        }
        for continuation in continuations { continuation.resume(returning: nil) }
        if releasingResources { queue.async { self.release() } }
    }

    func releaseResourcesWhenIdle() {
        queue.async {
            guard self.lock.withLock({ self.active == nil && self.pending == nil }) else { return }
            // Native access is confined to this serial queue. A request admitted
            // after the check will begin decoding after release has completed.
            self.release()
        }
    }

    private func schedule(_ request: Request) {
        guard prioritizesForeground else { queue.async { self.drain() }; return }
        let qos: DispatchQoS = !request.input.background ? .userInitiated : .utility
        queue.async(qos: qos, flags: .enforceQoS) { self.drain() }
    }

    private func drain() {
        while true {
            lock.lock()
            guard let request = active else { lock.unlock(); return }
            lock.unlock()
            let image = request.cancellation.cancellationRequested
                ? nil : decode(request.input, request.cancellation)
            lock.lock()
            request.deadline?.cancel()
            let continuation = request.continuation
            request.continuation = nil
            active = pending
            pending = nil
            let next = active
            lock.unlock()
            continuation?.resume(returning: request.cancellation.cancellationRequested ? nil : image)
            // A pending hover must get its own foreground work item even when
            // it arrived while a background native call was still returning.
            if prioritizesForeground {
                if let next { schedule(next) }
                return
            }
        }
    }
}
