import Foundation
import Testing
@testable import IlliquidPlaybackCore

@Suite("Renderer recovery regression coverage")
struct RendererRecoveryRegressionTests {
  enum Route: String, CaseIterable, Sendable {
    case videoFlush, videoRebuild, hardwareFallback, softwareRestart, transientVideo
    case audioFlush, audioRebuild, disableAudio, disableSubtitle

    var restartsPresentation: Bool {
      switch self {
      case .videoFlush, .videoRebuild, .hardwareFallback, .softwareRestart,
        .audioFlush, .audioRebuild: true
      case .transientVideo, .disableAudio, .disableSubtitle: false
      }
    }
  }

  private func readyRuntime(autoplay: Bool = true) throws -> PlaybackModelRuntime {
    var runtime = PlaybackModelRuntime(recordsReplaySteps: false)
    let load = runtime.send(.command(.load(
      source: MediaSourceIdentity(rawValue: "fixture/recovery.mkv"), autoplay: autoplay
    )))
    #expect(load.invariantViolations.isEmpty)
    for _ in 0..<3 {
      if let step = runtime.completeNext() { #expect(step.invariantViolations.isEmpty) }
    }
    #expect(runtime.pendingEffects.isEmpty)
    #expect(runtime.core.state.activeSession?.phase == (autoplay ? .playing : .paused))
    let catalog = runtime.send(.catalogObserved(PlaybackCatalog(
      hasVideo: true, audio: [PlaybackTrackCandidate(
        id: PlaybackTrackID(kind: .audio, mediaTrackID: 1), isDefault: true
      )]
    )))
    #expect(catalog.invariantViolations.isEmpty)
    return runtime
  }

  private func presentationFailure(
    stage: PlaybackFailure.Stage = .enqueue,
    recoverability: PlaybackFailure.Recoverability = .retryable
  ) -> PlaybackFailure {
    PlaybackFailure(
      domain: .presentation, stage: stage, stableCode: "requiresFlushToResumeDecoding",
      recoverability: recoverability
    )
  }

  private var terminalFailure: PlaybackFailure {
    PlaybackFailure(
      domain: .demux, stage: .read, stableCode: "terminalReadFailure", recoverability: .fatal
    )
  }

  private func complete(
    _ effect: PlaybackEffect, runtime: inout PlaybackModelRuntime
  ) throws -> PlaybackTransition {
    let result = runtime.complete(effectID: effect.context.effectID)
    let completed = try #require(result)
    #expect(completed.invariantViolations.isEmpty)
    return completed
  }

  private func finishRecovery(
    _ effect: PlaybackEffect, runtime: inout PlaybackModelRuntime
  ) throws {
    let completion = try complete(effect, runtime: &runtime)
    for next in completion.effects { _ = try complete(next, runtime: &runtime) }
  }

  private func startRecovery(
    _ route: Route, runtime: inout PlaybackModelRuntime
  ) throws -> PlaybackEffect {
    let video = PlaybackStreamID(kind: .video, demuxIndex: 0)
    let audio = PlaybackStreamID(kind: .audio, demuxIndex: 1)
    let failure: PlaybackFailure
    switch route {
    case .videoFlush, .videoRebuild:
      failure = presentationFailure()
    case .hardwareFallback, .transientVideo:
      failure = PlaybackFailure(
        domain: .videoDecode, stage: .receiveFrame, stableCode: "videoDecodeFailed",
        recoverability: .fallbackAvailable, streamID: video, hardwareWasConfigured: true,
        consecutiveCount: route == .transientVideo ? 1 : 3
      )
    case .softwareRestart:
      failure = PlaybackFailure(
        domain: .videoDecode, stage: .receiveFrame, stableCode: "softwareVideoDecoderNoProgress",
        recoverability: .fallbackAvailable, streamID: video
      )
    case .audioFlush, .audioRebuild:
      failure = PlaybackFailure(
        domain: .audioDecode, stage: .enqueue, stableCode: "nativeAudioPresentationFailed",
        recoverability: .fallbackAvailable, streamID: audio
      )
    case .disableAudio:
      failure = PlaybackFailure(
        domain: .audioDecode, stage: .receiveFrame, stableCode: "nativeAudioDecodeFailed",
        recoverability: .fallbackAvailable, streamID: audio
      )
    case .disableSubtitle:
      failure = PlaybackFailure(
        domain: .subtitle, stage: .read, stableCode: "nativeSubtitleReadFailed",
        recoverability: .fallbackAvailable,
        streamID: PlaybackStreamID(kind: .subtitle, demuxIndex: 2)
      )
    }
    if route == .videoRebuild || route == .audioRebuild {
      let first = runtime.send(.failureObserved(failure))
      let effect = try #require(first.effects.first)
      try finishRecovery(effect, runtime: &runtime)
    }
    let transition = runtime.send(.failureObserved(failure))
    #expect(transition.invariantViolations.isEmpty)
    #expect(transition.effects.count == 1)
    return try #require(transition.effects.first)
  }

  @Test(arguments: [true, false], [PlaybackFailure.Stage.enqueue, .flush, .render])
  func actualCoreEscalatesAcrossCommittedRevisions(
    autoplay: Bool, stage: PlaybackFailure.Stage
  ) throws {
    var runtime = try readyRuntime(autoplay: autoplay)
    let failure = presentationFailure(stage: stage)
    let first = runtime.send(.failureObserved(failure))
    let flush = try #require(first.effects.first)
    #expect(flush.kind == .flushPresentationForRecovery(revision: .init(rawValue: 1)))
    #expect(runtime.core.state.activeSession?.revisions.presentation?.rawValue == 1)
    try finishRecovery(flush, runtime: &runtime)

    let second = runtime.send(.failureObserved(failure))
    let rebuild = try #require(second.effects.first)
    #expect(rebuild.kind == .rebuildPresentationGraph(revision: .init(rawValue: 1)))
    #expect(runtime.core.state.activeSession?.revisions.presentationGraph?.rawValue == 1)
    try finishRecovery(rebuild, runtime: &runtime)

    let third = runtime.send(.failureObserved(failure))
    #expect(third.effects.isEmpty)
    #expect(third.snapshot.phase == .failed)
    #expect(third.snapshot.actualTransport == .stopped)
    #expect(third.snapshot.failureCode == failure.stableCode)
    #expect(runtime.core.state.activeSession?.recovery.presentationFlushConsumed.count == 1)
  }

  @Test(arguments: Route.allCases, [EffectResultKind.succeeded, .failed, .cancelled])
  func lateRecoveryResultPreservesTerminalFailure(route: Route, token: EffectResultKind) throws {
    var runtime = try readyRuntime()
    let recovery = try startRecovery(route, runtime: &runtime)
    let failed = runtime.send(.failureObserved(terminalFailure))
    #expect(failed.snapshot.phase == .failed)
    let before = runtime.core.state.activeSession
    let result = PlaybackEffectResult(
      context: recovery.context, token: EffectResultToken(kind: token),
      failure: token == .succeeded ? nil : PlaybackFailure(
        domain: .presentation, stage: .callback,
        stableCode: "olderRecoveryResult", recoverability: .fatal
      )
    )
    let late = runtime.send(.effectResult(result))
    #expect(late.disposition == .stale(reason: .operationMismatch))
    #expect(late.effects.isEmpty)
    #expect(late.invariantViolations.isEmpty)
    #expect(runtime.core.state.activeSession == before)
    #expect(runtime.core.state.outstandingEffects[recovery.context.effectID] == nil)
    let duplicate = runtime.send(.effectResult(result))
    #expect(duplicate.disposition == .duplicate(effectID: recovery.context.effectID))
    #expect(runtime.core.state.activeSession == before)
  }

  @Test(arguments: Route.allCases)
  func recoveryCompletionAfterItsDeadlineCannotRevivePlayback(route: Route) throws {
    var runtime = try readyRuntime()
    let recovery = try startRecovery(route, runtime: &runtime)
    let timeout = runtime.send(.deadlineReached(operationID: recovery.context.operationID))
    #expect(timeout.snapshot.failureCode == "operationTimedOut")
    let before = runtime.core.state.activeSession
    let completion = try complete(recovery, runtime: &runtime)
    #expect(completion.disposition == .stale(reason: .operationMismatch))
    #expect(completion.effects.isEmpty)
    #expect(runtime.core.state.activeSession == before)
  }

  @Test(arguments: Route.allCases.filter(\.restartsPresentation), [true, false])
  func recoveryRateResultCannotReviveTerminalFailure(route: Route, useDeadline: Bool) throws {
    var runtime = try readyRuntime()
    let recovery = try startRecovery(route, runtime: &runtime)
    let completion = try complete(recovery, runtime: &runtime)
    let rate = try #require(completion.effects.first)
    guard case .applyRate = rate.kind else {
      Issue.record("Expected a recovery resume-rate effect")
      return
    }
    if useDeadline {
      _ = runtime.send(.deadlineReached(operationID: rate.context.operationID))
    } else {
      _ = runtime.send(.failureObserved(terminalFailure))
    }
    let before = runtime.core.state.activeSession
    let late = try complete(rate, runtime: &runtime)
    #expect(late.disposition == .stale(reason: .operationMismatch))
    #expect(late.effects.isEmpty)
    #expect(runtime.core.state.activeSession == before)
  }

  @Test
  func furtherFailureObservationsDoNotRestartATerminalSession() throws {
    var runtime = try readyRuntime()
    _ = runtime.send(.failureObserved(terminalFailure))
    let before = runtime.core.state.activeSession
    for _ in 0..<100 {
      let ignored = runtime.send(.failureObserved(presentationFailure()))
      #expect(ignored.disposition == .stale(reason: .operationMismatch))
      #expect(ignored.effects.isEmpty)
      #expect(runtime.core.state.activeSession == before)
    }
  }

  @Test(arguments: [PlaybackFailure.Stage.enqueue, .flush, .render],
    [PlaybackFailure.Recoverability.fatal, .cancelled])
  func terminalPresentationClassificationDoesNotSpendRetryBudget(
    stage: PlaybackFailure.Stage, recoverability: PlaybackFailure.Recoverability
  ) {
    var recovery = RecoveryMachineState()
    let directive = recovery.classify(
      presentationFailure(stage: stage, recoverability: recoverability),
      sessionID: .init(rawValue: 1), revisions: PlaybackRevisionSet()
    )
    #expect(directive == .failTerminal)
    #expect(recovery.presentationFlushConsumed.isEmpty)
    #expect(recovery.presentationGraphRebuildCount == 0)
  }

  @Test(arguments: Route.allCases.filter(\.restartsPresentation))
  func pauseDuringRecoveryIsRespectedWithoutRequiringCurrentOperationID(route: Route) throws {
    var runtime = try readyRuntime()
    let recovery = try startRecovery(route, runtime: &runtime)
    let pause = runtime.send(.command(.pause))
    for effect in pause.effects { _ = try complete(effect, runtime: &runtime) }
    #expect(runtime.core.state.activeSession?.activeOperationID != recovery.context.operationID)
    try finishRecovery(recovery, runtime: &runtime)
    #expect(runtime.core.state.activeSession?.phase == .paused)
    #expect(runtime.core.state.activeSession?.actualTransport == .paused)
    #expect(runtime.core.state.activeSession?.lastFailure == nil)
  }

  @Test
  func seekingDoesNotRefundTheRendererBudget() throws {
    var runtime = try readyRuntime()
    let flush = try startRecovery(.videoFlush, runtime: &runtime)
    try finishRecovery(flush, runtime: &runtime)
    let time = try #require(ValidMediaTime(value: 12, timescale: 1))
    let seek = runtime.send(.command(.seek(target: .valid(time), mode: .exact)))
    let effect = try #require(seek.effects.first)
    try finishRecovery(effect, runtime: &runtime)
    let failure = runtime.send(.failureObserved(presentationFailure()))
    let rebuild = try #require(failure.effects.first)
    #expect(rebuild.kind == .rebuildPresentationGraph(revision: .init(rawValue: 1)))
  }

  @Test
  func aNewLoadRestoresTheBudgetAfterTerminalFailure() throws {
    var runtime = try readyRuntime()
    let flush = try startRecovery(.videoFlush, runtime: &runtime)
    _ = runtime.send(.failureObserved(terminalFailure))
    _ = runtime.send(.command(.load(
      source: MediaSourceIdentity(rawValue: "fixture/replacement.mkv"), autoplay: true
    )))
    for _ in 0..<4 {
      if let effect = runtime.pendingEffects.first(where: {
        if case .openSource = $0.kind { return true }
        if case .awaitPreroll = $0.kind { return true }
        if case .applyRate = $0.kind { return true }
        return false
      }) { _ = try complete(effect, runtime: &runtime) }
    }
    #expect(runtime.core.state.activeSession?.phase == .playing)
    #expect(runtime.core.state.activeSession?.recovery.presentationFlushConsumed.isEmpty == true)
    let old = runtime.send(.effectResult(PlaybackEffectResult(
      context: flush.context, token: EffectResultToken(kind: .succeeded)
    )))
    #expect(old.effects.isEmpty)
    let next = try startRecovery(.videoFlush, runtime: &runtime)
    #expect(next.kind == .flushPresentationForRecovery(revision: .init(rawValue: 1)))
  }

  @Test(arguments: [true, false])
  func overlappingRendererRecoveriesStayTerminalRegardlessOfCallbackOrder(
    flushFirst: Bool
  ) throws {
    var runtime = try readyRuntime()
    let first = runtime.send(.failureObserved(presentationFailure()))
    let flush = try #require(first.effects.first)
    let second = runtime.send(.failureObserved(presentationFailure()))
    let rebuild = try #require(second.effects.first)
    let terminal = runtime.send(.failureObserved(presentationFailure()))
    #expect(terminal.snapshot.phase == .failed)
    let before = runtime.core.state.activeSession
    for effect in flushFirst ? [flush, rebuild] : [rebuild, flush] {
      let result = try complete(effect, runtime: &runtime)
      #expect(result.effects.isEmpty)
      #expect(runtime.core.state.activeSession == before)
    }
    #expect(runtime.pendingEffects.isEmpty)
  }

  @Test
  func persistenceAndTeardownStillCompleteAfterTerminalFailure() throws {
    var runtime = try readyRuntime()
    let checkpoint = runtime.send(.command(.checkpoint))
    let persistence = try #require(checkpoint.effects.first)
    _ = runtime.send(.failureObserved(terminalFailure))
    let before = runtime.core.state.activeSession
    _ = try complete(persistence, runtime: &runtime)
    #expect(runtime.core.state.activeSession == before)
    let stop = runtime.send(.command(.stop))
    let cancellation = try #require(stop.effects.first)
    let stopping = runtime.core.state.activeSession
    let observation = runtime.send(.failureObserved(presentationFailure()))
    #expect(observation.disposition == .stale(reason: .operationMismatch))
    #expect(observation.effects.isEmpty)
    #expect(runtime.core.state.activeSession == stopping)
    _ = try complete(cancellation, runtime: &runtime)
    #expect(runtime.core.state.activeSession == nil)
  }

  @Test
  func failureOfARecoveryEffectIsNotErasedByAnOlderOptionalTrackCompletion() throws {
    var runtime = try readyRuntime()
    let first = try startRecovery(.disableSubtitle, runtime: &runtime)
    let second = try startRecovery(.disableAudio, runtime: &runtime)
    let failed = runtime.send(.effectResult(PlaybackEffectResult(
      context: second.context, token: EffectResultToken(kind: .failed), failure: terminalFailure
    )))
    #expect(failed.snapshot.phase == .failed)
    let before = runtime.core.state.activeSession
    let late = try complete(first, runtime: &runtime)
    #expect(late.disposition == .stale(reason: .operationMismatch))
    #expect(late.effects.isEmpty)
    #expect(runtime.core.state.activeSession == before)
  }

  @Test(arguments: [
    PlaybackEvent.synchronization(.supplyObserved(starved: true, cacheMicroseconds: 0)),
    .synchronization(.formatChanged(stream: .video, revision: .init(rawValue: 1))),
    .lifecycle(.systemWillSleep), .lifecycle(.systemDidWake),
    .demuxEndOfFile(requiredDrain: []),
  ])
  func automaticObservationsCannotReopenATerminalRecovery(event: PlaybackEvent) throws {
    var runtime = try readyRuntime()
    let recovery = try startRecovery(.videoFlush, runtime: &runtime)
    _ = runtime.send(.failureObserved(terminalFailure))
    let before = runtime.core.state.activeSession
    let observation = runtime.send(event)
    #expect(observation.disposition == .stale(reason: .operationMismatch))
    #expect(observation.effects.isEmpty)
    #expect(runtime.core.state.activeSession == before)
    let late = try complete(recovery, runtime: &runtime)
    #expect(late.effects.isEmpty)
    #expect(runtime.core.state.activeSession == before)
  }

  @Test(arguments: [
    PlaybackEvent.command(.seek(
      target: .valid(ValidMediaTime(value: 12, timescale: 1)!), mode: .exact
    )),
    .synchronization(.formatChanged(stream: .video, revision: .init(rawValue: 1))),
    .lifecycle(.systemDidWake),
    .command(.setSubtitleDelay(microseconds: 250_000)),
  ], [EffectResultKind.succeeded, .failed, .cancelled])
  func otherPendingPlaybackResultsCannotBypassTheTerminalFence(
    event: PlaybackEvent, token: EffectResultKind
  ) throws {
    var runtime = try readyRuntime()
    let pending = runtime.send(event)
    let effect = try #require(pending.effects.first)
    _ = runtime.send(.failureObserved(terminalFailure))
    let before = runtime.core.state.activeSession
    let late = runtime.send(.effectResult(PlaybackEffectResult(
      context: effect.context, token: EffectResultToken(kind: token),
      failure: token == .succeeded ? nil : PlaybackFailure(
        domain: .platform, stage: .callback, stableCode: "olderOperationFailure",
        recoverability: .fatal
      )
    )))
    #expect(late.disposition == .stale(reason: .operationMismatch))
    #expect(late.effects.isEmpty)
    #expect(runtime.core.state.activeSession == before)
    #expect(runtime.core.state.outstandingEffects[effect.context.effectID] == nil)
  }

  @Test
  func aLateDeadlineDoesNotReplaceTheFirstTerminalError() throws {
    var runtime = try readyRuntime()
    _ = runtime.send(.failureObserved(terminalFailure))
    let before = try #require(runtime.core.state.activeSession)
    let result = runtime.send(.deadlineReached(operationID: before.activeOperationID))
    #expect(result.disposition == .stale(reason: .operationMismatch))
    #expect(runtime.core.state.activeSession == before)
  }

  @Test(arguments: [PlaybackCommand.play, .pause])
  func transportCommandsDoNotUnpauseATerminallyFailedPipeline(command: PlaybackCommand) throws {
    var runtime = try readyRuntime()
    _ = runtime.send(.failureObserved(terminalFailure))
    let before = runtime.core.state.activeSession
    let result = runtime.send(.command(command))
    #expect(result.disposition == .invalid(reason: "transportNotReady"))
    #expect(result.effects.isEmpty)
    #expect(runtime.core.state.activeSession == before)
  }

  @Test
  func spentBudgetSurvivesCodableRoundTripAndLegacyDocuments() throws {
    let failure = presentationFailure()
    var recovery = RecoveryMachineState()
    _ = recovery.classify(failure, sessionID: .init(rawValue: 1), revisions: PlaybackRevisionSet())
    let data = try JSONEncoder().encode(recovery)
    var restored = try JSONDecoder().decode(RecoveryMachineState.self, from: data)
    #expect(restored.classify(failure, sessionID: .init(rawValue: 1), revisions: .init(
      presentation: .init(rawValue: 42)
    )) == .rebuildPresentationGraph(revision: .init(rawValue: 1)))
    let legacy = Data("{}".utf8)
    var fresh = try JSONDecoder().decode(RecoveryMachineState.self, from: legacy)
    #expect(fresh.classify(failure, sessionID: .init(rawValue: 1), revisions: .init())
      == .flushAndReprimePresentation(revision: .init(rawValue: 1)))
  }

  @Test
  func exhaustedRevisionCountersFailWithoutOverflow() {
    var flush = RecoveryMachineState()
    #expect(flush.classify(presentationFailure(), sessionID: .init(rawValue: 1), revisions: .init(
      presentation: .init(rawValue: UInt64.max)
    )) == .failTerminal)
    var rebuild = RecoveryMachineState(presentationFlushConsumed: [.init(rawValue: 1)])
    #expect(rebuild.classify(presentationFailure(), sessionID: .init(rawValue: 1), revisions: .init(
      presentationGraph: .init(rawValue: UInt64.max)
    )) == .failTerminal)
  }
}
