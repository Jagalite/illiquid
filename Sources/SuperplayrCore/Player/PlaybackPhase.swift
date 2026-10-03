/// The authoritative lifecycle of a playback session.
///
/// UI conveniences such as `isPaused` and `isLoading` are derived from this
/// value so contradictory combinations cannot be represented.
public enum PlaybackPhase: String, Codable, CaseIterable, Sendable {
    case idle
    case preparing
    case loading
    case playing
    case paused
    case buffering
    case stopping
    case failed
    case shuttingDown

    public var isLoading: Bool {
        switch self {
        case .preparing, .loading, .buffering:
            true
        case .idle, .playing, .paused, .stopping, .failed, .shuttingDown:
            false
        }
    }

    public var isPaused: Bool {
        switch self {
        case .idle, .paused, .stopping, .failed, .shuttingDown:
            true
        case .preparing, .loading, .playing, .buffering:
            false
        }
    }
}
