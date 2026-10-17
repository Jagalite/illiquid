import Foundation
import IlliquidCore
import IlliquidPlayback
import IlliquidPlaybackCore
@testable import IlliquidPlayer
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

private enum BenchmarkFailure: Error {
    case invalidArguments(String)
    case missingPrivateModel
    case surfaceIsNotUsed
    case legacyCommandIsNotUsed
}

/// No native decoding, output device, file, or UI participates in this harness.
/// The real driver still issues and settles all effects through its normal API.
@MainActor
private final class SynchronousBenchmarkRuntime: PlaybackRuntime {
    let capabilities: PlaybackCapabilities = [.relativeSeeking, .exactSeeking]
    var eventHandler: (@MainActor @Sendable (PlaybackRuntimeEvent) -> Void)?
    private(set) var executedSeekIDs: Set<UInt64> = []
    private(set) var executedEffectCount = 0
    private(set) var nativeCompletionCount = 0

    func execute(_ request: PlaybackRuntimeEffectRequest) {
        executedEffectCount += 1
        switch request.effect.kind {
        case .seekPipeline, .seek:
            executedSeekIDs.insert(request.effect.context.effectID.rawValue)
        default:
            break
        }
        nativeCompletionCount += 1
        eventHandler?(PlaybackRuntimeEvent(
            identity: nil,
            payload: .effectResult(PlaybackEffectResult(
                context: request.effect.context,
                token: EffectResultToken(kind: .succeeded)
            ))
        ))
    }

    func makeSurfaceHost() throws -> any PlaybackSurfaceHost {
        throw BenchmarkFailure.surfaceIsNotUsed
    }
    func execute(_ command: IlliquidCore.PlaybackCommand) async throws {
        throw BenchmarkFailure.legacyCommandIsNotUsed
    }
    func setVolume(_ value: Double) {}
    func setMuted(_ value: Bool) {}
    func setPlaybackSpeed(_ value: Double) {}
    func selectAudioOutputDevice(_ id: String?) {}
    func setAudioDelay(_ value: TimeInterval) {}
    func setTrackSelectionPreferences(_ preferences: TrackSelectionPreferences) {}
    func setSubtitleFallbackEncoding(_ encoding: SubtitleFallbackEncoding) {}
    func setHardwareDecodingPolicy(_ policy: HardwareDecodingPolicy) {}
    func setVideoScaleMode(_ mode: VideoScaleMode) {}
    func setVideoAspect(_ aspect: String?) {}
    func setVideoCrop(_ crop: String?) {}
    func setVideoRotation(_ rotation: Int) {}
    func setDeinterlace(_ enabled: Bool) {}
    func setVideoEqualizer(_ adjustments: VideoAdjustmentState) {}
    func setPictureInPictureActive(_ active: Bool) {}
    func setVideoColorSamplingEnabled(_ enabled: Bool) {}
    func shutdown() async {}
}

@MainActor
private final class IssuedEffectTrace {
    let retainsContextsForVerification: Bool
    private(set) var seekIDs: Set<UInt64> = []
    private(set) var seekContexts: [UInt64: PlaybackEffectContext] = [:]
    private(set) var transitions = 0
    private(set) var invariantViolationCount = 0

    init(retainsContextsForVerification: Bool) {
        self.retainsContextsForVerification = retainsContextsForVerification
    }

    func observe(_ transition: PlaybackTransition) {
        transitions += 1
        invariantViolationCount += transition.invariantViolations.count
        for effect in transition.effects {
            switch effect.kind {
            case .seekPipeline, .seek:
                let id = effect.context.effectID.rawValue
                seekIDs.insert(id)
                if retainsContextsForVerification {
                    seekContexts[id] = effect.context
                }
            default:
                break
            }
        }
    }
}

private struct LedgerCheckpoint {
    let pending: Int
    let outstanding: Int
    let completed: Int
    let outstandingIDs: Set<UInt64>

