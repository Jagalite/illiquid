import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Testing
@testable import IlliquidNativePlayback

@Suite("Bitmap subtitle timeline lookup")
struct BitmapSubtitleLookupTests {
    @Test(arguments: [0, 1, 2, 3, 4, 5, 7, 8, 9, 31, 32, 127, 128])
    func timestampBoundariesReturnCompleteOriginalDisplays(count: Int) throws {
        let budget = SubtitleMemoryBudget(
            limitBytes: 4_096, ownerLimitsBytes: [.bitmapEvents: 4_096]
        )
        var timeline = BitmapSubtitleTimeline(
            maximumEntries: max(1, count), maximumBytes: 4_096
        )
        timeline.reset(generation: 23)
        let starts = (0..<count).map { Double($0) * 2 - 8 }
        var displays: [NativeBitmapSubtitleComposition] = []
        for index in 0..<count {
            let lease = try #require(budget.acquire(owner: .bitmapEvents, bytes: 20))
            displays.append(display(UInt8(index), lease: lease))
        }
        // Reverse delivery exercises the established ordering invariant without
        // assuming the lookup method's search strategy.
        for index in starts.indices.reversed() {
            try insert(displays[index], at: starts[index], into: &timeline)
        }

        let revision = timeline.revision
        let retainedBytes = timeline.retainedBytes
        if count == 0 {
            for query in [-Double.greatestFiniteMagnitude, -1, -0.0, 0, 1, Double.greatestFiniteMagnitude] {
                #expect(timeline.composition(at: query) == nil)
            }
        } else {
            // Alternate between opposite ends; correctness cannot depend on
            // callers advancing the clock monotonically.
            for ordinal in 0..<count {
                let index = ordinal.isMultiple(of: 2) ? ordinal / 2 : count - 1 - ordinal / 2
                let start = starts[index]
                if index == 0 {
                    #expect(timeline.composition(at: start.nextDown) == nil)
                } else {
                    expectSelection(timeline, at: start.nextDown,
                                    start: starts[index - 1], value: displays[index - 1])
                }
                expectSelection(timeline, at: start, start: start, value: displays[index])
                expectSelection(timeline, at: start.nextUp, start: start, value: displays[index])
                expectSelection(timeline, at: start + 1, start: start, value: displays[index])
            }
            expectSelection(timeline, at: Double.greatestFiniteMagnitude,
                            start: starts[count - 1], value: displays[count - 1])
        }
        #expect(timeline.generation == 23)
        #expect(timeline.revision == revision)
        #expect(timeline.retainedBytes == retainedBytes)
        #expect(retainedBytes == count * 20)
        #expect(budget.snapshot.reservedBytes == count * 20)
    }

    @Test func nonfiniteQueriesNeverSelectAnIndefiniteTail() throws {
        let empty = BitmapSubtitleTimeline()
        var populated = BitmapSubtitleTimeline()
        let first = display(1)
        let last = display(2)
        try insert(first, at: -10, into: &populated)
        try insert(last, at: 10, into: &populated)
        let queries: [Double] = [
            .infinity, -.infinity, .nan,
            Double(bitPattern: 0x7FF8_0000_0000_0001),
            Double(bitPattern: 0xFFF8_0000_0000_0001),
        ]
        for query in queries {
            #expect(empty.composition(at: query) == nil)
            #expect(populated.composition(at: query) == nil)
        }
        expectSelection(populated, at: Double.greatestFiniteMagnitude, start: 10, value: last)
        expectSelection(populated, at: -10, start: -10, value: first)
    }

