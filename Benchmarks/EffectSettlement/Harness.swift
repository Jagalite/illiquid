import CEffectSettlementProbe
import Dispatch
import Foundation
import IlliquidPlaybackCore

private struct CaseSpec: Codable, Sendable {
    let id: String
    let scenario: String
    let population: Int
    let matching: String
    let ownership: String

    var batchSize: Int { min(256, max(8, 8_192 / max(1, population + 1))) }
    func matches(_ index: Int) -> Bool {
        switch matching {
        case "all": return true
        case "mixed": return index.isMultiple(of: 2)
        case "allButOne": return index != population - 1
        case "one": return index == 0
        default: return false
        }
    }
}

private func cases() -> [CaseSpec] {
    var result: [CaseSpec] = []
    func add(_ scenario: String, _ n: Int, _ matching: String, _ ownership: String = "unique") {
        result.append(CaseSpec(id: "\(scenario)-\(n)-\(matching)-\(ownership)",
            scenario: scenario, population: n, matching: matching, ownership: ownership))
    }
    for scenario in ["load", "stop", "cleanup"] {
        for n in [0, 1, 4, 8, 32, 128, 512] { add(scenario, n, "all") }
        for n in [2, 4] { add(scenario, n, "mixed") }
        for n in [8, 128] {
            add(scenario, n, "mixed")
            add(scenario, n, "none")
        }
    }
    for n in [8, 128] { add("load", n, "allButOne") }
    add("load", 128, "one")
    for n in [0, 8, 128] { add("control", n, "all") }
    for n in [8, 128] { add("load", n, "all", "snapshot") }
    return result
}

private func session(_ id: UInt64, phase: PlaybackMachinePhase) -> ActivePlaybackSession {
    ActivePlaybackSession(id: .init(rawValue: id),
        source: .init(rawValue: "benchmark/session-\(id).mkv"),
        generation: .init(rawValue: 4), phase: phase,
        desiredTransport: .paused, actualTransport: phase == .paused ? .paused : .stopped,
        activeOperationID: .init(rawValue: 8))
}

private func foreignAuthority(_ index: Int) -> PlaybackAuthority {
    switch index % 4 {
    case 0:
        return .application(.init(rawValue: 1))
    case 1:
        return .playback(sessionID: .init(rawValue: 10), generation: .init(rawValue: 5),
            revisions: PlaybackRevisionSet())
    case 2:
        var revisions = PlaybackRevisionSet()
        revisions.subtitle = .init(rawValue: 2)
        return .playback(sessionID: .init(rawValue: 10), generation: .init(rawValue: 4),
            revisions: revisions)
    default:
        return .playback(sessionID: .init(rawValue: 30), generation: .init(rawValue: 4),
            revisions: PlaybackRevisionSet())
    }
}

private final class Fixture {
    var core: PlaybackCore
    let event: PlaybackEventEnvelope
    let retainedSnapshot: PlaybackCoreState?
    let matchingIDs: Set<PlaybackEffectID>
    let originalIDs: Set<PlaybackEffectID>

    init(_ spec: CaseSpec, reverse: Bool = false) {
        let target = session(10, phase: .opening)
        var records: [PlaybackEffectID: OutstandingEffectRecord] = [:]
        var selected: Set<PlaybackEffectID> = []
        let indices = reverse ? Array((0..<spec.population).reversed()) : Array(0..<spec.population)
        for index in indices {
            let id = PlaybackEffectID(rawValue: UInt64(index + 1))
            let matches = spec.matches(index)
            let authority = matches ? target.authority : foreignAuthority(index)
            if matches { selected.insert(id) }
            let effect = PlaybackEffect(executor: .persistence,
                context: .init(authority: authority, operationID: .init(rawValue: 8),
                    effectID: id), kind: .persistCheckpoint,
                exclusiveKey: "benchmark.checkpoint.\(id.rawValue)")
            records[id] = OutstandingEffectRecord(effect: effect)
        }
        let command: PlaybackEvent
        if spec.scenario == "cleanup" {
            let id = PlaybackEffectID(rawValue: UInt64(spec.population + 1))
            let effect = PlaybackEffect(executor: .resource,
                context: .init(authority: target.authority, operationID: .init(rawValue: 8),
                    effectID: id), kind: .cancelSession, isCleanup: true)
            records[id] = OutstandingEffectRecord(effect: effect)
            selected.insert(id)
            command = .effectResult(.init(context: effect.context, token: .init(kind: .succeeded)))
        } else if spec.scenario == "load" {
            command = .command(.load(source: .init(rawValue: "benchmark/replacement.mkv"), autoplay: false))
        } else if spec.scenario == "stop" {
            command = .command(.stop)
        } else {
            command = .diagnosticObserved(code: "benchmark.noSettlement")
            selected.removeAll()
        }
        let initial = PlaybackCoreState(activeSession: session(20, phase: .paused),
            pendingSession: ["load", "stop"].contains(spec.scenario) ? target : nil,
            outstandingEffects: records,
            allocator: PlaybackIDAllocator(nextSession: 100, nextOperation: 100,
                nextEffect: UInt64(spec.population + 2)))
        core = PlaybackCore(state: initial)
        retainedSnapshot = spec.ownership == "snapshot" ? initial : nil
        matchingIDs = selected
        originalIDs = Set(records.keys)
        event = PlaybackEventEnvelope(sequence: 1, virtualTime: .init(ticks: 1), event: command)
    }