    var json: [String: Any] {
        [
            "pending_effects": pending,
            "outstanding_effects": outstanding,
            "completed_effect_ids": completed,
            // A lower bound for live value slots, excluding collection capacity,
            // collection headers, allocator overhead, strings, and Set payloads.
            // This is deliberately not an RSS/heap/footprint measurement.
            "pending_outstanding_value_slot_bytes":
                pending * MemoryLayout<PlaybackEffect>.stride
                + outstanding * (
                    MemoryLayout<PlaybackEffectID>.stride
                    + MemoryLayout<OutstandingEffectRecord>.stride
                ),
            "completed_id_value_slot_bytes": completed * MemoryLayout<PlaybackEffectID>.stride,
        ]
    }
}

private struct Options {
    var burst = 256
    var ticks = 4_096
    var verify = false
    var paused = false

    init(_ arguments: [String]) throws {
        var index = 0
        while index < arguments.count {
            let option = arguments[index]
            if option == "--verify" || option == "--paused" {
                if option == "--verify" { verify = true }
                if option == "--paused" { paused = true }
                index += 1
                continue
            }
            guard index + 1 < arguments.count,
                  let value = Int(arguments[index + 1]), value >= 0
            else {
                throw BenchmarkFailure.invalidArguments(
                    "Expected --burst N --ticks N [--verify] [--paused], with nonnegative integers."
                )
            }
            switch option {
            case "--burst" where value <= 1_000_000:
                burst = value
            case "--ticks" where value <= 10_000_000:
                ticks = value
            default:
                throw BenchmarkFailure.invalidArguments("Unknown argument or excessive count: \(option).")
            }
            index += 2
        }
    }
}

@main
private struct RelativeSeekBenchmark {
    private static let initialPosition = 100.0
    private static let warmupTicks = 256
    private static let taskDrainMilliseconds = 20

