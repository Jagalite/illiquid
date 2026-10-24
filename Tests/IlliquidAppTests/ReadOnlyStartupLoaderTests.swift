import Testing
@testable import IlliquidApp

@Suite("Read-only application startup")
@MainActor
struct ReadOnlyStartupLoaderTests {
    private actor ReadGate {
        private var completion: CheckedContinuation<Int, Never>?
        private var startedWaiters: [CheckedContinuation<Void, Never>] = []
        private(set) var calls = 0

        func read() async -> Int {
            calls += 1
            return await withCheckedContinuation { continuation in
                completion = continuation
                for waiter in startedWaiters { waiter.resume() }
                startedWaiters.removeAll()
            }
        }
        func waitUntilStarted() async {
            guard calls == 0 else { return }
            await withCheckedContinuation { startedWaiters.append($0) }
        }
        func finish() { completion?.resume(returning: 42); completion = nil }
    }

    @MainActor
    private final class ArrivalCounter {
        private(set) var count = 0
        private var target = 0
        private var completion: CheckedContinuation<Void, Never>?

        func record() {
            count += 1
            guard count >= target else { return }
            completion?.resume()
            completion = nil
        }

        func wait(until target: Int) async {
            guard count < target else { return }
            self.target = target
            await withCheckedContinuation { completion = $0 }
        }
    }

    @MainActor
    private final class SharedModel {
        let value: Int
        var receivedRequests: [[Int]] = []
        init(value: Int) { self.value = value }
    }

    @MainActor
    private final class SharedOwner {
        let loader: ReadOnlyStartupLoader<Int>
        let arrivals = ArrivalCounter()
        var shared: SharedModel?
        var isShutdown = false
        var publications = 0
        var pendingRequests: [[Int]] = []

        init(read: @escaping @Sendable () async -> Int) {
            loader = ReadOnlyStartupLoader(read: read)
        }

        func load() async -> SharedModel? {
            await loader.loadShared(existing: {
                self.arrivals.record()
                return self.shared
            }, isShutdown: {
                self.isShutdown
            }) { value in
                self.publications += 1
                let model = SharedModel(value: value)
                self.shared = model
                // The application's publisher also drains queued Finder opens
                // synchronously. Side effects must complete exactly once before
                // any waiting caller receives the shared model.
                let requests = self.pendingRequests
                self.pendingRequests.removeAll()
                for request in requests { model.receivedRequests.append(request) }
                return model
            }
        }
    }

    private final class SourceProbe: Sendable {
        let id: Int
        init(id: Int) { self.id = id }
    }

    private struct SourceSnapshot: Sendable {
        let sources: [SourceProbe]
    }

    private actor SourceFactory {
        private(set) var calls = 0
        private weak var first: SourceProbe?
        private weak var second: SourceProbe?

        func read() -> SourceSnapshot {
            calls += 1
            let first = SourceProbe(id: 1)
            let second = SourceProbe(id: 2)
            self.first = first
            self.second = second
            return SourceSnapshot(sources: [first, second])
        }

        var livingIDs: [Int] { [first?.id, second?.id].compactMap { $0 } }
    }

    @MainActor
    private final class SourceOwner {
        var sources: [SourceProbe]
        init(_ snapshot: SourceSnapshot) { sources = snapshot.sources }
    }

    @Test func sceneAndDelegateWaitersShareOneReadAndCachedValue() async {
        let gate = ReadGate()
        let loader = ReadOnlyStartupLoader { await gate.read() }
        let first = Task { await loader.load() }
        let second = Task { await loader.load() }
        await gate.waitUntilStarted()
        await Task.yield()
        #expect(await gate.calls == 1)
        await gate.finish()
        #expect(await first.value == 42)
        #expect(await second.value == 42)
        #expect(await loader.load() == 42)
        #expect(await gate.calls == 1)
    }

    @Test func shutdownPreventsLatePublicationOrAnotherRead() async {
        let gate = ReadGate()
        let loader = ReadOnlyStartupLoader { await gate.read() }
        let first = Task { await loader.load() }
        await gate.waitUntilStarted()
        loader.stop()
        #expect(await loader.load() == nil)
        #expect(await gate.calls == 1)
        await gate.finish()
        #expect(await first.value == nil)
        #expect(await loader.load() == nil)
    }

