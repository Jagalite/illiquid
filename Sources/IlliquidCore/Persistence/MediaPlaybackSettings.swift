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
        var bestIndex: Int?
        var bestScore = 0
        for index in tracks.indices {
            let track = tracks[index]
            guard track.kind == kind else { continue }
            var score = 0
            if isExternal == track.isExternal { score += 2 }
            if let externalFilename, externalFilename == track.externalFilename {
                score += 16
            }
            if let title, title == track.title { score += 8 }
            if let languageCode, languageCode == track.languageCode { score += 4 }
            if let codec, codec == track.codec { score += 2 }
            guard score > 0 else { continue }
            if let bestIndex {
                if score < bestScore { continue }
                if score == bestScore {
                    let incumbentID = tracks[bestIndex].id
                    // Metadata outranks the saved ID after remuxing. On a
                    // metadata tie, preserve that ID before comparing IDs.
                    if let trackID, (incumbentID == trackID) != (track.id == trackID) {
                        guard track.id == trackID else { continue }
                    } else {
                        // Strict comparison keeps the first complete track
                        // when duplicate IDs have the same score.
                        guard track.id < incumbentID else { continue }
                    }
                }
            }
            bestIndex = index
            bestScore = score
        }
        return bestIndex.map { tracks[$0] }
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
