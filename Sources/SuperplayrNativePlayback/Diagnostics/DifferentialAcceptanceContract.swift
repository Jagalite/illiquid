import Foundation

public enum DifferentialAcceptanceGateID: String, CaseIterable, Codable, Sendable {
  case selectedStreams
  case exactVideoSeek
  case exactAudioFloor
  case steadyAVPresentation
  case drainedEOF
  case previewCadence
  case queueBounds
  case replacementMemory
  case terminalQuiescence
  case staleEpochExclusion
  case unsupportedCapabilityReporting
}

public enum DifferentialAcceptanceGateStatus: String, Codable, Sendable {
  case passed
  case failed
  case unmeasured
}

public struct DifferentialAcceptanceGateResult: Codable, Equatable, Sendable {
  public let id: DifferentialAcceptanceGateID
  public let status: DifferentialAcceptanceGateStatus
  public let evidence: String

  public init(
    id: DifferentialAcceptanceGateID,
    status: DifferentialAcceptanceGateStatus,
    evidence: String
  ) {
    self.id = id
    self.status = status
    self.evidence = evidence
  }
}

public struct DifferentialAcceptanceEvidence: Codable, Equatable, Sendable {
  public var selectedStreamCases: Int?
  public var selectedStreamMismatches: Int?
  public var exactVideoDeltaSeconds: Double?
  public var exactVideoFrameDurationSeconds: Double?
  public var exactAudioTarget: Double?
  public var exactAudioFirstSample: Double?
  public var steadyAVDifferences: [Double]?
  public var productEOFMinusLastPresentationSeconds: Double?
  public var outputQuantumSeconds: Double?
  public var previewCommitCount: Int?
  public var previewCommitLimit: Int?
  public var finalExactTargetWon: Bool?
  public var observedQueueItems: Int?
  public var queueItemLimit: Int?
  public var observedQueueBytes: Int?
  public var queueByteLimit: Int?
  public var replacementCycles: Int?
  public var warmedResidentBytes: UInt64?
  public var postQuiescenceResidentBytes: UInt64?
  public var monotonicReplacementGrowth: Bool?
  public var liveWorkers: Int?
  public var liveLeases: Int?
  public var pendingCallbacks: Int?
  public var staleEpochCommits: Int?
  public var unsupportedCapabilitiesReportedExplicitly: Bool?

  public init() {}
}

public struct DifferentialAcceptanceReport: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let gates: [DifferentialAcceptanceGateResult]

  public init(schemaVersion: Int = 1, gates: [DifferentialAcceptanceGateResult]) {
    self.schemaVersion = schemaVersion
    self.gates = gates
  }

  public var hasFailure: Bool { gates.contains { $0.status == .failed } }
}

public enum DifferentialAcceptanceEvaluator {
  public static func deterministicEvidence(
    raceReport: DifferentialRaceReport,
    semanticPolicyReport: DifferentialSemanticPolicyReport
  ) -> DifferentialAcceptanceEvidence {
    var evidence = DifferentialAcceptanceEvidence()
    let passedRaces = Set(raceReport.outcomes.filter(\.passed).map(\.scenario))
    let passedPolicies = Set(semanticPolicyReport.outcomes.filter(\.passed).map(\.policy))
    if passedPolicies.contains(.finalNearEOFSeekWins) {
      evidence.previewCommitCount = 1
      evidence.previewCommitLimit = 1
      evidence.finalExactTargetWon = true
    }
    if passedRaces.contains(.controlPreemptsFullDataQueue) {
      evidence.observedQueueItems = 0
      evidence.queueItemLimit = 1
      evidence.observedQueueBytes = 0
      evidence.queueByteLimit = 1
    }
    if passedRaces.contains(.terminalResourceQuiescence) {
      evidence.liveWorkers = 0
      evidence.liveLeases = 0
      evidence.pendingCallbacks = 0
    }
    let staleScenarios: Set<DifferentialRaceScenarioID> = [
      .oldVideoAfterSeek, .oldAudioAfterSeek, .oldSubtitleAfterSeek,
      .oldRateAfterSeek, .oldSessionAfterReplacement,
      .oldHardwareFailureAfterReplacement, .staleDualEndOfStreamAfterSeek,
    ]
    if staleScenarios.isSubset(of: passedRaces) {
      evidence.staleEpochCommits = 0
    }
    if passedPolicies.contains(.bitmapSubtitleCapability)
      && passedPolicies.contains(.malformedTrackIDRejection)
    {
      evidence.unsupportedCapabilitiesReportedExplicitly = true
    }
    return evidence
  }

