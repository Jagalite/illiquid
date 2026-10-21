import Foundation
import Testing
@testable import IlliquidApp

@Suite("Filesystem watcher lifecycle")
struct SourceFilesystemLifecycleTests {
    private final class Stream: SourceFilesystemStream, @unchecked Sendable {
        private let lock = NSLock()
        private var stops = 0
        var stopCount: Int { lock.withLock { stops } }
        func stop() { lock.withLock { stops += 1 } }
    }
    private final class State: @unchecked Sendable {
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var calls: [String] = []
        var callbacks: [SourceFilesystemStreamWorker.Receive] = []
        let first = Stream(), second = Stream()
        func record(_ path: String, _ receive: @escaping SourceFilesystemStreamWorker.Receive) -> Int {
            lock.withLock { calls.append(path); callbacks.append(receive); return calls.count }
        }
        var paths: [String] { lock.withLock { calls } }
        func waitUntilStarted() -> Bool { started.wait(timeout: .now() + 3) == .success }
        func emit(_ index: Int) {
            let callback = lock.withLock { callbacks[index] }
            callback([.init(path: "/watched/file", flags: [.created])])
        }
    }
    private func drain(_ queue: DispatchQueue) async {
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
    }

    @Test @MainActor func blockedCreationDoesNotBlockUIAndRestartDropsObsoleteStream() async {
        let state = State()
        let queue = DispatchQueue(label: "test.watcher.blocked")
        let worker = SourceFilesystemStreamWorker(queue: queue) { paths, _, _, receive in
            #expect(!Thread.isMainThread)
            let index = state.record(paths[0], receive)
            if index == 1 {
                state.started.signal()
                #expect(state.release.wait(timeout: .now() + 5) == .success)
                return state.first
            }
            return state.second
        }
        var deliveries = 0
        let monitor = SourceFilesystemMonitor(worker: worker) { _ in deliveries += 1 }
        monitor.start(watching: [URL(fileURLWithPath: "/old")])
        let started = await Task.detached { state.waitUntilStarted() }.value
        #expect(started)
        // These main-actor calls must complete while native creation is blocked.
        monitor.stop()
        monitor.start(watching: [URL(fileURLWithPath: "/intermediate")])
        monitor.start(watching: [URL(fileURLWithPath: "/new")])
        #expect(state.paths == ["/old"])
        state.release.signal()
        await drain(queue)
        #expect(state.paths == ["/old", "/new"])
        #expect(state.first.stopCount == 1)
        state.emit(0) // Superseded native callback must not reach the UI.
        state.emit(1)
        // The accepted callback is queued before this main-actor barrier.
        await Task { @MainActor in }.value
        #expect(deliveries == 1)
        monitor.stop()
        await drain(queue)
        #expect(state.second.stopCount == 1)
    }

    @Test @MainActor func stopRejectsAlreadyQueuedMainActorDelivery() async {
        let state = State()
        let queue = DispatchQueue(label: "test.watcher.delivery")
        let worker = SourceFilesystemStreamWorker(queue: queue) { paths, _, _, receive in
            _ = state.record(paths[0], receive)
            return state.first
        }
        var deliveries = 0
        let monitor = SourceFilesystemMonitor(worker: worker) { _ in deliveries += 1 }
        monitor.start(watching: [URL(fileURLWithPath: "/old")])
        await drain(queue)
        state.emit(0)
        monitor.stop() // Invalidate before the main-actor delivery task executes.
        await drain(queue)
        await Task { @MainActor in }.value
        #expect(deliveries == 0)
        #expect(state.first.stopCount == 1)
    }

    @Test @MainActor func nativeStreamDeliversEventsAfterAsynchronousStartup() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = DispatchQueue(label: "test.watcher.native")
        let worker = SourceFilesystemStreamWorker(queue: queue)
        var received: [SourceFilesystemEvent] = []
        let monitor = SourceFilesystemMonitor(worker: worker) { received.append(contentsOf: $0) }
        monitor.start(watching: [root], latency: 0.01)
        await drain(queue)
        try Data("test".utf8).write(to: root.appendingPathComponent("new.txt"))
        let deadline = ContinuousClock.now + .seconds(5)
        while !received.contains(where: { $0.path.hasSuffix("/new.txt") }), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        monitor.stop()
        await drain(queue)
        #expect(received.contains { $0.path.hasSuffix("/new.txt") && $0.flags.contains(.created) })
    }

    @Test @MainActor func releasingMonitorStopsItsNativeStream() async {
        let state = State()
        let queue = DispatchQueue(label: "test.watcher.release")
        let worker = SourceFilesystemStreamWorker(queue: queue) { _, _, _, _ in state.first }
        var monitor: SourceFilesystemMonitor? = SourceFilesystemMonitor(worker: worker) { _ in }
        monitor?.start(watching: [URL(fileURLWithPath: "/old")])
        await drain(queue)
        monitor = nil
        await drain(queue)
        #expect(state.first.stopCount == 1)
    }
}
