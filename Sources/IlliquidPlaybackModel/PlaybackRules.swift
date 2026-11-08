/// Playback rules over the value state. Each rule is a deterministic
/// transformation of `PlaybackDomainState` and the emitted effect intents; the
/// production model's step (`PlaybackProductionModel.step`) orchestrates one
/// turn and Statelessness owns execution and the committed state.
extension PlaybackDomainState {
  mutating func reduce(_ command: PlaybackCommand) -> (EventDisposition, [PlaybackEffect]) {
    if self.lifecycle == .shuttingDown {
      return (.invalid(reason: "commandRejectedDuringShutdown"), [])
    }
    if self.lifecycle == .invariantFailed {
      return (.invalid(reason: "coreInvariantFailed"), [])
    }
    if self.pendingSession != nil {
      switch command {
      case .load, .stop, .shutdown, .setPlaybackSpeed:
        break
      case .play, .pause, .seek, .selectAudio, .selectSubtitle, .setLoop,
           .setSubtitleDelay, .setAudioDelay, .checkpoint:
        return (.invalid(reason: "sourceReplacementPending"), [])
      }
    }

    switch command {
    case .load(let source, let autoplay):
      return beginLoad(source: source, autoplay: autoplay)
    case .play:
      return beginRateChange(milliRate: self.playbackMilliRate)
    case .pause:
      return beginRateChange(milliRate: 0)
    case .setPlaybackSpeed(let rate):
      guard (250...4_000).contains(rate) else {
        return (.invalid(reason: "unsupportedPlaybackSpeed"), [])
      }
      self.preferredPlaybackMilliRate = rate
      if var pending = self.pendingSession?.value {
        pending.synchronization.desiredMilliRate = pending.desiredTransport == .playing ? rate : 0
        self.pendingSession = PendingPlaybackSession(pending)
        return (.accepted, [])
      }
      guard var session = self.activeSession else { return (.accepted, []) }
      session.synchronization.desiredMilliRate = session.desiredTransport == .playing ? rate : 0
      self.activeSession = session
      guard session.desiredTransport == .playing,
        session.synchronization.startupAcknowledged,
        session.phase == .playing || session.phase == .draining
      else { return (.accepted, []) }
      return beginRateChange(milliRate: rate)
    case .setLoop(let start, let end):
      guard let start, let end else { self.loopRange = nil; return (.accepted, []) }
      guard let session = self.activeSession,
        case .valid(let a) = start, case .valid(let b) = end,
        a.value >= 0, Self.seconds(start) < Self.seconds(end),
        boundedSeekTarget(end, duration: session.duration) == end
      else { return (.invalid(reason: "invalidLoopRange"), []) }
      _ = b
      self.loopRange = PlaybackLoopRange(sessionID: session.id, start: start, end: end)
      return (.accepted, [])
    case .seek(let target, let mode):
      return beginSeek(target: target, mode: mode)
    case .selectAudio(let intent):
      return beginAudioSelection(intent)
    case .selectSubtitle(let intent):
      return beginSubtitleSelection(intent)
    case .setSubtitleDelay(let microseconds):
      return beginSubtitleDelay(microseconds)
    case .setAudioDelay(let microseconds):
      return beginAudioDelay(microseconds)
    case .checkpoint:
      return beginCheckpoint()
    case .stop:
      return beginStop(forShutdown: false)
    case .shutdown:
      self.lifecycle = .shuttingDown
      if self.activeSession != nil || self.pendingSession != nil {
        return beginStop(forShutdown: true)
      }
      guard
        let effect = makeApplicationEffect(
          executor: .resource,
          kind: .finalizeShutdown,
          isCleanup: true,
          exclusiveKey: "runtime.shutdown"
        )
      else {
        return allocationFailure()
      }
      return (.accepted, [effect])
    }
  }

  mutating func beginLoad(
    source: MediaSourceIdentity,
    autoplay: Bool
  ) -> (EventDisposition, [PlaybackEffect]) {
    guard !source.rawValue.isEmpty else {
      return (.invalid(reason: "emptySourceIdentity"), [])
    }
    guard let sessionID = self.allocator.allocateSession(),
      let operationID = self.allocator.allocateOperation()
    else {
      return allocationFailure()
    }

    if let superseded = self.pendingSession {
      settleEffects(for: superseded.authority)
    }

    var session = ActivePlaybackSession(
      id: sessionID,
      source: source,
      generation: PlaybackGenerationID(rawValue: 1),
      phase: .opening,
      desiredTransport: autoplay ? .playing : .paused,
      actualTransport: .stopped,
      activeOperationID: operationID,
      loading: LoadingTransactionState()
    )
    session.synchronization.desiredMilliRate = autoplay ? self.playbackMilliRate : 0
    self.pendingSession = PendingPlaybackSession(session)
    self.lastLoadFailure = nil

    guard
      let openEffect = makeEffect(
        authority: session.authority,
        operationID: operationID,
        executor: .input,
        kind: .openSource(source),
        exclusiveKey: "input.open.\(sessionID.rawValue)"
      )
    else {
      return allocationFailure()
    }
    return (.accepted, [openEffect])
  }

  mutating func beginRateChange(
    milliRate: Int32
  ) -> (EventDisposition, [PlaybackEffect]) {
    guard var session = self.activeSession else {
      return (.invalid(reason: "transportRequiresSession"), [])
    }
    guard session.phase != .opening,
      session.phase != .probing,
      session.phase != .configuring,
      session.phase != .stopping,
      session.phase != .stopped,
      session.phase != .failed
    else {
      return (.invalid(reason: "transportNotReady"), [])
    }
    guard let operationID = self.allocator.allocateOperation() else {
      return allocationFailure()
    }

    session.desiredTransport = milliRate == 0 ? .paused : .playing
    session.synchronization.desiredMilliRate = milliRate
    session.activeOperationID = operationID
    self.activeSession = session
    if milliRate != 0, !session.synchronization.startupAcknowledged {
      return (.accepted, [])
    }
    guard
      let effect = makeEffect(
        authority: session.authority,
        operationID: operationID,
        executor: .presentation,
        kind: .applyRate(milliRate: milliRate),
        exclusiveKey: "presentation.rate.\(session.id.rawValue).\(session.generation.rawValue)"
      )
    else {
      return allocationFailure()
    }
    return (.accepted, [effect])
  }

  mutating func beginSeek(
    target: MediaTimestamp,
    mode: SeekMode
  ) -> (EventDisposition, [PlaybackEffect]) {
    guard case .valid = target else {
      return (.invalid(reason: "seekRequiresValidTarget"), [])
    }
    guard var session = self.activeSession else {
      return (.invalid(reason: "seekRequiresSession"), [])
    }
    guard session.phase != .opening && session.phase != .stopping else {
      return (.invalid(reason: "seekNotReady"), [])
    }
    guard session.generation.rawValue < UInt64.max,
      let operationID = self.allocator.allocateOperation()
    else {
      return allocationFailure()
    }

    let relativeBase = session.seek?.target ?? session.logicalPosition
    let requestedTarget = mode == .relative
      ? addingMediaTimestamp(relativeBase, target)
      : target
    let resolvedTarget = boundedSeekTarget(requestedTarget, duration: session.duration)
    guard case .valid = resolvedTarget else {
      return (.invalid(reason: "relativeSeekRequiresAcceptedClock"), [])
    }
    let resolvedMode: SeekMode = mode == .relative ? .exact : mode

    session.generation = PlaybackGenerationID(rawValue: session.generation.rawValue + 1)
    session.drain = PlaybackDrainState()
    session.synchronization.beginStartupObligation()
    session.phase = .seeking
    session.actualTransport = .paused
    session.activeOperationID = operationID
    let subtitleRevision = SubtitleRevisionID(
      rawValue: session.subtitles.subtitleRevision.rawValue + 1
    )
    let overlayRevision = OverlayRevisionID(
      rawValue: session.subtitles.overlayRevision.rawValue + 1
    )
    session.subtitles.subtitleRevision = subtitleRevision
    session.subtitles.overlayRevision = overlayRevision
    session.subtitles.pendingSourceInvalidation = subtitleRevision
    session.subtitles.pendingVisibleClear = overlayRevision
    session.revisions.subtitle = subtitleRevision
    session.revisions.overlay = overlayRevision
    session.seek = SeekTransactionState(
      operationID: operationID,
      generation: session.generation,
      target: resolvedTarget,
      mode: mode,
      phase: .demuxSeeking,
      pendingBarriers: []
    )
    self.activeSession = session
    guard let effect = makeEffect(
      authority: session.authority,
      operationID: operationID,
      executor: .input,
      kind: .seekPipeline(target: resolvedTarget, mode: resolvedMode),
      exclusiveKey: "seek.pipeline.\(session.id.rawValue).\(session.generation.rawValue)"
    ) else { return allocationFailure() }
    return (.accepted, [effect])
  }

