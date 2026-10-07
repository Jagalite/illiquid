import Foundation

/// A normalized media interval accepted by an Apple sample-buffer renderer.
/// Submission is recorded separately from presentation-clock evidence so the
/// differential harness cannot accidentally label queue admission as visible,
/// audible, or drained output.
public struct DifferentialMediaInterval: Equatable, Sendable {
  public let start: Double
  public let end: Double

  public init?(start: Double, end: Double) {
    guard start.isFinite, end.isFinite, end > start else { return nil }
    self.start = start
    self.end = end
  }
}

public struct DifferentialRendererObservationJournal: Sendable {
  public let epoch: Int
  public private(set) var staleObservationCount = 0
  public private(set) var rendererEOFMonotonicSeconds: Double?

  // Readiness asks whether the clock crossed any submitted start; drain asks
  // whether it crossed every submitted end. These extrema preserve both
  // predicates, including out-of-order submissions, without retaining a
  // playback-length array or scanning it on every EOF observation.
  private var earliestStarts: [DifferentialStreamKind: Double] = [:]
  private var latestEnd: Double?
  private var readiness: [DifferentialStreamKind: DifferentialReadiness] = [:]
  private var demuxEOF = false

  public init(epoch: Int) {
    self.epoch = epoch
  }

  public mutating func recordEnqueued(
    kind: DifferentialStreamKind,
    interval: DifferentialMediaInterval,
    epoch: Int
  ) {
    guard epoch == self.epoch else {
      staleObservationCount += 1
      return
    }
    earliestStarts[kind] = min(earliestStarts[kind] ?? interval.start, interval.start)
    latestEnd = max(latestEnd ?? interval.end, interval.end)
  }

  public mutating func markDemuxEOF(epoch: Int) {
    guard epoch == self.epoch else {
      staleObservationCount += 1
      return
    }
    demuxEOF = true
  }

  public mutating func observeRendererClock(
    mediaTime: Double,
    monotonicSeconds: Double,
    epoch: Int
  ) {
    guard epoch == self.epoch else {
      staleObservationCount += 1
      return
    }
    guard mediaTime.isFinite, monotonicSeconds.isFinite else { return }
    for (kind, start) in earliestStarts where readiness[kind] == nil {
      if mediaTime >= start {
        readiness[kind] = .measured(
          monotonicSeconds: monotonicSeconds,
          evidence: "renderer-clock-crossed-sample"
        )
      }
    }
    guard demuxEOF,
      let requiredEnd = latestEnd,
      mediaTime >= requiredEnd,
      rendererEOFMonotonicSeconds == nil
    else { return }
    rendererEOFMonotonicSeconds = monotonicSeconds
  }

  public func readiness(for kind: DifferentialStreamKind) -> DifferentialReadiness {
    readiness[kind] ?? .unmeasured(
      reason: "No renderer-backed clock observation crossed an enqueued interval"
    )
  }

  var retainedStreamCount: Int { earliestStarts.count }

  public var isRendererDrained: Bool { rendererEOFMonotonicSeconds != nil }
}
