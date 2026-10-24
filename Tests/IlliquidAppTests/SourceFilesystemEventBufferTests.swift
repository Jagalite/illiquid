import Foundation
import Testing

@testable import IlliquidApp

@Suite("Bounded source filesystem event retention")
struct SourceFilesystemEventBufferTests {
    private let roots = [
        URL(fileURLWithPath: "/media/movies", isDirectory: true),
        URL(fileURLWithPath: "/media/shows", isDirectory: true),
        URL(fileURLWithPath: "/media/shows/Season 1", isDirectory: true),
        URL(fileURLWithPath: "/Volumes/External/Library", isDirectory: true),
    ]

    @Test func emptyInputAndRepeatedDrainsProduceNoWork() {
        var buffer = SourceFilesystemEventBuffer()
        buffer.append(contentsOf: [])
        #expect(buffer.count == 0)
        #expect(buffer.take().isEmpty)
        #expect(buffer.take().isEmpty)
        buffer.removeAll()
        #expect(buffer.count == 0)
        #expect(SourceFilesystemInvalidationPlanner.plan(events: buffer.take(), roots: roots).isEmpty)
    }

    @Test func defaultCapacityPreservesExactly4096EventsInArrivalOrder() {
        let events = (0..<4096).map(event)
        var buffer = SourceFilesystemEventBuffer()
        buffer.append(contentsOf: Array(events[..<2000]))
        buffer.append(contentsOf: [])
        buffer.append(contentsOf: Array(events[2000...]))
        #expect(buffer.count == events.count)
        #expect(buffer.take() == events)
        #expect(buffer.count == 0)
    }

    @Test func firstEventBeyondDefaultCapacityRequestsRecovery() {
        var buffer = SourceFilesystemEventBuffer()
        buffer.append(contentsOf: (0..<4096).map(event))
        buffer.append(contentsOf: [event(4096)])
        #expect(buffer.count == 1)
        expectRecovery(buffer.take())
    }

    @Test(arguments: [1, 2, 7, 31], [false, true])
    func overflowAcrossCallbacksAndWithinOneCallbackRequestsRecovery(
        _ capacity: Int, _ singleCallback: Bool
    ) {
        let events = (0...capacity).map(event)
        var buffer = SourceFilesystemEventBuffer(maximumCount: capacity)
        if singleCallback {
            buffer.append(contentsOf: events)
        } else {
            buffer.append(contentsOf: Array(events.dropLast()))
            #expect(buffer.count == capacity)
            buffer.append(contentsOf: [events.last!])
        }
        #expect(buffer.count == 1)
        expectRecovery(buffer.take())
    }

    @Test(arguments: [0, 1, 3], [
        SourceFilesystemEvent.Flags.eventsDropped,
        [.eventsDropped, .mustScanSubdirectories, .directory],
    ])
    func reportedLossSupersedesDetailedEventsInAnyPosition(
        _ markerIndex: Int, _ flags: SourceFilesystemEvent.Flags
    ) {
        let marker = SourceFilesystemEvent(path: "/outside/all/watched/roots", flags: flags)
        var incoming = (10..<13).map(event)
        incoming.insert(marker, at: markerIndex)
        var buffer = SourceFilesystemEventBuffer(maximumCount: 10)
        buffer.append(contentsOf: [event(0), event(1)])
        buffer.append(contentsOf: incoming)
        #expect(buffer.count == 1)
        expectRecovery(buffer.take())
    }

    @Test func sustainedOverflowStaysCollapsedUntilTaken() {
        var buffer = SourceFilesystemEventBuffer(maximumCount: 4)
        buffer.append(contentsOf: (0..<5).map(event))
        for batch in 1...100 {
            buffer.append(contentsOf: (0..<100).map { event(batch * 100 + $0) })
            buffer.append(contentsOf: [])
            #expect(buffer.count == 1)
        }
        expectRecovery(buffer.take())
        #expect(buffer.count == 0)
        let nextBatch = (20..<24).map(event)
        buffer.append(contentsOf: nextBatch)
        #expect(buffer.take() == nextBatch)
    }

    @Test(arguments: [false, true])
    func clearingForWatcherRestartOrDisappearanceRestoresOrdinaryAdmission(_ overflowed: Bool) {
        var buffer = SourceFilesystemEventBuffer(maximumCount: 2)
        buffer.append(contentsOf: (0..<(overflowed ? 3 : 2)).map(event))
        buffer.removeAll()
        #expect(buffer.count == 0)
        #expect(buffer.take().isEmpty)
        let replacementEvents = [event(20), event(21)]
        buffer.append(contentsOf: replacementEvents)
        #expect(buffer.take() == replacementEvents)
    }

    @Test func takenBatchAndCopiedBufferRemainIndependentOfLaterMutation() {
        let firstBatch = [event(0), event(1)]
        var buffer = SourceFilesystemEventBuffer(maximumCount: 3)
        buffer.append(contentsOf: firstBatch)
        var copy = buffer
        let taken = buffer.take()
        buffer.append(contentsOf: [event(2)])
        copy.append(contentsOf: [event(3)])
        #expect(taken == firstBatch)
        #expect(buffer.take() == [event(2)])
        #expect(copy.take() == firstBatch + [event(3)])

        buffer.append(contentsOf: (0..<4).map(event))
        let recovery = buffer.take()
        buffer.append(contentsOf: firstBatch)
        expectRecovery(recovery)
        #expect(buffer.take() == firstBatch)
        #expect(taken == firstBatch)
    }