  static func seconds(_ timestamp: MediaTimestamp) -> Double {
    guard case .valid(let time) = timestamp else { return .nan }
    return Double(time.value) / Double(time.timescale)
  }

  mutating func acceptClockSample(
    _ timestamp: MediaTimestamp
  ) -> (EventDisposition, [PlaybackEffect]) {
    guard case .valid = timestamp, var session = self.activeSession else {
      return (.invalid(reason: "clockSampleRequiresValidSessionTime"), [])
    }
    session.logicalPosition = timestamp
    self.activeSession = session
    if let loop = self.loopRange, loop.sessionID == session.id,
      session.desiredTransport == .playing, session.seek == nil,
      session.phase == .playing || session.phase == .draining,
      Self.seconds(timestamp) >= Self.seconds(loop.end) {
      return beginSeek(target: loop.start, mode: .exact)
    }
    return (.accepted, [])
  }

  mutating func beginAudioSelection(
    _ intent: AudioSelectionIntent
  ) -> (EventDisposition, [PlaybackEffect]) {
    guard var session = self.activeSession else {
      return (.invalid(reason: "audioSelectionRequiresSession"), [])
    }
    let resolvedIntent: AudioSelectionIntent = switch intent {
    case .automatic:
      session.loading?.initialSelection.audio.map(AudioSelectionIntent.stream) ?? .automatic
    case .off, .stream: intent
    }
    guard let directive = session.tracks.requestAudio(resolvedIntent),
      case let .prepareAudio(requested, revision) = directive,
      let operationID = self.allocator.allocateOperation(),
      session.generation.rawValue < UInt64.max
    else { return (.invalid(reason: "audioSelectionNotAccepted"), []) }
    session.generation = PlaybackGenerationID(rawValue: session.generation.rawValue + 1)
    session.drain = PlaybackDrainState()
    session.synchronization.beginStartupObligation()
    session.revisions.track = revision
    session.phase = .prerolling
    session.actualTransport = .paused
    session.activeOperationID = operationID
    self.activeSession = session
    guard let effect = makeEffect(
      authority: session.authority,
      operationID: operationID,
      executor: .resource,
      kind: .applyAudioSelection(requested, revision: revision),
      exclusiveKey: "track.audio.\(session.id.rawValue)"
    ) else { return allocationFailure() }
    return (.accepted, [effect])
  }

  mutating func beginSubtitleSelection(
    _ intent: SubtitleSelectionIntent
  ) -> (EventDisposition, [PlaybackEffect]) {
    guard var session = self.activeSession else {
      return (.invalid(reason: "subtitleSelectionRequiresSession"), [])
    }
    let resolvedIntent: SubtitleSelectionIntent = switch intent {
    case .automatic:
      session.loading?.initialSelection.subtitle.map(SubtitleSelectionIntent.embedded) ?? .off
    case .off, .embedded, .external: intent
    }
    guard let directive = session.tracks.requestSubtitle(resolvedIntent),
      case let .prepareSubtitle(requested, revision) = directive,
      let operationID = self.allocator.allocateOperation(),
      session.generation.rawValue < UInt64.max
    else { return (.invalid(reason: "subtitleSelectionNotAccepted"), []) }
    session.generation = PlaybackGenerationID(rawValue: session.generation.rawValue + 1)
    session.drain = PlaybackDrainState()
    session.synchronization.beginStartupObligation()
    session.revisions.track = revision
    session.phase = .prerolling
    session.actualTransport = .paused
    session.activeOperationID = operationID
    self.activeSession = session
    guard let effect = makeEffect(
      authority: session.authority,
      operationID: operationID,
      executor: .resource,
      kind: .applySubtitleSelection(requested, revision: revision),
      exclusiveKey: "track.subtitle.\(session.id.rawValue)"
    ) else { return allocationFailure() }
    return (.accepted, [effect])
  }

  mutating func beginSubtitleDelay(
    _ microseconds: Int64
  ) -> (EventDisposition, [PlaybackEffect]) {
    guard var session = self.activeSession,
      let operationID = self.allocator.allocateOperation()
    else { return (.invalid(reason: "subtitleDelayRequiresSession"), []) }
    let requested = session.controls.requestSubtitleDelay(microseconds: microseconds)
    session.activeOperationID = operationID
    self.activeSession = session
    guard let effect = makeEffect(
      authority: session.authority,
      operationID: operationID,
      executor: .subtitle,
      kind: .applySubtitleDelay(microseconds: requested),
      exclusiveKey: "subtitle.delay.\(session.id.rawValue)"
    ) else { return allocationFailure() }
    return (.accepted, [effect])
  }

  mutating func beginAudioDelay(
    _ microseconds: Int64
  ) -> (EventDisposition, [PlaybackEffect]) {
    guard var session = self.activeSession else {
      return (.invalid(reason: "audioDelayRequiresSession"), [])
    }
    let requested = ControlMachineState.clampedAudioDelay(microseconds: microseconds)
    switch audioDelayAdmission(for: session) {
    case .refused:
      return (.invalid(reason: "audioDelayNotAccepted"), [])
    case .deferred:
      // A replacement, seek or preroll is in flight. Keep only the latest
      // intent and issue it when that work settles, so repeated adjustments
      // are not lost and the in-flight transaction is never superseded.
      session.controls.queuedAudioDelayMicroseconds = requested
      self.activeSession = session
      return (.accepted, [])
    case .ready:
      break
    }
    session.controls.queuedAudioDelayMicroseconds = nil
    self.activeSession = session
    guard requested != session.controls.appliedAudioDelayMicroseconds else {
      return (.accepted, [])
    }
    return startAudioDelayReplacement(requested)
  }

  /// Starts the replacement for `requested` on the active session, whose
  /// track transaction must be idle.
  mutating func startAudioDelayReplacement(
    _ requested: Int64
  ) -> (EventDisposition, [PlaybackEffect]) {
    guard var session = self.activeSession,
      let revision = session.tracks.requestReplacement(),
      let operationID = self.allocator.allocateOperation(),
      session.generation.rawValue < UInt64.max
    else { return (.invalid(reason: "audioDelayNotAccepted"), []) }
    session.controls.requestAudioDelay(microseconds: requested)
    session.generation = PlaybackGenerationID(rawValue: session.generation.rawValue + 1)
    session.drain = PlaybackDrainState()
    session.synchronization.beginStartupObligation()
    session.revisions.track = revision
    session.phase = .prerolling
    session.actualTransport = .paused
    session.activeOperationID = operationID
    self.activeSession = session
    guard let effect = makeEffect(
      authority: session.authority,
      operationID: operationID,
      executor: .resource,
      kind: .applyAudioDelay(microseconds: requested, revision: revision),
      exclusiveKey: "track.audio.\(session.id.rawValue)"
    ) else { return allocationFailure() }
    return (.accepted, [effect])
  }

  enum AudioDelayAdmission { case ready, deferred, refused }

  /// An audio-delay replacement bumps the generation, so it may start only
  /// from a settled session: no track transaction, seek or source replacement
  /// in flight. Busy sessions defer; teardown and failure refuse.
  func audioDelayAdmission(for session: ActivePlaybackSession) -> AudioDelayAdmission {
    switch session.phase {
    case .stopping, .stopped, .failed, .idle:
      return .refused
    case .opening, .probing, .configuring, .prerolling, .seeking, .draining:
      return .deferred
    case .ready, .buffering, .playing, .paused, .ended:
      break
    }
    guard session.tracks.phase == .idle, session.seek == nil, self.pendingSession == nil
    else { return .deferred }
    return .ready
  }

  /// Issues a queued audio delay once the session admits it. Returns the
  /// replacement effect, if one starts. A refusing session drops the queue.
  mutating func startQueuedAudioDelay() -> [PlaybackEffect]? {
    guard var session = self.activeSession,
      let queued = session.controls.queuedAudioDelayMicroseconds
    else { return nil }
    switch audioDelayAdmission(for: session) {
    case .deferred:
      return nil
    case .refused:
      session.controls.queuedAudioDelayMicroseconds = nil
      self.activeSession = session
      return nil
    case .ready:
      break
    }
    session.controls.queuedAudioDelayMicroseconds = nil
    self.activeSession = session
    guard queued != session.controls.appliedAudioDelayMicroseconds else { return nil }
    let (disposition, effects) = startAudioDelayReplacement(queued)
    guard disposition == .accepted, !effects.isEmpty else { return nil }
    return effects
  }

