import Testing
@testable import IlliquidApp

@Suite("Read-only application startup")
@MainActor
struct ReadOnlyStartupLoaderTests {
    private final class LifetimeToken: Sendable {}

    @MainActor
    private final class TokenWitness {
        weak var value: LifetimeToken?
        private(set) var reads = 0
        private(set) var readWasCancelled = false

        func make(wasCancelled: Bool = false) -> LifetimeToken {
            reads += 1
            readWasCancelled = wasCancelled
            let token = LifetimeToken()
            value = token
            return token
        }
    }

    // Return only a Bool so neither the helper nor a caller's Task result keeps
    // the token alive while the test inspects the loader's ownership.
    private func consume(_ loader: ReadOnlyStartupLoader<LifetimeToken>) async -> Bool {
        await loader.load() != nil
    }

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

    @Test func finishReleasesCachedValueAndPreventsAnotherRead() async {
        let witness = TokenWitness()
        let loader = ReadOnlyStartupLoader { await witness.make() }
        #expect(await consume(loader))
        #expect(await consume(loader))
        #expect(witness.value != nil)
        #expect(witness.reads == 1)

        loader.finish()
        loader.finish()
        #expect(witness.value == nil)
        #expect(await loader.load() == nil)
        #expect(witness.reads == 1)
    }

    @Test func finishAllowsInFlightReadWithoutCancellationOrRecaching() async {
        let gate = ReadGate()
        let witness = TokenWitness()
        let loader = ReadOnlyStartupLoader {
            _ = await gate.read()
            return await witness.make(wasCancelled: Task.isCancelled)
        }
        let first = Task { await consume(loader) }
        await gate.waitUntilStarted()

        loader.finish()
        #expect(await loader.load() == nil)
        await gate.finish()
        #expect(await first.value)
        #expect(!witness.readWasCancelled)
        #expect(witness.reads == 1)
        #expect(witness.value == nil)
        #expect(await loader.load() == nil)
        #expect(await gate.calls == 1)
    }

    @Test func shutdownAfterFinishRejectsAnInFlightResult() async {
        let gate = ReadGate()
        let loader = ReadOnlyStartupLoader { await gate.read() }
        let first = Task { await loader.load() }
        await gate.waitUntilStarted()

        loader.finish()
        loader.stop()
        loader.finish()
        await gate.finish()
        #expect(await first.value == nil)
        #expect(await loader.load() == nil)
        #expect(await gate.calls == 1)
    }

    @Test func finishCannotReviveAStoppedLoader() async {
        let witness = TokenWitness()
        let loader = ReadOnlyStartupLoader { await witness.make() }
        loader.stop()
        loader.finish()
        loader.stop()
        #expect(await loader.load() == nil)
        #expect(witness.reads == 0)
    }

    @Test func finishBeforeLoadingPreventsTheRead() async {
        let witness = TokenWitness()
        let loader = ReadOnlyStartupLoader { await witness.make() }
        loader.finish()
        #expect(await loader.load() == nil)
        #expect(witness.reads == 0)
    }
}
