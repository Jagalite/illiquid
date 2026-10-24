import Foundation
import Testing

@testable import IlliquidPlaybackCore

@Suite("Standard effect completion contracts")
struct StandardCompletionContractTests {
  @Test(arguments: [EffectResultKind.succeeded, .failed, .cancelled])
  func defaultEffectsAcceptEachStandardOutcomeOnce(kind: EffectResultKind) throws {
    var runtime = PlaybackModelRuntime()
    let load = runtime.send(
      .command(.load(source: .init(rawValue: "fixture/contract.mkv"), autoplay: false)))
    let effect = try #require(load.effects.first)

    // A known kind with extra scope is still a different, undeclared token.
    let rejected = runtime.send(.effectResult(.init(
      context: effect.context, token: .init(kind: kind, component: "unexpected"))))
    #expect(rejected.disposition == .invalid(reason: "undeclaredEffectResultToken"))
    #expect(runtime.core.state.outstandingEffects[effect.context.effectID] != nil)

    let result = PlaybackEffectResult(context: effect.context, token: .init(kind: kind))
    let completed = runtime.send(.effectResult(result))
    #expect(completed.disposition == .accepted)
    #expect(completed.invariantViolations.isEmpty)
    #expect(runtime.core.state.outstandingEffects[effect.context.effectID] == nil)
    #expect(runtime.core.state.containsCompletedEffect(effect.context.effectID))
    #expect(runtime.send(.effectResult(result)).disposition == .duplicate(
      effectID: effect.context.effectID))
  }

  @Test
  func extractedTerminalMutationIsIsolatedFromExistingAndFutureEffects() {
    let first = makeDefaultEffect()
    let second = makeDefaultEffect(id: 2)
    let original = first.completion
    guard case .oneShot(var extracted) = first.completion else {
      Issue.record("Default effects must have a one-shot completion contract")
      return
    }

    let custom = EffectResultToken(kind: .init(rawValue: "custom.done"))
    extracted.remove(.init(kind: .succeeded))
    extracted.insert(custom)
    let modified = EffectCompletionContract.oneShot(terminals: extracted)
    extracted.removeAll()

    #expect(first.completion == original)
    #expect(second.completion == original)
    #expect(makeDefaultEffect(id: 3).completion == original)
    #expect(EffectCompletionContract.standardOneShot == original)
    checkAdmission(original, accepted: [.init(kind: .succeeded)], rejected: [custom])
    checkAdmission(modified, accepted: [custom], rejected: [.init(kind: .succeeded)])
  }

  @Test
  func customOneShotKeepsItsExactTokens() throws {
    let scoped = EffectResultToken(
      kind: .succeeded,
      streamID: .init(kind: .video, demuxIndex: 2),
      graphRevision: .init(rawValue: 3),
      membershipRevision: .init(rawValue: 4),
      component: "renderer")
    var supplied: Set<EffectResultToken> = [scoped]
    let custom = EffectCompletionContract.oneShot(terminals: supplied)
    supplied.insert(.init(kind: .failed))
    supplied.remove(scoped)

    checkAdmission(custom, accepted: [scoped], rejected: [
      .init(kind: .succeeded), .init(kind: .failed), .init(kind: .cancelled),
      .init(kind: .succeeded, streamID: .init(kind: .video, demuxIndex: 2)),
    ])
    let decoded = try JSONDecoder().decode(
      EffectCompletionContract.self, from: JSONEncoder().encode(custom))
    #expect(decoded == custom)
  }

  @Test
  func phasedAndSubscriptionContractsRetainIndependentAdmissionRules() throws {
    let exact = EffectResultToken(kind: .init(rawValue: "phase.ready"))
    let callback = EffectResultToken(kind: .init(rawValue: "frame.available"))
    let alternate = EffectResultToken(kind: .init(rawValue: "frame.skipped"))
    let terminal = EffectResultToken(kind: .init(rawValue: "stream.finished"))
    var alternatives: Set<EffectResultToken> = [callback, alternate]
    var terminals: Set<EffectResultToken> = [terminal]
    let phased = EffectCompletionContract.phased(
      phases: [[.exactly(exact)], [.oneOf(alternatives)]], terminal: terminals)
    let subscription = EffectCompletionContract.subscription(
      id: .init(rawValue: 17), callbackKinds: alternatives, terminals: terminals)
    alternatives.removeAll()
    terminals.insert(.init(kind: .succeeded))

    let standardTokens = [EffectResultKind.succeeded, .failed, .cancelled].map {
      EffectResultToken(kind: $0)
    }
    checkAdmission(phased, accepted: [exact, callback, alternate, terminal], rejected: standardTokens)
    checkAdmission(
      subscription, accepted: [callback, alternate, terminal], rejected: standardTokens + [exact])
    for contract in [phased, subscription, .bestEffortMirror] {
      let decoded = try JSONDecoder().decode(
        EffectCompletionContract.self, from: JSONEncoder().encode(contract))
      #expect(decoded == contract)
    }
  }

  @Test
  func legacyCodableDataRoundTripsByValueRegardlessOfTerminalOrder() throws {
    // This is the pre-sharing Codable shape; Set element order is not a wire guarantee.
    let legacyJSON = [
      #"{"oneShot":{"terminals":[{"kind":"cancelled"},{"kind":"succeeded"},{"kind":"failed"}]}}"#,
      #"{"oneShot":{"terminals":[{"kind":"failed"},{"kind":"cancelled"},{"kind":"succeeded"}]}}"#,
    ]
    for json in legacyJSON {
      let decoded = try JSONDecoder().decode(
        EffectCompletionContract.self, from: Data(json.utf8))
      #expect(decoded == .standardOneShot)
      let roundTripped = try JSONDecoder().decode(
        EffectCompletionContract.self, from: JSONEncoder().encode(decoded))
      #expect(roundTripped == decoded)
    }
    let effect = makeDefaultEffect()
    let decodedEffect = try JSONDecoder().decode(
      PlaybackEffect.self, from: JSONEncoder().encode(effect))
    #expect(decodedEffect == effect)
  }

  @Test
  func canonicalReplayIsIndependentOfStandardTerminalSetConstruction() throws {
    var independentlyBuilt: Set<EffectResultToken> = []
    for kind in [EffectResultKind.cancelled, .failed, .succeeded] {
      independentlyBuilt.insert(.init(kind: kind))
    }
    let defaultEffect = makeDefaultEffect()
    let explicitEffect = makeEffect(completion: .oneShot(terminals: independentlyBuilt))

    for kind in [EffectResultKind.succeeded, .failed, .cancelled] {
      var shared = makeRuntime(for: defaultEffect)
      var independent = makeRuntime(for: explicitEffect)
      let result = PlaybackEffectResult(context: defaultEffect.context, token: .init(kind: kind))
      #expect(shared.send(.effectResult(result)).disposition == .accepted)
      #expect(independent.send(.effectResult(result)).disposition == .accepted)
      let sharedReplay = shared.replayDocument(illiquidRevision: "contract-test", seed: 42)
      let independentReplay = independent.replayDocument(illiquidRevision: "contract-test", seed: 42)
      #expect(sharedReplay == independentReplay)
      let encoded = try PlaybackReplayCodec.encode(sharedReplay)
      let independentEncoding = try PlaybackReplayCodec.encode(independentReplay)
      let decoded = try PlaybackReplayCodec.decode(encoded)
      #expect(encoded == independentEncoding)
      #expect(decoded == sharedReplay)
    }
  }

  private func makeDefaultEffect(id: UInt64 = 1) -> PlaybackEffect {
    PlaybackEffect(
      executor: .persistence,
      context: .init(
        authority: .application(.init(rawValue: 1)),
        operationID: .init(rawValue: 1),
        effectID: .init(rawValue: id)),
      kind: .persistCheckpoint)
  }

  private func makeEffect(completion: EffectCompletionContract) -> PlaybackEffect {
    let base = makeDefaultEffect()
    return PlaybackEffect(
      executor: base.executor, context: base.context, kind: base.kind, completion: completion)
  }

  private func makeRuntime(for effect: PlaybackEffect) -> PlaybackModelRuntime {
    PlaybackModelRuntime(state: .init(
      outstandingEffects: [effect.context.effectID: .init(effect: effect)],
      allocator: .init(nextOperation: 2, nextEffect: effect.context.effectID.rawValue + 1)))
  }

  private func checkAdmission(
    _ contract: EffectCompletionContract,
    accepted: [EffectResultToken],
    rejected: [EffectResultToken]
  ) {
    let effect = makeEffect(completion: contract)
    for token in accepted {
      var runtime = makeRuntime(for: effect)
      let transition = runtime.send(.effectResult(.init(context: effect.context, token: token)))
      #expect(transition.disposition == .accepted)
      #expect(transition.invariantViolations.isEmpty)
      #expect(runtime.core.state.outstandingEffects[effect.context.effectID] == nil)
    }
    for token in rejected {
      var runtime = makeRuntime(for: effect)
      let transition = runtime.send(.effectResult(.init(context: effect.context, token: token)))
      #expect(transition.disposition == .invalid(reason: "undeclaredEffectResultToken"))
      #expect(transition.invariantViolations.isEmpty)
      #expect(runtime.core.state.outstandingEffects[effect.context.effectID] != nil)
    }
  }
}
