import Foundation
import Testing

@testable import SuperplayrPlaybackCore

@Suite("Deterministic playback core")
struct PlaybackCoreTests {
  @Test
  func loadBecomesPlayingOnlyAfterOpenAndRateAcknowledgments() throws {
    var runtime = PlaybackModelRuntime()

    let load = runtime.send(
      .command(
        .load(
          source: MediaSourceIdentity(rawValue: "fixture/movie.mkv"),
          autoplay: true
        )))
    #expect(load.disposition == .accepted)
    #expect(load.snapshot.phase == .opening)
    #expect(load.effects.count == 1)
    #expect(load.effects.first?.executor == .input)
    #expect(load.snapshot.actualTransport == .stopped)

    let openResult = runtime.completeNext()
    let open = try #require(openResult)
    #expect(open.snapshot.phase == .prerolling)
    #expect(open.effects.first?.kind == .awaitPreroll)
    let prerolledResult = runtime.completeNext()
    let prerolled = try #require(prerolledResult)
    #expect(prerolled.snapshot.phase == .prerolling)
    #expect(prerolled.effects.first?.executor == .presentation)

    let rateResult = runtime.completeNext()
    let rate = try #require(rateResult)
    #expect(rate.snapshot.phase == .playing)
    #expect(rate.snapshot.actualTransport == .playing)
    #expect(rate.invariantViolations.isEmpty)
  }

  @Test
  func pausedLoadDoesNotRequestNonzeroRate() throws {
    var runtime = PlaybackModelRuntime()
    _ = runtime.send(
      .command(
        .load(
          source: MediaSourceIdentity(rawValue: "fixture/paused.mkv"),
          autoplay: false
        )))

    _ = runtime.completeNext()
    let prerolledResult = runtime.completeNext()
    let prerolled = try #require(prerolledResult)
    #expect(prerolled.snapshot.phase == .paused)
    #expect(prerolled.snapshot.actualTransport == .paused)
    #expect(prerolled.effects.isEmpty)
  }

