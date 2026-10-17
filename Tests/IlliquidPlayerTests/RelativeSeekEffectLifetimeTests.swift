import Foundation
import IlliquidCore
import IlliquidPlayback
import IlliquidPlaybackCore
import Testing
@testable import IlliquidPlayer

@MainActor
@Suite("Relative seek effect lifetime", .serialized)
struct RelativeSeekEffectLifetimeTests {
    @Test func burstRetainsOnlyDispatchedWorkAndTheLatestDeferredSeek() throws {
        let fixture = try RelativeSeekLifetimeFixture()
        var accepted = true
        // There is no actor suspension in this burst. If a slow machine crosses
        // a dispatch deadline, additional native-owned effects are legitimate.
        for _ in 0..<600 {
            accepted = fixture.driver.seek(to: 1, mode: .relative) && accepted
        }

        let issued = fixture.observations.seekEffects
        let final = try #require(issued.last)
        let dispatched = Set(fixture.runtime.seekEffects.map { $0.context.effectID })
        let allowed = dispatched.union([final.context.effectID])
        let retired = Set(issued.map { $0.context.effectID }).subtracting(allowed)
        let checkpoint = try fixture.checkpoint()

        #expect(accepted)
        #expect(issued.count == 600)
        #expect(!retired.isEmpty)
        #expect(checkpoint.pendingEffectIDs == allowed)
        #expect(checkpoint.outstandingEffectIDs == allowed)
        #expect(retired.isSubset(of: checkpoint.completedEffectIDs))
        #expect(fixture.driver.currentSnapshot.position == mediaTime(620))
        #expect(fixture.driver.currentSnapshot.desiredTransport == .playing)
        #expect(fixture.driver.currentSnapshot.failureCode == nil)
        #expect(fixture.observations.invariantViolations.isEmpty)
    }

    @Test func retiredCancellationIsDuplicateAndPreservesTheLatestTarget() throws {
        let fixture = try RelativeSeekLifetimeFixture()
        fixture.sendBurst([10, 10, -5])
        let retired = try fixture.requireDeferredEffect(at: 1)
        let before = fixture.driver.currentSnapshot
        let executedCount = fixture.runtime.executedEffects.count

        fixture.runtime.finish(retired, kind: .cancelled)
        #expect(fixture.observations.lastDisposition == .duplicate(effectID: retired.context.effectID))
        #expect(fixture.driver.currentSnapshot == before)
        fixture.runtime.finish(retired, kind: .cancelled)
        #expect(fixture.observations.lastDisposition == .duplicate(effectID: retired.context.effectID))
        #expect(fixture.driver.currentSnapshot == before)
        #expect(fixture.runtime.executedEffects.count == executedCount)
        #expect(before.position == mediaTime(35))
        #expect(before.phase == .seeking)
        #expect(before.failureCode == nil)
        #expect(fixture.observations.invariantViolations.isEmpty)
    }

    @Test(arguments: [false, true])
    func exactSeekAndStopRetireUndispatchedRelativeWork(stop: Bool) throws {
        let fixture = try RelativeSeekLifetimeFixture()
        fixture.sendBurst([10, 10])
        let deferred = try fixture.requireDeferredEffect(at: 1)

        if stop {
            #expect(fixture.driver.stop())
        } else {
            #expect(fixture.driver.seek(to: 120, mode: .exact))
        }
        let checkpoint = try fixture.checkpoint()
        let before = fixture.driver.currentSnapshot
        let executedCount = fixture.runtime.executedEffects.count
        #expect(!checkpoint.pendingEffectIDs.contains(deferred.context.effectID))
        #expect(!checkpoint.outstandingEffectIDs.contains(deferred.context.effectID))
        #expect(checkpoint.completedEffectIDs.contains(deferred.context.effectID))
        #expect(before.failureCode == nil)

        fixture.runtime.finish(deferred, kind: .cancelled)
        #expect(fixture.observations.lastDisposition == .duplicate(effectID: deferred.context.effectID))
        #expect(fixture.driver.currentSnapshot == before)
        #expect(fixture.runtime.executedEffects.count == executedCount)
        if stop {
            #expect(before.source == nil)
            #expect(before.desiredTransport == .stopped)
        } else {
            #expect(before.position == mediaTime(120))
            #expect(fixture.runtime.seekEffects.last?.kind == .seekPipeline(target: mediaTime(120), mode: .exact))
        }
        #expect(fixture.observations.invariantViolations.isEmpty)
    }

