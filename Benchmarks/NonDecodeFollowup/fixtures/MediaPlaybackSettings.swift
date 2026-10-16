import Foundation

public struct MediaTrackPreference: Codable, Equatable, Sendable {
    public let kind: MediaTrackKind
    /// A same-file tie-breaker, not a stable identity after remuxing/renumbering.
    /// Optional so preferences saved by older releases still decode.
    public let trackID: Int64?
    public let title: String?
    public let languageCode: String?
    public let codec: String?
    public let isExternal: Bool
    public let externalFilename: String?

    public init(track: MediaTrack) {
        kind = track.kind
        trackID = track.id
        title = track.title
        languageCode = track.languageCode
        codec = track.codec
        isExternal = track.isExternal
        externalFilename = track.externalFilename
    }

    public func bestMatch(in tracks: [MediaTrack]) -> MediaTrack? {
        tracks
            .filter { $0.kind == kind }
            .map { track in
                var score = 0
                if isExternal == track.isExternal { score += 2 }
                if let externalFilename,
                   externalFilename == track.externalFilename
                {
                    score += 16
                }
                if let title, title == track.title { score += 8 }
                if let languageCode, languageCode == track.languageCode { score += 4 }
                if let codec, codec == track.codec { score += 2 }
                return (track, score)
            }
            .filter { $0.1 > 0 }
            .max { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
                // Distinctive metadata still wins when stream IDs change.
                // For otherwise indistinguishable tracks, preserve the saved ID
                // instead of always selecting the lowest ID.
                if let trackID, (lhs.0.id == trackID) != (rhs.0.id == trackID) {
                    return rhs.0.id == trackID
                }
                return lhs.0.id > rhs.0.id
            }?
            .0
    }
}

public struct MediaPlaybackSettings: Codable, Equatable, Sendable {
    public var audioTrack: MediaTrackPreference?
    public var subtitleTrack: MediaTrackPreference?
    public var areSubtitlesVisible: Bool
    public var subtitleDelay: TimeInterval

    public init(
        audioTrack: MediaTrackPreference? = nil,
        subtitleTrack: MediaTrackPreference? = nil,
        areSubtitlesVisible: Bool = true,
        subtitleDelay: TimeInterval = 0
    ) {
        self.audioTrack = audioTrack
        self.subtitleTrack = subtitleTrack
        self.areSubtitlesVisible = areSubtitlesVisible
        self.subtitleDelay = min(max(
            subtitleDelay.isFinite ? subtitleDelay : 0,
            -10
        ), 10)
    }
}