  @Test
  func replacementKeepsCommittedSourceUntilCandidatePrerollCommits() throws {
    let first = MediaSourceIdentity(rawValue: "fixture/committed.mkv")
    let candidate = MediaSourceIdentity(rawValue: "fixture/candidate.mkv")
    var runtime = PlaybackModelRuntime()

    _ = runtime.send(.command(.load(source: first, autoplay: false)))
    _ = runtime.completeNext()
    _ = runtime.completeNext()
    #expect(runtime.core.state.activeSession?.source == first)
    #expect(runtime.core.state.pendingSession == nil)

    let requested = runtime.send(.command(.load(source: candidate, autoplay: false)))
    #expect(requested.snapshot.source == first)
    #expect(requested.snapshot.pendingSource == candidate)
    #expect(requested.effects.count == 1)
    #expect(requested.effects.first?.kind == .openSource(candidate))
    #expect(!requested.effects.contains { effect in
      if case .cancelSession = effect.kind { return true }
      return false
    })

    let optionalOpen = runtime.completeNext()
    let open = try #require(optionalOpen)
    #expect(open.snapshot.source == first)
    #expect(open.snapshot.pendingSource == candidate)
    #expect(open.effects.first?.kind == .awaitPreroll)

    let optionalCommitted = runtime.completeNext()
    let committed = try #require(optionalCommitted)
    #expect(committed.snapshot.source == candidate)
    #expect(committed.snapshot.pendingSource == nil)
    #expect(runtime.core.state.activeSession?.source == candidate)
  }

  @Test
  func failedReplacementDiscardsPendingSourceWithoutMutatingCommittedAuthority() throws {
    let first = MediaSourceIdentity(rawValue: "fixture/committed.mkv")
    let candidate = MediaSourceIdentity(rawValue: "fixture/malformed.mkv")
    var runtime = PlaybackModelRuntime()

    _ = runtime.send(.command(.load(source: first, autoplay: false)))
    _ = runtime.completeNext()
    _ = runtime.completeNext()
    _ = runtime.send(.command(.load(source: candidate, autoplay: true)))
    let open = try #require(runtime.pendingEffects.first(where: {
      if case .openSource = $0.kind { return true }
      return false
    }))
    let failure = PlaybackFailure(
      domain: .input,
      stage: .open,
      stableCode: "fixtureCandidateRejected",
      recoverability: .fatal
    )

    let optionalRejected = runtime.complete(
      effectID: open.context.effectID,
      token: EffectResultToken(kind: .failed),
      failure: failure
    )
    let rejected = try #require(optionalRejected)

    #expect(rejected.snapshot.source == first)
    #expect(rejected.snapshot.pendingSource == nil)
    #expect(rejected.snapshot.failureCode == failure.stableCode)
    #expect(runtime.core.state.activeSession?.source == first)
    #expect(runtime.core.state.pendingSession == nil)
  }

  @Test
  func staleGenerationResultCannotResumeAfterSeek() throws {
    var runtime = PlaybackModelRuntime()
    _ = runtime.send(
      .command(
        .load(
          source: MediaSourceIdentity(rawValue: "fixture/seek.mkv"),
          autoplay: true
        )))
    let openEffectID = try #require(runtime.pendingEffects.first?.context.effectID)
    _ = runtime.complete(effectID: openEffectID)
    _ = runtime.completeNext()
    let oldRateEffect = try #require(
      runtime.pendingEffects.first(where: {
        if case .applyRate = $0.kind { return true }
        return false
      }))

    let target = try #require(ValidMediaTime(value: 42_000, timescale: 1_000))
    let seek = runtime.send(.command(.seek(target: .valid(target), mode: .exact)))
    #expect(seek.snapshot.phase == .seeking)

    let staleResult = runtime.complete(effectID: oldRateEffect.context.effectID)
    let stale = try #require(staleResult)
    #expect(stale.disposition == .stale(reason: .generationMismatch))
    #expect(stale.snapshot.phase == .seeking)
    #expect(stale.snapshot.actualTransport == .paused)
  }

  @Test
  func duplicateCompletionIsIdempotent() throws {
    var runtime = PlaybackModelRuntime()
    _ = runtime.send(
      .command(
        .load(
          source: MediaSourceIdentity(rawValue: "fixture/duplicate.mkv"),
          autoplay: false
        )))
    let effect = try #require(runtime.pendingEffects.first)
    _ = runtime.complete(effectID: effect.context.effectID)
    let duplicate = runtime.send(
      .effectResult(
        PlaybackEffectResult(
          context: effect.context,
          token: EffectResultToken(kind: .succeeded)
        )))

    #expect(duplicate.disposition == .duplicate(effectID: effect.context.effectID))
    #expect(duplicate.effects.isEmpty)
    #expect(duplicate.snapshot.phase == .prerolling)
  }

  @Test
  func directEffectResultRetiresPendingRuntimeEffect() throws {
    var runtime = PlaybackModelRuntime()
    _ = runtime.send(
      .command(
        .load(
          source: MediaSourceIdentity(rawValue: "fixture/direct-result.mkv"),
          autoplay: false
        )))
    let effect = try #require(runtime.pendingEffects.first)

    _ = runtime.send(.effectResult(PlaybackEffectResult(
      context: effect.context,
      token: EffectResultToken(kind: .succeeded)
    )))

    #expect(!runtime.pendingEffects.contains {
      $0.context.effectID == effect.context.effectID
    })
  }

  @Test
  func shutdownRequiresCleanupAcknowledgmentAndThenEmitsNothing() throws {
    var runtime = PlaybackModelRuntime()
    _ = runtime.send(
      .command(
        .load(
          source: MediaSourceIdentity(rawValue: "fixture/shutdown.mkv"),
          autoplay: true
        )))
    let shutdown = runtime.send(.command(.shutdown))
    #expect(shutdown.snapshot.lifecycle == .shuttingDown)
    #expect(shutdown.effects.allSatisfy { $0.isCleanup })

    let cancellation = try #require(
      shutdown.effects.first(where: {
        if case .cancelSession = $0.kind { return true }
        return false
      }))
    let optionalCancellationResult = runtime.complete(
      effectID: cancellation.context.effectID
    )
    let cancellationResult = try #require(optionalCancellationResult)
    let finalizer = try #require(
      cancellationResult.effects.first(where: {
        if case .finalizeShutdown = $0.kind { return true }
        return false
      }))

    let optionalTerminated = runtime.complete(effectID: finalizer.context.effectID)
    let terminated = try #require(optionalTerminated)
    #expect(terminated.snapshot.lifecycle == .terminated)
    #expect(terminated.effects.isEmpty)
    #expect(runtime.core.state.outstandingEffects.isEmpty)
    #expect(runtime.core.state.resourceLeases.isEmpty)

    let hostileLateCommand = runtime.send(.command(.play))
    #expect(hostileLateCommand.disposition == .ignoredAfterTermination)
    #expect(hostileLateCommand.effects.isEmpty)
  }

  @Test
  func invalidTimeAndInvalidSeekAreRejectedWithoutEffects() {
    var runtime = PlaybackModelRuntime()
    let invalidSeek = runtime.send(.command(.seek(target: .unknown, mode: .exact)))
    #expect(invalidSeek.disposition == .invalid(reason: "seekRequiresValidTarget"))
    #expect(invalidSeek.effects.isEmpty)

    var core = PlaybackCore()
    _ = core.update(
      PlaybackEventEnvelope(
        sequence: 1,
        virtualTime: PlaybackInstant(ticks: 10),
        event: .command(
          .load(
            source: MediaSourceIdentity(rawValue: "fixture/time.mkv"),
            autoplay: true
          ))
      ))
    let regressed = core.update(
      PlaybackEventEnvelope(
        sequence: 2,
        virtualTime: PlaybackInstant(ticks: 9),
        event: .command(.pause)
      ))
    #expect(regressed.disposition == .invalid(reason: "virtualTimeRegressed"))
    #expect(regressed.effects.isEmpty)
  }

  @Test
  func checkpointAndDiagnosticEventsCarryDeterministicIdentity() throws {
    var runtime = PlaybackModelRuntime()
    _ = runtime.send(
      .command(
        .load(
          source: MediaSourceIdentity(rawValue: "fixture/checkpoint.mkv"),
          autoplay: false
    )))
    _ = runtime.completeNext()
    _ = runtime.completeNext()

    let checkpoint = runtime.send(.command(.checkpoint))
    let effect = try #require(checkpoint.effects.first)
    #expect(effect.executor == .persistence)
    #expect(effect.context.operationID.rawValue > 0)
    #expect(effect.context.effectID.rawValue > 0)

    let failure = PlaybackFailure(
      domain: .persistence,
      stage: .persist,
      stableCode: "writeFailed",
      recoverability: .retryable
    )
    _ = runtime.complete(
      effectID: effect.context.effectID,
      token: EffectResultToken(kind: .failed),
      failure: failure
    )
    #expect(runtime.core.state.lastPersistenceFailureCode == "writeFailed")

    _ = runtime.send(.diagnosticObserved(code: "backend.fixture"))
    #expect(runtime.core.state.diagnosticEventCount == 1)
  }

  @Test
  func subtitleInvalidationOwnsRevisionsClearAndFinalCommitFence() throws {
    var runtime = PlaybackModelRuntime()
    _ = runtime.send(.command(.load(
      source: MediaSourceIdentity(rawValue: "fixture/subtitle.mkv"),
      autoplay: false
    )))
    _ = runtime.completeNext()
    _ = runtime.completeNext()
    let oldAuthority = try #require(runtime.core.state.activeSession?.authority)

    let invalidation = runtime.send(.subtitle(.invalidate(reason: .seek)))
    #expect(invalidation.disposition == .accepted)
    #expect(invalidation.effects.count == 2)
    #expect(invalidation.effects.contains { $0.executor == .mainActorControl })
    #expect(invalidation.effects.contains { $0.executor == .subtitle })

    let currentSession = try #require(runtime.core.state.activeSession)
    #expect(currentSession.subtitles.pendingVisibleClear != nil)
    #expect(currentSession.subtitles.pendingSourceInvalidation != nil)
    let staleCommit = runtime.send(.subtitle(.overlayCommitCandidate(
      authority: oldAuthority,
      revision: OverlayRevisionID(rawValue: 0)
    )))
    #expect(staleCommit.disposition == .stale(reason: .authorityMismatch))

    while !runtime.pendingEffects.isEmpty { _ = runtime.completeNext() }
    let settled = try #require(runtime.core.state.activeSession)
    #expect(settled.subtitles.pendingVisibleClear == nil)
    #expect(settled.subtitles.pendingSourceInvalidation == nil)
    let acceptedCommit = runtime.send(.subtitle(.overlayCommitCandidate(
      authority: settled.authority,
      revision: settled.subtitles.overlayRevision
    )))
    #expect(acceptedCommit.disposition == .accepted)
    #expect(runtime.core.state.activeSession?.subtitles.lastAcceptedOverlayRevision
      == settled.subtitles.overlayRevision)
  }

  @Test
  func aggregateSeekAcknowledgmentRestoresRateOnlyAfterNativePreroll() throws {
    var runtime = PlaybackModelRuntime()
    _ = runtime.send(.command(.load(
      source: MediaSourceIdentity(rawValue: "fixture/seek-transaction.mkv"),
      autoplay: true
    )))
    for _ in 0..<5 { _ = runtime.completeNext() }

    let target = try #require(ValidMediaTime(value: 12_000, timescale: 1_000))
    let transition = runtime.send(.command(.seek(target: .valid(target), mode: .exact)))
    #expect(transition.effects.count == 1)
    #expect(transition.snapshot.position == .valid(target))
    #expect(runtime.core.state.activeSession?.logicalPosition != .valid(target))
    let seekEffect = try #require(transition.effects.first)
    if case .seekPipeline(.valid(let acknowledgedTarget), .exact) = seekEffect.kind {
      // Aggregate success is permitted only after the native transaction has
      // completed every invalidation, flush, seek, and preroll condition.
      #expect(acknowledgedTarget == target)
    } else {
      Issue.record("expected aggregate seek pipeline")
    }
    #expect(runtime.core.state.activeSession?.seek?.phase == .demuxSeeking)

    _ = runtime.complete(effectID: seekEffect.context.effectID)
    #expect(runtime.core.state.activeSession?.seek?.phase == .prerolling)
    let rate = try #require(runtime.pendingEffects.first {
      if case .applyRate = $0.kind { return true }
      return false
    })
    _ = runtime.complete(effectID: rate.context.effectID)
    #expect(runtime.core.state.activeSession?.seek == nil)
    #expect(runtime.core.state.activeSession?.actualTransport == .playing)
  }

  @Test
  func relativeSeekResolvesFromAcceptedClockAndAccumulatesPendingIntent() throws {
    var runtime = PlaybackModelRuntime()
    _ = runtime.send(.command(.load(
      source: MediaSourceIdentity(rawValue: "fixture/relative.mkv"),
      autoplay: false
    )))
    _ = runtime.completeNext()
    _ = runtime.completeNext()
    let delta = try #require(ValidMediaTime(value: 2, timescale: 1))
    let rejected = runtime.send(.command(.seek(target: .valid(delta), mode: .relative)))
    #expect(rejected.disposition == .invalid(reason: "relativeSeekRequiresAcceptedClock"))

    let clock = try #require(ValidMediaTime(value: 10, timescale: 1))
    _ = runtime.send(.acceptedClockSample(.valid(clock)))
    let accepted = runtime.send(.command(.seek(target: .valid(delta), mode: .relative)))
    #expect(accepted.disposition == .accepted)
    let expected = try #require(ValidMediaTime(value: 12, timescale: 1))
    #expect(runtime.core.state.activeSession?.seek?.target == .valid(expected))
    #expect(runtime.core.state.activeSession?.seek?.mode == .relative)
    if case .seekPipeline(.valid(let effectTarget), .exact) = accepted.effects.first?.kind {
      #expect(effectTarget == expected)
    } else {
      Issue.record("expected resolved relative seek to execute as an absolute exact seek")
    }

    let repeated = runtime.send(.command(.seek(target: .valid(delta), mode: .relative)))
    #expect(repeated.disposition == .accepted)
    let accumulated = try #require(ValidMediaTime(value: 14, timescale: 1))
    #expect(runtime.core.state.activeSession?.seek?.target == .valid(accumulated))
    if case .seekPipeline(.valid(let effectTarget), .exact) = repeated.effects.first?.kind {
      #expect(effectTarget == accumulated)
    } else {
      Issue.record("expected repeated relative seek to accumulate as an absolute exact seek")
    }
  }

  @Test
  func catalogDefaultsAndDrainFinalizationAreDeterministicAndExactlyOnce() throws {
    var runtime = PlaybackModelRuntime()
    _ = runtime.send(.command(.load(
      source: MediaSourceIdentity(rawValue: "fixture/drain.mkv"),
      autoplay: false
    )))
    _ = runtime.completeNext()
    _ = runtime.completeNext()
    let audioDefault = PlaybackTrackID(kind: .audio, mediaTrackID: 2)
    let subtitleForced = PlaybackTrackID(kind: .subtitle, mediaTrackID: 9)
    _ = runtime.send(.catalogObserved(PlaybackCatalog(
      hasVideo: true,
      audio: [
        PlaybackTrackCandidate(
          id: PlaybackTrackID(kind: .audio, mediaTrackID: 1),
          isDefault: false
        ),
        PlaybackTrackCandidate(id: audioDefault, isDefault: true),
      ],
      subtitles: [
        PlaybackTrackCandidate(id: subtitleForced, isDefault: false, isForced: true)
      ]
    )))
    #expect(runtime.core.state.activeSession?.loading?.initialSelection.audio == audioDefault)
    #expect(runtime.core.state.activeSession?.loading?.initialSelection.subtitle == subtitleForced)
    _ = runtime.completeNext()
    _ = runtime.completeNext()
    _ = runtime.completeNext()

    let required: Set<PlaybackDrainComponent> = [.videoDecoder, .videoPresenter]
    _ = runtime.send(.demuxEndOfFile(requiredDrain: required))
    let partial = runtime.send(.drainObserved(.videoPresenter))
    #expect(partial.effects.isEmpty)
    let final = runtime.send(.drainObserved(.videoDecoder))
    #expect(final.snapshot.phase == .ended)
    #expect(final.effects.count == 1)
    #expect(final.effects.contains { $0.kind == .persistCheckpoint })
    #expect(!final.effects.contains { $0.kind == .advancePlaylist })
    let completion = runtime.completeNext()
    let persisted = try #require(completion)
    #expect(persisted.effects.contains { $0.kind == .advancePlaylist })
    let duplicate = runtime.send(.drainObserved(.videoDecoder))
    #expect(duplicate.effects.isEmpty)
  }

  @Test
  func duplicateEOFInSameGenerationPreservesObservedDrainProgress() throws {
    var runtime = try readyRuntime(autoplay: false)
    let required: Set<PlaybackDrainComponent> = [.videoDecoder, .videoPresenter]
    _ = runtime.send(.demuxEndOfFile(requiredDrain: required))
    _ = runtime.send(.drainObserved(.videoDecoder))

    _ = runtime.send(.demuxEndOfFile(requiredDrain: required))

    #expect(runtime.core.state.activeSession?.drain.observed == [.videoDecoder])
    let final = runtime.send(.drainObserved(.videoPresenter))
    #expect(final.snapshot.phase == .ended)
    #expect(final.effects.filter { $0.kind == .persistCheckpoint }.count == 1)
    let completion = runtime.completeNext()
    let persisted = try #require(completion)
    #expect(persisted.effects.filter { $0.kind == .advancePlaylist }.count == 1)
  }

  @Test
  func failedEOFCheckpointCannotAdvanceAndLateSuccessCannotReplaceNewMedia() throws {
    var runtime = try readyRuntime(autoplay: false)
    let eof = runtime.send(.demuxEndOfFile(requiredDrain: []))
    let checkpoint = try #require(eof.effects.first { $0.kind == .persistCheckpoint })
    let failedCompletion = runtime.complete(
      effectID: checkpoint.context.effectID,
      token: EffectResultToken(kind: .failed)
    )
    let failure = try #require(failedCompletion)
    #expect(failure.effects.isEmpty)
    #expect(runtime.core.state.lastPersistenceFailureCode != nil)

    var replacing = try readyRuntime(autoplay: false)
    let oldEOF = replacing.send(.demuxEndOfFile(requiredDrain: []))
    let oldCheckpoint = try #require(oldEOF.effects.first)
    _ = replacing.send(.command(.load(
      source: MediaSourceIdentity(rawValue: "replacement"), autoplay: true
    )))
    let late = replacing.complete(effectID: oldCheckpoint.context.effectID)
    #expect(late?.effects.contains { $0.kind == .advancePlaylist } != true)
  }

  @Test
  func aggregateDuplicateEOFCannotSkipExistingDrainObligations() throws {
    var runtime = try readyRuntime(autoplay: false)
    let required: Set<PlaybackDrainComponent> = [.videoDecoder, .videoPresenter]
    _ = runtime.send(.demuxEndOfFile(requiredDrain: required))
    _ = runtime.send(.drainObserved(.videoDecoder))

    let duplicateAggregate = runtime.send(.demuxEndOfFile(requiredDrain: []))

    #expect(duplicateAggregate.effects.isEmpty)
    #expect(runtime.core.state.activeSession?.drain.finalized == false)
    #expect(runtime.core.state.activeSession?.drain.observed == [.videoDecoder])
  }

  @Test
  func acceptedNewSeekGenerationRearmsFinalizedEOFCycle() throws {
    var runtime = try readyRuntime(autoplay: false)
    _ = runtime.send(.demuxEndOfFile(requiredDrain: []))
    #expect(runtime.core.state.activeSession?.drain.finalized == true)

    let target = try #require(ValidMediaTime(value: 7, timescale: 1))
    let seek = runtime.send(.command(.seek(target: .valid(target), mode: .exact)))

    #expect(seek.disposition == .accepted)
    #expect(runtime.core.state.activeSession?.drain == PlaybackDrainState())
  }

  @Test
  func shutdownCleanupFailuresBecomeExplicitExternalWaits() throws {
    var cancellationRuntime = PlaybackModelRuntime()
    _ = cancellationRuntime.send(.command(.load(
      source: MediaSourceIdentity(rawValue: "fixture/shutdown-cancel.mkv"),
      autoplay: false
    )))
    let shutdown = cancellationRuntime.send(.command(.shutdown))
    let cancellation = try #require(shutdown.effects.first)
    _ = cancellationRuntime.complete(
      effectID: cancellation.context.effectID,
      token: EffectResultToken(kind: .failed)
    )
    #expect(cancellationRuntime.core.state.externalWaitReason == .shutdownCancellationFailed)

    var finalizerRuntime = PlaybackModelRuntime()
    let finalizerRequest = finalizerRuntime.send(.command(.shutdown))
    let finalizer = try #require(finalizerRequest.effects.first)
    _ = finalizerRuntime.complete(
      effectID: finalizer.context.effectID,
      token: EffectResultToken(kind: .cancelled)
    )
    #expect(finalizerRuntime.core.state.externalWaitReason == .shutdownFinalizationFailed)
  }

  @Test
  func shutdownRejectsLateRawFactsBeforeTheyCanEmitPlaybackWork() throws {
    var runtime = try readyRuntime(autoplay: true)
    _ = runtime.send(.command(.shutdown))

    let lateEOF = runtime.send(.demuxEndOfFile(requiredDrain: []))

    #expect(lateEOF.disposition == .invalid(reason: "eventRejectedDuringShutdown"))
    #expect(lateEOF.effects.isEmpty)
    #expect(lateEOF.invariantViolations.isEmpty)
  }

  @Test
  func failedTrackReplacementRestoresPrerollAuthorityWithPriorPlayback() throws {
    var runtime = try readyRuntime(autoplay: true)
    let selection = runtime.send(.command(.selectAudio(.stream(
      PlaybackTrackID(kind: .audio, mediaTrackID: 2)
    ))))
    let effect = try #require(selection.effects.first)

    let optionalFailed = runtime.complete(
      effectID: effect.context.effectID,
      token: EffectResultToken(kind: .failed)
    )
    let failed = try #require(optionalFailed)

    #expect(failed.invariantViolations.isEmpty)
    #expect(runtime.core.state.activeSession?.actualTransport == .playing)
    #expect(runtime.core.state.activeSession?.synchronization.startupAcknowledged == true)
  }

  @Test
  func subtitleInvalidationDoesNotStrandInFlightSubtitleSelection() throws {
    var runtime = try readyRuntime(autoplay: false)
    let selection = runtime.send(.command(.selectSubtitle(.external(
      MediaSourceIdentity(rawValue: "fixture/external.srt")
    ))))
    let selectionEffect = try #require(selection.effects.first)

    let invalidation = runtime.send(.subtitle(.invalidate(reason: .trackChange)))
    for effect in invalidation.effects {
      _ = runtime.complete(effectID: effect.context.effectID)
    }
    let optionalSelectionResult = runtime.complete(effectID: selectionEffect.context.effectID)
    let selectionResult = try #require(optionalSelectionResult)

    #expect(selectionResult.disposition == .accepted)
    #expect(runtime.core.state.activeSession?.tracks.phase == .idle)
    #expect(runtime.core.state.activeSession?.tracks.effectiveSubtitle == .external(
      MediaSourceIdentity(rawValue: "fixture/external.srt")
    ))
    #expect(selectionResult.effects.contains { $0.kind == .applyRate(milliRate: 0) })
  }

  @Test
  func subtitleInvalidationDoesNotStrandTrackResumeRate() throws {
    var runtime = try readyRuntime(autoplay: false)
    let selection = runtime.send(.command(.selectSubtitle(.external(
      MediaSourceIdentity(rawValue: "fixture/external.srt")
    ))))
    let selectionEffect = try #require(selection.effects.first)
    let optionalSelectionResult = runtime.complete(effectID: selectionEffect.context.effectID)
    let selectionResult = try #require(optionalSelectionResult)
    let rateEffect = try #require(selectionResult.effects.first {
      $0.kind == .applyRate(milliRate: 0)
    })

    let invalidation = runtime.send(.subtitle(.invalidate(reason: .trackChange)))
    for effect in invalidation.effects {
      _ = runtime.complete(effectID: effect.context.effectID)
    }
    let optionalRateResult = runtime.complete(effectID: rateEffect.context.effectID)
    let rateResult = try #require(optionalRateResult)

    #expect(rateResult.disposition == .accepted)
    #expect(runtime.core.state.activeSession?.phase == .paused)
    #expect(runtime.core.state.activeSession?.actualTransport == .paused)
  }

  @Test
  func aggregatePrerollIsTheOnlyStartupRateAuthority() throws {
    var runtime = PlaybackModelRuntime()
    _ = runtime.send(.command(.load(
      source: MediaSourceIdentity(rawValue: "fixture/preroll-authority.mkv"),
      autoplay: true
    )))
    _ = runtime.completeNext()
    _ = runtime.send(.catalogObserved(PlaybackCatalog(hasVideo: true)))

    let componentReady = runtime.send(.synchronization(.prerolled(.video)))
    #expect(componentReady.effects.isEmpty)
    #expect(
      runtime.core.state.pendingSession?.synchronization.startupAcknowledged == false
    )

    let aggregate = try #require(runtime.pendingEffects.first {
      $0.kind == .awaitPreroll
    })
    let optionalAggregateReady = runtime.complete(effectID: aggregate.context.effectID)
    let aggregateReady = try #require(optionalAggregateReady)
    #expect(runtime.core.state.activeSession?.synchronization.startupAcknowledged == true)
    #expect(aggregateReady.effects.contains { $0.kind == .applyRate(milliRate: 1_000) })
  }

  @Test
  func lateCatalogMetadataDoesNotRearmSatisfiedStartupPreroll() throws {
    var runtime = try readyRuntime(autoplay: true)

    let catalog = runtime.send(.catalogObserved(PlaybackCatalog(hasVideo: true)))

    #expect(catalog.invariantViolations.isEmpty)
    #expect(runtime.core.state.lifecycle == .running)
    #expect(runtime.core.state.activeSession?.actualTransport == .playing)
    #expect(runtime.core.state.activeSession?.synchronization.startupAcknowledged == true)
  }

  @Test
  func invariantRejectsPlaybackBeforeCurrentPrerollObligation() {
    let session = ActivePlaybackSession(
      id: PlaybackSessionID(rawValue: 1),
      source: MediaSourceIdentity(rawValue: "fixture/unprerolled.mkv"),
      generation: PlaybackGenerationID(rawValue: 1),
      phase: .playing,
      desiredTransport: .playing,
      actualTransport: .playing,
      activeOperationID: PlaybackOperationID(rawValue: 1),
      synchronization: SynchronizationMachineState(
        desiredMilliRate: 1_000,
        appliedMilliRate: 1_000,
        startupAcknowledged: false
      )
    )
    let violations = PlaybackInvariantChecker.check(state: PlaybackCoreState(
      activeSession: session
    ))
    #expect(violations.contains { $0.name == "playingRequiresCurrentPreroll" })
  }

  @Test
  func recoveryBudgetIsScopedToMediaSessionAndSelectedVideoLineage() {
    let session = PlaybackSessionID(rawValue: 7)
    let stream = PlaybackStreamID(kind: .video, demuxIndex: 2)
    let failure = PlaybackFailure(
      domain: .videoDecode,
      stage: .receiveFrame,
      stableCode: "vtLateFailure",
      nativeCode: -12_948,
      recoverability: .fallbackAvailable,
      streamID: stream,
      formatRevision: MediaFormatRevisionID(rawValue: 3),
      codecName: "hevc",
      codecProfile: 2,
      hardwareWasConfigured: true,
      hardwareOutputWasObserved: true,
      consecutiveCount: 1
    )
    var recovery = RecoveryMachineState()
    let first = recovery.classify(
      failure,
      sessionID: session,
      revisions: PlaybackRevisionSet(decoder: DecoderRevisionID(rawValue: 4))
    )
    #expect(first == .resumeVideoDecoderAfterTransientFailure(
      lineage: VideoRecoveryLineage(sessionID: session, streamID: stream),
      consecutiveCount: 1
    ))

    let secondFailure = PlaybackFailure(
      domain: .videoDecode,
      stage: .receiveFrame,
      stableCode: "vtLateFailure",
      recoverability: .fallbackAvailable,
      streamID: stream,
      hardwareWasConfigured: true,
      hardwareOutputWasObserved: true,
      consecutiveCount: 2
    )
    #expect(recovery.classify(
      secondFailure,
      sessionID: session,
      revisions: PlaybackRevisionSet(decoder: DecoderRevisionID(rawValue: 4))
    ) == .resumeVideoDecoderAfterTransientFailure(
      lineage: VideoRecoveryLineage(sessionID: session, streamID: stream),
      consecutiveCount: 2
    ))

    let thresholdFailure = PlaybackFailure(
      domain: .videoDecode,
      stage: .receiveFrame,
      stableCode: "vtLateFailure",
      recoverability: .fallbackAvailable,
      streamID: stream,
      hardwareWasConfigured: true,
      hardwareOutputWasObserved: true,
      consecutiveCount: RecoveryMachineState.hardwareDecodeFailureThreshold
    )
    #expect(recovery.classify(
      thresholdFailure,
      sessionID: session,
      revisions: PlaybackRevisionSet(decoder: DecoderRevisionID(rawValue: 4))
    ) == .recreateVideoDecoderInSoftware(
      lineage: VideoRecoveryLineage(sessionID: session, streamID: stream),
      revision: DecoderRevisionID(rawValue: 5)
    ))

    // Seek and decoder revisions do not replenish the budget.
    let recurrent = recovery.classify(
      thresholdFailure,
      sessionID: session,
      revisions: PlaybackRevisionSet(decoder: DecoderRevisionID(rawValue: 99))
    )
    #expect(recurrent == .failTerminal)

    let replacementStream = PlaybackStreamID(kind: .video, demuxIndex: 5)
    let replacementFailure = PlaybackFailure(
      domain: .videoDecode,
      stage: .receiveFrame,
      stableCode: "vtLateFailure",
      recoverability: .fallbackAvailable,
      streamID: replacementStream,
      hardwareWasConfigured: true,
      hardwareOutputWasObserved: false,
      consecutiveCount: RecoveryMachineState.hardwareDecodeFailureThreshold
    )
    #expect(recovery.classify(
      replacementFailure,
      sessionID: session,
      revisions: PlaybackRevisionSet()
    ) == .recreateVideoDecoderInSoftware(
      lineage: VideoRecoveryLineage(sessionID: session, streamID: replacementStream),
      revision: DecoderRevisionID(rawValue: 1)
    ))
  }

  @Test
  func retryableVideoDecodeFailureDoesNotReachUserFacingSnapshot() throws {
    var runtime = try readyRuntime(autoplay: true)
    let stream = PlaybackStreamID(kind: .video, demuxIndex: 2)
    let failure = PlaybackFailure(
      domain: .videoDecode,
      stage: .receiveFrame,
      stableCode: "videoDecodeFailed",
      recoverability: .fallbackAvailable,
      streamID: stream,
      hardwareWasConfigured: true,
      hardwareOutputWasObserved: true,
      consecutiveCount: 1
    )

    let retry = runtime.send(.failureObserved(failure))

    #expect(retry.snapshot.failureCode == nil)
    #expect(retry.snapshot.phase == .playing)
    let effect = try #require(retry.effects.first)
    guard case .resumeVideoDecoderAfterTransientFailure = effect.kind else {
      Issue.record("Expected transient video decoder recovery")
      return
    }

    let optionalCompletion = runtime.complete(effectID: effect.context.effectID)
    let completion = try #require(optionalCompletion)
    #expect(completion.snapshot.failureCode == nil)
  }

  @Test
  func presentationRecoveryIsScopedThenRebuildsOnceBeforeTerminalFailure() {
    let failure = PlaybackFailure(
      domain: .presentation,
      stage: .enqueue,
      stableCode: "requiresFlushToResumeDecoding",
      recoverability: .retryable
    )
    let revisions = PlaybackRevisionSet(
      presentation: PresentationRevisionID(rawValue: 8),
      presentationGraph: PresentationGraphRevisionID(rawValue: 3)
    )
    var recovery = RecoveryMachineState()
    #expect(recovery.classify(
      failure,
      sessionID: PlaybackSessionID(rawValue: 1),
      revisions: revisions
    ) == .flushAndReprimePresentation(revision: PresentationRevisionID(rawValue: 9)))
    #expect(recovery.classify(
      failure,
      sessionID: PlaybackSessionID(rawValue: 1),
      revisions: revisions
    ) == .rebuildPresentationGraph(revision: PresentationGraphRevisionID(rawValue: 4)))
    #expect(recovery.classify(
      failure,
      sessionID: PlaybackSessionID(rawValue: 1),
      revisions: revisions
    ) == .failTerminal)
  }

  @Test
  func synchronizationOwnsPrerollBufferingDriftAndRateAcknowledgment() throws {
    var synchronization = SynchronizationMachineState(desiredMilliRate: 1_000)
    _ = synchronization.observe(.require([.video, .audio]))
    #expect(synchronization.observe(.prerolled(.video)).isEmpty)
    #expect(synchronization.observe(.prerolled(.audio)).isEmpty)
    #expect(!synchronization.startupAcknowledged)
    let startupSatisfied = synchronization.satisfyStartupObligation()
    #expect(startupSatisfied)
    #expect(synchronization.observe(.rateAcknowledged(milliRate: 1_000)).isEmpty)
    #expect(synchronization.appliedMilliRate == 1_000)
    #expect(synchronization.observe(
      .supplyObserved(starved: true, cacheMicroseconds: 0)
    ) == [.applyRate(milliRate: 0)])
    #expect(synchronization.isBuffering)
    #expect(synchronization.observe(
      .supplyObserved(starved: false, cacheMicroseconds: 500_000)
    ) == [.applyRate(milliRate: 1_000)])
    #expect(!synchronization.isBuffering)

    let video = MediaTimestamp.valid(try #require(
      ValidMediaTime(value: 1_000_000, timescale: 1_000_000)
    ))
    let audio = MediaTimestamp.valid(try #require(
      ValidMediaTime(value: 1_250_001, timescale: 1_000_000)
    ))
    #expect(synchronization.observe(
      .presentationObserved(video: video, audio: audio)
    ) == [.correctAudioVideoDrift(microseconds: 250_001)])
  }

  @Test
  func lifecycleReducerRemembersExactlyOneResumeAfterWakeDecision() throws {
    let position = MediaTimestamp.valid(try #require(
      ValidMediaTime(value: 42, timescale: 1)
    ))
    var lifecycle = LifecycleMachineState()
    #expect(lifecycle.observe(
      .systemWillSleep,
      desiredMilliRate: 1_000,
      position: position
    ) == .applyRate(milliRate: 0))
    #expect(lifecycle.observe(
      .systemDidWake,
      desiredMilliRate: 1_000,
      position: position
    ) == .resumeAfterWake(position: position, milliRate: 1_000))
    #expect(lifecycle.observe(
      .systemDidWake,
      desiredMilliRate: 1_000,
      position: position
    ) == .resumeAfterWake(position: position, milliRate: 0))
  }

  @Test
  func trackIntentsAreDistinctAndRollbackKeepsOldEffectiveSelection() {
    var tracks = TrackSelectionMachineState()
    let audio = PlaybackTrackID(kind: .audio, mediaTrackID: 9)
    let subtitle = PlaybackTrackID(kind: .subtitle, mediaTrackID: 12)
    let audioRequest = tracks.requestAudio(.stream(audio))
    #expect(audioRequest == .prepareAudio(
      .stream(audio),
      revision: TrackRevisionID(rawValue: 1)
    ))
    let audioPrepared = tracks.prepared(revision: TrackRevisionID(rawValue: 1))
    #expect(audioPrepared == .commit(
      revision: TrackRevisionID(rawValue: 1)
    ))
    let audioFailed = tracks.failed(revision: TrackRevisionID(rawValue: 1))
    #expect(audioFailed == .rollback(
      revision: TrackRevisionID(rawValue: 1)
    ))
    let didRollBack = tracks.rolledBack(revision: TrackRevisionID(rawValue: 1))
    #expect(didRollBack)
    #expect(tracks.effectiveAudio == .automatic)

    let subtitleRequest = tracks.requestSubtitle(.embedded(subtitle))
    #expect(subtitleRequest == .prepareSubtitle(
      .embedded(subtitle),
      revision: TrackRevisionID(rawValue: 2)
    ))
    let subtitlePrepared = tracks.prepared(revision: TrackRevisionID(rawValue: 2))
    #expect(subtitlePrepared == .commit(
      revision: TrackRevisionID(rawValue: 2)
    ))
    let didCommit = tracks.committed(revision: TrackRevisionID(rawValue: 2))
    #expect(didCommit)
    #expect(tracks.effectiveSubtitle == .embedded(subtitle))
    #expect(SubtitleSelectionIntent.off != .automatic)
    #expect(AudioSelectionIntent.automatic != .stream(audio))
  }

  @Test
  func controlReducerOwnsRequestedAndAppliedSubtitleDelay() {
    var controls = ControlMachineState()
    let requested = controls.requestSubtitleDelay(microseconds: 12_000_000)
    #expect(requested == 10_000_000)
    let rejected = controls.acknowledgeSubtitleDelay(microseconds: 9_000_000)
    let accepted = controls.acknowledgeSubtitleDelay(microseconds: 10_000_000)
    #expect(!rejected)
    #expect(accepted)
    #expect(controls.appliedSubtitleDelayMicroseconds == 10_000_000)
  }

  private func readyRuntime(autoplay: Bool) throws -> PlaybackModelRuntime {
    var runtime = PlaybackModelRuntime()
    _ = runtime.send(.command(.load(
      source: MediaSourceIdentity(rawValue: "fixture/ready.mkv"),
      autoplay: autoplay
    )))
    _ = runtime.completeNext()
    _ = runtime.completeNext()
    if autoplay { _ = runtime.completeNext() }
    return runtime
  }

}

