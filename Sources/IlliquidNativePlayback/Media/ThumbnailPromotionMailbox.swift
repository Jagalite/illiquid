import Foundation

/// A bounded, synchronous handoff between resident hits and disk housekeeping.
/// The lock protects metadata only. It is NEVER held during I/O, hashing, await,
/// or task creation. Reservations precede background eviction at this boundary;
/// actor task ordering is deliberately not used as an ordering guarantee.
final class ThumbnailPromotionMailbox: @unchecked Sendable {
    struct Request: Equatable, Sendable {
        let digest: String
        let epoch: UInt64
        let serial: UInt64
    }
    enum Reservation: Equatable {
        case accepted(startDrain: Bool)
        case unavailable
    }
    private let lock = NSLock()
    private let capacity: Int
    private var epoch: UInt64 = 0
    private var serial: UInt64 = 0
    private var requests: [String: Request] = [:]
    private var draining = false
    private var evicting: String?
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(capacity: Int = 128) { self.capacity = max(1, capacity) }

    func reserve(_ digest: String, epoch: UInt64) -> Reservation {
        lock.lock(); defer { lock.unlock() }
        guard epoch == self.epoch, evicting != digest else { return .unavailable }
        if requests[digest] != nil { return .accepted(startDrain: false) }
        guard requests.count < capacity else { return .unavailable }
        serial &+= 1
        requests[digest] = Request(digest: digest, epoch: epoch, serial: serial)
        let start = !draining
        draining = true
        return .accepted(startDrain: start)
    }

    /// Keep the claim while the disk actor processes it, not merely until dequeue.
    func next() -> Request? {
        lock.lock(); defer { lock.unlock() }
        guard let request = requests.values.first else { draining = false; return nil }
        return request
    }

    func complete(_ request: Request) {
        lock.lock()
        if requests[request.digest] == request { requests.removeValue(forKey: request.digest) }
        let ready = requests.isEmpty ? waiters : []
        if requests.isEmpty { waiters.removeAll() }
        lock.unlock()
        for waiter in ready { waiter.resume() }
    }

    func waitUntilEmpty() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if requests.isEmpty {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func protects(_ digest: String, epoch: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return epoch == self.epoch && requests[digest] != nil
    }

    /// Linearize eviction before filesystem work without holding the lock over it.
    /// A hit arriving after this point takes the existing awaited promotion path.
    func beginEviction(_ digest: String, epoch: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard epoch == self.epoch, evicting == nil, requests[digest] == nil else { return false }
        evicting = digest
        return true
    }

    func endEviction(_ digest: String) {
        lock.lock(); defer { lock.unlock() }
        if evicting == digest { evicting = nil }
    }

    func reset(epoch: UInt64) {
        lock.lock()
        self.epoch = epoch
        requests.removeAll(keepingCapacity: false)
        evicting = nil
        let ready = waiters
        waiters.removeAll()
        lock.unlock()
        for waiter in ready { waiter.resume() }
        // A scheduled drainer still exists and will see the new epoch's requests.
        // Leave its ownership flag intact; next() releases it atomically on empty.
    }

    var pendingCount: Int { lock.lock(); defer { lock.unlock() }; return requests.count }
}