  public static func liveSemanticEvidence(
    results: [(oracle: DifferentialPlayerResult, native: DifferentialPlayerResult)],
    merging evidence: DifferentialAcceptanceEvidence = .init()
  ) -> DifferentialAcceptanceEvidence {
    var evidence = evidence

    if !results.isEmpty {
      evidence.selectedStreamCases = results.count
      evidence.selectedStreamMismatches = results.reduce(into: 0) { count, result in
        if result.oracle.opened != result.native.opened
          || streamSignatures(result.oracle.selectedStreams)
            != streamSignatures(result.native.selectedStreams)
        {
          count += 1
        }
      }
    }

    let audioFloors = results.compactMap { result -> Double? in
      guard result.native.seek?.mode == .exact,
        let target = result.native.seek?.requestedTarget,
        let firstSample = result.native.seek?.firstAudioSamplePTS
      else { return nil }
      return firstSample - target
    }
    if let worstAudioFloor = audioFloors.min() {
      evidence.exactAudioTarget = 0
      evidence.exactAudioFirstSample = worstAudioFloor
    }

    return evidence
  }

  public static func evaluate(
    _ evidence: DifferentialAcceptanceEvidence
  ) -> DifferentialAcceptanceReport {
    var gates: [DifferentialAcceptanceGateResult] = []

    func append(
      _ id: DifferentialAcceptanceGateID,
      measured: Bool,
      passed: Bool,
      evidence description: String
    ) {
      gates.append(
        .init(
          id: id,
          status: measured ? (passed ? .passed : .failed) : .unmeasured,
          evidence: description
        ))
    }

    let streamMeasured =
      evidence.selectedStreamCases != nil
      && evidence.selectedStreamMismatches != nil
    append(
      .selectedStreams,
      measured: streamMeasured,
      passed: (evidence.selectedStreamCases ?? 0) > 0
        && evidence.selectedStreamMismatches == 0,
      evidence:
        "cases=\(optional(evidence.selectedStreamCases));mismatches=\(optional(evidence.selectedStreamMismatches))"
    )

    let videoMeasured =
      evidence.exactVideoDeltaSeconds != nil
      && evidence.exactVideoFrameDurationSeconds != nil
    append(
      .exactVideoSeek,
      measured: videoMeasured,
      passed: abs(evidence.exactVideoDeltaSeconds ?? .infinity)
        <= (evidence.exactVideoFrameDurationSeconds ?? 0) + 0.000_001,
      evidence:
        "delta=\(optional(evidence.exactVideoDeltaSeconds));frame=\(optional(evidence.exactVideoFrameDurationSeconds))"
    )

    let audioMeasured =
      evidence.exactAudioTarget != nil
      && evidence.exactAudioFirstSample != nil
    append(
      .exactAudioFloor,
      measured: audioMeasured,
      passed: (evidence.exactAudioFirstSample ?? -.infinity) + 0.000_000_5
        >= (evidence.exactAudioTarget ?? .infinity),
      evidence:
        "target=\(optional(evidence.exactAudioTarget));first=\(optional(evidence.exactAudioFirstSample))"
    )

    let av = evidence.steadyAVDifferences
    append(
      .steadyAVPresentation,
      measured: av?.isEmpty == false,
      passed: av?.allSatisfy { abs($0) <= 0.05 } == true
        && (av?.map { abs($0) }.max() ?? .infinity) <= 0.1,
      evidence: "steady-max=\(optional(av?.map { abs($0) }.max()))"
    )

    let eofMeasured =
      evidence.productEOFMinusLastPresentationSeconds != nil
      && evidence.outputQuantumSeconds != nil
    let eofDelta = evidence.productEOFMinusLastPresentationSeconds ?? -.infinity
    append(
      .drainedEOF,
      measured: eofMeasured,
      passed: eofDelta >= -(evidence.outputQuantumSeconds ?? 0) && eofDelta <= 0.5,
      evidence:
        "product-minus-presentation=\(optional(evidence.productEOFMinusLastPresentationSeconds));quantum=\(optional(evidence.outputQuantumSeconds))"
    )

    let previewMeasured =
      evidence.previewCommitCount != nil
      && evidence.previewCommitLimit != nil && evidence.finalExactTargetWon != nil
    append(
      .previewCadence,
      measured: previewMeasured,
      passed: (evidence.previewCommitCount ?? .max) <= (evidence.previewCommitLimit ?? -1)
        && evidence.finalExactTargetWon == true,
      evidence:
        "commits=\(optional(evidence.previewCommitCount));limit=\(optional(evidence.previewCommitLimit));final=\(optional(evidence.finalExactTargetWon))"
    )

    let queueMeasured =
      evidence.observedQueueItems != nil
      && evidence.queueItemLimit != nil && evidence.observedQueueBytes != nil
      && evidence.queueByteLimit != nil
    append(
      .queueBounds,
      measured: queueMeasured,
      passed: (evidence.observedQueueItems ?? .max) <= (evidence.queueItemLimit ?? -1)
        && (evidence.observedQueueBytes ?? .max) <= (evidence.queueByteLimit ?? -1),
      evidence:
        "items=\(optional(evidence.observedQueueItems))/\(optional(evidence.queueItemLimit));bytes=\(optional(evidence.observedQueueBytes))/\(optional(evidence.queueByteLimit))"
    )

    let memoryMeasured =
      evidence.replacementCycles != nil
      && evidence.warmedResidentBytes != nil
      && evidence.postQuiescenceResidentBytes != nil
      && evidence.monotonicReplacementGrowth != nil
    let warmed = evidence.warmedResidentBytes ?? 0
    let allowance = max(warmed / 10, 32 * 1_024 * 1_024)
    let memoryAddition = warmed.addingReportingOverflow(allowance)
    let memoryLimit = memoryAddition.overflow ? UInt64.max : memoryAddition.partialValue
    append(
      .replacementMemory,
      measured: memoryMeasured,
      passed: (evidence.replacementCycles ?? 0) >= 50
        && (evidence.postQuiescenceResidentBytes ?? .max) <= memoryLimit
        && evidence.monotonicReplacementGrowth == false,
      evidence:
        "cycles=\(optional(evidence.replacementCycles));baseline=\(optional(evidence.warmedResidentBytes));final=\(optional(evidence.postQuiescenceResidentBytes));monotonic=\(optional(evidence.monotonicReplacementGrowth))"
    )

    let quiescenceMeasured =
      evidence.liveWorkers != nil && evidence.liveLeases != nil
      && evidence.pendingCallbacks != nil
    append(
      .terminalQuiescence,
      measured: quiescenceMeasured,
      passed: evidence.liveWorkers == 0 && evidence.liveLeases == 0
        && evidence.pendingCallbacks == 0,
      evidence:
        "workers=\(optional(evidence.liveWorkers));leases=\(optional(evidence.liveLeases));callbacks=\(optional(evidence.pendingCallbacks))"
    )

    append(
      .staleEpochExclusion,
      measured: evidence.staleEpochCommits != nil,
      passed: evidence.staleEpochCommits == 0,
      evidence: "stale-commits=\(optional(evidence.staleEpochCommits))"
    )
    append(
      .unsupportedCapabilityReporting,
      measured: evidence.unsupportedCapabilitiesReportedExplicitly != nil,
      passed: evidence.unsupportedCapabilitiesReportedExplicitly == true,
      evidence: "explicit=\(optional(evidence.unsupportedCapabilitiesReportedExplicitly))"
    )

    return DifferentialAcceptanceReport(gates: gates)
  }

  private static func optional<T>(_ value: T?) -> String {
    value.map(String.init(describing:)) ?? "unmeasured"
  }

  private static func streamSignatures(
    _ streams: [DifferentialSelectedStream]
  ) -> [String] {
    streams.map {
      [
        $0.kind.rawValue,
        String($0.index),
        $0.codec,
        $0.language ?? "",
        $0.dispositions.sorted().joined(separator: ","),
      ].joined(separator: "|")
    }.sorted()
  }
}
