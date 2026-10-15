import Foundation
import IlliquidCore

/// Main-actor admission orders automation requests independently of filesystem
/// completion order. Waiting requests allocate no worker and never bypass the
/// playback core. Cancelling a waiter cannot release its successor early.
@MainActor
final class PlaybackAutomationQueue {
    private var tail: Task<Void, Never>?
    private var pending = 0

    func perform<Value: Sendable>(_ operation: @escaping @MainActor @Sendable () async throws -> Value) async throws -> Value {
        guard pending < PlaybackAutomationPolicy.maximumPendingRequests else { throw PlaybackAutomationError.busy }
        try Task.checkCancellation()
        pending += 1
        let predecessor = tail
        let job = Task { @MainActor in
            await predecessor?.value
            try Task.checkCancellation()
            return try await operation()
        }
        let completion = Task { @MainActor in _ = try? await job.value }
        tail = completion
        defer {
            pending -= 1
            if pending == 0 { tail = nil }
        }
        return try await withTaskCancellationHandler {
            try await job.value
        } onCancel: { job.cancel() }
    }
}
