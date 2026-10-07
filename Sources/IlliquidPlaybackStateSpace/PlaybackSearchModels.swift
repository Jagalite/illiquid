import IlliquidPlaybackCore

public struct PlaybackSearchModelDefinition: Sendable {
  public let model: PlaybackSearchModel

  public init(model: PlaybackSearchModel) { self.model = model }

  public var modelVersion: UInt32 {
    switch model {
    // EOF advancement now waits for successful checkpoint completion. Bump
    // models sharing this core so prior reachable-key digests remain explicit.
    case .seek: 10
    case .eofDrain: 10
    case .recovery, .trackSubtitles, .stopShutdown, .prerollBuffering:
      9
    }
  }

  public var inventory: PlaybackSearchInventory {
    switch model {
    case .seek:
      return .init(
        seedProfiles: ["ready-playing", "ready-paused", "ended", "seek-in-flight"],
        actionClasses: [
          "exact", "keyframe", "preview", "relative", "superseding-seek",
          "pause", "eof", "shutdown", "success", "failure", "cancellation", "duplicate",
          "previous-generation", "wrong-operation", "unrelated-session", "executor-prerequisite",
        ],
        requiredScenarios: [
          "paused-restore-zero", "aggregate-before-rate", "seek-after-eof-rearm",
          "old-rate-stale", "old-frame-fenced", "old-subtitle-fenced", "shutdown-boundaries",
        ])
    case .eofDrain:
      return .init(
        seedProfiles: [
          "playing-av", "paused-av", "buffering-av", "seeking-av", "draining-av",
          "draining-stop", "draining-shutdown", "draining-seek",
          "draining-replacement",
          "playing-video", "playing-audio", "playing-empty",
        ],
        actionClasses: [
          "eof", "drain-component", "duplicate-eof", "unexpected-component", "seek",
          "stop", "replacement", "shutdown", "persistence-outcome", "playlist-outcome",
        ],
        requiredScenarios: [
          "all-drain-orders", "no-premature-finalization", "same-cycle-progress",
          "advance-at-most-once", "old-cycle-cannot-finalize", "aggregate-zero-required",
          "drain-interruptions-isolated",
        ])
    case .recovery:
      return .init(
        seedProfiles: [
          "playing-hardware", "prerolling-hardware", "software-active",
          "presentation-flush-consumed", "recovery-in-flight",
        ],
        actionClasses: [
          "video-failure", "software-outcome", "recurrent-failure", "replacement-lineage",
          "seek", "track", "stop", "shutdown", "presentation-flush", "graph-rebuild", "old-output",
        ],
        requiredScenarios: [
          "one-fallback-per-lineage", "seek-does-not-reset-budget", "terminal-exhaustion",
          "revision-fence", "interrupted-result-stale", "matching-outcome-settles",
        ])
    case .trackSubtitles:
      return .init(
        seedProfiles: ["automatic", "embedded-selected", "external-subtitle"],
        actionClasses: [
          "audio-select", "subtitle-select", "subtitle-off", "success", "failure",
          "cancellation", "in-flight-rejection", "invalid-id", "wrong-kind", "replacement", "seek",
          "stop", "shutdown", "invalidation", "overlay-current", "overlay-old",
        ],
        requiredScenarios: [
          "commit-only-on-success", "rollback", "explicit-inflight-rejection",
          "invalid-never-effective", "revision-monotonic", "clear-before-overlay",
        ])
    case .stopShutdown:
      return .init(
        seedProfiles: [
          "opening", "await-preroll", "seeking", "recovery", "track-replacement",
          "playing", "draining", "idle",
        ],
        actionClasses: [
          "stop", "shutdown", "duplicate-command", "cleanup-success", "cleanup-failure",
          "cleanup-cancellation", "late-result", "late-fact", "resource-custody",
        ],
        requiredScenarios: [
          "shutdown-monotonic", "cleanup-only", "terminated-quiescent",
          "late-callback-dropped", "cleanup-at-most-once", "explicit-finalization-wait",
        ])
    case .prerollBuffering:
      return .init(
        seedProfiles: [
          "opening-av", "partial-av", "playing-av", "playing-format", "buffering-av",
          "opening-video", "opening-audio", "opening-empty",
        ],
        actionClasses: [
          "video-ready", "audio-ready", "aggregate-preroll", "play", "pause", "starve",
          "supply", "queue-offer", "queue-consume", "seek", "stop", "shutdown", "eof",
          "format-change",
        ],
        requiredScenarios: [
          "single-startup-authority", "absent-stream-not-required", "partial-does-not-start",
          "paused-preroll-zero", "starvation-restores-desired", "queue-bounds",
          "control-preemption",
          "format-change-repreroll",
        ])
    }
  }

