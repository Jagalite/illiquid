import Foundation
import IlliquidPlaybackCore
#if os(Linux)
import Glibc
#else
import Darwin
#endif

/// Only the replacement-commit update is timed/probed. Setup, result checks,
/// canonicalization and state destruction are outside the measurement window.
@main
struct EffectRetirementProbe {
    static func main() throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 5,
              ["all", "mixed", "none", "sparse"].contains(arguments[1]),
              let count = Int(arguments[2]), (0...100_000).contains(count),
              let iterations = Int(arguments[3]), (1...100_000).contains(iterations),
              ["timing", "allocations"].contains(arguments[4])
        else {
            throw ProbeError("Usage: EffectRetirementProbe all|mixed|none|sparse COUNT ITERATIONS timing|allocations")
        }
        let scenario = arguments[1]
        let mode = arguments[4]
        let probe = mode == "allocations" ? try AllocationProbe() : nil

        // Warm shared runtime paths with a separate fixture before measurement.
        for _ in 0..<3 {
            var fixture = try makeFixture(scenario: scenario, count: min(count, 8))
            _ = fixture.core.update(fixture.event)
        }
        var elapsed: UInt64 = 0
        var checksum: UInt64 = 0
        var allocationCalls: UInt64 = 0
        var requestedBytes: UInt64 = 0
        for _ in 0..<iterations {
            // The factory returns after releasing its setup runtime/state.
            // No external copy of the outstanding dictionary survives here.
            var fixture = try makeFixture(scenario: scenario, count: count)
            let transition: PlaybackTransition
            if let probe {
                probe.begin()
                transition = fixture.core.update(fixture.event)
                probe.end()
                allocationCalls &+= probe.calls()
                requestedBytes &+= probe.bytes()
            } else {
                let start = DispatchTime.now().uptimeNanoseconds
                transition = fixture.core.update(fixture.event)
                elapsed &+= DispatchTime.now().uptimeNanoseconds - start
            }
            guard transition.disposition == .accepted, transition.invariantViolations.isEmpty else {
                throw ProbeError("Measured replacement failed its transition contract")
            }
            checksum &+= consume(fixture.core, transition: transition)
        }

        // A fresh untimed fixture checks complete semantics, including record
        // values for effects that must survive and exact completed membership.
        let receipt = try qualify(scenario: scenario, count: count)
        guard checksum == receipt.checksum &* UInt64(iterations) else {
            throw ProbeError("Timed checksum does not match the qualified transition")
        }
        let observation = Observation(
            scenario: scenario, count: count, iterations: iterations, mode: mode,
            elapsed_ns: elapsed, checksum: String(checksum),
            semanticFingerprint: receipt.fingerprint,
            alloc_calls: mode == "allocations" ? allocationCalls : nil,
            requested_bytes: mode == "allocations" ? requestedBytes : nil
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        print(String(decoding: try encoder.encode(observation), as: UTF8.self))
    }

    private struct Fixture {
        var core: PlaybackCore
        let event: PlaybackEventEnvelope
        let retiredAuthority: PlaybackAuthority
        let replacementSessionID: PlaybackSessionID
        let firstSeedID: UInt64
    }

    private static func makeFixture(scenario: String, count: Int) throws -> Fixture {
        var runtime = PlaybackModelRuntime(recordsReplaySteps: false)
        let initial = runtime.send(.command(.load(
            source: MediaSourceIdentity(rawValue: "fixture/retirement-A.mkv"), autoplay: false
        )))
        guard initial.disposition == .accepted,
              runtime.completeNext()?.disposition == .accepted,
              runtime.completeNext()?.disposition == .accepted,
              let active = runtime.core.state.activeSession, active.phase == .paused
        else { throw ProbeError("Initial paused-load fixture failed") }
        let replacement = runtime.send(.command(.load(
            source: MediaSourceIdentity(rawValue: "fixture/retirement-B.mkv"), autoplay: false
        )))
        guard replacement.disposition == .accepted,
              let opened = runtime.completeNext(), opened.disposition == .accepted,
              let preroll = opened.effects.first(where: { $0.kind == .awaitPreroll }),
              let pending = runtime.core.state.pendingSession
        else { throw ProbeError("Replacement-preroll fixture failed") }

        var state = runtime.core.state
        let firstSeedID = state.allocator.nextEffect
        for index in 0..<count {
            let matches = scenario == "all" || (scenario == "mixed" && index.isMultiple(of: 2)) || (scenario == "sparse" && index == 0)
            let authority = matches ? active.authority : pending.authority
            guard state.allocator.nextEffect < UInt64.max,
                  state.allocator.nextOperation < UInt64.max
            else { throw ProbeError("Fixture allocator overflow") }
            let id = PlaybackEffectID(rawValue: state.allocator.nextEffect)
            let operationID = PlaybackOperationID(rawValue: state.allocator.nextOperation)
            state.allocator.nextEffect += 1
            state.allocator.nextOperation += 1
            let effect = PlaybackEffect(
                executor: .persistence,
                context: PlaybackEffectContext(
                    authority: authority, operationID: operationID, effectID: id
                ),
                kind: .persistCheckpoint,
                exclusiveKey: "persistence.checkpoint.\(matches ? active.id.rawValue : pending.id.rawValue)"
            )
            state.outstandingEffects[id] = OutstandingEffectRecord(effect: effect)
        }
        guard PlaybackInvariantChecker.check(state: state).isEmpty else {
            throw ProbeError("Seeded fixture violates the production invariants")
        }
        let event = PlaybackEventEnvelope(
            sequence: runtime.nextSequence,
            virtualTime: PlaybackInstant(ticks: runtime.virtualTime.ticks + 1),
            event: .effectResult(PlaybackEffectResult(
                context: preroll.context, token: EffectResultToken(kind: .succeeded)
            ))
        )
        return Fixture(
            core: PlaybackCore(state: state), event: event,
            retiredAuthority: active.authority, replacementSessionID: pending.id,
            firstSeedID: firstSeedID
        )
    }

