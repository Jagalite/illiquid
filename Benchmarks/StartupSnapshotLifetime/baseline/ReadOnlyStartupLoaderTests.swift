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
}