  public func makeSeed(profile: String) throws -> PlaybackSearchNode {
    guard inventory.seedProfiles.contains(profile) else {
      throw PlaybackSearchError.unknownSeed(model: model.rawValue, seed: profile)
    }
    var builder = ReachableSeedBuilder()
    switch model {
    case .seek:
      try builder.ready(autoplay: profile != "ready-paused")
      if profile == "ended" { _ = builder.send(.demuxEndOfFile(requiredDrain: [])) }
      if profile == "seek-in-flight" {
        _ = builder.send(.command(.seek(target: fixedTime(12), mode: .exact)))
      }
      return node(
        state: builder.core.state, seedProfile: profile,
        environment: .seek(SeekSearchEnvironment())
      )
    case .eofDrain:
      try builder.ready(autoplay: !profile.hasPrefix("paused"))
      if profile.hasPrefix("buffering") {
        _ = builder.send(.synchronization(.supplyObserved(starved: true, cacheMicroseconds: 0)))
      }
      if profile.hasPrefix("seeking") {
        _ = builder.send(.command(.seek(target: fixedTime(5), mode: .exact)))
      }
      if profile.hasPrefix("draining") {
        _ = builder.send(.demuxEndOfFile(requiredDrain: [.videoDecoder, .videoPresenter]))
      }
      return node(
        state: builder.core.state, seedProfile: profile,
        environment: .eofDrain(EOFDrainSearchEnvironment())
      )
    case .recovery:
      try builder.ready(autoplay: true)
      if profile == "software-active" {
        _ = builder.send(.failureObserved(videoFailure()))
        try builder.completeFirst(where: isRecovery)
        try builder.completeFirst(where: isRate)
      } else if profile == "presentation-flush-consumed" {
        _ = builder.send(.failureObserved(presentationFailure()))
        try builder.completeFirst(where: isRecovery)
        try builder.completeFirst(where: isRate)
      } else if profile == "recovery-in-flight" {
        _ = builder.send(.failureObserved(videoFailure()))
      }
      var environment = RecoverySearchEnvironment()
      if profile == "software-active" { environment.decoder = .configuredSoftware }
      if profile == "prerolling-hardware" { environment.presenter = .prerolling }
      if profile == "recovery-in-flight" { environment.decoder = .failed }
      return node(
        state: builder.core.state, seedProfile: profile,
        environment: .recovery(environment)
      )
    case .trackSubtitles:
      _ = builder.send(
        .command(.load(source: MediaSourceIdentity(rawValue: "seed"), autoplay: false)))
      _ = builder.send(.catalogObserved(fixedCatalog()))
      try builder.completeFirst(where: isOpen)
      try builder.completeFirst(where: isPreroll)
      if profile == "embedded-selected" {
        _ = builder.send(.command(.selectSubtitle(.embedded(subtitleTrack(1)))))
        try builder.completeFirst(where: isSubtitleSelection)
        try builder.completeFirst(where: isRate)
      }
      if profile == "external-subtitle" {
        _ = builder.send(
          .command(.selectSubtitle(.external(MediaSourceIdentity(rawValue: "external")))))
        try builder.completeFirst(where: isSubtitleSelection)
        try builder.completeFirst(where: isRate)
      }
      return node(
        state: builder.core.state, seedProfile: profile,
        environment: .trackSubtitles(TrackSubtitleSearchEnvironment())
      )
    case .stopShutdown:
      if profile != "idle" {
        _ = builder.send(
          .command(.load(source: MediaSourceIdentity(rawValue: "seed"), autoplay: true)))
        if profile != "opening" { try builder.completeFirst(where: isOpen) }
        if profile != "await-preroll" && profile != "opening" {
          try builder.completeFirst(where: isPreroll)
          try builder.completeFirst(where: isRate)
        }
        if profile == "seeking" {
          _ = builder.send(.command(.seek(target: fixedTime(9), mode: .exact)))
        }
        if profile == "recovery" { _ = builder.send(.failureObserved(videoFailure())) }
        if profile == "track-replacement" {
          _ = builder.send(.command(.selectAudio(.stream(audioTrack(2)))))
        }
        if profile == "draining" {
          _ = builder.send(.demuxEndOfFile(requiredDrain: [.videoDecoder]))
        }
      }
      return node(
        state: builder.core.state, seedProfile: profile,
        environment: .stopShutdown(StopShutdownSearchEnvironment())
      )
    case .prerollBuffering:
      _ = builder.send(
        .command(.load(source: MediaSourceIdentity(rawValue: "seed"), autoplay: true)))
      try builder.completeFirst(where: isOpen)
      let streams: Set<SynchronizedStream> =
        if profile.hasSuffix("video") { [.video] } else if profile.hasSuffix("audio") {
          [.audio]
        } else if profile.hasSuffix("empty") { [] } else { [.video, .audio] }
      _ = builder.send(.synchronization(.require(streams)))
      if profile == "partial-av" { _ = builder.send(.synchronization(.prerolled(.video))) }
      if profile == "playing-av" || profile == "playing-format" || profile == "buffering-av" {
        try builder.completeFirst(where: isPreroll)
        try builder.completeFirst(where: isRate)
      }
      if profile == "buffering-av" {
        _ = builder.send(.synchronization(.supplyObserved(starved: true, cacheMicroseconds: 0)))
      }
      var environment = PrerollBufferingSearchEnvironment()
      if profile == "opening-video" { environment.audioQueue = .absent }
      if profile == "opening-audio" { environment.videoQueue = .absent }
      if profile == "opening-empty" {
        environment.videoQueue = .absent
        environment.audioQueue = .absent
      }
      if profile == "playing-av" || profile == "playing-format" {
        environment.videoQueue = .partial
        environment.audioQueue = .partial
      }
      if profile == "buffering-av" {
        environment.videoQueue = .full
        environment.audioQueue = .full
      }
      return node(
        state: builder.core.state, seedProfile: profile,
        environment: .prerollBuffering(environment)
      )
    }
  }

