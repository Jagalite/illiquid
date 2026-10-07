public struct PlaybackTrackCandidate: Codable, Equatable, Sendable {
  public let id: PlaybackTrackID
  public let isDefault: Bool
  public let isForced: Bool

  public init(id: PlaybackTrackID, isDefault: Bool, isForced: Bool = false) {
    self.id = id
    self.isDefault = isDefault
    self.isForced = isForced
  }
}

public struct PlaybackCatalog: Codable, Equatable, Sendable {
  public let hasVideo: Bool
  public let audio: [PlaybackTrackCandidate]
  public let subtitles: [PlaybackTrackCandidate]

  public init(
    hasVideo: Bool = false,
    audio: [PlaybackTrackCandidate] = [],
    subtitles: [PlaybackTrackCandidate] = []
  ) {
    self.hasVideo = hasVideo
    self.audio = audio
    self.subtitles = subtitles
  }
}

public struct InitialTrackSelectionState: Codable, Equatable, Sendable {
  public var audio: PlaybackTrackID?
  public var subtitle: PlaybackTrackID?

  public init(audio: PlaybackTrackID? = nil, subtitle: PlaybackTrackID? = nil) {
    self.audio = audio
    self.subtitle = subtitle
  }
}

public enum LoadingTransactionPhase: String, Codable, Equatable, Sendable {
  case opening
  case probing
  case configuring
  case prerolling
  case settled
}

public struct LoadingTransactionState: Codable, Equatable, Sendable {
  public var phase: LoadingTransactionPhase
  public var catalog: PlaybackCatalog?
  public var initialSelection: InitialTrackSelectionState

  public init(
    phase: LoadingTransactionPhase = .opening,
    catalog: PlaybackCatalog? = nil,
    initialSelection: InitialTrackSelectionState = InitialTrackSelectionState()
  ) {
    self.phase = phase
    self.catalog = catalog
    self.initialSelection = initialSelection
  }
}

public enum PlaybackDrainComponent: String, Codable, Hashable, Sendable {
  case videoDecoder
  case videoSubmission
  case videoPresenter
  case audioDecoder
  case audioConverter
  case audioSubmission
  case audioPresenter
}

extension PlaybackDrainComponent {
  public static let allCompatibilityComponents: [PlaybackDrainComponent] = [
    .videoDecoder, .videoSubmission, .videoPresenter,
    .audioDecoder, .audioConverter, .audioSubmission, .audioPresenter,
  ]
}

public struct PlaybackDrainState: Codable, Equatable, Sendable {
  public var required: Set<PlaybackDrainComponent>
  public var observed: Set<PlaybackDrainComponent>
  public var finalized: Bool

  public init(
    required: Set<PlaybackDrainComponent> = [],
    observed: Set<PlaybackDrainComponent> = [],
    finalized: Bool = false
  ) {
    self.required = required
    self.observed = observed
    self.finalized = finalized
  }
}

func selectInitialTracks(from catalog: PlaybackCatalog) -> InitialTrackSelectionState {
  let audio = catalog.audio.first(where: \.isDefault)?.id ?? catalog.audio.first?.id
  let subtitle = catalog.subtitles.first(where: { $0.isForced })?.id
    ?? catalog.subtitles.first(where: \.isDefault)?.id
  return InitialTrackSelectionState(audio: audio, subtitle: subtitle)
}