  /// A seek (or other generation change) can supersede an in-flight audio
  /// delay replacement. Native still completes it, so its late result must
  /// settle the track transaction; otherwise every later track or delay
  /// change would be refused until the source changes. Rate and preroll
  /// belong to the superseding operation, so no effects are emitted here.
  mutating func settleSupersededAudioDelay(
    _ effect: PlaybackEffect,
    revision: TrackRevisionID,
    succeeded: Bool
  ) -> Bool {
    guard var session = self.activeSession,
      case let .playback(sessionID, _, _) = effect.context.authority,
      sessionID == session.id,
      session.tracks.revision == revision,
      session.tracks.phase == .preparing
    else { return false }
    session.controls.settleAudioDelay(succeeded: succeeded)
    if succeeded {
      _ = session.tracks.prepared(revision: revision)
      _ = session.tracks.committed(revision: revision)
    } else {
      _ = session.tracks.failed(revision: revision)
      _ = session.tracks.rolledBack(revision: revision)
    }
    self.activeSession = session
    return true
  }

  mutating func acceptDuration(
    _ timestamp: MediaTimestamp
  ) -> (EventDisposition, [PlaybackEffect]) {
    guard case .valid(let value) = timestamp,
      value.value >= 0,
      var session = self.activeSession
    else {
      return (.invalid(reason: "durationRequiresValidSessionTime"), [])
    }
    session.duration = timestamp
    self.activeSession = session
    return (.accepted, [])
  }

  mutating func observeCatalog(
    _ catalog: PlaybackCatalog
  ) -> (EventDisposition, [PlaybackEffect]) {
    guard var session = self.activeSession else {
      return (.invalid(reason: "catalogRequiresSession"), [])
    }
    if var loading = session.loading {
      let isFirstCatalog = loading.catalog == nil
      loading.catalog = catalog
      if loading.phase != .settled || isFirstCatalog {
        loading.initialSelection = selectInitialTracks(from: catalog)
        if let audio = loading.initialSelection.audio {
          session.tracks.requestedAudio = .stream(audio)
          session.tracks.effectiveAudio = .stream(audio)
        }
        if let subtitle = loading.initialSelection.subtitle {
          session.tracks.requestedSubtitle = .embedded(subtitle)
          session.tracks.effectiveSubtitle = .embedded(subtitle)
        }
      }
      session.loading = loading
    }
    var required: Set<SynchronizedStream> = []
    if catalog.hasVideo { required.insert(.video) }
    if !catalog.audio.isEmpty { required.insert(.audio) }
    session.synchronization.desiredMilliRate = session.desiredTransport == .playing ? self.playbackMilliRate : 0
    if session.synchronization.startupAcknowledged {
      session.synchronization.updateRequirementsAfterStartup(required)
    } else {
      _ = session.synchronization.observe(.require(required))
    }
    self.activeSession = session
    return (.accepted, [])
  }

  mutating func observeSynchronization(
    _ event: SynchronizationCoreEvent
  ) -> (EventDisposition, [PlaybackEffect]) {
    guard var session = self.activeSession else {
      return (.stale(reason: .sessionMismatch), [])
    }
    guard session.phase != .failed else {
      return (.stale(reason: .operationMismatch), [])
    }
    let directives = session.synchronization.observe(event)
    if session.synchronization.isBuffering {
      session.phase = .buffering
      session.actualTransport = .buffering
    }
    for directive in directives {
      if case .reconfigureFormat(let stream, let revision) = directive {
        switch stream {
        case .video: session.revisions.videoFormat = revision
        case .audio: session.revisions.audioFormat = revision
        }
        session.phase = .prerolling
        session.actualTransport = .paused
      }
    }
    guard let operationID = self.allocator.allocateOperation() else {
      return allocationFailure()
    }
    session.activeOperationID = operationID
    self.activeSession = session
    var effects: [PlaybackEffect] = []
    for directive in directives {
      let specification: (ExecutorKind, PlaybackEffectKind, String)
      switch directive {
      case .applyRate(let milliRate):
        specification = (
          .presentation,
          .applyRate(milliRate: milliRate),
          "synchronization.rate.\(session.id.rawValue)"
        )
      case .correctAudioVideoDrift(let microseconds):
        specification = (
          .presentation,
          .correctAudioVideoDrift(microseconds: microseconds),
          "synchronization.drift.\(session.id.rawValue)"
        )
      case .reconfigureFormat(let stream, let revision):
        specification = (
          stream == .video ? .videoDecode : .audioDecode,
          .reconfigureMediaFormat(stream: stream, revision: revision),
          "synchronization.format.\(stream.rawValue).\(session.id.rawValue)"
        )
      }
      guard let effect = makeEffect(
        authority: session.authority,
        operationID: operationID,
        executor: specification.0,
        kind: specification.1,
        exclusiveKey: specification.2
      ) else { return allocationFailure() }
      effects.append(effect)
    }
    return (.accepted, effects)
  }

  mutating func observeLifecycle(
    _ event: LifecycleCoreEvent
  ) -> (EventDisposition, [PlaybackEffect]) {
    guard var session = self.activeSession else {
      return (.stale(reason: .sessionMismatch), [])
    }
    guard session.phase != .failed else {
      return (.stale(reason: .operationMismatch), [])
    }
    let desiredRate: Int32 = session.desiredTransport == .playing ? self.playbackMilliRate : 0
    let directive = session.lifecycleState.observe(
      event,
      desiredMilliRate: desiredRate,
      position: session.logicalPosition
    )
    guard let operationID = self.allocator.allocateOperation() else {
      return allocationFailure()
    }
    session.activeOperationID = operationID
    session.actualTransport = .paused
    if event == .systemWillSleep { session.phase = .paused }
    self.activeSession = session
    let effectKind: PlaybackEffectKind = switch directive {
    case .applyRate(let rate): .applyRate(milliRate: rate)
    case .resumeAfterWake(let position, let rate):
      .resumeAfterWake(position: position, milliRate: rate)
    }
    guard let effect = makeEffect(
      authority: session.authority,
      operationID: operationID,
      executor: .presentation,
      kind: effectKind,
      exclusiveKey: "lifecycle.\(session.id.rawValue)"
    ) else { return allocationFailure() }
    return (.accepted, [effect])
  }

  mutating func beginDrain(
    required: Set<PlaybackDrainComponent>
  ) -> (EventDisposition, [PlaybackEffect]) {
    guard var session = self.activeSession else {
      return (.invalid(reason: "drainRequiresSession"), [])
    }
    guard session.phase != .failed else {
      return (.stale(reason: .operationMismatch), [])
    }
    if let loop = self.loopRange, loop.sessionID == session.id,
      session.desiredTransport == .playing, session.seek == nil {
      return beginSeek(target: loop.start, mode: .exact)
    }
    guard !session.drain.finalized else { return (.accepted, []) }
    session.phase = .draining
    session.actualTransport = .paused
    if session.drain.required.isEmpty && session.drain.observed.isEmpty {
      session.drain = PlaybackDrainState(required: required)
    } else {
      session.drain.required.formUnion(required)
    }
    self.activeSession = session
    if session.drain.required.isEmpty { return finalizeDrain(session: session) }
    return (.accepted, [])
  }