    @Test func dispatchedSeekRemainsNativeOwnedUntilItsLateResultArrives() throws {
        let fixture = try RelativeSeekLifetimeFixture()
        fixture.sendBurst([10, 10, 10])
        let dispatched = try #require(fixture.runtime.seekEffects.first)
        let latest = try #require(fixture.observations.seekEffects.last)
        let checkpoint = try fixture.checkpoint()
        #expect(checkpoint.pendingEffectIDs.contains(dispatched.context.effectID))
        #expect(checkpoint.outstandingEffectIDs.contains(dispatched.context.effectID))
        #expect(!checkpoint.completedEffectIDs.contains(dispatched.context.effectID))

        let before = fixture.driver.currentSnapshot
        let executedCount = fixture.runtime.executedEffects.count
        fixture.runtime.finish(dispatched)
        #expect(fixture.observations.lastDisposition == .stale(reason: .generationMismatch))
        #expect(fixture.driver.currentSnapshot == before)
        #expect(fixture.runtime.executedEffects.count == executedCount)
        let settled = try fixture.checkpoint()
        #expect(!settled.pendingEffectIDs.contains(dispatched.context.effectID))
        #expect(!settled.outstandingEffectIDs.contains(dispatched.context.effectID))
        #expect(settled.pendingEffectIDs.contains(latest.context.effectID))
        #expect(before.position == mediaTime(50))
        #expect(before.desiredTransport == .playing)
        #expect(before.failureCode == nil)
        #expect(fixture.observations.invariantViolations.isEmpty)
    }

    @Test func sleepDispatchesTheCurrentDeferredSeekWithoutCancellingItsEffect() throws {
        let fixture = try RelativeSeekLifetimeFixture()
        fixture.sendBurst([10, 10])
        let deferred = try fixture.requireDeferredEffect(at: 1)
        fixture.runtime.completesSeeksSynchronously = true

        #expect(fixture.driver.systemWillSleep())

        #expect(fixture.runtime.seekEffects.last?.context == deferred.context)
        #expect(fixture.runtime.seekEffects.count == 2)
        #expect(fixture.driver.currentSnapshot.position == mediaTime(40))
        #expect(fixture.driver.currentSnapshot.phase == .paused)
        #expect(fixture.driver.currentSnapshot.desiredTransport == .playing)
        #expect(fixture.driver.currentSnapshot.failureCode == nil)
        #expect(fixture.observations.failureCodes.isEmpty)
        #expect(fixture.observations.invariantViolations.isEmpty)
        let checkpoint = try fixture.checkpoint()
        #expect(!checkpoint.pendingEffectIDs.contains(deferred.context.effectID))
        #expect(!checkpoint.outstandingEffectIDs.contains(deferred.context.effectID))
        #expect(checkpoint.completedEffectIDs.contains(deferred.context.effectID))
    }

    @Test func observerCanReenterWithDuplicateCancellationAfterRetirement() throws {
        let fixture = try RelativeSeekLifetimeFixture()
        fixture.sendBurst([10, 10])
        let deferred = try fixture.requireDeferredEffect(at: 1)
        var reentered = false
        fixture.driver.onTransition = { transition in
            fixture.observations.record(transition)
            if !reentered, transition.disposition == .stale(reason: .generationMismatch) {
                reentered = true
                fixture.runtime.finish(deferred, kind: .cancelled)
            }
        }
        defer { fixture.driver.onTransition = nil }

        #expect(fixture.driver.seek(to: -5, mode: .relative))

        #expect(reentered)
        #expect(fixture.observations.dispositions.contains(.duplicate(effectID: deferred.context.effectID)))
        #expect(fixture.driver.currentSnapshot.position == mediaTime(35))
        #expect(fixture.driver.currentSnapshot.failureCode == nil)
        #expect(fixture.observations.invariantViolations.isEmpty)
        let checkpoint = try fixture.checkpoint()
        #expect(!checkpoint.outstandingEffectIDs.contains(deferred.context.effectID))
        #expect(!checkpoint.pendingEffectIDs.contains(deferred.context.effectID))
    }

