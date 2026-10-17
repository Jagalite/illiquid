import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Testing
@testable import IlliquidNativePlayback

@Suite("Bitmap subtitle timeline ordering")
struct BitmapSubtitleTimelineOrderingTests {
    @Test(arguments: [127, 128])
    func productionSizedWindowsPreserveEveryPosition(capacity: Int) throws {
        for ordering in 0..<3 {
            var order = Array(0..<capacity)
            if ordering == 1 { order.reverse() }
            if ordering == 2 {
                var random = TimelineTestRandom(seed: 0x1234_5678)
                for index in stride(from: order.count - 1, through: 1, by: -1) {
                    order.swapAt(index, random.index(index + 1))
                }
            }
            var timeline = BitmapSubtitleTimeline(maximumEntries: capacity, maximumBytes: capacity * 64)
            var oracle = TimelineSortedArrayOracle(maximumEntries: capacity, maximumBytes: capacity * 64)
            let queries = [-1.0] + (0..<capacity).flatMap {
                [Double($0), Double($0) + 0.125, Double($0) + 0.25]
            } + [Double(capacity + 1)]
            for index in order {
                let display = timelineDisplay(UInt8(index), bytes: index.isMultiple(of: 2) ? 4 : 64,
                                              duration: index.isMultiple(of: 3) ? 0.25 : nil)
                let inserted = timeline.insert(display, at: Double(index), generation: 0)
                let expected = oracle.insert(display, at: Double(index), generation: 0)
                try #require(inserted)
                try #require(expected)
            }
            try assertTimeline(timeline, matches: oracle, at: queries)
            for index in order.reversed() {
                let display = timelineDisplay(UInt8(index ^ 0xa5), bytes: index.isMultiple(of: 5) ? 0 : 4)
                let inserted = timeline.insert(display, at: Double(index), generation: 0)
                let expected = oracle.insert(display, at: Double(index), generation: 0)
                try #require(inserted)
                try #require(expected)
            }
            try assertTimeline(timeline, matches: oracle, at: queries)
            let overflowInserted = timeline.insert(timelineDisplay(255), at: Double(capacity + 1), generation: 0)
            #expect(!overflowInserted)
            try assertTimeline(timeline, matches: oracle, at: queries)
        }
    }

    @Test func insertionPermutationsAndReplacementsMatchSortedArrayOracle() throws {
        let starts: [Double] = [-3, -0.0, 1, 2, 5]
        let queries: [Double] = [-4, -3, -2, -0.0, 0, 0.25, 1, 1.5, 2, 4, 5, 6, 100]
        for order in timelinePermutations(Array(starts.indices)) {
            var timeline = BitmapSubtitleTimeline(maximumEntries: 5, maximumBytes: 100)
            var oracle = TimelineSortedArrayOracle(maximumEntries: 5, maximumBytes: 100)
            for index in order {
                let display = timelineDisplay(UInt8(index + 1), bytes: 4 * (index % 3 + 1),
                                              duration: index.isMultiple(of: 2) ? nil : 0.5)
                let inserted = timeline.insert(display, at: starts[index], generation: 0)
                let expected = oracle.insert(display, at: starts[index], generation: 0)
                try #require(inserted == expected)
                try assertTimeline(timeline, matches: oracle, at: queries)
            }
            for index in order.reversed() {
                let display = timelineDisplay(UInt8(index + 20), bytes: index == 2 ? 0 : 4)
                let start = index == 1 ? 0.0 : starts[index]
                let inserted = timeline.insert(display, at: start, generation: 0)
                let expected = oracle.insert(display, at: start, generation: 0)
                try #require(inserted == expected)
                try assertTimeline(timeline, matches: oracle, at: queries)
            }
        }
    }

