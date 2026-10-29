import Foundation
import Testing
@testable import IlliquidCore

@Suite("Thumbnail refinement schedule")
struct ThumbnailRefinementOrderTests {
    @Test(arguments: [0, 1, 63, 64, 65, 80])
    func videoAndSampleCapsPreserveExactOrder(videoCount: Int) throws {
        for sampleCount in [0, 1, 6, 12, 24, 63, 64, 65, 80] {
            let plans = (0..<videoCount).map { video in
                (0..<sampleCount).map { Double(video * 1_000 + $0) }
            }
            for visit in refinementVisitLimits {
                let result = ThumbnailPolicy.refinementOrder(plans, maximumPerVisit: visit)
                try #require(refinementReceipt(result) == refinementOracle(plans, visit: visit))
                #expect(result.count == min(videoCount, 64) * min(sampleCount, 64))
                #expect(result.allSatisfy { (0..<64).contains($0.video) })
            }
        }
    }

    @Test func raggedPlansKeepOriginalVideoIndicesAndBoundedVisits() {
        let plans: [[Double]] = [[10, 11, 12], [], [20], [30, 31, 32]]
        let result = ThumbnailPolicy.refinementOrder(plans, maximumPerVisit: 2)
        #expect(result.map(\.video) == [0, 0, 2, 3, 3, 0, 3])
        #expect(result.map(\.position) == [10, 11, 20, 30, 31, 12, 32])
        #expect(refinementReceipt(ThumbnailPolicy.refinementOrder(plans))
            == refinementOracle(plans, visit: 4))
        #expect(ThumbnailPolicy.refinementOrder([]).isEmpty)
        #expect(ThumbnailPolicy.refinementOrder([[], [], []]).isEmpty)
    }

    @Test func mixedBoundaryLengthsKeepShortAndEmptyVideosInPlace() throws {
        let lengths = [0, 1, 6, 12, 24, 63, 64, 65, 80]
        let plans = (0..<80).map { video in
            (0..<lengths[video % lengths.count]).map { Double(video * 1_000 + $0) }
        }
        for visit in refinementVisitLimits {
            let result = ThumbnailPolicy.refinementOrder(plans, maximumPerVisit: visit)
            try #require(refinementReceipt(result) == refinementOracle(plans, visit: visit))
        }
    }

    @Test func positionsAreCopiedWithoutFloatingPointNormalization() throws {
        let bitPatterns: [UInt64] = [
            0x0000_0000_0000_0000, 0x8000_0000_0000_0000,
            0x7ff0_0000_0000_0000, 0xfff0_0000_0000_0000,
            0x7ff8_0000_0000_0001, 0xfff8_0000_0000_1234,
            0x7ff0_0000_0000_0001, 0x0000_0000_0000_0001,
            0x8000_0000_0000_0001, 0x7fef_ffff_ffff_ffff,
        ]
        let positions = bitPatterns.map { Double(bitPattern: $0) }
        let plans = [positions, [], Array(positions.reversed()), positions]
        for visit in refinementVisitLimits {
            let result = ThumbnailPolicy.refinementOrder(plans, maximumPerVisit: visit)
            try #require(refinementReceipt(result) == refinementOracle(plans, visit: visit))
        }
    }

    @Test(arguments: Array(0..<128))
    func deterministicRaggedCorpusMatchesSortedSchedule(seed: Int) throws {
        var random = RefinementTestRandom(state: UInt64(seed) &+ 0x6a09_e667_f3bc_c909)
        let count = Int(random.next() % 81)
        var plans: [[Double]] = []
        for _ in 0..<count {
            let length = Int(random.next() % 81)
            plans.append((0..<length).map { _ in Double(bitPattern: random.next()) })
        }
        let visit = refinementVisitLimits[seed % refinementVisitLimits.count]
        let result = ThumbnailPolicy.refinementOrder(plans, maximumPerVisit: visit)
        try #require(refinementReceipt(result) == refinementOracle(plans, visit: visit),
                     "seed \(seed), visit \(visit)")
    }

    @Test func inputSnapshotsAndReturnedSchedulesRemainIndependent() {
        var plans: [[Double]] = [[-0.0, 1, 2, 3, 4], [], [10, 11, 12]]
        let snapshot = plans
        let originalBits = plans.map { $0.map(\.bitPattern) }
        var result = ThumbnailPolicy.refinementOrder(plans, maximumPerVisit: 2)
        let savedResult = result
        let expected = refinementOracle(snapshot, visit: 2)
        #expect(plans.map { $0.map(\.bitPattern) } == originalBits)

        plans[0][0] = 99
        plans[1].append(100)
        plans.removeLast()
        #expect(refinementReceipt(result) == expected)
        #expect(snapshot.map { $0.map(\.bitPattern) } == originalBits)

        let changedInputBits = plans.map { $0.map(\.bitPattern) }
        result[0] = (video: 63, position: .infinity)
        result.removeLast()
        #expect(refinementReceipt(savedResult) == expected)
        #expect(plans.map { $0.map(\.bitPattern) } == changedInputBits)
        #expect(snapshot.map { $0.map(\.bitPattern) } == originalBits)
    }
}

private let refinementVisitLimits = [Int.min, -1, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, Int.max]

private struct RefinementOrderItem: Equatable {
    let video: Int
    let bits: UInt64
}

private func refinementReceipt(
    _ result: [(video: Int, position: Double)]
) -> [RefinementOrderItem] {
    result.map { RefinementOrderItem(video: $0.video, bits: $0.position.bitPattern) }
}

/// State the schedule as a global order over retained positions. Sorting by
/// visit, video, and position avoids the production stride and slice traversal.
private func refinementOracle(_ plans: [[Double]], visit requested: Int) -> [RefinementOrderItem] {
    let visit: Int
    if requested < 1 { visit = 1 }
    else if requested > 8 { visit = 8 }
    else { visit = requested }

    var indexed: [(video: Int, index: Int, bits: UInt64)] = []
    for (video, positions) in plans.enumerated() where video < 64 {
        for (index, position) in positions.enumerated() where index < 64 {
            indexed.append((video, index, position.bitPattern))
        }
    }
    indexed.sort { left, right in
        let leftVisit = left.index / visit
        let rightVisit = right.index / visit
        if leftVisit != rightVisit { return leftVisit < rightVisit }
        if left.video != right.video { return left.video < right.video }
        return left.index < right.index
    }
    return indexed.map { RefinementOrderItem(video: $0.video, bits: $0.bits) }
}

private struct RefinementTestRandom {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
}
