import CCompletionHeap
import Foundation
import IlliquidPlaybackCore

private enum Scenario: String, Codable, CaseIterable {
  case defaultEffects, customEffects, pendingCheckpoints, checkpointChurn
  var usesCore: Bool { self == .pendingCheckpoints || self == .checkpointChurn }
}

private struct Work: Codable, Equatable {
  var issued = 0
  var completed = 0
  var effectIDChecksum: UInt64 = 0

  mutating func recordIssued(_ effect: PlaybackEffect) {
    issued += 1
    effectIDChecksum = (effectIDChecksum &* 16_777_619) ^ effect.context.effectID.rawValue
  }
}

private final class Fixture {
  let scenario: Scenario
  var runtime: PlaybackModelRuntime?
  var effects: [PlaybackEffect] = []
  var work = Work()

  init(_ scenario: Scenario, count: Int) {
    self.scenario = scenario
    if scenario.usesCore {
      var core = PlaybackModelRuntime(recordsReplaySteps: false)
      let load = core.send(.command(.load(source: .init(rawValue: "fixture/contracts.mkv"), autoplay: false)))
      precondition(load.disposition == .accepted && load.invariantViolations.isEmpty)
      while let completed = core.completeNext() {
        precondition(completed.disposition == .accepted && completed.invariantViolations.isEmpty)
      }
      precondition(core.core.state.activeSession?.phase == .paused && core.pendingEffects.isEmpty)
      runtime = core
    } else {
      // Equal array capacity is allocated before sampling. The direct-effect
      // experiment isolates growth beyond the empty, preallocated container.
      effects.reserveCapacity(count)
    }
  }

  @inline(never)
  func exercise(count: Int, captureCoreEffects: Bool = false) {
    for index in 0..<count {
      let effect: PlaybackEffect
      if scenario.usesCore {
        let transition = runtime!.send(.command(.checkpoint))
        precondition(transition.disposition == .accepted && transition.invariantViolations.isEmpty)
        precondition(transition.effects.count == 1)
        effect = transition.effects[0]
        if scenario == .checkpointChurn {
          let completion = runtime!.completeNext()!
          precondition(completion.disposition == .accepted && completion.invariantViolations.isEmpty)
          work.completed += 1
        }
        // Diagnostic copies exist only in the separate, untimed validation run.
        if captureCoreEffects { effects.append(effect) }
      } else {
        effect = makeEffect(index: index, custom: scenario == .customEffects)
        effects.append(effect)
      }
      work.recordIssued(effect)
    }
  }
}

@inline(never)
private func makeEffect(index: Int, custom: Bool) -> PlaybackEffect {
  let context = PlaybackEffectContext(authority: .application(.init(rawValue: 1)),
    operationID: .init(rawValue: UInt64(index + 1)), effectID: .init(rawValue: UInt64(index + 1)))
  if custom {
    // Explicit caller-owned completion storage is an unchanged control.
    return PlaybackEffect(executor: .persistence, context: context, kind: .persistCheckpoint,
      completion: .oneShot(terminals: [.init(kind: .succeeded, component: "custom")]))
  }
  return PlaybackEffect(executor: .persistence, context: context, kind: .persistCheckpoint)
}

private struct Semantics: Encodable {
  let scenario: Scenario
  let count: Int
  let work: Work
  let effects: [CanonicalPlaybackEffect]
  let state: PlaybackCanonicalState?
  let effectRoundTripEqual: Bool
  let stateRoundTripEqual: Bool
  let pendingEffects: Int
  let outstandingEffects: Int
  let replaySteps: Int
}

private func encoded<T: Encodable>(_ value: T) throws -> Data {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
  return try encoder.encode(value)
}

