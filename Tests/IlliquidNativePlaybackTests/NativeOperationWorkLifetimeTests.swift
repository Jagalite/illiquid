import Foundation
import IlliquidCore
import IlliquidPlayback
import IlliquidPlaybackCore
import Testing

@testable import IlliquidNativePlayback

@Suite("Native operation work lifetime", .serialized)
struct NativeOperationWorkLifetimeTests {
    @Test @MainActor
    func supersededPresentationWorkIsRemovedBeforeTheNextTaskCanRun() async throws {
        let backend = try NativePlaybackRuntime()
        let recorder = OperationWorkEventRecorder()
        backend.eventHandler = { [weak recorder] event in recorder?.record(event) }

        let effects = (UInt64(1)...64).map { effect(
            $0,
            kind: .installPresentationFence(removeDisplayedImage: false)
        ) }
        // No suspension between effects: every older poller is still pending
        // when its successor must cancel and remove it.
        for pending in effects {
            backend.execute(PlaybackRuntimeEffectRequest(effect: pending))
        }

        #expect(backend.operationWorkTaskCountForTesting == 1)
        #expect(backend.operationDeadlineTaskCountForTesting == 1)
        for superseded in effects.dropLast() {
            #expect(recorder.results[superseded.context.effectID] == [.cancelled])
        }

        let latest = effects[effects.count - 1]
        #expect(await waitUntil {
            recorder.results[latest.context.effectID] == [.succeeded]
        })
        #expect(backend.operationWorkTaskCountForTesting == 0)
        #expect(backend.operationDeadlineTaskCountForTesting == 0)
        for superseded in effects.dropLast() {
            #expect(recorder.results[superseded.context.effectID] == [.cancelled])
        }

        backend.eventHandler = nil
        await backend.shutdown()
    }

    @Test @MainActor
    func synchronousResultReentryCannotReinstallSupersededWorkOrFence() async throws {
        let backend = try NativePlaybackRuntime()
        let first = effect(1, kind: .installPresentationFence(removeDisplayedImage: false))
        let second = effect(2, kind: .installPresentationFence(removeDisplayedImage: false))
        let newest = effect(3, kind: .installPresentationFence(removeDisplayedImage: false))
        let recorder = OperationWorkEventRecorder()
        backend.eventHandler = { [weak backend, weak recorder] event in
            guard let recorder else { return }
            recorder.record(event)
            guard case let .effectResult(result) = event.payload,
                  result.context.effectID == first.context.effectID,
                  result.token.kind == .cancelled,
                  !recorder.didReenter
            else { return }
            recorder.didReenter = true
            backend?.execute(PlaybackRuntimeEffectRequest(effect: newest))
        }

        backend.execute(PlaybackRuntimeEffectRequest(effect: first))
        backend.execute(PlaybackRuntimeEffectRequest(effect: second))

        #expect(recorder.didReenter)
        #expect(backend.operationWorkTaskCountForTesting == 1)
        #expect(backend.operationDeadlineTaskCountForTesting == 1)
        #expect(recorder.results[first.context.effectID] == [.cancelled])
        #expect(recorder.results[second.context.effectID] == [.cancelled])
        #expect(await waitUntil {
            recorder.results[newest.context.effectID] == [.succeeded]
        })
        #expect(backend.operationWorkTaskCountForTesting == 0)
        #expect(backend.operationDeadlineTaskCountForTesting == 0)
        #expect(recorder.results[first.context.effectID] == [.cancelled])
        #expect(recorder.results[second.context.effectID] == [.cancelled])

        backend.eventHandler = nil
        await backend.shutdown()
    }

    @Test(arguments: [false, true]) @MainActor
    func supersededStopRetainsPhysicalWaitUntilCompletionOrShutdown(
        shutdownImmediately: Bool
    ) async throws {
        guard let fixtureDirectory = ProcessInfo.processInfo.environment[
            "ILLIQUID_NATIVE_FIXTURE_DIR"
        ] else { return }
        let mediaURL = URL(fileURLWithPath: fixtureDirectory, isDirectory: true)
            .appendingPathComponent("multiple-audio-flags.mkv")
        try #require(FileManager.default.fileExists(atPath: mediaURL.path))
        let source = MediaSource.localFile(mediaURL)
        let media = try #require(MediaLoadRequest(source: source, origin: .userSelected))
        let backend = try NativePlaybackRuntime()
        do {
            _ = try backend.makeSurfaceHost()
            try backend.load(PlaybackRuntimeLoadRequest(
                media: media,
                identity: PlayerSessionIdentity(source: source, generation: 1)
            ))
        } catch {
            await backend.shutdown()
            throw error
        }
        #expect(await waitUntil(timeout: .seconds(8)) {
            backend.sessionSnapshotForDiagnostics?.isPrerolled == true
        })

        let recorder = OperationWorkEventRecorder()
        backend.eventHandler = { [weak recorder] event in recorder?.record(event) }
        let first = effect(1, kind: .cancelSession, executor: .input)
        let second = effect(2, kind: .cancelSession, executor: .input)
        backend.execute(PlaybackRuntimeEffectRequest(effect: first))
        #expect(backend.operationWorkTaskCountForTesting == 1)
        // Both calls run in the same main-actor turn. The first stop's task
        // cannot finish before the second removes its logical transaction.
        backend.execute(PlaybackRuntimeEffectRequest(effect: second))
        #expect(backend.operationWorkTaskCountForTesting == 1)
        #expect(backend.operationDeadlineTaskCountForTesting == 0)
        #expect(recorder.results[first.context.effectID] == [.cancelled])
        #expect(recorder.results[second.context.effectID] == [.succeeded])

        if !shutdownImmediately {
            #expect(await waitUntil {
                backend.operationWorkTaskCountForTesting == 0
            })
        }
        await backend.shutdown()

        #expect(backend.operationWorkTaskCountForTesting == 0)
        #expect(backend.operationDeadlineTaskCountForTesting == 0)
        #expect(recorder.results[first.context.effectID] == [.cancelled])
        #expect(recorder.results[second.context.effectID] == [.succeeded])
        let leases = backend.runtimeLeaseSnapshotsForTesting
        #expect(!leases.isEmpty)
        #expect(leases.allSatisfy {
            $0.disposition == .released && $0.activeBorrows.isEmpty
        })
        backend.eventHandler = nil
    }

    private func effect(
        _ id: UInt64,
        kind: PlaybackEffectKind,
        executor: ExecutorKind = .presentation
    ) -> PlaybackEffect {
        PlaybackEffect(
            executor: executor,
            context: PlaybackEffectContext(
                authority: .playback(
                    sessionID: PlaybackSessionID(rawValue: 1),
                    generation: PlaybackGenerationID(rawValue: 1),
                    revisions: PlaybackRevisionSet()
                ),
                operationID: PlaybackOperationID(rawValue: id),
                effectID: PlaybackEffectID(rawValue: id)
            ),
            kind: kind
        )
    }

    @MainActor
    private func waitUntil(
        timeout: Duration = .seconds(5),
        _ predicate: () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return predicate()
    }
}

@MainActor
private final class OperationWorkEventRecorder {
    var results: [PlaybackEffectID: [EffectResultKind]] = [:]
    var didReenter = false

    func record(_ event: PlaybackRuntimeEvent) {
        guard case let .effectResult(result) = event.payload else { return }
        results[result.context.effectID, default: []].append(result.token.kind)
    }
}
