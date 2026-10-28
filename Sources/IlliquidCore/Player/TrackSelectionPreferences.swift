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
        let languages = kind == .audio ? preferences.audioLanguages : preferences.subtitleLanguages
        let requiresForced = kind == .subtitle && preferences.subtitles == .forcedOnly
        let forcedLanguages: [String]
        if requiresForced {
            forcedLanguages = languages.isEmpty
                ? Self.normalizedLanguage(audioLanguage).map { [$0] } ?? [] : languages
        } else {
            forcedLanguages = []
        }
        // Visit eligible tracks in input order without materializing a catalog
        // copy. Forced-language normalization still runs once per tested track.
        let eligible = candidates.lazy.filter { candidate in
            guard candidate.track.kind == kind else { return false }
            return !requiresForced || (
                (candidate.track.isForced || candidate.canFilterForcedEvents)
                    && (forcedLanguages.isEmpty || forcedLanguages.contains(
                        Self.normalizedLanguage(candidate.track.languageCode) ?? ""
                    ))
            )
        }
        // With no language policy, Automatic retains the demuxer's subtitle
        // choice. Forced-only and Always have explicit, different semantics.
        if kind == .subtitle, preferences.subtitles == .automatic, languages.isEmpty,
           !preferences.prefersAccessibleTracks {
            return eligible.first { $0.track.id == fallbackID }?.track.id
        }
        // A lone eligible track needs no ranking, including language normalization.
        var iterator = eligible.makeIterator()
        guard let first = iterator.next() else { return nil }
        guard let second = iterator.next() else { return first.track.id }
        func rank(_ candidate: TrackSelectionCandidate) -> [Int] {
            let languageRank = languages.isEmpty ? 0 : languages.firstIndex(of:
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
        // Retain the incumbent's rank instead of normalizing it again for every comparison.
        var best = first
        var bestRank = rank(best)
        var next: TrackSelectionCandidate? = second
        while let candidate = next {
            let candidateRank = rank(candidate)
            if bestRank == candidateRank ? best.track.id > candidate.track.id
                : bestRank.lexicographicallyPrecedes(candidateRank) {
                best = candidate
                bestRank = candidateRank
            }
            next = iterator.next()
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
