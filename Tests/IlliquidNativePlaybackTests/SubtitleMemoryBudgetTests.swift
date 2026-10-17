import Foundation
import Testing
@testable import IlliquidNativePlayback

@Suite("Subtitle memory budget accounting")
struct SubtitleMemoryBudgetTests {
    @Test func admissionAndResizeRespectGlobalAndOwnerLimits() throws {
        let budget = SubtitleMemoryBudget(limitBytes: 100, ownerLimitsBytes: [.mainStaging: 64])
        let first = try #require(budget.acquire(owner: .mainStaging, bytes: 32))
        let second = try #require(budget.acquire(owner: .mainStaging, bytes: 32))
        let other = try #require(budget.acquire(owner: .bitmapEvents, bytes: 36))
        defer { withExtendedLifetime((first, second, other)) {} }

        #expect(first.owner == .mainStaging)
        #expect(budget.acquire(owner: .mainStaging, bytes: 1) == nil)
        #expect(budget.acquire(owner: .bitmapEvents, bytes: 1) == nil)
        #expect(!first.resize(to: 33))
        #expect(budget.snapshot.reservedBytes == 100)
        #expect(budget.snapshot.rejectedAcquisitions == 3)

        #expect(second.resize(to: -1))
        #expect(budget.snapshot.reservationsByOwner == [.mainStaging: 32, .bitmapEvents: 36])
        #expect(first.resize(to: 64))
        #expect(first.resize(to: 64))
        #expect(!other.resize(to: 37))
        #expect(budget.snapshot.reservedBytes == 100)
        #expect(budget.snapshot.rejectedAcquisitions == 4)
    }

    @Test func batchAdmissionAggregatesDuplicateOwnersWithoutMutatingState() throws {
        let budget = SubtitleMemoryBudget(
            limitBytes: 100, ownerLimitsBytes: [.mainStaging: 60, .bitmapEvents: 20]
        )
        let lease = try #require(budget.acquire(owner: .mainStaging, bytes: 40))
        defer { withExtendedLifetime(lease) {} }
        let before = budget.snapshot

        #expect(budget.canAcquire([]))
        #expect(budget.canAcquire([(.mainStaging, -20), (.mainStaging, 20)]))
        #expect(budget.canAcquire([(.mainStaging, 10), (.mainStaging, 10)]))
        #expect(!budget.canAcquire([(.mainStaging, 11), (.mainStaging, 10)]))
        #expect(!budget.canAcquire([(.bitmapEvents, 10), (.bitmapEvents, 11)]))
        #expect(budget.canAcquire([(.pictureInPictureStaging, 60)]))
        #expect(!budget.canAcquire([(.pictureInPictureStaging, 61)]))
        #expect(!budget.canAcquire([(.pictureInPictureStaging, 50), (.mainStaging, 11)]))
        #expect(budget.snapshot == before)
    }

    @Test func zeroByteOwnerKeySurvivesUntilItsLastLeaseIsReleased() throws {
        let budget = SubtitleMemoryBudget(limitBytes: 64, ownerLimitsBytes: [:])
        var leases = [
            budget.acquire(owner: .mainStaging, bytes: 0),
            budget.acquire(owner: .mainStaging, bytes: -9),
            budget.acquire(owner: .mainStaging, bytes: 12),
            budget.acquire(owner: .bitmapEvents, bytes: 0),
        ]
        try #require(leases.allSatisfy { $0 != nil })
        #expect(leases[2]?.resize(to: 0) == true)
        #expect(budget.snapshot.reservationsByOwner == [.mainStaging: 0, .bitmapEvents: 0])

        leases[0] = nil
        leases[2] = nil
        #expect(budget.snapshot.reservationsByOwner == [.mainStaging: 0, .bitmapEvents: 0])
        leases[1] = nil
        #expect(budget.snapshot.reservationsByOwner == [.bitmapEvents: 0])
        leases[3] = nil
        #expect(budget.snapshot.reservationsByOwner.isEmpty)
        #expect(budget.snapshot.reservedBytes == 0)
    }

