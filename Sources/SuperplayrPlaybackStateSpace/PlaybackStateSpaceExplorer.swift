import Foundation
import SuperplayrPlaybackCore

public struct PlaybackStateSpaceExplorer: Sendable {
  public struct Progress: Sendable {
    public let model: PlaybackSearchModel
    public let seedProfile: String
    public let depth: Int
    public let stateCount: Int
    public let edgeCount: Int
    public let frontierCount: Int
  }

  public init() {}

  public func run(
    model: PlaybackSearchModel,
    seedProfile: String,
    configuration: PlaybackSearchConfiguration,
    oracle: PlaybackSearchOracle = .production,
    progressHandler: (@Sendable (Progress) -> Void)? = nil
  ) throws -> PlaybackSearchResult {
    let definition = PlaybackSearchModelDefinition(model: model)
    let seed = try definition.makeSeed(profile: seedProfile)
    var nodes = [seed]
    var keys = [PlaybackSearchCanonicalizer.key(for: seed)]
    var predecessors: [PlaybackSearchPredecessor?] = [nil]
    var visited: [PlaybackSearchStateKey: Int] = [keys[0]: 0]
    var graph = PlaybackSearchGraph()
    var failures: [PlaybackSearchFailure] = []
    var currentFrontier = [0]
    var peakFrontier = 1
    var edgeCount = 0
    var productionTransitions = 0
    var gateRejections = 0
    var reducedEdges = 0
    var validatedDiamonds = 0
    var nonCommutingDiamonds = 0
    var deepestLayer = 0
    var termination = PlaybackSearchTermination.completeWithinBounds
    let startNanoseconds = DispatchTime.now().uptimeNanoseconds
    let timeLimitNanoseconds: UInt64? = configuration.timeLimitSeconds.flatMap {
      value -> UInt64? in
      guard value.isFinite else { return nil }
      return UInt64(min(max(0, value), Double(UInt64.max) / 1_000_000_000)
        * 1_000_000_000)
    }

    layerLoop: for depth in 0..<configuration.depthLimit {
      guard !currentFrontier.isEmpty else { break }
      if let timeLimitNanoseconds,
        DispatchTime.now().uptimeNanoseconds - startNanoseconds >= timeLimitNanoseconds
      {
        termination = .timeBudgetReached
        break
      }
      var nextFrontier: [Int] = []
      for nodeIndex in currentFrontier {
        var actions = definition.enabledActions(for: nodes[nodeIndex], configuration: configuration)
        if configuration.porMode != .disabled {
          let reduction = PlaybackPartialOrderReducer.reduce(
            actions: actions, node: nodes[nodeIndex], definition: definition,
            configuration: configuration,
            validateDiamonds: configuration.porMode == .validation
          )
          actions = reduction.actions
          reducedEdges += reduction.removedCount
          validatedDiamonds += reduction.validatedDiamondCount
          nonCommutingDiamonds += reduction.nonCommutingDiamondCount
        }
        for action in actions {
          if let timeLimitNanoseconds,
            DispatchTime.now().uptimeNanoseconds - startNanoseconds >= timeLimitNanoseconds
          {
            termination = .timeBudgetReached
            break layerLoop
          }
          if edgeCount >= configuration.edgeLimit {
            termination = .edgeCapReached
            break layerLoop
          }
          let applied = apply(
            action: action, to: nodes[nodeIndex], configuration: configuration
          )
          var transitionViolations = applied.violations
          if let violation = oracle.violation(for: action, transition: applied.transition) {
            transitionViolations.append(violation)
          }
          edgeCount += 1
          if applied.calledProductionCore { productionTransitions += 1 }
          if applied.gateRejected { gateRejections += 1 }
          let successorKey = PlaybackSearchCanonicalizer.key(for: applied.node)
          let successorIndex: Int
          if let existing = visited[successorKey] {
            successorIndex = existing
          } else {
            if nodes.count >= configuration.stateLimit {
              termination = .stateCapReached
              break layerLoop
            }
            successorIndex = nodes.count
            visited[successorKey] = successorIndex
            nodes.append(applied.node)
            keys.append(successorKey)
            predecessors.append(PlaybackSearchPredecessor(nodeIndex: nodeIndex, action: action))
            nextFrontier.append(successorIndex)
          }
          for violation in transitionViolations {
            failures.append(
              PlaybackSearchFailure(
                invariantName: violation.name, details: violation.details,
                nodeIndex: successorIndex, fromNodeIndex: nodeIndex,
                action: action, depth: depth + 1
              ))
          }
          graph.edges.append(
            .init(
              from: nodeIndex, to: successorIndex, actionClass: action.stableClass,
              isFairProgress: applied.isFairProgress
            ))
        }
      }
      deepestLayer = depth + 1
      currentFrontier = nextFrontier
      peakFrontier = max(peakFrontier, currentFrontier.count)
      progressHandler?(
        Progress(
          model: model, seedProfile: seedProfile, depth: deepestLayer,
          stateCount: nodes.count, edgeCount: edgeCount,
          frontierCount: currentFrontier.count
        )
      )
    }

    let canonicalDigest = digest(keys: keys)
    let summary = PlaybackSearchSummary(
      model: model, modelVersion: definition.modelVersion,
      seedProfile: seedProfile, configuration: configuration,
      termination: termination, stateCount: nodes.count, edgeCount: edgeCount,
      productionTransitionCount: productionTransitions, gateRejectionCount: gateRejections,
      peakFrontier: peakFrontier, deepestCompletedLayer: deepestLayer,
      reducedEdgeCount: reducedEdges, validatedDiamondCount: validatedDiamonds,
      nonCommutingDiamondCount: nonCommutingDiamonds,
      canonicalDigest: canonicalDigest
    )
    return PlaybackSearchResult(
      summary: summary, oracle: oracle, failures: uniqueFailures(failures), graph: graph,
      nodes: nodes, predecessors: predecessors
    )
  }
}

