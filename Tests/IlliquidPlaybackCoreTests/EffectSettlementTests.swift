import Testing

@testable import IlliquidPlaybackCore

@Suite("Effect settlement")
struct EffectSettlementTests {
  @Test(arguments: [0, 1, 8, 64])
  func replacementRetiresMatchingAuthorityAndPreservesOtherGenerations(
    pendingCount: Int
  ) throws {
    var trace = EffectSettlementTrace()
    try trace.loadPaused(MediaSourceIdentity(rawValue: "fixture/settlement-original.mkv"))
    let survivors = [
      try trace.commandEffect(.pause),
      try trace.commandEffect(.pause),
    ]
    let target = try #require(ValidMediaTime(value: 0, timescale: 1))
    let seek = try trace.commandEffect(.seek(target: .valid(target), mode: .exact))
    let seekRate = try settlementOnlyEffect(trace.succeed(seek))
    #expect(seekRate.kind == .applyRate(milliRate: 0))
    _ = trace.succeed(seekRate)
    let preservedRecords = trace.core.state.outstandingEffects
    let retiredAuthority = try #require(trace.core.state.activeSession?.authority)
    #expect(retiredAuthority != survivors[0].context.authority)

    var retired: [PlaybackEffect] = []
    for _ in 0..<pendingCount {
      retired.append(try trace.commandEffect(.pause))
    }
    let replacement = MediaSourceIdentity(rawValue: "fixture/settlement-replacement.mkv")
    let open = try trace.commandEffect(.load(source: replacement, autoplay: false))
    let preroll = try settlementOnlyEffect(trace.succeed(open))
    #expect(preroll.kind == .awaitPreroll)
    #expect(retired.allSatisfy { $0.context.authority == retiredAuthority })
    var expectedCompleted = trace.core.state.completedEffectIDs
    expectedCompleted.formUnion(retired.map { $0.context.effectID })
    expectedCompleted.insert(preroll.context.effectID)

    let committed = trace.succeed(preroll)
    #expect(committed.effects.isEmpty)
    #expect(committed.snapshot.source == replacement)
    #expect(committed.snapshot.phase == .paused)
    #expect(trace.core.state.pendingSession == nil)
    #expect(trace.core.state.outstandingEffects == preservedRecords)
    #expect(trace.core.state.completedEffectIDs == expectedCompleted)
    // The two earlier-generation effects keep a real hole in the history.
    #expect(trace.core.state.completedEffectHistoryPrefixCount == 2)
    #expect(trace.core.state.completedEffectHistorySparseCount == expectedCompleted.count - 2)

    for effect in retired {
      let late = trace.succeed(effect, expected: .duplicate(effectID: effect.context.effectID))
      #expect(late.snapshot == committed.snapshot)
      #expect(late.effects.isEmpty)
    }
    #expect(trace.core.state.outstandingEffects == preservedRecords)
    #expect(trace.core.state.completedEffectIDs == expectedCompleted)

    for effect in survivors {
      let late = trace.succeed(effect, expected: .stale(reason: .sessionMismatch))
      #expect(late.snapshot == committed.snapshot)
      #expect(late.effects.isEmpty)
      expectedCompleted.insert(effect.context.effectID)
    }
    #expect(trace.core.state.outstandingEffects.isEmpty)
    #expect(trace.core.state.completedEffectIDs == expectedCompleted)
    #expect(trace.core.state.completedEffectHistoryPrefixCount == UInt64(expectedCompleted.count))
    #expect(trace.core.state.completedEffectHistorySparseCount == 0)
  }

  @Test
  func replacementWithNoOutstandingEffectsKeepsHistoryConsecutive() throws {
    var trace = EffectSettlementTrace()
    try trace.loadPaused(MediaSourceIdentity(rawValue: "fixture/settlement-empty-first.mkv"))
    #expect(trace.core.state.outstandingEffects.isEmpty)

    let replacement = MediaSourceIdentity(rawValue: "fixture/settlement-empty-next.mkv")
    try trace.loadPaused(replacement)
    #expect(trace.core.state.activeSession?.source == replacement)
    #expect(trace.core.state.outstandingEffects.isEmpty)
    #expect(trace.core.state.completedEffectHistoryPrefixCount == 4)
    #expect(trace.core.state.completedEffectHistorySparseCount == 0)
    #expect(trace.core.state.completedEffectIDs.count == 4)
  }

