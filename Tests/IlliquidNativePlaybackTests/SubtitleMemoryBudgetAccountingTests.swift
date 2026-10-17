import Dispatch
import Foundation
import Testing
@testable import IlliquidNativePlayback

@Suite("Subtitle memory budget accounting")
struct SubtitleMemoryBudgetAccountingTests {
    private static let owners: [SubtitleMemoryOwner] = [
        .bitmapEvents,
        .mainLibass,
        .mainStaging,
        .pictureInPictureLibass,
        .pictureInPictureStaging,
    ]

    @Test
    func zeroByteReservationsKeepTheirOwnerUntilTheLastLeaseIsReleased() throws {
        let budget = SubtitleMemoryBudget(limitBytes: 10, ownerLimitsBytes: [:])
        var leases: [SubtitleMemoryBudget.Lease] = []
        for bytes in [0, Int.min, 7] {
            leases.append(try #require(budget.acquire(owner: .mainStaging, bytes: bytes)))
        }
        #expect(budget.snapshot.reservationsByOwner == [.mainStaging: 7])

        leases.removeLast()
        withExtendedLifetime(leases) {
            #expect(budget.snapshot.reservedBytes == 0)
            #expect(budget.snapshot.reservationsByOwner == [.mainStaging: 0])
        }
        #expect(leases[0].resize(to: 5))
        #expect(leases[0].resize(to: -1))
        leases.removeFirst()
        withExtendedLifetime(leases) {
            #expect(budget.snapshot.reservationsByOwner == [.mainStaging: 0])
        }
        leases.removeAll()
        #expect(budget.snapshot.reservedBytes == 0)
        #expect(budget.snapshot.reservationsByOwner.isEmpty)
        #expect(budget.snapshot.rejectedAcquisitions == 0)
    }

    @Test
    func rejectedGrowthPreservesBothTheLeaseAndOtherReservations() throws {
        let budget = SubtitleMemoryBudget(
            limitBytes: 20,
            ownerLimitsBytes: [.mainStaging: 12]
        )
        var leases = [
            try #require(budget.acquire(owner: .mainStaging, bytes: 8)),
            try #require(budget.acquire(owner: .mainStaging, bytes: 3)),
            try #require(budget.acquire(owner: .pictureInPictureStaging, bytes: 9)),
        ]
        #expect(budget.acquire(owner: .bitmapEvents, bytes: 1) == nil)
        #expect(!leases[0].resize(to: 9))
        #expect(!leases[1].resize(to: 6))
        #expect(budget.snapshot == SubtitleMemoryBudgetSnapshot(
            limitBytes: 20,
            reservedBytes: 20,
            reservationsByOwner: [.mainStaging: 11, .pictureInPictureStaging: 9],
            rejectedAcquisitions: 3
        ))