struct AppliedSearchAction {
  var node: PlaybackSearchNode
  var transition: PlaybackTransition?
  var envelope: PlaybackEventEnvelope?
  var calledProductionCore: Bool
  var gateRejected: Bool
  var isFairProgress: Bool
  var violations: [PlaybackInvariantViolation]
}

func apply(
  action: SearchAction,
  to input: PlaybackSearchNode,
  configuration: PlaybackSearchConfiguration
) -> AppliedSearchAction {
  var node = input
  node.depth += 1
  let preSession = node.coreState.activeSession?.id
  let preGeneration = node.coreState.activeSession?.generation
  let preKey = PlaybackSearchCanonicalizer.key(for: node)
  var event: PlaybackEvent?
  var gateRejected = false
  var fairProgress = false
  var deliveredEffect: PlaybackEffect?
  var deliveredResult: PlaybackEffectResult?

  switch action {
  case .command(let command):
    event = .command(materialize(command))
    fairProgress = [.stop, .shutdown].contains(command)
    if command == .shutdown { node.ghost.everShutdown = true }
  case .result(let effectID, let outcome, let mutation):
    guard let effect = node.coreState.outstandingEffects[effectID]?.effect else {
      return noCore(node: node)
    }
    let result = materialize(effect: effect, outcome: outcome, mutation: mutation)
    deliveredEffect = effect
    deliveredResult = result
    event = .effectResult(result)
    fairProgress = mutation == .none
  case .lateResult(let index):
    guard node.lateResults.indices.contains(index) else { return noCore(node: node) }
    node.lateResults[index].deliveries += 1
    event = .effectResult(node.lateResults[index].result)
  case .runtimeFact(let fact, let ingress):
    if ingress != .current {
      gateRejected = true
    } else {
      if fact == .subtitleInvalidate,
        case .trackSubtitles(var environment) = node.environment
      {
        environment.invalidations += 1
        node.environment = .trackSubtitles(environment)
      }
      if case .recovery(var environment) = node.environment {
        switch fact {
        case .recoverableVideoFailure, .recurrentVideoFailure:
          environment.decoder = .failed
        case .presentationFailure:
          environment.presenter = .failed
        default:
          break
        }
        node.environment = .recovery(environment)
      }
      event = materialize(fact: fact, node: node)
      fairProgress = isFair(fact)
    }
  case .seekPrerequisite(let prerequisite):
    if case .seek(var environment) = node.environment {
      environment.prerequisites.insert(prerequisite)
      node.environment = .seek(environment)
    }
    return noCore(node: node, fair: true)
  case .seekAggregateReady:
    if case .seek(var environment) = node.environment {
      environment.prerequisites = Set(SeekExecutorPrerequisite.allCases)
      node.environment = .seek(environment)
    }
    return noCore(node: node, fair: true)
  case .recoveryPrerequisite(let prerequisite):
    if case .recovery(var environment) = node.environment {
      guard !environment.prerequisites.contains(prerequisite),
        prerequisite.dependencies.isSubset(of: environment.prerequisites)
      else {
        return noCore(node: node)
      }
      environment.prerequisites.insert(prerequisite)
      switch prerequisite {
      case .oldOutputFence:
        environment.presenter = .flushing
      case .decoderTeardown:
        environment.decoder = .invalidated
      case .softwareConfiguration:
        environment.decoder = .configuredSoftware
      case .presentationMembership:
        environment.presenter = .prerolling
      case .requiredStreamPreroll:
        environment.presenter = .active
      }
      node.environment = .recovery(environment)
    }
    return noCore(node: node, fair: true)
  case .trackPrerequisite(let prerequisite):
    if case .trackSubtitles(var environment) = node.environment {
      environment.prerequisites.insert(prerequisite)
      node.environment = .trackSubtitles(environment)
    }
    return noCore(node: node, fair: true)
  case .recoveryAggregateReady:
    if case .recovery(var environment) = node.environment {
      environment.prerequisites = Set(RecoveryExecutorPrerequisite.allCases)
      environment.decoder = .configuredSoftware
      environment.presenter = .active
      node.environment = .recovery(environment)
    }
    return noCore(node: node, fair: true)
  case .trackAggregateReady:
    if case .trackSubtitles(var environment) = node.environment {
      environment.prerequisites = Set(TrackExecutorPrerequisite.allCases)
      node.environment = .trackSubtitles(environment)
    }
    return noCore(node: node, fair: true)
  case .queueOffer(let stream):
    updateQueue(stream: stream, offer: true, node: &node)
    return noCore(node: node)
  case .queueConsume(let stream):
    updateQueue(stream: stream, offer: false, node: &node)
    return noCore(node: node, fair: true)
  case .resourceCustodyReturned:
    if case .stopShutdown(var environment) = node.environment {
      environment.resourcesReturned = true
      node.environment = .stopShutdown(environment)
    }
    return noCore(node: node, fair: true)
  }

  guard !gateRejected, let event else {
    return AppliedSearchAction(
      node: node, transition: nil, envelope: nil, calledProductionCore: false,
      gateRejected: gateRejected, isFairProgress: false, violations: []
    )
  }

  var core = PlaybackCore(state: node.coreState)
  let envelope = PlaybackEventEnvelope(
    sequence: node.nextSequence,
    virtualTime: PlaybackInstant(ticks: node.coreState.lastVirtualTime.ticks + 1),
    event: event
  )
  node.nextSequence += 1
  let transition = core.update(envelope)
  node.coreState = core.state
  if let deliveredEffect, let deliveredResult,
    node.coreState.outstandingEffects[deliveredEffect.context.effectID] == nil,
    node.lateResults.count < configuration.lateResultLimit
  {
    node.lateResults.append(RetainedEffectResult(effect: deliveredEffect, result: deliveredResult))
  }
  if preSession != node.coreState.activeSession?.id
    || preGeneration != node.coreState.activeSession?.generation
  {
    node.ghost.generationChurn += 1
    node.ghost.playlistAdvanceCount = .zero
    switch node.environment {
    case .seek(var environment):
      environment.playlistAdvanceCount = .zero
      environment.prerequisites.removeAll()
      node.environment = .seek(environment)
    case .eofDrain(var environment):
      environment.playlistAdvanceCount = .zero
      node.environment = .eofDrain(environment)
    case .recovery(var environment):
      environment.prerequisites.removeAll()
      node.environment = .recovery(environment)
    case .trackSubtitles(var environment):
      environment.prerequisites.removeAll()
      node.environment = .trackSubtitles(environment)
    default: break
    }
  }
  if transition.effects.contains(where: { $0.kind == .advancePlaylist }) {
    node.ghost.playlistAdvanceCount.increment()
  }
  synchronizeEnvironment(node: &node, transition: transition)

  var violations = transition.invariantViolations
  if node.ghost.playlistAdvanceCount == .twoOrMore {
    violations.append(
      .init(
        name: "playlistAdvancesAtMostOncePerEOFCycle",
        details: "The bounded EOF cycle emitted playlist advancement more than once."
      ))
  }
  if case .stale = transition.disposition {
    let postKey = PlaybackSearchCanonicalizer.key(for: node)
    if preKey.lifecycle != postKey.lifecycle || preKey.externalWait != postKey.externalWait
      || preKey.session != postKey.session || preKey.leases != postKey.leases
    {
      violations.append(
        .init(
          name: "staleResultChangedSemanticState",
          details: "A stale transition changed the normalized production semantic state."
        ))
    }
  }
  return AppliedSearchAction(
    node: node, transition: transition, envelope: envelope, calledProductionCore: true,
    gateRejected: false, isFairProgress: fairProgress, violations: violations
  )
}