  mutating func observeFailure(
    _ failure: PlaybackFailure
  ) -> (EventDisposition, [PlaybackEffect]) {
    guard var session = self.activeSession else {
      return (.stale(reason: .sessionMismatch), [])
    }
    // A queued observation is not a user retry. In particular, do not erase
    // the terminal error or interrupt teardown by starting another recovery.
    guard session.phase != .failed,
      session.phase != .stopping,
      session.phase != .stopped
    else { return (.stale(reason: .operationMismatch), []) }
    guard let operationID = self.allocator.allocateOperation() else {
      return allocationFailure()
    }
    let directive = session.recovery.classify(
      failure,
      sessionID: session.id,
      revisions: session.revisions
    )
    // Recovery owns the diagnostic failure while an automatic remedy is in flight.
    // Only terminal failures should escape into the user-facing playback snapshot.
    session.lastFailure = nil
    session.activeOperationID = operationID

    switch directive {
    case .resumeVideoDecoderAfterTransientFailure(let lineage, let consecutiveCount):
      self.activeSession = session
      guard let resume = makeEffect(
        authority: session.authority,
        operationID: operationID,
        executor: .videoDecode,
        kind: .resumeVideoDecoderAfterTransientFailure(
          streamID: lineage.streamID,
          consecutiveCount: consecutiveCount
        ),
        exclusiveKey: "recovery.video.\(session.id.rawValue).\(lineage.streamID.demuxIndex)"
      ) else { return allocationFailure() }
      return (.accepted, [resume])

    case .recreateVideoDecoderInSoftware(let lineage, let revision):
      guard session.generation.rawValue < UInt64.max else { return allocationFailure() }
      session.generation = PlaybackGenerationID(rawValue: session.generation.rawValue + 1)
      session.drain = PlaybackDrainState()
      session.synchronization.beginStartupObligation()
      session.revisions.decoder = revision
      session.phase = .prerolling
      session.actualTransport = .paused
      self.activeSession = session
      guard let recreate = makeEffect(
        authority: session.authority,
        operationID: operationID,
        executor: .videoDecode,
        kind: .recreateVideoDecoderInSoftware(
          streamID: lineage.streamID,
          decoderRevision: revision
        ),
        exclusiveKey: "recovery.video.\(session.id.rawValue).\(lineage.streamID.demuxIndex)"
      ) else { return allocationFailure() }
      return (.accepted, [recreate])

    case .flushAndReprimePresentation(let revision):
      session.revisions.presentation = revision
      session.phase = .prerolling
      session.actualTransport = .paused
      self.activeSession = session
      guard let flush = makeEffect(
        authority: session.authority,
        operationID: operationID,
        executor: .presentation,
        kind: .flushPresentationForRecovery(revision: revision),
        exclusiveKey: "recovery.presentation.\(session.id.rawValue)"
      ) else { return allocationFailure() }
      return (.accepted, [flush])

    case .rebuildPresentationGraph(let revision):
      session.revisions.presentationGraph = revision
      session.phase = .prerolling
      session.actualTransport = .paused
      self.activeSession = session
      guard let rebuild = makeEffect(
        authority: session.authority,
        operationID: operationID,
        executor: .presentation,
        kind: .rebuildPresentationGraph(revision: revision),
        exclusiveKey: "recovery.graph.\(session.id.rawValue)"
      ) else { return allocationFailure() }
      return (.accepted, [rebuild])

    case .flushAndReprimeAudioPresentation(let revision):
      session.revisions.presentation = revision
      session.phase = .prerolling
      session.actualTransport = .paused
      self.activeSession = session
      guard let flush = makeEffect(
        authority: session.authority,
        operationID: operationID,
        executor: .presentation,
        kind: .flushAudioPresentationForRecovery(revision: revision),
        exclusiveKey: "recovery.audio-presentation.\(session.id.rawValue)"
      ) else { return allocationFailure() }
      return (.accepted, [flush])

    case .rebuildAudioPresentation(let revision):
      session.revisions.presentationGraph = revision
      session.phase = .prerolling
      session.actualTransport = .paused
      self.activeSession = session
      guard let rebuild = makeEffect(
        authority: session.authority,
        operationID: operationID,
        executor: .presentation,
        kind: .rebuildAudioPresentation(revision: revision),
        exclusiveKey: "recovery.audio-graph.\(session.id.rawValue)"
      ) else { return allocationFailure() }
      return (.accepted, [rebuild])

    case .disableAudioTrack(let streamID):
      guard session.synchronization.required.contains(.video) else {
        session.phase = .failed
        session.actualTransport = .stopped
        session.lastFailure = failure
        self.activeSession = session
        return (.accepted, [])
      }
      session.tracks.requestedAudio = .off
      session.tracks.effectiveAudio = .off
      session.synchronization.required.remove(.audio)
      session.synchronization.prerolled.remove(.audio)
      session.drain.required.subtract([
        .audioDecoder, .audioConverter, .audioSubmission, .audioPresenter,
      ])
      self.activeSession = session
      guard let disable = makeEffect(
        authority: session.authority,
        operationID: operationID,
        executor: .audioDecode,
        kind: .disableAudioTrack(streamID: streamID),
        exclusiveKey: "recovery.audio.\(session.id.rawValue).\(streamID.demuxIndex)"
      ) else { return allocationFailure() }
      return (.accepted, [disable])

    case .disableSubtitleTrack(let streamID):
      session.tracks.requestedSubtitle = .off
      session.tracks.effectiveSubtitle = .off
      self.activeSession = session
      guard let disable = makeEffect(
        authority: session.authority,
        operationID: operationID,
        executor: .subtitle,
        kind: .disableSubtitleTrack(streamID: streamID),
        exclusiveKey: "recovery.subtitle.\(session.id.rawValue)"
      ) else { return allocationFailure() }
      return (.accepted, [disable])

    case .failTerminal:
      session.phase = .failed
      session.actualTransport = .stopped
      session.lastFailure = failure
      self.activeSession = session
      return (.accepted, [])
    }
  }

  mutating func observeDrain(
    _ component: PlaybackDrainComponent
  ) -> (EventDisposition, [PlaybackEffect]) {
    guard var session = self.activeSession, session.phase == .draining else {
      return (.stale(reason: .authorityMismatch), [])
    }
    guard session.drain.required.contains(component) else {
      return (.invalid(reason: "unexpectedDrainComponent"), [])
    }
    session.drain.observed.insert(component)
    self.activeSession = session
    guard session.drain.observed.isSuperset(of: session.drain.required) else {
      return (.accepted, [])
    }
    return finalizeDrain(session: session)
  }

  mutating func finalizeDrain(
    session input: ActivePlaybackSession
  ) -> (EventDisposition, [PlaybackEffect]) {
    var session = input
    guard !session.drain.finalized else { return (.accepted, []) }
    session.drain.finalized = true
    session.phase = .ended
    session.actualTransport = .paused
    self.activeSession = session
    guard let persistence = makeEffect(
      authority: session.authority,
      operationID: session.activeOperationID,
      executor: .persistence,
      kind: .persistCheckpoint,
      exclusiveKey: "eof.checkpoint.\(session.id.rawValue)"
    ) else { return allocationFailure() }
    return (.accepted, [persistence])
  }

  mutating func beginStop(
    forShutdown: Bool
  ) -> (EventDisposition, [PlaybackEffect]) {
    if let pending = self.pendingSession {
      settleEffects(for: pending.authority)
      self.pendingSession = nil
      if self.activeSession == nil {
        self.activeSession = pending.value
      }
    }
    if self.activeSession?.controls.queuedAudioDelayMicroseconds != nil {
      // Stop ends the session's replacement work; a queued delay is dropped.
      self.activeSession?.controls.queuedAudioDelayMicroseconds = nil
    }
    guard var session = self.activeSession else {
      if forShutdown {
        guard
          let effect = makeApplicationEffect(
            executor: .resource,
            kind: .finalizeShutdown,
            isCleanup: true,
            exclusiveKey: "runtime.shutdown"
          )
        else {
          return allocationFailure()
        }
        return (.accepted, [effect])
      }
      return (.accepted, [])
    }
    guard session.generation.rawValue < UInt64.max,
      let operationID = self.allocator.allocateOperation()
    else {
      return allocationFailure()
    }

    session.generation = PlaybackGenerationID(rawValue: session.generation.rawValue + 1)
    session.drain = PlaybackDrainState()
    session.synchronization.beginStartupObligation()
    session.phase = .stopping
    session.desiredTransport = .stopped
    session.actualTransport = .stopped
    session.activeOperationID = operationID
    self.activeSession = session
    guard
      let effect = makeEffect(
        authority: session.authority,
        operationID: operationID,
        executor: .resource,
        kind: .cancelSession,
        isCleanup: forShutdown,
        exclusiveKey: "session.cancel.\(session.id.rawValue)"
      )
    else {
      return allocationFailure()
    }
    return (.accepted, [effect])
  }

  mutating func beginCheckpoint() -> (EventDisposition, [PlaybackEffect]) {
    guard let session = self.activeSession else {
      return (.invalid(reason: "checkpointRequiresSession"), [])
    }
    guard let operationID = self.allocator.allocateOperation(),
      let effect = makeEffect(
        authority: session.authority,
        operationID: operationID,
        executor: .persistence,
        kind: .persistCheckpoint,
        exclusiveKey: "persistence.checkpoint.\(session.id.rawValue)"
      )
    else {
      return allocationFailure()
    }
    return (.accepted, [effect])
  }