@Suite("Optional track recovery")
struct OptionalTrackRecoveryTests {
  @Test func audioDecodeFailureDisablesAudioWhenVideoCanContinue() {
    let stream = PlaybackStreamID(kind: .audio, demuxIndex: 3)
    var recovery = RecoveryMachineState()
    let directive = recovery.classify(
      PlaybackFailure(
        domain: .audioDecode,
        stage: .receiveFrame,
        stableCode: "nativeAudioDecodeFailed",
        recoverability: .fallbackAvailable,
        streamID: stream
      ),
      sessionID: PlaybackSessionID(rawValue: 1),
      revisions: PlaybackRevisionSet()
    )
    #expect(directive == .disableAudioTrack(streamID: stream))
  }

  @Test func subtitleReadFailureDisablesOnlyTheSubtitleTrack() {
    let stream = PlaybackStreamID(kind: .subtitle, demuxIndex: 4)
    var recovery = RecoveryMachineState()
    let directive = recovery.classify(
      PlaybackFailure(
        domain: .subtitle,
        stage: .read,
        stableCode: "nativeSubtitleReadFailed",
        recoverability: .fallbackAvailable,
        streamID: stream
      ),
      sessionID: PlaybackSessionID(rawValue: 1),
      revisions: PlaybackRevisionSet()
    )
    #expect(directive == .disableSubtitleTrack(streamID: stream))
  }

