import Foundation
import Testing
@testable import SuperplayrNativePlayback

@Suite("Bounded renderer observation")
struct RendererObservationBoundsTests {
  @Test func agreesWithIntervalOracleAcrossReorderingStaleEventsAndClockChanges() {
    for seed in 1...40 {
      var random = UInt64(seed)
      func next() -> UInt64 {
        random = random &* 6364136223846793005 &+ 1442695040888963407
        return random
      }
      var bounded = DifferentialRendererObservationJournal(epoch: 4)
      var oracle = ArrayObservationOracle(epoch: 4)
      for step in 0..<1000 {
        let epoch = next() % 7 == 0 ? 3 : 4
        let kind: DifferentialStreamKind = [.video, .audio, .subtitle][Int(next() % 3)]
        let position = Double(Int(next() % 1000) - 100) / 10
        switch next() % 5 {
        case 0, 1, 2:
          let interval = DifferentialMediaInterval(start: position, end: position + Double(next() % 50 + 1) / 20)!
          bounded.recordEnqueued(kind: kind, interval: interval, epoch: epoch)
          oracle.recordEnqueued(kind: kind, interval: interval, epoch: epoch)
        case 3:
          bounded.markDemuxEOF(epoch: epoch)
          oracle.markDemuxEOF(epoch: epoch)
        default:
          let clock = step % 11 == 0 ? Double.nan : position
          let uptime = step % 13 == 0 ? Double.infinity : Double(step)
          bounded.observeRendererClock(mediaTime: clock, monotonicSeconds: uptime, epoch: epoch)
          oracle.observeRendererClock(mediaTime: clock, monotonicSeconds: uptime, epoch: epoch)
        }
        for stream: DifferentialStreamKind in [.video, .audio, .subtitle] {
          #expect(bounded.readiness(for: stream) == oracle.readiness(for: stream))
        }
        #expect(bounded.rendererEOFMonotonicSeconds == oracle.rendererEOFMonotonicSeconds)
        #expect(bounded.staleObservationCount == oracle.staleObservationCount)
      }
    }
  }

  @Test func longSessionWaitsForLongestStreamAndNewEpochHasNoEvidence() {
    var journal = DifferentialRendererObservationJournal(epoch: 1)
    for index in 0..<100_000 {
      let start = Double(index) / 60
      journal.recordEnqueued(kind: .video, interval: DifferentialMediaInterval(start: start, end: start + 1 / 60)!, epoch: 1)
    }
    journal.recordEnqueued(kind: .audio, interval: DifferentialMediaInterval(start: -0.1, end: 2000)!, epoch: 1)
    journal.markDemuxEOF(epoch: 1)
    journal.observeRendererClock(mediaTime: 1999, monotonicSeconds: 1, epoch: 1)
    #expect(!journal.isRendererDrained)
    journal.observeRendererClock(mediaTime: 2000, monotonicSeconds: 2, epoch: 1)
    #expect(journal.rendererEOFMonotonicSeconds == 2)
    let oldSnapshot = journal
    journal = DifferentialRendererObservationJournal(epoch: 2)
    journal.markDemuxEOF(epoch: 2)
    journal.observeRendererClock(mediaTime: 3000, monotonicSeconds: 3, epoch: 2)
    #expect(!journal.isRendererDrained)
    #expect(oldSnapshot.rendererEOFMonotonicSeconds == 2)
  }
}

// The previous interval-retaining implementation is the behavioral oracle.
private struct ArrayObservationOracle: Sendable {
  let epoch: Int
  private(set) var staleObservationCount = 0
  private(set) var rendererEOFMonotonicSeconds: Double?

  private var intervals: [DifferentialStreamKind: [DifferentialMediaInterval]] = [:]
  private var readiness: [DifferentialStreamKind: DifferentialReadiness] = [:]
  private var demuxEOF = false

  init(epoch: Int) {
    self.epoch = epoch
  }

  mutating func recordEnqueued(
    kind: DifferentialStreamKind,
    interval: DifferentialMediaInterval,
    epoch: Int
  ) {
    guard epoch == self.epoch else {
      staleObservationCount += 1
      return
    }
    intervals[kind, default: []].append(interval)
  }

  mutating func markDemuxEOF(epoch: Int) {
    guard epoch == self.epoch else {
      staleObservationCount += 1
      return
    }
    demuxEOF = true
  }

  mutating func observeRendererClock(
    mediaTime: Double,
    monotonicSeconds: Double,
    epoch: Int
  ) {
    guard epoch == self.epoch else {
      staleObservationCount += 1
      return
    }
    guard mediaTime.isFinite, monotonicSeconds.isFinite else { return }
    for (kind, samples) in intervals where readiness[kind] == nil {
      if samples.contains(where: { mediaTime >= $0.start }) {
        readiness[kind] = .measured(
          monotonicSeconds: monotonicSeconds,
          evidence: "renderer-clock-crossed-sample"
        )
      }
    }
    guard demuxEOF,
      let requiredEnd = intervals.values.flatMap({ $0 }).map(\.end).max(),
      mediaTime >= requiredEnd,
      rendererEOFMonotonicSeconds == nil
    else { return }
    rendererEOFMonotonicSeconds = monotonicSeconds
  }

  func readiness(for kind: DifferentialStreamKind) -> DifferentialReadiness {
    readiness[kind] ?? .unmeasured(
      reason: "No renderer-backed clock observation crossed an enqueued interval"
    )
  }

  var isRendererDrained: Bool { rendererEOFMonotonicSeconds != nil }
}