    @MainActor
    static func main() async {
        do {
            let options = try Options(Array(CommandLine.arguments.dropFirst()))
            let runtime = SynchronousBenchmarkRuntime()
            let driver = makeDriver(runtime: runtime, playing: !options.paused)
            // Warm only the measured clock path; no seek history exists yet.
            for _ in 0..<warmupTicks { sendClock(driver, seconds: initialPosition) }
            let before = try checkpoint(driver)
            let trace = IssuedEffectTrace(retainsContextsForVerification: options.verify)
            driver.onTransition = { trace.observe($0) }

            var acceptedRelativeCommands = 0
            let burstCPUStart = cpuNanoseconds()
            let burstStart = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<options.burst {
                if driver.seek(to: 1, mode: .relative) { acceptedRelativeCommands += 1 }
            }
            let burstElapsed = DispatchTime.now().uptimeNanoseconds - burstStart
            let burstCPU = cpuNanoseconds() - burstCPUStart

            // Preserve every accepted delta, then settle the latest intent with
            // one absolute seek. This also removes the last deferred dispatch.
            // There is no pacing/sleep or injected clock: the real 40 ms policy
            // can dispatch during the compressed burst as wall time advances.
            let expectedTarget = initialPosition + Double(options.burst)
            let relativeIntentSnapshot = driver.currentSnapshot
            let acceptedRelativeTarget = seconds(relativeIntentSnapshot.position)
            let settlementStart = DispatchTime.now().uptimeNanoseconds
            let absoluteAccepted = options.burst == 0
                || acceptedRelativeTarget.map { driver.seek(to: $0, mode: .exact) } == true
            let settlementElapsed = DispatchTime.now().uptimeNanoseconds - settlementStart
            driver.onTransition = nil

            // Canceled dispatch tasks were queued while the main actor handled
            // the synchronous burst. Allow them to retire outside both timed
            // regions. This wait is not an explicit quiescence barrier.
            let taskDrainStart = DispatchTime.now().uptimeNanoseconds
            try await Task.sleep(for: .milliseconds(taskDrainMilliseconds))
            let taskDrainElapsed = DispatchTime.now().uptimeNanoseconds - taskDrainStart

            let afterBurst = try checkpoint(driver)
            let settledSnapshot = driver.currentSnapshot
            let abandonedIDs = trace.seekIDs.subtracting(runtime.executedSeekIDs)
            let sortedAbandonedIDs = abandonedIDs.sorted()
            let abandonedChecksum = identifierChecksum(sortedAbandonedIDs)
            let settledSemantics = semanticSnapshot(settledSnapshot)
            let settledChecksum = try objectChecksum(settledSemantics)
            let clockBaseSeconds = seconds(settledSnapshot.position) ?? initialPosition

            // checkpoint() returns only independent IDs and scalar counts. Its
            // temporary private-model copy has already died before mutation.
            // No transition observer or reflection participates in this loop.
            let clockCPUStart = cpuNanoseconds()
            let clockStart = DispatchTime.now().uptimeNanoseconds
            for index in 0..<options.ticks {
                sendClock(driver, seconds: clockBaseSeconds + Double(index) * 0.25)
            }
            let clockElapsed = DispatchTime.now().uptimeNanoseconds - clockStart
            let clockCPU = cpuNanoseconds() - clockCPUStart

            let afterClock = try checkpoint(driver)
            let finalSnapshot = driver.currentSnapshot
            let finalSemantics = semanticSnapshot(finalSnapshot)
            let finalChecksum = try objectChecksum(finalSemantics)
            let expectedClockPosition = options.ticks == 0
                ? expectedTarget
                : clockBaseSeconds + Double(options.ticks - 1) * 0.25
            let expectedPhase: PlaybackMachinePhase = options.paused ? .paused : .playing
            let valid = acceptedRelativeCommands == options.burst
                && absoluteAccepted
                && acceptedRelativeTarget == expectedTarget
                && seconds(settledSnapshot.position) == expectedTarget
                && seconds(finalSnapshot.position) == expectedClockPosition
                && relativeIntentSnapshot.lifecycle == .running
                && settledSnapshot.lifecycle == .running && finalSnapshot.lifecycle == .running
                && settledSnapshot.phase == expectedPhase && finalSnapshot.phase == expectedPhase
                && settledSnapshot.failureCode == nil && finalSnapshot.failureCode == nil
                && trace.invariantViolationCount == 0
                && runtime.executedSeekIDs.isSubset(of: trace.seekIDs)
                && before.pending == 0 && before.outstanding == 0
                && afterBurst.pending == afterClock.pending
                && afterBurst.outstanding == afterClock.outstanding
                && afterBurst.completed == afterClock.completed

            var verification: [String: Any]?
            var verificationPassed = true
            if options.verify {
                // Results delivered a second time prove whether the abandoned
                // effect was already retired, without adding a production API.
                var duplicateCallbacks = 0
                var otherDispositions: [String: Int] = [:]
                var replayInvariantViolations = 0
                driver.onTransition = { transition in
                    replayInvariantViolations += transition.invariantViolations.count
                    switch transition.disposition {
                    case .duplicate:
                        duplicateCallbacks += 1
                    default:
                        otherDispositions[String(describing: transition.disposition), default: 0] += 1
                    }
                }
                for id in sortedAbandonedIDs {
                    guard let context = trace.seekContexts[id] else {
                        throw BenchmarkFailure.invalidArguments("Missing verification context.")
                    }
                    driver.receive(PlaybackRuntimeEvent(
                        identity: nil,
                        payload: .effectResult(PlaybackEffectResult(
                            context: context,
                            token: EffectResultToken(kind: .cancelled)
                        ))
                    ))
                }
                driver.onTransition = nil
                let replayChecksum = try objectChecksum(semanticSnapshot(driver.currentSnapshot))
                verificationPassed = valid && afterClock.pending == 0
                    && afterClock.outstanding == 0
                    && duplicateCallbacks == abandonedIDs.count
                    && replayInvariantViolations == 0
                    && replayChecksum == finalChecksum
                verification = [
                    "passed": verificationPassed,
                    "abandoned_callbacks_replayed": sortedAbandonedIDs.count,
                    "duplicate_abandoned_callbacks": duplicateCallbacks,
                    "other_dispositions": otherDispositions,
                    "replay_invariant_violations": replayInvariantViolations,
                    "snapshot_unchanged_after_callback_replay": replayChecksum == finalChecksum,
                ]
            }

            let result: [String: Any] = [
                "schema_version": 1,
                "kind": "relative_seek_coalescing_benchmark",
                "valid_semantics": valid,
                "configuration": [
                    "relative_seek_commands": options.burst,
                    "absolute_settlement_commands": options.burst > 0 ? 1 : 0,
                    "clock_events": options.ticks,
                    "clock_warmup_events": warmupTicks,
                    "clock_sample_spacing_seconds": 0.25,
                    "clock_events_start_seconds": clockBaseSeconds,
                    "untimed_task_drain_milliseconds": taskDrainMilliseconds,
                    "workload": "compressed synchronous commands and clock events; no real-time pacing",
                    "runtime": "synchronous successful effect completion; no native media work",
                    "verification_enabled": options.verify,
                    "transport": options.paused ? "paused" : "playing",
                ],
                "accepted_relative_commands": acceptedRelativeCommands,
                "absolute_settlement_accepted": absoluteAccepted,
                "issued_seek_effects": trace.seekIDs.count,
                "native_seek_dispatches": runtime.executedSeekIDs.count,
                "native_effect_executions": runtime.executedEffectCount,
                "native_effect_completions": runtime.nativeCompletionCount,
                "abandoned_never_dispatched_seek_effects": abandonedIDs.count,
                "abandoned_effect_id_checksum": abandonedChecksum,
                "outstanding_ids_match_abandoned_ids": afterClock.outstandingIDs == abandonedIDs,
                "burst_transition_callbacks": trace.transitions,
                "invariant_violations_during_burst": trace.invariantViolationCount,
                "before_burst": before.json,
                "after_burst": afterBurst.json,
                "after_clock_events": afterClock.json,
                "value_strides": [
                    "playback_effect": MemoryLayout<PlaybackEffect>.stride,
                    "outstanding_effect_record": MemoryLayout<OutstandingEffectRecord>.stride,
                    "effect_id": MemoryLayout<PlaybackEffectID>.stride,
                ],
                "burst_elapsed_ns": burstElapsed,
                "burst_cpu_ns": burstCPU,
                "absolute_settlement_elapsed_ns": settlementElapsed,
                "untimed_task_drain_elapsed_ns": taskDrainElapsed,
                "clock_events_elapsed_ns": clockElapsed,
                "clock_events_cpu_ns": clockCPU,
                "clock_event_mean_ns": options.ticks > 0
                    ? Double(clockElapsed) / Double(options.ticks) : NSNull(),
                "clock_event_mean_cpu_ns": options.ticks > 0
                    ? Double(clockCPU) / Double(options.ticks) : NSNull(),
                "expected_settled_target_seconds": expectedTarget,
                "accepted_relative_target_before_settlement_seconds":
                    acceptedRelativeTarget as Any? ?? NSNull(),
                "relative_intent_snapshot_before_settlement": semanticSnapshot(relativeIntentSnapshot),
                "settled_snapshot": settledSemantics,
                "settled_snapshot_checksum": settledChecksum,
                "final_snapshot": finalSemantics,
                "final_snapshot_checksum": finalChecksum,
                "verification": verification as Any? ?? NSNull(),
            ]
            let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
            print(String(decoding: data, as: UTF8.self))
            if !valid || !verificationPassed { exit(1) }
        } catch {
            FileHandle.standardError.write(Data(("ERROR: \(error)\n").utf8))
            exit(2)
        }
    }

