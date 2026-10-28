import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Testing
@testable import IlliquidNativePlayback

@Suite("Bitmap subtitle timeline lookup")
struct BitmapSubtitleTimelineLookupTests {
    @Test(arguments: [0, 1, 2, 3, 7, 8, 9, 31, 32, 33, 127, 128, 129])
    func timestampBoundariesMatchLinearSelection(count: Int) throws {
        var timeline = BitmapSubtitleTimeline(maximumEntries: max(1, count),
                                              maximumBytes: max(1, count * 4))
        var entries: [LookupEntry] = []
        timeline.reset(generation: 23)
        for index in 0..<count {
            let start = Double(index * 2 - count)
            let composition = lookupDisplay(UInt8(index), duration: index.isMultiple(of: 3) ? 0.5 : nil)
            let inserted = timeline.insert(composition, at: start, generation: 23)
            try #require(inserted)
            entries.append(LookupEntry(start: start, composition: composition))
        }

        var queries: [Double] = [
            .nan, -.infinity, .infinity,
            -Double.greatestFiniteMagnitude, Double.greatestFiniteMagnitude,
            -0.0, 0.0,
        ]
        for entry in entries {
            queries += [entry.start.nextDown, entry.start, entry.start.nextUp]
            if let duration = entry.composition.duration {
                let end = entry.start + duration
                queries += [end.nextDown, end, end.nextUp]
            }
        }
        for query in queries {
            let actual = timeline.composition(at: query).map(LookupResult.init)
            let expected = linearLookup(entries, at: query).map(LookupResult.init)
            #expect(actual == expected, "count \(count), query bits \(query.bitPattern)")
        }
    }

    @Test func finiteEndOverflowAndRoundingPreserveExpirationRules() throws {
        var overflowing = BitmapSubtitleTimeline(maximumEntries: 2, maximumBytes: 8)
        let largeStart = Double.greatestFiniteMagnitude / 2
        let largeDuration = Double.greatestFiniteMagnitude
        #expect((largeStart + largeDuration).isInfinite)
        let firstInserted = overflowing.insert(lookupDisplay(1), at: 0, generation: 0)
        let overflowingInserted = overflowing.insert(
            lookupDisplay(2, duration: largeDuration), at: largeStart, generation: 0)
        try #require(firstInserted)
        try #require(overflowingInserted)
        #expect(overflowing.composition(at: largeStart.nextDown)?.start == 0)
        for query in [largeStart, largeStart.nextUp, Double.greatestFiniteMagnitude] {
            let selected = try #require(overflowing.composition(at: query))
            #expect(selected.start.bitPattern == largeStart.bitPattern)
            #expect(selected.value.regions.first?.pixels.first == 2)
        }
        #expect(overflowing.composition(at: .infinity) == nil)

        var rounded = BitmapSubtitleTimeline(maximumEntries: 3, maximumBytes: 12)
        let roundedStart = Double(sign: .plus, exponent: 100, significand: 1)
        let roundedDuration = 1.0
        #expect(roundedStart + roundedDuration == roundedStart)
        let earlierInserted = rounded.insert(lookupDisplay(3), at: 0, generation: 0)
        let roundedInserted = rounded.insert(
            lookupDisplay(4, duration: roundedDuration), at: roundedStart, generation: 0)
        let laterInserted = rounded.insert(lookupDisplay(5), at: roundedStart * 2, generation: 0)
        try #require(earlierInserted)
        try #require(roundedInserted)
        try #require(laterInserted)
        #expect(rounded.composition(at: roundedStart.nextDown)?.start == 0)
        // The selected finite event is already expired when its end rounds to
        // its start. Lookup must not fall back to the older indefinite event.
        #expect(rounded.composition(at: roundedStart) == nil)
        #expect(rounded.composition(at: roundedStart.nextUp) == nil)
        #expect(rounded.composition(at: roundedStart * 2)?.value.regions.first?.pixels.first == 5)
    }