    func validate(_ transition: PlaybackTransition, spec: CaseSpec) {
        precondition(transition.disposition == .accepted)
        precondition(transition.invariantViolations.isEmpty)
        precondition(core.state.lifecycle == .running)
        let emitted = Set(transition.effects.map { $0.context.effectID })
        precondition(Set(core.state.outstandingEffects.keys) == originalIDs.subtracting(matchingIDs).union(emitted))
        precondition(core.state.completedEffectIDs == matchingIDs)
        if let retainedSnapshot {
            precondition(Set(retainedSnapshot.outstandingEffects.keys) == originalIDs)
            precondition(retainedSnapshot.completedEffectIDs.isEmpty)
        }
        switch spec.scenario {
        case "load":
            precondition(core.state.activeSession?.id.rawValue == 20)
            precondition(core.state.pendingSession?.id.rawValue == 100)
            precondition(transition.effects.count == 1)
            if case .openSource = transition.effects[0].kind {} else { preconditionFailure() }
        case "stop":
            precondition(core.state.pendingSession == nil)
            precondition(core.state.activeSession?.id.rawValue == 20)
            precondition(core.state.activeSession?.generation.rawValue == 5)
            precondition(core.state.activeSession?.phase == .stopping)
            precondition(transition.effects.count == 1 && transition.effects[0].kind == .cancelSession)
        default:
            precondition(core.state.activeSession?.id.rawValue == 20)
            precondition(core.state.activeSession?.generation.rawValue == 4)
            precondition(transition.effects.isEmpty)
        }
    }
}

// PlaybackCanonicalState deliberately omits these four stored state fields.
// Include them explicitly so verification covers the complete production state.
private struct FullState: Codable {
    let canonical: PlaybackCanonicalState
    let pendingSession: ActivePlaybackSession?
    let lastLoadFailure: PlaybackFailure?
    let loopRange: PlaybackLoopRange?
    let preferredPlaybackMilliRate: Int32?
    init(_ state: PlaybackCoreState) {
        canonical = PlaybackCanonicalState(state: state)
        pendingSession = state.pendingSession?.value
        lastLoadFailure = state.lastLoadFailure
        loopRange = state.loopRange
        preferredPlaybackMilliRate = state.preferredPlaybackMilliRate
    }
}

private struct Trace: Codable {
    let spec: CaseSpec
    let insertionOrder: String
    let initial: FullState
    let final: FullState
    let snapshot: PlaybackUISnapshot
    let disposition: EventDisposition
    let effects: [CanonicalPlaybackEffect]
    let invariants: [PlaybackInvariantViolation]
}

private func verify() -> [Trace] {
    cases().flatMap { spec in
        [false, true].map { reverse in
            let fixture = Fixture(spec, reverse: reverse)
            let before = FullState(fixture.core.state)
            let result = fixture.core.update(fixture.event)
            fixture.validate(result, spec: spec)
            return Trace(spec: spec, insertionOrder: reverse ? "descending" : "ascending",
                initial: before, final: FullState(fixture.core.state),
                snapshot: result.snapshot, disposition: result.disposition,
                effects: result.effects.map(CanonicalPlaybackEffect.init),
                invariants: result.invariantViolations)
        }
    }
}

