import Dispatch
import Foundation

@_silgen_name("live_heap_bytes")
private func liveHeapBytes() -> UInt64

private struct BenchmarkFailure: Error, CustomStringConvertible {
    let description: String
}

private enum Fixture {
    static let limit = 4096
    static let rootPaths = ["/illiquid-handoff/a", "/illiquid-handoff/b"]
    static let roots = rootPaths.map { URL(fileURLWithPath: $0, isDirectory: true) }
    static let padding = String(repeating: "x", count: 96)

    static func event(_ index: Int) -> SourceFilesystemEvent {
        let flags: SourceFilesystemEvent.Flags
        switch index % 3 {
        case 0: flags = [.created]
        case 1: flags = [.removed]
        default: flags = [.renamed]
        }
        let path = rootPaths[index % 2]
            + "/folder-\(index / 64)/event-\(index)-\(padding).mkv"
        return .init(path: path, flags: flags)
    }
}

/// Holds the stream's receive closure, never an emitted input batch.
private final class FakeSource: @unchecked Sendable {
    private let lock = NSLock()
    private var receiver: SourceFilesystemStreamWorker.Receive?
    private var stops = 0
    let emitted = DispatchSemaphore(value: 0)

    func install(_ receive: @escaping SourceFilesystemStreamWorker.Receive) {
        lock.withLock { receiver = receive }
    }

    func stop() {
        lock.withLock { receiver = nil; stops += 1 }
    }

    var stopCount: Int { lock.withLock { stops } }

    @inline(never)
    func emit(total: Int, batchSize: Int) {
        let receive = lock.withLock { receiver! }
        var offset = 0
        while offset < total {
            let count = min(batchSize, total - offset)
            autoreleasepool {
                var events: [SourceFilesystemEvent] = []
                events.reserveCapacity(count)
                for index in offset..<(offset + count) { events.append(Fixture.event(index)) }
                receive(events)
            }
            offset += count
        }
    }
}

private final class FakeStream: SourceFilesystemStream, @unchecked Sendable {
    private let source: FakeSource
    init(_ source: FakeSource) { self.source = source }
    func stop() { source.stop() }
}

@MainActor
private final class Sink {
    let total: Int
    var armed = false
    var startupDelivered = false
    var deliveryCount = 0
    var rawEventCount = 0
    var nextOrdinaryIndex = 0
    var failure: String?
    var buffer = SourceFilesystemEventBuffer()

    init(total: Int) { self.total = total }

    func receive(_ events: [SourceFilesystemEvent]) {
        if !armed {
            let expected = Fixture.rootPaths.map {
                SourceFilesystemEvent(path: $0, flags: [.mustScanSubdirectories])
            }
            if startupDelivered || events != expected {
                failure = "Startup reconciliation differs from the expected roots"
            }
            startupDelivered = true
            return
        }
        deliveryCount += 1
        rawEventCount += events.count
        if total <= Fixture.limit {
            for event in events {
                if event != Fixture.event(nextOrdinaryIndex) {
                    failure = "Ordinary event payload, flags, or ordering changed"
                }
                nextOrdinaryIndex += 1
            }
        }
        buffer.append(contentsOf: events)
    }

    @inline(never)
    func verify(variant: String, expectedCallbacks: Int) throws -> [String: Any] {
        if let failure { throw BenchmarkFailure(description: failure) }
        guard deliveryCount == expectedCallbacks else {
            throw BenchmarkFailure(description: "Unexpected handler delivery count")
        }
        let expectedRawCount = variant == "candidate" && total > Fixture.limit ? 1 : total
        guard rawEventCount == expectedRawCount else {
            throw BenchmarkFailure(description: "Unexpected raw event count")
        }
        let events = buffer.take()
        let plan = SourceFilesystemInvalidationPlanner.plan(events: events, roots: Fixture.roots)
        if total > Fixture.limit {
            guard events == [.init(path: "/", flags: [.eventsDropped])],
                  plan == SourceFilesystemInvalidationPlan(rootsToRescan: Set(Fixture.rootPaths))
            else { throw BenchmarkFailure(description: "Overflow lost all-root recovery") }
        } else {
            let expected = (0..<total).map { Fixture.event($0) }
            guard nextOrdinaryIndex == total, events == expected,
                  plan == SourceFilesystemInvalidationPlanner.plan(events: expected, roots: Fixture.roots)
            else { throw BenchmarkFailure(description: "Ordinary output or planner parity failed") }
        }
        var checksum: UInt64 = 14_695_981_039_346_656_037
        for event in events {
            for byte in event.path.utf8 { checksum = (checksum ^ UInt64(byte)) &* 1_099_511_628_211 }
            checksum = (checksum ^ UInt64(event.flags.rawValue)) &* 1_099_511_628_211
        }
        return [
            "downstream_event_count": events.count,
            "downstream_checksum": String(checksum, radix: 16),
            "directories_to_reload": plan.directoriesToReload.sorted(),
            "trees_to_invalidate": plan.treesToInvalidate.sorted(),
            "roots_to_rescan": plan.rootsToRescan.sorted(),
        ]
    }
}

