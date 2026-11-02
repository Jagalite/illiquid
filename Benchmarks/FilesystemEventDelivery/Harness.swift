import Foundation
import CLeaseHeap

private let watchedRoots = [
    URL(fileURLWithPath: "/media/first", isDirectory: true),
    URL(fileURLWithPath: "/media/second", isDirectory: true),
]

private func event(_ index: Int, loss: Bool = false) -> SourceFilesystemEvent {
    let folder = index.isMultiple(of: 2) ? "first" : "second"
    return .init(
        path: "/media/\(folder)/Season \(index % 31)/"
            + String(repeating: "x", count: 64 + index % 65) + "/\(index).mkv",
        flags: loss ? [.eventsDropped] : (index.isMultiple(of: 3) ? [.renamed] : [.created])
    )
}

// Release temporary Foundation objects before the heap sample on macOS.
private func scoped(_ body: () -> Void) {
    #if canImport(ObjectiveC)
    autoreleasepool(invoking: body)
    #else
    body()
    #endif
}

@MainActor
private final class Recorder {
    var batches: [[SourceFilesystemEvent]] = []
    var count = 0
    var target = 0
    var continuation: CheckedContinuation<Void, Never>?

    func receive(_ events: [SourceFilesystemEvent]) {
        batches.append(events)
        count += events.count
        if let continuation, count >= target {
            self.continuation = nil
            continuation.resume()
        }
    }

    func wait(for count: Int) async {
        if self.count >= count { return }
        target = count
        await withCheckedContinuation { continuation = $0 }
    }
}

@main
private struct Harness {
    @MainActor
    static func main() async throws {
        let args = CommandLine.arguments
        precondition(args.count == 5, "usage: Harness measure|measure-close|verify COUNT BATCH ordinary|loss")
        let mode = args[1]
        let count = Int(args[2])!
        let batchSize = Int(args[3])!
        let hasLoss = args[4] == "loss"
        precondition(count > 0 && batchSize > 0)

        // Warm task runtime, worker queue, and allocator query before measuring.
        await Task { @MainActor in }.value
        let queue = DispatchQueue(label: "benchmark.filesystem-producer")
        let warmed = DispatchSemaphore(value: 0)
        queue.async { warmed.signal() }
        precondition(warmed.wait(timeout: .now() + 10) == .success)
        _ = lease_history_allocator_bytes()
        let recorder = Recorder()
        let delivery = MeasuredDelivery { recorder.receive($0) }
        let done = DispatchSemaphore(value: 0)
        let before = lease_history_allocator_bytes()

        // Synchronously hold MainActor while the real scheduling mechanism is
        // called from the worker queue. No delivery can run before the sample.
        queue.async {
            for offset in stride(from: 0, to: count, by: batchSize) {
                scoped {
                    let end = min(count, offset + batchSize)
                    let events = (offset..<end).map {
                        event($0, loss: hasLoss && $0 == count / 2)
                    }
                    delivery.send(events)
                }
            }
            done.signal()
        }
        precondition(done.wait(timeout: .now() + 120) == .success, "producer timed out")
        precondition(recorder.count == 0, "MainActor was not held")
        let pendingBytes = lease_history_allocator_bytes()

        if mode == "measure-close" {
            // Keep MainActor occupied: queued tasks have no opportunity to
            // release their captures. Observe what closing alone releases.
            delivery.close()
            let closedBytes = lease_history_allocator_bytes()
            precondition(recorder.count == 0)
            withExtendedLifetime(delivery) {}
            try emit([
                "input_events": count,
                "batch_size": batchSize,
                "held_main_actor": true,
                "allocator_metric": String(cString: lease_history_allocator_metric()),
                "allocator_before_bytes": before,
                "allocator_pending_bytes": pendingBytes,
                "allocator_closed_bytes": closedBytes,
                "pending_delta_bytes": Int64(pendingBytes) - Int64(before),
                "closed_delta_bytes": Int64(closedBytes) - Int64(before),
                "bytes_released_by_close": Int64(pendingBytes) - Int64(closedBytes),
            ])
            return
        }

        #if CANDIDATE_DELIVERY
        let isRecovery = count > 4096 || hasLoss
        let expectedCount = isRecovery ? 1 : count
        #else
        let isRecovery = false
        let expectedCount = count
        #endif
        await recorder.wait(for: expectedCount)
        let events = recorder.batches.flatMap { $0 }
        precondition(events.count == expectedCount)
        if isRecovery {
            precondition(events == [.init(path: "/", flags: [.eventsDropped])])
        } else {
            precondition(events == (0..<count).map { event($0, loss: hasLoss && $0 == count / 2) })
        }
        let plan = SourceFilesystemInvalidationPlanner.plan(events: events, roots: watchedRoots)
        if isRecovery || hasLoss {
            precondition(plan.rootsToRescan == Set(watchedRoots.map(\.path)))
            precondition(plan.directoriesToReload.isEmpty && plan.treesToInvalidate.isEmpty)
        }
        let deliveries = recorder.batches.count
        #if CANDIDATE_DELIVERY
        precondition(deliveries == 1)
        #else
        precondition(deliveries == (count + batchSize - 1) / batchSize)
        #endif
        var result: [String: Any] = [
            "input_events": count,
            "batch_size": batchSize,
            "input_batches": (count + batchSize - 1) / batchSize,
            "loss_marker_in_input": hasLoss,
            "held_main_actor": true,
            "allocator_metric": String(cString: lease_history_allocator_metric()),
            "allocator_before_bytes": before,
            "allocator_pending_bytes": pendingBytes,
            "allocator_delta_bytes": Int64(pendingBytes) - Int64(before),
            "delivered_batches": deliveries,
            "delivered_events": events.count,
            "delivered_path_utf8_bytes": events.reduce(0) { $0 + $1.path.utf8.count },
            "directories_to_reload_count": plan.directoriesToReload.count,
            "trees_to_invalidate_count": plan.treesToInvalidate.count,
            "roots_to_rescan": plan.rootsToRescan.sorted(),
        ]
        if mode == "verify" {
            result["directories_to_reload"] = plan.directoriesToReload.sorted()
            result["trees_to_invalidate"] = plan.treesToInvalidate.sorted()
            result["events"] = events.map { ["path": $0.path, "flags": $0.flags.rawValue] as [String: Any] }
        }
        delivery.close()
        withExtendedLifetime(delivery) {}
        try emit(result)
    }

    private static func emit(_ result: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
