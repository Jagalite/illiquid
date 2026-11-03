import Foundation
import IlliquidPlaybackModel
import Testing

/// The legacy runtime wrapper's `send` host policy (44722ec5), applied to
/// the model step: envelope sequence from 1, virtual time +ticks saturating
/// from the state's last time, and the dispatched-effect bookkeeping. Kept
/// only as a reference for `PlaybackSessionHost`.
private struct LegacyHostReference {
  var state: PlaybackDomainState
  var pendingEffects: [PlaybackEffect] = []
  var virtualTime: PlaybackInstant
  var nextSequence: UInt64 = 1

  init(state: PlaybackDomainState) {
    self.state = state
    virtualTime = state.lastVirtualTime
  }

  mutating func send(_ event: PlaybackEvent, advancingBy ticks: UInt64 = 1) -> PlaybackTransition {
    if UInt64.max - virtualTime.ticks >= ticks {
      virtualTime = PlaybackInstant(ticks: virtualTime.ticks + ticks)
    }
    let envelope = PlaybackEventEnvelope(sequence: nextSequence, virtualTime: virtualTime, event: event)
    if nextSequence < UInt64.max { nextSequence += 1 }
    let stepped = PlaybackProductionModel.step(state, envelope)
    state = stepped.state
    let transition = stepped.outputs[0]
    if case let .effectResult(result) = event,
      state.outstandingEffects[result.context.effectID] == nil,
      let index = pendingEffects.firstIndex(where: { $0.context == result.context })
    {
      pendingEffects.remove(at: index)
    }
    pendingEffects.removeAll { state.outstandingEffects[$0.context.effectID] == nil }
    pendingEffects.append(contentsOf: transition.effects.filter { $0.completion != .bestEffortMirror })
    return transition
  }
}

@Suite("Session host equivalence")
struct SessionHostEquivalenceTests {
  /// Every oracle event stream, driven through the live host, matches the
  /// legacy host policy step for step: transition, committed state, pending
  /// effects, sequence and virtual time.
  @Test func hostMatchesTheLegacyHostPolicyOnEveryOracleStream() throws {
    let fixture = try ProductionModelOracleTests.fixture()
    let starts = Dictionary(
      uniqueKeysWithValues: try ProductionOracle.decodedStarts(fixture.starts).map { ($0.name, $0.state) })
    var compared = 0
    for stream in fixture.streams {
      let start = try #require(starts[stream.start])
      let host = PlaybackSessionHost(state: start)
      var reference = LegacyHostReference(state: start)
      var generator = ProductionOracleStream(seed: stream.seed, state: start)
      for step in 0..<stream.steps {
        let event = generator.nextEnvelope().event
        let ticks = UInt64(1 + step % 3)
        let actual = host.send(event, advancingBy: ticks)
        let expected = reference.send(event, advancingBy: ticks)
        generator.observe(expected)
        guard actual == expected, host.state == reference.state,
          host.pendingEffects == reference.pendingEffects,
          host.nextSequence == reference.nextSequence, host.virtualTime == reference.virtualTime
        else {
          Issue.record("\(stream.start) seed \(stream.seed): host diverges at step \(step)")
          break
        }
        compared += 1
      }
      #expect(host.lastFault == nil)
      #expect(host.session.sequence == UInt64(stream.steps))
    }
    #expect(compared == fixture.streams.reduce(0) { $0 + $1.steps })
  }

  /// `complete` routes a result to the pending effect exactly as the legacy
  /// runtime did, and ignores effects that are not pending.
  @Test func completeRoutesOnlyPendingEffects() throws {
    let host = PlaybackSessionHost()
    var reference = LegacyHostReference(state: PlaybackDomainState())
    let load = PlaybackEvent.command(.load(source: MediaSourceIdentity(rawValue: "host.mkv"), autoplay: true))
    #expect(host.send(load) == reference.send(load))
    var settled = 0
    while let effect = reference.pendingEffects.first, settled < 16 {
      let result = PlaybackEvent.effectResult(
        PlaybackEffectResult(context: effect.context, token: EffectResultToken(kind: .succeeded)))
      let actual = host.complete(effectID: effect.context.effectID)
      reference.pendingEffects.removeFirst()
      #expect(actual == reference.send(result))
      #expect(host.state == reference.state)
      #expect(host.pendingEffects == reference.pendingEffects)
      settled += 1
    }
    #expect(host.complete(effectID: PlaybackEffectID(rawValue: 999_999)) == nil)
    #expect(host.state.activeSession?.phase == .playing)
  }
}
