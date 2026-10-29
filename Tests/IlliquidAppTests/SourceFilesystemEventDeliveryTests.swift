import Foundation
import Testing

@testable import IlliquidApp

@Suite("Bounded source filesystem delivery")
struct SourceFilesystemEventDeliveryTests {
    @MainActor private final class Received {
        var batches: [[SourceFilesystemEvent]] = []
        var count = 0
        weak var delivery: SourceFilesystemEventDelivery?

        func append(_ events: [SourceFilesystemEvent]) {
            batches.append(events)
            count += events.count
        }

        func waitForCount(_ expected: Int) async {
            let deadline = ContinuousClock.now + .seconds(5)
            while count < expected, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(1))
            }
            #expect(count >= expected, "MainActor delivery did not complete")
        }
    }

    private static func event(_ index: Int) -> SourceFilesystemEvent {
        .init(path: "/media/movies/Film \(index).mkv", flags: [.created])
    }

    /// MainActor remains occupied until every callback has returned. This
    /// observes an actual executor backlog without depending on machine speed.
    @MainActor private func blockedBurst(
        to delivery: SourceFilesystemEventDelivery,
        count: Int,
        batchSize: Int
    ) {
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue(label: "test.filesystem-delivery.producer").async {
            for offset in stride(from: 0, to: count, by: batchSize) {
                delivery.send((offset..<min(count, offset + batchSize)).map(Self.event))
            }
            finished.signal()
        }
        #expect(finished.wait(timeout: .now() + 5) == .success)
    }

    @Test(arguments: [1, 128, 4096])
    @MainActor func pendingCallbacksCoalesceWithoutChangingEventsOrOrder(_ batchSize: Int) async {
        let received = Received()
        let delivery = SourceFilesystemEventDelivery { received.append($0) }
        defer { delivery.close() }
        delivery.send([])
        blockedBurst(to: delivery, count: 4096, batchSize: batchSize)
        #expect(received.count == 0)
        await received.waitForCount(4096)
        #expect(received.batches == [(0..<4096).map(Self.event)])
    }

    @Test(arguments: [1, 128, 4097])
    @MainActor func overflowWhileMainActorIsBusyRetainsOneRecoveryObligation(_ batchSize: Int) async {
        let received = Received()
        let delivery = SourceFilesystemEventDelivery { received.append($0) }
        defer { delivery.close() }
        blockedBurst(to: delivery, count: 8193, batchSize: batchSize)
        #expect(received.count == 0)
        await received.waitForCount(1)
        #expect(received.batches == [[.init(path: "/", flags: [.eventsDropped])]])
        let roots = [URL(fileURLWithPath: "/media/movies"), URL(fileURLWithPath: "/media/shows")]
        let plan = SourceFilesystemInvalidationPlanner.plan(
            events: received.batches.flatMap { $0 }, roots: roots)
        #expect(plan == SourceFilesystemInvalidationPlan(rootsToRescan: ["/media/movies", "/media/shows"]))
    }

    @Test @MainActor func nativeLossMarkerSupersedesPendingDetailAndDrainRearmsDelivery() async {
        let received = Received()
        let delivery = SourceFilesystemEventDelivery { received.append($0) }
        defer { delivery.close() }
        delivery.send([Self.event(0)])
        delivery.send([.init(path: "/unrelated", flags: [.eventsDropped])])
        delivery.send([Self.event(1)])
        await received.waitForCount(1)
        #expect(received.batches == [[.init(path: "/", flags: [.eventsDropped])]])
        delivery.send([Self.event(2), Self.event(3)])
        await received.waitForCount(3)
        #expect(received.batches.last == [Self.event(2), Self.event(3)])
    }

    @Test @MainActor func ordinaryDeliveryPreservesEveryFlagIncludingUnknownBits() async {
        let received = Received()
        let delivery = SourceFilesystemEventDelivery { received.append($0) }
        defer { delivery.close() }
        let flags: [SourceFilesystemEvent.Flags] = [
            [], [.created], [.removed, .directory], [.renamed],
            [.mustScanSubdirectories], [.rootChanged], [.eventIDsWrapped],
            .init(rawValue: 1 << 15),
        ]
        let events = flags.enumerated().map { index, flags in
            SourceFilesystemEvent(path: "/media/映画 Café \(index)", flags: flags)
        }
        for event in events { delivery.send([event]) }
        await received.waitForCount(events.count)
        #expect(received.batches == [events])
    }

    @Test @MainActor func closeDiscardsQueuedInputAndNeverAffectsReplacementSession() async {
        let received = Received()
        let retired = SourceFilesystemEventDelivery { received.append($0) }
        blockedBurst(to: retired, count: 4096, batchSize: 128)
        retired.close()
        retired.close()
        // Simulate a late callback from the old stream after its replacement.
        retired.send([Self.event(9999)])
        let replacement = SourceFilesystemEventDelivery { received.append($0) }
        defer { replacement.close() }
        replacement.send([Self.event(42)])
        await received.waitForCount(1)
        #expect(received.batches == [[Self.event(42)]])
    }

    @Test @MainActor func queuedTaskDoesNotKeepReleasedDeliveryAlive() async {
        let received = Received()
        var delivery: SourceFilesystemEventDelivery? = .init { received.append($0) }
        received.delivery = delivery
        delivery?.send((0..<4096).map(Self.event))
        delivery = nil
        #expect(received.delivery == nil)
        let sentinel = SourceFilesystemEventDelivery { received.append($0) }
        defer { sentinel.close() }
        sentinel.send([Self.event(42)])
        await received.waitForCount(1)
        #expect(received.batches == [[Self.event(42)]])
    }

    @Test @MainActor func handlerCanSendAgainWithoutDeadlockOrStrandingEvents() async {
        let received = Received()
        // This holder is MainActor-confined; the handler intentionally sends
        // synchronously while the previous delivery is still executing.
        let delivery = SourceFilesystemEventDelivery { events in
            received.append(events)
            if events == [Self.event(0)] { received.delivery?.send([Self.event(1)]) }
        }
        received.delivery = delivery
        defer { delivery.close() }
        delivery.send([Self.event(0)])
        await received.waitForCount(2)
        #expect(received.batches == [[Self.event(0)], [Self.event(1)]])
    }

    @Test @MainActor func concurrentProducersAndDrainsNeitherLoseNorDuplicateEvents() async {
        let received = Received()
        let delivery = SourceFilesystemEventDelivery(maximumCount: 2048) { received.append($0) }
        defer { delivery.close() }
        await withTaskGroup(of: Void.self) { group in
            for producer in 0..<4 {
                group.addTask {
                    for index in 0..<256 {
                        delivery.send([Self.event(producer * 256 + index)])
                        if index.isMultiple(of: 7) { await Task.yield() }
                    }
                }
            }
        }
        await received.waitForCount(1024)
        let events = received.batches.flatMap { $0 }
        #expect(events.count == 1024)
        #expect(Set(events.map(\.path)) == Set((0..<1024).map { Self.event($0).path }))
        #expect(events.allSatisfy { $0.flags == [.created] })
        for producer in 0..<4 {
            let expected = (0..<256).map { Self.event(producer * 256 + $0) }
            let paths = Set(expected.map(\.path))
            #expect(events.filter { paths.contains($0.path) } == expected)
        }
    }
}