@MainActor
private func waitFor(_ description: String, _ predicate: @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(30)
    while !predicate() {
        guard ContinuousClock.now < deadline else {
            throw BenchmarkFailure(description: "Timed out waiting for \(description)")
        }
        try await Task.sleep(for: .milliseconds(1))
    }
}

private func drainWorker(_ queue: DispatchQueue) async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        queue.async { continuation.resume() }
    }
}

/// Hold MainActor until emit returns and all callback inputs have left scope.
@MainActor @inline(never)
private func enqueueWhileActorIsHeld(
    source: FakeSource, queue: DispatchQueue, total: Int, batchSize: Int
) throws -> UInt64 {
    queue.async {
        source.emit(total: total, batchSize: batchSize)
        source.emitted.signal()
    }
    guard source.emitted.wait(timeout: .now() + 30) == .success else {
        throw BenchmarkFailure(description: "Worker emission timed out")
    }
    queue.sync {} // Include completion of the signaling worker closure.
    return liveHeapBytes()
}

@main
private struct Driver {
    @MainActor
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count == 4, ["baseline", "candidate"].contains(args[1]),
              let total = Int(args[2]), total >= 0,
              let batchSize = Int(args[3]), batchSize > 0 else {
            throw BenchmarkFailure(description: "Usage: Driver baseline|candidate TOTAL_EVENTS BATCH_SIZE")
        }
        let variant = args[1]
        let batches = total / batchSize + (total % batchSize == 0 ? 0 : 1)
        let expectedCallbacks = variant == "baseline" ? batches : (total == 0 ? 0 : 1)
        let source = FakeSource()
        let queue = DispatchQueue(label: "benchmark.filesystem-handoff")
        let worker = SourceFilesystemStreamWorker(queue: queue) { _, _, _, receive in
            source.install(receive)
            return FakeStream(source)
        }
        let sink = Sink(total: total)
        let monitor = SourceFilesystemMonitor(worker: worker) { sink.receive($0) }
        guard monitor.start(watching: Fixture.roots) else {
            throw BenchmarkFailure(description: "Watch request was rejected")
        }
        try await waitFor("startup reconciliation") { sink.startupDelivered || sink.failure != nil }
        if let failure = sink.failure { throw BenchmarkFailure(description: failure) }
        await drainWorker(queue)
        autoreleasepool { _ = Fixture.event(0) } // Warm lazy fixture storage.
        _ = liveHeapBytes()
        sink.armed = true
        let before = liveHeapBytes()
        let held = try enqueueWhileActorIsHeld(source: source, queue: queue, total: total, batchSize: batchSize)
        try await waitFor("handler receipts") { sink.deliveryCount >= expectedCallbacks || sink.failure != nil }
        let afterDrain = liveHeapBytes()
        monitor.stop()
        await drainWorker(queue)
        let afterStop = withExtendedLifetime(monitor) { liveHeapBytes() }
        guard source.stopCount == 1 else {
            throw BenchmarkFailure(description: "Stream did not stop exactly once")
        }
        let semantic = try sink.verify(variant: variant, expectedCallbacks: expectedCallbacks)
        let output: [String: Any] = [
            "variant": variant, "total_events": total, "batch_size": batchSize, "verified": true,
            "delivery_count": sink.deliveryCount, "raw_delivered_event_count": sink.rawEventCount,
            "heap_before_bytes": before, "heap_held_bytes": held,
            "heap_after_drain_bytes": afterDrain, "heap_after_stop_bytes": afterStop,
            "held_delta_bytes": Int64(held) - Int64(before),
            "after_drain_delta_bytes": Int64(afterDrain) - Int64(before),
            "after_stop_delta_bytes": Int64(afterStop) - Int64(before),
            "downstream_retained_during_release_samples": true, "semantic": semantic,
        ]
        let encoded = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
        print(String(decoding: encoded, as: UTF8.self))
    }
}
