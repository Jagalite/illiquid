import Testing
@testable import IlliquidApp

@Suite("Read-only application startup")
@MainActor
struct ReadOnlyStartupLoaderTests {
    private final class StartupPayload: Sendable {
        let bytes = [UInt8](repeating: 0xA5, count: 4096)
    }

    @MainActor
    private final class WeakLoader {
        weak var value: ReadOnlyStartupLoader<StartupPayload>?

        init(_ value: ReadOnlyStartupLoader<StartupPayload>?) {
            self.value = value
        }
    }

    private actor PayloadReadGate {
        private var completion: CheckedContinuation<StartupPayload, Never>?
        private var startedWaiters: [CheckedContinuation<Void, Never>] = []
        private weak var payload: StartupPayload?
        private(set) var calls = 0

        var hasLivePayload: Bool { payload != nil }

        func read() async -> StartupPayload {
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

        func finish() {
            let value = StartupPayload()
            payload = value
            completion?.resume(returning: value)
            completion = nil
        }
    }

    @MainActor
    private final class ReaderEntryGate {
        private var entries = 0
        private var completion: CheckedContinuation<Void, Never>?

        func enter() {
            entries += 1
            if entries == 2 {
                completion?.resume()
                completion = nil
            }
        }

        func waitForBoth() async {
            guard entries < 2 else { return }
            await withCheckedContinuation { completion = $0 }
        }
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
        let entries = ReaderEntryGate()
        let loader = ReadOnlyStartupLoader { await gate.read() }
        let first = Task { entries.enter(); return await loader.load() }
        let second = Task { entries.enter(); return await loader.load() }
        await entries.waitForBoth()
        await gate.waitUntilStarted()
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

    @Test func releasingTheLoaderOwnerReleasesItsCachedSnapshot() async {
        let gate = PayloadReadGate()
        var loader: ReadOnlyStartupLoader<StartupPayload>? = ReadOnlyStartupLoader {
            await gate.read()
        }
        let originalLoader = WeakLoader(loader)
        // Return only a scalar: a completed Task must not become another owner
        // of the snapshot whose lifetime this test is checking.
        var reader: Task<Int?, Never>? = Task { @MainActor [weak loader] in
            await loader?.load()?.bytes.count
        }
        await gate.waitUntilStarted()
        await gate.finish()
        #expect(await reader?.value == 4096)
        reader = nil

        #expect(await gate.hasLivePayload)
        #expect(originalLoader.value != nil)
        loader = nil
        #expect(originalLoader.value == nil)
        #expect(await !gate.hasLivePayload)
    }

    @Test(arguments: [false, true])
    func activeReadersOutliveTheOwnerAndRespectShutdown(stopping: Bool) async {
        let gate = PayloadReadGate()
        let entries = ReaderEntryGate()
        var loader: ReadOnlyStartupLoader<StartupPayload>? = ReadOnlyStartupLoader {
            await gate.read()
        }
        let originalLoader = WeakLoader(loader)
        var first: Task<Int?, Never>? = Task { @MainActor [weak loader] in
            entries.enter()
            return await loader?.load()?.bytes.count
        }
        var second: Task<Int?, Never>? = Task { @MainActor [weak loader] in
            entries.enter()
            return await loader?.load()?.bytes.count
        }
        await entries.waitForBoth()
        await gate.waitUntilStarted()
        #expect(await gate.calls == 1)

        if stopping { loader?.stop() }
        loader = nil
        // In-flight load calls own the loader until their read completes.
        #expect(originalLoader.value != nil)
        await gate.finish()
        let expected: Int? = stopping ? nil : 4096
        #expect(await first?.value == expected)
        #expect(await second?.value == expected)
        first = nil
        second = nil
        #expect(await gate.calls == 1)
        #expect(originalLoader.value == nil)
        #expect(await !gate.hasLivePayload)
    }
}
