import Foundation

/// Explicit local metadata. Missing values do not erase filename evidence.
public struct MediaMetadataHints: Equatable, Sendable {
    public enum Content: Sendable { case movie, show, episode }
    public var content: Content?
    public var title: String?
    public var year: Int?
    public var season: Int?
    public var episode: Int?
    public var lastEpisode: Int?
    public var episodeTitle: String?
    public var catalogIDs: [String] = []
    public var sources: [String] = []

    public init() {}

    public func overriding(_ previous: Self) -> Self {
        var older = previous
        if content == .movie && older.content != .movie
            || content != nil && content != .movie && older.content == .movie {
            older = Self()
        }
        var result = self
        result.content = content ?? older.content
        result.title = title ?? older.title
        result.year = year ?? older.year
        result.season = season ?? older.season
        result.episode = episode ?? older.episode
        // An explicit new episode replaces a previous range, rather than inheriting it.
        result.lastEpisode = episode == nil ? older.lastEpisode : lastEpisode
        result.episodeTitle = episodeTitle ?? older.episodeTitle
        let replacedProviders = Set(catalogIDs.compactMap { $0.split(separator: "-").first })
        result.catalogIDs = older.catalogIDs.filter { !replacedProviders.contains($0.split(separator: "-").first ?? "") } + catalogIDs
        result.sources = Array(Set(older.sources + sources)).sorted()
        return result
    }

    static func number(_ value: String, maximum: Int = 9999) -> Int? {
        guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }),
              let number = Int(value), number <= maximum else { return nil }
        return number
    }

    static func catalogID(provider: String, value: String) -> String? {
        let provider = provider.lowercased()
        var value = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard ["imdb", "tmdb", "tvdb"].contains(provider) else { return nil }
        if provider == "imdb", value.hasPrefix("tt") { value.removeFirst(2) }
        guard !value.isEmpty, value.count <= 20, value.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return provider + "-" + (provider == "imdb" ? "tt" : "") + value
    }
}

extension RecognizedMediaName {
    public func applying(_ hints: MediaMetadataHints) -> Self {
        // Folder metadata must not turn trailers into episodes or movies.
        guard kind != .extra else { return self }
        let resolvedTitle = hints.title ?? title
        let resolvedEpisode = hints.episode ?? episode
        let resolvedSeason = hints.season ?? season
        let resolvedKind: Kind
        switch hints.content {
        case .movie: resolvedKind = .movie
        case .show, .episode:
            resolvedKind = resolvedEpisode != nil || airDate != nil ? .episode : kind
        case nil: resolvedKind = kind
        }
        // A show title without an episode number cannot identify a movie/file.
        guard hints.content != .show || resolvedKind == .episode else { return self }
        let ids = hints.catalogIDs.isEmpty ? catalogIDs : hints.catalogIDs
        return .init(kind: resolvedKind, title: resolvedTitle,
            year: hints.year ?? year, season: resolvedKind == .episode ? (resolvedSeason ?? (airDate == nil ? 1 : nil)) : nil,
            episode: resolvedKind == .episode ? resolvedEpisode : nil,
            lastEpisode: resolvedKind == .episode ? (hints.episode == nil ? lastEpisode : hints.lastEpisode) : nil,
            airDate: resolvedKind == .episode && hints.episode == nil ? airDate : nil,
            episodeTitle: resolvedKind == .episode ? (hints.episodeTitle ?? episodeTitle) : nil, edition: edition,
            catalogIDs: ids, variant: variant, metadataSources: hints.sources)
    }
}