    @Test func queriesPreserveBookkeepingAndRetainOnlyTheSelectedLease() throws {
        let budget = SubtitleMemoryBudget(limitBytes: 64, ownerLimitsBytes: [:])
        var timeline = BitmapSubtitleTimeline(maximumEntries: 8, maximumBytes: 64)
        timeline.reset(generation: 9)
        for index in 0..<8 {
            let inserted = timeline.insert(
                try leasedLookupDisplay(UInt8(index), budget: budget),
                at: Double(index * 2), generation: 9)
            try #require(inserted)
        }
        let generation = timeline.generation
        let revision = timeline.revision
        let retainedBytes = timeline.retainedBytes
        let originalBudget = budget.snapshot
        #expect(originalBudget.reservedBytes == 32)

        let queries: [Double] = [-1, 0, 0.25, 5, 13.75, 14, 100, .nan, -.infinity, .infinity]
        for _ in 0..<5 {
            for query in queries {
                _ = timeline.composition(at: query)
            }
        }
        var selected = [try #require(timeline.composition(at: 5)).value]
        #expect(selected[0].regions.first?.pixels.first == 2)
        #expect(timeline.generation == generation)
        #expect(timeline.revision == revision)
        #expect(timeline.retainedBytes == retainedBytes)
        #expect(budget.snapshot == originalBudget)

        timeline.reset(generation: 10)
        withExtendedLifetime(selected) {
            #expect(budget.snapshot.reservedBytes == 4)
        }
        selected.removeAll()
        #expect(budget.snapshot.reservedBytes == 0)
    }
}

private struct LookupEntry {
    let start: Double
    let composition: NativeBitmapSubtitleComposition
}

// An independent linear reference preserves selection before expiration:
// an expired latest entry must never expose an older active entry.
private func linearLookup(
    _ entries: [LookupEntry], at seconds: Double
) -> (start: Double, value: NativeBitmapSubtitleComposition)? {
    guard seconds.isFinite else { return nil }
    var selected: LookupEntry?
    for entry in entries where entry.start <= seconds { selected = entry }
    guard let selected else { return nil }
    if let duration = selected.composition.duration,
       seconds >= selected.start + duration { return nil }
    return (selected.start, selected.composition)
}

private struct LookupResult: Equatable {
    let startBits: UInt64
    let durationBits: UInt64?
    let canvas: CGSize
    let pixels: [Data]
    let frames: [CGRect]
    let forced: [Bool]
    let hasLease: Bool

    init(_ selection: (start: Double, value: NativeBitmapSubtitleComposition)) {
        startBits = selection.start.bitPattern
        durationBits = selection.value.duration?.bitPattern
        canvas = selection.value.canvasSize
        pixels = selection.value.regions.map(\.pixels)
        frames = selection.value.regions.map(\.frame)
        forced = selection.value.regions.map(\.isForced)
        hasLease = selection.value.memoryLease != nil
    }
}

private func lookupDisplay(
    _ marker: UInt8, duration: Double? = nil,
    lease: SubtitleMemoryBudget.Lease? = nil
) -> NativeBitmapSubtitleComposition {
    let region = NativeBitmapSubtitleRegion(
        pixels: Data([marker, 0, 0, 255]),
        frame: CGRect(x: 0, y: 0, width: 1, height: 1),
        isForced: marker.isMultiple(of: 2))
    return NativeBitmapSubtitleComposition(
        regions: [region], canvasSize: CGSize(width: 1920, height: 1080),
        duration: duration, memoryLease: lease)
}

private func leasedLookupDisplay(
    _ marker: UInt8, budget: SubtitleMemoryBudget
) throws -> NativeBitmapSubtitleComposition {
    let lease = try #require(budget.acquire(owner: .bitmapEvents, bytes: 4))
    return lookupDisplay(marker, lease: lease)
}