  mutating func reduce(
    _ event: SubtitleCoreEvent
  ) -> (EventDisposition, [PlaybackEffect]) {
    guard var session = self.activeSession else {
      return (.invalid(reason: "subtitleRequiresSession"), [])
    }
    switch event {
    case .invalidate:
      guard session.subtitles.subtitleRevision.rawValue < UInt64.max,
        session.subtitles.overlayRevision.rawValue < UInt64.max,
        let operationID = self.allocator.allocateOperation()
      else { return allocationFailure() }

      let subtitleRevision = SubtitleRevisionID(
        rawValue: session.subtitles.subtitleRevision.rawValue + 1
      )
      let overlayRevision = OverlayRevisionID(
        rawValue: session.subtitles.overlayRevision.rawValue + 1
      )
      session.subtitles.subtitleRevision = subtitleRevision
      session.subtitles.overlayRevision = overlayRevision
      session.subtitles.pendingSourceInvalidation = subtitleRevision
      session.subtitles.pendingVisibleClear = overlayRevision
      session.revisions.subtitle = subtitleRevision
      session.revisions.overlay = overlayRevision
      session.activeOperationID = operationID
      self.activeSession = session

      guard let clear = makeEffect(
        authority: session.authority,
        operationID: operationID,
        executor: .mainActorControl,
        kind: .clearSubtitleOverlay(revision: overlayRevision),
        exclusiveKey: "subtitle.clear.\(session.id.rawValue)"
      ), let invalidate = makeEffect(
        authority: session.authority,
        operationID: operationID,
        executor: .subtitle,
        kind: .invalidateSubtitleSource(revision: subtitleRevision),
        exclusiveKey: "subtitle.invalidate.\(session.id.rawValue)"
      ) else { return allocationFailure() }
      return (.accepted, [clear, invalidate])

    case .overlayCommitCandidate(let authority, let revision):
      guard authority == session.authority,
        revision == session.subtitles.overlayRevision,
        session.subtitles.pendingVisibleClear == nil,
        session.subtitles.pendingSourceInvalidation == nil
      else {
        session.subtitles.rejectedOverlayCommitCount += 1
        self.activeSession = session
        return (.stale(reason: .authorityMismatch), [])
      }
      session.subtitles.lastAcceptedOverlayRevision = revision
      self.activeSession = session
      return (.accepted, [])

    case .sourceInstalled(let source, let external):
      session.subtitles.installedSource = source
      session.subtitles.installedSourceIsExternal = external
      self.activeSession = session
      return (.accepted, [])

    case .appliedDelay(let microseconds):
      guard session.controls.acknowledgeSubtitleDelay(microseconds: microseconds) else {
        return (.stale(reason: .operationMismatch), [])
      }
      session.subtitles.appliedDelayMicroseconds = microseconds
      self.activeSession = session
      return (.accepted, [])
    }
  }

  mutating func reduce(_ result: PlaybackEffectResult) -> (
    EventDisposition, [PlaybackEffect]
  ) {
    let effectID = result.context.effectID
    if self.containsCompletedEffect(effectID) {
      return (.duplicate(effectID: effectID), [])
    }
    guard let record = self.outstandingEffects[effectID] else {
      return (.stale(reason: .unknownEffect), [])
    }
    guard record.effect.context == result.context else {
      return (.stale(reason: contextMismatch(record.effect.context, result.context)), [])
    }
    guard completionContract(record.effect.completion, accepts: result.token) else {
      return (.invalid(reason: "undeclaredEffectResultToken"), [])
    }

    self.outstandingEffects.removeValue(forKey: effectID)
    self.recordCompletedEffect(effectID)

    if !record.effect.isCleanup,
      !authorityIsCurrent(record.effect.context.authority)
    {
      if case .applyAudioDelay(_, let revision) = record.effect.kind,
        settleSupersededAudioDelay(
          record.effect, revision: revision, succeeded: result.token.kind == .succeeded)
      {
        return (.accepted, startQueuedAudioDelay() ?? [])
      }
      return (.stale(reason: staleAuthorityReason(record.effect.context.authority)), [])
    }

    // Terminal failure does not necessarily advance session authority. Retire
    // late playback results without allowing them to clear the error, resume,
    // or issue more work. A pending replacement has its own session authority;
    // persistence and resource cleanup must still be able to settle.
    if !record.effect.isCleanup,
      self.activeSession?.phase == .failed,
      authorityMatchesActiveSession(record.effect.context.authority)
    {
      switch record.effect.kind {
      case .persistCheckpoint, .cancelSession, .releaseLease, .mirrorDiagnostic:
        break
      default:
        return (.stale(reason: .operationMismatch), [])
      }
    }

    return apply(result: result, to: record.effect)
  }

  mutating func apply(
    result: PlaybackEffectResult,
    to effect: PlaybackEffect
  ) -> (EventDisposition, [PlaybackEffect]) {
    let succeeded = result.token.kind == .succeeded
    switch effect.kind {
    case .openSource:
      return settleOpenSourceResult(result: result, effect: effect)

    case .probeSource:
      return settleProbeSourceResult(result: result, effect: effect)

    case .configureSession:
      return settleConfigureSessionResult(result: result, effect: effect)

    case .awaitPreroll:
      return settleAwaitPrerollResult(result: result, effect: effect)

    case .applyRate(let milliRate):
      return settleApplyRateResult(result: result, effect: effect, milliRate: milliRate)

    case .seekPipeline(let target, _), .seek(let target, _):
      return settleSeekPipelineResult(result: result, effect: effect, target: target)

    case .applyAudioSelection(_, let revision):
      return settleTrackSelection(revision: revision, succeeded: succeeded, result: result)

    case .applySubtitleSelection(_, let revision):
      return settleTrackSelection(revision: revision, succeeded: succeeded, result: result)

    case .applyAudioDelay(_, let revision):
      return settleTrackSelection(
        revision: revision, succeeded: succeeded, result: result, settlesAudioDelay: true)

    case .applySubtitleDelay(let microseconds):
      return settleApplySubtitleDelayResult(result: result, effect: effect, microseconds: microseconds)

    case .cancelSession:
      return settleCancelSessionResult(result: result, effect: effect)

    case .finalizeShutdown:
      return settleFinalizeShutdownResult(result: result, effect: effect)

    case .persistCheckpoint:
      return settlePersistCheckpointResult(result: result, effect: effect)

    case .cancelInputRead:
      return completeSeekBarrier(
        .inputReadCancellation,
        succeeded: succeeded,
        effect: effect
      )

    case .flushDecoder(let stream):
      let barrier: SeekBarrier = stream == .video ? .videoDecoderFlush : .audioDecoderFlush
      return completeSeekBarrier(barrier, succeeded: succeeded, effect: effect)

    case .installPresentationFence:
      return completeSeekBarrier(.presentationFence, succeeded: succeeded, effect: effect)

    case .clearSubtitleOverlay(let revision):
      guard var session = self.activeSession,
        revision == session.subtitles.pendingVisibleClear
      else { return (.stale(reason: .authorityMismatch), []) }
      if succeeded { session.subtitles.pendingVisibleClear = nil }
      self.activeSession = session
      return completeSeekBarrier(.subtitleVisibleClear, succeeded: succeeded, effect: effect)

    case .invalidateSubtitleSource(let revision):
      guard var session = self.activeSession,
        revision == session.subtitles.pendingSourceInvalidation
      else { return (.stale(reason: .authorityMismatch), []) }
      if succeeded { session.subtitles.pendingSourceInvalidation = nil }
      self.activeSession = session
      return completeSeekBarrier(
        .subtitleSourceInvalidation,
        succeeded: succeeded,
        effect: effect
      )

    case .resumeVideoDecoderAfterTransientFailure,
      .disableAudioTrack,
      .disableSubtitleTrack:
      return settleResumeVideoDecoderAfterTransientFailureResult(result: result, effect: effect)

    case .recreateVideoDecoderInSoftware,
      .flushPresentationForRecovery,
      .rebuildPresentationGraph,
      .flushAudioPresentationForRecovery,
      .rebuildAudioPresentation:
      return settleRecreateVideoDecoderInSoftwareResult(result: result, effect: effect)

    case .correctAudioVideoDrift:
      return (.accepted, [])

    case .reconfigureMediaFormat:
      return settleReconfigureMediaFormatResult(result: result, effect: effect)

    case .resumeAfterWake(let position, let milliRate):
      return settleResumeAfterWakeResult(result: result, effect: effect, position: position, milliRate: milliRate)

    case .releaseLease, .mirrorDiagnostic, .advancePlaylist:
      return (.accepted, [])
    }
  }