func noCore(
  node: PlaybackSearchNode,
  fair: Bool = false
) -> AppliedSearchAction {
  AppliedSearchAction(
    node: node, transition: nil, envelope: nil, calledProductionCore: false,
    gateRejected: false, isFairProgress: fair, violations: []
  )
}

func materialize(_ command: SearchCommand) -> PlaybackCommand {
  switch command {
  case .loadReplacement: .load(source: MediaSourceIdentity(rawValue: "replacement"), autoplay: true)
  case .play: .play
  case .pause: .pause
  case .seekExact: .seek(target: fixedTime(20), mode: .exact)
  case .seekKeyframe: .seek(target: fixedTime(20), mode: .keyframe)
  case .seekPreview: .seek(target: fixedTime(20), mode: .preview)
  case .seekRelative: .seek(target: fixedTime(2), mode: .relative)
  case .selectAudio: .selectAudio(.stream(audioTrack(2)))
  case .selectSubtitle: .selectSubtitle(.embedded(subtitleTrack(2)))
  case .subtitleOff: .selectSubtitle(.off)
  case .selectAudioInvalid:
    .selectAudio(.stream(PlaybackTrackID(kind: .audio, mediaTrackID: -1)))
  case .selectSubtitleInvalid:
    .selectSubtitle(.embedded(PlaybackTrackID(kind: .subtitle, mediaTrackID: -1)))
  case .selectWrongKind:
    .selectAudio(.stream(PlaybackTrackID(kind: .subtitle, mediaTrackID: 2)))
  case .setSubtitleDelay: .setSubtitleDelay(microseconds: 250_000)
  case .stop: .stop
  case .shutdown: .shutdown
  case .invalidSeek: .seek(target: .invalid(.zeroTimescale), mode: .exact)
  }
}