    @Test func retainedSnapshotsRemainStableAcrossMutationsAndRelease() throws {
        let budget = SubtitleMemoryBudget(limitBytes: 64, ownerLimitsBytes: [:])
        var leases = [budget.acquire(owner: .mainStaging, bytes: 16)]
        try #require(leases[0] != nil)
        let original = budget.snapshot
        #expect(leases[0]?.resize(to: 32) == true)
        leases.append(budget.acquire(owner: .bitmapEvents, bytes: 7))
        let resized = budget.snapshot
        #expect(budget.acquire(owner: .mainStaging, bytes: 64) == nil)
        leases.removeAll()

        #expect(original == SubtitleMemoryBudgetSnapshot(
            limitBytes: 64, reservedBytes: 16,
            reservationsByOwner: [.mainStaging: 16], rejectedAcquisitions: 0
        ))
        #expect(resized == SubtitleMemoryBudgetSnapshot(
            limitBytes: 64, reservedBytes: 39,
            reservationsByOwner: [.mainStaging: 32, .bitmapEvents: 7], rejectedAcquisitions: 0
        ))
        #expect(budget.snapshot.reservedBytes == 0)
        #expect(budget.snapshot.reservationsByOwner.isEmpty)
        #expect(budget.snapshot.rejectedAcquisitions == 1)
    }

    @Test(arguments: [0, -7])
    func nonpositiveGlobalLimitStillAllowsOneByte(limit: Int) throws {
        let budget = SubtitleMemoryBudget(limitBytes: limit, ownerLimitsBytes: [:])
        let lease = try #require(budget.acquire(owner: .mainStaging, bytes: -1))
        defer { withExtendedLifetime(lease) {} }
        #expect(budget.snapshot.limitBytes == 1)
        #expect(lease.resize(to: 1))
        #expect(!lease.resize(to: 2))
        #expect(!budget.canAcquire([(.bitmapEvents, 1)]))
        #expect(budget.snapshot.reservedBytes == 1)
        #expect(budget.snapshot.rejectedAcquisitions == 1)
    }

    @Test func leaseCanOutliveItsBudget() throws {
        var budget: SubtitleMemoryBudget? = SubtitleMemoryBudget(limitBytes: 64)
        let isBudgetReleased = { [weak budget] in budget == nil }
        var lease = budget?.acquire(owner: .mainStaging, bytes: 16)
        try #require(lease != nil)
        budget = nil

        #expect(isBudgetReleased())
        #expect(lease?.resize(to: 0) == false)
        lease = nil
    }

    @Test(arguments: [UInt64(1), 7, 0xC0FFEE, 0xDEADBEEF])
    func mixedOperationsMatchIndependentReservationModel(seed: UInt64) throws {
        let limits: [SubtitleMemoryOwner: Int] = [
            .mainStaging: 97, .bitmapEvents: 40, .mainLibass: 0,
        ]
        let budget = SubtitleMemoryBudget(limitBytes: 257, ownerLimitsBytes: limits)
        var model = BudgetReferenceModel(limit: 257, ownerLimits: limits)
        var random = BudgetTraceRandom(state: seed)
        let owners: [SubtitleMemoryOwner] = [
            .bitmapEvents, .mainLibass, .mainStaging,
            .pictureInPictureLibass, .pictureInPictureStaging,
        ]
        let sizes = [-17, -1, 0, 1, 2, 7, 31, 64, 95, 128, 400]
        var leases = [SubtitleMemoryBudget.Lease?](repeating: nil, count: 48)
        var snapshots: [(actual: SubtitleMemoryBudgetSnapshot, expected: SubtitleMemoryBudgetSnapshot)] = []

        for step in 0..<3_000 {
            let slot = random.next(leases.count)
            let owner = owners[random.next(owners.count)]
            let bytes = sizes[random.next(sizes.count)]
            switch random.next(5) {
            case 0:
                leases[slot] = nil
                model.reservations[slot] = nil
                let expected = model.acquire(slot: slot, owner: owner, bytes: bytes)
                leases[slot] = budget.acquire(owner: owner, bytes: bytes)
                try #require((leases[slot] != nil) == expected, "seed \(seed), step \(step)")
                if let lease = leases[slot] { #expect(lease.owner == owner) }
            case 1:
                if let lease = leases[slot] {
                    let expected = model.resize(slot: slot, bytes: bytes)
                    try #require(lease.resize(to: bytes) == expected, "seed \(seed), step \(step)")
                }
            case 2:
                leases[slot] = nil
                model.reservations[slot] = nil
            case 3:
                let requests = (0..<random.next(6)).map { _ in
                    (owner: owners[random.next(owners.count)], bytes: sizes[random.next(sizes.count)])
                }
                let expected = model.canAcquire(requests)
                try #require(budget.canAcquire(requests) == expected, "seed \(seed), step \(step)")
            default:
                if let reservation = model.reservations[slot] {
                    try #require(leases[slot]?.resize(to: reservation.bytes) == true)
                } else {
                    let expected = model.acquire(slot: slot, owner: owner, bytes: 0)
                    leases[slot] = budget.acquire(owner: owner, bytes: 0)
                    try #require((leases[slot] != nil) == expected)
                }
            }
            let actual = budget.snapshot
            let expected = model.snapshot
            try #require(actual == expected, "seed \(seed), step \(step)")
            if step.isMultiple(of: 173) { snapshots.append((actual, expected)) }
        }

        leases.removeAll()
        model.reservations.removeAll()
        #expect(budget.snapshot == model.snapshot)
        for saved in snapshots { #expect(saved.actual == saved.expected) }
    }

    @Test func concurrentAdmissionResizeAndReleasePreserveAccounting() async {
        let budget = SubtitleMemoryBudget(
            limitBytes: 128, ownerLimitsBytes: [.mainStaging: 96, .bitmapEvents: 96]
        )
        var leases = await withTaskGroup(of: [SubtitleMemoryBudget.Lease].self) { group in
            for worker in 0..<8 {
                group.addTask {
                    let owner: SubtitleMemoryOwner = worker.isMultiple(of: 2) ? .mainStaging : .bitmapEvents
                    return (0..<64).compactMap { _ in budget.acquire(owner: owner, bytes: 1) }
                }
            }
            var held: [SubtitleMemoryBudget.Lease] = []
            for await result in group { held.append(contentsOf: result) }
            return held
        }
        #expect(leases.count == 128)
        let full = budget.snapshot
        #expect(full.reservedBytes == 128)
        #expect(full.reservationsByOwner.values.reduce(0, +) == 128)

        #expect(full.reservationsByOwner.count == 2)
        #expect(full.reservationsByOwner.values.allSatisfy { $0 <= 96 })
        #expect(full.rejectedAcquisitions == 8 * 64 - 128)

        await withTaskGroup(of: Void.self) { group in
            for lease in leases {
                group.addTask {
                    #expect(!lease.resize(to: 2))
                    #expect(lease.resize(to: 1))
                }
            }
        }
        #expect(budget.snapshot.reservedBytes == 128)
        #expect(budget.snapshot.rejectedAcquisitions == 8 * 64)

        await withTaskGroup(of: Void.self) { group in
            for lease in leases { group.addTask { #expect(lease.resize(to: 0)) } }
        }
        #expect(budget.snapshot.reservedBytes == 0)
        #expect(budget.snapshot.reservationsByOwner == [.mainStaging: 0, .bitmapEvents: 0])
        leases.removeAll()
        #expect(budget.snapshot.reservationsByOwner.isEmpty)
        #expect(full.reservedBytes == 128)
        #expect(full.reservationsByOwner.values.reduce(0, +) == 128)

        // Keep at most one small lease per worker so every request must succeed,
        // while final releases race acquisitions for the same owner's zero key.
        await withTaskGroup(of: Void.self) { group in
            for worker in 0..<8 {
                group.addTask {
                    let owner: SubtitleMemoryOwner = worker.isMultiple(of: 2) ? .mainStaging : .bitmapEvents
                    for _ in 0..<64 {
                        var lease = budget.acquire(owner: owner, bytes: 1)
                        #expect(lease != nil)
                        #expect(lease?.resize(to: 4) == true)
                        #expect(lease?.resize(to: 0) == true)
                        lease = nil
                        let observed = budget.snapshot
                        #expect(observed.reservedBytes == observed.reservationsByOwner.values.reduce(0, +))
                        #expect(observed.reservedBytes <= 8 * 4)
                    }
                }
            }
        }
        #expect(budget.snapshot.reservedBytes == 0)
        #expect(budget.snapshot.reservationsByOwner.isEmpty)
        #expect(budget.snapshot.rejectedAcquisitions == 8 * 64)
    }
}

/// Recomputes admission from individual reservations instead of sharing the
/// production admission code. The small bounded traces cannot overflow Int sums.
private struct BudgetReferenceModel {
    struct Reservation {
        let owner: SubtitleMemoryOwner
        let bytes: Int
    }

    let limit: Int
    let ownerLimits: [SubtitleMemoryOwner: Int]
    var reservations: [Int: Reservation] = [:]
    var rejected = 0

    func canAcquire(_ requests: [(owner: SubtitleMemoryOwner, bytes: Int)]) -> Bool {
        var trial = Array(reservations.values)
        trial.append(contentsOf: requests.map { Reservation(owner: $0.owner, bytes: max(0, $0.bytes)) })
        guard trial.reduce(0, { $0 + $1.bytes }) <= max(1, limit) else { return false }
        return requests.allSatisfy { request in
            guard let ownerLimit = ownerLimits[request.owner] else { return true }
            return trial.filter { $0.owner == request.owner }.reduce(0, { $0 + $1.bytes }) <= ownerLimit
        }
    }

    mutating func acquire(slot: Int, owner: SubtitleMemoryOwner, bytes: Int) -> Bool {
        guard canAcquire([(owner, bytes)]) else {
            rejected += 1
            return false
        }
        reservations[slot] = Reservation(owner: owner, bytes: max(0, bytes))
        return true
    }

    mutating func resize(slot: Int, bytes: Int) -> Bool {
        guard let original = reservations.removeValue(forKey: slot) else { return false }
        if acquire(slot: slot, owner: original.owner, bytes: bytes) { return true }
        reservations[slot] = original
        return false
    }

    var snapshot: SubtitleMemoryBudgetSnapshot {
        var byOwner: [SubtitleMemoryOwner: Int] = [:]
        for reservation in reservations.values {
            byOwner[reservation.owner, default: 0] += reservation.bytes
        }
        return SubtitleMemoryBudgetSnapshot(
            limitBytes: max(1, limit),
            reservedBytes: reservations.values.reduce(0) { $0 + $1.bytes },
            reservationsByOwner: byOwner,
            rejectedAcquisitions: rejected
        )
    }
}

private struct BudgetTraceRandom {
    var state: UInt64

    mutating func next(_ upperBound: Int) -> Int {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Int((state >> 32) % UInt64(upperBound))
    }
}
