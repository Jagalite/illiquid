import CFFmpeg
import Foundation

struct FFmpegInputEffectToken: RawRepresentable, Equatable, Hashable, Sendable {
    let rawValue: UInt64
}

enum FFmpegInputCancellationDisposition: Equatable, Sendable {
    case interruptRequested
    case targetNotActive
}

final class FFmpegInputCancellationSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var isRequested = false
    private var handlers: [UUID: @Sendable () -> Void] = [:]

    var cancellationRequested: Bool {
        lock.withLock { isRequested }
    }

    func requestCancellation() {
        let callbacks = lock.withLock { () -> [@Sendable () -> Void] in
            guard !isRequested else { return [] }
            isRequested = true
            return Array(handlers.values)
        }
        for callback in callbacks {
            callback()
        }
    }

    func register(_ handler: @escaping @Sendable () -> Void) -> UUID {
        let registration = UUID()
        let invokeImmediately = lock.withLock { () -> Bool in
            guard !isRequested else { return true }
            handlers[registration] = handler
            return false
        }
        if invokeImmediately {
            handler()
        }
        return registration
    }

    func unregister(_ registration: UUID) {
        _ = lock.withLock {
            handlers.removeValue(forKey: registration)
        }
    }

    func checkCancellation() throws {
        if cancellationRequested {
            throw FFmpegInputExecutorError.operationCancelled
        }
    }
}

struct FFmpegInputQuarantineSnapshot: Equatable, Sendable {
    let workers: Int
    let retainedBytes: Int
}

enum FFmpegBlockingWaitDisposition: Equatable, Sendable {
    case completed
    case completedAfterCancellation
    case quarantined
}

enum FFmpegBlockingDeadlineWaiter {
    static func wait(
        for completion: DispatchSemaphore,
        timeout: TimeInterval,
        cancellationGrace: TimeInterval,
        requestCancellation: () -> Void
    ) -> FFmpegBlockingWaitDisposition {
        if completion.wait(timeout: .now() + max(timeout, 0)) == .success {
            return .completed
        }
        requestCancellation()
        if completion.wait(timeout: .now() + max(cancellationGrace, 0)) == .success {
            return .completedAfterCancellation
        }
        return .quarantined
    }
}

/// Hard admission bound for the rare case where an interrupted C call fails
/// to return before its deadline and must be quarantined rather than closed
/// concurrently. The registry owns no worker; it only prevents unbounded
/// worker/byte retention.
final class FFmpegInputQuarantineBudget: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumWorkers: Int
    private let maximumRetainedBytes: Int
    private var entries: [UInt64: Int] = [:]

    init(maximumWorkers: Int = 2, maximumRetainedBytes: Int = 128 * 1_024 * 1_024) {
        precondition(maximumWorkers > 0 && maximumRetainedBytes > 0)
        self.maximumWorkers = maximumWorkers
        self.maximumRetainedBytes = maximumRetainedBytes
    }

    func admit(workerID: UInt64, retainedBytes: Int) -> Bool {
        lock.withLock {
            let bytes = max(retainedBytes, 0)
            guard entries[workerID] == nil,
                  entries.count < maximumWorkers,
                  entries.values.reduce(0, +) <= maximumRetainedBytes - min(bytes, maximumRetainedBytes)
            else { return false }
            entries[workerID] = bytes
            return true
        }
    }

    func release(workerID: UInt64) {
        lock.withLock { _ = entries.removeValue(forKey: workerID) }
    }

    var snapshot: FFmpegInputQuarantineSnapshot {
        lock.withLock {
            FFmpegInputQuarantineSnapshot(
                workers: entries.count,
                retainedBytes: entries.values.reduce(0, +)
            )
        }
    }
}

final class FFmpegInterruptState: @unchecked Sendable {
    private let lock = NSLock()
    private var active: FFmpegInputEffectToken?
    private var cancellationRequested: Set<FFmpegInputEffectToken> = []
    private var cancelNextRead = false

    func begin(
        _ token: FFmpegInputEffectToken,
        consumesDeferredReadCancellation: Bool = true
    ) {
        lock.withLock {
            precondition(active == nil, "FFmpeg input operations must be serialized")
            active = token
            if consumesDeferredReadCancellation, cancelNextRead {
                cancellationRequested.insert(token)
                cancelNextRead = false
            }
        }
    }

    func end(_ token: FFmpegInputEffectToken) {
        lock.withLock {
            if active == token { active = nil }
            cancellationRequested.remove(token)
        }
    }

