// Exact declarations from PlaylistMutation.swift and VideoPresentationGeometry.swift
// at 854f8365750a0e4f046ab7015e01ca7a138ada40; unrelated methods are not compiled.
public enum PlaybackRepeatMode: String, Codable, CaseIterable, Sendable {
    case off
    case all
    case one
}

public enum VideoScaleMode: String, Codable, CaseIterable, Sendable {
    case fit, fill
}
