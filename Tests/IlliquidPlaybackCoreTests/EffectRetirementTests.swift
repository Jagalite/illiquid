import Foundation
import Testing
@testable import IlliquidPlaybackCore

@Suite("Effect retirement preserves completion and authority")
struct EffectRetirementTests {
  @Test(arguments: [0, 1, 64, 257])
  func committedReplacementRetiresEveryOldCheckpoint(count: Int) throws {
    var driver = Driver()
    try driver.loadPaused("fixture/old.mkv")
    let oldSession = try #require(driver.core.state.activeSession)
    var checkpoints: [PlaybackEffect] = []
    for _ in 0..<count {
      checkpoints.append(try onlyEffect(driver.send(.command(.checkpoint))))
    }

    let open = try onlyEffect(driver.send(.command(.load(
      source: .init(rawValue: "fixture/new.mkv"), autoplay: false
    ))))
    let preroll = try onlyEffect(driver.complete(open))
    #expect(driver.core.state.activeSession?.id == oldSession.id)
    for effect in checkpoints {
      #expect(driver.core.state.outstandingEffects[effect.context.effectID]?.effect == effect)
    }

    let committed = driver.complete(preroll)
    expectAccepted(committed)
    #expect(committed.effects.isEmpty)
    #expect(driver.core.state.activeSession?.source.rawValue == "fixture/new.mkv")
    #expect(driver.core.state.activeSession?.phase == .paused)
    #expect(driver.core.state.pendingSession == nil)
    #expect(driver.core.state.outstandingEffects.isEmpty)
    #expect(driver.core.state.completedEffectIDs.count == count + 4)

    let snapshot = PlaybackUISnapshot(state: driver.core.state)
    for effect in checkpoints {
      let duplicate = driver.complete(effect)
      #expect(duplicate.disposition == .duplicate(effectID: effect.context.effectID))
      #expect(duplicate.effects.isEmpty)
      #expect(duplicate.invariantViolations.isEmpty)
      #expect(duplicate.snapshot == snapshot)
    }
  }

  @Test(arguments: [false, true])
  func failedReplacementDoesNotRetireTheStillActiveSession(failAtPreroll: Bool) throws {
    var driver = Driver()
    try driver.loadPaused("fixture/old.mkv")
    let oldSession = try #require(driver.core.state.activeSession)
    let checkpoint = try onlyEffect(driver.send(.command(.checkpoint)))
    var failing = try onlyEffect(driver.send(.command(.load(
      source: .init(rawValue: "fixture/failing.mkv"), autoplay: false
    ))))
    if failAtPreroll {
      failing = try onlyEffect(driver.complete(failing))
    }

    expectAccepted(driver.complete(failing, kind: .failed))
    #expect(driver.core.state.pendingSession == nil)
    #expect(driver.core.state.activeSession == oldSession)
    #expect(driver.core.state.outstandingEffects[checkpoint.context.effectID]?.effect == checkpoint)
    #expect(!driver.core.state.completedEffectIDs.contains(checkpoint.context.effectID))

    let completed = driver.complete(checkpoint)
    expectAccepted(completed)
    #expect(completed.effects.isEmpty)
    #expect(driver.core.state.outstandingEffects[checkpoint.context.effectID] == nil)
  }

  @Test
  func supersedingPendingLoadRetiresItsCallbackWithoutDisturbingTheNewLoad() throws {
    var driver = Driver()
    let obsolete = try onlyEffect(driver.send(.command(.load(
      source: .init(rawValue: "fixture/obsolete.mkv"), autoplay: false
    ))))
    let replacement = try onlyEffect(driver.send(.command(.load(
      source: .init(rawValue: "fixture/replacement.mkv"), autoplay: false
    ))))

    #expect(driver.core.state.outstandingEffects[obsolete.context.effectID] == nil)
    #expect(driver.core.state.completedEffectIDs.contains(obsolete.context.effectID))
    #expect(driver.core.state.outstandingEffects[replacement.context.effectID]?.effect == replacement)
    let snapshot = PlaybackUISnapshot(state: driver.core.state)
    let duplicate = driver.complete(obsolete, kind: .failed)
    #expect(duplicate.disposition == .duplicate(effectID: obsolete.context.effectID))
    #expect(duplicate.effects.isEmpty)
    #expect(duplicate.invariantViolations.isEmpty)
    #expect(duplicate.snapshot == snapshot)

    let preroll = try onlyEffect(driver.complete(replacement))
    expectAccepted(driver.complete(preroll))
    #expect(driver.core.state.activeSession?.source.rawValue == "fixture/replacement.mkv")
    #expect(driver.core.state.pendingSession == nil)
  }

