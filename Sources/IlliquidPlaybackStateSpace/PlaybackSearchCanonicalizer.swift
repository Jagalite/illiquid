import Foundation
import IlliquidPlaybackCore

public struct PlaybackSearchStateKey: Codable, Hashable, Sendable {
  public let model: PlaybackSearchModel
  public let seedProfile: String
  public let lifecycle: String
  public let externalWait: String
  public let session: NormalizedSessionKey?
  public let pendingSession: NormalizedPendingSessionKey?
  public let lastLoadFailure: String
  public let effects: [NormalizedEffectKey]
  public let lateResults: [NormalizedEffectKey]
  public let leases: [String]
  public let environment: PlaybackModelEnvironment
  public let ghost: PlaybackSearchGhost
}

public struct NormalizedPendingSessionKey: Codable, Hashable, Sendable {
  public let source: String
  public let phase: String
  public let desiredTransport: String
  public let loading: String
}

public struct NormalizedSessionKey: Codable, Hashable, Sendable {
  public let source: String
  public let phase: String
  public let desiredTransport: String
  public let actualTransport: String
  public let position: String
  public let duration: String
  public let loading: String
  public let seek: String
  public let drain: String
  public let recovery: String
  public let synchronization: String
  public let tracks: String
  public let subtitles: String
  public let controls: String
  public let revisions: String
}

public struct NormalizedEffectKey: Codable, Hashable, Comparable, Sendable {
  public let authority: String
  public let operation: String
  public let executor: String
  public let kind: String
  public let completion: String
  public let acceptedTokens: [String]
  public let isCleanup: Bool
  public let exclusiveClass: String

  public static func < (lhs: Self, rhs: Self) -> Bool {
    lhs.stableDescription < rhs.stableDescription
  }

  public var stableDescription: String {
    [
      authority, operation, executor, kind, completion, acceptedTokens.joined(separator: ","),
      isCleanup ? "cleanup" : "work", exclusiveClass,
    ].joined(separator: "|")
  }
}

public enum PlaybackSearchCanonicalizer {
  @inline(never)
  public static func key(
    for node: PlaybackSearchNode,
    previousKey: PlaybackSearchStateKey? = nil
  ) -> PlaybackSearchStateKey {
    _ = previousKey
    let active = node.coreState.activeSession
    let records = node.coreState.outstandingEffects.values.map { record in
      normalize(record: record, active: active)
    }.sorted()
    let late = node.lateResults.map {
      normalize(effect: $0.effect, acceptedTokens: [], active: active)
    }.sorted()
    let leases = node.coreState.resourceLeases.values.map { lease in
      let authority = normalize(authority: lease.authority, active: active)
      return [
        authority, lease.storageExecutor.rawValue, lease.currentCustodian.rawValue,
        lease.releaseRequested ? "requested" : "held",
        lease.physicalReleaseObserved ? "released" : "not-released",
        lease.activeBorrows.isEmpty ? "no-borrows" : "borrowed",
        lease.inFlightUseCount == 0 ? "idle" : "in-use",
      ].joined(separator: "|")
    }.sorted()
    return PlaybackSearchStateKey(
      model: node.model,
      seedProfile: node.seedProfile,
      lifecycle: node.coreState.lifecycle.rawValue,
      externalWait: node.coreState.externalWaitReason?.rawValue ?? "none",
      session: active.map(normalize(session:)),
      pendingSession: node.coreState.pendingSession.map {
        normalize(pendingSession: $0.value)
      },
      lastLoadFailure: node.coreState.lastLoadFailure.map(failureClass) ?? "none",
      effects: records,
      lateResults: late,
      leases: leases,
      environment: node.environment,
      ghost: node.ghost
    )
  }

  public static func digest(_ key: PlaybackSearchStateKey) -> String {
    let data = Data(stableDescription(key).utf8)
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in data {
      hash ^= UInt64(byte)
      hash &*= 1_099_511_628_211
    }
    return "fnv1a64:" + String(hash, radix: 16).leftPadding(toLength: 16, withPad: "0")
  }