@inline(never)
private func semantics(_ scenario: Scenario, count: Int, expected: Work?) throws -> Data {
  let fixture = Fixture(scenario, count: count)
  fixture.exercise(count: count, captureCoreEffects: true)
  if let expected { precondition(fixture.work == expected) }
  precondition(fixture.effects.count == count)
  let expectedTokens: Set<EffectResultToken> = scenario == .customEffects
    ? [.init(kind: .succeeded, component: "custom")]
    : [.init(kind: .succeeded), .init(kind: .failed), .init(kind: .cancelled)]
  for effect in fixture.effects {
    precondition(effect.completion == .oneShot(terminals: expectedTokens))
  }
  let decoded = try JSONDecoder().decode([PlaybackEffect].self, from: encoded(fixture.effects))
  precondition(decoded == fixture.effects)
  var state: PlaybackCanonicalState?
  var stateRoundTrip = true
  if let runtime = fixture.runtime {
    precondition(runtime.steps.isEmpty)
    let expectedOutstanding = scenario == .pendingCheckpoints ? count : 0
    precondition(runtime.pendingEffects.count == expectedOutstanding)
    precondition(runtime.core.state.outstandingEffects.count == expectedOutstanding)
    let restored = try JSONDecoder().decode(PlaybackCoreState.self, from: encoded(runtime.core.state))
    stateRoundTrip = restored == runtime.core.state
    precondition(stateRoundTrip)
    state = PlaybackCanonicalState(state: runtime.core.state)
    precondition(PlaybackCanonicalState(state: restored) == state)
  }
  return try encoded(Semantics(scenario: scenario, count: count, work: fixture.work,
    effects: fixture.effects.map(CanonicalPlaybackEffect.init), state: state,
    effectRoundTripEqual: true, stateRoundTripEqual: stateRoundTrip,
    pendingEffects: fixture.runtime?.pendingEffects.count ?? 0,
    outstandingEffects: fixture.runtime?.core.state.outstandingEffects.count ?? 0,
    replaySteps: fixture.runtime?.steps.count ?? 0))
}

private struct Measurement: Encodable {
  let schema = 1
  let scenario: Scenario
  let count: Int
  let allocatorMetric: String
  let allocatorBeforeWorkBytes: UInt64
  let allocatorAfterWorkBytes: UInt64
  let retainedAllocatorDeltaBytes: Int64
  let allocationMeterAvailable: Bool
  let allocationRequests: UInt64?
  let requestedBytes: UInt64?
  let meteredWallNanoseconds: UInt64
  let work: Work
  let semanticBytes: Int
}

@main
private enum CompletionContractBenchmark {
  static func main() throws {
    let args = CommandLine.arguments
    precondition(args.count == 4, "Usage: benchmark SCENARIO COUNT SEMANTIC_OUTPUT_PATH")
    let scenario = Scenario(rawValue: args[1])!
    let count = Int(args[2])!
    precondition((1...8192).contains(count))
    // Warm framework/encoder/type metadata and the one shared candidate Set.
    // Its small process-lifetime allocation is outside this steady-state delta.
    _ = try semantics(scenario, count: 8, expected: nil)
    _ = completion_heap_bytes()
    let metric = String(cString: completion_heap_metric())
    precondition(metric != "unsupported")
    let meterAvailable = completion_allocation_meter_available() != 0
    var fixture: Fixture? = Fixture(scenario, count: count)
    let before = completion_heap_bytes()
    let start = DispatchTime.now().uptimeNanoseconds
    completion_meter_begin()
    fixture!.exercise(count: count)
    completion_meter_end()
    let elapsed = DispatchTime.now().uptimeNanoseconds - start
    let requests = completion_allocation_requests()
    let bytes = completion_requested_bytes()
    let after = withExtendedLifetime(fixture) { completion_heap_bytes() }
    let work = fixture!.work
    fixture = nil
    // Complete canonical bytes are compared outside measurement in Python.
    // Only one compressed reference per scenario/count is retained as evidence.
    let semantic = try semantics(scenario, count: count, expected: work)
    try semantic.write(to: URL(fileURLWithPath: args[3]))
    let result = Measurement(scenario: scenario, count: count, allocatorMetric: metric,
      allocatorBeforeWorkBytes: before, allocatorAfterWorkBytes: after,
      retainedAllocatorDeltaBytes: Int64(after) - Int64(before),
      allocationMeterAvailable: meterAvailable,
      allocationRequests: meterAvailable ? requests : nil, requestedBytes: meterAvailable ? bytes : nil,
      meteredWallNanoseconds: elapsed, work: work, semanticBytes: semantic.count)
    print(String(decoding: try encoded(result), as: UTF8.self))
  }
}