  // Keep each result branch in its own stack frame. In debug builds, putting
  // all session copies in one switch exhausted Swift worker-thread stacks.
  mutating func settleOpenSourceResult(
    result: PlaybackEffectResult, effect: PlaybackEffect
  ) -> (EventDisposition, [PlaybackEffect]) {
    let succeeded = result.token.kind == .succeeded
    guard var session = pendingSession(matching: effect.context.authority) else {
      return (.stale(reason: .sessionMismatch), [])
    }
    if succeeded {
      // Native preparation is an intentional aggregate: opening, probing,
      // stream/decoder configuration, and renderer membership are all
      // complete before the prepared session is installed.
      session.phase = .prerolling
      session.loading?.phase = .prerolling
      self.pendingSession = PendingPlaybackSession(session)
      guard let preroll = makeEffect(
        authority: session.authority,
        operationID: session.activeOperationID,
        executor: .presentation,
        kind: .awaitPreroll,
        exclusiveKey: "presentation.preroll.\(session.id.rawValue)"
      ) else { return allocationFailure() }
      return (.accepted, [preroll])
    } else {
      self.pendingSession = nil
      self.lastLoadFailure = result.failure ?? genericFailure(for: effect)
    }
    return (.accepted, [])
  }

  mutating func settleProbeSourceResult(
    result: PlaybackEffectResult, effect: PlaybackEffect
  ) -> (EventDisposition, [PlaybackEffect]) {
    let succeeded = result.token.kind == .succeeded
    guard var session = self.activeSession else {
      return (.stale(reason: .sessionMismatch), [])
    }
    guard succeeded else {
      session.phase = .failed
      session.lastFailure = result.failure ?? genericFailure(for: effect)
      self.activeSession = session
      return (.accepted, [])
    }
    session.phase = .configuring
    session.loading?.phase = .configuring
    let selection = session.loading?.initialSelection ?? InitialTrackSelectionState()
    self.activeSession = session
    guard let configure = makeEffect(
      authority: session.authority,
      operationID: session.activeOperationID,
      executor: .resource,
      kind: .configureSession(selection),
      exclusiveKey: "session.configure.\(session.id.rawValue)"
    ) else { return allocationFailure() }
    return (.accepted, [configure])
  }

  mutating func settleConfigureSessionResult(
    result: PlaybackEffectResult, effect: PlaybackEffect
  ) -> (EventDisposition, [PlaybackEffect]) {
    let succeeded = result.token.kind == .succeeded
    guard var session = self.activeSession else {
      return (.stale(reason: .sessionMismatch), [])
    }
    guard succeeded else {
      session.phase = .failed
      session.lastFailure = result.failure ?? genericFailure(for: effect)
      self.activeSession = session
      return (.accepted, [])
    }
    session.phase = .prerolling
    session.loading?.phase = .prerolling
    self.activeSession = session
    guard let preroll = makeEffect(
      authority: session.authority,
      operationID: session.activeOperationID,
      executor: .presentation,
      kind: .awaitPreroll,
      exclusiveKey: "presentation.preroll.\(session.id.rawValue)"
    ) else { return allocationFailure() }
    return (.accepted, [preroll])
  }

  mutating func settleAwaitPrerollResult(
    result: PlaybackEffectResult, effect: PlaybackEffect
  ) -> (EventDisposition, [PlaybackEffect]) {
    let succeeded = result.token.kind == .succeeded
    if var pending = pendingSession(matching: effect.context.authority) {
      guard succeeded else {
        self.pendingSession = nil
        self.lastLoadFailure = result.failure ?? genericFailure(for: effect)
        return (.accepted, [])
      }
      if let committed = self.activeSession {
        settleEffects(for: committed.authority)
      }
      _ = pending.synchronization.satisfyStartupObligation()
      pending.loading?.phase = .settled
      self.activeSession = pending
      self.pendingSession = nil
      self.lastLoadFailure = nil
      if pending.desiredTransport == .paused {
        pending.phase = .paused
        pending.actualTransport = .paused
        self.activeSession = pending
        return (.accepted, [])
      }
      guard let rateEffect = makeEffect(
        authority: pending.authority,
        operationID: pending.activeOperationID,
        executor: .presentation,
        kind: .applyRate(milliRate: self.playbackMilliRate),
        exclusiveKey:
          "presentation.rate.\(pending.id.rawValue).\(pending.generation.rawValue)"
      ) else { return allocationFailure() }
      return (.accepted, [rateEffect])
    }
    guard var session = self.activeSession else {
      return (.stale(reason: .sessionMismatch), [])
    }
    guard succeeded else {
      session.phase = .failed
      session.lastFailure = result.failure ?? genericFailure(for: effect)
      self.activeSession = session
      return (.accepted, [])
    }
    _ = session.synchronization.satisfyStartupObligation()
    session.loading?.phase = .settled
    if session.desiredTransport == .paused {
      session.phase = .paused
      session.actualTransport = .paused
      self.activeSession = session
      return (.accepted, [])
    }
    self.activeSession = session
    guard let rateEffect = makeEffect(
      authority: session.authority,
      operationID: session.activeOperationID,
      executor: .presentation,
      kind: .applyRate(milliRate: self.playbackMilliRate),
      exclusiveKey: "presentation.rate.\(session.id.rawValue).\(session.generation.rawValue)"
    ) else { return allocationFailure() }
    return (.accepted, [rateEffect])
  }

  mutating func settleApplyRateResult(
    result: PlaybackEffectResult, effect: PlaybackEffect,
    milliRate: Int32
  ) -> (EventDisposition, [PlaybackEffect]) {
    let succeeded = result.token.kind == .succeeded
    guard var session = self.activeSession else {
      return (.stale(reason: .sessionMismatch), [])
    }
    if succeeded {
      guard milliRate == 0 || session.synchronization.startupAcknowledged else {
        return (.stale(reason: .operationMismatch), [])
      }
      _ = session.synchronization.observe(.rateAcknowledged(milliRate: milliRate))
      if session.synchronization.isBuffering,
        session.desiredTransport == .playing,
        milliRate == 0
      {
        session.phase = .buffering
        session.actualTransport = .buffering
      } else if milliRate == 0 {
        session.phase = .paused
        session.actualTransport = .paused
      } else {
        session.phase = .playing
        session.actualTransport = .playing
      }
      if session.seek?.phase == .prerolling { session.seek = nil }
    } else {
      session.phase = .failed
      session.actualTransport = .stopped
      session.lastFailure = result.failure ?? genericFailure(for: effect)
    }
    self.activeSession = session
    // An audio delay requested while a seek was settling waits for it.
    if succeeded, let followUp = startQueuedAudioDelay() { return (.accepted, followUp) }
    return (.accepted, [])
  }

  mutating func settleSeekPipelineResult(
    result: PlaybackEffectResult, effect: PlaybackEffect,
    target: MediaTimestamp
  ) -> (EventDisposition, [PlaybackEffect]) {
    let succeeded = result.token.kind == .succeeded
    guard var session = self.activeSession else {
      return (.stale(reason: .sessionMismatch), [])
    }
    if succeeded {
      _ = session.synchronization.satisfyStartupObligation()
      session.logicalPosition = target
      session.phase = .prerolling
      session.seek?.phase = .prerolling
      self.activeSession = session
      let rate = session.desiredTransport == .playing ? self.playbackMilliRate : Int32(0)
      guard
        let rateEffect = makeEffect(
          authority: session.authority,
          operationID: session.activeOperationID,
          executor: .presentation,
          kind: .applyRate(milliRate: rate),
          exclusiveKey: "presentation.rate.\(session.id.rawValue).\(session.generation.rawValue)"
        )
      else {
        return allocationFailure()
      }
      return (.accepted, [rateEffect])
    }
    session.phase = .failed
    session.lastFailure = result.failure ?? genericFailure(for: effect)
    self.activeSession = session
    return (.accepted, [])
  }

  mutating func settleApplySubtitleDelayResult(
    result: PlaybackEffectResult, effect: PlaybackEffect,
    microseconds: Int64
  ) -> (EventDisposition, [PlaybackEffect]) {
    let succeeded = result.token.kind == .succeeded
    guard var session = self.activeSession else {
      return (.stale(reason: .sessionMismatch), [])
    }
    if succeeded {
      guard session.controls.acknowledgeSubtitleDelay(microseconds: microseconds) else {
        return (.stale(reason: .operationMismatch), [])
      }
      session.subtitles.appliedDelayMicroseconds = microseconds
    } else {
      session.lastFailure = result.failure ?? genericFailure(for: effect)
    }
    self.activeSession = session
    return (.accepted, [])
  }

