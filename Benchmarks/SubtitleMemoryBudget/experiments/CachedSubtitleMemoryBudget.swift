import Foundation

enum SubtitleMemoryOwner: String, Sendable {
    case bitmapEvents
    case mainLibass
    case mainStaging
    case pictureInPictureLibass
    case pictureInPictureStaging
}

struct SubtitleMemoryBudgetSnapshot: Equatable, Sendable {
    let limitBytes: Int
    let reservedBytes: Int
    let reservationsByOwner: [SubtitleMemoryOwner: Int]
    let rejectedAcquisitions: Int
}

/// One application-runtime boundary for subtitle-owned CPU memory.
///
/// Libass cache limits are reserved when a pipeline is created. Frame packers
/// resize their reservation before growing reusable Data storage. A failed
/// optional PiP staging reservation produces a video-only frame; main
/// presentation never depends on the PiP reservation.
final class SubtitleMemoryBudget: @unchecked Sendable {
    static let productionLimitBytes = 192 * 1_024 * 1_024
    static let productionOwnerLimitsBytes: [SubtitleMemoryOwner: Int] = [
        .bitmapEvents: 32 * 1_024 * 1_024,
        .mainLibass: 64 * 1_024 * 1_024,
        .mainStaging: 64 * 1_024 * 1_024,
        .pictureInPictureLibass: 32 * 1_024 * 1_024,
        .pictureInPictureStaging: 32 * 1_024 * 1_024,
    ]

    private struct State {
        struct OwnerReservation {
            var bytes = 0
            var count = 0
        }

        var nextID: UInt64 = 0
        var reservations: [UInt64: (owner: SubtitleMemoryOwner, bytes: Int)] = [:]
        // Keep accounting under the same lock as the leases. Frame packers
        // resize their staging lease repeatedly while bitmap events may keep
        // many other leases alive; those updates must not scan every lease.
        var reservedBytes = 0
        var reservationsByOwner: [SubtitleMemoryOwner: OwnerReservation] = [:]
        var rejectedAcquisitions = 0
    }

    final class Lease: @unchecked Sendable {
        private weak var budget: SubtitleMemoryBudget?
        private let id: UInt64
        let owner: SubtitleMemoryOwner

        fileprivate init(
            budget: SubtitleMemoryBudget,
            id: UInt64,
            owner: SubtitleMemoryOwner
        ) {
            self.budget = budget
            self.id = id
            self.owner = owner
        }

        @discardableResult
        func resize(to bytes: Int) -> Bool {
            budget?.resize(id: id, to: bytes) ?? false
        }

        deinit {
            budget?.release(id: id)
        }
    }

    private let limitBytes: Int
    private let ownerLimitsBytes: [SubtitleMemoryOwner: Int]
    private let lock = NSLock()
    private var state = State()

    init(
        limitBytes: Int = SubtitleMemoryBudget.productionLimitBytes,
        ownerLimitsBytes: [SubtitleMemoryOwner: Int] =
            SubtitleMemoryBudget.productionOwnerLimitsBytes
    ) {
        self.limitBytes = max(1, limitBytes)
        self.ownerLimitsBytes = ownerLimitsBytes
    }

    func acquire(
        owner: SubtitleMemoryOwner,
        bytes: Int
    ) -> Lease? {
        let requested = max(0, bytes)
        return lock.withLock {
            var ownerReservation = state.reservationsByOwner[owner] ?? .init()
            let ownerAvailable = ownerLimitsBytes[owner].map { $0 - ownerReservation.bytes }
                ?? Int.max
            guard requested <= limitBytes - state.reservedBytes,
                  requested <= ownerAvailable
            else {
                state.rejectedAcquisitions += 1
                return nil
            }
            state.nextID &+= 1
            let id = state.nextID
            state.reservations[id] = (owner, requested)
            state.reservedBytes += requested
            ownerReservation.bytes += requested
            ownerReservation.count += 1
            state.reservationsByOwner[owner] = ownerReservation
            return Lease(budget: self, id: id, owner: owner)
        }
    }

    func canAcquire(
        _ requests: [(owner: SubtitleMemoryOwner, bytes: Int)]
    ) -> Bool {
        lock.withLock {
            var requestedByOwner: [SubtitleMemoryOwner: Int] = [:]
            var requestedTotal = 0
            for request in requests {
                let bytes = max(0, request.bytes)
                requestedByOwner[request.owner, default: 0] += bytes
                requestedTotal += bytes
            }

            guard requestedTotal <= limitBytes - state.reservedBytes else { return false }
            return requestedByOwner.allSatisfy { owner, requested in
                let ownerLimit = ownerLimitsBytes[owner] ?? Int.max
                return requested <= ownerLimit - (state.reservationsByOwner[owner]?.bytes ?? 0)
            }
        }
    }

    var snapshot: SubtitleMemoryBudgetSnapshot {
        lock.withLock {
            return SubtitleMemoryBudgetSnapshot(
                limitBytes: limitBytes,
                reservedBytes: state.reservedBytes,
                reservationsByOwner: state.reservationsByOwner.mapValues(\.bytes),
                rejectedAcquisitions: state.rejectedAcquisitions
            )
        }
    }

    private func resize(id: UInt64, to bytes: Int) -> Bool {
        let requested = max(0, bytes)
        return lock.withLock {
            guard let existing = state.reservations[id] else { return false }
            // Limits are immutable, so an admitted, unchanged reservation is
            // still valid. Reused staging storage commonly takes this path.
            guard requested != existing.bytes else { return true }
            let available = limitBytes - (state.reservedBytes - existing.bytes)
            let ownerReserved = state.reservationsByOwner[existing.owner]!.bytes
            let ownerAvailable = ownerLimitsBytes[existing.owner].map {
                $0 - (ownerReserved - existing.bytes)
            } ?? Int.max
            guard requested <= available,
                  requested <= ownerAvailable
            else {
                state.rejectedAcquisitions += 1
                return false
            }
            state.reservations[id] = (existing.owner, requested)
            let delta = requested - existing.bytes
            state.reservedBytes += delta
            state.reservationsByOwner[existing.owner]!.bytes += delta
            return true
        }
    }

    private func release(id: UInt64) {
        lock.withLock {
            guard let existing = state.reservations.removeValue(forKey: id) else { return }
            state.reservedBytes -= existing.bytes
            var ownerReservation = state.reservationsByOwner[existing.owner]!
            ownerReservation.bytes -= existing.bytes
            ownerReservation.count -= 1
            // Zero-byte leases still appear in snapshots. Drop the owner only
            // when its final lease is released, not when its byte total is zero.
            state.reservationsByOwner[existing.owner] =
                ownerReservation.count == 0 ? nil : ownerReservation
        }
    }
}