    @Test func concurrentWaitersPublishOnceAndCompleteQueuedRequestsInOrder() async throws {
        let gate = ReadGate()
        let owner = SharedOwner { await gate.read() }
        owner.pendingRequests = [[3, 1], [4], [2, 5]]
        let waiters = (0..<8).map { _ in Task { await owner.load() } }
        // Every caller has passed its pre-read existing-model check before the
        // underlying read is released. No sleeps or scheduler luck are needed.
        await owner.arrivals.wait(until: waiters.count)
        await gate.waitUntilStarted()
        #expect(owner.arrivals.count == waiters.count)
        #expect(await gate.calls == 1)
        await gate.finish()

        for waiter in waiters {
            let received = try #require(await waiter.value)
            #expect(received === owner.shared)
            #expect(received.value == 42)
            #expect(received.receivedRequests == [[3, 1], [4], [2, 5]])
        }
        #expect(owner.publications == 1)
        #expect(owner.pendingRequests.isEmpty)
        #expect(await owner.loader.load() == nil)
        let later = try #require(await owner.load())
        #expect(later === owner.shared)
        #expect(owner.publications == 1)
        #expect(await gate.calls == 1)
    }

    @Test func suspendedWaiterReturnsSharedModelAfterAnotherCallerRetiresLoader() async throws {
        let gate = ReadGate()
        let owner = SharedOwner { await gate.read() }
        let waiter = Task { await owner.load() }
        await gate.waitUntilStarted()
        // Force the race boundary: a sibling has published while this caller
        // is suspended, and retirement makes its underlying load return nil.
        let published = SharedModel(value: 91)
        owner.shared = published
        owner.loader.stop()
        await gate.finish()

        let received = try #require(await waiter.value)
        #expect(received === published)
        #expect(owner.publications == 0)
        #expect(await owner.loader.load() == nil)
        #expect(await gate.calls == 1)
    }

    @Test(arguments: [false, true])
    func shutdownBeforeLoadWinsOverExistingModel(hasPublishedModel: Bool) async {
        let gate = ReadGate()
        let owner = SharedOwner { await gate.read() }
        if hasPublishedModel { owner.shared = SharedModel(value: 91) }
        owner.isShutdown = true
        owner.loader.stop()

        #expect(await owner.load() == nil)
        #expect(owner.publications == 0)
        #expect(await gate.calls == 0)
    }

    @Test(arguments: [false, true])
    func shutdownDuringReadRejectsEveryWaiter(hasPublishedModel: Bool) async {
        let gate = ReadGate()
        let owner = SharedOwner { await gate.read() }
        let waiters = (0..<8).map { _ in Task { await owner.load() } }
        await owner.arrivals.wait(until: waiters.count)
        await gate.waitUntilStarted()
        if hasPublishedModel { owner.shared = SharedModel(value: 91) }
        owner.isShutdown = true
        owner.loader.stop()
        await gate.finish()

        for waiter in waiters { #expect(await waiter.value == nil) }
        #expect(owner.publications == 0)
        #expect(await owner.load() == nil)
        #expect(await gate.calls == 1)
    }

    @Test func retiredLoaderWithoutSharedModelDoesNotPublish() async {
        let gate = ReadGate()
        let owner = SharedOwner { await gate.read() }
        let waiter = Task { await owner.load() }
        await gate.waitUntilStarted()
        owner.loader.stop()
        await gate.finish()

        #expect(await waiter.value == nil)
        #expect(owner.shared == nil)
        #expect(owner.publications == 0)
    }

    @Test func startupSnapshotReleasesSourcesWhenPublishedOwnerRemovesThem() async throws {
        let factory = SourceFactory()
        let loader = ReadOnlyStartupLoader { await factory.read() }
        var shared: SourceOwner?
        let published = try #require(await loader.loadShared(
            existing: { shared }, isShutdown: { false }
        ) { snapshot in
            let model = SourceOwner(snapshot)
            shared = model
            return model
        })
        #expect(published === shared)
        #expect(await factory.livingIDs == [1, 2])

        published.sources.removeFirst()
        #expect(await factory.livingIDs == [2])
        published.sources.removeAll()
        #expect(await factory.livingIDs.isEmpty)
        #expect(await loader.load() == nil)

        let later = await loader.loadShared(existing: { shared }, isShutdown: { false }) { snapshot in
            Issue.record("A published model must not be replaced or rehydrate removed sources")
            return SourceOwner(snapshot)
        }
        #expect(later === published)
        #expect(await factory.calls == 1)
        #expect(await factory.livingIDs.isEmpty)
    }
}