  public func enabledActionClasses(for node: PlaybackSearchNode) -> [String] {
    enabledActions(for: node, configuration: .pr).map(\.stableClass).sorted()
  }

  func enabledActions(
    for node: PlaybackSearchNode,
    configuration: PlaybackSearchConfiguration
  ) -> [SearchAction] {
    if node.coreState.lifecycle == .terminated {
      var actions: [SearchAction] = [.command(.play)]
      if !node.lateResults.isEmpty, configuration.duplicateLimit > 0 {
        actions.append(.lateResult(index: 0))
      }
      actions.append(.runtimeFact(.eofAggregate, ingress: .previous))
      return actions
    }

    var actions = resultActions(node: node, configuration: configuration)
    let canCreateGeneration = node.ghost.generationChurn < configuration.generationLimit
    let pendingCount = node.coreState.outstandingEffects.count
    let hasWorkCapacity = pendingCount < max(configuration.pendingEffectLimit - 1, 1)
    let hasEOFCapacity = pendingCount <= max(configuration.pendingEffectLimit - 2, 0)
    let hasCleanupCapacity = pendingCount < configuration.pendingEffectLimit
    let canInterrupt = configuration.interruptLimit > 0
    switch model {
    case .seek:
      let hasSeekEffect = node.coreState.outstandingEffects.values.contains {
        isSeek($0.effect.kind)
      }
      if pendingCount == 0 {
        let phase = node.coreState.activeSession?.phase
        let canStartSeek = phase == .playing || phase == .paused || phase == .ended
        let profileAllowsAnotherSeek = node.ghost.generationChurn == 0
        if canCreateGeneration && canStartSeek && profileAllowsAnotherSeek {
          actions += [
            .command(.seekExact), .command(.seekKeyframe), .command(.seekPreview),
            .command(.seekRelative),
          ]
        }
        if node.seedProfile == "ready-paused" {
          actions.append(.command(.play))
        } else if node.seedProfile == "ready-playing" {
          actions.append(.command(.pause))
        }
        actions.append(.command(.invalidSeek))
        if node.seedProfile == "ended" {
          actions.append(.runtimeFact(.eofAggregate, ingress: .previous))
          if hasEOFCapacity { actions.append(.runtimeFact(.eofAggregate, ingress: .current)) }
        }
        if node.seedProfile == "seek-in-flight", hasCleanupCapacity {
          actions.append(.command(.shutdown))
        }
      } else if hasSeekEffect {
        if case .seek(let environment) = node.environment {
          let atNamedInterruptBoundary =
            environment.prerequisites.isEmpty
            || environment.prerequisites.isSuperset(of: SeekExecutorPrerequisite.allCases)
          if node.seedProfile == "seek-in-flight", environment.prerequisites.isEmpty,
            canCreateGeneration && hasWorkCapacity
          {
            actions.append(.command(.seekExact))
          }
          if node.seedProfile == "seek-in-flight", atNamedInterruptBoundary {
            if node.coreState.activeSession?.desiredTransport == .playing && hasWorkCapacity {
              actions.append(.command(.pause))
            }
            actions.append(.runtimeFact(.eofAggregate, ingress: .previous))
            if node.coreState.activeSession?.phase == .seeking && hasEOFCapacity {
              actions.append(.runtimeFact(.eofAggregate, ingress: .current))
            }
            if hasCleanupCapacity && canInterrupt { actions.append(.command(.shutdown)) }
          }
          if node.seedProfile == "seek-in-flight" {
            if environment.prerequisites.isEmpty { actions.append(.seekAggregateReady) }
          } else {
            actions += SeekExecutorPrerequisite.allCases.filter {
              !environment.prerequisites.contains($0)
            }.map(SearchAction.seekPrerequisite)
          }
        }
      } else if hasCleanupCapacity {
        actions.append(.command(.shutdown))
      }
    case .eofDrain:
      let drainFocused = [
        "playing-av", "paused-av", "playing-video", "playing-audio",
        "playing-empty",
      ].contains(node.seedProfile)
      let interruptFocused = [
        "buffering-av", "seeking-av", "draining-stop", "draining-shutdown",
        "draining-seek", "draining-replacement",
      ].contains(node.seedProfile)
      if hasEOFCapacity {
        let eof: SearchRuntimeFact =
          switch node.seedProfile {
          case "playing-video": .eofVideo
          case "playing-audio": .eofAudio
          case "playing-empty": .eofAggregate
          default: .eofAV
          }
        actions.append(.runtimeFact(eof, ingress: .current))
        if eof != .eofAggregate {
          actions.append(.runtimeFact(.eofAggregate, ingress: .current))
        }
      }
      actions.append(.runtimeFact(.eofAV, ingress: .previous))
      if interruptFocused && node.ghost.generationChurn == 0 {
        switch node.seedProfile {
        case "buffering-av":
          if hasCleanupCapacity { actions += [.command(.stop), .command(.shutdown)] }
        case "seeking-av":
          if canCreateGeneration && hasWorkCapacity { actions.append(.command(.seekExact)) }
          if hasCleanupCapacity { actions.append(.command(.shutdown)) }
        case "draining-stop":
          if hasCleanupCapacity { actions.append(.command(.stop)) }
        case "draining-shutdown":
          if hasCleanupCapacity { actions.append(.command(.shutdown)) }
        case "draining-seek":
          if canCreateGeneration && hasWorkCapacity { actions.append(.command(.seekExact)) }
        case "draining-replacement":
          if canCreateGeneration && hasWorkCapacity {
            actions.append(.command(.loadReplacement))
          }
        default: break
        }
      }
      if drainFocused || node.coreState.activeSession?.phase == .draining {
        actions += PlaybackDrainComponent.allCompatibilityComponents.map {
          .runtimeFact(runtimeFact(for: $0), ingress: .current)
        }
      }
    case .recovery:
      if case .recovery(let environment) = node.environment,
        node.coreState.outstandingEffects.values.contains(where: { isRecovery($0.effect.kind) })
      {
        if node.seedProfile == "recovery-in-flight" {
          if environment.prerequisites.isEmpty { actions.append(.recoveryAggregateReady) }
        } else {
          actions += RecoveryExecutorPrerequisite.allCases.filter {
            !environment.prerequisites.contains($0)
              && $0.dependencies.isSubset(of: environment.prerequisites)
          }.map(SearchAction.recoveryPrerequisite)
        }
      }
      if pendingCount == 0 && hasWorkCapacity {
        switch node.seedProfile {
        case "playing-hardware", "prerolling-hardware":
          if configuration.failureLimit > 0 {
            actions.append(.runtimeFact(.recoverableVideoFailure, ingress: .current))
          }
        case "software-active":
          if configuration.failureLimit > 0 {
            actions.append(.runtimeFact(.recurrentVideoFailure, ingress: .current))
          }
        case "presentation-flush-consumed":
          if configuration.failureLimit > 0 {
            actions.append(.runtimeFact(.presentationFailure, ingress: .current))
          }
        default: break
        }
      }
      if node.seedProfile == "recovery-in-flight" {
        if hasCleanupCapacity && canInterrupt { actions += [.command(.stop), .command(.shutdown)] }
        if canCreateGeneration && hasWorkCapacity && canInterrupt {
          actions += [.command(.seekExact), .command(.selectAudio)]
        }
      }
    case .trackSubtitles:
      let selectionInFlight = node.coreState.activeSession?.tracks.phase != .idle
      if selectionInFlight, case .trackSubtitles(let environment) = node.environment {
        if node.seedProfile == "automatic" {
          actions += TrackExecutorPrerequisite.allCases.filter {
            !environment.prerequisites.contains($0)
          }.map(SearchAction.trackPrerequisite)
        } else if environment.prerequisites.isEmpty {
          actions.append(.trackAggregateReady)
        }
      }
      if pendingCount == 0 && canCreateGeneration && hasWorkCapacity
        && node.ghost.generationChurn == 0
      {
        switch node.seedProfile {
        case "automatic":
          actions += [
            .command(.selectAudio), .command(.selectAudioInvalid),
            .command(.selectWrongKind),
          ]
        case "embedded-selected": actions += [.command(.selectSubtitle), .command(.subtitleOff)]
        case "external-subtitle":
          actions += [
            .command(.subtitleOff), .command(.selectSubtitleInvalid),
            .command(.setSubtitleDelay),
          ]
        default: break
        }
      }
      if selectionInFlight {
        // Current owner policy is explicit rejection, so keep one competing
        // request enabled without adding a second transaction.
        actions.append(
          node.seedProfile == "automatic"
            ? .command(.selectSubtitle) : .command(.selectAudio))
      }
      if node.seedProfile == "external-subtitle" {
        if case .trackSubtitles(let environment) = node.environment,
          environment.invalidations == 0, hasWorkCapacity
        {
          actions.append(.runtimeFact(.subtitleInvalidate, ingress: .current))
        }
        actions += [
          .runtimeFact(.oldOverlayCommit, ingress: .current),
          .runtimeFact(.currentOverlayCommit, ingress: .current),
          .runtimeFact(.installExternalSubtitle, ingress: .current),
        ]
      }
      if selectionInFlight && node.seedProfile == "embedded-selected" {
        if canCreateGeneration && hasWorkCapacity && canInterrupt {
          actions.append(.command(.seekExact))
        }
        if hasCleanupCapacity && canInterrupt { actions += [.command(.stop), .command(.shutdown)] }
      }
    case .stopShutdown:
      if hasCleanupCapacity { actions += [.command(.stop), .command(.shutdown)] }
      actions += [.runtimeFact(.eofAggregate, ingress: .previous), .resourceCustodyReturned]
    case .prerollBuffering:
      let opening = node.seedProfile.hasPrefix("opening") || node.seedProfile == "partial-av"
      if opening {
        if node.seedProfile != "opening-audio" {
          actions.append(.runtimeFact(.prerollVideo, ingress: .current))
        }
        if node.seedProfile != "opening-video" {
          actions.append(.runtimeFact(.prerollAudio, ingress: .current))
        }
        if hasWorkCapacity { actions += [.command(.play), .command(.pause)] }
        if node.seedProfile == "opening-av" && hasEOFCapacity {
          actions.append(.runtimeFact(.eofAggregate, ingress: .current))
        }
      } else {
        if node.seedProfile == "playing-av" {
          actions += [
            .runtimeFact(.starved, ingress: .current),
            .runtimeFact(.supplied, ingress: .current), .queueOffer(.video), .queueOffer(.audio),
            .queueConsume(.video), .queueConsume(.audio),
          ]
          if hasWorkCapacity { actions.append(.command(.pause)) }
        } else if node.seedProfile == "playing-format" {
          if hasWorkCapacity {
            actions += [.runtimeFact(.formatVideo, ingress: .current), .command(.pause)]
          }
          actions += [
            .runtimeFact(.prerollVideo, ingress: .current),
            .runtimeFact(.prerollAudio, ingress: .current),
          ]
        } else {
          actions.append(.runtimeFact(.supplied, ingress: .current))
          if node.ghost.generationChurn == 0,
            node.coreState.activeSession?.phase == .buffering
          {
            if hasCleanupCapacity { actions += [.command(.stop), .command(.shutdown)] }
            if canCreateGeneration && hasWorkCapacity { actions.append(.command(.seekExact)) }
          }
        }
      }
    }
    if !node.lateResults.isEmpty, configuration.duplicateLimit > 0 {
      actions.append(.lateResult(index: 0))
    }
    return stableUnique(actions)
  }

