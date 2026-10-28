import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Testing
@testable import IlliquidNativePlayback

@Suite("Bitmap subtitle timeline lookup boundaries")
struct BitmapSubtitleTimelineLookupTests {
    @Test(arguments: [0, 1, 2, 4, 8, 32, 128])
    func smallAndLargeWindowsSelectExactPredecessors(count: Int) throws {
        let starts = (0..<count).map { Double($0 * 4 + 8) }
        var timeline = BitmapSubtitleTimeline(
            maximumEntries: max(1, count),
            maximumBytes: max(1, count)
        )
        for index in starts.indices {
            try requireLookupInsert(
                lookupDisplay(UInt8(index + 1)),
                at: starts[index],
                into: &timeline
            )
        }

        // Exact equality and one representable value to either side exercise
        // before-first, first, interior, penultimate and latest positions.
        let queries: [Double] =
            [-Double.greatestFiniteMagnitude, Double.greatestFiniteMagnitude]
            + starts.flatMap { [$0.nextDown, $0, $0.nextUp] }
            + [.nan, .infinity, -.infinity]
        for query in queries {
            try assertLookup(timeline, starts: starts, at: query)
        }
    }

    @Test func adjacentAndExtremeFiniteTimestampsPreserveStoredStartBits() throws {
        let starts: [Double] = [
            -Double.greatestFiniteMagnitude,
            -1,
            -Double.leastNonzeroMagnitude,
            -0.0,
            Double.leastNonzeroMagnitude,
            Double(1).nextDown,
            1,
            Double(1).nextUp,
            Double.greatestFiniteMagnitude.nextDown,
            Double.greatestFiniteMagnitude,
        ]
        var timeline = BitmapSubtitleTimeline()
        for index in starts.indices.reversed() {
            try requireLookupInsert(
                lookupDisplay(UInt8(index + 1)),
                at: starts[index],
                into: &timeline
            )
        }

        for start in starts {
            for query in [start.nextDown, start, start.nextUp] {
                try assertLookup(timeline, starts: starts, at: query)
            }
        }
    }

    @Test func roundedAndOverflowingExpiryKeepExistingSelectionSemantics() throws {
        var rounded = BitmapSubtitleTimeline()
        try requireLookupInsert(lookupDisplay(1), at: 0, into: &rounded)
        try requireLookupInsert(
            lookupDisplay(2, duration: Double.leastNonzeroMagnitude),
            at: 1,
            into: &rounded
        )
        #expect(rounded.composition(at: Double(1).nextDown)?.value.regions.first?.pixels.first == 1)
        // 1 + leastNonzeroMagnitude rounds back to 1. An expired latest
        // display must not resurrect the preceding indefinite display.
        #expect(rounded.composition(at: 1) == nil)
        #expect(rounded.composition(at: Double(1).nextUp) == nil)

        try requireLookupInsert(lookupDisplay(3), at: 2, into: &rounded)
        // The same expired predecessor is now found through the search path.
        #expect(rounded.composition(at: 1) == nil)
        #expect(rounded.composition(at: Double(1).nextUp) == nil)

        var overflow = BitmapSubtitleTimeline()
        let start = Double.greatestFiniteMagnitude.nextDown
        try requireLookupInsert(
            lookupDisplay(4, duration: Double.greatestFiniteMagnitude),
            at: start,
            into: &overflow
        )
        // The finite start and duration are valid; their sum overflows.
        #expect(overflow.composition(at: Double.greatestFiniteMagnitude)?.value.regions.first?.pixels.first == 4)
        #expect(overflow.composition(at: .infinity) == nil)
    }

    @Test func clearRemainsASelectedDisplayOnLatestAndPredecessorPaths() throws {
        var timeline = BitmapSubtitleTimeline()
        try requireLookupInsert(lookupDisplay(1), at: 0, into: &timeline)
        let clear = NativeBitmapSubtitleComposition(
            regions: [],
            canvasSize: .init(width: 100, height: 100),
            duration: nil,
            memoryLease: nil
        )
        try requireLookupInsert(clear, at: 1, into: &timeline)

        let latest = try #require(timeline.composition(at: 1))
        #expect(latest.start == 1)
        #expect(latest.value.regions.isEmpty)
        #expect(timeline.composition(at: Double.greatestFiniteMagnitude)?.value.regions.isEmpty == true)

        try requireLookupInsert(lookupDisplay(2), at: 2, into: &timeline)
        let preceding = try #require(timeline.composition(at: Double(2).nextDown))
        #expect(preceding.start == 1)
        #expect(preceding.value.regions.isEmpty)
        #expect(timeline.composition(at: 2)?.value.regions.first?.pixels.first == 2)
    }
}

private func lookupDisplay(
    _ marker: UInt8,
    duration: Double? = nil
) -> NativeBitmapSubtitleComposition {
    NativeBitmapSubtitleComposition(
        regions: [
            .init(
                pixels: Data([marker]),
                frame: .init(x: 0, y: 0, width: 1, height: 1),
                isForced: false
            ),
        ],
        canvasSize: .init(width: 100, height: 100),
        duration: duration,
        memoryLease: nil
    )
}

private func requireLookupInsert(
    _ display: NativeBitmapSubtitleComposition,
    at start: Double,
    into timeline: inout BitmapSubtitleTimeline
) throws {
    let inserted = timeline.insert(display, at: start, generation: 0)
    try #require(inserted)
}

/// A forward walk gives an independent, simple expected predecessor.
private func assertLookup(
    _ timeline: BitmapSubtitleTimeline,
    starts: [Double],
    at query: Double
) throws {
    var expectedIndex: Int?
    if query.isFinite {
        for index in starts.indices where starts[index] <= query {
            expectedIndex = index
        }
    }
    guard let index = expectedIndex else {
        #expect(timeline.composition(at: query) == nil)
        return
    }
    let selected = try #require(timeline.composition(at: query))
    #expect(selected.start.bitPattern == starts[index].bitPattern)
    #expect(selected.value.regions.first?.pixels.first == UInt8(index + 1))
}
