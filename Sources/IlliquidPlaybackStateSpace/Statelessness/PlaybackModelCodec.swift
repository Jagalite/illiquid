import IlliquidPlaybackModel
import Statelessness

/// Versioned, lossless, deterministic encodings for playback model evidence.
///
/// State encodes the complete executable `PlaybackSearchNode`: core state,
/// pending effects, environment, retained late results, ghost obligations and
/// sequence data. The lossy search key is never used as a decoder. Inputs and
/// observations use the same canonical JSON. Bump `codecVersion` for any
/// change to these encodings, and the model version for semantic changes.
public enum PlaybackModelCodec {
  public static let codecVersion: UInt32 = 1
  /// Property set version: production invariants plus the two model
  /// properties `playlistAdvancesAtMostOncePerEOFCycle` and
  /// `staleResultChangedSemanticState` recorded by the transition adapter.
  public static let propertiesVersion: UInt32 = 1

  struct StateRecord: Codable {
    let model: PlaybackSearchModel
    let seedProfile: String
    let coreState: PlaybackDomainState
    let environment: PlaybackModelEnvironment
    let lateResults: [RetainedEffectResult]
    let ghost: PlaybackSearchGhost
    let nextSequence: UInt64
    let depth: Int
  }

  public static func encodeState(_ state: PlaybackModelState) throws -> [UInt8] {
    let node = state.node
    return try CanonicalJSON.encode(
      StateRecord(
        model: node.model, seedProfile: node.seedProfile, coreState: node.coreState,
        environment: node.environment, lateResults: node.lateResults, ghost: node.ghost,
        nextSequence: node.nextSequence, depth: node.depth))
  }

  public static func decodeState(_ bytes: [UInt8]) throws -> PlaybackModelState {
    let record = try CanonicalJSON.decode(StateRecord.self, from: bytes)
    return PlaybackModelState(
      node: PlaybackSearchNode(
        model: record.model, seedProfile: record.seedProfile, coreState: record.coreState,
        environment: record.environment, lateResults: record.lateResults, ghost: record.ghost,
        nextSequence: record.nextSequence, depth: record.depth))
  }

  public static func encodeInput(_ action: SearchAction) throws -> [UInt8] {
    try CanonicalJSON.encode(action)
  }

  public static func decodeInput(_ bytes: [UInt8]) throws -> SearchAction {
    try CanonicalJSON.decode(SearchAction.self, from: bytes)
  }

  public static func encodeOutput(_ observation: PlaybackModelObservation) throws -> [UInt8] {
    try CanonicalJSON.encode(observation)
  }

  public static func decodeOutput(_ bytes: [UInt8]) throws -> PlaybackModelObservation {
    try CanonicalJSON.decode(PlaybackModelObservation.self, from: bytes)
  }

  /// Model identity: family, model version and property set. Test oracles are
  /// properties, so a non-production oracle is part of the name.
  public static func metadata(
    model: PlaybackSearchModel, oracle: PlaybackSearchOracle
  ) -> Metadata {
    let name: String =
      switch oracle {
      case .production: "illiquid.playback.\(model.rawValue)"
      case .failOnActionClass(let actionClass, let invariant):
        "illiquid.playback.\(model.rawValue)+oracle:\(actionClass)=\(invariant)"
      }
    return Metadata(
      name: name, modelVersion: PlaybackSearchModelDefinition(model: model).modelVersion,
      propertiesVersion: propertiesVersion, codecVersion: codecVersion,
      build: "illiquid-playback-state-space")
  }

  public static func codec(
    model: PlaybackSearchModel, oracle: PlaybackSearchOracle
  ) -> Codec<PlaybackModelState, SearchAction, PlaybackModelObservation> {
    let identity = metadata(model: model, oracle: oracle)
    return Codec(
      metadata: { identity },
      encodeState: encodeState, decodeState: decodeState,
      encodeInput: encodeInput, decodeInput: decodeInput,
      encodeOutput: encodeOutput)
  }
}