  private func resultActions(
    node: PlaybackSearchNode,
    configuration: PlaybackSearchConfiguration
  ) -> [SearchAction] {
    let effects = node.coreState.outstandingEffects.values.map(\.effect).sorted {
      let lhs = normalizedEffectClass($0, node: node)
      let rhs = normalizedEffectClass($1, node: node)
      return lhs == rhs ? $0.context.effectID < $1.context.effectID : lhs < rhs
    }.prefix(configuration.pendingEffectLimit)
    var actions: [SearchAction] = []
    for (index, effect) in effects.enumerated() {
      let successEnabled: Bool
      if isSeek(effect.kind), case .seek(let environment) = node.environment {
        successEnabled = environment.prerequisites.isSuperset(of: SeekExecutorPrerequisite.allCases)
      } else if isRecovery(effect.kind), case .recovery(let environment) = node.environment {
        successEnabled = environment.prerequisites.isSuperset(
          of: RecoveryExecutorPrerequisite.allCases
        )
      } else if isTrackSelection(effect.kind),
        case .trackSubtitles(let environment) = node.environment
      {
        successEnabled = environment.prerequisites.isSuperset(
          of: TrackExecutorPrerequisite.allCases)
      } else {
        successEnabled = true
      }
      if successEnabled {
        actions.append(
          .result(effectID: effect.context.effectID, outcome: .succeeded, mutation: .none))
      }
      if configuration.failureLimit > 0 {
        actions.append(
          .result(effectID: effect.context.effectID, outcome: .failed, mutation: .none))
      }
      actions.append(
        .result(effectID: effect.context.effectID, outcome: .cancelled, mutation: .none))
      if index == 0 {
        actions += mismatchClasses.map {
          .result(effectID: effect.context.effectID, outcome: .succeeded, mutation: $0)
        }
      } else if model == .stopShutdown {
        actions.append(
          .result(
            effectID: effect.context.effectID, outcome: .succeeded, mutation: .wrongOperation
          ))
      }
    }
    return actions
  }

