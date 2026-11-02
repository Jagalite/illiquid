import Statelessness

/// The host side of the production model contract.
///
/// The host turns live observations into concrete envelopes (sequence numbers
/// and monotonic virtual time are host policy, not library clock reads),
/// submits each one to a Statelessness `ExecutionSession`, and keeps the list
/// of dispatched effects whose results it still has to route back. It owns no
/// playback state and implements no rules: the committed state is the
/// session's, and every decision is made by `PlaybackProductionModel.step`.
///
/// Like the session it wraps, a host is confined to one isolation domain (the
/// player's main actor). There is no retained step history; attach a bounded
/// Statelessness `Recorder` to keep a replayable trace.
public final class PlaybackSessionHost {
  public let session: PlaybackSession
  /// Effects handed to executors whose terminal result is still expected.
  public private(set) var pendingEffects: [PlaybackEffect] = []
  public private(set) var virtualTime: PlaybackInstant
  public private(set) var nextSequence: UInt64
  /// The last session fault, if a submission was refused. Faults commit
  /// nothing; the host reports them as rejected transitions.
  public private(set) var lastFault: ExecutionFault?

  public init(state: PlaybackDomainState = PlaybackDomainState(), recorder: Recorder? = nil) {
    do {
      session = try PlaybackProductionModel.session(state: state, recorder: recorder)
    } catch {
      // The production model's checkpoint checks and value clones cannot throw.
      preconditionFailure("playback session restore failed: \(error)")
    }
    virtualTime = state.lastVirtualTime
    nextSequence = 1
  }

  /// The committed playback state (a value copy).
  public var state: PlaybackDomainState {
    do { return try session.snapshot() } catch {
      preconditionFailure("playback state snapshot failed: \(error)")
    }
  }

  /// Submits one event and returns the committed transition.
  @discardableResult
  public func send(_ event: PlaybackEvent, advancingBy ticks: UInt64 = 1) -> PlaybackTransition {
    if UInt64.max - virtualTime.ticks >= ticks {
      virtualTime = PlaybackInstant(ticks: virtualTime.ticks + ticks)
    }
    let envelope = PlaybackEventEnvelope(sequence: nextSequence, virtualTime: virtualTime, event: event)
    if nextSequence < UInt64.max { nextSequence += 1 }

    let transition: PlaybackTransition
    do {
      let turn = try session.submit(envelope)
      transition = turn.outputs[0]
      lastFault = nil
    } catch {
      lastFault = error as? ExecutionFault ?? .model(String(describing: error))
      return PlaybackTransition(
        disposition: .invalid(reason: "sessionFault"),
        effects: [],
        snapshot: PlaybackUISnapshot(state: state),
        invariantViolations: [])
    }

    let committed = state
    if case let .effectResult(result) = event,
      committed.outstandingEffects[result.context.effectID] == nil,
      let index = pendingEffects.firstIndex(where: { $0.context == result.context })
    {
      pendingEffects.remove(at: index)
    }
    pendingEffects.removeAll { committed.outstandingEffects[$0.context.effectID] == nil }
    pendingEffects.append(contentsOf: transition.effects.filter { $0.completion != .bestEffortMirror })
    return transition
  }

  /// Delivers a result for a pending effect, if it is still pending.
  @discardableResult
  public func complete(
    effectID: PlaybackEffectID,
    token: EffectResultToken = EffectResultToken(kind: .succeeded),
    failure: PlaybackFailure? = nil,
    advancingBy ticks: UInt64 = 1
  ) -> PlaybackTransition? {
    guard let index = pendingEffects.firstIndex(where: { $0.context.effectID == effectID }) else {
      return nil
    }
    let effect = pendingEffects.remove(at: index)
    return send(
      .effectResult(PlaybackEffectResult(context: effect.context, token: token, failure: failure)),
      advancingBy: ticks)
  }

  @discardableResult
  public func completeNext(
    at index: Int = 0,
    token: EffectResultToken = EffectResultToken(kind: .succeeded)
  ) -> PlaybackTransition? {
    guard pendingEffects.indices.contains(index) else { return nil }
    return complete(effectID: pendingEffects[index].context.effectID, token: token)
  }
}
