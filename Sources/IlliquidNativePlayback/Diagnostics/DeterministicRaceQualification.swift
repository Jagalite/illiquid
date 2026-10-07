import Foundation

public enum DifferentialRaceScenarioID: String, CaseIterable, Codable, Sendable {
  case oldVideoAfterSeek
  case oldAudioAfterSeek
  case oldSubtitleAfterSeek
  case oldRateAfterSeek
  case oldSessionAfterReplacement
  case oldHardwareFailureAfterReplacement
  case staleDualEndOfStreamAfterSeek
  case controlPreemptsFullDataQueue
  case closeDuringBlockedInput
  case closeDuringOpenSeekDecodePresent
  case terminalResourceQuiescence
}

public struct DifferentialRaceOutcome: Codable, Equatable, Sendable {
  public let scenario: DifferentialRaceScenarioID
  public let passed: Bool
  public let evidence: String

  public init(scenario: DifferentialRaceScenarioID, passed: Bool, evidence: String) {
    self.scenario = scenario
    self.passed = passed
    self.evidence = evidence
  }
}

public struct DifferentialRaceReport: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let outcomes: [DifferentialRaceOutcome]

  public init(schemaVersion: Int = 1, outcomes: [DifferentialRaceOutcome]) {
    self.schemaVersion = schemaVersion
    self.outcomes = outcomes
  }

  public var passed: Bool {
    Set(outcomes.map(\.scenario)) == Set(DifferentialRaceScenarioID.allCases)
      && outcomes.allSatisfy(\.passed)
  }
}

public enum DifferentialRaceQualification {
  public static func run() -> DifferentialRaceReport {
    var outcomes: [DifferentialRaceOutcome] = []

    func stale(
      _ scenario: DifferentialRaceScenarioID,
      _ kind: DifferentialCommitKind
    ) -> DifferentialRaceOutcome {
      let barrier = DifferentialCommitBarrier()
      barrier.arm(kind)
      guard let token = barrier.arrive(kind: kind, epoch: 1) else {
        return .init(scenario: scenario, passed: false, evidence: "barrier did not arm")
      }
      let disposition = barrier.release(
        token,
        currentEpoch: 2,
        terminated: false,
        carriesResourceCustody: false
      )
      return .init(
        scenario: scenario,
        passed: disposition == .stale && barrier.pendingCount == 0,
        evidence: "release=\(String(describing: disposition));pending=\(barrier.pendingCount)"
      )
    }

    outcomes.append(stale(.oldVideoAfterSeek, .video))
    outcomes.append(stale(.oldAudioAfterSeek, .audio))
    outcomes.append(stale(.oldSubtitleAfterSeek, .subtitle))
    outcomes.append(stale(.oldRateAfterSeek, .rateChange))
    outcomes.append(stale(.oldSessionAfterReplacement, .presentation))
    outcomes.append(stale(.oldHardwareFailureAfterReplacement, .hardwareFailure))

    let eosBarrier = DifferentialCommitBarrier()
    eosBarrier.arm(.videoEndOfStream)
    eosBarrier.arm(.audioEndOfStream)
    let eosTokens = [
      eosBarrier.arrive(kind: .videoEndOfStream, epoch: 3),
      eosBarrier.arrive(kind: .audioEndOfStream, epoch: 3),
    ].compactMap { $0 }
    let eosDispositions = eosTokens.map {
      eosBarrier.release(
        $0,
        currentEpoch: 4,
        terminated: false,
        carriesResourceCustody: false
      )
    }
    outcomes.append(.init(
      scenario: .staleDualEndOfStreamAfterSeek,
      passed: eosTokens.count == 2 && eosDispositions == [.stale, .stale]
        && eosBarrier.pendingCount == 0,
      evidence: "releases=\(eosDispositions.map(String.init(describing:)))"
    ))

    let queue = BoundedQueue<Int>(capacity: 1)
    _ = queue.push(1)
    let producerFinished = DispatchSemaphore(value: 0)
    let producerResult = LockedBox<Bool?>(nil)
    DispatchQueue.global(qos: .userInitiated).async {
      producerResult.withValue { $0 = queue.push(2) }
      producerFinished.signal()
    }
    let producerDidBlock = queue.waitForBlockedProducer(timeout: 1)
    queue.removeAll()
    let producerDidFinish = producerFinished.wait(timeout: .now() + 1) == .success
    outcomes.append(.init(
      scenario: .controlPreemptsFullDataQueue,
      passed: producerDidBlock && producerDidFinish
        && producerResult.value == false && queue.count == 0,
      evidence: "blocked=\(producerDidBlock);producer=\(String(describing: producerResult.value));queue=\(queue.count)"
    ))
    queue.close()

    let readBarrier = DifferentialCommitBarrier()
    readBarrier.arm(.inputRead)
    let readToken = readBarrier.arrive(kind: .inputRead, epoch: 5)
    let readDisposition = readToken.map {
      readBarrier.release(
        $0,
        currentEpoch: 5,
        terminated: true,
        carriesResourceCustody: true
      )
    }
    outcomes.append(.init(
      scenario: .closeDuringBlockedInput,
      passed: readDisposition == .cleanupOnly && readBarrier.pendingCount == 0,
      evidence: "release=\(String(describing: readDisposition))"
    ))

    let closeBarrier = DifferentialCommitBarrier()
    let closeKinds: [DifferentialCommitKind] = [.open, .seek, .decoder, .presentation]
    let closeTokens = closeKinds.compactMap { kind -> DifferentialCommitToken? in
      closeBarrier.arm(kind)
      return closeBarrier.arrive(kind: kind, epoch: 6)
    }
    let closeDispositions = closeTokens.map {
      closeBarrier.release(
        $0,
        currentEpoch: 6,
        terminated: true,
        carriesResourceCustody: false
      )
    }
    outcomes.append(.init(
      scenario: .closeDuringOpenSeekDecodePresent,
      passed: closeTokens.count == closeKinds.count
        && closeDispositions.allSatisfy { $0 == .droppedAfterTermination }
        && closeBarrier.pendingCount == 0,
      evidence: "releases=\(closeDispositions.map(String.init(describing:)))"
    ))

    let metadata = PlaybackRuntimeMetadataDirectory()
    let session = metadata.beginSession()
    metadata.leases.supersede(authority: session.authority)
    metadata.leases.requestRelease(session.workerLease)
    let released = metadata.leases.observePhysicalRelease(session.workerLease)
    let snapshots = metadata.leases.snapshots()
    outcomes.append(.init(
      scenario: .terminalResourceQuiescence,
      passed: released && snapshots.allSatisfy {
        $0.disposition == .released && $0.activeBorrows.isEmpty
      },
      evidence: "leases=\(snapshots.count);released=\(released)"
    ))

    return DifferentialRaceReport(outcomes: outcomes)
  }
}

private final class LockedBox<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: Value

  init(_ value: Value) { stored = value }

  var value: Value { lock.withLock { stored } }

  func withValue(_ body: (inout Value) -> Void) {
    lock.withLock { body(&stored) }
  }
}
