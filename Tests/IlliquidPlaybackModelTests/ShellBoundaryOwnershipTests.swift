import Foundation
import Testing

@testable import IlliquidPlaybackModel
import Statelessness

/// Decisions moved from the shells into the model: the effective initial
/// track selection, audio delay, and the projected loop and rate.
@Suite("Shell boundary ownership")
struct ShellBoundaryOwnershipTests {
  private let audioDefault = PlaybackTrackID(kind: .audio, mediaTrackID: 1)
  private let audioPreferred = PlaybackTrackID(kind: .audio, mediaTrackID: 2)
  private let subtitleDefault = PlaybackTrackID(kind: .subtitle, mediaTrackID: 3)

  private func readySession(autoplay: Bool = false) -> PlaybackSessionHost {
    var host = PlaybackSessionHost()
    _ = host.send(.command(.load(
      source: MediaSourceIdentity(rawValue: "fixture/boundary.mkv"),
      autoplay: autoplay
    )))
    _ = host.completeNext()
    _ = host.completeNext()
    if autoplay { _ = host.completeNext() }
    return host
  }

  private func catalog(configured: InitialTrackSelectionState?) -> PlaybackCatalog {
    PlaybackCatalog(
      hasVideo: true,
      audio: [
        PlaybackTrackCandidate(id: audioDefault, isDefault: true),
        PlaybackTrackCandidate(id: audioPreferred, isDefault: false),
      ],
      subtitles: [PlaybackTrackCandidate(id: subtitleDefault, isDefault: true)],
      configuredSelection: configured
    )
  }

  @Test
  func configuredSelectionIsTheEffectiveSelection() {
    var host = readySession()
    // Native ranked a non-default audio stream first and left subtitles off
    // (for example a language preference and "subtitles: off").
    let transition = host.send(.catalogObserved(catalog(
      configured: InitialTrackSelectionState(audio: audioPreferred, subtitle: nil)
    )))
    #expect(transition.disposition == .accepted)
    #expect(transition.snapshot.selectedAudioTrackID == audioPreferred)
    #expect(transition.snapshot.selectedSubtitleTrackID == nil)
    #expect(host.state.activeSession?.tracks.effectiveSubtitle == .off)
  }

  @Test
  func unreportedSelectionKeepsTheCatalogRule() {
    var host = readySession()
    let transition = host.send(.catalogObserved(catalog(configured: nil)))
    #expect(transition.snapshot.selectedAudioTrackID == audioDefault)
    #expect(transition.snapshot.selectedSubtitleTrackID == subtitleDefault)
  }

  @Test
  func configuredSelectionOutsideTheCatalogIsNotInvented() {
    var host = readySession()
    let unknown = PlaybackTrackID(kind: .audio, mediaTrackID: 99)
    let transition = host.send(.catalogObserved(catalog(
      configured: InitialTrackSelectionState(audio: unknown, subtitle: subtitleDefault)
    )))
    #expect(transition.snapshot.selectedAudioTrackID == nil)
    #expect(transition.snapshot.selectedSubtitleTrackID == subtitleDefault)
  }

  @Test
  func unreportedSelectionKeepsCanonicalCatalogEncoding() throws {
    let legacy = PlaybackCatalog(hasVideo: true, audio: [
      PlaybackTrackCandidate(id: audioDefault, isDefault: true)
    ])
    let encoded = String(decoding: try CanonicalJSON.encode(legacy), as: UTF8.self)
    #expect(!encoded.contains("configuredSelection"))
    let controls = String(
      decoding: try CanonicalJSON.encode(ControlMachineState()), as: UTF8.self)
    #expect(!controls.contains("AudioDelay"))
  }

