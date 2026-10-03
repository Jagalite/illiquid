public struct VideoRecoveryLineage: Codable, Equatable, Hashable, Sendable {
  public let sessionID: PlaybackSessionID
  public let streamID: PlaybackStreamID

  public init(sessionID: PlaybackSessionID, streamID: PlaybackStreamID) {
    self.sessionID = sessionID
    self.streamID = streamID
  }
}

public enum RecoveryDirective: Codable, Equatable, Sendable {
  case resumeVideoDecoderAfterTransientFailure(
    lineage: VideoRecoveryLineage,
    consecutiveCount: Int
  )
  case recreateVideoDecoderInSoftware(
    lineage: VideoRecoveryLineage,
    revision: DecoderRevisionID
  )
  case flushAndReprimePresentation(revision: PresentationRevisionID)
  case rebuildPresentationGraph(revision: PresentationGraphRevisionID)
  case flushAndReprimeAudioPresentation(revision: PresentationRevisionID)
  case rebuildAudioPresentation(revision: PresentationGraphRevisionID)
  case disableAudioTrack(streamID: PlaybackStreamID)
  case disableSubtitleTrack(streamID: PlaybackStreamID?)
  case failTerminal
}

/// Pure retry-budget and classification state. Ordinary seeks and decoder
/// revisions deliberately do not reset the fallback budget; only a new media
/// session or committed selected-video-stream lineage does.
public struct RecoveryMachineState: Codable, Equatable, Sendable {
  public static let hardwareDecodeFailureThreshold = 3

  public var videoLineage: VideoRecoveryLineage?
  public var consumedVideoFallbackLineages: Set<VideoRecoveryLineage>
  public var presentationFlushConsumed: Set<PresentationRevisionID>
  public var presentationGraphRebuildCount: UInt8
  public var disabledAudioStreams: Set<PlaybackStreamID>
  public var disabledSubtitleStreams: Set<PlaybackStreamID>
  public var audioPresentationRecoveryStage: [PlaybackStreamID: UInt8]
  public var lastFailure: PlaybackFailure?

  public init(
    videoLineage: VideoRecoveryLineage? = nil,
    consumedVideoFallbackLineages: Set<VideoRecoveryLineage> = [],
    presentationFlushConsumed: Set<PresentationRevisionID> = [],
    presentationGraphRebuildCount: UInt8 = 0,
    disabledAudioStreams: Set<PlaybackStreamID> = [],
    disabledSubtitleStreams: Set<PlaybackStreamID> = [],
    audioPresentationRecoveryStage: [PlaybackStreamID: UInt8] = [:],
    lastFailure: PlaybackFailure? = nil
  ) {
    self.videoLineage = videoLineage
    self.consumedVideoFallbackLineages = consumedVideoFallbackLineages
    self.presentationFlushConsumed = presentationFlushConsumed
    self.presentationGraphRebuildCount = presentationGraphRebuildCount
    self.disabledAudioStreams = disabledAudioStreams
    self.disabledSubtitleStreams = disabledSubtitleStreams
    self.audioPresentationRecoveryStage = audioPresentationRecoveryStage
    self.lastFailure = lastFailure
  }

  private enum CodingKeys: String, CodingKey {
    case videoLineage
    case consumedVideoFallbackLineages
    case presentationFlushConsumed
    case presentationGraphRebuildCount
    case disabledAudioStreams
    case disabledSubtitleStreams
    case audioPresentationRecoveryStage
    case lastFailure
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    videoLineage = try container.decodeIfPresent(
      VideoRecoveryLineage.self,
      forKey: .videoLineage
    )
    consumedVideoFallbackLineages = try container.decodeIfPresent(
      Set<VideoRecoveryLineage>.self,
      forKey: .consumedVideoFallbackLineages
    ) ?? []
    presentationFlushConsumed = try container.decodeIfPresent(
      Set<PresentationRevisionID>.self,
      forKey: .presentationFlushConsumed
    ) ?? []
    presentationGraphRebuildCount = try container.decodeIfPresent(
      UInt8.self,
      forKey: .presentationGraphRebuildCount
    ) ?? 0
    disabledAudioStreams = try container.decodeIfPresent(
      Set<PlaybackStreamID>.self,
      forKey: .disabledAudioStreams
    ) ?? []
    disabledSubtitleStreams = try container.decodeIfPresent(
      Set<PlaybackStreamID>.self,
      forKey: .disabledSubtitleStreams
    ) ?? []
    audioPresentationRecoveryStage = try container.decodeIfPresent(
      [PlaybackStreamID: UInt8].self,
      forKey: .audioPresentationRecoveryStage
    ) ?? [:]
    lastFailure = try container.decodeIfPresent(
      PlaybackFailure.self,
      forKey: .lastFailure
    )
  }