    @Test func shutdownFinalizesWithoutDispatchingTheDeferredSeek() async throws {
        let fixture = try RelativeSeekLifetimeFixture()
        fixture.sendBurst([10, 10, 10])
        let deferred = try fixture.requireDeferredEffect(at: 2)
        let seekCount = fixture.runtime.seekEffects.count

        await fixture.driver.shutdown()
        // Let the cancelled dispatch task pass its original 40 ms deadline.
        try await Task.sleep(for: .milliseconds(60))

        #expect(fixture.runtime.seekEffects.count == seekCount)
        #expect(fixture.runtime.finalizationCount == 1)
        #expect(fixture.runtime.directShutdownCount == 0)
        #expect(fixture.driver.currentSnapshot.lifecycle == .terminated)
        let checkpoint = try fixture.checkpoint()
        #expect(checkpoint.pendingEffectIDs.isEmpty)
        #expect(checkpoint.outstandingEffectIDs.isEmpty)

        let executedCount = fixture.runtime.executedEffects.count
        fixture.runtime.finish(deferred, kind: .cancelled)
        #expect(fixture.observations.lastDisposition == .ignoredAfterTermination)
        #expect(fixture.driver.currentSnapshot.lifecycle == .terminated)
        #expect(fixture.runtime.executedEffects.count == executedCount)
        #expect(fixture.observations.failureCodes.isEmpty)
        #expect(fixture.observations.invariantViolations.isEmpty)
    }

    private func mediaTime(_ seconds: Int64) -> MediaTimestamp {
        .valid(ValidMediaTime(value: seconds * 1_000_000, timescale: 1_000_000)!)
    }
}

@MainActor
private final class RelativeSeekLifetimeFixture {
    let driver: PlaybackRuntimeDriver
    let runtime = RelativeSeekLifetimeRuntime()
    let observations = RelativeSeekLifetimeObservations()

    init() throws {
        var model = PlaybackModelRuntime(recordsReplaySteps: false)
        _ = model.send(.command(.load(
            source: MediaSourceIdentity(rawValue: "fixture/relative-seek-lifetime.mkv"),
            autoplay: true
        )))
        // Settle the real core's open, preroll and resume sequence before the
        // driver is installed. The fake never opens a file or creates a view.
        for _ in 0..<8 where !model.pendingEffects.isEmpty {
            _ = model.completeNext()
        }
        #expect(model.pendingEffects.isEmpty)
        #expect(model.core.state.activeSession?.phase == .playing)
        _ = model.send(.acceptedClockSample(.valid(ValidMediaTime(value: 20, timescale: 1)!)))
        _ = model.send(.durationObserved(.valid(ValidMediaTime(value: 3_600, timescale: 1)!)))
        driver = PlaybackRuntimeDriver(runtime: runtime, model: model)
        let observations = self.observations
        driver.onTransition = { observations.record($0) }
    }

    func sendBurst(_ deltas: [Double]) {
        var accepted = true
        for delta in deltas {
            accepted = driver.seek(to: delta, mode: .relative) && accepted
        }
        #expect(accepted)
    }

    func requireDeferredEffect(at index: Int) throws -> PlaybackEffect {
        let issued = observations.seekEffects
        let effect = try #require(issued.indices.contains(index) ? issued[index] : nil)
        let wasDispatched = runtime.seekEffects.contains { $0.context == effect.context }
        try #require(!wasDispatched, "The synchronous burst must leave this effect undispatched")
        return effect
    }

