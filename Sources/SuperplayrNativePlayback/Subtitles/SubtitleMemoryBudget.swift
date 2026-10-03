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
        var nextID: UInt64 = 0
        var reservations: [UInt64: (owner: SubtitleMemoryOwner, bytes: Int)] = [:]
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
            let reserved = state.reservations.values.reduce(0) { $0 + $1.bytes }
            let ownerReserved = state.reservations.values
                .filter { $0.owner == owner }
                .reduce(0) { $0 + $1.bytes }
            let ownerAvailable = ownerLimitsBytes[owner].map { $0 - ownerReserved }
                ?? Int.max
            guard requested <= limitBytes - reserved,
                  requested <= ownerAvailable
            else {
                state.rejectedAcquisitions += 1
                return nil
            }
            state.nextID &+= 1
            let id = state.nextID
            state.reservations[id] = (owner, requested)
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

            let reserved = state.reservations.values.reduce(0) { $0 + $1.bytes }
            guard requestedTotal <= limitBytes - reserved else { return false }

            var reservedByOwner: [SubtitleMemoryOwner: Int] = [:]
            for reservation in state.reservations.values {
                reservedByOwner[reservation.owner, default: 0] += reservation.bytes
            }
            return requestedByOwner.allSatisfy { owner, requested in
                let ownerLimit = ownerLimitsBytes[owner] ?? Int.max
                return requested <= ownerLimit - reservedByOwner[owner, default: 0]
            }
        }
    }

    var snapshot: SubtitleMemoryBudgetSnapshot {
        lock.withLock {
            var byOwner: [SubtitleMemoryOwner: Int] = [:]
            for reservation in state.reservations.values {
                byOwner[reservation.owner, default: 0] += reservation.bytes
            }
            return SubtitleMemoryBudgetSnapshot(
                limitBytes: limitBytes,
                reservedBytes: byOwner.values.reduce(0, +),
                reservationsByOwner: byOwner,
                rejectedAcquisitions: state.rejectedAcquisitions
            )
        }
    }

    private func resize(id: UInt64, to bytes: Int) -> Bool {
        let requested = max(0, bytes)
        return lock.withLock {
            guard let existing = state.reservations[id] else { return false }
            let reserved = state.reservations.values.reduce(0) { $0 + $1.bytes }
            let available = limitBytes - (reserved - existing.bytes)
            let ownerReserved = state.reservations.values
                .filter { $0.owner == existing.owner }
                .reduce(0) { $0 + $1.bytes }
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
            return true
        }
    }

    private func release(id: UInt64) {
        lock.withLock {
            state.reservations[id] = nil
        }
    }
}
