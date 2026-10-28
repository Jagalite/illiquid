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
        // A lone eligible track needs no ranking, including language normalization.
        guard eligible.count > 1 else { return eligible.first?.track.id }
        func rank(_ candidate: TrackSelectionCandidate) -> Int {
            let languageRank = languages.isEmpty ? 0 : languages.firstIndex(of:
                Self.normalizedLanguage(candidate.track.languageCode) ?? "")
                .map { languages.count - $0 } ?? 0
            // Six Boolean priorities fit below the language rank. Each bit
            // outweighs every lower priority, preserving lexicographic order
            // without allocating a rank array for each eligible track.
            // Sanitization bounds languageRank to 0...32 (the full rank is <= 2_111).
            var value = languageRank << 6
            if !preferences.avoidsCommentary || !candidate.isCommentary {
                value |= 1 << 5
            }
            if candidate.isAccessible == preferences.prefersAccessibleTracks {
                value |= 1 << 4
            }
            if kind == .subtitle && preferences.subtitles == .forcedOnly && candidate.track.isForced {
                value |= 1 << 3
            }
            if candidate.track.isDefault { value |= 1 << 2 }
            if kind == .subtitle && candidate.track.isForced { value |= 1 << 1 }
            if candidate.track.id == fallbackID { value |= 1 }
            return value
        }
        // Retain the incumbent's rank instead of normalizing it again for every comparison.
        var best = eligible[0]
        var bestRank = rank(best)
        for candidate in eligible.dropFirst() {
            let candidateRank = rank(candidate)
            if bestRank == candidateRank ? best.track.id > candidate.track.id
                : bestRank < candidateRank {
                best = candidate
                bestRank = candidateRank
            }
        }
        return best.track.id
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