func materialize(
  effect: PlaybackEffect,
  outcome: SearchResultOutcome,
  mutation: SearchResultMutation
) -> PlaybackEffectResult {
  var authority = effect.context.authority
  var operation = effect.context.operationID
  var effectID = effect.context.effectID
  switch mutation {
  case .none, .undeclaredToken: break
  case .wrongOperation:
    operation = PlaybackOperationID(rawValue: operation.rawValue &+ 100)
  case .previousGeneration:
    if case .playback(let session, let generation, let revisions) = authority {
      authority = .playback(
        sessionID: session,
        generation: PlaybackGenerationID(
          rawValue: generation.rawValue == 0 ? 0 : generation.rawValue - 1),
        revisions: revisions
      )
    }
  case .unrelatedSession:
    if case .playback(_, let generation, let revisions) = authority {
      authority = .playback(
        sessionID: PlaybackSessionID(rawValue: 9_999), generation: generation, revisions: revisions
      )
    }
  case .wrongEffect:
    effectID = PlaybackEffectID(rawValue: effectID.rawValue &+ 100)
  case .wrongRevision:
    if case .playback(let session, let generation, var revisions) = authority {
      revisions.track = TrackRevisionID(rawValue: (revisions.track?.rawValue ?? 0) &+ 100)
      authority = .playback(sessionID: session, generation: generation, revisions: revisions)
    }
  }
  let kind: EffectResultKind =
    switch outcome {
    case .succeeded: .succeeded
    case .failed: .failed
    case .cancelled: .cancelled
    }
  let token = EffectResultToken(
    kind: kind, component: mutation == .undeclaredToken ? "undeclared" : nil
  )
  let failure: PlaybackFailure? =
    outcome == .failed
    ? PlaybackFailure(
      domain: .resource, stage: .callback, stableCode: "boundedFailure",
      recoverability: .retryable
    ) : nil
  return PlaybackEffectResult(
    context: PlaybackEffectContext(
      authority: authority, operationID: operation, effectID: effectID
    ),
    token: token, failure: failure
  )
}