    @Test(arguments: [false, true])
    func signedZeroReplacementKeepsTheIncomingStartBits(negativeFirst: Bool) throws {
        let initial: Double = negativeFirst ? -0.0 : 0.0
        let replacement: Double = negativeFirst ? 0.0 : -0.0
        for hasFutureEntry in [false, true] {
            var timeline = BitmapSubtitleTimeline(maximumEntries: 4)
            let previous = display(10)
            let originalZero = display(11)
            let replacedZero = display(12)
            try insert(previous, at: -2, into: &timeline)
            try insert(originalZero, at: initial, into: &timeline)
            if hasFutureEntry {
                try insert(display(13), at: 2, into: &timeline)
            }
            try insert(replacedZero, at: replacement, into: &timeline)
            for query in [-0.0, 0.0, Double.zero.nextUp, 1] {
                expectSelection(timeline, at: query, start: replacement, value: replacedZero)
            }
            expectSelection(timeline, at: Double.zero.nextDown, start: -2, value: previous)
            #expect(timeline.retainedBytes == (hasFutureEntry ? 3 : 2) * 20)
        }
    }

    @Test func expiryAndExplicitClearsNeverResurrectAnEarlierDisplay() throws {
        let starts: [Double] = [0, 10, 20, 30, 40, 50]
        let displays = [
            display(20),
            display(21, duration: 2),
            display(22, clear: true),
            display(23, duration: 0.25, clear: true),
            display(24),
            display(25, duration: 2),
        ]
        var timeline = BitmapSubtitleTimeline()
        for index in starts.indices {
            try insert(displays[index], at: starts[index], into: &timeline)
        }
        // Expected entry indices are authored explicitly. Expiry applies only
        // after selecting the latest start, including empty display sets.
        let queries: [(Double, Int?)] = [
            (-1, nil), (0, 0), (10.0.nextDown, 0),
            (10, 1), (12.0.nextDown, 1), (12, nil), (20.0.nextDown, nil),
            (20, 2), (30.0.nextDown, 2),
            (30, 3), (30.25.nextDown, 3), (30.25, nil), (40.0.nextDown, nil),
            (40, 4), (50.0.nextDown, 4),
            (50, 5), (52.0.nextDown, 5), (52, nil), (Double.greatestFiniteMagnitude, nil),
        ]
        for (query, expectedIndex) in queries.reversed() {
            if let index = expectedIndex {
                expectSelection(timeline, at: query, start: starts[index], value: displays[index])
            } else {
                #expect(timeline.composition(at: query) == nil)
            }
        }
    }

    @Test func replacementsPruningAndValueCopiesKeepIndependentLookupResults() throws {
        let first = display(30)
        let second = display(31)
        let third = display(32)
        let last = display(33)
        var original = BitmapSubtitleTimeline(maximumEntries: 8)
        try insert(last, at: 30, into: &original)
        try insert(second, at: 10, into: &original)
        try insert(first, at: 0, into: &original)
        try insert(third, at: 20, into: &original)
        let retainedResult = try #require(original.composition(at: 20))
        var copy = original
        let replacement = display(34, duration: 3)
        let added = display(35)
        try insert(replacement, at: 20, into: &copy)
        try insert(added, at: 15, into: &copy)

        expectSelection(original, at: 15, start: 10, value: second)
        expectSelection(copy, at: 15, start: 15, value: added)
        expectSelection(original, at: 25, start: 20, value: third)
        #expect(copy.composition(at: 25) == nil)
        #expect(LookupDisplaySnapshot(retainedResult) == LookupDisplaySnapshot((20, third)))

        copy.prune(before: 21)
        #expect(copy.composition(at: 15) == nil)
        expectSelection(copy, at: 21, start: 20, value: replacement)
        #expect(copy.composition(at: 23) == nil)
        expectSelection(copy, at: 30, start: 30, value: last)
        expectSelection(original, at: 0, start: 0, value: first)
        expectSelection(original, at: 20, start: 20, value: third)

        original.reset(generation: 9)
        #expect(original.composition(at: 20) == nil)
        expectSelection(copy, at: 21, start: 20, value: replacement)
        expectSelection(copy, at: 100, start: 30, value: last)
        #expect(LookupDisplaySnapshot(retainedResult) == LookupDisplaySnapshot((20, third)))
    }

