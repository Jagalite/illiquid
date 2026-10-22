import CoreMedia
import Foundation
import Testing
@testable import IlliquidNativePlayback

@Suite("Presentation observation cadence", .serialized)
@MainActor
struct PresentationObservationCadenceTests {
    @Test func firstRequestAlwaysReachesTheReceiver() {
        for interval in [CMTime(value: 1, timescale: 30),
                         CMTime(value: 1, timescale: 4)] {
            var cadence = PresentationObservationCadence()
            var applied: [CMTime] = []
            cadence.update(interval) { applied.append($0) }

            // A new gate must not assume the receiver already has its
            // default 30 Hz interval, even when that is the first request.
            #expect(applied.count == 1)
            #expect(applied.first?.value == interval.value)
            #expect(applied.first?.timescale == interval.timescale)
        }
    }

    @Test func steadyRequestsDoNotReconfigureTheReceiver() {
        var cadence = PresentationObservationCadence()
        var applied: [CMTime] = []
        let interval = CMTime(value: 1, timescale: 60)

        for _ in 0..<10_000 {
            cadence.update(interval) { applied.append($0) }
        }

        #expect(applied == [interval])
    }

    @Test func equivalentRationalIntervalsUseCoreMediaEquality() {
        let initial = CMTime(value: 1, timescale: 30)
        let equivalent = CMTime(value: 4_000, timescale: 120_000)
        #expect(initial == equivalent)

        var cadence = PresentationObservationCadence()
        var applied: [CMTime] = []
        cadence.update(initial) { applied.append($0) }
        cadence.update(equivalent) { applied.append($0) }

        #expect(applied.count == 1)
        #expect(applied.first?.value == initial.value)
        #expect(applied.first?.timescale == initial.timescale)
    }

    @Test func forwardsCadenceChangesAndReturnToEarlierIntervals() {
        let intervals = [4, 24, 30, 60, 120, 60, 30, 24, 4].map {
            CMTime(value: 1, timescale: Int32($0))
        }
        var cadence = PresentationObservationCadence()
        var applied: [CMTime] = []

        for interval in intervals {
            for _ in 0..<25 {
                cadence.update(interval) { applied.append($0) }
            }
        }

        #expect(applied == intervals)
    }

    @Test func aNewReceiverGetsItsOwnInitialRequest() {
        let interval = CMTime(value: 1, timescale: 30)
        var firstCadence = PresentationObservationCadence()
        var secondCadence = PresentationObservationCadence()
        var firstApplied: [CMTime] = []
        var secondApplied: [CMTime] = []

        firstCadence.update(interval) { firstApplied.append($0) }
        firstCadence.update(interval) { firstApplied.append($0) }
        secondCadence.update(interval) { secondApplied.append($0) }
        secondCadence.update(interval) { secondApplied.append($0) }

        #expect(firstApplied == [interval])
        #expect(secondApplied == [interval])
    }

    @Test func invalidIntervalsDoNotReachTheReceiverOrReplaceTheLastValidInterval() {
        let invalidIntervals: [CMTime] = [
            .invalid, .indefinite, .positiveInfinity, .negativeInfinity,
            .zero, CMTime(value: -1, timescale: 30),
        ]
        let initial = CMTime(value: 1, timescale: 30)
        let changed = CMTime(value: 1, timescale: 60)
        var cadence = PresentationObservationCadence()
        var applied: [CMTime] = []

        for interval in invalidIntervals {
            cadence.update(interval) { applied.append($0) }
        }
        #expect(applied.isEmpty)
        cadence.update(initial) { applied.append($0) }
        #expect(applied == [initial])

        for interval in invalidIntervals {
            cadence.update(interval) { applied.append($0) }
            cadence.update(initial) { applied.append($0) }
        }
        #expect(applied == [initial])

        cadence.update(changed) { applied.append($0) }
        #expect(applied == [initial, changed])
    }

    @Test func duplicateRequestDoesNotEnterABlockedReceiverQueue() throws {
        let interval = CMTime(value: 1, timescale: 30)
        var cadence = PresentationObservationCadence()
        var applied: [CMTime] = []
        cadence.update(interval) { applied.append($0) }

        let receiverQueue = DispatchQueue(label: "illiquid.test.cadence-receiver")
        let blockerEntered = DispatchSemaphore(value: 0)
        let releaseBlocker = DispatchSemaphore(value: 0)
        receiverQueue.async {
            blockerEntered.signal()
            releaseBlocker.wait()
        }
        // Ensure the receiver really is occupied before issuing the duplicate.
        // This timeout is a deadlock bound, not a performance assertion.
        let didEnter = blockerEntered.wait(timeout: .now() + 5) == .success
        if !didEnter { releaseBlocker.signal() }
        try #require(didEnter)

        // A broken gate might enter the synchronous receiver. Release it from
        // outside MainActor so that such a regression fails instead of hanging.
        let watchdog = DispatchWorkItem { releaseBlocker.signal() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: watchdog)
        defer {
            watchdog.cancel()
            releaseBlocker.signal()
            receiverQueue.sync {}
        }

        cadence.update(interval) { requested in
            applied.append(requested)
            receiverQueue.sync {}
        }

        // The proof is zero additional receiver calls, independent of timing.
        #expect(applied == [interval])
    }
}
