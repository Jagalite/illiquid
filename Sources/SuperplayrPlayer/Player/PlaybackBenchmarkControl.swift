import Foundation

/// Commands accepted only by the signed benchmark bundle when benchmark
/// overrides are explicitly enabled. Production UI and playback paths never
/// create these values.
public enum PlaybackBenchmarkControlAction: Equatable, Sendable {
    case play
    case pause
    case seekExact(TimeInterval)
    case snapshot

    var diagnosticName: String {
        switch self {
        case .play: "play"
        case .pause: "pause"
        case .seekExact: "seek-exact"
        case .snapshot: "snapshot"
        }
    }
}
