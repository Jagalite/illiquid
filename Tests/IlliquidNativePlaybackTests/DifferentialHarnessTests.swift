import Foundation
import Testing

@testable import IlliquidNativePlayback

@Suite("mpv differential harness contract")
struct DifferentialHarnessTests {
  @Test func fixtureIdentityRequiresProvenanceAndMatchingContentHash() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let fixtureURL = directory.appendingPathComponent("smoke.mp4")
    try Data("fixture-v1".utf8).write(to: fixtureURL)
    let record = DifferentialFixtureRecord(
      path: fixtureURL.lastPathComponent,
      sha256: SHA256Digest.file(at: fixtureURL),
      generatorCommand: "ffmpeg -f lavfi -i testsrc2 smoke.mp4",
      license: "CC0-1.0",
      origin: "repository-generated lavfi",
      truthPath: "smoke.ffprobe.json",
      assertions: [
        FixtureTruthAssertion(name: "has-video", passed: true, evidence: "h264")
      ]
    )
    try Data("{}".utf8).write(
      to: directory.appendingPathComponent(record.truthPath)
    )

    #expect(try DifferentialFixtureVerifier.verify(record, in: directory) == fixtureURL)

    try Data("fixture-v2".utf8).write(to: fixtureURL)
    #expect(throws: DifferentialHarnessError.self) {
      try DifferentialFixtureVerifier.verify(record, in: directory)
    }

    let missingProvenance = DifferentialFixtureRecord(
      path: fixtureURL.lastPathComponent,
      sha256: SHA256Digest.file(at: fixtureURL),
      generatorCommand: "",
      license: "",
      origin: "",
      truthPath: record.truthPath,
      assertions: record.assertions
    )
    #expect(throws: DifferentialHarnessError.self) {
      try DifferentialFixtureVerifier.verify(missingProvenance, in: directory)
    }
  }

  @Test func exactSeekRejectsPretargetAudioEvenWhenBothRunnersExitSuccessfully() {
    let target = 1.25
    let oracle = DifferentialPlayerResult.fixture(
      runner: .mpv,
      seekTarget: target,
      videoPTS: 1.267,
      audioPTS: target,
      eof: .clean
    )
    let native = DifferentialPlayerResult.fixture(
      runner: .illiquid,
      seekTarget: target,
      videoPTS: 1.267,
      audioPTS: 1.249,
      eof: .clean
    )

    let comparison = DifferentialComparator.compare(
      oracle: oracle,
      native: native,
      frameTolerance: 1.0 / 30.0
    )

    #expect(!comparison.passed)
    #expect(comparison.findings.contains { $0.code == "nativeAudioBeforeExactTarget" })
  }

  @Test func nativeSeekJournalRecordsFirstEligibleEnqueueSeparatelyFromHorizons() {
    let target = 1.25
    var snapshot = MediaSessionSnapshot()
    snapshot.generation = 1
    snapshot.beginDifferentialSeekObservation()
    snapshot.recordEnqueuedVideo(startPTS: 1.267, endPTS: 1.300, generation: 1)
    snapshot.recordEnqueuedVideo(startPTS: 1.300, endPTS: 1.333, generation: 1)
    snapshot.recordEnqueuedAudio(startPTS: target, endPTS: 1.271, generation: 1)
    snapshot.recordEnqueuedAudio(startPTS: 1.271, endPTS: 1.292, generation: 1)

    #expect(snapshot.firstEnqueuedVideoPTS == 1.267)
    #expect(snapshot.videoPTS == 1.333)
    #expect(snapshot.firstEnqueuedAudioPTS == target)
    #expect(snapshot.audioPTS == 1.292)

    snapshot.beginDifferentialSeekObservation()
    #expect(snapshot.firstEnqueuedVideoPTS == nil)
    #expect(snapshot.firstEnqueuedAudioPTS == nil)
  }

  @Test func retiredEnqueueCannotOverwriteANewSeekJournal() {
    var snapshot = MediaSessionSnapshot()
    snapshot.generation = 1
    snapshot.recordEnqueuedVideo(startPTS: 0.5, endPTS: 0.533, generation: 1)
    snapshot.recordEnqueuedAudio(startPTS: 0.5, endPTS: 0.521, generation: 1)
    // Native enqueue has completed; a concurrent seek resets the journal
    // before the old presentation worker acquires the state lock to record it.
    snapshot.generation = 2
    snapshot.beginDifferentialSeekObservation()
    let beforeRetiredCompletion = snapshot
    let staleVideoAccepted = snapshot.recordEnqueuedVideo(startPTS: 0.533, endPTS: 0.566, generation: 1)
    let staleAudioAccepted = snapshot.recordEnqueuedAudio(startPTS: 0.521, endPTS: 0.542, generation: 1)
    #expect(!staleVideoAccepted)
    #expect(!staleAudioAccepted)
    #expect(snapshot == beforeRetiredCompletion)
    let currentVideoAccepted = snapshot.recordEnqueuedVideo(startPTS: 2, endPTS: 2.033, generation: 2)
    let currentAudioAccepted = snapshot.recordEnqueuedAudio(startPTS: 2, endPTS: 2.021, generation: 2)
    #expect(currentVideoAccepted)
    #expect(currentAudioAccepted)
    #expect(snapshot.firstEnqueuedVideoPTS == 2)
    #expect(snapshot.firstEnqueuedAudioPTS == 2)
  }

  @Test func disagreementCannotBecomeAValidArtifactWithoutDisposition() {
    let comparison = DifferentialComparison(
      passed: false,
      findings: [.init(code: "eofOutcomeDiffers", message: "EOF differs")]
    )
    #expect(throws: DifferentialHarnessError.self) {
      try DifferentialArtifactPolicy.validate(
        comparison: comparison,
        dispositions: []
      )
    }
    #expect(throws: Never.self) {
      try DifferentialArtifactPolicy.validate(
        comparison: comparison,
        dispositions: [
          .init(
            findingCode: "eofOutcomeDiffers",
            category: .oracleLimitation,
            rationale: "headless mpv cannot prove renderer drain"
          )
        ]
      )
    }
  }

  @Test func selectedTracksMapByStreamIdentityNotRunnerExplanation() {
    let oracleTrack = DifferentialSelectedStream(
      kind: .video,
      index: 0,
      codec: "h264",
      language: nil,
      dispositions: ["default"],
      stableID: "video:0",
      selectionReason: "mpv selected track"
    )
    let nativeTrack = DifferentialSelectedStream(
      kind: .video,
      index: 0,
      codec: "h264",
      language: nil,
      dispositions: ["default"],
      stableID: "video:0",
      selectionReason: "native demux default policy"
    )
    let oracle = DifferentialPlayerResult.fixture(
      runner: .mpv,
      seekTarget: 1.25,
      videoPTS: 1.267,
      audioPTS: 1.25,
      eof: .clean,
      selectedStreams: [oracleTrack]
    )
    let native = DifferentialPlayerResult.fixture(
      runner: .illiquid,
      seekTarget: 1.25,
      videoPTS: 1.267,
      audioPTS: 1.25,
      eof: .clean,
      selectedStreams: [nativeTrack]
    )

    #expect(
      DifferentialComparator.compare(
        oracle: oracle,
        native: native,
        frameTolerance: 1.0 / 30.0
      ).passed)
  }

  @Test func deterministicFaultsUsePolicyRecordsInsteadOfManufacturedLiveParity() {
    let records = DifferentialFaultTranslator.requiredPolicyRecords(
      mpvRevision: "94335ab87ab225ca3e36e0faeac831639d3e1d4e"
    )
    #expect(records.count == DifferentialFaultScenario.allCases.count)
    #expect(records.allSatisfy { $0.oracleMode == .pinnedBehaviorRecord })
    #expect(records.allSatisfy { !$0.expectedIlliquidPolicy.isEmpty })
    #expect(
      records.allSatisfy {
        $0.referenceRevision == "94335ab87ab225ca3e36e0faeac831639d3e1d4e"
      })
  }

  @Test func rendererObservationNeverTreatsEnqueueAsVisibleOrDrainedEvidence() throws {
    var journal = DifferentialRendererObservationJournal(epoch: 7)
    journal.recordEnqueued(
      kind: .video,
      interval: try #require(DifferentialMediaInterval(start: 1.0, end: 1.04)),
      epoch: 7
    )
    journal.recordEnqueued(
      kind: .audio,
      interval: try #require(DifferentialMediaInterval(start: 1.0, end: 1.02)),
      epoch: 7
    )
    journal.markDemuxEOF(epoch: 7)

    #expect(
      journal.readiness(for: .video)
        == .unmeasured(
          reason: "No renderer-backed clock observation crossed an enqueued interval"
        ))
    #expect(
      journal.readiness(for: .audio)
        == .unmeasured(
          reason: "No renderer-backed clock observation crossed an enqueued interval"
        ))
    #expect(!journal.isRendererDrained)

    journal.observeRendererClock(mediaTime: 1.01, monotonicSeconds: 5.0, epoch: 7)
    #expect(
      journal.readiness(for: .video)
        == .measured(
          monotonicSeconds: 5.0,
          evidence: "renderer-clock-crossed-sample"
        ))
    #expect(!journal.isRendererDrained)

    journal.observeRendererClock(mediaTime: 1.05, monotonicSeconds: 5.04, epoch: 7)
    #expect(journal.isRendererDrained)
    #expect(journal.rendererEOFMonotonicSeconds == 5.04)
  }

  @Test func mediaSessionEOFWaitsForTheFinalSubmittedAudioToRender() {
    #expect(
      !MediaSessionEndPolicy.shouldFinish(
        decoderDrainComplete: true,
        rendererDrainEvidence: false,
        successfulVideoSubmissions: 0,
        successfulAudioSubmissions: 1
      ))
    #expect(
      MediaSessionEndPolicy.shouldFinish(
        decoderDrainComplete: true,
        rendererDrainEvidence: true,
        successfulVideoSubmissions: 0,
        successfulAudioSubmissions: 1
      ))
    #expect(
      MediaSessionEndPolicy.shouldFinish(
        decoderDrainComplete: true,
        rendererDrainEvidence: false,
        successfulVideoSubmissions: 0,
        successfulAudioSubmissions: 0
      ))
    #expect(
      !MediaSessionEndPolicy.shouldFinish(
        decoderDrainComplete: false,
        rendererDrainEvidence: true,
        successfulVideoSubmissions: 0,
        successfulAudioSubmissions: 1
      ))
  }

  @Test func decoderEOFDrainsSubmittedMediaWithoutEnteringBuffering() {
    #expect(
      !MediaSessionEndPolicy.isSupplyStarved(
        presentationRate: 1,
        beforeEnd: true,
        decoderDrainComplete: true,
        videoStarved: true,
        audioStarved: true
      ))
    #expect(
      MediaSessionEndPolicy.isSupplyStarved(
        presentationRate: 1,
        beforeEnd: true,
        decoderDrainComplete: false,
        videoStarved: true,
        audioStarved: false
      ))
  }

  @Test func queuedRendererMediaPreventsFalseSoftwareQueueStarvation() {
    #expect(
      !MediaSessionEndPolicy.isStreamStarved(
        isSelected: true,
        packetDepth: 0,
        frameDepth: 0,
        rendererBufferedDuration: 0.021
      ))
    #expect(
      MediaSessionEndPolicy.isStreamStarved(
        isSelected: true,
        packetDepth: 0,
        frameDepth: 0,
        rendererBufferedDuration: 0
      ))
    #expect(
      !MediaSessionEndPolicy.isStreamStarved(
        isSelected: true,
        packetDepth: 1,
        frameDepth: 0,
        rendererBufferedDuration: 0
      ))
  }

  @Test func rendererJournalMatchesSampleHistoryForReorderedIntervals() throws {
    var journal = DifferentialRendererObservationJournal(epoch: 4)
    var history: [DifferentialStreamKind: [DifferentialMediaInterval]] = [:]
    var expectedReadiness: [DifferentialStreamKind: DifferentialReadiness] = [:]
    var expectedEOF: Double?
    var seed: UInt64 = 17
    for step in 0..<2_000 {
      seed = seed &* 6364136223846793005 &+ 1
      let kind: DifferentialStreamKind = step.isMultiple(of: 3) ? .audio : .video
      let start = Double(seed % 10_000) / 100 - 20
      let interval = try #require(DifferentialMediaInterval(start: start, end: start + 0.04))
      history[kind, default: []].append(interval)
      journal.recordEnqueued(kind: kind, interval: interval, epoch: 4)
      if step >= 1_000 { journal.markDemuxEOF(epoch: 4) }
      let clock = Double((seed >> 16) % 12_000) / 100 - 20
      let monotonic = Double(step)
      for (stream, samples) in history where expectedReadiness[stream] == nil {
        if samples.contains(where: { clock >= $0.start }) {
          expectedReadiness[stream] = .measured(
            monotonicSeconds: monotonic, evidence: "renderer-clock-crossed-sample")
        }
      }
      if step >= 1_000, expectedEOF == nil,
         let end = history.values.flatMap({ $0 }).map(\.end).max(), clock >= end {
        expectedEOF = monotonic
      }
      journal.observeRendererClock(mediaTime: clock, monotonicSeconds: monotonic, epoch: 4)
      for stream in [DifferentialStreamKind.video, .audio] {
        if let expected = expectedReadiness[stream] {
          #expect(journal.readiness(for: stream) == expected)
        }
      }
      #expect(journal.rendererEOFMonotonicSeconds == expectedEOF)
    }
    #expect(journal.retainedStreamCount == 2)
  }

  @Test func rendererJournalStaysBoundedAndPreservesCompletedEOF() throws {
    var journal = DifferentialRendererObservationJournal(epoch: 8)
    journal.markDemuxEOF(epoch: 8)
    journal.observeRendererClock(mediaTime: 10, monotonicSeconds: 1, epoch: 8)
    #expect(!journal.isRendererDrained) // Empty epochs do not manufacture drain.
    for index in 0..<1_000_000 {
      let time = Double(index) / 100
      journal.recordEnqueued(kind: index.isMultiple(of: 2) ? .video : .audio,
        interval: try #require(DifferentialMediaInterval(start: time, end: time + 0.01)), epoch: 8)
    }
    #expect(journal.retainedStreamCount == 2)
    journal.observeRendererClock(mediaTime: 10_000, monotonicSeconds: 2, epoch: 8)
    #expect(journal.rendererEOFMonotonicSeconds == 2)
    // Preserve the existing contract: a late enqueue does not revoke drain.
    journal.recordEnqueued(kind: .audio,
      interval: try #require(DifferentialMediaInterval(start: 20_000, end: 20_001)), epoch: 8)
    journal.observeRendererClock(mediaTime: 30_000, monotonicSeconds: 3, epoch: 8)
    #expect(journal.rendererEOFMonotonicSeconds == 2)
    let replacement = DifferentialRendererObservationJournal(epoch: 9)
    #expect(replacement.retainedStreamCount == 0)
    #expect(!replacement.isRendererDrained)
  }

  @Test func rendererObservationRejectsStaleEpochSamplesAndClocks() throws {
    var journal = DifferentialRendererObservationJournal(epoch: 2)
    journal.recordEnqueued(
      kind: .video,
      interval: try #require(DifferentialMediaInterval(start: 0, end: 0.04)),
      epoch: 1
    )
    journal.observeRendererClock(mediaTime: 1, monotonicSeconds: 1, epoch: 1)
    #expect(journal.staleObservationCount == 2)
    #expect(
      journal.readiness(for: .video)
        == .unmeasured(
          reason: "No renderer-backed clock observation crossed an enqueued interval"
        ))
  }

  @Test func semanticMatrixCoversTheRequiredDependencyOrderedCases() throws {
    let cases = DifferentialSemanticMatrix.requiredCases
    #expect(Set(cases.map(\.id)) == Set(DifferentialSemanticCaseID.allCases))
    #expect(cases.first?.id == .openCatalogSelection)
    #expect(cases.allSatisfy { !$0.fixtureNames.isEmpty })
    let timeline = try #require(cases.firstIndex { $0.id == .timelineCapabilities })
    let seeking = try #require(cases.firstIndex { $0.id == .seeking })
    let drain = try #require(cases.firstIndex { $0.id == .drainAndEOF })
    #expect(timeline < seeking)
    #expect(seeking < drain)
  }

  @Test func stagedInputRetriesTemporaryUnreadabilityAndHonorsCancellation() throws {
    var adapter = DifferentialStagedInputAdapter(
      stages: [
        .temporarilyUnreadable,
        .temporarilyUnreadable,
        .readable(Data("eventual bytes".utf8)),
      ],
      retryLimit: 3
    )

    #expect(try adapter.read() == Data("eventual bytes".utf8))
    #expect(adapter.retryCount == 2)

    var cancelled = DifferentialStagedInputAdapter(
      stages: [.temporarilyUnreadable, .readable(Data("too late".utf8))],
      retryLimit: 2
    )
    cancelled.cancel()
    #expect(throws: DifferentialStagedInputError.cancelled) {
      try cancelled.read()
    }
  }

  @Test func stagedInputFailsDeterministicallyWhenRetryBudgetIsExhausted() {
    var adapter = DifferentialStagedInputAdapter(
      stages: [.temporarilyUnreadable, .temporarilyUnreadable],
      retryLimit: 1
    )

    #expect(throws: DifferentialStagedInputError.retryLimitExceeded) {
      try adapter.read()
    }
    #expect(adapter.retryCount == 2)
  }

  @Test func acceptanceEvaluatorEnforcesEveryNumericAndLifecycleThreshold() {
    var evidence = DifferentialAcceptanceEvidence()
    evidence.selectedStreamCases = 24
    evidence.selectedStreamMismatches = 0
    evidence.exactVideoDeltaSeconds = 1.0 / 60.0
    evidence.exactVideoFrameDurationSeconds = 1.0 / 30.0
    evidence.exactAudioTarget = 1.25
    evidence.exactAudioFirstSample = 1.25
    evidence.steadyAVDifferences = [0.01, -0.02, 0.05]
    evidence.productEOFMinusLastPresentationSeconds = 0.2
    evidence.outputQuantumSeconds = 0.02
    evidence.previewCommitCount = 8
    evidence.previewCommitLimit = 8
    evidence.finalExactTargetWon = true
    evidence.observedQueueItems = 192
    evidence.queueItemLimit = 192
    evidence.observedQueueBytes = 8 * 1_024 * 1_024
    evidence.queueByteLimit = 8 * 1_024 * 1_024
    evidence.replacementCycles = 50
    evidence.warmedResidentBytes = 200 * 1_024 * 1_024
    evidence.postQuiescenceResidentBytes = 231 * 1_024 * 1_024
    evidence.monotonicReplacementGrowth = false
    evidence.liveWorkers = 0
    evidence.liveLeases = 0
    evidence.pendingCallbacks = 0
    evidence.staleEpochCommits = 0
    evidence.unsupportedCapabilitiesReportedExplicitly = true

    let passing = DifferentialAcceptanceEvaluator.evaluate(evidence)
    #expect(Set(passing.gates.map(\.id)) == Set(DifferentialAcceptanceGateID.allCases))
    #expect(passing.gates.allSatisfy { $0.status == .passed })
    #expect(!passing.hasFailure)

    evidence.exactAudioFirstSample = 1.249
    evidence.replacementCycles = 49
    evidence.liveWorkers = 1
    evidence.staleEpochCommits = 1
    let failing = DifferentialAcceptanceEvaluator.evaluate(evidence)
    #expect(failing.hasFailure)
    #expect(failing.gates.first { $0.id == .exactAudioFloor }?.status == .failed)
    #expect(failing.gates.first { $0.id == .replacementMemory }?.status == .failed)
    #expect(failing.gates.first { $0.id == .terminalQuiescence }?.status == .failed)
    #expect(failing.gates.first { $0.id == .staleEpochExclusion }?.status == .failed)
  }

  @Test func absentPhysicalEvidenceStaysUnmeasuredInsteadOfPassing() {
    let report = DifferentialAcceptanceEvaluator.evaluate(DifferentialAcceptanceEvidence())
    #expect(!report.hasFailure)
    #expect(report.gates.allSatisfy { $0.status == .unmeasured })
  }

  @Test func deterministicSemanticPolicyArtifactCoversSwitchRollbackDelayAndNearEOF() {
    let report = DifferentialSemanticPolicyQualification.run()
    #expect(report.passed)
    #expect(Set(report.outcomes.map(\.policy)) == Set(DifferentialSemanticPolicyID.allCases))
    #expect(report.outcomes.allSatisfy { $0.passed })
  }

  @Test func deterministicAcceptanceMarksOnlyActuallyExercisedGatesAsPassed() {
    let evidence = DifferentialAcceptanceEvaluator.deterministicEvidence(
      raceReport: DifferentialRaceQualification.run(),
      semanticPolicyReport: DifferentialSemanticPolicyQualification.run()
    )
    let report = DifferentialAcceptanceEvaluator.evaluate(evidence)
    #expect(!report.hasFailure)
    let passed = Set(report.gates.filter { $0.status == .passed }.map(\.id))
    #expect(
      passed == [
        .previewCadence, .queueBounds, .terminalQuiescence,
        .staleEpochExclusion, .unsupportedCapabilityReporting,
      ])
    #expect(report.gates.filter { $0.status == .unmeasured }.count == 6)
  }

  @Test func liveSemanticAcceptanceAddsSelectionAndWorstAudioFloorEvidence() {
    let target = 1.25
    let oracleTrack = DifferentialSelectedStream(
      kind: .audio,
      index: 0,
      codec: "flac",
      language: "eng",
      dispositions: ["default"],
      stableID: "audio:0",
      selectionReason: "mpv selected track"
    )
    let nativeTrack = DifferentialSelectedStream(
      kind: .audio,
      index: 0,
      codec: "flac",
      language: "eng",
      dispositions: ["default"],
      stableID: "audio:0",
      selectionReason: "native demux default policy"
    )
    let oracle = DifferentialPlayerResult.fixture(
      runner: .mpv,
      seekTarget: target,
      videoPTS: target,
      audioPTS: target,
      eof: .clean,
      selectedStreams: [oracleTrack]
    )
    let native = DifferentialPlayerResult.fixture(
      runner: .illiquid,
      seekTarget: target,
      videoPTS: target,
      audioPTS: target + 0.000_01,
      eof: .clean,
      selectedStreams: [nativeTrack]
    )
    let deterministic = DifferentialAcceptanceEvaluator.deterministicEvidence(
      raceReport: DifferentialRaceQualification.run(),
      semanticPolicyReport: DifferentialSemanticPolicyQualification.run()
    )
    let evidence = DifferentialAcceptanceEvaluator.liveSemanticEvidence(
      results: [(oracle, native)],
      merging: deterministic
    )
    let report = DifferentialAcceptanceEvaluator.evaluate(evidence)

    #expect(report.gates.first { $0.id == .selectedStreams }?.status == .passed)
    #expect(report.gates.first { $0.id == .exactAudioFloor }?.status == .passed)
    #expect(report.gates.filter { $0.status == .passed }.count == 7)
    #expect(report.gates.filter { $0.status == .unmeasured }.count == 4)
  }

  @Test func liveSemanticAcceptanceCountsMissingSelectionAsAMismatch() {
    let selected = DifferentialSelectedStream(
      kind: .video,
      index: 0,
      codec: "h264",
      language: nil,
      dispositions: ["default"],
      stableID: "video:0",
      selectionReason: "selected by runner"
    )
    let oracle = DifferentialPlayerResult.fixture(
      runner: .mpv,
      seekTarget: 1,
      videoPTS: 1,
      audioPTS: 1,
      eof: .clean,
      selectedStreams: [selected]
    )
    let native = DifferentialPlayerResult.fixture(
      runner: .illiquid,
      seekTarget: 1,
      videoPTS: 1,
      audioPTS: 1,
      eof: .notReached,
      selectedStreams: []
    )

    let evidence = DifferentialAcceptanceEvaluator.liveSemanticEvidence(
      results: [(oracle, native)]
    )
    let report = DifferentialAcceptanceEvaluator.evaluate(evidence)

    #expect(evidence.selectedStreamCases == 1)
    #expect(evidence.selectedStreamMismatches == 1)
    let selectedStreamsGate = report.gates.first { $0.id == .selectedStreams }
    #expect(selectedStreamsGate?.status == .failed)
  }
}

extension DifferentialPlayerResult {
  fileprivate static func fixture(
    runner: DifferentialRunnerIdentity,
    seekTarget: Double,
    videoPTS: Double,
    audioPTS: Double,
    eof: DifferentialEOFOutcome,
    selectedStreams: [DifferentialSelectedStream] = []
  ) -> Self {
    DifferentialPlayerResult(
      runner: runner,
      mode: .headlessSemantic,
      processExitCode: 0,
      opened: true,
      selectedStreams: selectedStreams,
      firstDecoded: [.video: 0, .audio: 0],
      firstEnqueued: [.video: 0, .audio: 0],
      readiness: [
        .video: .unmeasured(reason: "headless"),
        .audio: .unmeasured(reason: "headless"),
      ],
      seek: DifferentialSeekResult(
        mode: .exact,
        requestedTarget: seekTarget,
        lowLevelTarget: seekTarget,
        actualVideoPTS: videoPTS,
        firstAudioSamplePTS: audioPTS,
        completionReason: "prerolled",
        latencyMilliseconds: 10
      ),
      eof: eof,
      timeline: [],
      limitations: ["Presentation is unmeasured in headless semantic mode"]
    )
  }
}