    func checkpoint() throws -> RelativeSeekLifetimeCheckpoint {
        // Reflection is confined to assertions, without adding production
        // observability. Rebuild the ID sets so no model COW storage is retained
        // by a checkpoint during later commands or callbacks.
        let reflected = Mirror(reflecting: driver).children.first { $0.label == "model" }?.value
        let model = try #require(reflected as? PlaybackModelRuntime)
        return RelativeSeekLifetimeCheckpoint(
            pendingEffectIDs: Set(model.pendingEffects.map { $0.context.effectID }),
            outstandingEffectIDs: Set(model.core.state.outstandingEffects.keys.map { $0 }),
            completedEffectIDs: Set(model.core.state.completedEffectIDs.map { $0 })
        )
    }
}

private struct RelativeSeekLifetimeCheckpoint {
    let pendingEffectIDs: Set<PlaybackEffectID>
    let outstandingEffectIDs: Set<PlaybackEffectID>
    let completedEffectIDs: Set<PlaybackEffectID>
}

@MainActor
private final class RelativeSeekLifetimeObservations {
    private(set) var seekEffects: [PlaybackEffect] = []
    private(set) var dispositions: [EventDisposition] = []
    private(set) var failureCodes: [String] = []
    private(set) var invariantViolations: [PlaybackInvariantViolation] = []

    var lastDisposition: EventDisposition? { dispositions.last }

    func record(_ transition: PlaybackTransition) {
        seekEffects.append(contentsOf: transition.effects.filter {
            if case .seekPipeline = $0.kind { return true }
            return false
        })
        dispositions.append(transition.disposition)
        if let code = transition.snapshot.failureCode { failureCodes.append(code) }
        invariantViolations.append(contentsOf: transition.invariantViolations)
    }
}

@MainActor
private final class RelativeSeekLifetimeRuntime: PlaybackRuntime {
    let capabilities: PlaybackCapabilities = [.relativeSeeking, .exactSeeking]
    var eventHandler: (@MainActor @Sendable (PlaybackRuntimeEvent) -> Void)?
    var completesSeeksSynchronously = false
    private(set) var executedEffects: [PlaybackEffect] = []
    private(set) var finalizationCount = 0
    private(set) var directShutdownCount = 0

    var seekEffects: [PlaybackEffect] {
        executedEffects.filter {
            if case .seekPipeline = $0.kind { return true }
            return false
        }
    }

    func makeSurfaceHost() throws -> any PlaybackSurfaceHost {
        throw UnsupportedPlaybackCapabilityError("surface unused by effect lifetime tests")
    }

    func execute(_ request: PlaybackRuntimeEffectRequest) {
        let effect = request.effect
        executedEffects.append(effect)
        switch effect.kind {
        case .seekPipeline, .seek:
            if completesSeeksSynchronously { finish(effect) }
        case .finalizeShutdown:
            finalizationCount += 1
            finish(effect)
        default:
            finish(effect)
        }
    }

    func finish(_ effect: PlaybackEffect, kind: EffectResultKind = .succeeded) {
        eventHandler?(PlaybackRuntimeEvent(
            identity: nil,
            payload: .effectResult(PlaybackEffectResult(
                context: effect.context,
                token: EffectResultToken(kind: kind)
            ))
        ))
    }

    func setVolume(_ value: Double) {}
    func setMuted(_ value: Bool) {}
    func setPlaybackSpeed(_ value: Double) {}
    func selectAudioOutputDevice(_ id: String?) {}
    func setAudioDelay(_ value: TimeInterval) {}
    func setHardwareDecodingPolicy(_ policy: HardwareDecodingPolicy) {}
    func setVideoAspect(_ aspect: String?) {}
    func setVideoCrop(_ crop: String?) {}
    func setVideoRotation(_ rotation: Int) {}
    func setDeinterlace(_ enabled: Bool) {}
    func setVideoEqualizer(_ adjustments: VideoAdjustmentState) {}
    func setPictureInPictureActive(_ active: Bool) {}
    func execute(_ command: IlliquidCore.PlaybackCommand) async throws {}
    func shutdown() async { directShutdownCount += 1 }
}