  private static func stableDescription(_ key: PlaybackSearchStateKey) -> String {
    var parts = [key.model.rawValue, key.seedProfile, key.lifecycle, key.externalWait]
    if let session = key.session {
      parts += [
        session.source, session.phase, session.desiredTransport, session.actualTransport,
        session.position, session.duration, session.loading, session.seek, session.drain,
        session.recovery, session.synchronization, session.tracks, session.subtitles,
        session.controls, session.revisions,
      ]
    } else {
      parts.append("no-session")
    }
    if let pendingSession = key.pendingSession {
      parts += [
        "pending", pendingSession.source, pendingSession.phase,
        pendingSession.desiredTransport, pendingSession.loading,
      ]
    } else {
      parts.append("no-pending-session")
    }
    parts.append("load-failure:\(key.lastLoadFailure)")
    parts += key.effects.map(\.stableDescription)
    parts += key.lateResults.map { "late:" + $0.stableDescription }
    parts += key.leases
    parts.append(environmentDescription(key.environment))
    parts += [
      "churn:\(key.ghost.generationChurn)",
      "duplicates:\(key.ghost.duplicateClasses.sorted().joined(separator: ","))",
      "shutdown:\(key.ghost.everShutdown)", "advance:\(key.ghost.playlistAdvanceCount.rawValue)",
      "wait:\(key.ghost.externalWait?.rawValue ?? "none")",
    ]
    return parts.joined(separator: "\u{1f}")
  }

  private static func environmentDescription(_ environment: PlaybackModelEnvironment) -> String {
    switch environment {
    case .seek(let value):
      return [
        "seek", value.prerequisites.map(\.rawValue).sorted().joined(separator: ","),
        String(value.generationChurn), String(value.interrupts), String(value.eofCycles),
        value.playlistAdvanceCount.rawValue, String(value.oldOutputPresented),
      ].joined(separator: "|")
    case .eofDrain(let value):
      return [
        "eof", value.playlistAdvanceCount.rawValue, String(value.generationChurn),
        String(value.interrupts), value.externalWait?.rawValue ?? "none",
      ].joined(separator: "|")
    case .recovery(let value):
      return [
        "recovery", value.prerequisites.map(\.rawValue).sorted().joined(separator: ","),
        value.decoder.rawValue, value.presenter.rawValue,
        String(value.failures), String(value.generationChurn),
        String(value.interrupts), String(value.oldOutputPresented),
      ].joined(separator: "|")
    case .trackSubtitles(let value):
      return [
        "track", value.prerequisites.map(\.rawValue).sorted().joined(separator: ","),
        String(value.generationChurn), String(value.interrupts),
        String(value.invalidations), String(value.oldOverlayAccepted),
      ].joined(separator: "|")
    case .stopShutdown(let value):
      let cleanup = value.cleanupApplications.keys.sorted().map {
        "\($0)=\(value.cleanupApplications[$0]!.rawValue)"
      }.joined(separator: ",")
      return [
        "shutdown", String(value.everShutdown), cleanup,
        value.externalWait?.rawValue ?? "none", String(value.resourcesReturned),
      ].joined(separator: "|")
    case .prerollBuffering(let value):
      return [
        "preroll", value.videoQueue.rawValue, value.audioQueue.rawValue,
        String(value.startupSatisfied), String(value.interrupts),
      ].joined(separator: "|")
    }
  }