  private var mismatchClasses: [SearchResultMutation] {
    switch model {
    case .seek: [.wrongOperation, .previousGeneration, .unrelatedSession, .undeclaredToken]
    case .eofDrain: [.wrongOperation, .previousGeneration]
    case .recovery: [.wrongRevision, .previousGeneration]
    case .trackSubtitles: [.wrongRevision, .wrongOperation]
    case .stopShutdown: [.wrongOperation, .unrelatedSession, .wrongEffect]
    case .prerollBuffering: [.undeclaredToken, .wrongOperation]
    }
  }

  private func node(
    state: PlaybackCoreState,
    seedProfile: String,
    environment: PlaybackModelEnvironment
  ) -> PlaybackSearchNode {
    PlaybackSearchNode(
      model: model, seedProfile: seedProfile, coreState: state, environment: environment,
      nextSequence: state.acceptedEventCount + state.rejectedEventCount + 1
    )
  }
}

public enum PlaybackSearchError: Error, Equatable {
  case unknownSeed(model: String, seed: String)
  case missingEffect(String)
}

private struct ReachableSeedBuilder {
  var core = PlaybackCore()
  var sequence: UInt64 = 1

  @discardableResult
  mutating func send(_ event: PlaybackEvent) -> PlaybackTransition {
    let transition = core.update(
      PlaybackEventEnvelope(
        sequence: sequence,
        virtualTime: PlaybackInstant(ticks: core.state.lastVirtualTime.ticks + 1),
        event: event
      ))
    sequence += 1
    return transition
  }

