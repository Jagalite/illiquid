import Foundation
import Testing
@testable import IlliquidApp

@Suite("Filesystem worker-to-main-actor handoff")
struct SourceFilesystemHandoffTests {
    private final class Stream: SourceFilesystemStream, @unchecked Sendable {
        func stop() {}
    }

    private final class Callback: @unchecked Sendable {
        private let lock = NSLock()
        private var receive: SourceFilesystemStreamWorker.Receive?

        func install(_ receive: @escaping SourceFilesystemStreamWorker.Receive) {
            lock.withLock { self.receive = receive }
        }

        func emit(_ events: [SourceFilesystemEvent]) {
            let callback = lock.withLock { receive }
            callback?(events)
        }
    }

    @MainActor private final class Sink {
        var batches: [[SourceFilesystemEvent]] = []

        func waitForDelivery() async {
            let deadline = ContinuousClock.now + .seconds(3)
            while batches.isEmpty, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(1))
            }
            #expect(!batches.isEmpty, "Expected a main-actor delivery")
        }
    }

    @MainActor private func start(
        callback: Callback, queue: DispatchQueue, sink: Sink
    ) async -> SourceFilesystemMonitor {
        let worker = SourceFilesystemStreamWorker(queue: queue) { _, _, _, receive in
            callback.install(receive)
            return Stream()
        }
        let monitor = SourceFilesystemMonitor(worker: worker) { sink.batches.append($0) }
        #expect(monitor.start(watching: [
            URL(fileURLWithPath: "/media/first"),
            URL(fileURLWithPath: "/media/second"),
        ]))
        await sink.waitForDelivery()
        #expect(sink.batches.flatMap { $0 }.count == 2)
        sink.batches.removeAll()
        return monitor
    }

    @Test @MainActor func stalledActorReceivesOneOrderedBatchAndCanBeRearmed() async {
        let callback = Callback(), queue = DispatchQueue(label: "test.handoff.ordinary")
        let sink = Sink()
        let monitor = await start(callback: callback, queue: queue, sink: sink)
        defer { monitor.stop() }
        let events: [SourceFilesystemEvent] = (0..<4096).map {
            .init(path: "/media/first/Film \($0).mkv", flags: [.created])
        }
        // Keep MainActor occupied until every worker callback has returned.
        queue.sync {
            for start in stride(from: 0, to: events.count, by: 128) {
                callback.emit(Array(events[start..<min(start + 128, events.count)]))
            }
            callback.emit([])
        }
        #expect(sink.batches.isEmpty)
        await sink.waitForDelivery()
        #expect(sink.batches == [events])
        sink.batches.removeAll()
        let next = SourceFilesystemEvent(path: "/media/second/New.mkv", flags: [.renamed])
        queue.sync { callback.emit([next]) }
        await sink.waitForDelivery()
        #expect(sink.batches == [[next]])
    }

    @Test @MainActor func stalledActorOverflowRecoversEveryWatchedRoot() async {
        let callback = Callback(), queue = DispatchQueue(label: "test.handoff.overflow")
        let sink = Sink()
        let monitor = await start(callback: callback, queue: queue, sink: sink)
        defer { monitor.stop() }
        queue.sync {
            for batch in 0..<1000 {
                callback.emit((0..<128).map {
                    .init(path: "/media/first/Film \(batch * 128 + $0).mkv", flags: [.created])
                })
            }
        }
        #expect(sink.batches.isEmpty)
        await sink.waitForDelivery()
        #expect(sink.batches.count == 1)
        let events = sink.batches.flatMap { $0 }
        #expect(events.count == 1)
        #expect(events.first?.flags.contains(.eventsDropped) == true)
        let plan = SourceFilesystemInvalidationPlanner.plan(events: events, roots: [
            URL(fileURLWithPath: "/media/first"), URL(fileURLWithPath: "/media/second"),
        ])
        #expect(plan == SourceFilesystemInvalidationPlan(
            rootsToRescan: ["/media/first", "/media/second"]))
    }

    @Test @MainActor func restartWhileDeliveryIsQueuedRejectsOldEvents() async {
        let callback = Callback(), queue = DispatchQueue(label: "test.handoff.restart")
        let sink = Sink()
        let monitor = await start(callback: callback, queue: queue, sink: sink)
        defer { monitor.stop() }
        queue.sync {
            callback.emit([.init(path: "/media/first/old.mkv", flags: [.created])])
        }
        monitor.start(watching: [URL(fileURLWithPath: "/replacement")])
        // Install the replacement stream and queue readiness while MainActor is held.
        queue.sync {}
        queue.sync {
            callback.emit([.init(path: "/replacement/new.mkv", flags: [.created])])
        }
        await sink.waitForDelivery()
        #expect(sink.batches.flatMap { $0 } == [
            .init(path: "/replacement", flags: [.mustScanSubdirectories]),
            .init(path: "/replacement/new.mkv", flags: [.created]),
        ])
    }

    @Test @MainActor func queuedDeliveryDoesNotKeepMonitorAlive() async {
        let callback = Callback(), queue = DispatchQueue(label: "test.handoff.deinit")
        let sink = Sink()
        var monitor: SourceFilesystemMonitor? = await start(callback: callback, queue: queue, sink: sink)
        weak let weakMonitor = monitor
        queue.sync {
            callback.emit([.init(path: "/media/first/old.mkv", flags: [.created])])
        }
        monitor = nil
        #expect(weakMonitor == nil)
        queue.sync {} // Complete worker teardown without giving the queued task self.
        await Task { @MainActor in }.value
        #expect(sink.batches.isEmpty)
    }
}
