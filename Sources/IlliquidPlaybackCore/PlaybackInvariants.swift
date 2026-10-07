public struct PlaybackInvariantViolation: Codable, Equatable, Sendable {
  public let name: String
  public let details: String

  public init(name: String, details: String) {
    self.name = name
    self.details = details
  }
}

public enum PlaybackInvariantChecker {
  public static func check(
    state: PlaybackCoreState,
    emittedEffects: [PlaybackEffect] = []
  ) -> [PlaybackInvariantViolation] {
    var violations: [PlaybackInvariantViolation] = []

    if state.lifecycle == .terminated {
      if state.activeSession != nil {
        violations.append(
          .init(
            name: "terminatedHasNoSession",
            details: "A terminated core retained an active playback session."
          ))
      }
      if state.pendingSession != nil {
        violations.append(
          .init(
            name: "terminatedHasNoPendingSession",
            details: "A terminated core retained a pending playback session."
          ))
      }
      if !state.outstandingEffects.isEmpty {
        violations.append(
          .init(
            name: "terminatedHasNoOutstandingEffects",
            details: "A terminated core retained outstanding effects."
          ))
      }
      if !state.resourceLeases.isEmpty {
        violations.append(
          .init(
            name: "terminatedHasNoLeases",
            details: "A terminated core retained resource leases."
          ))
      }
      if !emittedEffects.isEmpty {
        violations.append(
          .init(
            name: "terminatedEmitsNoEffects",
            details: "A terminated transition emitted runtime work."
          ))
      }
    }

    if state.activeSession?.actualTransport == .playing,
      state.activeSession?.phase != .playing
    {
      violations.append(
        .init(
          name: "playingRequiresPlayingPhase",
          details: "Actual playing transport requires the playing machine phase."
        ))
    }

    if state.activeSession?.actualTransport == .playing,
      state.activeSession?.synchronization.startupAcknowledged != true
    {
      violations.append(
        .init(
          name: "playingRequiresCurrentPreroll",
          details: "Actual playing transport requires the current startup preroll obligation."
        ))
    }

    if state.activeSession == nil,
      state.pendingSession == nil,
      state.lifecycle == .running,
      emittedEffects.contains(where: { effect in
        if case .playback = effect.context.authority { return true }
        return false
      })
    {
      violations.append(
        .init(
          name: "playbackEffectRequiresSession",
          details: "A playback-authority effect was emitted without an active session."
        ))
    }

    for (effectID, record) in state.outstandingEffects {
      if effectID != record.effect.context.effectID {
        violations.append(
          .init(
            name: "outstandingEffectKeyMatchesContext",
            details: "Outstanding effect key and effect context disagree."
          ))
      }
      if state.completedEffectIDs.contains(effectID) {
        violations.append(
          .init(
            name: "completedEffectIsNotOutstanding",
            details: "Effect \(effectID.rawValue) is both completed and outstanding."
          ))
      }
    }

    for (key, lease) in state.resourceLeases {
      if key != lease.key {
        violations.append(
          .init(
            name: "leaseKeyMatchesRecord",
            details: "Resource lease dictionary key and record disagree."
          ))
      }
      if lease.inFlightUseCount < 0 {
        violations.append(
          .init(
            name: "leaseUseCountNonnegative",
            details: "A resource lease has a negative in-flight use count."
          ))
      }
      if lease.physicalReleaseObserved,
        !lease.releaseRequested || !lease.activeBorrows.isEmpty || lease.inFlightUseCount != 0
      {
        violations.append(
          .init(
            name: "physicalReleaseRequiresQuiescence",
            details: "A lease was physically released before requests, borrows, and uses settled."
          ))
      }
    }

    if state.lifecycle == .shuttingDown,
      emittedEffects.contains(where: { !$0.isCleanup })
    {
      violations.append(
        .init(
          name: "shutdownEmitsCleanupOnly",
          details: "A shutting-down core emitted non-cleanup work."
        ))
    }

    var exclusiveKeys: Set<String> = []
    for effect in emittedEffects {
      guard let key = effect.exclusiveKey else { continue }
      if !exclusiveKeys.insert(key).inserted {
        violations.append(
          .init(
            name: "noConflictingExclusiveEffects",
            details: "More than one effect used exclusive key \(key)."
          ))
      }
    }

    return violations
  }
}
