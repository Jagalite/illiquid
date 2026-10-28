import Foundation
import Testing
@testable import IlliquidApp

@Suite("Source filesystem event handoff")
struct SourceFilesystemEventMailboxTests {
    @Test func ordinaryBatchesKeepOrderAndScheduleOnlyOneDelivery() {
        let mailbox = SourceFilesystemEventMailbox(maximumCount: 8)
        let first = [Self.event(0), Self.event(1)]
        let second = [Self.event(2), Self.event(0)] // Duplicates remain meaningful.
        #expect(!mailbox.enqueue([]))
        #expect(mailbox.take().isEmpty)
        #expect(mailbox.enqueue(first))
        #expect(!mailbox.enqueue([]))
        #expect(!mailbox.enqueue(second))
        let taken = mailbox.take()
        #expect(taken == first + second)
        #expect(mailbox.take().isEmpty)
        #expect(mailbox.enqueue([Self.event(3)]))
        #expect(!mailbox.enqueue([Self.event(4)]))
        #expect(mailbox.take() == [Self.event(3), Self.event(4)])
        #expect(taken == first + second)
    }

    @Test(arguments: [false, true])
    func overflowAndNativeLossRecoverEveryRootThenAcceptOrdinaryEvents(_ nativeLoss: Bool) {
        let mailbox = SourceFilesystemEventMailbox(maximumCount: 4)
        #expect(mailbox.enqueue((0..<4).map(Self.event)))
        let incoming = nativeLoss
            ? [SourceFilesystemEvent(path: "/unrelated", flags: [.eventsDropped])]
            : [Self.event(4)]
        #expect(!mailbox.enqueue(incoming))
        for index in 5..<100 { #expect(!mailbox.enqueue([Self.event(index)])) }
        let recovery = mailbox.take()
        #expect(recovery == [.init(path: "/", flags: [.eventsDropped])])
        let roots = ["/media", "/other"].map { URL(fileURLWithPath: $0) }
        let plan = SourceFilesystemInvalidationPlanner.plan(events: recovery, roots: roots)
        #expect(plan == SourceFilesystemInvalidationPlan(rootsToRescan: ["/media", "/other"]))
        #expect(mailbox.enqueue([Self.event(100)]))
        #expect(mailbox.take() == [Self.event(100)])
        #expect(mailbox.take().isEmpty)
    }

    @Test func oversizedFirstCallbackSchedulesExactlyOneRecovery() {
        let mailbox = SourceFilesystemEventMailbox(maximumCount: 2)
        #expect(mailbox.enqueue((0..<100).map(Self.event)))
        #expect(!mailbox.enqueue([Self.event(100)]))
        #expect(mailbox.take() == [.init(path: "/", flags: [.eventsDropped])])
        #expect(mailbox.enqueue([Self.event(101)]))
        #expect(mailbox.take() == [Self.event(101)])
    }

    @Test func stoppingDiscardsPendingWorkAndPermanentlyRejectsAdmission() {
        weak var released: SourceFilesystemEventMailbox?
        do {
            let mailbox = SourceFilesystemEventMailbox()
            released = mailbox
            let path = "/media/" + String(repeating: "long-path", count: 1024)
            #expect(mailbox.enqueue([.init(path: path, flags: [.created])]))
            mailbox.stop()
            #expect(mailbox.take().isEmpty)
            #expect(!mailbox.enqueue([]))
            #expect(!mailbox.enqueue([Self.event(1)]))
            mailbox.stop()
            #expect(mailbox.take().isEmpty)
        }
        #expect(released == nil)
    }

    @Test func concurrentProducersKeepEveryEventWithOnePendingDelivery() {
        let count = 512
        let mailbox = SourceFilesystemEventMailbox(maximumCount: count)
        let observations = MailboxObservations()
        DispatchQueue.concurrentPerform(iterations: count) { index in
            observations.recordWake(mailbox.enqueue([Self.event(index)]))
        }
        let actual = mailbox.take()
        #expect(observations.snapshot().wakes == 1)
        #expect(actual.count == count)
        #expect(Set(actual.map(\.path)) == Set((0..<count).map { Self.event($0).path }))
        #expect(actual.allSatisfy { $0.flags == [.created] })
        #expect(mailbox.take().isEmpty)
        #expect(mailbox.enqueue([Self.event(count)]))
        #expect(mailbox.take() == [Self.event(count)])
    }

    @Test func racingTakeAndEnqueueNeverLoseAnEventOrItsWakeup() {
        for iteration in 0..<256 {
            let mailbox = SourceFilesystemEventMailbox(maximumCount: 2)
            let first = Self.event(iteration * 2)
            let second = Self.event(iteration * 2 + 1)
            let observations = MailboxObservations()
            #expect(mailbox.enqueue([first]))
            DispatchQueue.concurrentPerform(iterations: 2) { participant in
                if participant == 0 {
                    observations.recordBatch(mailbox.take())
                } else {
                    observations.recordWake(mailbox.enqueue([second]))
                }
            }
            let observed = observations.snapshot()
            let remaining = mailbox.take()
            #expect(observed.batches.count == 1)
            #expect(observed.batches.flatMap { $0 } + remaining == [first, second])
            // A post-drain event needs a wakeup; a pre-drain event joins that delivery.
            #expect(observed.wakes == (remaining.isEmpty ? 0 : 1))
            #expect(mailbox.take().isEmpty)
        }
    }

    private static func event(_ index: Int) -> SourceFilesystemEvent {
        .init(path: "/media/Film \(index).mkv", flags: [.created])
    }
}

private final class MailboxObservations: @unchecked Sendable {
    private let lock = NSLock()
    private var wakes = 0
    private var batches: [[SourceFilesystemEvent]] = []
    func recordWake(_ scheduled: Bool) { lock.withLock { if scheduled { wakes += 1 } } }
    func recordBatch(_ batch: [SourceFilesystemEvent]) { lock.withLock { batches.append(batch) } }
    func snapshot() -> (wakes: Int, batches: [[SourceFilesystemEvent]]) {
        lock.withLock { (wakes, batches) }
    }
}