    @MainActor
    private static func makeDriver(
        runtime: SynchronousBenchmarkRuntime, playing: Bool
    ) -> PlaybackRuntimeDriver {
        let position = MediaTimestamp.valid(ValidMediaTime(value: 100_000_000, timescale: 1_000_000)!)
        let duration = MediaTimestamp.valid(ValidMediaTime(value: 1_000_000_000, timescale: 1)!)
        let session = ActivePlaybackSession(
            id: PlaybackSessionID(rawValue: 1),
            source: MediaSourceIdentity(rawValue: "synthetic:relative-seek-benchmark"),
            generation: PlaybackGenerationID(rawValue: 1),
            phase: playing ? .playing : .paused,
            desiredTransport: playing ? .playing : .paused,
            actualTransport: playing ? .playing : .paused,
            logicalPosition: position,
            duration: duration,
            activeOperationID: PlaybackOperationID(rawValue: 1),
            synchronization: SynchronizationMachineState(
                required: [.video, .audio],
                prerolled: [.video, .audio],
                desiredMilliRate: playing ? 1_000 : 0,
                appliedMilliRate: playing ? 1_000 : 0,
                startupAcknowledged: true
            )
        )
        return PlaybackRuntimeDriver(
            runtime: runtime,
            model: PlaybackModelRuntime(
                state: PlaybackCoreState(
                    activeSession: session,
                    allocator: PlaybackIDAllocator(nextSession: 2, nextOperation: 2)
                ),
                recordsReplaySteps: false
            )
        )
    }

