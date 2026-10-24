import CEffectHistoryHeap
import Dispatch
import Foundation
import IlliquidPlaybackCore

// Only the public production core/runtime API is used here. In particular, the
// measured path never reads completedEffectIDs or creates canonical snapshots:
// either would materialize the history and obscure its retained representation.
private enum Scenario: String, Codable {
  case transport
  case replacement
  case checkpointBurst
  case unclosedGap
}

private struct Work: Codable, Equatable {
  var commands = 0
  var completions = 0
  var accepted = 0
  var duplicates = 0
  var stale = 0
  var invalid = 0
  var ignored = 0
  var invariant_violations = 0
  var effect_id_checksum: UInt64 = 0

  mutating func observe(_ transition: PlaybackTransition) {
    invariant_violations += transition.invariantViolations.count
    precondition(transition.invariantViolations.isEmpty)
    switch transition.disposition {
    case .accepted: accepted += 1
    case .duplicate: duplicates += 1
    case .stale: stale += 1
    case .invalid: invalid += 1
    case .ignoredAfterTermination: ignored += 1
    }
  }

  mutating func completed(_ id: PlaybackEffectID) {
    completions += 1
    effect_id_checksum = (effect_id_checksum &* 16_777_619) ^ id.rawValue
  }
}

private final class Fixture {
  var runtime: PlaybackModelRuntime
  var work = Work()
  let startingEffectID: UInt64

  init(startingEffectID: UInt64 = 1) {
    self.startingEffectID = startingEffectID
    runtime = PlaybackModelRuntime(
      state: PlaybackCoreState(allocator: PlaybackIDAllocator(nextEffect: startingEffectID)),
      recordsReplaySteps: false
    )
    command(.load(source: MediaSourceIdentity(rawValue: "fixture/initial.mkv"), autoplay: false))
    settle()
    precondition(runtime.core.state.activeSession?.phase == .paused)
    precondition(work.completions == 2)
  }

  @inline(never)
  func command(_ command: PlaybackCommand) {
    work.commands += 1
    let transition = runtime.send(.command(command))
    work.observe(transition)
    precondition(transition.disposition == .accepted)
  }

  @inline(never)
  func settle() {
    var count = 0
    while let effect = runtime.pendingEffects.first {
      count += 1
      precondition(count <= 32, "Workload failed to settle")
      guard let transition = runtime.complete(effectID: effect.context.effectID) else {
        preconditionFailure("A pending effect disappeared before completion")
      }
      work.completed(effect.context.effectID)
      work.observe(transition)
      precondition(transition.disposition == .accepted)
    }
    precondition(runtime.core.state.outstandingEffects.isEmpty)
  }

  @inline(never)
  func settleReverseBatch() {
    precondition(runtime.pendingEffects.count <= 32)
    while let effect = runtime.pendingEffects.last {
      guard let transition = runtime.complete(effectID: effect.context.effectID) else {
        preconditionFailure("A pending checkpoint disappeared before completion")
      }
      work.completed(effect.context.effectID)
      work.observe(transition)
      precondition(transition.disposition == .accepted)
    }
    precondition(runtime.core.state.outstandingEffects.isEmpty)
  }

  @inline(never)
  func exercise(_ scenario: Scenario, cycles: Int) {
    for index in 0..<cycles {
      switch scenario {
      case .transport, .unclosedGap:
        command(.play)
        settle()
        command(.pause)
        settle()
      case .replacement:
        // Alternate two sources, but let the production allocator create each
        // new session/operation/effect identity and commit its preroll normally.
        let source = index.isMultiple(of: 2) ? "fixture/a.mkv" : "fixture/b.mkv"
        command(.load(source: MediaSourceIdentity(rawValue: source), autoplay: false))
        settle()
      case .checkpointBurst:
        // Keep real checkpoint effects outstanding in batches, then complete
        // newest first. The oldest missing ID prevents prefix advancement until
        // the batch finishes, exercising temporary sparse-history storage.
        command(.checkpoint)
        if (index + 1).isMultiple(of: 32) || index + 1 == cycles {
          settleReverseBatch()
        }
      }
    }
    precondition(runtime.steps.isEmpty)
    precondition(runtime.core.state.activeSession?.phase == .paused)
    precondition(runtime.core.state.pendingSession == nil)
    let completionsPerCycle = scenario == .checkpointBurst ? 1 : 2
    precondition(work.completions == 2 + cycles * completionsPerCycle)
    precondition(work.accepted == work.commands + work.completions)
    precondition(runtime.core.state.allocator.nextEffect == startingEffectID + UInt64(work.completions))
  }
}