  @Test
  func supersessionUsesExactAuthorityAndPreservesAnEarlierStateCopy() throws {
    let pending = session(id: 1)
    var otherSession = pending
    otherSession.id = .init(rawValue: 2)
    var otherGeneration = pending
    otherGeneration.generation = .init(rawValue: 2)
    var otherRevision = pending
    otherRevision.revisions.subtitle = .init(rawValue: 99)

    let retired = [effect(id: 1, authority: pending.authority),
                   effect(id: 7, authority: pending.authority)]
    let survivors = [
      effect(id: 3, authority: .application(.init(rawValue: 1))),
      effect(id: 4, authority: otherSession.authority),
      effect(id: 5, authority: otherGeneration.authority),
      effect(id: 6, authority: otherRevision.authority),
    ]
    let records = Dictionary(uniqueKeysWithValues: (retired + survivors).map {
      ($0.context.effectID, OutstandingEffectRecord(effect: $0))
    })
    let originalHistory: Set<PlaybackEffectID> = [.init(rawValue: 0), .init(rawValue: 99)]
    let original = PlaybackCoreState(
      pendingSession: pending,
      outstandingEffects: records,
      completedEffectIDs: originalHistory,
      allocator: .init(nextSession: 3, nextOperation: 100, nextEffect: 1_000)
    )
    var driver = Driver(state: original)
    let newOpen = try onlyEffect(driver.send(.command(.load(
      source: .init(rawValue: "fixture/new.mkv"), autoplay: false
    ))))

    #expect(driver.core.state.pendingSession?.id == PlaybackSessionID(rawValue: 3))
    #expect(driver.core.state.outstandingEffects.count == survivors.count + 1)
    #expect(driver.core.state.outstandingEffects[newOpen.context.effectID]?.effect == newOpen)
    for effect in survivors {
      #expect(driver.core.state.outstandingEffects[effect.context.effectID] == records[effect.context.effectID])
    }
    let expectedHistory = originalHistory.union(retired.map { $0.context.effectID })
    #expect(driver.core.state.completedEffectIDs == expectedHistory)
    #expect(original.outstandingEffects == records)
    #expect(original.completedEffectIDs == originalHistory)
    #expect(original.pendingSession?.value == pending)

    let bytes = try JSONEncoder().encode(driver.core.state)
    let decoded = try JSONDecoder().decode(PlaybackCoreState.self, from: bytes)
    #expect(decoded == driver.core.state)
    #expect(PlaybackCanonicalState(state: decoded).completedEffectIDs == expectedHistory.sorted())

    let snapshot = PlaybackUISnapshot(state: driver.core.state)
    for effect in retired {
      let duplicate = driver.complete(effect)
      #expect(duplicate.disposition == .duplicate(effectID: effect.context.effectID))
      #expect(duplicate.effects.isEmpty)
      #expect(duplicate.invariantViolations.isEmpty)
      #expect(duplicate.snapshot == snapshot)
    }
    let unknown = effect(id: 500, authority: pending.authority)
    let rejected = driver.complete(unknown)
    #expect(rejected.disposition == .stale(reason: .unknownEffect))
    #expect(rejected.effects.isEmpty)
    #expect(rejected.invariantViolations.isEmpty)
    #expect(rejected.snapshot == snapshot)
  }

  @Test
  func stopRetiresPendingPreparationButPreservesOtherAuthorityRecords() throws {
    var driver = Driver()
    try driver.loadPaused("fixture/active.mkv")
    let oldCheckpoint = try onlyEffect(driver.send(.command(.checkpoint)))
    let pendingOpen = try onlyEffect(driver.send(.command(.load(
      source: .init(rawValue: "fixture/pending.mkv"), autoplay: false
    ))))
    let cancellation = try onlyEffect(driver.send(.command(.stop)))

    #expect(cancellation.kind == .cancelSession)
    #expect(driver.core.state.pendingSession == nil)
    #expect(driver.core.state.completedEffectIDs.contains(pendingOpen.context.effectID))
    #expect(driver.core.state.outstandingEffects[pendingOpen.context.effectID] == nil)
    #expect(driver.core.state.outstandingEffects[oldCheckpoint.context.effectID]?.effect == oldCheckpoint)

    let duplicate = driver.complete(pendingOpen)
    #expect(duplicate.disposition == .duplicate(effectID: pendingOpen.context.effectID))
    #expect(duplicate.effects.isEmpty)
    #expect(duplicate.invariantViolations.isEmpty)
  }