    @MainActor
    private static func sendClock(_ driver: PlaybackRuntimeDriver, seconds: Double) {
        driver.receive(PlaybackRuntimeEvent(identity: nil, payload: .positionChanged(seconds)))
    }

    /// Reflection is deliberately confined to one non-inlined checkpoint frame.
    /// Returning a model or its collection storage would force measured COWs.
    @MainActor @inline(never)
    private static func checkpoint(_ driver: PlaybackRuntimeDriver) throws -> LedgerCheckpoint {
        guard let model = Mirror(reflecting: driver).children.first(where: { $0.label == "model" })?.value
            as? PlaybackModelRuntime
        else { throw BenchmarkFailure.missingPrivateModel }
        return LedgerCheckpoint(
            pending: model.pendingEffects.count,
            outstanding: model.core.state.outstandingEffects.count,
            completed: model.core.state.completedEffectIDs.count,
            outstandingIDs: Set(model.core.state.outstandingEffects.keys.map(\.rawValue))
        )
    }

    private static func seconds(_ timestamp: MediaTimestamp) -> Double? {
        guard case let .valid(time) = timestamp else { return nil }
        return Double(time.value) / Double(time.timescale)
    }

    private static func semanticSnapshot(_ snapshot: PlaybackUISnapshot) -> [String: Any] {
        [
            "phase": snapshot.phase.rawValue,
            "lifecycle": snapshot.lifecycle.rawValue,
            "desired_transport": snapshot.desiredTransport.rawValue,
            "actual_transport": snapshot.actualTransport.rawValue,
            "position_seconds": seconds(snapshot.position) as Any? ?? NSNull(),
            "duration_seconds": seconds(snapshot.duration) as Any? ?? NSNull(),
            "failure_code": snapshot.failureCode as Any? ?? NSNull(),
            "buffering": snapshot.isBuffering,
        ]
    }

    private static func cpuNanoseconds() -> UInt64 {
        var value = timespec()
        precondition(clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &value) == 0)
        return UInt64(value.tv_sec) * 1_000_000_000 + UInt64(value.tv_nsec)
    }

    private static func identifierChecksum(_ identifiers: [UInt64]) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for id in identifiers {
            for shift in stride(from: 0, through: 56, by: 8) {
                hash = (hash ^ UInt64(UInt8(truncatingIfNeeded: id >> shift))) &* 1_099_511_628_211
            }
        }
        return String(hash, radix: 16)
    }

    private static func objectChecksum(_ object: [String: Any]) throws -> String {
        let bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in bytes { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
        return String(hash, radix: 16)
    }
}
