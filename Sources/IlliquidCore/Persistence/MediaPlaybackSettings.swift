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

/// Which choices were explicitly made for this file. Absence means inheritance,
/// not Off or zero. Existing metadata-only records decode with legacy semantics.
public enum MediaPlaybackSetting: String, Codable, CaseIterable, Sendable {
    case audio, subtitles, subtitleDelay, playbackSpeed, audioDelay
}

public struct MediaPlaybackSettings: Codable, Equatable, Sendable {
    public var audioTrack: MediaTrackPreference?
    public var subtitleTrack: MediaTrackPreference?
    public var areSubtitlesVisible: Bool
    public var subtitleDelay: TimeInterval
    public var playbackSpeed: Double?
    public var audioDelay: TimeInterval?
    public var audioLanguage: String?
    public var subtitleLanguage: String?
    public var externalSubtitleURL: URL?
    public var overriddenFields: Set<MediaPlaybackSetting>

    public init(
        audioTrack: MediaTrackPreference? = nil,
        subtitleTrack: MediaTrackPreference? = nil,
        areSubtitlesVisible: Bool = true,
        subtitleDelay: TimeInterval = 0,
        playbackSpeed: Double? = nil,
        audioDelay: TimeInterval? = nil,
        audioLanguage: String? = nil,
        subtitleLanguage: String? = nil,
        externalSubtitleURL: URL? = nil,
        overriddenFields: Set<MediaPlaybackSetting>? = nil
    ) {
        self.audioTrack = audioTrack
        self.subtitleTrack = subtitleTrack
        self.areSubtitlesVisible = areSubtitlesVisible
        self.subtitleDelay = Self.validDelay(subtitleDelay)
        self.playbackSpeed = playbackSpeed.map { Self.validSpeed($0) }
        self.audioDelay = audioDelay.map { Self.validDelay($0) }
        self.audioLanguage = TrackSelectionPreferences.normalizedLanguage(audioLanguage)
        self.subtitleLanguage = TrackSelectionPreferences.normalizedLanguage(subtitleLanguage)
        self.externalSubtitleURL = externalSubtitleURL.flatMap { NormalizedFileURL.normalize($0) }
        var inferred: Set<MediaPlaybackSetting> = []
        if audioTrack != nil || self.audioLanguage != nil { inferred.insert(.audio) }
        if subtitleTrack != nil || !areSubtitlesVisible || self.subtitleLanguage != nil || self.externalSubtitleURL != nil {
            inferred.insert(.subtitles)
        }
        if subtitleDelay != 0 { inferred.insert(.subtitleDelay) }
        if playbackSpeed != nil { inferred.insert(.playbackSpeed) }
        if audioDelay != nil { inferred.insert(.audioDelay) }
        self.overriddenFields = overriddenFields ?? inferred
    }

    public var isEmpty: Bool { overriddenFields.isEmpty }

    public func overrides(_ field: MediaPlaybackSetting) -> Bool {
        overriddenFields.contains(field)
    }

    public mutating func inherit(_ field: MediaPlaybackSetting) {
        overriddenFields.remove(field)
        switch field {
        case .audio: audioTrack = nil; audioLanguage = nil
        case .subtitles:
            subtitleTrack = nil; subtitleLanguage = nil
            areSubtitlesVisible = true; externalSubtitleURL = nil
        case .subtitleDelay: subtitleDelay = 0
        case .playbackSpeed: playbackSpeed = nil
        case .audioDelay: audioDelay = nil
        }
    }

    public func sanitized() -> Self {
        Self(audioTrack: audioTrack, subtitleTrack: subtitleTrack,
             areSubtitlesVisible: areSubtitlesVisible, subtitleDelay: subtitleDelay,
             playbackSpeed: playbackSpeed, audioDelay: audioDelay,
             audioLanguage: audioLanguage, subtitleLanguage: subtitleLanguage,
             externalSubtitleURL: externalSubtitleURL, overriddenFields: overriddenFields)
    }

    public func effectivePlaybackSpeed(default defaultSpeed: Double) -> Double {
        Self.validSpeed(overrides(.playbackSpeed) ? (playbackSpeed ?? defaultSpeed) : defaultSpeed)
    }

    public var effectiveAudioDelay: TimeInterval {
        overrides(.audioDelay) ? Self.validDelay(audioDelay ?? 0) : 0
    }

    private static func validDelay(_ value: Double) -> Double {
        min(max(value.isFinite ? value : 0, -10), 10)
    }

    private static func validSpeed(_ value: Double) -> Double {
        guard value.isFinite, value > 0 else { return 1 }
        return (min(max(value, 0.25), 4) * 1_000).rounded() / 1_000
    }

    private enum CodingKeys: String, CodingKey {
        case audioTrack, subtitleTrack, areSubtitlesVisible, subtitleDelay
        case playbackSpeed, audioDelay, audioLanguage, subtitleLanguage
        case externalSubtitleURL, overriddenFields
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let audio = try values.decodeIfPresent(MediaTrackPreference.self, forKey: .audioTrack)
        // Old records stored subtitle visibility/delay unconditionally. Preserve
        // their meaning rather than silently converting Off to Automatic.
        let fields = try values.decodeIfPresent(Set<MediaPlaybackSetting>.self, forKey: .overriddenFields)
            ?? Set([.subtitles, .subtitleDelay] + (audio == nil ? [] : [.audio]))
        self.init(audioTrack: audio,
            subtitleTrack: try values.decodeIfPresent(MediaTrackPreference.self, forKey: .subtitleTrack),
            areSubtitlesVisible: try values.decodeIfPresent(Bool.self, forKey: .areSubtitlesVisible) ?? true,
            subtitleDelay: try values.decodeIfPresent(Double.self, forKey: .subtitleDelay) ?? 0,
            playbackSpeed: try values.decodeIfPresent(Double.self, forKey: .playbackSpeed),
            audioDelay: try values.decodeIfPresent(Double.self, forKey: .audioDelay),
            audioLanguage: try values.decodeIfPresent(String.self, forKey: .audioLanguage),
            subtitleLanguage: try values.decodeIfPresent(String.self, forKey: .subtitleLanguage),
            externalSubtitleURL: try values.decodeIfPresent(URL.self, forKey: .externalSubtitleURL),
            overriddenFields: fields)
    }
}
