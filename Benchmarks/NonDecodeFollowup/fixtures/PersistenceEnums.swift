// Exact enum declarations extracted from PlaybackModels.swift and
// PlaylistMutation.swift at 854f8365750a0e4f046ab7015e01ca7a138ada40.
// Not mocks; unrelated UI/model declarations are excluded from this harness.
public enum HardwareDecodingPolicy: String, Codable, CaseIterable, Sendable {
    case automatic
    case compatibility
    case off
}

public enum PlaybackRepeatMode: String, Codable, CaseIterable, Sendable {
    case off
    case all
    case one
}