  @inline(never)
  private static func normalize(session: ActivePlaybackSession) -> NormalizedSessionKey {
    let synchronization = session.synchronization
    let required = synchronization.required.map(\.rawValue).sorted().joined(separator: ",")
    let prerolled = synchronization.prerolled.map(\.rawValue).sorted().joined(separator: ",")
    let drainRequired = session.drain.required.map(\.rawValue).sorted().joined(separator: ",")
    let drainObserved = session.drain.observed.map(\.rawValue).sorted().joined(separator: ",")
    let seek =
      session.seek.map {
        [
          relation($0.generation.rawValue, to: session.generation.rawValue),
          timeClass($0.target), $0.mode.rawValue, String(describing: $0.phase),
          $0.pendingBarriers.map(\.rawValue).sorted().joined(separator: ","),
        ]
        .joined(separator: "|")
      } ?? "none"
    let loading =
      session.loading.map {
        let catalog =
          $0.catalog.map {
            "v:\($0.hasVideo)|a:\($0.audio.isEmpty ? "0" : "some")|s:\($0.subtitles.isEmpty ? "0" : "some")"
          } ?? "none"
        return "\($0.phase.rawValue)|\(catalog)"
      } ?? "none"
    let recovery = [
      session.recovery.videoLineage.map {
        "\($0.streamID.kind.rawValue):\(indexClass($0.streamID.demuxIndex))"
      } ?? "none",
      "vf:\(session.recovery.consumedVideoFallbackLineages.isEmpty ? 0 : 1)",
      "pf:\(session.recovery.presentationFlushConsumed.isEmpty ? 0 : 1)",
      "gr:\(session.recovery.presentationGraphRebuildCount)",
      session.recovery.lastFailure.map(failureClass) ?? "none",
    ].joined(separator: "|")
    let tracks = [
      intentClass(session.tracks.requestedAudio), intentClass(session.tracks.effectiveAudio),
      subtitleIntentClass(session.tracks.requestedSubtitle),
      subtitleIntentClass(session.tracks.effectiveSubtitle), session.tracks.phase.rawValue,
      session.tracks.requestedAudio == session.tracks.effectiveAudio
        ? "audio-same" : "audio-different",
      session.tracks.requestedSubtitle == session.tracks.effectiveSubtitle
        ? "subtitle-same" : "subtitle-different",
    ].joined(separator: "|")
    let subtitles = [
      session.subtitles.pendingVisibleClear == nil ? "clear-settled" : "clear-pending",
      session.subtitles.pendingSourceInvalidation == nil ? "source-settled" : "source-pending",
      revisionRelation(
        session.subtitles.lastAcceptedOverlayRevision, session.subtitles.overlayRevision),
      session.subtitles.installedSource == nil
        ? "none" : (session.subtitles.installedSourceIsExternal ? "external" : "embedded"),
      delayClass(session.subtitles.appliedDelayMicroseconds),
    ].joined(separator: "|")
    let revisions = [
      session.revisions.track == nil ? "t0" : "t1",
      session.revisions.decoder == nil ? "d0" : "d1",
      session.revisions.videoFormat == nil ? "vf0" : "vf1",
      session.revisions.audioFormat == nil ? "af0" : "af1",
      session.revisions.presentation == nil ? "p0" : "p1",
      session.revisions.presentationGraph == nil ? "pg0" : "pg1",
      session.revisions.presentationMembership == nil ? "pm0" : "pm1",
      session.revisions.subtitle == session.subtitles.subtitleRevision ? "s-current" : "s-other",
      session.revisions.overlay == session.subtitles.overlayRevision ? "o-current" : "o-other",
      session.revisions.surface == nil ? "sf0" : "sf1",
    ].joined(separator: "|")
    return NormalizedSessionKey(
      source: session.source.rawValue.isEmpty ? "invalid-empty" : "primary",
      phase: session.phase.rawValue,
      desiredTransport: session.desiredTransport.rawValue,
      actualTransport: session.actualTransport.rawValue,
      position: timeClass(session.logicalPosition), duration: timeClass(session.duration),
      loading: loading, seek: seek,
      drain: "\(drainRequired)|\(drainObserved)|\(session.drain.finalized)",
      recovery: recovery,
      synchronization: [
        required, prerolled, String(synchronization.desiredMilliRate),
        String(synchronization.appliedMilliRate),
        synchronization.startupAcknowledged ? "ready" : "waiting",
        synchronization.isBuffering ? "buffering" : "supplied",
        cacheClass(synchronization.cacheMicroseconds),
      ]
      .joined(separator: "|"),
      tracks: tracks, subtitles: subtitles,
      controls:
        "\(delayClass(session.controls.requestedSubtitleDelayMicroseconds))|\(delayClass(session.controls.appliedSubtitleDelayMicroseconds))",
      revisions: revisions
    )
  }

  private static func normalize(
    pendingSession: ActivePlaybackSession
  ) -> NormalizedPendingSessionKey {
    NormalizedPendingSessionKey(
      source: pendingSession.source.rawValue.isEmpty ? "invalid-empty" : "primary",
      phase: pendingSession.phase.rawValue,
      desiredTransport: pendingSession.desiredTransport.rawValue,
      loading: pendingSession.loading?.phase.rawValue ?? "none"
    )
  }