  mutating func ready(autoplay: Bool) throws {
    _ = send(.command(.load(source: MediaSourceIdentity(rawValue: "seed"), autoplay: autoplay)))
    try completeFirst(where: isOpen)
    try completeFirst(where: isPreroll)
    if autoplay { try completeFirst(where: isRate) }
    _ = send(.acceptedClockSample(fixedTime(10)))
  }

  mutating func completeFirst(where predicate: (PlaybackEffectKind) -> Bool) throws {
    guard
      let effect = core.state.outstandingEffects.values.map(\.effect).first(where: {
        predicate($0.kind)
      })
    else { throw PlaybackSearchError.missingEffect("seed effect") }
    _ = send(
      .effectResult(
        PlaybackEffectResult(
          context: effect.context, token: EffectResultToken(kind: .succeeded)
        )))
  }
}

func fixedTime(_ seconds: Int64) -> MediaTimestamp {
  .valid(ValidMediaTime(value: seconds, timescale: 1)!)
}

func videoFailure() -> PlaybackFailure {
  PlaybackFailure(
    domain: .videoDecode, stage: .receiveFrame, stableCode: "vtFallback",
    recoverability: .fallbackAvailable,
    streamID: PlaybackStreamID(kind: .video, demuxIndex: 0),
    hardwareWasConfigured: true, hardwareOutputWasObserved: true,
    consecutiveCount: RecoveryMachineState.hardwareDecodeFailureThreshold
  )
}