  public mutating func classify(
    _ failure: PlaybackFailure,
    sessionID: PlaybackSessionID,
    revisions: PlaybackRevisionSet
  ) -> RecoveryDirective {
    lastFailure = failure

    if failure.domain == .audioDecode,
      failure.stage == .enqueue,
      failure.recoverability == .fallbackAvailable,
      let streamID = failure.streamID,
      streamID.kind == .audio
    {
      let stage = audioPresentationRecoveryStage[streamID, default: 0]
      if stage == 0 {
        audioPresentationRecoveryStage[streamID] = 1
        let current = revisions.presentation?.rawValue ?? 0
        guard current < UInt64.max else { return .failTerminal }
        return .flushAndReprimeAudioPresentation(
          revision: PresentationRevisionID(rawValue: current + 1)
        )
      }
      if stage == 1 {
        audioPresentationRecoveryStage[streamID] = 2
        let current = revisions.presentationGraph?.rawValue ?? 0
        guard current < UInt64.max else { return .failTerminal }
        return .rebuildAudioPresentation(
          revision: PresentationGraphRevisionID(rawValue: current + 1)
        )
      }
      guard disabledAudioStreams.insert(streamID).inserted else {
        return .failTerminal
      }
      return .disableAudioTrack(streamID: streamID)
    }

    if failure.domain == .audioDecode,
      failure.recoverability == .fallbackAvailable,
      let streamID = failure.streamID,
      streamID.kind == .audio
    {
      guard disabledAudioStreams.insert(streamID).inserted else {
        return .failTerminal
      }
      return .disableAudioTrack(streamID: streamID)
    }

    if (failure.domain == .subtitle || failure.stableCode == "nativeSubtitleReadFailed"),
      failure.recoverability == .fallbackAvailable
    {
      if let streamID = failure.streamID {
        guard disabledSubtitleStreams.insert(streamID).inserted else {
          return .failTerminal
        }
      }
      return .disableSubtitleTrack(streamID: failure.streamID)
    }

    if failure.domain == .videoDecode,
      failure.recoverability == .fallbackAvailable,
      failure.hardwareWasConfigured,
      let streamID = failure.streamID,
      streamID.kind == .video
    {
      let lineage = VideoRecoveryLineage(sessionID: sessionID, streamID: streamID)
      if videoLineage != lineage {
        videoLineage = lineage
      }
      guard !consumedVideoFallbackLineages.contains(lineage) else {
        return .failTerminal
      }
      if failure.consecutiveCount < Self.hardwareDecodeFailureThreshold {
        return .resumeVideoDecoderAfterTransientFailure(
          lineage: lineage,
          consecutiveCount: max(1, failure.consecutiveCount)
        )
      }
      consumedVideoFallbackLineages.insert(lineage)
      let current = revisions.decoder?.rawValue ?? 0
      guard current < UInt64.max else { return .failTerminal }
      return .recreateVideoDecoderInSoftware(
        lineage: lineage,
        revision: DecoderRevisionID(rawValue: current + 1)
      )
    }

    if failure.domain == .videoDecode,
      failure.stableCode == "softwareVideoDecoderNoProgress",
      failure.recoverability == .fallbackAvailable,
      let streamID = failure.streamID,
      streamID.kind == .video
    {
      let lineage = VideoRecoveryLineage(sessionID: sessionID, streamID: streamID)
      guard !consumedVideoFallbackLineages.contains(lineage) else {
        return .failTerminal
      }
      consumedVideoFallbackLineages.insert(lineage)
      videoLineage = lineage
      let current = revisions.decoder?.rawValue ?? 0
      guard current < UInt64.max else { return .failTerminal }
      return .recreateVideoDecoderInSoftware(
        lineage: lineage,
        revision: DecoderRevisionID(rawValue: current + 1)
      )
    }

    if failure.domain == .presentation,
      failure.stage == .flush || failure.stage == .enqueue || failure.stage == .render
    {
      let current = revisions.presentation ?? PresentationRevisionID(rawValue: 0)
      if !presentationFlushConsumed.contains(current) {
        presentationFlushConsumed.insert(current)
        guard current.rawValue < UInt64.max else { return .failTerminal }
        return .flushAndReprimePresentation(
          revision: PresentationRevisionID(rawValue: current.rawValue + 1)
        )
      }
      guard presentationGraphRebuildCount == 0 else { return .failTerminal }
      presentationGraphRebuildCount = 1
      let graph = revisions.presentationGraph?.rawValue ?? 0
      guard graph < UInt64.max else { return .failTerminal }
      return .rebuildPresentationGraph(
        revision: PresentationGraphRevisionID(rawValue: graph + 1)
      )
    }

    return .failTerminal
  }
}