    @Test(arguments: [false, true])
    func signedZeroReplacementUsesTheIncomingTimestampSign(negativeFirst: Bool) throws {
        let first: Double = negativeFirst ? -0.0 : 0.0
        let replacement: Double = negativeFirst ? 0.0 : -0.0
        for surrounding in [[], [-1.0], [1.0], [-1.0, 1.0]] {
            var timeline = BitmapSubtitleTimeline(maximumEntries: surrounding.count + 1, maximumBytes: 64)
            for start in surrounding { timeline.insert(timelineDisplay(1), at: start, generation: 0) }
            let firstInserted = timeline.insert(timelineDisplay(2), at: first, generation: 0)
            let replacementInserted = timeline.insert(timelineDisplay(3), at: replacement, generation: 0)
            #expect(firstInserted)
            #expect(replacementInserted)
            let selected = try #require(timeline.composition(at: 0))
            #expect(selected.start.bitPattern == replacement.bitPattern)
            #expect(selected.value.regions.first?.pixels.first == 3)
            #expect(timeline.retainedBytes == (surrounding.count + 1) * 4)
            #expect(timeline.revision == UInt64(surrounding.count + 2))
        }
    }

    @Test func byteAndEntryLimitsRejectAtomicallyAndAllowFullCapacityReplacement() throws {
        var timeline = BitmapSubtitleTimeline(maximumEntries: 2, maximumBytes: 12)
        var oracle = TimelineSortedArrayOracle(maximumEntries: 2, maximumBytes: 12)
        let actions: [(Double, Int, Bool)] = [
            (-0.0, 4, true), (2, 8, true),
            (1, 0, false), // A clear still requires its own entry.
            (0.0, 8, false), // Failed replacement must keep the old -0 timestamp.
            (2, 12, false), (2, 4, true),
            (0.0, 0, true), // A clear can replace an entry at the count limit.
            (3, 4, false),
        ]
        for (index, action) in actions.enumerated() {
            let display = timelineDisplay(UInt8(index + 1), bytes: action.1)
            let beforeRevision = timeline.revision
            let expected = oracle.insert(display, at: action.0, generation: 0)
            #expect(expected == action.2)
            let inserted = timeline.insert(display, at: action.0, generation: 0)
            #expect(inserted == expected)
            #expect(timeline.revision == beforeRevision &+ (expected ? 1 : 0))
            try assertTimeline(timeline, matches: oracle, at: [-1, -0.0, 0, 1, 2, 3, 10])
        }
        let beforePrune = timeline.revision
        timeline.prune(before: 2)
        oracle.prune(before: 2)
        #expect(timeline.revision == beforePrune)
        let insertedAfterPrune = timeline.insert(timelineDisplay(99, bytes: 8), at: 3, generation: 0)
        let expectedAfterPrune = oracle.insert(timelineDisplay(99, bytes: 8), at: 3, generation: 0)
        #expect(insertedAfterPrune)
        #expect(expectedAfterPrune)
        try assertTimeline(timeline, matches: oracle, at: [-1, 0, 1, 2, 3, 4])
    }

    @Test func invalidDeliveriesAreAtomicAndStaleMalformedDeliveriesAreHarmless() throws {
        var timeline = BitmapSubtitleTimeline(maximumEntries: 4, maximumBytes: 32)
        var oracle = TimelineSortedArrayOracle(maximumEntries: 4, maximumBytes: 32)
        timeline.reset(generation: 7)
        oracle.reset(generation: 7)
        let existing = timelineDisplay(1)
        timeline.insert(existing, at: 1, generation: 7)
        oracle.insert(existing, at: 1, generation: 7)

        let invalidStarts: [Double] = [.nan, .infinity, -.infinity]
        for start in invalidStarts {
            let invalidInserted = timeline.insert(timelineDisplay(2), at: start, generation: 7)
            let staleInserted = timeline.insert(timelineDisplay(2), at: start, generation: 6)
            #expect(!invalidInserted)
            #expect(staleInserted)
            try assertTimeline(timeline, matches: oracle, at: [0, 1, 2, 100, .nan, .infinity])
        }
        let canvases: [CGSize] = [
            .init(width: 0, height: 10), .init(width: -1, height: 10),
            .init(width: 10, height: 0), .init(width: 10, height: -1),
            .init(width: Double.nan, height: 10), .init(width: 10, height: Double.nan),
            .init(width: Double.infinity, height: 10), .init(width: 10, height: Double.infinity),
        ]
        for canvas in canvases {
            let display = timelineDisplay(3, canvas: canvas)
            let invalidInserted = timeline.insert(display, at: 1, generation: 7)
            let staleInserted = timeline.insert(display, at: .nan, generation: 8)
            #expect(!invalidInserted)
            #expect(staleInserted)
            try assertTimeline(timeline, matches: oracle, at: [0, 1, 2, 100])
        }
        for duration in [0.0, -1, Double.nan, .infinity, -.infinity] {
            let display = timelineDisplay(4, duration: duration)
            let invalidInserted = timeline.insert(display, at: 1, generation: 7)
            let staleInserted = timeline.insert(display, at: .nan, generation: -1)
            #expect(!invalidInserted)
            #expect(staleInserted)
            try assertTimeline(timeline, matches: oracle, at: [0, 1, 2, 100])
        }
        let revision = timeline.revision
        let identicalInserted = timeline.insert(existing, at: 1, generation: 7)
        #expect(identicalInserted)
        #expect(timeline.revision == revision &+ 1) // Identical replacements are deliveries too.
    }