        leases.removeLast()
        #expect(leases[0].resize(to: 9))
        for _ in 0..<100 {
            #expect(leases[0].resize(to: 9))
        }
        #expect(!leases[1].resize(to: 4))
        #expect(leases[0].resize(to: 0))
        withExtendedLifetime(leases) {
            #expect(budget.snapshot.reservedBytes == 3)
            #expect(budget.snapshot.reservationsByOwner == [.mainStaging: 3])
            #expect(budget.snapshot.rejectedAcquisitions == 4)
        }
        leases.removeAll()
        #expect(budget.snapshot.reservedBytes == 0)
        #expect(budget.snapshot.reservationsByOwner.isEmpty)
    }

    @Test
    func preflightCombinesDuplicateOwnersAndDoesNotReserveOrReject() throws {
        let budget = SubtitleMemoryBudget(
            limitBytes: 10,
            ownerLimitsBytes: [
                .mainStaging: 4,
                .pictureInPictureStaging: 0,
                .pictureInPictureLibass: -1,
            ]
        )
        let lease = try #require(budget.acquire(owner: .mainStaging, bytes: 3))
        let original = budget.snapshot
        #expect(budget.canAcquire([]))
        #expect(budget.canAcquire([(.mainStaging, -100), (.mainStaging, 1)]))
        #expect(!budget.canAcquire([(.mainStaging, 1), (.mainStaging, 1)]))
        #expect(budget.canAcquire([(.pictureInPictureStaging, 0), (.bitmapEvents, 7)]))
        #expect(!budget.canAcquire([(.pictureInPictureStaging, 1)]))
        #expect(!budget.canAcquire([(.pictureInPictureLibass, 0)]))
        #expect(!budget.canAcquire([(.bitmapEvents, 4), (.mainLibass, 4)]))
        #expect(!budget.canAcquire([(.bitmapEvents, 8)]))
        withExtendedLifetime(lease) {
            #expect(budget.snapshot == original)
            #expect(budget.acquire(owner: .pictureInPictureLibass, bytes: 0) == nil)
            #expect(budget.snapshot.rejectedAcquisitions == 1)
            #expect(budget.snapshot.reservationsByOwner == [.mainStaging: 3])
        }
    }

    @Test(arguments: [0, -7, Int.min])
    func nonpositiveGlobalLimitsStillAllowOneByte(limit: Int) throws {
        let budget = SubtitleMemoryBudget(limitBytes: limit, ownerLimitsBytes: [:])
        var leases = [try #require(budget.acquire(owner: .bitmapEvents, bytes: 1))]
        #expect(budget.snapshot.limitBytes == 1)
        #expect(budget.acquire(owner: .mainStaging, bytes: 1) == nil)
        leases.append(try #require(budget.acquire(owner: .mainStaging, bytes: -4)))
        withExtendedLifetime(leases) {
            #expect(budget.snapshot.reservedBytes == 1)
            #expect(budget.snapshot.reservationsByOwner == [.bitmapEvents: 1, .mainStaging: 0])
        }
        leases.removeAll()
        #expect(budget.snapshot.reservationsByOwner.isEmpty)
    }

    @Test(arguments: [false, true])
    func accountingHandlesTheFullIntegerCapacity(withOwnerLimit: Bool) throws {
        let budget = SubtitleMemoryBudget(
            limitBytes: Int.max,
            ownerLimitsBytes: withOwnerLimit ? [.mainStaging: Int.max] : [:]
        )
        var leases = [
            try #require(budget.acquire(owner: .mainStaging, bytes: Int.max)),
            try #require(budget.acquire(owner: .pictureInPictureStaging, bytes: 0)),
        ]
        #expect(budget.acquire(owner: .bitmapEvents, bytes: 1) == nil)
        #expect(!leases[1].resize(to: 1))
        #expect(budget.snapshot.reservedBytes == Int.max)
        #expect(leases[0].resize(to: 0))
        #expect(budget.snapshot.reservedBytes == 0)
        #expect(leases[0].resize(to: Int.max))
        #expect(leases[0].resize(to: Int.max))
        #expect(budget.canAcquire([(.mainStaging, 0), (.pictureInPictureStaging, 0)]))
        #expect(!budget.canAcquire([(.bitmapEvents, 1)]))
        withExtendedLifetime(leases) {
            #expect(budget.snapshot.reservationsByOwner == [
                .mainStaging: Int.max,
                .pictureInPictureStaging: 0,
            ])
            #expect(budget.snapshot.rejectedAcquisitions == 2)
        }
        leases.removeFirst()
        withExtendedLifetime(leases) {
            #expect(budget.snapshot.reservedBytes == 0)
            #expect(budget.snapshot.reservationsByOwner == [.pictureInPictureStaging: 0])
        }
        leases.removeAll()
        #expect(budget.snapshot.reservationsByOwner.isEmpty)
    }

    @Test
    func previouslyReturnedSnapshotsDoNotChangeAfterUpdates() throws {
        let budget = SubtitleMemoryBudget(limitBytes: 20, ownerLimitsBytes: [:])
        let empty = budget.snapshot
        var leases = [try #require(budget.acquire(owner: .mainLibass, bytes: 8))]
        let acquired = budget.snapshot
        #expect(leases[0].resize(to: 2))
        let resized = budget.snapshot
        leases.append(try #require(budget.acquire(owner: .mainLibass, bytes: 4)))
        let overlapping = budget.snapshot
        leases.removeAll()

        #expect(empty.reservedBytes == 0)
        #expect(empty.reservationsByOwner.isEmpty)
        #expect(acquired.reservedBytes == 8)
        #expect(acquired.reservationsByOwner == [.mainLibass: 8])
        #expect(resized.reservedBytes == 2)
        #expect(resized.reservationsByOwner == [.mainLibass: 2])
        #expect(overlapping.reservedBytes == 6)
        #expect(overlapping.reservationsByOwner == [.mainLibass: 6])
        #expect(budget.snapshot == empty)
    }

    @Test
    func aliasesReleaseAReservationOnlyWhenTheFinalReferenceIsDropped() throws {
        let budget = SubtitleMemoryBudget(limitBytes: 20, ownerLimitsBytes: [:])
        var aliases = [try #require(budget.acquire(owner: .mainLibass, bytes: 8))]
        aliases.append(aliases[0])
        aliases.removeFirst()
        withExtendedLifetime(aliases) {
            #expect(budget.snapshot.reservedBytes == 8)
            #expect(budget.snapshot.reservationsByOwner == [.mainLibass: 8])
        }
        aliases.removeAll()
        #expect(budget.snapshot.reservationsByOwner.isEmpty)
    }

    @Test
    func leasesDoNotKeepAnOrphanedBudgetAlive() throws {
        var budget: SubtitleMemoryBudget? = SubtitleMemoryBudget(
            limitBytes: 20,
            ownerLimitsBytes: [:]
        )
        let budgetIsAlive = { [weak budget] in budget != nil }
        var leases = [try #require(budget?.acquire(owner: .bitmapEvents, bytes: 8))]
        let leaseIsAlive = { [weak lease = leases[0]] in lease != nil }
        #expect(budgetIsAlive())
        #expect(leaseIsAlive())
        budget = nil
        #expect(!budgetIsAlive())
        #expect(!leases[0].resize(to: 8))
        #expect(!leases[0].resize(to: 0))
        leases.removeAll()
        #expect(!leaseIsAlive())
    }

    @Test(arguments: [UInt64(1), 42, 0x1234_5678_9ABC_DEF0, 0xDEAD_BEEF])
    func mixedOperationsMatchAnIndependentScanOracle(seed: UInt64) throws {
        let configurations: [(limit: Int, owners: [SubtitleMemoryOwner: Int])] = [
            (97, [:]),
            (97, [.mainStaging: 23, .pictureInPictureStaging: 0]),
            (67, Dictionary(uniqueKeysWithValues: Self.owners.map { ($0, 21) })),
            (0, [.bitmapEvents: 0, .mainLibass: 1, .pictureInPictureStaging: -1]),
        ]
        for (configurationIndex, configuration) in configurations.enumerated() {
            let budget = SubtitleMemoryBudget(
                limitBytes: configuration.limit,
                ownerLimitsBytes: configuration.owners
            )
            var oracle = SubtitleBudgetScanOracle(
                limit: configuration.limit,
                ownerLimits: configuration.owners
            )
            var random = SubtitleBudgetRandom(seed: seed)
            var leases: [Int: SubtitleMemoryBudget.Lease] = [:]
            var nextID = 0

            for step in 0..<2_000 {
                let operation = step < Self.owners.count ? 0 : random.index(100)
                let owner = Self.owners[step < Self.owners.count ? step : random.index(Self.owners.count)]
                let sizes = [-20, -1, 0, 0, 1, 3, 7, 16, 23, 67, 98]
                let bytes = step < Self.owners.count ? 0 : sizes[random.index(sizes.count)]

                if operation < 30 {
                    nextID += 1
                    let expected = oracle.acquire(id: nextID, owner: owner, bytes: bytes)
                    let lease = budget.acquire(owner: owner, bytes: bytes)
                    try #require((lease != nil) == expected,
                                 "acquire: seed \(seed), config \(configurationIndex), step \(step)")
                    if let lease {
                        #expect(lease.owner == owner)
                        leases[nextID] = lease
                    }
                } else if operation < 65, !oracle.entries.isEmpty {
                    let entry = oracle.entries[random.index(oracle.entries.count)]
                    let requested = step.isMultiple(of: 3) ? entry.bytes : bytes
                    let expected = oracle.resize(id: entry.id, bytes: requested)
                    let lease = try #require(leases[entry.id])
                    try #require(lease.resize(to: requested) == expected,
                                 "resize: seed \(seed), config \(configurationIndex), step \(step)")
                } else if operation < 85, !oracle.entries.isEmpty {
                    let id = oracle.entries[random.index(oracle.entries.count)].id
                    leases[id] = nil
                    oracle.release(id: id)
                } else {
                    let requests = (0..<random.index(7)).map { _ in
                        (owner: Self.owners[random.index(Self.owners.count)],
                         bytes: sizes[random.index(sizes.count)])
                    }
                    try #require(budget.canAcquire(requests) == oracle.canAcquire(requests),
                                 "preflight: seed \(seed), config \(configurationIndex), step \(step)")
                }
                try withExtendedLifetime(leases) {
                    try #require(budget.snapshot == oracle.snapshot,
                                 "snapshot: seed \(seed), config \(configurationIndex), step \(step)")
                }
            }

            for id in oracle.entries.map(\.id).reversed() {
                leases[id] = nil
                oracle.release(id: id)
                try withExtendedLifetime(leases) {
                    try #require(budget.snapshot == oracle.snapshot,
                                 "release: seed \(seed), config \(configurationIndex), id \(id)")
                }
            }
            #expect(budget.snapshot.reservationsByOwner.isEmpty)
        }
    }

    @Test
    func concurrentReservationsRespectLimitsAndReturnToKnownBaseline() throws {
        let ownerLimits = Dictionary(uniqueKeysWithValues: Self.owners.map { ($0, 23) })
        let budget = SubtitleMemoryBudget(limitBytes: 83, ownerLimitsBytes: ownerLimits)
        var baseline = try Self.owners.map {
            try #require(budget.acquire(owner: $0, bytes: 3))
        }
        let results = SubtitleBudgetConcurrentResults()

        DispatchQueue.concurrentPerform(iterations: 16) { worker in
            var random = SubtitleBudgetRandom(seed: UInt64(worker + 1))
            var rejected = 0
            var invalidSnapshots = 0
            for iteration in 0..<500 {
                var leases: [SubtitleMemoryBudget.Lease] = []
                for _ in 0..<3 {
                    let owner = Self.owners[random.index(Self.owners.count)]
                    if let lease = budget.acquire(owner: owner, bytes: random.index(31) - 2) {
                        leases.append(lease)
                    } else {
                        rejected += 1
                    }
                }
                for lease in leases {
                    if !lease.resize(to: random.index(31) - 2) { rejected += 1 }
                    if !lease.resize(to: 0) { invalidSnapshots += 1 }
                }
                if iteration.isMultiple(of: 10) {
                    if budget.acquire(owner: .bitmapEvents, bytes: 84) == nil {
                        rejected += 1
                    } else {
                        invalidSnapshots += 1
                    }
                }
                _ = budget.canAcquire([(.mainStaging, 24), (.mainStaging, -1)])
                let snapshot = budget.snapshot
                if snapshot.reservedBytes != snapshot.reservationsByOwner.values.reduce(0, +)
                    || !(15...83).contains(snapshot.reservedBytes)
                    || Set(snapshot.reservationsByOwner.keys) != Set(Self.owners)
                    || snapshot.reservationsByOwner.contains(where: { !((3...23).contains($0.value)) })
                {
                    invalidSnapshots += 1
                }
                leases.removeAll()
            }
            results.record(rejected: rejected, invalidSnapshots: invalidSnapshots)
        }

        let result = results.snapshot
        #expect(result.invalidSnapshots == 0)
        #expect(result.rejected > 0)
        withExtendedLifetime(baseline) {
            #expect(budget.snapshot == SubtitleMemoryBudgetSnapshot(
                limitBytes: 83,
                reservedBytes: 15,
                reservationsByOwner: Dictionary(uniqueKeysWithValues: Self.owners.map { ($0, 3) }),
                rejectedAcquisitions: result.rejected
            ))
        }
        baseline.removeAll()
        #expect(budget.snapshot.reservedBytes == 0)
        #expect(budget.snapshot.reservationsByOwner.isEmpty)
    }

    @Test
    func concurrentResizesOfSharedLeasesKeepZeroByteOwnersAndReleaseExactlyOnce() throws {
        let budget = SubtitleMemoryBudget(
            limitBytes: 50,
            ownerLimitsBytes: Dictionary(uniqueKeysWithValues: Self.owners.map { ($0, 10) })
        )
        var leases = try Self.owners.map {
            try #require(budget.acquire(owner: $0, bytes: 1))
        }
        let results = SubtitleBudgetConcurrentResults()
        // Capture an immutable array for simultaneous access to the same leases.
        withExtendedLifetime(leases) { sharedLeases in
            DispatchQueue.concurrentPerform(iterations: 12) { worker in
                var invalidSnapshots = 0
                for iteration in 0..<1_000 {
                    let index = (worker + iteration) % sharedLeases.count
                    if !sharedLeases[index].resize(to: iteration % 11) {
                        invalidSnapshots += 1
                    }
                    let snapshot = budget.snapshot
                    if snapshot.reservedBytes != snapshot.reservationsByOwner.values.reduce(0, +)
                        || !(0...50).contains(snapshot.reservedBytes)
                        || Set(snapshot.reservationsByOwner.keys) != Set(Self.owners)
                        || snapshot.reservationsByOwner.contains(where: { !((0...10).contains($0.value)) })
                    {
                        invalidSnapshots += 1
                    }
                }
                results.record(rejected: 0, invalidSnapshots: invalidSnapshots)
            }
        }
        #expect(results.snapshot.invalidSnapshots == 0)
        for lease in leases { #expect(lease.resize(to: 0)) }
        withExtendedLifetime(leases) {
            #expect(budget.snapshot.reservationsByOwner ==
                    Dictionary(uniqueKeysWithValues: Self.owners.map { ($0, 0) }))
            #expect(budget.snapshot.rejectedAcquisitions == 0)
        }
        leases.removeAll()
        #expect(budget.snapshot.reservedBytes == 0)
        #expect(budget.snapshot.reservationsByOwner.isEmpty)
    }
}