  @Test(arguments: [0, 1, 64])
  func successfulCancellationRetiresOnlyTheMatchingGeneration(count: Int) throws {
    var driver = Driver()
    try driver.loadPaused("fixture/cancel.mkv")
    let oldCheckpoint = try onlyEffect(driver.send(.command(.checkpoint)))
    let cancellation = try onlyEffect(driver.send(.command(.stop)))
    var matching: [PlaybackEffect] = []
    for _ in 0..<count {
      matching.append(try onlyEffect(driver.send(.command(.checkpoint))))
    }

    let completed = driver.complete(cancellation)
    expectAccepted(completed)
    #expect(completed.effects.isEmpty)
    #expect(driver.core.state.activeSession == nil)
    #expect(driver.core.state.outstandingEffects.count == 1)
    #expect(driver.core.state.outstandingEffects[oldCheckpoint.context.effectID]?.effect == oldCheckpoint)
    #expect(!driver.core.state.completedEffectIDs.contains(oldCheckpoint.context.effectID))
    for effect in matching {
      #expect(driver.core.state.completedEffectIDs.contains(effect.context.effectID))
      let duplicate = driver.complete(effect)
      #expect(duplicate.disposition == .duplicate(effectID: effect.context.effectID))
      #expect(duplicate.effects.isEmpty)
      #expect(duplicate.invariantViolations.isEmpty)
    }
  }

  @Test
  func failedCancellationDoesNotRetireOtherMatchingEffects() throws {
    var driver = Driver()
    try driver.loadPaused("fixture/cancel-failure.mkv")
    let cancellation = try onlyEffect(driver.send(.command(.stop)))
    let checkpoint = try onlyEffect(driver.send(.command(.checkpoint)))

    let failed = driver.complete(cancellation, kind: .failed)
    expectAccepted(failed)
    #expect(driver.core.state.activeSession?.phase == .failed)
    #expect(driver.core.state.outstandingEffects[checkpoint.context.effectID]?.effect == checkpoint)
    #expect(!driver.core.state.completedEffectIDs.contains(checkpoint.context.effectID))
  }

  private func session(id: UInt64) -> ActivePlaybackSession {
    ActivePlaybackSession(
      id: .init(rawValue: id),
      source: .init(rawValue: "fixture/seeded-\(id).mkv"),
      generation: .init(rawValue: 1),
      phase: .opening,
      desiredTransport: .paused,
      actualTransport: .stopped,
      activeOperationID: .init(rawValue: 1),
      loading: LoadingTransactionState()
    )
  }

  private func effect(id: UInt64, authority: PlaybackAuthority) -> PlaybackEffect {
    PlaybackEffect(
      executor: .persistence,
      context: .init(authority: authority, operationID: .init(rawValue: 1),
                     effectID: .init(rawValue: id)),
      kind: .persistCheckpoint
    )
  }

  private func onlyEffect(_ transition: PlaybackTransition) throws -> PlaybackEffect {
    expectAccepted(transition)
    #expect(transition.effects.count == 1)
    return try #require(transition.effects.first)
  }

  private func expectAccepted(_ transition: PlaybackTransition) {
    #expect(transition.disposition == .accepted)
    #expect(transition.invariantViolations.isEmpty)
  }

  /// Drives the real reducer; no executor or retirement behavior is modeled here.
  private struct Driver {
    var core: PlaybackCore
    private var sequence: UInt64 = 0

    init(state: PlaybackCoreState = PlaybackCoreState()) {
      core = PlaybackCore(state: state)
    }

    mutating func send(_ event: PlaybackEvent) -> PlaybackTransition {
      sequence += 1
      return core.update(.init(sequence: sequence, virtualTime: .init(ticks: 0), event: event))
    }

    mutating func complete(
      _ effect: PlaybackEffect, kind: EffectResultKind = .succeeded
    ) -> PlaybackTransition {
      send(.effectResult(.init(context: effect.context, token: .init(kind: kind))))
    }

    mutating func loadPaused(_ source: String) throws {
      let opening = send(.command(.load(source: .init(rawValue: source), autoplay: false)))
      #expect(opening.disposition == .accepted)
      #expect(opening.invariantViolations.isEmpty)
      let open = try #require(opening.effects.first)
      let prepared = complete(open)
      #expect(prepared.disposition == .accepted)
      #expect(prepared.invariantViolations.isEmpty)
      let preroll = try #require(prepared.effects.first)
      #expect(preroll.kind == .awaitPreroll)
      let committed = complete(preroll)
      #expect(committed.disposition == .accepted)
      #expect(committed.invariantViolations.isEmpty)
      #expect(core.state.activeSession?.phase == .paused)
      #expect(core.state.pendingSession == nil)
    }
  }
}
