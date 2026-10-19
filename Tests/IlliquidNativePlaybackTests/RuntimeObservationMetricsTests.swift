import Foundation
import Testing
@testable import IlliquidNativePlayback

@Suite("Runtime observation metrics")
struct RuntimeObservationMetricsTests {
    @Test func sourceLookupsAndMutationsKeepDictionarySemantics() {
        enum InterruptedMutation: Error { case expected }
        func mutateThenThrow(_ value: inout Int) throws {
            value += 5
            throw InterruptedMutation.expected
        }

        for source in RuntimeObservationSource.allCases {
            var actual = RuntimeObservationMetricsSnapshot()
            var expected: [RuntimeObservationSource: Int] = [:]
            var actualDefaultEvaluations = 0
            var expectedDefaultEvaluations = 0
            func actualDefault() -> Int {
                actualDefaultEvaluations += 1
                return 17
            }
            func expectedDefault() -> Int {
                expectedDefaultEvaluations += 1
                return 17
            }

            #expect(actual.requestsBySource[source] == nil)
            let absentActual = actual.requestsBySource[source, default: actualDefault()]
            let absentExpected = expected[source, default: expectedDefault()]
            #expect(absentActual == absentExpected)
            #expect(actualDefaultEvaluations == expectedDefaultEvaluations)
            #expect(actual.requestsBySource[source] == nil)
            #expect(actual == RuntimeObservationMetricsSnapshot())

            // Reading a default does not insert it; modifying it does, even when
            // the modification leaves the numeric value at zero.
            actual.requestsBySource[source, default: 0] += 0
            expected[source, default: 0] += 0
            #expect(actual.requestsBySource[source] == expected[source])
            #expect(actual.totalRequests == 0)
            #expect(actual != RuntimeObservationMetricsSnapshot())
            let explicitZero = actual

            let presentActual = actual.requestsBySource[source, default: actualDefault()]
            let presentExpected = expected[source, default: expectedDefault()]
            #expect(presentActual == presentExpected)
            #expect(actualDefaultEvaluations == expectedDefaultEvaluations)

            actual.requestsBySource[source, default: actualDefault()] += 9
            expected[source, default: expectedDefault()] += 9
            #expect(actual.requestsBySource[source] == expected[source])
            #expect(actualDefaultEvaluations == expectedDefaultEvaluations)
            #expect(explicitZero.requestsBySource[source] == 0)

            actual.requestsBySource[source] = nil
            expected[source] = nil
            #expect(actual.requestsBySource[source] == expected[source])
            #expect(actual == RuntimeObservationMetricsSnapshot())

            actual.requestsBySource[source, default: actualDefault()] += 2
            expected[source, default: expectedDefault()] += 2
            #expect(actual.requestsBySource[source] == expected[source])
            #expect(actual.totalRequests == 19)
            #expect(actualDefaultEvaluations == expectedDefaultEvaluations)

            actual.requestsBySource[source] = nil
            expected[source] = nil
            actual.requestsBySource[source, default: actualDefault()] = -4
            expected[source, default: expectedDefault()] = -4
            #expect(actual.requestsBySource[source] == expected[source])
            #expect(actual.totalRequests == expected.values.reduce(0, +))
            #expect(actualDefaultEvaluations == expectedDefaultEvaluations)
            #expect(explicitZero.requestsBySource[source] == 0)

            // A thrown mutation still writes back its partial change. Missing
            // keys evaluate the default once; present keys leave it unevaluated.
            for initial in [nil, 3] as [Int?] {
                actual.requestsBySource[source] = initial
                expected[source] = initial
                #expect(throws: InterruptedMutation.self) {
                    try mutateThenThrow(&actual.requestsBySource[source, default: actualDefault()])
                }
                #expect(throws: InterruptedMutation.self) {
                    try mutateThenThrow(&expected[source, default: expectedDefault()])
                }
                #expect(actual.requestsBySource[source] == expected[source])
                #expect(actual.requestsBySource[source] == (initial ?? 17) + 5)
                #expect(actualDefaultEvaluations == expectedDefaultEvaluations)
                #expect(explicitZero.requestsBySource[source] == 0)
            }
        }
    }

    @Test func snapshotEqualityIncludesEveryCounterAndIgnoresInsertionOrder() {
        let sources = RuntimeObservationSource.allCases
        var forward = RuntimeObservationMetricsSnapshot()
        var reverse = RuntimeObservationMetricsSnapshot()
        for (index, source) in sources.enumerated() {
            forward.requestsBySource[source] = index * 3
        }
        for (index, source) in sources.enumerated().reversed() {
            reverse.requestsBySource[source] = index * 3
        }
        #expect(forward == reverse)
        #expect(forward.totalRequests == sources.indices.reduce(0) { $0 + $1 * 3 })

        for source in sources {
            var changed = forward
            changed.requestsBySource[source, default: 0] += 1
            #expect(changed != forward)
            changed.requestsBySource[source] = nil
            #expect(changed != forward)
        }

        let counterChanges: [(inout RuntimeObservationMetricsSnapshot) -> Void] = [
            { $0.scheduledDeliveries += 1 },
            { $0.coalescedRequests += 1 },
            { $0.deliveredObservations += 1 },
            { $0.followUpDeliveries += 1 },
            { $0.maximumDelayNanoseconds = 1 },
            { $0.maximumUrgentDelayNanoseconds = 1 },
        ]
        for change in counterChanges {
            var changed = forward
            change(&changed)
            #expect(changed != forward)
        }
        #expect(forward == reverse)
    }

    @Test func deliveryTracksEarliestRequestsAndClearsPendingWindows() {
        var ledger = RuntimeObservationMetricsLedger()
        ledger.recordRequest(.init(source: .videoEnqueue, urgency: .routine), at: 100, scheduled: true)
        ledger.recordRequest(.init(source: .audioEnqueue, urgency: .routine), at: 90, scheduled: false)
        ledger.recordRequest(.init(source: .rendererFailure, urgency: .urgent), at: 150, scheduled: false)
        ledger.recordRequest(.init(source: .decoderDrain, urgency: .urgent), at: 130, scheduled: false)
        ledger.recordDelivery(at: 200, isFollowUp: false)
        let first = ledger.snapshot
        #expect(first.totalRequests == 4)
        #expect(first.scheduledDeliveries == 1)
        #expect(first.coalescedRequests == 3)
        #expect(first.maximumDelayNanoseconds == 110)
        #expect(first.maximumUrgentDelayNanoseconds == 70)

        // A delivery with no new requests still counts, but must not extend
        // either delay maximum using a request from the previous delivery.
        ledger.recordDelivery(at: UInt64.max, isFollowUp: true)
        #expect(ledger.snapshot.deliveredObservations == 2)
        #expect(ledger.snapshot.followUpDeliveries == 1)
        #expect(ledger.snapshot.maximumDelayNanoseconds == 110)
        #expect(ledger.snapshot.maximumUrgentDelayNanoseconds == 70)

        ledger.recordRequest(.init(source: .preroll, urgency: .routine), at: 1_000, scheduled: true)
        ledger.recordDelivery(at: 2_000, isFollowUp: false)
        #expect(ledger.snapshot.maximumDelayNanoseconds == 1_000)
        #expect(ledger.snapshot.maximumUrgentDelayNanoseconds == 70)
        #expect(first.deliveredObservations == 1)
        #expect(first.requestsBySource[.preroll] == nil)
        #expect(first.maximumDelayNanoseconds == 110)
    }

    @Test func delayArithmeticPreservesUnsignedWrapAndNumericOldestTime() {
        let cases: [(requests: [(UInt64, Bool)], deliveredAt: UInt64, delay: UInt64, urgentDelay: UInt64)] = [
            ([(UInt64.max - 9, false), (UInt64.max - 4, true)], 5, 15, 10),
            ([(100, true)], 99, UInt64.max, UInt64.max),
            ([(20, false), (10, true), (30, true)], 100, 90, 90),
            ([(UInt64.max - 2, true), (2, false)], 8, 6, 11),
            ([(11, true)], 11, 0, 0),
            ([], UInt64.max, 0, 0),
        ]
        for (index, fixture) in cases.enumerated() {
            var ledger = RuntimeObservationMetricsLedger()
            for (time, urgent) in fixture.requests {
                ledger.recordRequest(
                    .init(source: .subtitlePacket, urgency: urgent ? .urgent : .routine),
                    at: time,
                    scheduled: true
                )
            }
            ledger.recordDelivery(at: fixture.deliveredAt, isFollowUp: false)
            #expect(ledger.snapshot.maximumDelayNanoseconds == fixture.delay, "case \(index)")
            #expect(ledger.snapshot.maximumUrgentDelayNanoseconds == fixture.urgentDelay, "case \(index)")
        }
    }

    @Test func tenThousandMixedEventsMatchJournalOracleAndRetainOldSnapshots() {
        var ledger = RuntimeObservationMetricsLedger()
        var journal: [ObservationMetricsEvent] = []
        var retained: [(actual: RuntimeObservationMetricsSnapshot, expected: ObservationMetricsReference)] = []
        let sources = RuntimeObservationSource.allCases
        var random: UInt64 = 0xDCA5_03A9_713E_825B
        var now: UInt64 = 1_000_000
        func next() -> UInt64 {
            random = random &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return random >> 32
        }

        expectSnapshot(ledger.snapshot, equals: ObservationMetricsReference(journal: []), context: "empty")
        retained.append((ledger.snapshot, ObservationMetricsReference(journal: [])))

        for step in 0..<10_000 {
            now += next() % 1_000
            let event: ObservationMetricsEvent
            if step < sources.count * 4 || next() % 4 != 0 {
                let source = sources[step < sources.count * 4 ? step % sources.count : Int(next() % UInt64(sources.count))]
                let urgent = step < sources.count * 4 ? step / sources.count >= 2 : next() % 3 == 0
                let scheduled = step < sources.count * 4 ? (step / sources.count).isMultiple(of: 2) : next() % 5 == 0
                event = .request(source: source, urgent: urgent, at: now - next() % 300, scheduled: scheduled)
            } else {
                event = .delivery(at: now, followUp: next() % 3 == 0)
            }
            journal.append(event)
            event.apply(to: &ledger)

            if step.isMultiple(of: 127) {
                let expected = ObservationMetricsReference(journal: journal)
                expectSnapshot(ledger.snapshot, equals: expected, context: "step \(step)")
                retained.append((ledger.snapshot, expected))
            }
            if step.isMultiple(of: 53) {
                let older = retained[Int(next() % UInt64(retained.count))]
                expectSnapshot(older.actual, equals: older.expected, context: "retained at step \(step)")
                var editedCopy = older.actual
                let source = sources[Int(next() % UInt64(sources.count))]
                editedCopy.requestsBySource[source, default: 0] += 1
                #expect(editedCopy != older.actual)
                expectSnapshot(older.actual, equals: older.expected, context: "after editing snapshot copy")
            }
        }

        expectSnapshot(ledger.snapshot, equals: ObservationMetricsReference(journal: journal), context: "final")
        for (index, older) in retained.enumerated() {
            expectSnapshot(older.actual, equals: older.expected, context: "retained snapshot \(index)")
        }
        for source in sources {
            #expect((ledger.snapshot.requestsBySource[source] ?? 0) > 0)
        }
        #expect(ledger.snapshot.scheduledDeliveries > 0)
        #expect(ledger.snapshot.coalescedRequests > 0)
        #expect(ledger.snapshot.deliveredObservations > 0)
        #expect(ledger.snapshot.followUpDeliveries > 0)
        #expect(ledger.snapshot.maximumDelayNanoseconds > 0)
        #expect(ledger.snapshot.maximumUrgentDelayNanoseconds > 0)
    }

    private func expectSnapshot(
        _ actual: RuntimeObservationMetricsSnapshot,
        equals expected: ObservationMetricsReference,
        context: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        var reconstructed = RuntimeObservationMetricsSnapshot()
        for source in RuntimeObservationSource.allCases {
            #expect(actual.requestsBySource[source] == expected.requestsBySource[source],
                    "\(context): \(source.rawValue)", sourceLocation: sourceLocation)
            #expect(actual.requestsBySource[source, default: -1] == expected.requestsBySource[source, default: -1],
                    "\(context): default \(source.rawValue)", sourceLocation: sourceLocation)
            reconstructed.requestsBySource[source] = expected.requestsBySource[source]
        }
        reconstructed.scheduledDeliveries = expected.scheduledDeliveries
        reconstructed.coalescedRequests = expected.coalescedRequests
        reconstructed.deliveredObservations = expected.deliveredObservations
        reconstructed.followUpDeliveries = expected.followUpDeliveries
        reconstructed.maximumDelayNanoseconds = expected.maximumDelayNanoseconds
        reconstructed.maximumUrgentDelayNanoseconds = expected.maximumUrgentDelayNanoseconds
        #expect(actual == reconstructed, "\(context)", sourceLocation: sourceLocation)
        #expect(actual.totalRequests == expected.requestsBySource.values.reduce(0, +),
                "\(context): total requests", sourceLocation: sourceLocation)
    }
}