func materialize(fact: SearchRuntimeFact, node: PlaybackSearchNode) -> PlaybackEvent? {
  switch fact {
  case .eofAV:
    return .demuxEndOfFile(requiredDrain: Set(PlaybackDrainComponent.allCompatibilityComponents))
  case .eofVideo:
    return .demuxEndOfFile(requiredDrain: [.videoDecoder, .videoSubmission, .videoPresenter])
  case .eofAudio:
    return .demuxEndOfFile(requiredDrain: [
      .audioDecoder, .audioConverter, .audioSubmission, .audioPresenter,
    ])
  case .eofAggregate: return .demuxEndOfFile(requiredDrain: [])
  case .drainVideoDecoder: return .drainObserved(.videoDecoder)
  case .drainVideoSubmission: return .drainObserved(.videoSubmission)
  case .drainVideoPresenter: return .drainObserved(.videoPresenter)
  case .drainAudioDecoder: return .drainObserved(.audioDecoder)
  case .drainAudioConverter: return .drainObserved(.audioConverter)
  case .drainAudioSubmission: return .drainObserved(.audioSubmission)
  case .drainAudioPresenter: return .drainObserved(.audioPresenter)
  case .prerollVideo: return .synchronization(.prerolled(.video))
  case .prerollAudio: return .synchronization(.prerolled(.audio))
  case .starved: return .synchronization(.supplyObserved(starved: true, cacheMicroseconds: 0))
  case .supplied:
    return .synchronization(.supplyObserved(starved: false, cacheMicroseconds: 500_000))
  case .subtitleInvalidate: return .subtitle(.invalidate(reason: .trackChange))
  case .recoverableVideoFailure, .recurrentVideoFailure: return .failureObserved(videoFailure())
  case .presentationFailure: return .failureObserved(presentationFailure())
  case .oldOverlayCommit:
    guard let session = node.coreState.activeSession else { return nil }
    let old =
      session.subtitles.overlayRevision.rawValue == 0
      ? 0 : session.subtitles.overlayRevision.rawValue - 1
    return .subtitle(
      .overlayCommitCandidate(
        authority: session.authority, revision: OverlayRevisionID(rawValue: old)
      ))
  case .currentOverlayCommit:
    guard let session = node.coreState.activeSession else { return nil }
    return .subtitle(
      .overlayCommitCandidate(
        authority: session.authority, revision: session.subtitles.overlayRevision
      ))
  case .formatVideo:
    let current = node.coreState.activeSession?.revisions.videoFormat?.rawValue ?? 0
    return .synchronization(
      .formatChanged(
        stream: .video, revision: MediaFormatRevisionID(rawValue: current + 1)
      ))
  case .installExternalSubtitle:
    return .subtitle(
      .sourceInstalled(
        MediaSourceIdentity(rawValue: "external-subtitle"), external: true
      ))
  }
}