    @Test func durationAndClearEventsNeverResurrectEarlierDisplays() throws {
        var timeline = BitmapSubtitleTimeline()
        var oracle = TimelineSortedArrayOracle()
        let events: [(Double, NativeBitmapSubtitleComposition)] = [
            (10, timelineDisplay(1)), (20, timelineDisplay(2, duration: 2)),
            (30, timelineDisplay(3, bytes: 0)), (40, timelineDisplay(4, duration: 0.5)),
            (25, timelineDisplay(5, duration: 1)), // Out-of-order finite set.
        ]
        for (start, display) in events {
            let inserted = timeline.insert(display, at: start, generation: 0)
            let expected = oracle.insert(display, at: start, generation: 0)
            #expect(inserted)
            #expect(expected)
        }
        let queries: [Double] = [9, 10, 19.99, 20, 21.99, 22, 24, 25, 25.99, 26, 29, 30, 39, 40, 40.5, 100]
        try assertTimeline(timeline, matches: oracle, at: queries)
        #expect(timeline.composition(at: 22) == nil)
        #expect(timeline.composition(at: 26) == nil)
        #expect(timeline.composition(at: 35)?.value.regions.isEmpty == true)
        #expect(timeline.composition(at: 100) == nil)
        timeline.prune(before: 29)
        oracle.prune(before: 29)
        try assertTimeline(timeline, matches: oracle, at: queries)
        #expect(timeline.composition(at: 29) == nil)
    }

    @Test func resetPruneAndValueCopiesRemainIndependent() throws {
        var original = BitmapSubtitleTimeline(maximumEntries: 8, maximumBytes: 128)
        var originalOracle = TimelineSortedArrayOracle(maximumEntries: 8, maximumBytes: 128)
        for index in 0..<5 {
            let display = timelineDisplay(UInt8(index), bytes: (index + 1) * 4)
            original.insert(display, at: Double(index), generation: 0)
            originalOracle.insert(display, at: Double(index), generation: 0)
        }
        var copy = original
        var copyOracle = originalOracle
        copy.insert(timelineDisplay(99), at: 2, generation: 0)
        copyOracle.insert(timelineDisplay(99), at: 2, generation: 0)
        copy.prune(before: 3.5)
        copyOracle.prune(before: 3.5)
        let queries: [Double] = [-1, 0, 1, 2, 3, 4, 5, 100]
        try assertTimeline(original, matches: originalOracle, at: queries)
        try assertTimeline(copy, matches: copyOracle, at: queries)
        original.reset(generation: 9)
        originalOracle.reset(generation: 9)
        try assertTimeline(original, matches: originalOracle, at: queries)
        try assertTimeline(copy, matches: copyOracle, at: queries)
        copy.reset()
        copyOracle.reset()
        #expect(copy.generation == 0)
        try assertTimeline(copy, matches: copyOracle, at: queries)
        original.insert(timelineDisplay(7), at: -2, generation: 9)
        originalOracle.insert(timelineDisplay(7), at: -2, generation: 9)
        for cutoff in [Double.nan, -.infinity, .infinity] {
            original.prune(before: cutoff)
            originalOracle.prune(before: cutoff)
            try assertTimeline(original, matches: originalOracle, at: [-3, -2, 0, 100])
        }
    }