private enum ObservationMetricsEvent {
    case request(source: RuntimeObservationSource, urgent: Bool, at: UInt64, scheduled: Bool)
    case delivery(at: UInt64, followUp: Bool)

    func apply(to ledger: inout RuntimeObservationMetricsLedger) {
        switch self {
        case let .request(source, urgent, time, scheduled):
            ledger.recordRequest(.init(source: source, urgency: urgent ? .urgent : .routine),
                                 at: time, scheduled: scheduled)
        case let .delivery(time, followUp):
            ledger.recordDelivery(at: time, isFollowUp: followUp)
        }
    }
}

/// Rebuilds the expected result from an immutable event journal. Source counts
/// come from grouping complete request history in a Dictionary. Delay maxima
/// come from complete pending windows, rather than incremental minimum fields.
private struct ObservationMetricsReference {
    let requestsBySource: [RuntimeObservationSource: Int]
    let scheduledDeliveries: Int
    let coalescedRequests: Int
    let deliveredObservations: Int
    let followUpDeliveries: Int
    let maximumDelayNanoseconds: UInt64
    let maximumUrgentDelayNanoseconds: UInt64

    init(journal: [ObservationMetricsEvent]) {
        var sources: [RuntimeObservationSource] = []
        var scheduling: [Bool] = []
        var deliveries: [Bool] = []
        var delays: [UInt64] = []
        var urgentDelays: [UInt64] = []
        var pending: [(time: UInt64, urgent: Bool)] = []
        for event in journal {
            switch event {
            case let .request(source, urgent, time, scheduled):
                sources.append(source)
                scheduling.append(scheduled)
                pending.append((time, urgent))
            case let .delivery(time, followUp):
                deliveries.append(followUp)
                if let oldest = pending.map(\.time).min() {
                    delays.append(time &- oldest)
                }
                if let oldestUrgent = pending.filter(\.urgent).map(\.time).min() {
                    urgentDelays.append(time &- oldestUrgent)
                }
                pending.removeAll()
            }
        }
        requestsBySource = Dictionary(grouping: sources, by: { $0 }).mapValues(\.count)
        scheduledDeliveries = scheduling.filter { $0 }.count
        coalescedRequests = scheduling.filter { !$0 }.count
        deliveredObservations = deliveries.count
        followUpDeliveries = deliveries.filter { $0 }.count
        maximumDelayNanoseconds = delays.max() ?? 0
        maximumUrgentDelayNanoseconds = urgentDelays.max() ?? 0
    }
}
