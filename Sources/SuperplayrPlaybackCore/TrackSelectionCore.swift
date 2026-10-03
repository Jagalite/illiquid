public enum AudioSelectionIntent: Codable, Equatable, Sendable {
  case off
  case automatic
  case stream(PlaybackTrackID)
}

public enum SubtitleSelectionIntent: Codable, Equatable, Sendable {
  case off
  case automatic
  case embedded(PlaybackTrackID)
  case external(MediaSourceIdentity)
}

public enum TrackSelectionTransactionPhase: String, Codable, Equatable, Sendable {
  case idle
  case preparing
  case prepared
  case committing
  case rollingBack
}

public enum TrackSelectionDirective: Codable, Equatable, Sendable {
  case prepareAudio(AudioSelectionIntent, revision: TrackRevisionID)
  case prepareSubtitle(SubtitleSelectionIntent, revision: TrackRevisionID)
  case commit(revision: TrackRevisionID)
  case rollback(revision: TrackRevisionID)
}

public struct TrackSelectionMachineState: Codable, Equatable, Sendable {
  public var requestedAudio: AudioSelectionIntent
  public var effectiveAudio: AudioSelectionIntent
  public var requestedSubtitle: SubtitleSelectionIntent
  public var effectiveSubtitle: SubtitleSelectionIntent
  public var revision: TrackRevisionID
  public var phase: TrackSelectionTransactionPhase
  public var priorAudio: AudioSelectionIntent?
  public var priorSubtitle: SubtitleSelectionIntent?

  public init(
    requestedAudio: AudioSelectionIntent = .automatic,
    effectiveAudio: AudioSelectionIntent = .automatic,
    requestedSubtitle: SubtitleSelectionIntent = .off,
    effectiveSubtitle: SubtitleSelectionIntent = .off,
    revision: TrackRevisionID = TrackRevisionID(rawValue: 0),
    phase: TrackSelectionTransactionPhase = .idle,
    priorAudio: AudioSelectionIntent? = nil,
    priorSubtitle: SubtitleSelectionIntent? = nil
  ) {
    self.requestedAudio = requestedAudio
    self.effectiveAudio = effectiveAudio
    self.requestedSubtitle = requestedSubtitle
    self.effectiveSubtitle = effectiveSubtitle
    self.revision = revision
    self.phase = phase
    self.priorAudio = priorAudio
    self.priorSubtitle = priorSubtitle
  }

  public mutating func requestAudio(
    _ intent: AudioSelectionIntent
  ) -> TrackSelectionDirective? {
    guard phase == .idle, intent != effectiveAudio, revision.rawValue < UInt64.max else {
      return nil
    }
    revision = TrackRevisionID(rawValue: revision.rawValue + 1)
    priorAudio = effectiveAudio
    requestedAudio = intent
    phase = .preparing
    return .prepareAudio(intent, revision: revision)
  }

  public mutating func requestSubtitle(
    _ intent: SubtitleSelectionIntent
  ) -> TrackSelectionDirective? {
    guard phase == .idle, intent != effectiveSubtitle, revision.rawValue < UInt64.max else {
      return nil
    }
    revision = TrackRevisionID(rawValue: revision.rawValue + 1)
    priorSubtitle = effectiveSubtitle
    requestedSubtitle = intent
    phase = .preparing
    return .prepareSubtitle(intent, revision: revision)
  }

  public mutating func prepared(revision candidate: TrackRevisionID) -> TrackSelectionDirective? {
    guard candidate == revision, phase == .preparing else { return nil }
    phase = .committing
    return .commit(revision: revision)
  }

  public mutating func committed(revision candidate: TrackRevisionID) -> Bool {
    guard candidate == revision, phase == .committing else { return false }
    effectiveAudio = requestedAudio
    effectiveSubtitle = requestedSubtitle
    priorAudio = nil
    priorSubtitle = nil
    phase = .idle
    return true
  }

  public mutating func failed(revision candidate: TrackRevisionID) -> TrackSelectionDirective? {
    guard candidate == revision, phase != .idle else { return nil }
    phase = .rollingBack
    return .rollback(revision: revision)
  }

  public mutating func rolledBack(revision candidate: TrackRevisionID) -> Bool {
    guard candidate == revision, phase == .rollingBack else { return false }
    if let priorAudio { requestedAudio = priorAudio; effectiveAudio = priorAudio }
    if let priorSubtitle { requestedSubtitle = priorSubtitle; effectiveSubtitle = priorSubtitle }
    priorAudio = nil
    priorSubtitle = nil
    phase = .idle
    return true
  }
}

public struct ControlMachineState: Codable, Equatable, Sendable {
  public var requestedSubtitleDelayMicroseconds: Int64
  public var appliedSubtitleDelayMicroseconds: Int64

  public init(
    requestedSubtitleDelayMicroseconds: Int64 = 0,
    appliedSubtitleDelayMicroseconds: Int64 = 0
  ) {
    self.requestedSubtitleDelayMicroseconds = requestedSubtitleDelayMicroseconds
    self.appliedSubtitleDelayMicroseconds = appliedSubtitleDelayMicroseconds
  }

  public mutating func requestSubtitleDelay(microseconds: Int64) -> Int64 {
    requestedSubtitleDelayMicroseconds = min(max(microseconds, -10_000_000), 10_000_000)
    return requestedSubtitleDelayMicroseconds
  }

  public mutating func acknowledgeSubtitleDelay(microseconds: Int64) -> Bool {
    guard microseconds == requestedSubtitleDelayMicroseconds else { return false }
    appliedSubtitleDelayMicroseconds = microseconds
    return true
  }
}
