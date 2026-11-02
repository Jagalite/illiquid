import Statelessness

/// The playback state machine as a native Statelessness model.
///
/// `step` is the single definition of playback behavior: the live player
/// submits concrete envelopes to an `ExecutionSession` built from `make()`,
/// and verification explores the same callback. There is no engine object
/// behind it; Statelessness owns execution and the committed state.
public typealias PlaybackModel = Model<PlaybackDomainState, PlaybackEventEnvelope, PlaybackTransition>
public typealias PlaybackSession = ExecutionSession<PlaybackDomainState, PlaybackEventEnvelope, PlaybackTransition>

public enum PlaybackProductionModel {
  public static let name = "illiquid-playback-production"
  public static let modelVersion: UInt32 = 1
  public static let propertiesVersion: UInt32 = 1
  public static let codecVersion: UInt32 = 1

  /// One playback turn. Invariants are checked on the candidate together with
  /// the effects it emits, before the turn is returned, and a violation moves
  /// the lifecycle to `invariantFailed` inside the same turn. The violations
  /// travel in the output; the model's transition check reports them without
  /// re-running this function.
  public static func step(
    _ state: PlaybackDomainState,
    _ envelope: PlaybackEventEnvelope
  ) -> Transition<PlaybackDomainState, PlaybackTransition> {
    var next = state
    let output = turn(&next, envelope)
    return Transition(state: next, outputs: [output], disposition: disposition(output.disposition))
  }

  static func turn(
    _ state: inout PlaybackDomainState,
    _ envelope: PlaybackEventEnvelope
  ) -> PlaybackTransition {
    if state.lifecycle == .terminated {
      return state.transition(disposition: .ignoredAfterTermination, effects: [])
    }

    guard envelope.virtualTime >= state.lastVirtualTime else {
      state.rejectedEventCount += 1
      return state.transition(disposition: .invalid(reason: "virtualTimeRegressed"), effects: [])
    }
    state.lastVirtualTime = envelope.virtualTime

    if state.lifecycle == .shuttingDown, !state.isAllowedDuringShutdown(envelope.event) {
      state.rejectedEventCount += 1
      return state.transition(
        disposition: .invalid(reason: "eventRejectedDuringShutdown"), effects: [])
    }

    let reduction: (EventDisposition, [PlaybackEffect])
    switch envelope.event {
    case .command(let command):
      reduction = state.reduce(command)
    case .effectResult(let result):
      reduction = state.reduce(result)
    case .deadlineReached(let operationID):
      reduction = state.reduceDeadline(operationID)
    case .diagnosticObserved:
      state.diagnosticEventCount += 1
      reduction = (.accepted, [])
    case .subtitle(let event):
      reduction = state.reduce(event)
    case .acceptedClockSample(let timestamp):
      reduction = state.acceptClockSample(timestamp)
    case .audioOutputChanged(let timestamp):
      if let session = state.activeSession,
        state.pendingSession == nil,
        !session.lifecycleState.resumeAfterWake,
        [.playing, .paused, .buffering, .seeking, .prerolling, .draining].contains(session.phase)
      {
        // Route changes are repeatable lifecycle observations, not decoder
        // failures. An in-flight user seek retains its target. The existing
        // exact-seek barriers flush/re-preroll both streams and preserve intent.
        reduction = state.beginSeek(target: session.seek?.target ?? timestamp, mode: .exact)
      } else {
        reduction = (.accepted, [])
      }
    case .durationObserved(let timestamp):
      reduction = state.acceptDuration(timestamp)
    case .catalogObserved(let catalog):
      reduction = state.observeCatalog(catalog)
    case .demuxEndOfFile(let required):
      reduction = state.beginDrain(required: required)
    case .drainObserved(let component):
      reduction = state.observeDrain(component)
    case .failureObserved(let failure):
      reduction = state.observeFailure(failure)
    case .synchronization(let event):
      reduction = state.observeSynchronization(event)
    case .lifecycle(let event):
      reduction = state.observeLifecycle(event)
    }

    switch reduction.0 {
    case .accepted:
      state.acceptedEventCount += 1
      state.snapshotRevision += 1
    case .duplicate, .stale, .invalid, .ignoredAfterTermination:
      state.rejectedEventCount += 1
    }

    state.register(reduction.1)
    let violations = PlaybackInvariantChecker.check(state: state, emittedEffects: reduction.1)
    if !violations.isEmpty {
      state.lifecycle = .invariantFailed
    }

    return PlaybackTransition(
      disposition: reduction.0,
      effects: reduction.1,
      snapshot: PlaybackUISnapshot(state: state),
      invariantViolations: violations
    )
  }

  /// Statelessness's classification of the richer playback disposition, which
  /// the output keeps verbatim.
  public static func disposition(_ disposition: EventDisposition) -> Disposition {
    switch disposition {
    case .accepted: .accepted
    case .duplicate(let effectID): .rejected("duplicate:\(effectID.rawValue)")
    case .stale(let reason): .rejected("stale:\(reason.rawValue)")
    case .invalid(let reason): .rejected("invalid:\(reason)")
    case .ignoredAfterTermination: .ignored("afterTermination")
    }
  }

  /// Property checks for one turn: each invariant violation the step reported
  /// is a failed check; a clean turn records one passed check.
  public static func checks(_ transition: Transition<PlaybackDomainState, PlaybackTransition>) -> [Check] {
    let violations = transition.outputs.flatMap(\.invariantViolations)
    guard !violations.isEmpty else { return [Check("playback.invariants")] }
    return violations.map {
      Check("playback.invariant.\($0.name)", .failed, $0.details.isEmpty ? $0.name : $0.details)
    }
  }

  public static var metadata: Metadata {
    Metadata(
      name: name, modelVersion: modelVersion, propertiesVersion: propertiesVersion,
      codecVersion: codecVersion, build: "illiquid-playback-model")
  }

  /// The production model. Values are Swift value types, so clones are copies.
  public static func make(initialState: PlaybackDomainState = PlaybackDomainState()) -> PlaybackModel {
    Model(
      initialState: { initialState },
      step: { state, envelope in step(state, envelope) },
      checkState: { _ in [] },
      cloneState: { $0 },
      cloneInput: { $0 },
      cloneOutput: { $0 },
      checkTransition: { _, _, transition in checks(transition) },
      equalStates: { $0 == $1 },
      codec: PlaybackProductionCodec.codec)
  }

  /// A live session over the production model, starting from `state`.
  public static func session(
    state: PlaybackDomainState = PlaybackDomainState(),
    sequence: UInt64 = 0,
    recorder: Recorder? = nil
  ) throws -> PlaybackSession {
    try ExecutionSession(model: make(initialState: state), checkpoint: state, sequence: sequence, recorder: recorder)
  }
}