private struct Observation: Codable {
    let mode: String
    let spec: CaseSpec
    let batches: Int
    let batchSize: Int
    let operations: Int
    let wallNanoseconds: UInt64
    let cpuNanoseconds: UInt64
    let allocationMeterSelfCheck: Bool?
    let allocationRequests: UInt64?
    let requestedBytes: UInt64?
    let checksum: UInt64
    let checksumPerOperation: UInt64
}

// Each instance has its own dictionary; there is no shared seed-state CoW.
// The snapshot cases deliberately retain a second value to measure that separate
// ownership situation. Fixture construction and destruction are outside windows.
@inline(never)
private func measure(_ spec: CaseSpec, batches: Int, allocation: Bool) -> Observation {
    precondition(batches > 0)
    if allocation {
        precondition(settlement_meter_available() != 0, "Allocation interposer missing")
        precondition(settlement_meter_self_check() != 0, "Known allocation was not intercepted")
    }
    for _ in 0..<8 {
        let warm = Fixture(spec)
        let result = warm.core.update(warm.event)
        warm.validate(result, spec: spec)
    }
    _ = settlement_cpu_nanoseconds()
    _ = DispatchTime.now().uptimeNanoseconds
    var wall: UInt64 = 0, cpu: UInt64 = 0, requests: UInt64 = 0, bytes: UInt64 = 0, checksum: UInt64 = 0
    for _ in 0..<batches {
        let fixtures = (0..<spec.batchSize).map { _ in Fixture(spec) }
        let cpuStart = settlement_cpu_nanoseconds()
        let wallStart = DispatchTime.now().uptimeNanoseconds
        if allocation { settlement_meter_begin() }
        for fixture in fixtures {
            let result = fixture.core.update(fixture.event)
            precondition(result.disposition == .accepted && result.invariantViolations.isEmpty)
            checksum &+= fixture.core.state.allocator.nextEffect
                &+ UInt64(fixture.core.state.outstandingEffects.count)
                &+ result.snapshot.revision &+ UInt64(result.effects.count)
        }
        if allocation { settlement_meter_end() }
        wall += DispatchTime.now().uptimeNanoseconds - wallStart
        cpu += settlement_cpu_nanoseconds() - cpuStart
        if allocation {
            requests += settlement_meter_requests()
            bytes += settlement_meter_bytes()
        }
        // Check exact completion membership outside the measured window.
        // Full state/effect expectations are checked by verify() and warmup.
        precondition(fixtures[0].core.state.completedEffectIDs == fixtures[0].matchingIDs)
        withExtendedLifetime(fixtures) {}
    }
    let operations = batches * spec.batchSize
    precondition(checksum % UInt64(operations) == 0)
    return Observation(mode: allocation ? "allocations" : "timing", spec: spec,
        batches: batches, batchSize: spec.batchSize, operations: operations,
        wallNanoseconds: wall, cpuNanoseconds: cpu,
        allocationMeterSelfCheck: allocation ? true : nil,
        allocationRequests: allocation ? requests : nil, requestedBytes: allocation ? bytes : nil,
        checksum: checksum, checksumPerOperation: checksum / UInt64(operations))
}

@main
private struct Main {
    static func main() throws {
        var options: [String: String] = [:]
        let arguments = Array(CommandLine.arguments.dropFirst())
        precondition(arguments.count.isMultiple(of: 2), "Expected --option value pairs")
        for index in stride(from: 0, to: arguments.count, by: 2) {
            options[arguments[index]] = arguments[index + 1]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let output: Data
        switch options["--mode"] ?? "verify" {
        case "cases": output = try encoder.encode(cases())
        case "verify": output = try encoder.encode(verify())
        case "timing", "allocations":
            guard let spec = cases().first(where: { $0.id == options["--case"] }),
                  let batches = Int(options["--batches"] ?? "1") else { preconditionFailure("Unknown case") }
            output = try encoder.encode(measure(spec, batches: batches,
                allocation: options["--mode"] == "allocations"))
        default: preconditionFailure("Unknown mode")
        }
        FileHandle.standardOutput.write(output)
        FileHandle.standardOutput.write(Data([10]))
    }
}