  @Test func audioPresentationFlushesThenRebuildsThenDisables() {
    let stream = PlaybackStreamID(kind: .audio, demuxIndex: 3)
    let failure = PlaybackFailure(
      domain: .audioDecode,
      stage: .enqueue,
      stableCode: "nativeAudioPresentationFailed",
      recoverability: .fallbackAvailable,
      streamID: stream
    )
    var recovery = RecoveryMachineState()
    #expect(recovery.classify(
      failure,
      sessionID: PlaybackSessionID(rawValue: 1),
      revisions: PlaybackRevisionSet(
        presentation: PresentationRevisionID(rawValue: 2),
        presentationGraph: PresentationGraphRevisionID(rawValue: 4)
      )
    ) == .flushAndReprimeAudioPresentation(
      revision: PresentationRevisionID(rawValue: 3)
    ))
    #expect(recovery.classify(
      failure,
      sessionID: PlaybackSessionID(rawValue: 1),
      revisions: PlaybackRevisionSet(
        presentation: PresentationRevisionID(rawValue: 3),
        presentationGraph: PresentationGraphRevisionID(rawValue: 4)
      )
    ) == .rebuildAudioPresentation(
      revision: PresentationGraphRevisionID(rawValue: 5)
    ))
    #expect(recovery.classify(
      failure,
      sessionID: PlaybackSessionID(rawValue: 1),
      revisions: PlaybackRevisionSet()
    ) == .disableAudioTrack(streamID: stream))
  }

  @Test func audioOnlyDecodeFailureRemainsTerminal() throws {
    var runtime = PlaybackModelRuntime()
    _ = runtime.send(.command(.load(
      source: MediaSourceIdentity(rawValue: "fixture/audio-only.m4a"),
      autoplay: false
    )))
    _ = runtime.completeNext()
    let audio = PlaybackTrackID(kind: .audio, mediaTrackID: 2)
    _ = runtime.send(.catalogObserved(PlaybackCatalog(audio: [
      PlaybackTrackCandidate(id: audio, isDefault: true),
    ])))
    _ = runtime.completeNext()
    let failure = runtime.send(.failureObserved(PlaybackFailure(
      domain: .audioDecode,
      stage: .receiveFrame,
      stableCode: "nativeAudioDecodeFailed",
      recoverability: .fallbackAvailable,
      streamID: PlaybackStreamID(kind: .audio, demuxIndex: 1)
    )))
    #expect(failure.snapshot.phase == .failed)
    #expect(failure.effects.isEmpty)
  }

  @Test func recoveryStateDecodesDocumentsFromBeforeOptionalTrackBudgets() throws {
    let encoded = try JSONEncoder().encode(RecoveryMachineState())
    var object = try #require(
      JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    object.removeValue(forKey: "disabledAudioStreams")
    object.removeValue(forKey: "disabledSubtitleStreams")
    object.removeValue(forKey: "audioPresentationRecoveryStage")
    let legacy = try JSONSerialization.data(withJSONObject: object)

    let decoded = try JSONDecoder().decode(RecoveryMachineState.self, from: legacy)

    #expect(decoded.disabledAudioStreams.isEmpty)
    #expect(decoded.disabledSubtitleStreams.isEmpty)
    #expect(decoded.audioPresentationRecoveryStage.isEmpty)
  }
}