    func cancel(_ token: FFmpegInputEffectToken) -> FFmpegInputCancellationDisposition {
        lock.withLock {
            guard active == token else { return .targetNotActive }
            cancellationRequested.insert(token)
            return .interruptRequested
        }
    }

    func requestCancellation(
        for token: FFmpegInputEffectToken
    ) -> FFmpegInputCancellationDisposition {
        lock.withLock {
            cancellationRequested.insert(token)
            return active == token ? .interruptRequested : .targetNotActive
        }
    }

    func cancelActive() -> FFmpegInputCancellationDisposition {
        lock.withLock {
            guard let active else {
                cancelNextRead = true
                return .targetNotActive
            }
            cancellationRequested.insert(active)
            return .interruptRequested
        }
    }

    func shouldInterrupt() -> Bool {
        lock.withLock {
            guard let active else { return false }
            return cancellationRequested.contains(active)
        }
    }

    func clearDeferredReadCancellation() {
        lock.withLock { cancelNextRead = false }
    }
}

let ffmpegInputInterruptCallback:
    @convention(c) (UnsafeMutableRawPointer?) -> Int32 = { opaque in
        guard let opaque else { return 0 }
        let state = Unmanaged<FFmpegInterruptState>.fromOpaque(opaque).takeUnretainedValue()
        return state.shouldInterrupt() ? 1 : 0
    }

private final class FFmpegBlockingResultBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, Error>?

    func store(_ result: Result<Value, Error>) {
        lock.withLock { self.result = result }
    }

    func take() -> Result<Value, Error> {
        lock.withLock {
            precondition(result != nil, "FFmpeg result signaled without a value")
            return result!
        }
    }
}

enum FFmpegInputExecutorError: LocalizedError, Equatable {
    case openAdmissionExceeded
    case openTimedOut
    case operationCancelled

    var errorDescription: String? {
        switch self {
        case .openAdmissionExceeded:
            "Too many unresponsive media-open operations are already retained."
        case .openTimedOut:
            "Opening and probing the media source timed out."
        case .operationCancelled:
            "The native input operation was cancelled."
        }
    }
}

private final class FFmpegInputOpenAdmission: @unchecked Sendable {
    static let shared = FFmpegInputOpenAdmission()

    private let lock = NSLock()
    private let budget = FFmpegInputQuarantineBudget()
    private var nextWorkerID: UInt64 = 1
    private let estimatedRetainedBytes = 64 * 1_024 * 1_024

    func reserve() -> UInt64? {
        lock.withLock {
            guard nextWorkerID < UInt64.max else { return nil }
            let workerID = nextWorkerID
            guard budget.admit(
                workerID: workerID,
                retainedBytes: estimatedRetainedBytes
            ) else { return nil }
            nextWorkerID += 1
            return workerID
        }
    }

    func release(_ workerID: UInt64) {
        budget.release(workerID: workerID)
    }
}

final class OwnedCodecParameters: @unchecked Sendable {
    private var pointer: UnsafeMutablePointer<AVCodecParameters>?

    init(copying source: UnsafePointer<AVCodecParameters>) throws {
        guard let copy = avcodec_parameters_alloc() else {
            throw FFmpegError(
                operation: "Allocate owned codec configuration",
                code: superplayr_averror_nomem()
            )
        }
        let result = avcodec_parameters_copy(copy, source)
        guard result >= 0 else {
            var disposable: UnsafeMutablePointer<AVCodecParameters>? = copy
            avcodec_parameters_free(&disposable)
            throw FFmpegError(operation: "Copy codec configuration", code: result)
        }
        pointer = copy
    }

    deinit { avcodec_parameters_free(&pointer) }

    func withUnsafePointer<Result>(
        _ body: (UnsafePointer<AVCodecParameters>) throws -> Result
    ) rethrows -> Result? {
        guard let pointer else { return nil }
        return try body(UnsafePointer(pointer))
    }
}

/// Sole owner of AVFormatContext and every open/probe/read/seek/close C-call.
/// Calls are serialized on one executor; the AVIO interrupt callback is
/// installed before open and checks the exact active effect token.
final class FFmpegInputExecutor: @unchecked Sendable {
    private enum OperationKind {
        case read
        case seek
        case other
    }

    private let queue: DispatchQueue
    private let tokenLock = NSLock()
    private let interruptState: FFmpegInterruptState
    private var nextTokenValue: UInt64 = 1
    private var demuxer: FFmpegDemuxer?

    let mediaInfo: FFmpegMediaInfo
    let openWasPerformedOnMainThread: Bool

