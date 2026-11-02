import Foundation
import Statelessness

/// Versioned lossless codec for the production model (canonical JSON: sorted
/// keys, sorted unordered collections, NFC strings, normalized zero).
public enum PlaybackProductionCodec {
  public static var codec: Codec<PlaybackDomainState, PlaybackEventEnvelope, PlaybackTransition> {
    Codec(
      metadata: { PlaybackProductionModel.metadata },
      encodeState: { try CanonicalJSON.encode($0) },
      decodeState: { try CanonicalJSON.decode(PlaybackDomainState.self, from: $0) },
      encodeInput: { try CanonicalJSON.encode($0) },
      decodeInput: { try CanonicalJSON.decode(PlaybackEventEnvelope.self, from: $0) },
      encodeOutput: { try CanonicalJSON.encode($0) })
  }
}