  @Test(arguments: [false, true])
  func pendingLoadSupersessionPreservesCommittedSessionWork(afterOpen: Bool) throws {
    var trace = EffectSettlementTrace()
    try trace.loadPaused(MediaSourceIdentity(rawValue: "fixture/settlement-active.mkv"))
    let activePause = try trace.commandEffect(.pause)
    let activeSession = trace.core.state.activeSession
    let firstOpen = try trace.commandEffect(.load(
      source: MediaSourceIdentity(rawValue: "fixture/settlement-superseded.mkv"),
      autoplay: false
    ))
    let superseded: PlaybackEffect
    if afterOpen {
      superseded = try settlementOnlyEffect(trace.succeed(firstOpen))
    } else {
      superseded = firstOpen
    }
    var expectedCompleted = trace.core.state.completedEffectIDs
    expectedCompleted.insert(superseded.context.effectID)

    let replacement = MediaSourceIdentity(rawValue: "fixture/settlement-latest.mkv")
    let nextOpen = try trace.commandEffect(.load(source: replacement, autoplay: false))
    #expect(trace.core.state.activeSession == activeSession)
    #expect(trace.core.state.pendingSession?.source == replacement)
    #expect(Set(trace.core.state.outstandingEffects.keys) == [
      activePause.context.effectID, nextOpen.context.effectID,
    ])
    #expect(trace.core.state.outstandingEffects[activePause.context.effectID]
      == OutstandingEffectRecord(effect: activePause))
    #expect(trace.core.state.completedEffectIDs == expectedCompleted)
    let snapshot = PlaybackUISnapshot(state: trace.core.state)
    let late = trace.succeed(
      superseded, expected: .duplicate(effectID: superseded.context.effectID)
    )
    #expect(late.snapshot == snapshot)
    #expect(late.effects.isEmpty)

    let nextPreroll = try settlementOnlyEffect(trace.succeed(nextOpen))
    _ = trace.succeed(nextPreroll)
    expectedCompleted.formUnion([
      activePause.context.effectID, nextOpen.context.effectID, nextPreroll.context.effectID,
    ])
    #expect(trace.core.state.completedEffectIDs == expectedCompleted)
    #expect(trace.core.state.outstandingEffects.isEmpty)
    #expect(trace.core.state.activeSession?.source == replacement)
  }

  @Test
  func stopSettlesPendingWorkAndCancellationSettlesOnlyItsAuthority() throws {
    var trace = EffectSettlementTrace()
    try trace.loadPaused(MediaSourceIdentity(rawValue: "fixture/settlement-stop.mkv"))
    let oldPause = try trace.commandEffect(.pause)
    let pendingOpen = try trace.commandEffect(.load(
      source: MediaSourceIdentity(rawValue: "fixture/settlement-stop-pending.mkv"),
      autoplay: false
    ))
    var expectedCompleted = trace.core.state.completedEffectIDs
    let cancellation = try trace.commandEffect(.stop)
    #expect(cancellation.kind == .cancelSession)
    #expect(trace.core.state.pendingSession == nil)
    #expect(trace.core.state.activeSession?.phase == .stopping)
    expectedCompleted.insert(pendingOpen.context.effectID)
    #expect(trace.core.state.completedEffectIDs == expectedCompleted)
    #expect(trace.core.state.outstandingEffects[oldPause.context.effectID]
      == OutstandingEffectRecord(effect: oldPause))

    // Stop advances the generation. Checkpoint remains an accepted command
    // while stopping and provides outstanding work with cancellation's authority.
    let checkpoints = [
      try trace.commandEffect(.checkpoint),
      try trace.commandEffect(.checkpoint),
    ]
    #expect(checkpoints.allSatisfy {
      $0.context.authority == cancellation.context.authority
    })
    #expect(oldPause.context.authority != cancellation.context.authority)
    let cancelled = trace.succeed(cancellation)
    expectedCompleted.insert(cancellation.context.effectID)
    expectedCompleted.formUnion(checkpoints.map { $0.context.effectID })
    #expect(cancelled.effects.isEmpty)
    #expect(trace.core.state.activeSession == nil)
    #expect(trace.core.state.outstandingEffects == [
      oldPause.context.effectID: OutstandingEffectRecord(effect: oldPause),
    ])
    #expect(trace.core.state.completedEffectIDs == expectedCompleted)
    #expect(trace.core.state.completedEffectHistoryPrefixCount == 2)

    for effect in [pendingOpen] + checkpoints {
      let late = trace.succeed(effect, expected: .duplicate(effectID: effect.context.effectID))
      #expect(late.snapshot == cancelled.snapshot)
      #expect(late.effects.isEmpty)
    }
    _ = trace.succeed(oldPause, expected: .stale(reason: .sessionMismatch))
    expectedCompleted.insert(oldPause.context.effectID)
    #expect(trace.core.state.completedEffectIDs == expectedCompleted)
    #expect(trace.core.state.outstandingEffects.isEmpty)
    #expect(trace.core.state.completedEffectHistoryPrefixCount == UInt64(expectedCompleted.count))
    #expect(trace.core.state.completedEffectHistorySparseCount == 0)
  }
}

private struct EffectSettlementTrace {
  var core = PlaybackCore()
  private var sequence: UInt64 = 0

  mutating func send(_ event: PlaybackEvent) -> PlaybackTransition {
    sequence += 1
    let transition = core.update(PlaybackEventEnvelope(
      sequence: sequence,
      virtualTime: PlaybackInstant(ticks: sequence),
      event: event
    ))
    #expect(transition.invariantViolations.isEmpty)
    return transition
  }

  mutating func commandEffect(_ command: PlaybackCommand) throws -> PlaybackEffect {
    let transition = send(.command(command))
    #expect(transition.disposition == .accepted)
    return try settlementOnlyEffect(transition)
  }

  mutating func succeed(
    _ effect: PlaybackEffect,
    expected: EventDisposition = .accepted
  ) -> PlaybackTransition {
    let transition = send(.effectResult(PlaybackEffectResult(
      context: effect.context,
      token: EffectResultToken(kind: .succeeded)
    )))
    #expect(transition.disposition == expected)
    return transition
  }

  mutating func loadPaused(_ source: MediaSourceIdentity) throws {
    let open = try commandEffect(.load(source: source, autoplay: false))
    let preroll = try settlementOnlyEffect(succeed(open))
    #expect(preroll.kind == .awaitPreroll)
    let loaded = succeed(preroll)
    #expect(loaded.effects.isEmpty)
    #expect(loaded.snapshot.phase == .paused)
    #expect(loaded.snapshot.actualTransport == .paused)
    #expect(core.state.activeSession?.source == source)
    #expect(core.state.pendingSession == nil)
  }
}

private func settlementOnlyEffect(_ transition: PlaybackTransition) throws -> PlaybackEffect {
  #expect(transition.effects.count == 1)
  return try #require(transition.effects.first)
}