func presentationFailure() -> PlaybackFailure {
  PlaybackFailure(
    domain: .presentation, stage: .enqueue, stableCode: "presenterFlush",
    recoverability: .retryable
  )
}

func fixedCatalog() -> PlaybackCatalog {
  PlaybackCatalog(
    hasVideo: true,
    audio: [
      PlaybackTrackCandidate(id: audioTrack(1), isDefault: true),
      PlaybackTrackCandidate(id: audioTrack(2), isDefault: false),
    ],
    subtitles: [
      PlaybackTrackCandidate(id: subtitleTrack(1), isDefault: false),
      PlaybackTrackCandidate(id: subtitleTrack(2), isDefault: true),
    ]
  )
}

func audioTrack(_ value: Int64) -> PlaybackTrackID {
  PlaybackTrackID(kind: .audio, mediaTrackID: value)
}

func subtitleTrack(_ value: Int64) -> PlaybackTrackID {
  PlaybackTrackID(kind: .subtitle, mediaTrackID: value)
}

func isOpen(_ kind: PlaybackEffectKind) -> Bool {
  if case .openSource = kind { return true }
  return false
}

func isPreroll(_ kind: PlaybackEffectKind) -> Bool { kind == .awaitPreroll }
func isRate(_ kind: PlaybackEffectKind) -> Bool {
  if case .applyRate = kind { return true }
  return false
}
func isSubtitleSelection(_ kind: PlaybackEffectKind) -> Bool {
  if case .applySubtitleSelection = kind { return true }
  return false
}
func isSeek(_ kind: PlaybackEffectKind) -> Bool {
  switch kind {
  case .seek, .seekPipeline: true
  default: false
  }
}
func isRecovery(_ kind: PlaybackEffectKind) -> Bool {
  switch kind {
  case .resumeVideoDecoderAfterTransientFailure,
    .recreateVideoDecoderInSoftware, .flushPresentationForRecovery,
    .rebuildPresentationGraph, .flushAudioPresentationForRecovery,
    .rebuildAudioPresentation, .disableAudioTrack, .disableSubtitleTrack:
    true
  default: false
  }
}
func isTrackSelection(_ kind: PlaybackEffectKind) -> Bool {
  switch kind {
  case .applyAudioSelection, .applySubtitleSelection: true
  default: false
  }
}