@Suite("Playback core replay")
struct PlaybackReplayTests {
  @Test
  func canonicalEncodingIgnoresSetAndDictionaryInsertionHistory() throws {
    let effectID = PlaybackEffectID(rawValue: 7)
    let operationID = PlaybackOperationID(rawValue: 4)
    let authority = PlaybackAuthority.application(ApplicationEpochID(rawValue: 1))
    let tokenA = EffectResultToken(kind: .succeeded, component: "a")
    let tokenB = EffectResultToken(kind: .failed, component: "b")
    let effectA = PlaybackEffect(
      executor: .resource,
      context: PlaybackEffectContext(
        authority: authority,
        operationID: operationID,
        effectID: effectID
      ),
      kind: .finalizeShutdown,
      completion: .oneShot(terminals: Set([tokenA, tokenB])),
      isCleanup: true
    )
    var reversedTerminals: Set<EffectResultToken> = []
    reversedTerminals.insert(tokenB)
    reversedTerminals.insert(tokenA)
    let effectB = PlaybackEffect(
      executor: .resource,
      context: effectA.context,
      kind: .finalizeShutdown,
      completion: .oneShot(terminals: reversedTerminals),
      isCleanup: true
    )

    var first = PlaybackCoreState()
    first.outstandingEffects[effectID] = OutstandingEffectRecord(
      effect: effectA,
      acceptedTokens: Set([tokenA, tokenB])
    )
    first.completedEffectIDs.insert(PlaybackEffectID(rawValue: 9))
    first.completedEffectIDs.insert(PlaybackEffectID(rawValue: 3))

    var second = PlaybackCoreState()
    second.completedEffectIDs.insert(PlaybackEffectID(rawValue: 3))
    second.completedEffectIDs.insert(PlaybackEffectID(rawValue: 9))
    second.outstandingEffects[effectID] = OutstandingEffectRecord(
      effect: effectB,
      acceptedTokens: reversedTerminals
    )

    let canonicalFirst = PlaybackCanonicalState(state: first)
    let canonicalSecond = PlaybackCanonicalState(state: second)
    #expect(canonicalFirst == canonicalSecond)
    #expect(
      PlaybackReplayCodec.digest(canonicalFirst) == PlaybackReplayCodec.digest(canonicalSecond))
  }

  @Test
  func replayJSONRoundTripsWithStableBytes() throws {
    var runtime = PlaybackModelRuntime()
    _ = runtime.send(
      .command(
        .load(
          source: MediaSourceIdentity(rawValue: "fixtures/movie.mkv"),
          autoplay: true
        )))
    _ = runtime.completeNext()
    let replay = runtime.replayDocument(
      superplayrRevision: "fbdc699",
      seed: 847_221
    )

    let firstEncoding = try PlaybackReplayCodec.encode(replay)
    let decoded = try PlaybackReplayCodec.decode(firstEncoding)
    let secondEncoding = try PlaybackReplayCodec.encode(decoded)
    #expect(decoded == replay)
    #expect(firstEncoding == secondEncoding)
  }

  @Test
  func shrinkerProducesDeterministicNonemptyDeletionCandidates() {
    let envelopes = (1...8).map { value in
      PlaybackEventEnvelope(
        sequence: UInt64(value),
        virtualTime: PlaybackInstant(ticks: UInt64(value)),
        event: .command(.pause)
      )
    }
    let first = PlaybackReplayShrinker.deletionCandidates(for: envelopes)
    let second = PlaybackReplayShrinker.deletionCandidates(for: envelopes)
    #expect(first == second)
    #expect(!first.isEmpty)
    #expect(first.allSatisfy { !$0.isEmpty && $0.count < envelopes.count })
  }
}