private struct Checks: Codable, Equatable {
  let scenario: String
  let cycles: Int
  let starting_effect_id: UInt64
  let work: Work
  let completed_count: Int
  let first_completed_id: UInt64?
  let last_completed_id: UInt64?
  let next_effect_id: UInt64
  let outstanding_count: Int
  let pending_count: Int
  let recorded_step_count: Int
  let state_digest: String
  let roundtrip_state_digest: String
  let codable_state_equal: Bool
}

// Diagnostic work is deliberately separate from the measured fixture, and is
// invoked only after every allocator sample (including fixture release).
@inline(never)
private func semanticChecks(_ scenario: Scenario, cycles: Int, expected: Work?) throws -> Checks {
  let fixture = Fixture(startingEffectID: scenario == .unclosedGap ? 2 : 1)
  fixture.exercise(scenario, cycles: cycles)
  if let expected { precondition(fixture.work == expected) }
  let state = fixture.runtime.core.state
  let ids = state.completedEffectIDs.sorted()
  precondition(ids.count == fixture.work.completions)
  precondition(ids.enumerated().allSatisfy { index, id in
    id.rawValue == fixture.startingEffectID + UInt64(index)
  })
  let canonical = PlaybackCanonicalState(state: state)
  precondition(canonical.completedEffectIDs == ids)
  let decoded = try JSONDecoder().decode(PlaybackCoreState.self, from: JSONEncoder().encode(state))
  precondition(decoded == state)
  let digest = PlaybackReplayCodec.digest(canonical)
  let roundtripDigest = PlaybackReplayCodec.digest(PlaybackCanonicalState(state: decoded))
  precondition(digest == roundtripDigest)
  return Checks(
    scenario: scenario.rawValue, cycles: cycles, starting_effect_id: fixture.startingEffectID,
    work: fixture.work,
    completed_count: ids.count, first_completed_id: ids.first?.rawValue,
    last_completed_id: ids.last?.rawValue, next_effect_id: state.allocator.nextEffect,
    outstanding_count: state.outstandingEffects.count,
    pending_count: fixture.runtime.pendingEffects.count,
    recorded_step_count: fixture.runtime.steps.count,
    state_digest: digest, roundtrip_state_digest: roundtripDigest, codable_state_equal: true
  )
}

private struct Measurement: Encodable {
  let schema = 1
  let mode = "measure"
  let allocator_metric: String
  let allocator_before_fixture_bytes: UInt64
  let allocator_after_commands_bytes: UInt64
  let allocator_after_release_bytes: UInt64
  let retained_allocator_delta_bytes: Int64
  let released_allocator_delta_bytes: Int64
  let loop_wall_nanoseconds: UInt64
  let loop_cpu_nanoseconds: UInt64
  let checks: Checks
}

@inline(never)
private func warmUp(_ scenario: Scenario) throws {
  // Warm the runtime, invariants, allocator probe and diagnostic encoders using
  // a separate small fixture. Startup/framework loading is outside all timings.
  let warm = try semanticChecks(scenario, cycles: 8, expected: nil)
  _ = try JSONEncoder().encode(warm)
  _ = effect_history_heap_bytes()
  _ = effect_history_cpu_nanoseconds()
  _ = DispatchTime.now().uptimeNanoseconds
}

@inline(never)
private func measure(_ scenario: Scenario, cycles: Int) throws -> Measurement {
  try warmUp(scenario)
  let metric = String(cString: effect_history_heap_metric())
  precondition(metric != "unsupported", "Retained allocator metric unavailable")
  let before = effect_history_heap_bytes()
  // The unclosed-gap control starts at ID 2 without ever issuing ID 1. This is
  // legal state but deliberately prevents a completed prefix from forming.
  var fixture: Fixture? = Fixture(startingEffectID: scenario == .unclosedGap ? 2 : 1)
  let wallStart = DispatchTime.now().uptimeNanoseconds
  let cpuStart = effect_history_cpu_nanoseconds()
  fixture!.exercise(scenario, cycles: cycles)
  let cpu = effect_history_cpu_nanoseconds() - cpuStart
  let wall = DispatchTime.now().uptimeNanoseconds - wallStart
  let retained = withExtendedLifetime(fixture) { effect_history_heap_bytes() }
  // Work contains only scalar values. It cannot keep core history alive.
  let work = fixture!.work
  fixture = nil
  let released = effect_history_heap_bytes()
  // Canonicalization, Set access, Codable round trips and the second fixture
  // happen after the measured fixture and every memory sample are finished.
  let checks = try semanticChecks(scenario, cycles: cycles, expected: work)
  return Measurement(
    allocator_metric: metric, allocator_before_fixture_bytes: before,
    allocator_after_commands_bytes: retained, allocator_after_release_bytes: released,
    retained_allocator_delta_bytes: Int64(retained) - Int64(before),
    released_allocator_delta_bytes: Int64(released) - Int64(before),
    loop_wall_nanoseconds: wall, loop_cpu_nanoseconds: cpu, checks: checks
  )
}

