public struct PlaybackModelRuntime: Sendable {
  public private(set) var core: PlaybackCore
  public private(set) var pendingEffects: [PlaybackEffect]
  public private(set) var steps: [PlaybackReplayStep]
  public private(set) var virtualTime: PlaybackInstant
  public private(set) var nextSequence: UInt64
  public let initialState: PlaybackCanonicalState
  public let recordsReplaySteps: Bool

  public init(
    state: PlaybackCoreState = PlaybackCoreState(),
    recordsReplaySteps: Bool = true
  ) {
    core = PlaybackCore(state: state)
    pendingEffects = []
    steps = []
    virtualTime = state.lastVirtualTime
    nextSequence = 1
    initialState = PlaybackCanonicalState(state: state)
    self.recordsReplaySteps = recordsReplaySteps
  }

  @discardableResult
  public mutating func send(
    _ event: PlaybackEvent,
    advancingBy ticks: UInt64 = 1
  ) -> PlaybackTransition {
    if UInt64.max - virtualTime.ticks >= ticks {
      virtualTime = PlaybackInstant(ticks: virtualTime.ticks + ticks)
    }
    let envelope = PlaybackEventEnvelope(
      sequence: nextSequence,
      virtualTime: virtualTime,
      event: event
    )
    if nextSequence < UInt64.max { nextSequence += 1 }

    let preState = recordsReplaySteps ? PlaybackCanonicalState(state: core.state) : nil
    let transition = core.update(envelope)
    if case let .effectResult(result) = event,
      core.state.outstandingEffects[result.context.effectID] == nil,
      let completedIndex = pendingEffects.firstIndex(where: {
        $0.context == result.context
      })
    {
      pendingEffects.remove(at: completedIndex)
    }
    pendingEffects.removeAll {
      core.state.outstandingEffects[$0.context.effectID] == nil
    }
    pendingEffects.append(
      contentsOf: transition.effects.filter {
        $0.completion != .bestEffortMirror
      })
    if let preState {
      let postState = PlaybackCanonicalState(state: core.state)
      steps.append(
        PlaybackReplayStep(
          envelope: envelope,
          disposition: transition.disposition,
          preState: preState,
          postState: postState,
          preStateDigest: PlaybackReplayCodec.digest(preState),
          postStateDigest: PlaybackReplayCodec.digest(postState),
          generatedEffects: transition.effects,
          invariantResults: transition.invariantViolations
        ))
    }
    return transition
  }

  @discardableResult
  public mutating func complete(
    effectID: PlaybackEffectID,
    token: EffectResultToken = EffectResultToken(kind: .succeeded),
    failure: PlaybackFailure? = nil,
    advancingBy ticks: UInt64 = 1
  ) -> PlaybackTransition? {
    guard
      let index = pendingEffects.firstIndex(where: {
        $0.context.effectID == effectID
      })
    else { return nil }
    let effect = pendingEffects.remove(at: index)
    return send(
      .effectResult(
        PlaybackEffectResult(
          context: effect.context,
          token: token,
          failure: failure
        )),
      advancingBy: ticks
    )
  }

  @discardableResult
  public mutating func completeNext(
    at index: Int = 0,
    token: EffectResultToken = EffectResultToken(kind: .succeeded)
  ) -> PlaybackTransition? {
    guard pendingEffects.indices.contains(index) else { return nil }
    return complete(effectID: pendingEffects[index].context.effectID, token: token)
  }

  public func replayDocument(
    superplayrRevision: String,
    seed: UInt64,
    shrinkHistory: [PlaybackReplayShrinkRecord] = []
  ) -> PlaybackReplayDocument {
    let staleSequences = steps.compactMap { step -> UInt64? in
      if case .stale = step.disposition { return step.envelope.sequence }
      return nil
    }
    let firstFailure = steps.compactMap { step -> PlaybackReplayFailure? in
      guard let violation = step.invariantResults.first else { return nil }
      return PlaybackReplayFailure(
        invariantName: violation.name,
        step: step.envelope.sequence,
        details: violation.details
      )
    }.first
    return PlaybackReplayDocument(
      superplayrRevision: superplayrRevision,
      seed: seed,
      initialState: initialState,
      steps: steps,
      finalState: PlaybackCanonicalState(state: core.state),
      rejectedStaleEvents: staleSequences,
      failedInvariant: firstFailure,
      shrinkHistory: shrinkHistory
    )
  }
}

public struct SeededPlaybackGenerator: Sendable {
  public private(set) var state: UInt64

  public init(seed: UInt64) {
    state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
  }

  public mutating func next() -> UInt64 {
    state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    return state
  }

  public mutating func nextCommand(for coreState: PlaybackCoreState) -> PlaybackCommand {
    guard coreState.lifecycle == .running else { return .shutdown }
    guard coreState.activeSession != nil else {
      return .load(
        source: MediaSourceIdentity(rawValue: "fixture-\(next() % 8)"),
        autoplay: next() % 2 == 0
      )
    }

    switch next() % 7 {
    case 0: return .play
    case 1: return .pause
    case 2:
      let validTime = ValidMediaTime(value: Int64(next() % 300_000), timescale: 1_000)
      return .seek(
        target: validTime.map(MediaTimestamp.valid) ?? .invalid(.zeroTimescale),
        mode: [.relative, .keyframe, .exact, .preview][Int(next() % 4)]
      )
    case 3: return .stop
    case 4:
      return .load(
        source: MediaSourceIdentity(rawValue: "fixture-\(next() % 8)"),
        autoplay: true
      )
    case 5: return .shutdown
    default: return .play
    }
  }

  public mutating func shouldMutateResult(percent: UInt64 = 10) -> Bool {
    next() % 100 < percent
  }
}

public enum PlaybackReplayShrinker {
  public static func deletionCandidates(
    for envelopes: [PlaybackEventEnvelope]
  ) -> [[PlaybackEventEnvelope]] {
    guard envelopes.count > 1 else { return [] }
    var candidates: [[PlaybackEventEnvelope]] = []
    var chunkSize = envelopes.count / 2
    while chunkSize > 0 {
      var start = 0
      while start < envelopes.count {
        let end = min(start + chunkSize, envelopes.count)
        var candidate = envelopes
        candidate.removeSubrange(start..<end)
        if !candidate.isEmpty { candidates.append(candidate) }
        start += chunkSize
      }
      chunkSize /= 2
    }
    return candidates
  }
}