    @Test func extremeFiniteTimesPreserveComparisonAndDurationArithmetic() throws {
        let maximum = Double.greatestFiniteMagnitude
        let negative = display(40, duration: maximum)
        let middle = display(41)
        let tail = display(42, duration: maximum)
        var timeline = BitmapSubtitleTimeline()
        try insert(tail, at: maximum, into: &timeline)
        try insert(negative, at: -maximum, into: &timeline)
        try insert(middle, at: 0, into: &timeline)

        expectSelection(timeline, at: -maximum, start: -maximum, value: negative)
        expectSelection(timeline, at: Double.zero.nextDown, start: -maximum, value: negative)
        expectSelection(timeline, at: 0, start: 0, value: middle)
        expectSelection(timeline, at: maximum.nextDown, start: 0, value: middle)
        // Finite start + finite duration may overflow to infinity. Preserve
        // the existing duration comparison rather than rejecting that entry.
        expectSelection(timeline, at: maximum, start: maximum, value: tail)
        #expect(timeline.composition(at: .infinity) == nil)
        #expect(timeline.composition(at: -.infinity) == nil)

        // Positive durations can round back to their start at this magnitude.
        var rounded = BitmapSubtitleTimeline()
        try insert(display(43, duration: Double.leastNonzeroMagnitude),
                   at: maximum, into: &rounded)
        #expect(rounded.composition(at: maximum) == nil)
    }

    private func insert(_ value: NativeBitmapSubtitleComposition, at start: Double,
                        into timeline: inout BitmapSubtitleTimeline) throws {
        let accepted = timeline.insert(value, at: start, generation: timeline.generation)
        try #require(accepted)
    }

    private func expectSelection(_ timeline: BitmapSubtitleTimeline, at query: Double,
                                 start: Double, value: NativeBitmapSubtitleComposition) {
        let actual = timeline.composition(at: query).map(LookupDisplaySnapshot.init)
        let expected = LookupDisplaySnapshot((start, value))
        #expect(actual == expected, "Complete display for query \(query)")
    }

    private func display(_ marker: UInt8, duration: Double? = nil,
                         clear: Bool = false, lease: SubtitleMemoryBudget.Lease? = nil)
        -> NativeBitmapSubtitleComposition {
        let regions: [NativeBitmapSubtitleRegion] = clear ? [] : [
            NativeBitmapSubtitleRegion(
                pixels: Data(repeating: marker, count: 8),
                frame: CGRect(x: CGFloat(marker), y: 3, width: 2, height: 1),
                isForced: marker.isMultiple(of: 2)
            ),
            NativeBitmapSubtitleRegion(
                pixels: Data(repeating: marker &+ 37, count: 12),
                frame: CGRect(x: 5, y: CGFloat(marker) + 1, width: 3, height: 1),
                isForced: !marker.isMultiple(of: 2)
            ),
        ]
        return NativeBitmapSubtitleComposition(
            regions: regions,
            canvasSize: CGSize(width: 1_920 + CGFloat(marker), height: 1_080 + CGFloat(marker)),
            duration: duration,
            memoryLease: lease
        )
    }
}

private struct LookupDisplaySnapshot: Equatable {
    struct Region: Equatable {
        let pixels: Data
        let frame: CGRect
        let isForced: Bool
    }

    let startBits: UInt64
    let canvas: CGSize
    let durationBits: UInt64?
    let regions: [Region]
    let leaseIdentity: ObjectIdentifier?

    init(_ result: (start: Double, value: NativeBitmapSubtitleComposition)) {
        startBits = result.start.bitPattern
        canvas = result.value.canvasSize
        durationBits = result.value.duration?.bitPattern
        regions = result.value.regions.map {
            Region(pixels: $0.pixels, frame: $0.frame, isForced: $0.isForced)
        }
        leaseIdentity = result.value.memoryLease.map(ObjectIdentifier.init)
    }
}
