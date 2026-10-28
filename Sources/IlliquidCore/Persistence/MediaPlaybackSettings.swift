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
        var best: MediaTrack?
        var bestScore = 0
        for track in tracks where track.kind == kind {
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
            guard score > 0 else { continue }

            if let current = best {
                if score < bestScore { continue }
                if score == bestScore {
                    // Metadata wins first, then the saved ID, then the lowest
                    // ID. A complete tie keeps the first track, including its
                    // non-ranking fields such as default and forced flags.
                    if let trackID, (current.id == trackID) != (track.id == trackID) {
                        if track.id != trackID { continue }
                    } else if track.id >= current.id {
                        continue
                    }
                }
            }
            best = track
            bestScore = score
        }
        return best
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
