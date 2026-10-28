import Dispatch
import Foundation
import IlliquidPlaybackCore
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

private enum BenchmarkFailure: Error { case invalid(String) }

private func require(_ condition: Bool, _ message: String) throws {
  if !condition { throw BenchmarkFailure.invalid(message) }
}

private func cpuNanoseconds() -> UInt64 {
  var time = timespec()
  precondition(clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &time) == 0)
  return UInt64(time.tv_sec) * 1_000_000_000 + UInt64(time.tv_nsec)
}

private func only(_ result: PlaybackTransition) throws -> PlaybackEffect {
  try require(result.effects.count == 1, "Expected one setup effect")
  return result.effects[0]
}

/// Each fixture owns a newly constructed core. No state or core template is
/// retained across the timed mutation; effect contexts do not alias its tables.
private struct Fixture {
  var core = PlaybackCore()
  var sequence: UInt64 = 0
  var targetContexts: [PlaybackEffectContext] = []
  var survivorRecords: [PlaybackEffectID: OutstandingEffectRecord] = [:]
  var expectedCompleted: Set<PlaybackEffectID> = []
  var completion: PlaybackEventEnvelope?
  var transition: PlaybackTransition?

  init(count: Int, survivors: Int = 0) throws {
    let open = try only(try send(.command(.load(
      source: .init(rawValue: "fixture/settlement-old.mkv"), autoplay: false
    ))))
    let initialPreroll = try only(try complete(open))
    _ = try complete(initialPreroll)
    for _ in 0..<survivors {
      let effect = try only(try send(.command(.pause)))
      survivorRecords[effect.context.effectID] = .init(effect: effect)
    }
    if survivors > 0 {
      let target = MediaTimestamp.valid(ValidMediaTime(value: 0, timescale: 1)!)
      let seek = try only(try send(.command(.seek(target: target, mode: .exact))))
      let rate = try only(try complete(seek))
      _ = try complete(rate)
    }
    targetContexts.reserveCapacity(count)
    for _ in 0..<count {
      let effect = try only(try send(.command(.pause)))
      targetContexts.append(effect.context)
    }
    let replacement = try only(try send(.command(.load(
      source: .init(rawValue: "fixture/settlement-new.mkv"), autoplay: false
    ))))
    let preroll = try only(try complete(replacement))
    guard case .awaitPreroll = preroll.kind else {
      throw BenchmarkFailure.invalid("Replacement did not await preroll")
    }
    expectedCompleted.formUnion(targetContexts.map(\.effectID))
    expectedCompleted.insert(preroll.context.effectID)
    completion = envelope(.effectResult(.init(
      context: preroll.context, token: .init(kind: .succeeded)
    )))
    try require(core.state.outstandingEffects.count == count + survivors + 1,
                "Unexpected setup effects")
  }

  mutating func envelope(_ event: PlaybackEvent) -> PlaybackEventEnvelope {
    sequence += 1
    return .init(sequence: sequence, virtualTime: .init(ticks: sequence), event: event)
  }

  private mutating func send(_ event: PlaybackEvent) throws -> PlaybackTransition {
    let event = envelope(event)
    let result = core.update(event)
    try require(result.disposition == .accepted && result.invariantViolations.isEmpty,
                "Setup transition failed")
    return result
  }

  private mutating func complete(_ effect: PlaybackEffect) throws -> PlaybackTransition {
    let result = try send(.effectResult(.init(
      context: effect.context, token: .init(kind: .succeeded)
    )))
    expectedCompleted.insert(effect.context.effectID)
    return result
  }

  // The measured driver calls only this method. Result storage is pre-existing.
  mutating func finish() {
    let event = completion!
    transition = core.update(event)
  }

  func validate() throws {
    guard let transition else { throw BenchmarkFailure.invalid("Missing transition") }
    try require(transition.disposition == .accepted && transition.effects.isEmpty,
                "Replacement disposition/effects changed")
    try require(transition.invariantViolations.isEmpty
                && PlaybackInvariantChecker.check(state: core.state).isEmpty,
                "Replacement violated an invariant")
    try require(core.state.pendingSession == nil
                && core.state.activeSession?.source.rawValue == "fixture/settlement-new.mkv"
                && core.state.activeSession?.phase == .paused,
                "Replacement was not committed paused")
    try require(core.state.outstandingEffects == survivorRecords,
                "Retirement removed an unrelated authority or retained a target")
    try require(core.state.completedEffectIDs == expectedCompleted,
                "Completed membership changed")
  }