func isFair(_ fact: SearchRuntimeFact) -> Bool {
  switch fact {
  case .drainVideoDecoder, .drainVideoSubmission, .drainVideoPresenter,
    .drainAudioDecoder, .drainAudioConverter, .drainAudioSubmission, .drainAudioPresenter,
    .prerollVideo, .prerollAudio, .supplied:
    true
  default: false
  }
}

func updateQueue(stream: SynchronizedStream, offer: Bool, node: inout PlaybackSearchNode) {
  guard case .prerollBuffering(var environment) = node.environment else { return }
  var queue = stream == .video ? environment.videoQueue : environment.audioQueue
  if offer {
    queue =
      switch queue {
      case .empty: .partial
      case .partial: .full
      case .absent, .full, .draining, .invalidated: queue
      }
  } else {
    queue =
      switch queue {
      case .full: .partial
      case .partial: .empty
      case .absent, .empty, .draining, .invalidated: queue
      }
  }
  if stream == .video { environment.videoQueue = queue } else { environment.audioQueue = queue }
  node.environment = .prerollBuffering(environment)
}

func synchronizeEnvironment(node: inout PlaybackSearchNode, transition: PlaybackTransition) {
  if let reason = node.coreState.externalWaitReason {
    node.ghost.externalWait =
      reason == .shutdownCancellationFailed
      ? .shutdownCancellationFailure : .shutdownFinalizationFailure
  }
  if transition.effects.contains(where: { $0.kind == .advancePlaylist }) {
    switch node.environment {
    case .seek(var environment):
      environment.playlistAdvanceCount.increment()
      node.environment = .seek(environment)
    case .eofDrain(var environment):
      environment.playlistAdvanceCount.increment()
      node.environment = .eofDrain(environment)
    default: break
    }
  }
  if case .stopShutdown(var environment) = node.environment {
    environment.everShutdown = node.ghost.everShutdown
    environment.externalWait = node.ghost.externalWait
    for effect in transition.effects where effect.isCleanup {
      let key = normalizedEffectClass(effect, node: node)
      var count = environment.cleanupApplications[key] ?? .zero
      count.increment()
      environment.cleanupApplications[key] = count
    }
    node.environment = .stopShutdown(environment)
  }
  if case .prerollBuffering(var environment) = node.environment {
    environment.startupSatisfied =
      node.coreState.activeSession?.synchronization.startupAcknowledged == true
    node.environment = .prerollBuffering(environment)
  }
}

func digest(keys: [PlaybackSearchStateKey]) -> String {
  var hash: UInt64 = 14_695_981_039_346_656_037
  for digest in keys.map(PlaybackSearchCanonicalizer.digest).sorted() {
    for byte in digest.utf8 {
      hash ^= UInt64(byte)
      hash &*= 1_099_511_628_211
    }
  }
  return "fnv1a64:" + String(hash, radix: 16)
}

func uniqueFailures(_ failures: [PlaybackSearchFailure]) -> [PlaybackSearchFailure] {
  var names: Set<String> = []
  return failures.filter { names.insert("\($0.invariantName)|\($0.details)").inserted }
}