    @Test(arguments: [Int.min, -1, 0, 1])
    func nonpositiveLimitsAreSafelyClampedToOne(_ requestedCapacity: Int) {
        var buffer = SourceFilesystemEventBuffer(maximumCount: requestedCapacity)
        buffer.append(contentsOf: [event(0)])
        #expect(buffer.count == 1)
        #expect(buffer.take() == [event(0)])
        buffer.append(contentsOf: [event(1), event(2)])
        expectRecovery(buffer.take())
    }

    @Test func maximumIntegerLimitDoesNotOverflowOrAllocateUpFront() {
        var buffer = SourceFilesystemEventBuffer(maximumCount: .max)
        buffer.append(contentsOf: [event(0)])
        buffer.append(contentsOf: [event(1)])
        #expect(buffer.take() == [event(0), event(1)])
    }

    @Test func overflowUsesCurrentNormalizedRootsAndNoRootsMeansNoWork() {
        var buffer = SourceFilesystemEventBuffer(maximumCount: 1)
        buffer.append(contentsOf: [
            .init(path: "/retired/root/Movie.mkv", flags: [.created]),
            .init(path: "/retired/root/Show.mkv", flags: [.removed]),
        ])
        let batch = buffer.take()
        let replacementRoots = [
            URL(fileURLWithPath: "/new/root/"),
            URL(fileURLWithPath: "/new/root/../root"),
            URL(fileURLWithPath: "/other/root"),
        ]
        let plan = SourceFilesystemInvalidationPlanner.plan(events: batch, roots: replacementRoots)
        #expect(plan == SourceFilesystemInvalidationPlan(rootsToRescan: ["/new/root", "/other/root"]))
        #expect(SourceFilesystemInvalidationPlanner.plan(events: batch, roots: []).isEmpty)
    }

    @Test(arguments: [UInt64(1), 42, 0x1234_5678_9abc_def0, 0xdead_beef])
    func generatedBatchesBelowCapacityPreserveEventsAndPlannerResults(_ seed: UInt64) {
        var random = EventBufferRandom(seed: seed)
        for capacity in [1, 2, 7, 31, 128] {
            var buffer = SourceFilesystemEventBuffer(maximumCount: capacity)
            for cycle in 0..<40 {
                let total = random.index(capacity + 1)
                let expected = (0..<total).map { _ in generatedEvent(&random) }
                var offset = 0
                while offset < total {
                    buffer.append(contentsOf: [])
                    let end = min(total, offset + 1 + random.index(11))
                    buffer.append(contentsOf: Array(expected[offset..<end]))
                    #expect(buffer.count == end)
                    offset = end
                }
                let actual = buffer.take()
                #expect(actual == expected, "seed \(seed), capacity \(capacity), cycle \(cycle)")
                #expect(buffer.count == 0)
                #expect(
                    SourceFilesystemInvalidationPlanner.plan(events: actual, roots: roots)
                        == SourceFilesystemInvalidationPlanner.plan(events: expected, roots: roots)
                )
            }
        }
    }

    @Test(arguments: [UInt64(7), 0xfeed_face])
    func generatedOverflowNeverLosesRecoveryAndStaysWithinItsBound(_ seed: UInt64) {
        var random = EventBufferRandom(seed: seed)
        for capacity in [1, 3, 19, 128] {
            for _ in 0..<20 {
                var buffer = SourceFilesystemEventBuffer(maximumCount: capacity)
                let total = capacity + 1 + random.index(100)
                let events = (0..<total).map { _ in generatedEvent(&random) }
                var offset = 0
                while offset < total {
                    let end = min(total, offset + 1 + random.index(17))
                    buffer.append(contentsOf: Array(events[offset..<end]))
                    #expect(buffer.count <= capacity)
                    if end > capacity { #expect(buffer.count == 1) }
                    offset = end
                }
                expectRecovery(buffer.take())
                #expect(buffer.count == 0)
            }
        }
    }

    private func event(_ index: Int) -> SourceFilesystemEvent {
        .init(path: "/media/movies/Film \(index).mkv", flags: [.created])
    }

    private func generatedEvent(_ random: inout EventBufferRandom) -> SourceFilesystemEvent {
        let paths = [
            "/media/movies/Film.mkv", "/media/movies/Film.NFO", "/media/movies/.plexmatch",
            "/media/shows/Season 1", "/media/shows/Season 1/Episode.mkv", "/media/shows",
            "/Volumes/External/Library/映画 Café.mkv", "/media/movies2/Other.mkv",
            "/outside/watched/roots", "/", "/media/movies/../shows/Season 2", "/media",
        ]
        // Include path-local recovery and unknown bits, but never event loss:
        // under the limit every event and its planner meaning must survive.
        let flags: [SourceFilesystemEvent.Flags] = [
            [], .created, .removed, .renamed, .directory,
            [.directory, .created], [.directory, .removed], [.directory, .renamed],
            .rootChanged, .eventIDsWrapped, .mustScanSubdirectories,
            .init(rawValue: 1 << 12),
        ]
        return .init(path: paths[random.index(paths.count)], flags: flags[random.index(flags.count)])
    }

    private func expectRecovery(_ events: [SourceFilesystemEvent]) {
        #expect(events.count == 1)
        #expect(events.first?.flags.contains(.eventsDropped) == true)
        let plan = SourceFilesystemInvalidationPlanner.plan(events: events, roots: roots)
        #expect(plan == SourceFilesystemInvalidationPlan(rootsToRescan: Set(roots.map(\.path))))
    }
}

private struct EventBufferRandom {
    var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func index(_ upperBound: Int) -> Int {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Int((state >> 32) % UInt64(upperBound))
    }
}