func runtimeFact(for component: PlaybackDrainComponent) -> SearchRuntimeFact {
  switch component {
  case .videoDecoder: .drainVideoDecoder
  case .videoSubmission: .drainVideoSubmission
  case .videoPresenter: .drainVideoPresenter
  case .audioDecoder: .drainAudioDecoder
  case .audioConverter: .drainAudioConverter
  case .audioSubmission: .drainAudioSubmission
  case .audioPresenter: .drainAudioPresenter
  }
}

func stableUnique(_ actions: [SearchAction]) -> [SearchAction] {
  var seen: Set<SearchAction> = []
  return actions.sorted {
    $0.stableClass == $1.stableClass
      ? String(describing: $0) < String(describing: $1)
      : $0.stableClass < $1.stableClass
  }.filter { seen.insert($0).inserted }
}

func normalizedEffectClass(_ effect: PlaybackEffect, node: PlaybackSearchNode) -> String {
  let single = PlaybackSearchNode(
    model: node.model,
    coreState: PlaybackCoreState(
      lifecycle: node.coreState.lifecycle,
      activeSession: node.coreState.activeSession,
      outstandingEffects: [effect.context.effectID: OutstandingEffectRecord(effect: effect)]
    ),
    environment: node.environment
  )
  return PlaybackSearchCanonicalizer.key(for: single).effects.first?.stableDescription ?? ""
}
