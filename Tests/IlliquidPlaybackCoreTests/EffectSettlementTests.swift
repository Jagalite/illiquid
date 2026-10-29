import Testing

@testable import IlliquidPlaybackCore

@Suite("Effect settlement")
struct EffectSettlementTests {
  @Test
  func supersededLoadSettlesOnlyTheExactAuthorityAndPreservesRetainedState() throws {
    let pending = makeSession(10)
    let revisionVariants: [PlaybackRevisionSet] = [
      .init(track: .init(rawValue: 1)),
      .init(decoder: .init(rawValue: 1)),
      .init(videoFormat: .init(rawValue: 1)),
      .init(audioFormat: .init(rawValue: 1)),
      .init(presentation: .init(rawValue: 1)),
      .init(presentationGraph: .init(rawValue: 1)),
      .init(presentationMembership: .init(rawValue: 1)),
      .init(subtitle: .init(rawValue: 1)),
      .init(overlay: .init(rawValue: 1)),
      .init(surface: .init(rawValue: 1)),
    ]
    let unrelatedAuthorities: [PlaybackAuthority] = [
      .playback(sessionID: .init(rawValue: 11), generation: pending.generation,
                revisions: pending.revisions),
      .playback(sessionID: pending.id, generation: .init(rawValue: 4),
                revisions: pending.revisions),
      .application(.init(rawValue: 1)),
    ] + revisionVariants.map {
      .playback(sessionID: pending.id, generation: pending.generation, revisions: $0)
    }
    let unrelated = Dictionary(uniqueKeysWithValues: unrelatedAuthorities.enumerated().map {
      let record = makeRecord(UInt64($0.offset) + 20, authority: $0.element)
      return (record.effect.context.effectID, record)
    })
    let retired = [UInt64(1), 3, 5].map { makeRecord($0, authority: pending.authority) }
    var records = unrelated
    for record in retired { records[record.effect.context.effectID] = record }
    let initial = makeState(pending: pending, records: records, completed: [id(2), id(4)])
    var core = PlaybackCore(state: initial)
    let retained = core.state

    let transition = send(.command(.load(source: .init(rawValue: "fixture/new.mkv"),
                                        autoplay: false)), to: &core)
    #expect(transition.disposition == .accepted)
    #expect(transition.invariantViolations.isEmpty)
    #expect(transition.effects.count == 1)
    let opened = try #require(transition.effects.first)
    #expect(opened.kind == .openSource(.init(rawValue: "fixture/new.mkv")))
    #expect(core.state.pendingSession?.id == .init(rawValue: 100))
    var expected = unrelated
    expected[opened.context.effectID] = .init(effect: opened)
    #expect(core.state.outstandingEffects == expected)
    #expect(core.state.completedEffectIDs == Set((UInt64(1)...5).map(id)))
    #expect(core.state.completedEffectHistoryPrefixCount == 5)
    #expect(core.state.completedEffectHistorySparseCount == 0)

    // Reducer copies and replay snapshots may retain both dictionary and history
    // storage while the live state retires an authority.
    #expect(retained == initial)
    #expect(retained.outstandingEffects == records)
    #expect(retained.completedEffectIDs == [id(2), id(4)])
    #expect(retained.pendingSession?.value == pending)

    for record in retired {
      let duplicate = send(.effectResult(.init(context: record.effect.context,
                                               token: .init(kind: .succeeded))), to: &core)
      #expect(duplicate.disposition == .duplicate(effectID: record.effect.context.effectID))
      #expect(duplicate.effects.isEmpty)
      #expect(duplicate.snapshot == transition.snapshot)
      #expect(duplicate.invariantViolations.isEmpty)
    }
    let unknown = makeRecord(999, authority: pending.authority)
    let stale = send(.effectResult(.init(context: unknown.effect.context,
                                        token: .init(kind: .succeeded))), to: &core)
    #expect(stale.disposition == .stale(reason: .unknownEffect))
    #expect(!core.state.containsCompletedEffect(id(999)))
    #expect(core.state.outstandingEffects == expected)
    #expect(retained == initial)
  }

  @Test(arguments: [false, true])
  func supersededLoadWithNoMatchingEffectsPreservesExistingRecords(hasUnrelatedEffect: Bool) {
    let pending = makeSession(10)
    let unrelated = makeRecord(7, authority: makeSession(20).authority)
    let records = hasUnrelatedEffect ? [id(7): unrelated] : [:]
    var core = PlaybackCore(state: makeState(pending: pending, records: records,
                                            completed: [id(2)]))
    let transition = send(.command(.load(source: .init(rawValue: "fixture/new.mkv"),
                                        autoplay: false)), to: &core)
    #expect(transition.disposition == .accepted)
    #expect(transition.invariantViolations.isEmpty)
    #expect(core.state.outstandingEffects.count == records.count + 1)
    #expect(core.state.outstandingEffects[id(7)] == records[id(7)])
    #expect(core.state.completedEffectIDs == [id(2)])
  }

