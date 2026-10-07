public struct PlaybackCore: Sendable {
  public private(set) var state: PlaybackCoreState

  public init(state: PlaybackCoreState = PlaybackCoreState()) {
    self.state = state
  }

  public mutating func update(_ envelope: PlaybackEventEnvelope) -> PlaybackTransition {
    if state.lifecycle == .terminated {
      return transition(disposition: .ignoredAfterTermination, effects: [])
    }

    guard envelope.virtualTime >= state.lastVirtualTime else {
      state.rejectedEventCount += 1
      return transition(
        disposition: .invalid(reason: "virtualTimeRegressed"),
        effects: []
      )
    }
    state.lastVirtualTime = envelope.virtualTime

    if state.lifecycle == .shuttingDown,
      !isAllowedDuringShutdown(envelope.event)
    {
      state.rejectedEventCount += 1
      return transition(
        disposition: .invalid(reason: "eventRejectedDuringShutdown"),
        effects: []
      )
    }

    let reduction: (EventDisposition, [PlaybackEffect])
    switch envelope.event {
    case .command(let command):
      reduction = reduce(command)
    case .effectResult(let result):
      reduction = reduce(result)
    case .deadlineReached(let operationID):
      reduction = reduceDeadline(operationID)
    case .diagnosticObserved:
      state.diagnosticEventCount += 1
      reduction = (.accepted, [])
    case .subtitle(let event):
      reduction = reduce(event)
    case .acceptedClockSample(let timestamp):
      reduction = acceptClockSample(timestamp)
    case .audioOutputChanged(let timestamp):
      if let session = state.activeSession,
        state.pendingSession == nil,
        !session.lifecycleState.resumeAfterWake,
        [.playing, .paused, .buffering, .seeking, .prerolling, .draining].contains(session.phase)
      {
        // Route changes are repeatable lifecycle observations, not decoder
        // failures. An in-flight user seek retains its target. The existing
        // exact-seek barriers flush/re-preroll both streams and preserve intent.
        reduction = beginSeek(target: session.seek?.target ?? timestamp, mode: .exact)
      } else {
        reduction = (.accepted, [])
      }
    case .durationObserved(let timestamp):
      reduction = acceptDuration(timestamp)
    case .catalogObserved(let catalog):
      reduction = observeCatalog(catalog)
    case .demuxEndOfFile(let required):
      reduction = beginDrain(required: required)
    case .drainObserved(let component):
      reduction = observeDrain(component)
    case .failureObserved(let failure):
      reduction = observeFailure(failure)
    case .synchronization(let event):
      reduction = observeSynchronization(event)
    case .lifecycle(let event):
      reduction = observeLifecycle(event)
    }

    switch reduction.0 {
    case .accepted:
      state.acceptedEventCount += 1
      state.snapshotRevision += 1
    case .duplicate, .stale, .invalid, .ignoredAfterTermination:
      state.rejectedEventCount += 1
    }

    register(reduction.1)
    let violations = PlaybackInvariantChecker.check(
      state: state,
      emittedEffects: reduction.1
    )
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

  private mutating func reduce(_ command: PlaybackCommand) -> (EventDisposition, [PlaybackEffect]) {
    if state.lifecycle == .shuttingDown {
      return (.invalid(reason: "commandRejectedDuringShutdown"), [])
    }
    if state.lifecycle == .invariantFailed {
      return (.invalid(reason: "coreInvariantFailed"), [])
    }
    if state.pendingSession != nil {
      switch command {
      case .load, .stop, .shutdown, .setPlaybackSpeed:
        break
      case .play, .pause, .seek, .selectAudio, .selectSubtitle, .setLoop,
           .setSubtitleDelay, .checkpoint:
        return (.invalid(reason: "sourceReplacementPending"), [])
      }
    }

    switch command {
    case .load(let source, let autoplay):
      return beginLoad(source: source, autoplay: autoplay)
    case .play:
      return beginRateChange(milliRate: state.playbackMilliRate)
    case .pause:
      return beginRateChange(milliRate: 0)
    case .setPlaybackSpeed(let rate):
      guard (250...4_000).contains(rate) else {
        return (.invalid(reason: "unsupportedPlaybackSpeed"), [])
      }
      state.preferredPlaybackMilliRate = rate
      if var pending = state.pendingSession?.value {
        pending.synchronization.desiredMilliRate = pending.desiredTransport == .playing ? rate : 0
        state.pendingSession = PendingPlaybackSession(pending)
        return (.accepted, [])
      }
      guard var session = state.activeSession else { return (.accepted, []) }
      session.synchronization.desiredMilliRate = session.desiredTransport == .playing ? rate : 0
      state.activeSession = session
      guard session.desiredTransport == .playing,
        session.synchronization.startupAcknowledged,
        session.phase == .playing || session.phase == .draining
      else { return (.accepted, []) }
      return beginRateChange(milliRate: rate)
    case .setLoop(let start, let end):
      guard let start, let end else { state.loopRange = nil; return (.accepted, []) }
      guard let session = state.activeSession,
        case .valid(let a) = start, case .valid(let b) = end,
        a.value >= 0, Self.seconds(start) < Self.seconds(end),
        boundedSeekTarget(end, duration: session.duration) == end
      else { return (.invalid(reason: "invalidLoopRange"), []) }
      _ = b
      state.loopRange = PlaybackLoopRange(sessionID: session.id, start: start, end: end)
      return (.accepted, [])
    case .seek(let target, let mode):
      return beginSeek(target: target, mode: mode)
    case .selectAudio(let intent):
      return beginAudioSelection(intent)
    case .selectSubtitle(let intent):
      return beginSubtitleSelection(intent)
    case .setSubtitleDelay(let microseconds):
      return beginSubtitleDelay(microseconds)
    case .checkpoint:
      return beginCheckpoint()
    case .stop:
      return beginStop(forShutdown: false)
    case .shutdown:
      state.lifecycle = .shuttingDown
      if state.activeSession != nil || state.pendingSession != nil {
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

  private mutating func beginLoad(
    source: MediaSourceIdentity,
    autoplay: Bool
  ) -> (EventDisposition, [PlaybackEffect]) {
    guard !source.rawValue.isEmpty else {
      return (.invalid(reason: "emptySourceIdentity"), [])
    }
    guard let sessionID = state.allocator.allocateSession(),
      let operationID = state.allocator.allocateOperation()
    else {
      return allocationFailure()
    }

    if let superseded = state.pendingSession {
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
    session.synchronization.desiredMilliRate = autoplay ? state.playbackMilliRate : 0
    state.pendingSession = PendingPlaybackSession(session)
    state.lastLoadFailure = nil

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

  private mutating func beginRateChange(
    milliRate: Int32
  ) -> (EventDisposition, [PlaybackEffect]) {
    guard var session = state.activeSession else {
      return (.invalid(reason: "transportRequiresSession"), [])
    }
    guard session.phase != .opening,
      session.phase != .probing,
      session.phase != .configuring,
      session.phase != .stopping,
      session.phase != .stopped
    else {
      return (.invalid(reason: "transportNotReady"), [])
    }
    guard let operationID = state.allocator.allocateOperation() else {
      return allocationFailure()
    }

    session.desiredTransport = milliRate == 0 ? .paused : .playing
    session.synchronization.desiredMilliRate = milliRate
    session.activeOperationID = operationID
    state.activeSession = session
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

  private mutating func beginSeek(
    target: MediaTimestamp,
    mode: SeekMode
  ) -> (EventDisposition, [PlaybackEffect]) {
    guard case .valid = target else {
      return (.invalid(reason: "seekRequiresValidTarget"), [])
    }
    guard var session = state.activeSession else {
      return (.invalid(reason: "seekRequiresSession"), [])
    }
    guard session.phase != .opening && session.phase != .stopping else {
      return (.invalid(reason: "seekNotReady"), [])
    }
    guard session.generation.rawValue < UInt64.max,
      let operationID = state.allocator.allocateOperation()
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
    state.activeSession = session
    guard let effect = makeEffect(
      authority: session.authority,
      operationID: operationID,
      executor: .input,
      kind: .seekPipeline(target: resolvedTarget, mode: resolvedMode),
      exclusiveKey: "seek.pipeline.\(session.id.rawValue).\(session.generation.rawValue)"
    ) else { return allocationFailure() }
    return (.accepted, [effect])
  }

  private static func seconds(_ timestamp: MediaTimestamp) -> Double {
    guard case .valid(let time) = timestamp else { return .nan }
    return Double(time.value) / Double(time.timescale)
  }

  private mutating func acceptClockSample(
    _ timestamp: MediaTimestamp
  ) -> (EventDisposition, [PlaybackEffect]) {
    guard case .valid = timestamp, var session = state.activeSession else {
      return (.invalid(reason: "clockSampleRequiresValidSessionTime"), [])
    }
    session.logicalPosition = timestamp
    state.activeSession = session
    if let loop = state.loopRange, loop.sessionID == session.id,
      session.desiredTransport == .playing, session.seek == nil,
      session.phase == .playing || session.phase == .draining,
      Self.seconds(timestamp) >= Self.seconds(loop.end) {
      return beginSeek(target: loop.start, mode: .exact)
    }
    return (.accepted, [])
  }

  private mutating func beginAudioSelection(
    _ intent: AudioSelectionIntent
  ) -> (EventDisposition, [PlaybackEffect]) {
    guard var session = state.activeSession else {
      return (.invalid(reason: "audioSelectionRequiresSession"), [])
    }
    let resolvedIntent: AudioSelectionIntent = switch intent {
    case .automatic:
      session.loading?.initialSelection.audio.map(AudioSelectionIntent.stream) ?? .automatic
    case .off, .stream: intent
    }
    guard let directive = session.tracks.requestAudio(resolvedIntent),
      case let .prepareAudio(requested, revision) = directive,
      let operationID = state.allocator.allocateOperation(),
      session.generation.rawValue < UInt64.max
    else { return (.invalid(reason: "audioSelectionNotAccepted"), []) }
    session.generation = PlaybackGenerationID(rawValue: session.generation.rawValue + 1)
    session.drain = PlaybackDrainState()
    session.synchronization.beginStartupObligation()
    session.revisions.track = revision
    session.phase = .prerolling
    session.actualTransport = .paused
    session.activeOperationID = operationID
    state.activeSession = session
    guard let effect = makeEffect(
      authority: session.authority,
      operationID: operationID,
      executor: .resource,
      kind: .applyAudioSelection(requested, revision: revision),
      exclusiveKey: "track.audio.\(session.id.rawValue)"
    ) else { return allocationFailure() }
    return (.accepted, [effect])
  }

  private mutating func beginSubtitleSelection(
    _ intent: SubtitleSelectionIntent
  ) -> (EventDisposition, [PlaybackEffect]) {
    guard var session = state.activeSession else {
      return (.invalid(reason: "subtitleSelectionRequiresSession"), [])
    }
    let resolvedIntent: SubtitleSelectionIntent = switch intent {
    case .automatic:
      session.loading?.initialSelection.subtitle.map(SubtitleSelectionIntent.embedded) ?? .off
    case .off, .embedded, .external: intent
    }
    guard let directive = session.tracks.requestSubtitle(resolvedIntent),
      case let .prepareSubtitle(requested, revision) = directive,
      let operationID = state.allocator.allocateOperation(),
      session.generation.rawValue < UInt64.max
    else { return (.invalid(reason: "subtitleSelectionNotAccepted"), []) }
    session.generation = PlaybackGenerationID(rawValue: session.generation.rawValue + 1)
    session.drain = PlaybackDrainState()
    session.synchronization.beginStartupObligation()
    session.revisions.track = revision
    session.phase = .prerolling
    session.actualTransport = .paused
    session.activeOperationID = operationID
    state.activeSession = session
    guard let effect = makeEffect(
      authority: session.authority,
      operationID: operationID,
      executor: .resource,
      kind: .applySubtitleSelection(requested, revision: revision),
      exclusiveKey: "track.subtitle.\(session.id.rawValue)"
    ) else { return allocationFailure() }
    return (.accepted, [effect])
  }

  private mutating func beginSubtitleDelay(
    _ microseconds: Int64
  ) -> (EventDisposition, [PlaybackEffect]) {
    guard var session = state.activeSession,
      let operationID = state.allocator.allocateOperation()
    else { return (.invalid(reason: "subtitleDelayRequiresSession"), []) }
    let requested = session.controls.requestSubtitleDelay(microseconds: microseconds)
    session.activeOperationID = operationID
    state.activeSession = session
    guard let effect = makeEffect(
      authority: session.authority,
      operationID: operationID,
      executor: .subtitle,
      kind: .applySubtitleDelay(microseconds: requested),
      exclusiveKey: "subtitle.delay.\(session.id.rawValue)"
    ) else { return allocationFailure() }
    return (.accepted, [effect])
  }

  private mutating func acceptDuration(
    _ timestamp: MediaTimestamp
  ) -> (EventDisposition, [PlaybackEffect]) {
    guard case .valid(let value) = timestamp,
      value.value >= 0,
      var session = state.activeSession
    else {
      return (.invalid(reason: "durationRequiresValidSessionTime"), [])
    }
    session.duration = timestamp
    state.activeSession = session
    return (.accepted, [])
  }

  private mutating func observeCatalog(
    _ catalog: PlaybackCatalog
  ) -> (EventDisposition, [PlaybackEffect]) {
    guard var session = state.activeSession else {
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
    session.synchronization.desiredMilliRate = session.desiredTransport == .playing ? state.playbackMilliRate : 0
    if session.synchronization.startupAcknowledged {
      session.synchronization.updateRequirementsAfterStartup(required)
    } else {
      _ = session.synchronization.observe(.require(required))
    }
    state.activeSession = session
    return (.accepted, [])
  }

  private mutating func observeSynchronization(
    _ event: SynchronizationCoreEvent
  ) -> (EventDisposition, [PlaybackEffect]) {
    guard var session = state.activeSession else {
      return (.stale(reason: .sessionMismatch), [])
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
    guard let operationID = state.allocator.allocateOperation() else {
      return allocationFailure()
    }
    session.activeOperationID = operationID
    state.activeSession = session
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

  private mutating func observeLifecycle(
    _ event: LifecycleCoreEvent
  ) -> (EventDisposition, [PlaybackEffect]) {
    guard var session = state.activeSession else {
      return (.stale(reason: .sessionMismatch), [])
    }
    let desiredRate: Int32 = session.desiredTransport == .playing ? state.playbackMilliRate : 0
    let directive = session.lifecycleState.observe(
      event,
      desiredMilliRate: desiredRate,
      position: session.logicalPosition
    )
    guard let operationID = state.allocator.allocateOperation() else {
      return allocationFailure()
    }
    session.activeOperationID = operationID
    session.actualTransport = .paused
    if event == .systemWillSleep { session.phase = .paused }
    state.activeSession = session
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

  private mutating func beginDrain(
    required: Set<PlaybackDrainComponent>
  ) -> (EventDisposition, [PlaybackEffect]) {
    guard var session = state.activeSession else {
      return (.invalid(reason: "drainRequiresSession"), [])
    }
    if let loop = state.loopRange, loop.sessionID == session.id,
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
    state.activeSession = session
    if session.drain.required.isEmpty { return finalizeDrain(session: session) }
    return (.accepted, [])
  }

  private mutating func observeFailure(
    _ failure: PlaybackFailure
  ) -> (EventDisposition, [PlaybackEffect]) {
    guard var session = state.activeSession else {
      return (.stale(reason: .sessionMismatch), [])
    }
    guard let operationID = state.allocator.allocateOperation() else {
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
      state.activeSession = session
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
      state.activeSession = session
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
      state.activeSession = session
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
      state.activeSession = session
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
      state.activeSession = session
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
      state.activeSession = session
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
        state.activeSession = session
        return (.accepted, [])
      }
      session.tracks.requestedAudio = .off
      session.tracks.effectiveAudio = .off
      session.synchronization.required.remove(.audio)
      session.synchronization.prerolled.remove(.audio)
      session.drain.required.subtract([
        .audioDecoder, .audioConverter, .audioSubmission, .audioPresenter,
      ])
      state.activeSession = session
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
      state.activeSession = session
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
      state.activeSession = session
      return (.accepted, [])
    }
  }

  private mutating func observeDrain(
    _ component: PlaybackDrainComponent
  ) -> (EventDisposition, [PlaybackEffect]) {
    guard var session = state.activeSession, session.phase == .draining else {
      return (.stale(reason: .authorityMismatch), [])
    }
    guard session.drain.required.contains(component) else {
      return (.invalid(reason: "unexpectedDrainComponent"), [])
    }
    session.drain.observed.insert(component)
    state.activeSession = session
    guard session.drain.observed.isSuperset(of: session.drain.required) else {
      return (.accepted, [])
    }
    return finalizeDrain(session: session)
  }

  private mutating func finalizeDrain(
    session input: ActivePlaybackSession
  ) -> (EventDisposition, [PlaybackEffect]) {
    var session = input
    guard !session.drain.finalized else { return (.accepted, []) }
    session.drain.finalized = true
    session.phase = .ended
    session.actualTransport = .paused
    state.activeSession = session
    guard let persistence = makeEffect(
      authority: session.authority,
      operationID: session.activeOperationID,
      executor: .persistence,
      kind: .persistCheckpoint,
      exclusiveKey: "eof.checkpoint.\(session.id.rawValue)"
    ) else { return allocationFailure() }
    return (.accepted, [persistence])
  }

  private mutating func beginStop(
    forShutdown: Bool
  ) -> (EventDisposition, [PlaybackEffect]) {
    if let pending = state.pendingSession {
      settleEffects(for: pending.authority)
      state.pendingSession = nil
      if state.activeSession == nil {
        state.activeSession = pending.value
      }
    }
    guard var session = state.activeSession else {
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
      let operationID = state.allocator.allocateOperation()
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
    state.activeSession = session
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

  private mutating func beginCheckpoint() -> (EventDisposition, [PlaybackEffect]) {
    guard let session = state.activeSession else {
      return (.invalid(reason: "checkpointRequiresSession"), [])
    }
    guard let operationID = state.allocator.allocateOperation(),
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

  private mutating func reduce(
    _ event: SubtitleCoreEvent
  ) -> (EventDisposition, [PlaybackEffect]) {
    guard var session = state.activeSession else {
      return (.invalid(reason: "subtitleRequiresSession"), [])
    }
    switch event {
    case .invalidate:
      guard session.subtitles.subtitleRevision.rawValue < UInt64.max,
        session.subtitles.overlayRevision.rawValue < UInt64.max,
        let operationID = state.allocator.allocateOperation()
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
      state.activeSession = session

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
        state.activeSession = session
        return (.stale(reason: .authorityMismatch), [])
      }
      session.subtitles.lastAcceptedOverlayRevision = revision
      state.activeSession = session
      return (.accepted, [])

    case .sourceInstalled(let source, let external):
      session.subtitles.installedSource = source
      session.subtitles.installedSourceIsExternal = external
      state.activeSession = session
      return (.accepted, [])

    case .appliedDelay(let microseconds):
      guard session.controls.acknowledgeSubtitleDelay(microseconds: microseconds) else {
        return (.stale(reason: .operationMismatch), [])
      }
      session.subtitles.appliedDelayMicroseconds = microseconds
      state.activeSession = session
      return (.accepted, [])
    }
  }

  private mutating func reduce(_ result: PlaybackEffectResult) -> (
    EventDisposition, [PlaybackEffect]
  ) {
    let effectID = result.context.effectID
    if state.completedEffectIDs.contains(effectID) {
      return (.duplicate(effectID: effectID), [])
    }
    guard let record = state.outstandingEffects[effectID] else {
      return (.stale(reason: .unknownEffect), [])
    }
    guard record.effect.context == result.context else {
      return (.stale(reason: contextMismatch(record.effect.context, result.context)), [])
    }
    guard completionContract(record.effect.completion, accepts: result.token) else {
      return (.invalid(reason: "undeclaredEffectResultToken"), [])
    }

    state.outstandingEffects.removeValue(forKey: effectID)
    state.completedEffectIDs.insert(effectID)

    if !record.effect.isCleanup,
      !authorityIsCurrent(record.effect.context.authority)
    {
      return (.stale(reason: staleAuthorityReason(record.effect.context.authority)), [])
    }

    return apply(result: result, to: record.effect)
  }

  private mutating func apply(
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
      guard var session = state.activeSession,
        revision == session.subtitles.pendingVisibleClear
      else { return (.stale(reason: .authorityMismatch), []) }
      if succeeded { session.subtitles.pendingVisibleClear = nil }
      state.activeSession = session
      return completeSeekBarrier(.subtitleVisibleClear, succeeded: succeeded, effect: effect)

    case .invalidateSubtitleSource(let revision):
      guard var session = state.activeSession,
        revision == session.subtitles.pendingSourceInvalidation
      else { return (.stale(reason: .authorityMismatch), []) }
      if succeeded { session.subtitles.pendingSourceInvalidation = nil }
      state.activeSession = session
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
  private mutating func settleOpenSourceResult(
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
      state.pendingSession = PendingPlaybackSession(session)
      guard let preroll = makeEffect(
        authority: session.authority,
        operationID: session.activeOperationID,
        executor: .presentation,
        kind: .awaitPreroll,
        exclusiveKey: "presentation.preroll.\(session.id.rawValue)"
      ) else { return allocationFailure() }
      return (.accepted, [preroll])
    } else {
      state.pendingSession = nil
      state.lastLoadFailure = result.failure ?? genericFailure(for: effect)
    }
    return (.accepted, [])
  }

  private mutating func settleProbeSourceResult(
    result: PlaybackEffectResult, effect: PlaybackEffect
  ) -> (EventDisposition, [PlaybackEffect]) {
    let succeeded = result.token.kind == .succeeded
    guard var session = state.activeSession else {
      return (.stale(reason: .sessionMismatch), [])
    }
    guard succeeded else {
      session.phase = .failed
      session.lastFailure = result.failure ?? genericFailure(for: effect)
      state.activeSession = session
      return (.accepted, [])
    }
    session.phase = .configuring
    session.loading?.phase = .configuring
    let selection = session.loading?.initialSelection ?? InitialTrackSelectionState()
    state.activeSession = session
    guard let configure = makeEffect(
      authority: session.authority,
      operationID: session.activeOperationID,
      executor: .resource,
      kind: .configureSession(selection),
      exclusiveKey: "session.configure.\(session.id.rawValue)"
    ) else { return allocationFailure() }
    return (.accepted, [configure])
  }

  private mutating func settleConfigureSessionResult(
    result: PlaybackEffectResult, effect: PlaybackEffect
  ) -> (EventDisposition, [PlaybackEffect]) {
    let succeeded = result.token.kind == .succeeded
    guard var session = state.activeSession else {
      return (.stale(reason: .sessionMismatch), [])
    }
    guard succeeded else {
      session.phase = .failed
      session.lastFailure = result.failure ?? genericFailure(for: effect)
      state.activeSession = session
      return (.accepted, [])
    }
    session.phase = .prerolling
    session.loading?.phase = .prerolling
    state.activeSession = session
    guard let preroll = makeEffect(
      authority: session.authority,
      operationID: session.activeOperationID,
      executor: .presentation,
      kind: .awaitPreroll,
      exclusiveKey: "presentation.preroll.\(session.id.rawValue)"
    ) else { return allocationFailure() }
    return (.accepted, [preroll])
  }

  private mutating func settleAwaitPrerollResult(
    result: PlaybackEffectResult, effect: PlaybackEffect
  ) -> (EventDisposition, [PlaybackEffect]) {
    let succeeded = result.token.kind == .succeeded
    if var pending = pendingSession(matching: effect.context.authority) {
      guard succeeded else {
        state.pendingSession = nil
        state.lastLoadFailure = result.failure ?? genericFailure(for: effect)
        return (.accepted, [])
      }
      if let committed = state.activeSession {
        settleEffects(for: committed.authority)
      }
      _ = pending.synchronization.satisfyStartupObligation()
      pending.loading?.phase = .settled
      state.activeSession = pending
      state.pendingSession = nil
      state.lastLoadFailure = nil
      if pending.desiredTransport == .paused {
        pending.phase = .paused
        pending.actualTransport = .paused
        state.activeSession = pending
        return (.accepted, [])
      }
      guard let rateEffect = makeEffect(
        authority: pending.authority,
        operationID: pending.activeOperationID,
        executor: .presentation,
        kind: .applyRate(milliRate: state.playbackMilliRate),
        exclusiveKey:
          "presentation.rate.\(pending.id.rawValue).\(pending.generation.rawValue)"
      ) else { return allocationFailure() }
      return (.accepted, [rateEffect])
    }
    guard var session = state.activeSession else {
      return (.stale(reason: .sessionMismatch), [])
    }
    guard succeeded else {
      session.phase = .failed
      session.lastFailure = result.failure ?? genericFailure(for: effect)
      state.activeSession = session
      return (.accepted, [])
    }
    _ = session.synchronization.satisfyStartupObligation()
    session.loading?.phase = .settled
    if session.desiredTransport == .paused {
      session.phase = .paused
      session.actualTransport = .paused
      state.activeSession = session
      return (.accepted, [])
    }
    state.activeSession = session
    guard let rateEffect = makeEffect(
      authority: session.authority,
      operationID: session.activeOperationID,
      executor: .presentation,
      kind: .applyRate(milliRate: state.playbackMilliRate),
      exclusiveKey: "presentation.rate.\(session.id.rawValue).\(session.generation.rawValue)"
    ) else { return allocationFailure() }
    return (.accepted, [rateEffect])
  }

  private mutating func settleApplyRateResult(
    result: PlaybackEffectResult, effect: PlaybackEffect,
    milliRate: Int32
  ) -> (EventDisposition, [PlaybackEffect]) {
    let succeeded = result.token.kind == .succeeded
    guard var session = state.activeSession else {
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
    state.activeSession = session
    return (.accepted, [])
  }

  private mutating func settleSeekPipelineResult(
    result: PlaybackEffectResult, effect: PlaybackEffect,
    target: MediaTimestamp
  ) -> (EventDisposition, [PlaybackEffect]) {
    let succeeded = result.token.kind == .succeeded
    guard var session = state.activeSession else {
      return (.stale(reason: .sessionMismatch), [])
    }
    if succeeded {
      _ = session.synchronization.satisfyStartupObligation()
      session.logicalPosition = target
      session.phase = .prerolling
      session.seek?.phase = .prerolling
      state.activeSession = session
      let rate = session.desiredTransport == .playing ? state.playbackMilliRate : Int32(0)
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
    state.activeSession = session
    return (.accepted, [])
  }

  private mutating func settleApplySubtitleDelayResult(
    result: PlaybackEffectResult, effect: PlaybackEffect,
    microseconds: Int64
  ) -> (EventDisposition, [PlaybackEffect]) {
    let succeeded = result.token.kind == .succeeded
    guard var session = state.activeSession else {
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
    state.activeSession = session
    return (.accepted, [])
  }

  private mutating func settleCancelSessionResult(
    result: PlaybackEffectResult, effect: PlaybackEffect
  ) -> (EventDisposition, [PlaybackEffect]) {
    let succeeded = result.token.kind == .succeeded
    guard succeeded else {
      if state.lifecycle == .shuttingDown {
        state.externalWaitReason = .shutdownCancellationFailed
      }
      if var session = state.activeSession,
        authorityMatchesActiveSession(effect.context.authority)
      {
        session.phase = .failed
        session.actualTransport = .stopped
        session.lastFailure = result.failure ?? genericFailure(for: effect)
        state.activeSession = session
      }
      return (.accepted, [])
    }
    settleEffects(for: effect.context.authority)
    if authorityMatchesActiveSession(effect.context.authority) {
      state.activeSession = nil
    }
    if state.lifecycle == .shuttingDown {
      state.externalWaitReason = nil
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

  private mutating func settleFinalizeShutdownResult(
    result: PlaybackEffectResult, effect: PlaybackEffect
  ) -> (EventDisposition, [PlaybackEffect]) {
    let succeeded = result.token.kind == .succeeded
    if succeeded {
      state.externalWaitReason = nil
      state.activeSession = nil
      state.pendingSession = nil
      state.outstandingEffects.removeAll()
      state.resourceLeases.removeAll()
      state.lifecycle = .terminated
    } else {
      state.lifecycle = .shuttingDown
      state.externalWaitReason = .shutdownFinalizationFailed
    }
    return (.accepted, [])
  }

  private mutating func settlePersistCheckpointResult(
    result: PlaybackEffectResult, effect: PlaybackEffect
  ) -> (EventDisposition, [PlaybackEffect]) {
    let succeeded = result.token.kind == .succeeded
    state.lastPersistenceFailureCode =
      succeeded
      ? nil
      : (result.failure?.stableCode ?? "persistenceEffectFailed")
    // EOF advancement depends on durable storage, not merely scheduling a
    // write. A seek, replay or replacement during the write revokes this edge.
    guard succeeded, state.pendingSession == nil,
      let session = state.activeSession,
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

  private mutating func settleResumeVideoDecoderAfterTransientFailureResult(
    result: PlaybackEffectResult, effect: PlaybackEffect
  ) -> (EventDisposition, [PlaybackEffect]) {
    let succeeded = result.token.kind == .succeeded
    guard var session = state.activeSession else {
      return (.stale(reason: .sessionMismatch), [])
    }
    if succeeded {
      session.lastFailure = nil
    } else {
      session.phase = .failed
      session.actualTransport = .stopped
      session.lastFailure = result.failure ?? genericFailure(for: effect)
    }
    state.activeSession = session
    return (.accepted, [])
  }

  private mutating func settleRecreateVideoDecoderInSoftwareResult(
    result: PlaybackEffectResult, effect: PlaybackEffect
  ) -> (EventDisposition, [PlaybackEffect]) {
    let succeeded = result.token.kind == .succeeded
    guard var session = state.activeSession else {
      return (.stale(reason: .sessionMismatch), [])
    }
    if succeeded {
      _ = session.synchronization.satisfyStartupObligation()
      session.phase = .prerolling
      session.actualTransport = .paused
      session.lastFailure = nil
      state.activeSession = session
      let rate = session.desiredTransport == .playing ? state.playbackMilliRate : Int32(0)
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
    state.activeSession = session
    return (.accepted, [])
  }

  private mutating func settleReconfigureMediaFormatResult(
    result: PlaybackEffectResult, effect: PlaybackEffect
  ) -> (EventDisposition, [PlaybackEffect]) {
    let succeeded = result.token.kind == .succeeded
    guard var session = state.activeSession else {
      return (.stale(reason: .sessionMismatch), [])
    }
    if succeeded {
      _ = session.synchronization.satisfyStartupObligation()
      session.phase = .prerolling
      session.actualTransport = .paused
      state.activeSession = session
      let rate = session.desiredTransport == .playing ? state.playbackMilliRate : Int32(0)
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
    state.activeSession = session
    return (.accepted, [])
  }

  private mutating func settleResumeAfterWakeResult(
    result: PlaybackEffectResult, effect: PlaybackEffect,
    position: MediaTimestamp,
    milliRate: Int32
  ) -> (EventDisposition, [PlaybackEffect]) {
    let succeeded = result.token.kind == .succeeded
    guard var session = state.activeSession else {
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
    state.activeSession = session
    return (.accepted, [])
  }

  private mutating func settleTrackSelection(
    revision: TrackRevisionID,
    succeeded: Bool,
    result: PlaybackEffectResult
  ) -> (EventDisposition, [PlaybackEffect]) {
    guard var session = state.activeSession,
      revision == session.tracks.revision,
      session.tracks.phase == .preparing
    else { return (.stale(reason: .operationMismatch), []) }
    if succeeded {
      _ = session.synchronization.satisfyStartupObligation()
      _ = session.tracks.prepared(revision: revision)
      _ = session.tracks.committed(revision: revision)
      let rate = session.desiredTransport == .playing ? state.playbackMilliRate : Int32(0)
      state.activeSession = session
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
    state.activeSession = session
    return (.accepted, [])
  }

  private func isAllowedDuringShutdown(_ event: PlaybackEvent) -> Bool {
    switch event {
    case .diagnosticObserved:
      return true
    case .effectResult(let result):
      return state.outstandingEffects[result.context.effectID]?.effect.isCleanup == true
    default:
      return false
    }
  }

  private mutating func completeSeekBarrier(
    _ barrier: SeekBarrier,
    succeeded: Bool,
    effect: PlaybackEffect
  ) -> (EventDisposition, [PlaybackEffect]) {
    guard var session = state.activeSession,
      var transaction = session.seek,
      transaction.operationID == effect.context.operationID,
      transaction.generation == session.generation
    else { return (.accepted, []) }
    guard succeeded else {
      session.seek = nil
      session.phase = .failed
      session.actualTransport = .stopped
      session.lastFailure = genericFailure(for: effect)
      state.activeSession = session
      return (.accepted, [])
    }
    transaction.pendingBarriers.remove(barrier)
    session.seek = transaction
    state.activeSession = session
    guard transaction.pendingBarriers.isEmpty else { return (.accepted, []) }

    transaction.phase = .demuxSeeking
    session.seek = transaction
    state.activeSession = session
    guard let seekEffect = makeEffect(
      authority: session.authority,
      operationID: transaction.operationID,
      executor: .input,
      kind: .seek(target: transaction.target, mode: transaction.mode),
      exclusiveKey: "input.seek.\(session.id.rawValue).\(session.generation.rawValue)"
    ) else { return allocationFailure() }
    return (.accepted, [seekEffect])
  }

  private mutating func reduceDeadline(
    _ operationID: PlaybackOperationID
  ) -> (EventDisposition, [PlaybackEffect]) {
    guard var session = state.activeSession else {
      return (.stale(reason: .expiredDeadline), [])
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
    state.activeSession = session
    return (.accepted, [])
  }

  private mutating func makeApplicationEffect(
    executor: ExecutorKind,
    kind: PlaybackEffectKind,
    isCleanup: Bool,
    exclusiveKey: String?
  ) -> PlaybackEffect? {
    guard let operationID = state.allocator.allocateOperation() else { return nil }
    return makeEffect(
      authority: .application(state.applicationEpoch),
      operationID: operationID,
      executor: executor,
      kind: kind,
      isCleanup: isCleanup,
      exclusiveKey: exclusiveKey
    )
  }

  private mutating func makeEffect(
    authority: PlaybackAuthority,
    operationID: PlaybackOperationID,
    executor: ExecutorKind,
    kind: PlaybackEffectKind,
    isCleanup: Bool = false,
    exclusiveKey: String? = nil
  ) -> PlaybackEffect? {
    guard let effectID = state.allocator.allocateEffect() else { return nil }
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

  private mutating func register(_ effects: [PlaybackEffect]) {
    for effect in effects {
      guard effect.completion != .bestEffortMirror else { continue }
      state.outstandingEffects[effect.context.effectID] = OutstandingEffectRecord(effect: effect)
    }
  }

  private mutating func settleEffects(for authority: PlaybackAuthority) {
    let settled = state.outstandingEffects
      .filter { $0.value.effect.context.authority == authority }
      .map(\.key)
    for effectID in settled {
      state.outstandingEffects.removeValue(forKey: effectID)
      state.completedEffectIDs.insert(effectID)
    }
  }

  private func completionContract(
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

  private func authorityIsCurrent(_ authority: PlaybackAuthority) -> Bool {
    switch authority {
    case .application(let epoch):
      return epoch == state.applicationEpoch
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

  private func authorityMatchesActiveSession(_ authority: PlaybackAuthority) -> Bool {
    guard case .playback(let sessionID, let generation, _) = authority,
      let session = state.activeSession
    else { return false }
    return session.id == sessionID && session.generation == generation
  }

  private func staleAuthorityReason(_ authority: PlaybackAuthority) -> StaleReason {
    guard case .playback(let sessionID, let generation, _) = authority else {
      return .authorityMismatch
    }
    guard let session = session(matching: sessionID, generation: generation) else {
      if state.activeSession?.id != sessionID, state.pendingSession?.id != sessionID {
        return .sessionMismatch
      }
      return .generationMismatch
    }
    if sessionID != session.id { return .sessionMismatch }
    if generation != session.generation { return .generationMismatch }
    return .authorityMismatch
  }

  private func pendingSession(
    matching authority: PlaybackAuthority
  ) -> ActivePlaybackSession? {
    guard case .playback(let sessionID, let generation, _) = authority,
      let pending = state.pendingSession,
      pending.id == sessionID,
      pending.generation == generation
    else { return nil }
    return pending.value
  }

  private func session(
    matching sessionID: PlaybackSessionID,
    generation: PlaybackGenerationID
  ) -> ActivePlaybackSession? {
    if let active = state.activeSession,
      active.id == sessionID,
      active.generation == generation
    {
      return active
    }
    if let pending = state.pendingSession,
      pending.id == sessionID,
      pending.generation == generation
    {
      return pending.value
    }
    return nil
  }

  private func contextMismatch(
    _ expected: PlaybackEffectContext,
    _ actual: PlaybackEffectContext
  ) -> StaleReason {
    if expected.operationID != actual.operationID { return .operationMismatch }
    if expected.authority != actual.authority { return staleAuthorityReason(actual.authority) }
    return .authorityMismatch
  }

  private func genericFailure(for effect: PlaybackEffect) -> PlaybackFailure {
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

  private mutating func allocationFailure() -> (EventDisposition, [PlaybackEffect]) {
    state.lifecycle = .invariantFailed
    return (.invalid(reason: "monotonicIDExhausted"), [])
  }

  private func transition(
    disposition: EventDisposition,
    effects: [PlaybackEffect]
  ) -> PlaybackTransition {
    PlaybackTransition(
      disposition: disposition,
      effects: effects,
      snapshot: PlaybackUISnapshot(state: state),
      invariantViolations: PlaybackInvariantChecker.check(
        state: state,
        emittedEffects: effects
      )
    )
  }
}
