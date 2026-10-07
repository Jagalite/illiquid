import Foundation

/// Converts AVFoundation's demand callback into one consumable work grant.
/// It never polls renderer readiness and coalesces repeated ready callbacks.
final class RendererDemandGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var available = false
    private var terminated = false
    private var epoch: UInt64 = 0

    /// Starts a new renderer callback epoch. Grants from an older callback
    /// registration are rejected after EOF suspension, recovery, or re-arming.
    func beginEpoch() -> UInt64 {
        lock.withLock {
            guard !terminated else { return epoch }
            epoch &+= 1
            available = false
            return epoch
        }
    }

    func offer(epoch candidate: UInt64) {
        let shouldSignal = lock.withLock { () -> Bool in
            guard !terminated, candidate == epoch, !available else { return false }
            available = true
            return true
        }
        if shouldSignal { semaphore.signal() }
    }

    /// Invalidates outstanding callback grants without terminating the gate.
    /// A later seek from EOF can begin a fresh epoch and reuse the worker.
    func revoke() {
        lock.withLock {
            guard !terminated else { return }
            epoch &+= 1
            available = false
        }
    }

    func consume(while running: () -> Bool) -> Bool {
        while running() {
            semaphore.wait()
            let result = lock.withLock { () -> Bool? in
                if terminated { return false }
                guard available else { return nil }
                available = false
                return true
            }
            if let result { return result }
        }
        return false
    }

    func close() {
        lock.withLock {
            terminated = true
            available = false
            epoch &+= 1
        }
        semaphore.signal()
    }
}

/// Tracks the only renderer-demand suspension that can be resumed in-place.
/// Session stop terminates the gates permanently; drained EOF instead suspends
/// callbacks so a later seek/replay can safely re-arm them.
struct EndOfStreamDemandLifecycle {
    private(set) var isSuspended = false

    mutating func suspendIfNeeded() -> Bool {
        guard !isSuspended else { return false }
        isSuspended = true
        return true
    }

    mutating func resumeIfNeeded() -> Bool {
        guard isSuspended else { return false }
        isSuspended = false
        return true
    }
}