  mutating func settleCancelSessionResult(
    result: PlaybackEffectResult, effect: PlaybackEffect
  ) -> (EventDisposition, [PlaybackEffect]) {
    let succeeded = result.token.kind == .succeeded
    guard succeeded else {
      if self.lifecycle == .shuttingDown {
        self.externalWaitReason = .shutdownCancellationFailed
      }
      if var session = self.activeSession,
        authorityMatchesActiveSession(effect.context.authority)
      {
        session.phase = .failed
        session.actualTransport = .stopped
        session.lastFailure = result.failure ?? genericFailure(for: effect)
        self.activeSession = session
      }
      return (.accepted, [])
    }
    settleEffects(for: effect.context.authority)
    if authorityMatchesActiveSession(effect.context.authority) {
      self.activeSession = nil
    }
    if self.lifecycle == .shuttingDown {
      self.externalWaitReason = nil
      guard
        let shutdown = makeApplicationEffect(
          executor: .resource,
          kind: .finalizeShutdown,
          isCleanup: true,
          exclusiveKey: "runtime.shutdown"
        )
      else {
        return allocationFailure()
      }
      return (.accepted, [shutdown])
    }
    return (.accepted, [])
  }

  mutating func settleFinalizeShutdownResult(
    result: PlaybackEffectResult, effect: PlaybackEffect
  ) -> (EventDisposition, [PlaybackEffect]) {
    let succeeded = result.token.kind == .succeeded
    if succeeded {
      self.externalWaitReason = nil
      self.activeSession = nil
      self.pendingSession = nil
      self.outstandingEffects.removeAll()
      self.resourceLeases.removeAll()
      self.lifecycle = .terminated
    } else {
      self.lifecycle = .shuttingDown
      self.externalWaitReason = .shutdownFinalizationFailed
    }
    return (.accepted, [])
  }

  mutating func settlePersistCheckpointResult(
    result: PlaybackEffectResult, effect: PlaybackEffect
  ) -> (EventDisposition, [PlaybackEffect]) {
    let succeeded = result.token.kind == .succeeded
    self.lastPersistenceFailureCode =
      succeeded
      ? nil
      : (result.failure?.stableCode ?? "persistenceEffectFailed")
    // EOF advancement depends on durable storage, not merely scheduling a
    // write. A seek, replay or replacement during the write revokes this edge.
    guard succeeded, self.pendingSession == nil,
      let session = self.activeSession,
      session.phase == .ended, session.drain.finalized,
      session.activeOperationID == effect.context.operationID,
      effect.exclusiveKey == "eof.checkpoint.\(session.id.rawValue)"
    else { return (.accepted, []) }
    guard let advance = makeEffect(
      authority: session.authority,
      operationID: session.activeOperationID,
      executor: .platform,
      kind: .advancePlaylist,
      exclusiveKey: "eof.advance.\(session.id.rawValue)"
    ) else { return allocationFailure() }
    return (.accepted, [advance])
  }

  mutating func settleResumeVideoDecoderAfterTransientFailureResult(
    result: PlaybackEffectResult, effect: PlaybackEffect
  ) -> (EventDisposition, [PlaybackEffect]) {
    let succeeded = result.token.kind == .succeeded
    guard var session = self.activeSession else {
      return (.stale(reason: .sessionMismatch), [])
    }
    if succeeded {
      session.lastFailure = nil
    } else {
      session.phase = .failed
      session.actualTransport = .stopped
      session.lastFailure = result.failure ?? genericFailure(for: effect)
    }
    self.activeSession = session
    return (.accepted, [])
  }

  mutating func settleRecreateVideoDecoderInSoftwareResult(
    result: PlaybackEffectResult, effect: PlaybackEffect
  ) -> (EventDisposition, [PlaybackEffect]) {
    let succeeded = result.token.kind == .succeeded
    guard var session = self.activeSession else {
      return (.stale(reason: .sessionMismatch), [])
    }
    if succeeded {
      _ = session.synchronization.satisfyStartupObligation()
      session.phase = .prerolling
      session.actualTransport = .paused
      session.lastFailure = nil
      self.activeSession = session
      let rate = session.desiredTransport == .playing ? self.playbackMilliRate : Int32(0)
      guard let rateEffect = makeEffect(
        authority: session.authority,
        operationID: session.activeOperationID,
        executor: .presentation,
        kind: .applyRate(milliRate: rate),
        exclusiveKey: "presentation.rate.\(session.id.rawValue).\(session.generation.rawValue)"
      ) else { return allocationFailure() }
      return (.accepted, [rateEffect])
    } else {
      session.phase = .failed
      session.actualTransport = .stopped
      session.lastFailure = result.failure ?? genericFailure(for: effect)
    }
    self.activeSession = session
    return (.accepted, [])
  }

  mutating func settleReconfigureMediaFormatResult(
    result: PlaybackEffectResult, effect: PlaybackEffect
  ) -> (EventDisposition, [PlaybackEffect]) {
    let succeeded = result.token.kind == .succeeded
    guard var session = self.activeSession else {
      return (.stale(reason: .sessionMismatch), [])
    }
    if succeeded {
      _ = session.synchronization.satisfyStartupObligation()
      session.phase = .prerolling
      session.actualTransport = .paused
      self.activeSession = session
      let rate = session.desiredTransport == .playing ? self.playbackMilliRate : Int32(0)
      guard let rateEffect = makeEffect(
        authority: session.authority,
        operationID: session.activeOperationID,
        executor: .presentation,
        kind: .applyRate(milliRate: rate),
        exclusiveKey: "presentation.rate.\(session.id.rawValue).\(session.generation.rawValue)"
      ) else { return allocationFailure() }
      return (.accepted, [rateEffect])
    } else {
      session.phase = .failed
      session.actualTransport = .stopped
      session.lastFailure = result.failure ?? genericFailure(for: effect)
    }
    self.activeSession = session
    return (.accepted, [])
  }

  mutating func settleResumeAfterWakeResult(
    result: PlaybackEffectResult, effect: PlaybackEffect,
    position: MediaTimestamp,
    milliRate: Int32
  ) -> (EventDisposition, [PlaybackEffect]) {
    let succeeded = result.token.kind == .succeeded
    guard var session = self.activeSession else {
      return (.stale(reason: .sessionMismatch), [])
    }
    if succeeded {
      session.logicalPosition = position
      session.phase = milliRate == 0 ? .paused : .playing
      session.actualTransport = milliRate == 0 ? .paused : .playing
    } else {
      session.phase = .failed
      session.actualTransport = .stopped
      session.lastFailure = result.failure ?? genericFailure(for: effect)
    }
    self.activeSession = session
    return (.accepted, [])
  }

  mutating func settleTrackSelection(
    revision: TrackRevisionID,
    succeeded: Bool,
    result: PlaybackEffectResult,
    settlesAudioDelay: Bool = false
  ) -> (EventDisposition, [PlaybackEffect]) {
    guard var session = self.activeSession,
      revision == session.tracks.revision,
      session.tracks.phase == .preparing
    else { return (.stale(reason: .operationMismatch), []) }
    if settlesAudioDelay { session.controls.settleAudioDelay(succeeded: succeeded) }
    if succeeded {
      _ = session.synchronization.satisfyStartupObligation()
      _ = session.tracks.prepared(revision: revision)
      _ = session.tracks.committed(revision: revision)
      let rate = session.desiredTransport == .playing ? self.playbackMilliRate : Int32(0)
      self.activeSession = session
      // A queued audio delay starts once this rate is acknowledged
      // (`settleApplyRateResult`), when the session is settled again.
      guard let rateEffect = makeEffect(
        authority: session.authority,
        operationID: session.activeOperationID,
        executor: .presentation,
        kind: .applyRate(milliRate: rate),
        exclusiveKey: "presentation.rate.\(session.id.rawValue).\(session.generation.rawValue)"
      ) else { return allocationFailure() }
      return (.accepted, [rateEffect])
    } else {
      _ = session.tracks.failed(revision: revision)
      _ = session.tracks.rolledBack(revision: revision)
      _ = session.synchronization.satisfyStartupObligation()
      session.lastFailure = result.failure
      session.phase = session.desiredTransport == .playing ? .playing : .paused
      session.actualTransport = session.desiredTransport == .playing ? .playing : .paused
    }
    self.activeSession = session
    if let followUp = startQueuedAudioDelay() { return (.accepted, followUp) }
    return (.accepted, [])
  }

  func isAllowedDuringShutdown(_ event: PlaybackEvent) -> Bool {
    switch event {
    case .diagnosticObserved:
      return true
    case .effectResult(let result):
      return self.outstandingEffects[result.context.effectID]?.effect.isCleanup == true
    default:
      return false
    }
  }