  @Test(arguments: [false, true])
  func stopSettlesThePendingLoadBeforeCreatingCancellation(hasCommittedSession: Bool) throws {
    let pending = makeSession(10)
    let committed = makeSession(20, phase: .paused)
    let preserved = makeRecord(20, authority: committed.authority)
    let records = [
      id(1): makeRecord(1, authority: pending.authority),
      id(3): makeRecord(3, authority: pending.authority),
      id(20): preserved,
    ]
    var core = PlaybackCore(state: makeState(active: hasCommittedSession ? committed : nil,
                                            pending: pending, records: records,
                                            completed: [id(2)]))

    let transition = send(.command(.stop), to: &core)
    #expect(transition.disposition == .accepted)
    #expect(transition.invariantViolations.isEmpty)
    #expect(core.state.pendingSession == nil)
    #expect(core.state.activeSession?.id == (hasCommittedSession ? committed.id : pending.id))
    #expect(core.state.activeSession?.generation == .init(rawValue: 4))
    #expect(core.state.activeSession?.phase == .stopping)
    #expect(core.state.completedEffectIDs == [id(1), id(2), id(3)])
    #expect(transition.effects.count == 1)
    let cancel = try #require(transition.effects.first)
    #expect(cancel.kind == .cancelSession)
    #expect(cancel.context.authority == core.state.activeSession?.authority)
    #expect(core.state.outstandingEffects == [
      id(20): preserved, cancel.context.effectID: .init(effect: cancel),
    ])
    #expect(!core.state.containsCompletedEffect(cancel.context.effectID))
  }

  @Test
  func committingPrerollRetiresThePreviousSessionWithoutSettlingTheReplacement() {
    let committed = makeSession(10, phase: .paused)
    let pending = makeSession(20, phase: .prerolling)
    let preroll = makeRecord(10, authority: pending.authority, kind: .awaitPreroll)
    let pendingWork = makeRecord(11, authority: pending.authority)
    var otherRevision = committed
    otherRevision.revisions.overlay = .init(rawValue: 1)
    let revisedWork = makeRecord(12, authority: otherRevision.authority)
    let records = [
      id(1): makeRecord(1, authority: committed.authority),
      id(3): makeRecord(3, authority: committed.authority),
      id(10): preroll, id(11): pendingWork, id(12): revisedWork,
    ]
    var core = PlaybackCore(state: makeState(active: committed, pending: pending,
                                            records: records, completed: [id(2)]))
    let retained = core.state

    let transition = send(.effectResult(.init(context: preroll.effect.context,
                                             token: .init(kind: .succeeded))), to: &core)
    #expect(transition.disposition == .accepted)
    #expect(transition.invariantViolations.isEmpty)
    #expect(transition.effects.isEmpty)
    #expect(core.state.activeSession?.id == pending.id)
    #expect(core.state.activeSession?.phase == .paused)
    #expect(core.state.pendingSession == nil)
    #expect(core.state.outstandingEffects == [id(11): pendingWork, id(12): revisedWork])
    #expect(core.state.completedEffectIDs == [id(1), id(2), id(3), id(10)])
    #expect(retained.outstandingEffects == records)
    #expect(retained.completedEffectIDs == [id(2)])
    #expect(retained.activeSession == committed)
    #expect(retained.pendingSession?.value == pending)
  }

  @Test(arguments: [EffectResultKind.succeeded, .failed, .cancelled])
  func retiredSessionCleanupSettlesItsRemainingEffectsOnlyAfterSuccess(kind: EffectResultKind) {
    let current = makeSession(30, phase: .paused)
    let retired = makeSession(10)
    let cancel = makeRecord(10, authority: retired.authority, kind: .cancelSession,
                            isCleanup: true)
    let remaining = makeRecord(1, authority: retired.authority)
    let currentWork = makeRecord(20, authority: current.authority)
    var nextGeneration = retired
    nextGeneration.generation = .init(rawValue: 4)
    let newerWork = makeRecord(21, authority: nextGeneration.authority)
    var core = PlaybackCore(state: makeState(active: current, records: [
      id(1): remaining, id(10): cancel, id(20): currentWork, id(21): newerWork,
    ]))

    let transition = send(.effectResult(.init(context: cancel.effect.context,
                                             token: .init(kind: kind))), to: &core)
    #expect(transition.disposition == .accepted)
    #expect(transition.invariantViolations.isEmpty)
    #expect(transition.effects.isEmpty)
    #expect(core.state.activeSession == current)
    var expected = [id(20): currentWork, id(21): newerWork]
    if kind != .succeeded { expected[id(1)] = remaining }
    #expect(core.state.outstandingEffects == expected)
    let completed: Set<PlaybackEffectID> = kind == .succeeded ? [id(1), id(10)] : [id(10)]
    #expect(core.state.completedEffectIDs == completed)
    let duplicate = send(.effectResult(.init(context: cancel.effect.context,
                                             token: .init(kind: kind))), to: &core)
    #expect(duplicate.disposition == .duplicate(effectID: id(10)))
    #expect(core.state.outstandingEffects == expected)
    #expect(core.state.completedEffectIDs == completed)
  }

  @Test
  func settlementClosesCompletionGapsRegardlessOfDictionaryInsertionOrder() {
    let pending = makeSession(10)
    let oddIDs = Array(stride(from: UInt64(1), through: 63, by: 2))
    let completed = Set(stride(from: UInt64(2), through: 64, by: 2).map(id))
      .union([id(0), id(.max)])
    let expectedCompleted = Set((UInt64(1)...64).map(id)).union([id(0), id(.max)])
    let unrelated = makeRecord(200, authority: makeSession(20).authority)
    var settledStates: [PlaybackCoreState] = []
    for values in [oddIDs, Array(oddIDs.reversed()), Array(oddIDs[8...]) + Array(oddIDs[..<8])] {
      var records = [id(200): unrelated]
      for value in values { records[id(value)] = makeRecord(value, authority: pending.authority) }
      var core = PlaybackCore(state: makeState(pending: pending, records: records,
                                              completed: completed))
      let transition = send(.command(.load(source: .init(rawValue: "fixture/new.mkv"),
                                          autoplay: false)), to: &core)
      #expect(transition.disposition == .accepted)
      #expect(transition.invariantViolations.isEmpty)
      #expect(core.state.completedEffectIDs == expectedCompleted)
      #expect(core.state.completedEffectHistoryPrefixCount == 64)
      #expect(core.state.completedEffectHistorySparseCount == 2)
      #expect(core.state.outstandingEffects.count == 2)
      #expect(core.state.outstandingEffects[id(200)] == unrelated)
      #expect(!core.state.containsCompletedEffect(id(200)))
      settledStates.append(core.state)
    }
    #expect(settledStates[0] == settledStates[1])
    #expect(settledStates[0] == settledStates[2])
  }

  private func id(_ value: UInt64) -> PlaybackEffectID { .init(rawValue: value) }

  private func makeSession(_ value: UInt64, phase: PlaybackMachinePhase = .opening)
    -> ActivePlaybackSession
  {
    .init(id: .init(rawValue: value), source: .init(rawValue: "fixture/\(value).mkv"),
          generation: .init(rawValue: 3), phase: phase, desiredTransport: .paused,
          actualTransport: phase == .paused ? .paused : .stopped,
          activeOperationID: .init(rawValue: value), loading: .init())
  }

  private func makeRecord(_ value: UInt64, authority: PlaybackAuthority,
                          kind: PlaybackEffectKind = .persistCheckpoint, isCleanup: Bool = false)
    -> OutstandingEffectRecord
  {
    let executor: ExecutorKind = switch kind {
    case .cancelSession: .resource
    case .awaitPreroll: .presentation
    default: .persistence
    }
    return .init(effect: .init(executor: executor,
                        context: .init(authority: authority, operationID: .init(rawValue: value),
                                       effectID: id(value)),
                        kind: kind, isCleanup: isCleanup, exclusiveKey: "fixture.effect.\(value)"))
  }

  private func makeState(active: ActivePlaybackSession? = nil,
                         pending: ActivePlaybackSession? = nil,
                         records: [PlaybackEffectID: OutstandingEffectRecord],
                         completed: Set<PlaybackEffectID> = []) -> PlaybackCoreState
  {
    .init(activeSession: active, pendingSession: pending, outstandingEffects: records,
          completedEffectIDs: completed,
          allocator: .init(nextSession: 100, nextOperation: 100, nextEffect: 1_000))
  }

  private func send(_ event: PlaybackEvent, to core: inout PlaybackCore) -> PlaybackTransition {
    let tick = core.state.lastVirtualTime.ticks + 1
    return core.update(.init(sequence: tick, virtualTime: .init(ticks: tick), event: event))
  }
}