    @inline(never)
    private static func consume(_ core: borrowing PlaybackCore, transition: PlaybackTransition) -> UInt64 {
        UInt64(core.state.outstandingEffects.count)
            &+ core.state.snapshotRevision
            &+ core.state.acceptedEventCount
            &+ core.state.rejectedEventCount
            &+ (core.state.activeSession?.id.rawValue ?? 0)
            &+ UInt64(transition.effects.count)
    }

    private static func qualify(scenario: String, count: Int) throws -> (checksum: UInt64, fingerprint: String) {
        var fixture = try makeFixture(scenario: scenario, count: count)
        let before = fixture.core.state
        guard case let .effectResult(result) = fixture.event.event else {
            throw ProbeError("Fixture event is not a preroll completion")
        }
        let prerollID = result.context.effectID
        var expectedCompleted = before.completedEffectIDs
        expectedCompleted.insert(prerollID)
        var expectedOutstanding = before.outstandingEffects
        expectedOutstanding.removeValue(forKey: prerollID)
        for index in 0..<count {
            let id = PlaybackEffectID(rawValue: fixture.firstSeedID + UInt64(index))
            if scenario == "all" || (scenario == "mixed" && index.isMultiple(of: 2)) || (scenario == "sparse" && index == 0) {
                expectedCompleted.insert(id)
                expectedOutstanding.removeValue(forKey: id)
            }
        }
        let transition = fixture.core.update(fixture.event)
        let after = fixture.core.state
        guard transition.disposition == .accepted,
              transition.effects.isEmpty,
              transition.invariantViolations.isEmpty,
              after.outstandingEffects == expectedOutstanding,
              after.completedEffectIDs == expectedCompleted,
              after.pendingSession == nil,
              after.activeSession?.id == fixture.replacementSessionID,
              after.activeSession?.source == MediaSourceIdentity(rawValue: "fixture/retirement-B.mkv"),
              after.activeSession?.phase == .paused,
              after.activeSession?.actualTransport == .paused,
              after.lifecycle == .running,
              after.allocator == before.allocator,
              after.acceptedEventCount == before.acceptedEventCount + 1,
              after.rejectedEventCount == before.rejectedEventCount,
              after.snapshotRevision == before.snapshotRevision + 1
        else { throw ProbeError("Retirement changed an unrelated record or transition field") }
        let encoded = try JSONEncoder().encode(after)
        guard try JSONDecoder().decode(PlaybackCoreState.self, from: encoded) == after else {
            throw ProbeError("Retired state does not survive its Codable round trip")
        }
        let canonical = PlaybackCanonicalState(state: after)
        // Ensure encoding succeeds before using the production digest helper,
        // which itself has a fallback for an encoding error.
        _ = try JSONEncoder().encode(canonical)
        return (
            consume(fixture.core, transition: transition),
            PlaybackReplayCodec.digest(canonical) + "|pending:nil|roundtrip:equal"
        )
    }

    private struct AllocationProbe {
        let begin: @convention(c) () -> Void
        let end: @convention(c) () -> Void
        let calls: @convention(c) () -> UInt64
        let bytes: @convention(c) () -> UInt64

        init() throws {
            #if os(Linux)
            guard let handle = dlopen(nil, RTLD_NOW),
                  let beginAddress = dlsym(handle, "illiquid_effect_probe_begin"),
                  let endAddress = dlsym(handle, "illiquid_effect_probe_end"),
                  let callsAddress = dlsym(handle, "illiquid_effect_probe_calls"),
                  let bytesAddress = dlsym(handle, "illiquid_effect_probe_bytes")
            else { throw ProbeError("Allocation mode requires the probe in LD_PRELOAD") }
            begin = unsafeBitCast(beginAddress, to: (@convention(c) () -> Void).self)
            end = unsafeBitCast(endAddress, to: (@convention(c) () -> Void).self)
            calls = unsafeBitCast(callsAddress, to: (@convention(c) () -> UInt64).self)
            bytes = unsafeBitCast(bytesAddress, to: (@convention(c) () -> UInt64).self)
            #else
            throw ProbeError("The allocation-request probe is Linux/glibc only")
            #endif
        }
    }

    private struct Observation: Encodable {
        let scenario: String
        let count: Int
        let iterations: Int
        let mode: String
        let elapsed_ns: UInt64
        let checksum: String
        let semanticFingerprint: String
        let alloc_calls: UInt64?
        let requested_bytes: UInt64?
    }

    private struct ProbeError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