    init(
        url: URL,
        openTimeout: TimeInterval = 12,
        cancellationGrace: TimeInterval = 1,
        cancellationSignal: FFmpegInputCancellationSignal? = nil
    ) throws {
        try cancellationSignal?.checkCancellation()
        guard let workerID = FFmpegInputOpenAdmission.shared.reserve() else {
            throw FFmpegInputExecutorError.openAdmissionExceeded
        }
        let openingQueue = DispatchQueue(label: "com.superplayr.native.ffmpeg-input")
        let openingInterruptState = FFmpegInterruptState()
        queue = openingQueue
        interruptState = openingInterruptState
        let token = FFmpegInputEffectToken(rawValue: 1)
        nextTokenValue = 2
        let cancellationRegistration = cancellationSignal?.register {
            _ = openingInterruptState.requestCancellation(for: token)
        }
        defer {
            if let cancellationRegistration {
                cancellationSignal?.unregister(cancellationRegistration)
            }
        }
        let result = FFmpegBlockingResultBox<(FFmpegDemuxer, Bool)>()
        let completed = DispatchSemaphore(value: 0)
        openingQueue.async {
            defer { FFmpegInputOpenAdmission.shared.release(workerID) }
            result.store(Result {
                openingInterruptState.begin(
                    token,
                    consumesDeferredReadCancellation: false
                )
                defer { openingInterruptState.end(token) }
                return (
                    try FFmpegDemuxer(url: url, interruptState: openingInterruptState),
                    Thread.isMainThread
                )
            })
            completed.signal()
        }
        let waitDisposition = FFmpegBlockingDeadlineWaiter.wait(
            for: completed,
            timeout: openTimeout,
            cancellationGrace: cancellationGrace
        ) {
            _ = openingInterruptState.cancel(token)
        }
        guard waitDisposition == .completed else {
            if waitDisposition == .completedAfterCancellation {
                _ = result.take()
            }
            throw FFmpegInputExecutorError.openTimedOut
        }
        try cancellationSignal?.checkCancellation()
        let opened = try result.take().get()
        demuxer = opened.0
        mediaInfo = opened.0.mediaInfo
        openWasPerformedOnMainThread = opened.1
    }

    deinit {
        queue.sync { demuxer = nil }
    }

    func readPacket(generation: Int) throws -> FFmpegPacket? {
        try perform(kind: .read) { demuxer in
            try demuxer.readPacket(generation: generation)
        }
    }

    func seek(to seconds: Double, exact: Bool) throws {
        try perform(kind: .seek) { demuxer in
            try demuxer.seek(to: seconds, exact: exact)
        }
    }

    func activeSubtitlePackets(
        streamIndex: Int32,
        at seconds: Double,
        generation: Int
    ) throws -> [FFmpegPacket] {
        // This operation seeks the input. It must consume sticky cancellation
        // just like seek(to:), before attempting subtitle reconstruction.
        try perform(kind: .seek) { demuxer in
            try demuxer.activeSubtitlePackets(
                streamIndex: streamIndex,
                at: seconds,
                generation: generation
            )
        }
    }

    func copyCodecParameters(streamIndex: Int32) throws -> OwnedCodecParameters? {
        try perform(kind: .other) { demuxer in
            guard let parameters = demuxer.codecParameters(streamIndex: streamIndex) else {
                return nil
            }
            return try OwnedCodecParameters(copying: parameters)
        }
    }

    func codecPrivateData(streamIndex: Int32) -> Data? {
        try? perform(kind: .other) { $0.codecPrivateData(streamIndex: streamIndex) }
    }

    @discardableResult
    func cancel(_ token: FFmpegInputEffectToken) -> FFmpegInputCancellationDisposition {
        interruptState.cancel(token)
    }

    @discardableResult
    func cancelActiveOperation() -> FFmpegInputCancellationDisposition {
        interruptState.cancelActive()
    }

    func makeEffectToken() -> FFmpegInputEffectToken {
        tokenLock.withLock {
            precondition(nextTokenValue < UInt64.max, "FFmpeg input token exhausted")
            defer { nextTokenValue += 1 }
            return FFmpegInputEffectToken(rawValue: nextTokenValue)
        }
    }

    private func perform<Result>(
        kind: OperationKind,
        _ body: (FFmpegDemuxer) throws -> Result
    ) throws -> Result {
        let token = makeEffectToken()
        return try queue.sync {
            if kind == .seek {
                interruptState.clearDeferredReadCancellation()
            }
            interruptState.begin(
                token,
                consumesDeferredReadCancellation: kind == .read
            )
            defer { interruptState.end(token) }
            guard let demuxer else {
                throw FFmpegError(
                    operation: "Use closed input executor",
                    code: superplayr_averror_unknown()
                )
            }
            return try body(demuxer)
        }
    }
}