@Suite("Playback core model runtime")
struct PlaybackModelRuntimeTests {
  @Test
  func productionModeSkipsReplayEncodingAndRetention() {
    var runtime = PlaybackModelRuntime(recordsReplaySteps: false)

    let transition = runtime.send(
      .command(
        .load(
          source: MediaSourceIdentity(rawValue: "fixture/production.mkv"),
          autoplay: true
        )))

    #expect(transition.disposition == .accepted)
    #expect(runtime.core.state.activeSession == nil)
    #expect(runtime.core.state.pendingSession != nil)
    #expect(runtime.steps.isEmpty)
    #expect(!runtime.pendingEffects.isEmpty)
  }

  @Test
  func seededSequencesRemainDeterministicAndInvariantSafe() {
    let first = runSequence(seed: 0xC0FFEE, steps: 2_000)
    let second = runSequence(seed: 0xC0FFEE, steps: 2_000)
    #expect(first.document == second.document)
    #expect(first.violations.isEmpty)
    #expect(second.violations.isEmpty)
  }

  private func runSequence(
    seed: UInt64,
    steps: Int
  ) -> (document: PlaybackReplayDocument, violations: [PlaybackInvariantViolation]) {
    var runtime = PlaybackModelRuntime()
    var generator = SeededPlaybackGenerator(seed: seed)
    var violations: [PlaybackInvariantViolation] = []

    for _ in 0..<steps {
      if runtime.core.state.lifecycle == .terminated { break }
      let transition: PlaybackTransition
      if !runtime.pendingEffects.isEmpty && generator.next() % 3 != 0 {
        let index = Int(generator.next() % UInt64(runtime.pendingEffects.count))
        if generator.shouldMutateResult(percent: 8) {
          let effect = runtime.pendingEffects[index]
          transition = runtime.send(
            .effectResult(
              PlaybackEffectResult(
                context: effect.context,
                token: EffectResultToken(kind: .succeeded, component: "mutated")
              )))
        } else {
          transition = runtime.completeNext(at: index) ?? runtime.send(.command(.pause))
        }
      } else {
        transition = runtime.send(.command(generator.nextCommand(for: runtime.core.state)))
      }
      violations.append(contentsOf: transition.invariantViolations)
    }

    return (
      runtime.replayDocument(superplayrRevision: "test", seed: seed),
      violations
    )
  }
}