/// The reference keeps only live reservations and tests complete hypothetical
/// lists. It intentionally has no cached total, owner total, or owner count.
private struct SubtitleBudgetScanOracle {
    struct Entry {
        let id: Int
        let owner: SubtitleMemoryOwner
        var bytes: Int
    }

    let limit: Int
    let ownerLimits: [SubtitleMemoryOwner: Int]
    var entries: [Entry] = []
    private var rejected = 0

    init(limit: Int, ownerLimits: [SubtitleMemoryOwner: Int]) {
        self.limit = max(1, limit)
        self.ownerLimits = ownerLimits
    }

    mutating func acquire(id: Int, owner: SubtitleMemoryOwner, bytes: Int) -> Bool {
        let entry = Entry(id: id, owner: owner, bytes: max(0, bytes))
        guard fits(entries + [entry], checking: [owner]) else {
            rejected += 1
            return false
        }
        entries.append(entry)
        return true
    }

    mutating func resize(id: Int, bytes: Int) -> Bool {
        guard let index = entries.firstIndex(where: { $0.id == id }) else {
            preconditionFailure("The test attempted to resize an unknown reservation")
        }
        var proposed = entries
        proposed[index].bytes = max(0, bytes)
        guard fits(proposed, checking: [entries[index].owner]) else {
            rejected += 1
            return false
        }
        entries = proposed
        return true
    }

