import IlliquidPlaybackCore

public enum SearchResultOutcome: String, Codable, Hashable, CaseIterable, Sendable {
  case succeeded, failed, cancelled
}

public enum SearchResultMutation: String, Codable, Hashable, Sendable {
  case none, previousGeneration, unrelatedSession, wrongOperation, wrongEffect
  case wrongRevision, undeclaredToken
}

public enum SearchCommand: String, Codable, Hashable, Sendable {
  case loadReplacement, play, pause, seekExact, seekKeyframe, seekPreview, seekRelative
  case selectAudio, selectSubtitle, subtitleOff, stop, shutdown, invalidSeek
  case selectAudioInvalid, selectSubtitleInvalid, selectWrongKind, setSubtitleDelay
}

public enum SearchRuntimeFact: String, Codable, Hashable, Sendable {
  case eofAV, eofVideo, eofAudio, eofAggregate
  case drainVideoDecoder, drainVideoSubmission, drainVideoPresenter
  case drainAudioDecoder, drainAudioConverter, drainAudioSubmission, drainAudioPresenter
  case prerollVideo, prerollAudio, starved, supplied, subtitleInvalidate
  case recoverableVideoFailure, recurrentVideoFailure, presentationFailure
  case oldOverlayCommit, currentOverlayCommit, formatVideo, installExternalSubtitle
}

public enum SearchIngressRelation: String, Codable, Hashable, Sendable {
  case current, previous, unrelated
}

public enum SearchAction: Codable, Hashable, Sendable {
  case command(SearchCommand)
  case result(
    effectID: PlaybackEffectID, outcome: SearchResultOutcome, mutation: SearchResultMutation)
  case lateResult(index: Int)
  case runtimeFact(SearchRuntimeFact, ingress: SearchIngressRelation)
  case seekPrerequisite(SeekExecutorPrerequisite)
  case seekAggregateReady
  case recoveryPrerequisite(RecoveryExecutorPrerequisite)
  case trackPrerequisite(TrackExecutorPrerequisite)
  case recoveryAggregateReady
  case trackAggregateReady
  case queueOffer(SynchronizedStream)
  case queueConsume(SynchronizedStream)
  case resourceCustodyReturned

  public var stableClass: String {
    switch self {
    case .command(let command): return "command.\(command.rawValue)"
    case .result(_, let outcome, let mutation):
      return "result.\(outcome.rawValue).\(mutation.rawValue)"
    case .lateResult: return "result.duplicate"
    case .runtimeFact(let fact, let ingress):
      return "fact.\(fact.rawValue).\(ingress.rawValue)"
    case .seekPrerequisite(let prerequisite):
      return "executor.seek.\(prerequisite.rawValue)"
    case .seekAggregateReady: return "executor.seek.aggregate-ready"
    case .recoveryPrerequisite(let prerequisite):
      return "executor.recovery.\(prerequisite.rawValue)"
    case .trackPrerequisite(let prerequisite):
      return "executor.track.\(prerequisite.rawValue)"
    case .recoveryAggregateReady: return "executor.recovery.aggregate-ready"
    case .trackAggregateReady: return "executor.track.aggregate-ready"
    case .queueOffer(let stream): return "queue.\(stream.rawValue).offer"
    case .queueConsume(let stream): return "queue.\(stream.rawValue).consume"
    case .resourceCustodyReturned: return "resource.custody-returned"
    }
  }
}