  private static func normalize(
    record: OutstandingEffectRecord,
    active: ActivePlaybackSession?
  ) -> NormalizedEffectKey {
    normalize(effect: record.effect, acceptedTokens: record.acceptedTokens, active: active)
  }

  private static func normalize(
    effect: PlaybackEffect,
    acceptedTokens: Set<EffectResultToken>,
    active: ActivePlaybackSession?
  ) -> NormalizedEffectKey {
    NormalizedEffectKey(
      authority: normalize(authority: effect.context.authority, active: active),
      operation: effect.context.operationID == active?.activeOperationID ? "active" : "other",
      executor: effect.executor.rawValue,
      kind: effectKindClass(effect.kind, active: active),
      completion: completionClass(effect.completion),
      acceptedTokens: acceptedTokens.map(tokenClass).sorted(),
      isCleanup: effect.isCleanup,
      exclusiveClass: exclusiveClass(effect.exclusiveKey)
    )
  }

  private static func normalize(
    authority: PlaybackAuthority,
    active: ActivePlaybackSession?
  ) -> String {
    switch authority {
    case .application: return "application"
    case .playback(let sessionID, let generation, let revisions):
      guard let active else { return "unrelated-playback" }
      let session = sessionID == active.id ? "current-session" : "unrelated-session"
      let generation = relation(generation.rawValue, to: active.generation.rawValue)
      let revision = revisions == active.revisions ? "current-revisions" : "other-revisions"
      return "\(session)|\(generation)|\(revision)"
    }
  }

  private static func effectKindClass(
    _ kind: PlaybackEffectKind,
    active: ActivePlaybackSession?
  ) -> String {
    switch kind {
    case .openSource(let source): return "open:\(source.rawValue.isEmpty ? "invalid" : "primary")"
    case .probeSource: return "probe"
    case .configureSession(let selection):
      return
        "configure:\(selection.audio == nil ? "a0" : "a1"):\(selection.subtitle == nil ? "s0" : "s1")"
    case .awaitPreroll: return "await-preroll"
    case .applyRate(let rate): return "rate:\(rate)"
    case .seekPipeline(let target, let mode):
      return "seek-pipeline:\(timeClass(target)):\(mode.rawValue)"
    case .seek(let target, let mode): return "seek:\(timeClass(target)):\(mode.rawValue)"
    case .applyAudioSelection(let intent, _): return "audio-selection:\(intentClass(intent))"
    case .applySubtitleSelection(let intent, _):
      return "subtitle-selection:\(subtitleIntentClass(intent))"
    case .applySubtitleDelay(let delay): return "subtitle-delay:\(delayClass(delay))"
    case .cancelSession: return "cancel-session"
    case .persistCheckpoint: return "persist-checkpoint"
    case .cancelInputRead: return "cancel-input"
    case .flushDecoder(let stream): return "flush-decoder:\(stream.rawValue)"
    case .installPresentationFence(let remove): return "presentation-fence:\(remove)"
    case .clearSubtitleOverlay(let revision):
      return
        "clear-overlay:\(revisionRelation(Optional(revision), active?.subtitles.overlayRevision))"
    case .invalidateSubtitleSource(let revision):
      return
        "invalidate-subtitle:\(revisionRelation(Optional(revision), active?.subtitles.subtitleRevision))"
    case .releaseLease: return "release-lease"
    case .finalizeShutdown: return "finalize-shutdown"
    case .advancePlaylist: return "advance-playlist"
    case .resumeVideoDecoderAfterTransientFailure(let stream, let count):
      return "video-decoder-retry:\(stream.kind.rawValue):\(indexClass(stream.demuxIndex)):\(count)"
    case .recreateVideoDecoderInSoftware(let stream, _):
      return "software-decoder:\(stream.kind.rawValue):\(indexClass(stream.demuxIndex))"
    case .flushPresentationForRecovery: return "recovery-presentation-flush"
    case .rebuildPresentationGraph: return "recovery-graph-rebuild"
    case .flushAudioPresentationForRecovery: return "recovery-audio-flush"
    case .rebuildAudioPresentation: return "recovery-audio-rebuild"
    case .disableAudioTrack(let stream):
      return "disable-audio:\(indexClass(stream.demuxIndex))"
    case .disableSubtitleTrack(let stream):
      return "disable-subtitle:\(stream.map { indexClass($0.demuxIndex) } ?? "unknown")"
    case .correctAudioVideoDrift(let microseconds):
      return "drift:\(microseconds == 0 ? "zero" : "nonzero")"
    case .reconfigureMediaFormat(let stream, _): return "format:\(stream.rawValue)"
    case .resumeAfterWake(let position, let rate): return "wake:\(timeClass(position)):\(rate)"
    case .mirrorDiagnostic: return "diagnostic"
    }
  }