    mutating func release(id: Int) {
        entries.removeAll { $0.id == id }
    }

    func canAcquire(_ requests: [(owner: SubtitleMemoryOwner, bytes: Int)]) -> Bool {
        let proposed = requests.map { Entry(id: -1, owner: $0.owner, bytes: max(0, $0.bytes)) }
        return fits(entries + proposed, checking: Set(requests.map(\.owner)))
    }

    var snapshot: SubtitleMemoryBudgetSnapshot {
        let groups = Dictionary(grouping: entries, by: \.owner)
        return SubtitleMemoryBudgetSnapshot(
            limitBytes: limit,
            reservedBytes: entries.reduce(0) { $0 + $1.bytes },
            reservationsByOwner: groups.mapValues { $0.reduce(0) { $0 + $1.bytes } },
            rejectedAcquisitions: rejected
        )
    }

    private func fits(_ proposed: [Entry], checking owners: Set<SubtitleMemoryOwner>) -> Bool {
        guard proposed.reduce(0, { $0 + $1.bytes }) <= limit else { return false }
        return owners.allSatisfy { owner in
            guard let cap = ownerLimits[owner] else { return true }
            return proposed.filter { $0.owner == owner }.reduce(0) { $0 + $1.bytes } <= cap
        }
    }
}

private struct SubtitleBudgetRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func index(_ upperBound: Int) -> Int {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Int((state >> 32) % UInt64(upperBound))
    }
}

private final class SubtitleBudgetConcurrentResults: @unchecked Sendable {
    private let lock = NSLock()
    private var rejected = 0
    private var invalidSnapshots = 0

    func record(rejected: Int, invalidSnapshots: Int) {
        lock.withLock {
            self.rejected += rejected
            self.invalidSnapshots += invalidSnapshots
        }
    }

    var snapshot: (rejected: Int, invalidSnapshots: Int) {
        lock.withLock { (rejected, invalidSnapshots) }
    }
}