  mutating func lateDuplicates() throws -> [EventDisposition] {
    guard case .effectResult(let preroll) = completion!.event else {
      throw BenchmarkFailure.invalid("Missing completion context")
    }
    var results: [EventDisposition] = []
    for context in targetContexts + [preroll.context] {
      let event = envelope(.effectResult(.init(context: context, token: .init(kind: .succeeded))))
      let result = core.update(event)
      try require(result.disposition == .duplicate(effectID: context.effectID),
                  "A retired effect lost duplicate classification")
      try require(result.effects.isEmpty && result.invariantViolations.isEmpty,
                  "Duplicate emitted work or violated an invariant")
      results.append(result.disposition)
    }
    try require(core.state.outstandingEffects == survivorRecords
                && core.state.completedEffectIDs == expectedCompleted,
                "Late duplicates changed effect membership")
    return results
  }
}

// CanonicalState sorts dictionary and Set fields. Include its omitted state
// properties explicitly so parity is a comparison of the complete final state.
private struct CompleteState: Encodable {
  let canonical: PlaybackCanonicalState
  let pendingSession: ActivePlaybackSession?
  let loopRange: PlaybackLoopRange?
  let preferredPlaybackMilliRate: Int32?
  let lastLoadFailure: PlaybackFailure?

  init(_ state: PlaybackCoreState) {
    canonical = .init(state: state)
    pendingSession = state.pendingSession?.value
    loopRange = state.loopRange
    preferredPlaybackMilliRate = state.preferredPlaybackMilliRate
    lastLoadFailure = state.lastLoadFailure
  }
}

private struct Verification: Encodable {
  let count: Int
  let survivors: Int
  let transition: PlaybackTransition
  let settled: CompleteState
  let duplicates: [EventDisposition]
  let afterDuplicates: CompleteState
}

private struct Observation: Encodable {
  let count: Int
  let iterations: Int
  let batchSize: Int
  let wallNanoseconds: UInt64
  let cpuNanoseconds: UInt64
  let checks: Checks

  struct Checks: Encodable {
    var transitions = 0
    var completedIDs = 0
    var retiredTargets = 0
    var snapshotRevisionSum: UInt64 = 0
  }
}

private func measure(count: Int, iterations: Int) throws -> Observation {
  // Warm the complete update path in this process before any timed batch.
  do {
    var warmup = try Fixture(count: count)
    warmup.finish()
    try warmup.validate()
  }
  // Bound live setup storage. Stress has a single fresh core per batch.
  let batchSize = count == 4_096 ? 1 : min(256, max(1, 16_384 / max(1, count)))
  var wall: UInt64 = 0
  var cpu: UInt64 = 0
  var checks = Observation.Checks()
  var remaining = iterations
  while remaining > 0 {
    let size = min(batchSize, remaining)
    var fixtures: [Fixture] = []
    fixtures.reserveCapacity(size)
    for _ in 0..<size { fixtures.append(try Fixture(count: count)) }
    let cpuStart = cpuNanoseconds()
    let wallStart = DispatchTime.now().uptimeNanoseconds
    for index in fixtures.indices { fixtures[index].finish() }
    wall += DispatchTime.now().uptimeNanoseconds - wallStart
    cpu += cpuNanoseconds() - cpuStart
    for fixture in fixtures {
      try fixture.validate()
      checks.transitions += 1
      checks.completedIDs += fixture.expectedCompleted.count
      checks.retiredTargets += fixture.targetContexts.count
      checks.snapshotRevisionSum += fixture.core.state.snapshotRevision
    }
    // All fixtures and results are destroyed outside both timers.
    remaining -= size
  }
  return .init(count: count, iterations: iterations, batchSize: batchSize,
               wallNanoseconds: wall, cpuNanoseconds: cpu, checks: checks)
}

@main
private enum Main {
  static func main() throws {
    let args = Array(CommandLine.arguments.dropFirst())
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let output: Data
    if args == ["--verify"] {
      var checks: [Verification] = []
      for count in [0, 1, 8, 64, 4_096] {
        for survivors in [0, 3] {
          var fixture = try Fixture(count: count, survivors: survivors)
          fixture.finish()
          try fixture.validate()
          let transition = fixture.transition!
          let settled = CompleteState(fixture.core.state)
          let duplicates = try fixture.lateDuplicates()
          checks.append(.init(count: count, survivors: survivors, transition: transition,
                              settled: settled, duplicates: duplicates,
                              afterDuplicates: CompleteState(fixture.core.state)))
        }
      }
      output = try encoder.encode(checks)
    } else {
      guard args.count == 2, let count = Int(args[0]), let iterations = Int(args[1]),
            [0, 1, 8, 64, 4_096].contains(count), iterations > 0 else {
        throw BenchmarkFailure.invalid("Use --verify or COUNT ITERATIONS")
      }
      output = try encoder.encode(measure(count: count, iterations: iterations))
    }
    print(String(decoding: output, as: UTF8.self))
  }
}