private struct SetMutationReceipt: Encodable {
  let snapshots: [[UInt64]]
  let original_ids: [UInt64]
  let original_value_preserved: Bool
  let roundtrip_state_equal: Bool
  let wire_history_is_array: Bool
  let state_digest: String
  let roundtrip_state_digest: String
}

private struct VerificationChecks: Encodable {
  let replay: PlaybackReplayDocument
  let replay_roundtrip_equal: Bool
  let out_of_order_completions: [UInt64]
  let work: Work
  let public_set_mutation: SetMutationReceipt
}

private struct Verification: Encodable {
  let schema = 1
  let mode = "verify"
  let checks: VerificationChecks
}

private func verify() throws -> Verification {
  var runtime = PlaybackModelRuntime()
  var work = Work()
  func send(_ event: PlaybackEvent) -> PlaybackTransition {
    let transition = runtime.send(event)
    if case .command = event { work.commands += 1 }
    work.observe(transition)
    return transition
  }
  func complete(_ effect: PlaybackEffect) -> PlaybackTransition {
    guard let transition = runtime.complete(effectID: effect.context.effectID) else {
      preconditionFailure("Missing expected effect")
    }
    work.completed(effect.context.effectID)
    work.observe(transition)
    return transition
  }
  func settle() {
    var count = 0
    while let effect = runtime.pendingEffects.first {
      count += 1
      precondition(count <= 32)
      precondition(complete(effect).disposition == .accepted)
    }
  }
  func result(_ effect: PlaybackEffect) -> PlaybackEvent {
    .effectResult(PlaybackEffectResult(context: effect.context, token: EffectResultToken(kind: .succeeded)))
  }

  precondition(send(.command(.load(source: MediaSourceIdentity(rawValue: "fixture/verify.mkv"), autoplay: false))).disposition == .accepted)
  let firstOpen = runtime.pendingEffects[0]
  settle()
  precondition(send(.command(.play)).disposition == .accepted)
  let rate = runtime.pendingEffects[0]
  precondition(send(.command(.checkpoint)).disposition == .accepted)
  let checkpoint = runtime.pendingEffects.last!
  precondition(checkpoint.context.effectID > rate.context.effectID)
  precondition(complete(checkpoint).disposition == .accepted)
  precondition(complete(rate).disposition == .accepted)
  precondition(send(result(checkpoint)).disposition == .duplicate(effectID: checkpoint.context.effectID))
  precondition(send(result(firstOpen)).disposition == .duplicate(effectID: firstOpen.context.effectID))

  // A mismatched context must leave the genuine pending completion available.
  precondition(send(.command(.pause)).disposition == .accepted)
  let pause = runtime.pendingEffects[0]
  let mismatched = PlaybackEffectContext(
    authority: pause.context.authority,
    operationID: PlaybackOperationID(rawValue: pause.context.operationID.rawValue + 100),
    effectID: pause.context.effectID
  )
  precondition(send(.effectResult(PlaybackEffectResult(context: mismatched, token: EffectResultToken(kind: .succeeded)))).disposition == .stale(reason: .operationMismatch))
  precondition(complete(pause).disposition == .accepted)

  let unknown = PlaybackEffectContext(
    authority: pause.context.authority, operationID: pause.context.operationID,
    effectID: PlaybackEffectID(rawValue: UInt64.max - 1)
  )
  precondition(send(.effectResult(PlaybackEffectResult(context: unknown, token: EffectResultToken(kind: .succeeded)))).disposition == .stale(reason: .unknownEffect))

  // Completing an old generation retires its ID but cannot resume playback.
  precondition(send(.command(.play)).disposition == .accepted)
  let oldRate = runtime.pendingEffects[0]
  let target = ValidMediaTime(value: 42_000, timescale: 1_000)!
  precondition(send(.command(.seek(target: .valid(target), mode: .exact))).disposition == .accepted)
  precondition(complete(oldRate).disposition == .stale(reason: .generationMismatch))
  precondition(send(result(oldRate)).disposition == .duplicate(effectID: oldRate.context.effectID))
  settle()

  // Replacing an unfinished candidate retires its outstanding ID; later results
  // retain the established duplicate classification after session supersession.
  precondition(send(.command(.load(source: MediaSourceIdentity(rawValue: "fixture/superseded.mkv"), autoplay: false))).disposition == .accepted)
  let superseded = runtime.pendingEffects[0]
  precondition(send(.command(.load(source: MediaSourceIdentity(rawValue: "fixture/replacement.mkv"), autoplay: false))).disposition == .accepted)
  precondition(send(result(superseded)).disposition == .duplicate(effectID: superseded.context.effectID))
  settle()
  precondition(runtime.pendingEffects.isEmpty)
  precondition(runtime.core.state.outstandingEffects.isEmpty)
  precondition(work.duplicates == 4 && work.stale == 3)
  precondition(work.invalid == 0 && work.invariant_violations == 0)

  let replay = runtime.replayDocument(illiquidRevision: "component-comparison", seed: 20261023)
  let decodedReplay = try PlaybackReplayCodec.decode(PlaybackReplayCodec.encode(replay))
  precondition(decodedReplay == replay)

  let original = runtime.core.state
  let originalIDs = original.completedEffectIDs.sorted().map(\.rawValue)
  var edited = original
  var expected = original.completedEffectIDs
  var snapshots: [[UInt64]] = []
  func recordSet() {
    precondition(edited.completedEffectIDs == expected)
    precondition(original.completedEffectIDs.sorted().map(\.rawValue) == originalIDs)
    snapshots.append(edited.completedEffectIDs.sorted().map(\.rawValue))
  }
  let extremeIDs: Set<PlaybackEffectID> = [
    PlaybackEffectID(rawValue: 0), PlaybackEffectID(rawValue: UInt64.max),
    PlaybackEffectID(rawValue: UInt64.max - 1), PlaybackEffectID(rawValue: 100),
    PlaybackEffectID(rawValue: 102),
  ]
  edited.completedEffectIDs.formUnion(extremeIDs)
  expected.formUnion(extremeIDs)
  recordSet()
  let removed = PlaybackEffectID(rawValue: 4)
  precondition(edited.completedEffectIDs.remove(removed) == expected.remove(removed))
  recordSet()
  let bridge = PlaybackEffectID(rawValue: 101)
  precondition(edited.completedEffectIDs.insert(bridge).inserted == expected.insert(bridge).inserted)
  recordSet()
  edited.completedEffectIDs.subtract([PlaybackEffectID(rawValue: UInt64.max - 1), PlaybackEffectID(rawValue: 0)])
  expected.subtract([PlaybackEffectID(rawValue: UInt64.max - 1), PlaybackEffectID(rawValue: 0)])
  recordSet()
  let encoded = try JSONEncoder().encode(edited)
  let roundtrip = try JSONDecoder().decode(PlaybackCoreState.self, from: encoded)
  precondition(roundtrip == edited)
  let wire = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
  precondition(wire["completedEffectIDs"] is [Any])
  let stateDigest = PlaybackReplayCodec.digest(PlaybackCanonicalState(state: edited))
  let roundtripDigest = PlaybackReplayCodec.digest(PlaybackCanonicalState(state: roundtrip))
  precondition(stateDigest == roundtripDigest)
  let mutation = SetMutationReceipt(
    snapshots: snapshots, original_ids: originalIDs, original_value_preserved: true,
    roundtrip_state_equal: true, wire_history_is_array: true,
    state_digest: stateDigest, roundtrip_state_digest: roundtripDigest
  )
  return Verification(checks: VerificationChecks(
    replay: replay, replay_roundtrip_equal: true,
    out_of_order_completions: [checkpoint.context.effectID.rawValue, rate.context.effectID.rawValue],
    work: work, public_set_mutation: mutation
  ))
}

@main
private struct CompletedEffectHistoryHarness {
  static func main() throws {
    var mode = "measure"
    var scenario = Scenario.transport
    var cycles = 4_096
    let arguments = Array(CommandLine.arguments.dropFirst())
    precondition(arguments.count.isMultiple(of: 2), "Options require values")
    for index in stride(from: 0, to: arguments.count, by: 2) {
      let value = arguments[index + 1]
      switch arguments[index] {
      case "--mode": mode = value
      case "--scenario":
        guard let parsed = Scenario(rawValue: value) else { preconditionFailure("Unknown scenario") }
        scenario = parsed
      case "--cycles":
        guard let parsed = Int(value), (0...1_000_000).contains(parsed) else {
          preconditionFailure("cycles must be an integer from 0 through 1000000")
        }
        cycles = parsed
      default: preconditionFailure("Unknown option: \(arguments[index])")
      }
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data: Data
    switch mode {
    case "measure": data = try encoder.encode(measure(scenario, cycles: cycles))
    case "verify": data = try encoder.encode(verify())
    default: preconditionFailure("mode must be measure or verify")
    }
    print(String(decoding: data, as: UTF8.self))
  }
}