    @Test(arguments: [UInt64(1), 42, 0x1234_5678_9abc_def0, 0xdead_beef])
    func mixedOperationsMatchIndependentSortedArrayOracle(seed: UInt64) throws {
        let configurations = [(1, 1), (3, 24), (16, 160), (128, 4_096)]
        var accepted = 0
        var rejected = 0
        for (capacity, bytes) in configurations {
            var timeline = BitmapSubtitleTimeline(maximumEntries: capacity, maximumBytes: bytes)
            var oracle = TimelineSortedArrayOracle(maximumEntries: capacity, maximumBytes: bytes)
            var random = TimelineTestRandom(seed: seed)
            for step in 0..<1_000 {
                let operation = random.index(100)
                let startChoices: [Double] = [-4, -0.0, 0.0, 0.25, 1, 2.5, 8, 17, 40, .nan, .infinity, -.infinity]
                let start = startChoices[random.index(startChoices.count)]
                if operation < 78 {
                    let sizes = [0, 0, 4, 8, 16, 32, 164]
                    let durations: [Double?] = [nil, nil, 0.125, 1, 4, 0, -1, .nan, .infinity]
                    let canvas = random.index(20) == 0
                        ? CGSize(width: 0, height: 100) : CGSize(width: 1920, height: 1080)
                    let display = timelineDisplay(UInt8(step & 255), bytes: sizes[random.index(sizes.count)],
                                                  duration: durations[random.index(durations.count)], canvas: canvas)
                    let generation = random.index(8) == 0 ? oracle.generation - 1 : oracle.generation
                    let expected = oracle.insert(display, at: start, generation: generation)
                    let inserted = timeline.insert(display, at: start, generation: generation)
                    try #require(inserted == expected,
                                 "seed \(seed), capacity \(capacity), step \(step)")
                    if generation == oracle.generation {
                        if expected { accepted += 1 } else { rejected += 1 }
                    }
                } else if operation < 93 {
                    timeline.prune(before: start)
                    oracle.prune(before: start)
                } else {
                    let generation = random.index(2) == 0 ? nil : Optional(oracle.generation + 1)
                    timeline.reset(generation: generation)
                    oracle.reset(generation: generation)
                }
                try assertTimeline(timeline, matches: oracle, at: startChoices,
                                   context: "seed \(seed), capacity \(capacity), step \(step)")
            }
        }
        #expect(accepted > 0)
        #expect(rejected > 0)
    }

    @Test func queriedRenderedAndCopiedOwnersKeepRetiredLeaseAlive() throws {
        let budget = SubtitleMemoryBudget(limitBytes: 64, ownerLimitsBytes: [:])
        var timeline = BitmapSubtitleTimeline(maximumEntries: 4, maximumBytes: 64)
        let initialInserted = timeline.insert(try leasedTimelineDisplay(1, bytes: 4, budget: budget), at: 0, generation: 0)
        #expect(initialInserted)
        var queried = [try #require(timeline.composition(at: 0)).value]
        var rendered = queried[0].renderedRegions(in: CGRect(x: 0, y: 0, width: 100, height: 100))
        var copy = timeline
        let replacementInserted = timeline.insert(try leasedTimelineDisplay(2, bytes: 8, budget: budget), at: 0, generation: 0)
        #expect(replacementInserted)
        #expect(timeline.retainedBytes == 8)
        withExtendedLifetime((queried, rendered, copy)) {
            #expect(budget.snapshot.reservedBytes == 12)
        }
        copy.reset()
        queried.removeAll()
        withExtendedLifetime(rendered) { #expect(budget.snapshot.reservedBytes == 12) }
        timeline.reset()
        withExtendedLifetime(rendered) { #expect(budget.snapshot.reservedBytes == 4) }
        rendered.removeAll()
        #expect(budget.snapshot.reservedBytes == 0)
    }

    @Test func pruneReleasesOnlyUnaliasedRemovedEntries() throws {
        let budget = SubtitleMemoryBudget(limitBytes: 64, ownerLimitsBytes: [:])
        var timeline = BitmapSubtitleTimeline(maximumEntries: 4, maximumBytes: 64)
        for index in 0..<3 {
            let inserted = timeline.insert(try leasedTimelineDisplay(UInt8(index), bytes: 4 * (index + 1), budget: budget),
                                           at: Double(index), generation: 0)
            #expect(inserted)
        }
        var copy = timeline
        timeline.prune(before: 2)
        #expect(timeline.retainedBytes == 12)
        withExtendedLifetime(copy) { #expect(budget.snapshot.reservedBytes == 24) }
        copy.reset()
        #expect(budget.snapshot.reservedBytes == 12)
        timeline.reset()
        #expect(budget.snapshot.reservedBytes == 0)
    }

    @Test func rejectedAndStaleIncomingLeasesAreNotRetained() throws {
        let budget = SubtitleMemoryBudget(limitBytes: 64, ownerLimitsBytes: [:])
        var timeline = BitmapSubtitleTimeline(maximumEntries: 1, maximumBytes: 4)
        let initialInserted = timeline.insert(try leasedTimelineDisplay(1, bytes: 4, budget: budget), at: 0, generation: 0)
        #expect(initialInserted)
        func deliver(bytes: Int, start: Double, generation: Int) throws -> Bool {
            let incoming = try leasedTimelineDisplay(2, bytes: bytes, budget: budget)
            return timeline.insert(incoming, at: start, generation: generation)
        }
        let oversizedInserted = try deliver(bytes: 8, start: 0, generation: 0)
        #expect(!oversizedInserted)
        #expect(budget.snapshot.reservedBytes == 4)
        let overflowInserted = try deliver(bytes: 4, start: 1, generation: 0)
        #expect(!overflowInserted)
        #expect(budget.snapshot.reservedBytes == 4)
        let invalidInserted = try deliver(bytes: 4, start: .nan, generation: 0)
        #expect(!invalidInserted)
        #expect(budget.snapshot.reservedBytes == 4)
        let staleInserted = try deliver(bytes: 4, start: .nan, generation: -1)
        #expect(staleInserted)
        #expect(budget.snapshot.reservedBytes == 4)
        #expect(timeline.revision == 1)
        #expect(timeline.composition(at: 0)?.value.regions.first?.pixels.first == 1)
        timeline.reset()
        #expect(budget.snapshot.reservedBytes == 0)
    }
}

private func timelineDisplay(_ marker: UInt8, bytes: Int = 4, duration: Double? = nil,
                             canvas: CGSize = .init(width: 100, height: 100),
                             lease: SubtitleMemoryBudget.Lease? = nil) -> NativeBitmapSubtitleComposition {
    let sizes = bytes == 0 ? [] : (bytes >= 8 ? [bytes / 2, bytes - bytes / 2] : [bytes])
    let regions = sizes.enumerated().map { index, size in
        NativeBitmapSubtitleRegion(
            pixels: Data(repeating: marker &+ UInt8(index), count: size),
            frame: CGRect(x: CGFloat(index + 1), y: CGFloat(index + 2),
                          width: CGFloat(max(1, size / 4)), height: 1),
            isForced: index.isMultiple(of: 2)
        )
    }
    return NativeBitmapSubtitleComposition(regions: regions, canvasSize: canvas,
                                            duration: duration, memoryLease: lease)
}

private func leasedTimelineDisplay(_ marker: UInt8, bytes: Int,
                                   budget: SubtitleMemoryBudget) throws -> NativeBitmapSubtitleComposition {
    let lease = try #require(budget.acquire(owner: .bitmapEvents, bytes: bytes))
    return timelineDisplay(marker, bytes: bytes, lease: lease)
}

private struct TimelineDisplaySnapshot: Equatable {
    struct Region: Equatable {
        let pixels: Data
        let frame: CGRect
        let isForced: Bool
    }
    let startBits: UInt64
    let canvas: CGSize
    let durationBits: UInt64?
    let regions: [Region]

    init(_ result: (start: Double, value: NativeBitmapSubtitleComposition)) {
        startBits = result.start.bitPattern
        canvas = result.value.canvasSize
        durationBits = result.value.duration?.bitPattern
        regions = result.value.regions.map { Region(pixels: $0.pixels, frame: $0.frame, isForced: $0.isForced) }
    }
}

private func assertTimeline(_ timeline: BitmapSubtitleTimeline, matches oracle: TimelineSortedArrayOracle,
                            at queries: [Double], context: String = "timeline parity") throws {
    try #require(timeline.generation == oracle.generation, "\(context): generation")
    try #require(timeline.revision == oracle.revision, "\(context): revision")
    try #require(timeline.retainedBytes == oracle.retainedBytes, "\(context): retained bytes")
    for query in queries {
        let actual = timeline.composition(at: query).map(TimelineDisplaySnapshot.init)
        let expected = oracle.composition(at: query).map(TimelineDisplaySnapshot.init)
        try #require(actual == expected, "\(context): query \(query)")
    }
}

/// Linear filtering and full sorting deliberately avoid the candidate's search
/// and mutation strategy. Byte totals are recomputed from the whole proposed set.
private struct TimelineSortedArrayOracle {
    struct Entry {
        let start: Double
        let value: NativeBitmapSubtitleComposition
    }
    let maximumEntries: Int
    let maximumBytes: Int
    private var entries: [Entry] = []
    private(set) var generation = 0
    private(set) var revision: UInt64 = 0
    var retainedBytes: Int { entries.reduce(0) { total, entry in
        total + entry.value.regions.reduce(0) { $0 + $1.pixels.count }
    } }

    init(maximumEntries: Int = 128, maximumBytes: Int = 32 * 1_024 * 1_024) {
        self.maximumEntries = max(1, maximumEntries)
        self.maximumBytes = max(1, maximumBytes)
    }

    @discardableResult
    mutating func insert(_ value: NativeBitmapSubtitleComposition, at start: Double, generation: Int) -> Bool {
        if generation != self.generation { return true }
        if !start.isFinite || !value.canvasSize.width.isFinite || !value.canvasSize.height.isFinite
            || value.canvasSize.width <= 0 || value.canvasSize.height <= 0 { return false }
        if let duration = value.duration, !duration.isFinite || duration <= 0 { return false }
        let proposed = entries.filter { $0.start != start } + [Entry(start: start, value: value)]
        let proposedBytes = proposed.reduce(0) { total, entry in
            total + entry.value.regions.reduce(0) { $0 + $1.pixels.count }
        }
        guard proposed.count <= maximumEntries, proposedBytes <= maximumBytes else { return false }
        entries = proposed.sorted { $0.start < $1.start }
        revision &+= 1
        return true
    }

    func composition(at seconds: Double) -> (start: Double, value: NativeBitmapSubtitleComposition)? {
        guard seconds.isFinite else { return nil }
        var selected: Entry?
        for entry in entries where entry.start <= seconds { selected = entry }
        guard let selected else { return nil }
        if let duration = selected.value.duration, seconds >= selected.start + duration { return nil }
        return (selected.start, selected.value)
    }

    mutating func reset(generation: Int? = nil) {
        entries = []
        if let generation { self.generation = generation }
        revision &+= 1
    }

    mutating func prune(before seconds: Double) {
        guard let preceding = entries.filter({ $0.start <= seconds }).last else { return }
        entries = entries.filter { $0.start >= preceding.start }
    }
}

private struct TimelineTestRandom {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func index(_ count: Int) -> Int {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Int((state >> 32) % UInt64(count))
    }
}

private func timelinePermutations(_ values: [Int]) -> [[Int]] {
    guard values.count > 1 else { return [values] }
    return values.flatMap { first in
        timelinePermutations(values.filter { $0 != first }).map { [first] + $0 }
    }
}