  @Test
  func audioDelayIsAnIdentifiedReplacementTransaction() throws {
    var host = readySession(autoplay: true)
    let generation = try #require(host.state.activeSession?.generation)
    let request = host.send(.command(.setAudioDelay(microseconds: 250_000)))
    #expect(request.disposition == .accepted)
    let effect = try #require(request.effects.first)
    guard case .applyAudioDelay(250_000, let revision) = effect.kind else {
      Issue.record("expected an audio-delay replacement effect, got \(effect.kind)")
      return
    }
    let session = try #require(host.state.activeSession)
    #expect(session.generation.rawValue == generation.rawValue + 1)
    #expect(session.revisions.track == revision)
    #expect(session.controls.requestedAudioDelayMicroseconds == 250_000)
    #expect(session.controls.appliedAudioDelayMicroseconds == 0)

    // A track change cannot interleave with the in-flight replacement.
    let competing = host.send(.command(.selectAudio(.stream(audioPreferred))))
    #expect(competing.disposition != .accepted)

    let settled = try #require(host.complete(effectID: effect.context.effectID))
    #expect(settled.disposition == .accepted)
    #expect(settled.effects.contains { $0.kind == .applyRate(milliRate: 1_000) })
    #expect(host.state.activeSession?.controls.appliedAudioDelayMicroseconds == 250_000)
    #expect(PlaybackControlProjection(state: host.state).appliedAudioDelayMicroseconds == 250_000)

    let unchanged = host.send(.command(.setAudioDelay(microseconds: 250_000)))
    #expect(unchanged.disposition == .accepted)
    #expect(unchanged.effects.isEmpty)
  }