  private static func completionClass(_ completion: EffectCompletionContract) -> String {
    switch completion {
    case .oneShot(let terminals):
      return "one:" + terminals.map(tokenClass).sorted().joined(separator: ",")
    case .phased(let phases, let terminal):
      return "phased:\(phases.count):" + terminal.map(tokenClass).sorted().joined(separator: ",")
    case .subscription(_, let callbacks, let terminals):
      return "subscription:" + callbacks.map(tokenClass).sorted().joined(separator: ",")
        + ":" + terminals.map(tokenClass).sorted().joined(separator: ",")
    case .bestEffortMirror: return "mirror"
    }
  }

  private static func tokenClass(_ token: EffectResultToken) -> String {
    [
      token.kind.rawValue, token.streamID?.kind.rawValue ?? "-",
      token.graphRevision == nil ? "g-" : "g*",
      token.membershipRevision == nil ? "m-" : "m*", token.component ?? "-",
    ]
    .joined(separator: ":")
  }

  private static func exclusiveClass(_ key: String?) -> String {
    guard let key else { return "none" }
    return key.split(separator: ".").map { part in
      part.allSatisfy(\.isNumber) ? "#" : String(part)
    }.joined(separator: ".")
  }

  private static func relation(_ value: UInt64, to current: UInt64) -> String {
    if value == current { return "current" }
    return value < current ? "previous" : "unrelated"
  }

  private static func revisionRelation<T: RawRepresentable>(
    _ value: T?, _ current: T?
  ) -> String where T.RawValue == UInt64 {
    guard let value else { return "unset" }
    guard let current else { return "unrelated" }
    return relation(value.rawValue, to: current.rawValue)
  }

  private static func timeClass(_ value: MediaTimestamp) -> String {
    switch value {
    case .unknown: return "unknown"
    case .invalid: return "invalid"
    case .valid(let time):
      if time.value < 0 { return "before-target" }
      if time.value == 0 { return "at-start" }
      return time.value > Int64(time.timescale) * 100 ? "near-eof" : "at-target"
    }
  }

  private static func cacheClass(_ value: UInt64) -> String {
    value == 0 ? "empty" : (value < 1_000_000 ? "partial" : "full")
  }

  private static func delayClass(_ value: Int64) -> String {
    value == 0 ? "zero" : (value < 0 ? "negative" : "positive")
  }

  private static func indexClass(_ value: Int32) -> String {
    value < 0 ? "invalid" : (value == 0 ? "selected" : "other")
  }

  private static func failureClass(_ failure: PlaybackFailure) -> String {
    "\(failure.domain.rawValue):\(failure.stage.rawValue):\(failure.recoverability.rawValue)"
  }

  private static func intentClass(_ intent: AudioSelectionIntent) -> String {
    switch intent {
    case .off: return "off"
    case .automatic: return "automatic"
    case .stream(let id):
      return "stream:\(id.kind.rawValue):\(id.mediaTrackID < 0 ? "invalid" : "valid")"
    }
  }

  private static func subtitleIntentClass(_ intent: SubtitleSelectionIntent) -> String {
    switch intent {
    case .off: return "off"
    case .automatic: return "automatic"
    case .embedded(let id):
      return "embedded:\(id.kind.rawValue):\(id.mediaTrackID < 0 ? "invalid" : "valid")"
    case .external(let source):
      return source.rawValue.isEmpty ? "external-invalid" : "external-valid"
    }
  }
}

extension String {
  fileprivate func leftPadding(toLength: Int, withPad character: Character) -> String {
    guard count < toLength else { return self }
    return String(repeating: String(character), count: toLength - count) + self
  }
}