  mutating func completeSeekBarrier(
    _ barrier: SeekBarrier,
    succeeded: Bool,
    effect: PlaybackEffect
  ) -> (EventDisposition, [PlaybackEffect]) {
    guard var session = self.activeSession,
      var transaction = session.seek,
      transaction.operationID == effect.context.operationID,
      transaction.generation == session.generation
    else { return (.accepted, []) }
    guard succeeded else {
      session.seek = nil
      session.phase = .failed
      session.actualTransport = .stopped
      session.lastFailure = genericFailure(for: effect)
      self.activeSession = session
      return (.accepted, [])
    }
    transaction.pendingBarriers.remove(barrier)
    session.seek = transaction
    self.activeSession = session
    guard transaction.pendingBarriers.isEmpty else { return (.accepted, []) }

    transaction.phase = .demuxSeeking
    session.seek = transaction
    self.activeSession = session
    guard let seekEffect = makeEffect(
      authority: session.authority,
      operationID: transaction.operationID,
      executor: .input,
      kind: .seek(target: transaction.target, mode: transaction.mode),
      exclusiveKey: "input.seek.\(session.id.rawValue).\(session.generation.rawValue)"
    ) else { return allocationFailure() }
    return (.accepted, [seekEffect])
  }

  mutating func reduceDeadline(
    _ operationID: PlaybackOperationID
  ) -> (EventDisposition, [PlaybackEffect]) {
    guard var session = self.activeSession else {
      return (.stale(reason: .expiredDeadline), [])
    }
    guard session.phase != .failed else {
      return (.stale(reason: .operationMismatch), [])
    }
    guard session.activeOperationID == operationID else {
      return (.stale(reason: .operationMismatch), [])
    }
    session.phase = .failed
    session.actualTransport = .stopped
    session.lastFailure = PlaybackFailure(
      domain: .invariant,
      stage: .callback,
      stableCode: "operationTimedOut",
      recoverability: .fatal
    )
    self.activeSession = session
    return (.accepted, [])
  }

  mutating func makeApplicationEffect(
    executor: ExecutorKind,
    kind: PlaybackEffectKind,
    isCleanup: Bool,
    exclusiveKey: String?
  ) -> PlaybackEffect? {
    guard let operationID = self.allocator.allocateOperation() else { return nil }
    return makeEffect(
      authority: .application(self.applicationEpoch),
      operationID: operationID,
      executor: executor,
      kind: kind,
      isCleanup: isCleanup,
      exclusiveKey: exclusiveKey
    )
  }

  mutating func makeEffect(
    authority: PlaybackAuthority,
    operationID: PlaybackOperationID,
    executor: ExecutorKind,
    kind: PlaybackEffectKind,
    isCleanup: Bool = false,
    exclusiveKey: String? = nil
  ) -> PlaybackEffect? {
    guard let effectID = self.allocator.allocateEffect() else { return nil }
    return PlaybackEffect(
      executor: executor,
      context: PlaybackEffectContext(
        authority: authority,
        operationID: operationID,
        effectID: effectID
      ),
      kind: kind,
      isCleanup: isCleanup,
      exclusiveKey: exclusiveKey
    )
  }

  mutating func register(_ effects: [PlaybackEffect]) {
    for effect in effects {
      guard effect.completion != .bestEffortMirror else { continue }
      self.outstandingEffects[effect.context.effectID] = OutstandingEffectRecord(effect: effect)
    }
  }

  mutating func settleEffects(for authority: PlaybackAuthority) {
    // Collect IDs before mutation, avoiding a filtered dictionary of records.
    // Keep a known-size key copy when every effect belongs to this authority.
    let settled: [PlaybackEffectID]
    if self.outstandingEffects.values.allSatisfy({
      $0.effect.context.authority == authority
    }) {
      settled = self.outstandingEffects.map(\.key)
    } else {
      settled = self.outstandingEffects.compactMap { effectID, record in
        record.effect.context.authority == authority ? effectID : nil
      }
    }
    for effectID in settled {
      self.outstandingEffects.removeValue(forKey: effectID)
      self.recordCompletedEffect(effectID)
    }
  }

  func completionContract(
    _ contract: EffectCompletionContract,
    accepts token: EffectResultToken
  ) -> Bool {
    switch contract {
    case .oneShot(let terminals):
      return terminals.contains(token)
    case .phased(let phases, let terminal):
      if terminal.contains(token) { return true }
      return phases.joined().contains { requirement in
        switch requirement {
        case .exactly(let expected): return expected == token
        case .oneOf(let expected): return expected.contains(token)
        }
      }
    case .subscription(_, let callbackKinds, let terminals):
      return callbackKinds.contains(token) || terminals.contains(token)
    case .bestEffortMirror:
      return false
    }
  }

  /// Whether ordinary playback work still has authority to affect a session.
  /// Dispatchers must share this result-admission rule when retiring work that
  /// never reached an executor; subtitle/overlay-only invalidation is orthogonal.
  /// Cleanup and effect-specific revision checks remain the reducer's concern.
  public func authorityIsCurrent(_ authority: PlaybackAuthority) -> Bool {
    switch authority {
    case .application(let epoch):
      return epoch == self.applicationEpoch
    case .playback(let sessionID, let generation, let revisions):
      guard let session = session(matching: sessionID, generation: generation) else {
        return false
      }
      guard session.id == sessionID, session.generation == generation else { return false }
      if session.revisions == revisions { return true }

      // Subtitle invalidation fences its clear/source work with the explicit
      // revision payload checks in apply(result:to:). Those orthogonal
      // revisions must not strand matching session work such as track commit
      // or its resume-rate acknowledgement.
      var revisionsIgnoringSubtitleInvalidation = revisions
      revisionsIgnoringSubtitleInvalidation.subtitle = session.revisions.subtitle
      revisionsIgnoringSubtitleInvalidation.overlay = session.revisions.overlay
      return revisionsIgnoringSubtitleInvalidation == session.revisions
    }
  }

  func authorityMatchesActiveSession(_ authority: PlaybackAuthority) -> Bool {
    guard case .playback(let sessionID, let generation, _) = authority,
      let session = self.activeSession
    else { return false }
    return session.id == sessionID && session.generation == generation
  }

  func staleAuthorityReason(_ authority: PlaybackAuthority) -> StaleReason {
    guard case .playback(let sessionID, let generation, _) = authority else {
      return .authorityMismatch
    }
    guard let session = session(matching: sessionID, generation: generation) else {
      if self.activeSession?.id != sessionID, self.pendingSession?.id != sessionID {
        return .sessionMismatch
      }
      return .generationMismatch
    }
    if sessionID != session.id { return .sessionMismatch }
    if generation != session.generation { return .generationMismatch }
    return .authorityMismatch
  }

  func pendingSession(
    matching authority: PlaybackAuthority
  ) -> ActivePlaybackSession? {
    guard case .playback(let sessionID, let generation, _) = authority,
      let pending = self.pendingSession,
      pending.id == sessionID,
      pending.generation == generation
    else { return nil }
    return pending.value
  }

  func session(
    matching sessionID: PlaybackSessionID,
    generation: PlaybackGenerationID
  ) -> ActivePlaybackSession? {
    if let active = self.activeSession,
      active.id == sessionID,
      active.generation == generation
    {
      return active
    }
    if let pending = self.pendingSession,
      pending.id == sessionID,
      pending.generation == generation
    {
      return pending.value
    }
    return nil
  }

  func contextMismatch(
    _ expected: PlaybackEffectContext,
    _ actual: PlaybackEffectContext
  ) -> StaleReason {
    if expected.operationID != actual.operationID { return .operationMismatch }
    if expected.authority != actual.authority { return staleAuthorityReason(actual.authority) }
    return .authorityMismatch
  }

  func genericFailure(for effect: PlaybackEffect) -> PlaybackFailure {
    let domain: PlaybackFailure.Domain
    switch effect.executor {
    case .input: domain = .input
    case .videoDecode: domain = .videoDecode
    case .audioDecode: domain = .audioDecode
    case .presentation: domain = .presentation
    case .subtitle: domain = .subtitle
    case .persistence: domain = .persistence
    case .platform: domain = .platform
    case .resource: domain = .resource
    case .diagnostics: domain = .invariant
    case .mainActorControl: domain = .platform
    }
    return PlaybackFailure(
      domain: domain,
      stage: .callback,
      stableCode: "effectFailedWithoutTypedFailure",
      recoverability: .fatal
    )
  }

  mutating func allocationFailure() -> (EventDisposition, [PlaybackEffect]) {
    self.lifecycle = .invariantFailed
    return (.invalid(reason: "monotonicIDExhausted"), [])
  }

  func transition(
    disposition: EventDisposition,
    effects: [PlaybackEffect]
  ) -> PlaybackTransition {
    PlaybackTransition(
      disposition: disposition,
      effects: effects,
      snapshot: PlaybackUISnapshot(state: self),
      invariantViolations: PlaybackInvariantChecker.check(
        state: self,
        emittedEffects: effects
      )
    )
  }
}