  @Test
  func failedAudioDelayRollsBackTheRequest() throws {
    var host = readySession()
    let request = host.send(.command(.setAudioDelay(microseconds: -20_000_000)))
    let effect = try #require(request.effects.first)
    #expect(effect.kind == .applyAudioDelay(
      microseconds: -10_000_000, revision: TrackRevisionID(rawValue: 1)))
    _ = host.complete(
      effectID: effect.context.effectID,
      token: EffectResultToken(kind: .failed)
    )
    let controls = try #require(host.state.activeSession?.controls)
    #expect(controls.requestedAudioDelayMicroseconds == 0)
    #expect(controls.appliedAudioDelayMicroseconds == 0)
    #expect(host.state.activeSession?.tracks.phase == .idle)
  }

  @Test
  func audioDelayRequestedDuringAReplacementIsAppliedAfterIt() throws {
    var host = readySession(autoplay: true)
    let first = try #require(
      host.send(.command(.setAudioDelay(microseconds: 100_000))).effects.first)
    // Further adjustments and a reset while the first replacement runs keep
    // only the latest intent; none of them is dropped.
    #expect(host.send(.command(.setAudioDelay(microseconds: 200_000))).disposition == .accepted)
    #expect(host.send(.command(.setAudioDelay(microseconds: 0))).disposition == .accepted)
    #expect(PlaybackControlProjection(state: host.state).requestedAudioDelayMicroseconds == 0)

    let settled = try #require(host.complete(effectID: first.context.effectID))
    #expect(host.state.activeSession?.controls.appliedAudioDelayMicroseconds == 100_000)
    // The replaced session resumes first; the queued delay follows its rate
    // acknowledgement, from a settled session.
    let rate = try #require(settled.effects.first)
    #expect(rate.kind == .applyRate(milliRate: 1_000))
    let resumed = try #require(host.complete(effectID: rate.context.effectID))
    let followUp = try #require(resumed.effects.first)
    guard case .applyAudioDelay(0, _) = followUp.kind else {
      Issue.record("expected the queued delay to start, got \(resumed.effects.map(\.kind))")
      return
    }
    let last = try #require(host.complete(effectID: followUp.context.effectID))
    #expect(last.effects.contains { $0.kind == .applyRate(milliRate: 1_000) })
    #expect(host.state.activeSession?.controls.appliedAudioDelayMicroseconds == 0)
    #expect(host.state.activeSession?.controls.queuedAudioDelayMicroseconds == nil)
  }

  @Test(arguments: [true, false])
  func seekDuringAudioDelaySettlesTheReplacementWhenItsResultArrives(succeeds: Bool) throws {
    var host = readySession(autoplay: true)
    _ = host.send(.durationObserved(.valid(try #require(ValidMediaTime(value: 60, timescale: 1)))))
    let delay = try #require(
      host.send(.command(.setAudioDelay(microseconds: 300_000))).effects.first)
    let target = MediaTimestamp.valid(try #require(ValidMediaTime(value: 20, timescale: 1)))
    #expect(host.send(.command(.seek(target: target, mode: .exact))).disposition == .accepted)

    let late = try #require(host.complete(
      effectID: delay.context.effectID,
      token: EffectResultToken(kind: succeeds ? .succeeded : .failed)
    ))
    #expect(late.disposition == .accepted)
    #expect(host.state.activeSession?.tracks.phase == .idle)
    #expect(host.state.activeSession?.seek != nil)
    #expect(host.state.activeSession?.controls.appliedAudioDelayMicroseconds == (succeeds ? 300_000 : 0))
    #expect(host.state.activeSession?.controls.requestedAudioDelayMicroseconds == (succeeds ? 300_000 : 0))
    // Track changes are accepted again instead of being refused indefinitely.
    let selection = host.send(.command(.selectAudio(.stream(audioPreferred))))
    #expect(selection.disposition == .accepted)
  }

  @Test
  func audioDelayRequestedDuringASeekWaitsForTheSeekToSettle() throws {
    var host = readySession(autoplay: true)
    _ = host.send(.durationObserved(.valid(try #require(ValidMediaTime(value: 60, timescale: 1)))))
    let target = MediaTimestamp.valid(try #require(ValidMediaTime(value: 20, timescale: 1)))
    let seek = try #require(
      host.send(.command(.seek(target: target, mode: .exact))).effects.first)
    let generation = try #require(host.state.activeSession?.generation)

    let request = host.send(.command(.setAudioDelay(microseconds: 150_000)))
    #expect(request.disposition == .accepted)
    #expect(request.effects.isEmpty)
    #expect(host.state.activeSession?.generation == generation)
    #expect(PlaybackControlProjection(state: host.state).requestedAudioDelayMicroseconds == 150_000)

    let seekSettled = try #require(host.complete(effectID: seek.context.effectID))
    let rate = try #require(seekSettled.effects.first { if case .applyRate = $0.kind { true } else { false } })
    let resumed = try #require(host.complete(effectID: rate.context.effectID))
    #expect(host.state.activeSession?.seek == nil)
    #expect(resumed.effects.contains {
      if case .applyAudioDelay(150_000, _) = $0.kind { true } else { false }
    })
  }

  @Test
  func stopDropsAQueuedAudioDelayAndALateResultStartsNoWork() throws {
    var host = readySession(autoplay: true)
    let first = try #require(
      host.send(.command(.setAudioDelay(microseconds: 100_000))).effects.first)
    _ = host.send(.command(.setAudioDelay(microseconds: 200_000)))
    #expect(host.send(.command(.stop)).disposition == .accepted)
    #expect(host.state.activeSession?.controls.queuedAudioDelayMicroseconds == nil)

    let late = try #require(host.complete(
      effectID: first.context.effectID, token: EffectResultToken(kind: .cancelled)))
    #expect(late.effects.isEmpty)
    #expect(!host.pendingEffects.contains {
      if case .applyAudioDelay = $0.kind { true } else { false }
    })
    #expect(host.send(.command(.setAudioDelay(microseconds: 300_000))).effects.isEmpty)
  }

  @Test
  func controlProjectionCarriesOnlyTheActiveSessionsLoopAndTheRate() throws {
    var host = readySession(autoplay: true)
    _ = host.send(.durationObserved(.valid(try #require(ValidMediaTime(value: 60, timescale: 1)))))
    let start = MediaTimestamp.valid(try #require(ValidMediaTime(value: 5, timescale: 1)))
    let end = MediaTimestamp.valid(try #require(ValidMediaTime(value: 9, timescale: 1)))
    #expect(host.send(.command(.setLoop(start: start, end: end))).disposition == .accepted)
    #expect(host.send(.command(.setPlaybackSpeed(milliRate: 1_500))).disposition == .accepted)
    var projection = PlaybackControlProjection(state: host.state)
    #expect(projection.loopStart == start)
    #expect(projection.loopEnd == end)
    #expect(projection.playbackMilliRate == 1_500)

    // A new session never inherits the previous session's loop.
    _ = host.send(.command(.load(
      source: MediaSourceIdentity(rawValue: "fixture/next.mkv"), autoplay: false)))
    // Settle the rate change and the replacement's open and preroll.
    for _ in 0..<8 where !host.pendingEffects.isEmpty { _ = host.completeNext() }
    #expect(host.state.activeSession?.source.rawValue == "fixture/next.mkv")
    projection = PlaybackControlProjection(state: host.state)
    #expect(projection.loopStart == nil)
    #expect(projection.loopEnd == nil)
    #expect(projection.playbackMilliRate == 1_500)
  }
}
