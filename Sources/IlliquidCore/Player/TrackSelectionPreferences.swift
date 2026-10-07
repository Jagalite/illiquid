import Foundation

public enum AutomaticSubtitleSelection: String, Codable, CaseIterable, Sendable {
    case automatic, forcedOnly, always, off

    public var title: String {
        switch self {
        case .automatic: "Automatic"
        case .forcedOnly: "Forced only"
        case .always: "Always when available"
        case .off: "Off"
        }
    }
}

/// Global defaults apply when opening media. Explicit per-file choices are
/// restored by the product coordinator after the catalog is acknowledged.
public struct TrackSelectionPreferences: Codable, Equatable, Sendable {
    public var audioLanguages: [String]
    public var subtitleLanguages: [String]
    public var subtitles: AutomaticSubtitleSelection
    public var prefersAccessibleTracks: Bool
    public var avoidsCommentary: Bool

    public init(audioLanguages: [String] = [], subtitleLanguages: [String] = [],
                subtitles: AutomaticSubtitleSelection = .automatic,
                prefersAccessibleTracks: Bool = false, avoidsCommentary: Bool = true) {
        self.audioLanguages = Self.normalizedLanguages(audioLanguages)
        self.subtitleLanguages = Self.normalizedLanguages(subtitleLanguages)
        self.subtitles = subtitles
        self.prefersAccessibleTracks = prefersAccessibleTracks
        self.avoidsCommentary = avoidsCommentary
    }

    public func sanitized() -> Self {
        Self(audioLanguages: audioLanguages, subtitleLanguages: subtitleLanguages,
             subtitles: subtitles, prefersAccessibleTracks: prefersAccessibleTracks,
             avoidsCommentary: avoidsCommentary)
    }

    public static func normalizedLanguage(_ value: String?) -> String? {
        guard let value else { return nil }
        let raw = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !raw.isEmpty, raw.count <= 35 else { return nil }
        let language = Locale.Language(identifier: raw).languageCode
        guard let language, language.isISOLanguage,
              language != .unidentified, language != .multiple, language != .uncoded
        else { return nil }
        return language.identifier(.alpha2) ?? language.identifier(.alpha3)
    }

    private static func normalizedLanguages(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.prefix(32).compactMap(normalizedLanguage).filter { seen.insert($0).inserted }
    }

    public func select(in candidates: [TrackSelectionCandidate], kind: MediaTrackKind,
                       fallbackID: Int64?, audioLanguage: String? = nil) -> Int64? {
        let preferences = sanitized()
        if kind == .subtitle, preferences.subtitles == .off { return nil }
        var eligible = candidates.filter { $0.track.kind == kind }
        let languages = kind == .audio ? preferences.audioLanguages : preferences.subtitleLanguages
        if kind == .subtitle, preferences.subtitles == .forcedOnly {
            let forcedLanguages = languages.isEmpty
                ? Self.normalizedLanguage(audioLanguage).map { [$0] } ?? [] : languages
            eligible = eligible.filter {
                ($0.track.isForced || $0.canFilterForcedEvents) && (forcedLanguages.isEmpty || forcedLanguages.contains(
                    Self.normalizedLanguage($0.track.languageCode) ?? ""
                ))
            }
        }
        // With no language policy, Automatic retains the demuxer's subtitle
        // choice. Forced-only and Always have explicit, different semantics.
        if kind == .subtitle, preferences.subtitles == .automatic, languages.isEmpty,
           !preferences.prefersAccessibleTracks {
            return eligible.first { $0.track.id == fallbackID }?.track.id
        }
        func rank(_ candidate: TrackSelectionCandidate) -> [Int] {
            let languageRank = languages.firstIndex(of:
                Self.normalizedLanguage(candidate.track.languageCode) ?? "")
                .map { languages.count - $0 } ?? 0
            return [languageRank,
                    preferences.avoidsCommentary && candidate.isCommentary ? 0 : 1,
                    candidate.isAccessible == preferences.prefersAccessibleTracks ? 1 : 0,
                    kind == .subtitle && preferences.subtitles == .forcedOnly && candidate.track.isForced ? 1 : 0,
                    candidate.track.isDefault ? 1 : 0,
                    kind == .subtitle && candidate.track.isForced ? 1 : 0,
                    candidate.track.id == fallbackID ? 1 : 0]
        }
        return eligible.max {
            let left = rank($0), right = rank($1)
            return left == right ? $0.track.id > $1.track.id : left.lexicographicallyPrecedes(right)
        }?.track.id
    }
}

public struct TrackSelectionCandidate: Sendable {
    public let track: MediaTrack
    public let isCommentary: Bool
    public let isAccessible: Bool
    public let canFilterForcedEvents: Bool

    public init(track: MediaTrack, isCommentary: Bool = false, isAccessible: Bool = false,
                canFilterForcedEvents: Bool = false) {
        self.track = track
        self.isCommentary = isCommentary
        self.isAccessible = isAccessible
        self.canFilterForcedEvents = canFilterForcedEvents
    }
}
