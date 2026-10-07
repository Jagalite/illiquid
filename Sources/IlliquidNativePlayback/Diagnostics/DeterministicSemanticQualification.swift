import CoreMedia
import Foundation
import IlliquidPlaybackCore

public enum DifferentialSemanticPolicyID: String, CaseIterable, Codable, Sendable {
  case audioSwitchRollback
  case subtitleSwitchCommit
  case subtitleDelayClampAndAcknowledge
  case finalNearEOFSeekWins
  case malformedTrackIDRejection
  case bitmapSubtitleCapability
}

public struct DifferentialSemanticPolicyOutcome: Codable, Equatable, Sendable {
  public let policy: DifferentialSemanticPolicyID
  public let passed: Bool
  public let evidence: String

  public init(policy: DifferentialSemanticPolicyID, passed: Bool, evidence: String) {
    self.policy = policy
    self.passed = passed
    self.evidence = evidence
  }
}

public struct DifferentialSemanticPolicyReport: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let outcomes: [DifferentialSemanticPolicyOutcome]

  public init(schemaVersion: Int = 1, outcomes: [DifferentialSemanticPolicyOutcome]) {
    self.schemaVersion = schemaVersion
    self.outcomes = outcomes
  }

  public var passed: Bool {
    Set(outcomes.map(\.policy)) == Set(DifferentialSemanticPolicyID.allCases)
      && outcomes.allSatisfy(\.passed)
  }
}

public enum DifferentialSemanticPolicyQualification {
  public static func run() -> DifferentialSemanticPolicyReport {
    var outcomes: [DifferentialSemanticPolicyOutcome] = []

    let audio = PlaybackTrackID(kind: .audio, mediaTrackID: 2)
    var audioSwitch = TrackSelectionMachineState()
    let requestedAudio = audioSwitch.requestAudio(.stream(audio))
    let audioRevision = audioSwitch.revision
    let preparedAudio = audioSwitch.prepared(revision: audioRevision)
    let failedAudio = audioSwitch.failed(revision: audioRevision)
    let rolledBackAudio = audioSwitch.rolledBack(revision: audioRevision)
    outcomes.append(.init(
      policy: .audioSwitchRollback,
      passed: requestedAudio == .prepareAudio(.stream(audio), revision: audioRevision)
        && preparedAudio == .commit(revision: audioRevision)
        && failedAudio == .rollback(revision: audioRevision)
        && rolledBackAudio && audioSwitch.effectiveAudio == .automatic
        && audioSwitch.phase == .idle,
      evidence: "revision=\(audioRevision.rawValue);phase=\(audioSwitch.phase.rawValue)"
    ))

    let subtitle = PlaybackTrackID(kind: .subtitle, mediaTrackID: 4)
    var subtitleSwitch = TrackSelectionMachineState()
    let requestedSubtitle = subtitleSwitch.requestSubtitle(.embedded(subtitle))
    let subtitleRevision = subtitleSwitch.revision
    let preparedSubtitle = subtitleSwitch.prepared(revision: subtitleRevision)
    let committedSubtitle = subtitleSwitch.committed(revision: subtitleRevision)
    outcomes.append(.init(
      policy: .subtitleSwitchCommit,
      passed: requestedSubtitle == .prepareSubtitle(
        .embedded(subtitle), revision: subtitleRevision)
        && preparedSubtitle == .commit(revision: subtitleRevision)
        && committedSubtitle
        && subtitleSwitch.effectiveSubtitle == .embedded(subtitle)
        && subtitleSwitch.phase == .idle,
      evidence: "revision=\(subtitleRevision.rawValue);phase=\(subtitleSwitch.phase.rawValue)"
    ))

    var control = ControlMachineState()
    let clamped = control.requestSubtitleDelay(microseconds: 20_000_000)
    let staleAcknowledgment = control.acknowledgeSubtitleDelay(microseconds: 2_000_000)
    let currentAcknowledgment = control.acknowledgeSubtitleDelay(microseconds: clamped)
    outcomes.append(.init(
      policy: .subtitleDelayClampAndAcknowledge,
      passed: clamped == 10_000_000 && !staleAcknowledgment && currentAcknowledgment
        && control.appliedSubtitleDelayMicroseconds == 10_000_000,
      evidence: "requested=\(control.requestedSubtitleDelayMicroseconds);applied=\(control.appliedSubtitleDelayMicroseconds)"
    ))

    let seeks = SeekCoordinator()
    let targets = [2.70, 2.85, 2.95, 2.99]
    for (offset, target) in targets.enumerated() {
      seeks.submit(SeekRequest(
        target: CMTime(seconds: target, preferredTimescale: 60_000),
        exact: offset == targets.indices.last,
        generation: offset + 1,
        resumeRate: 0,
        isPreview: offset != targets.indices.last
      ))
    }
    let finalGeneration = targets.count
    for barrier in [
      SeekInvalidationBarrier.inputReadCancellation, .packetAndFrameQueues,
      .presentationFence, .subtitleVisibleClear, .subtitleSourceInvalidation,
    ] {
      seeks.acknowledge(barrier, generation: finalGeneration)
    }
    let finalSeek = seeks.takePending()
    outcomes.append(.init(
      policy: .finalNearEOFSeekWins,
      passed: finalSeek?.generation == finalGeneration && finalSeek?.exact == true
        && finalSeek?.isPreview == false
        && abs((finalSeek?.target.seconds ?? 0) - (targets.last ?? 0)) < 0.000_001,
      evidence: "generation=\(finalSeek?.generation ?? -1);target=\(finalSeek?.target.seconds ?? -1)"
    ))

    let malformed = [Int64.min, -1, 0, Int64(Int32.max) + 2, Int64.max]
    outcomes.append(.init(
      policy: .malformedTrackIDRejection,
      passed: malformed.allSatisfy { NativeTrackIDMapping.streamIndex(for: $0) == nil }
        && NativeTrackIDMapping.streamIndex(for: 1) == 0,
      evidence: "rejected=\(malformed.count);valid-one=\(String(describing: NativeTrackIDMapping.streamIndex(for: 1)))"
    ))

    let bitmapCodecs = ["hdmv_pgs_subtitle", "dvd_subtitle", "dvb_subtitle"]
    outcomes.append(.init(
      policy: .bitmapSubtitleCapability,
      passed: bitmapCodecs.allSatisfy {
        NativeSubtitleCapability.classify(codecName: $0) == .bitmap
      } && !NativeSubtitleCapability.classify(codecName: "xsub").isPlayable
        && NativeSubtitleCapability.classify(codecName: "ass").isPlayable,
      evidence: "selectable=\(bitmapCodecs.joined(separator: ","));unsupported=xsub;text=ass;pixel-qualification=separate"
    ))

    return DifferentialSemanticPolicyReport(outcomes: outcomes)
  }
}
