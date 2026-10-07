import Foundation

/// Filename evidence only: no network requests, directory reads, or guessed catalog matches.
public struct RecognizedMediaName: Equatable, Sendable {
    public enum Kind: String, Sendable { case movie, episode, extra, unknown }
    public let kind: Kind
    public let title: String
    public let year: Int?
    public let season: Int?
    public let episode: Int?
    public let lastEpisode: Int?
    public let airDate: String?
    public let episodeTitle: String?
    public let edition: String?
    public let catalogIDs: [String]
    public let variant: String?
    public var metadataSources: [String] = []

    public var seriesTitle: String {
        title + (year.map { " (\($0))" } ?? "")
    }

    public var displayName: String {
        guard kind == .episode else { return seriesTitle }
        let number = airDate ?? String(format: "S%02dE%02d", season ?? 0, episode ?? 0)
            + (lastEpisode.map { String(format: "–E%02d", $0) } ?? "")
        return number + (episodeTitle.map { " · \($0)" } ?? "")
    }

    public var section: String {
        switch kind {
        case .movie: "Movies"
        case .episode:
            "TV Shows · \(seriesTitle) · " + (season.map { $0 == 0 ? "Specials" : "Season \($0)" } ?? "By date")
        case .extra: "Extras"
        case .unknown: "Other Videos"
        }
    }
}

public enum MediaNameRecognition {
    // Compiled once, then shared by background projections. Explicit boundaries avoid
    // interpreting numbers inside words or resolutions as episode markers.
    private static let episode = regex(#"(?i)(?<![\p{L}\d])s(\d{1,3})[ ._-]*e(\d{1,4})(?:[ ._-]*e(\d{1,4}))?(?!\d)"#)
    private static let alternateEpisode = regex(#"(?i)(?<![\p{L}\d])(\d{1,2})x(\d{1,3})(?!\d)"#)
    private static let seasonFolder = regex(#"(?i)^season[ ._-]*(\d{1,3})$"#)
    private static let explicitYear = regex(#"\(((?:18|19|20)\d{2})\)"#)
    private static let year = regex(#"(?:^|[ ._(\[-])((?:18|19|20)\d{2})(?=$|[ ._)\]-])"#)
    private static let date = regex(#"(?<!\d)((?:19|20)\d{2})[ ._-](\d{2})[ ._-](\d{2})(?!\d)"#)
    private static let reverseDate = regex(#"(?<!\d)(\d{2})[ ._-](\d{2})[ ._-]((?:19|20)\d{2})(?!\d)"#)
    private static let id = regex(#"(?i)\{((?:tmdb|tvdb)-\d+|imdb-tt\d+)\}"#)
    private static let edition = regex(#"(?i)\{edition-([^}]+)\}"#)
    private static let tags = regex(#"\{[^}]*\}|\[[^\]]*\]"#)
    private static let release = regex(#"(?i)(?<![\p{L}\d])(?:2160p|1080[pi]|720p|480p|4k|uhd|blu[ ._-]?ray|b[dr]rip|web[ ._-]?(?:dl|rip)|hdtv|dvdrip|[xh][ ._-]?26[45]|hevc|av1)(?![\p{L}\d])"#)
    private static let part = regex(#"(?i)(?:^|[ ._-])((?:cd|disc|disk|dvd|part|pt)[ ._-]*\d+)(?=$|[ ._-])"#)
    private static let extraSuffix = regex(#"(?i)-(trailer|behindthescenes|deleted|featurette|interview|scene|short|other)$"#)
    private static let extraFolders: Set<String> = [
        "behind the scenes", "deleted scenes", "featurettes", "interviews", "scenes", "shorts", "trailers", "other", "extras"
    ]

    /// Pass a path relative to the source, including its root folder when that root
    /// may itself be a show/movie. Ancestors are only consulted for explicit naming cues.
    public static func recognize(relativePath: String) -> RecognizedMediaName {
        let path = relativePath as NSString
        let raw = (path.lastPathComponent as NSString).deletingPathExtension
        let folders = (path.deletingLastPathComponent as NSString).pathComponents.filter { $0 != "/" && $0 != "." }
        let parent = folders.last ?? ""
        let seasonParent = match(seasonFolder, parent) != nil || parent.lowercased() == "specials"
        let showFolder = seasonParent ? folders.dropLast().last : nil
        let evidence = [raw, showFolder ?? parent].joined(separator: "/")
        let ids = Array(Set(matches(id, evidence).compactMap { capture($0, 1, in: evidence)?.lowercased() })).sorted()
        let editionName = match(edition, evidence).flatMap { capture($0, 1, in: evidence) }
        var variantParts: [String] = []
        if let editionName { variantParts.append(editionName) }
        if let m = match(part, raw), let value = capture(m, 1, in: raw) { variantParts.append(clean(value)) }
        if let m = match(release, raw), let range = Range(m.range, in: raw) {
            variantParts.append(clean(String(raw[range.lowerBound...])))
        }
        let variant = variantParts.isEmpty ? nil : variantParts.joined(separator: " · ")
        func result(_ kind: RecognizedMediaName.Kind, _ title: String, year: Int? = nil,
                    season: Int? = nil, episode: Int? = nil, lastEpisode: Int? = nil,
                    airDate: String? = nil, episodeTitle: String? = nil) -> RecognizedMediaName {
            .init(kind: kind, title: title.isEmpty ? raw : title, year: year, season: season,
                  episode: episode, lastEpisode: lastEpisode, airDate: airDate,
                  episodeTitle: episodeTitle, edition: editionName, catalogIDs: ids, variant: variant)
        }
        // Extras must win over embedded movie years / episode identifiers.
        if let extra = match(extraSuffix, raw) {
            return result(.extra, clean(prefix(raw, before: extra)))
        }
        if extraFolders.contains(parent.lowercased()) { return result(.extra, clean(raw)) }

        if let token = match(episode, raw) ?? match(alternateEpisode, raw),
           let season = capture(token, 1, in: raw).flatMap(Int.init),
           let first = capture(token, 2, in: raw).flatMap(Int.init) {
            let prefixTitle = clean(prefix(raw, before: token))
            let namedParent = titleAndYear(parent).1 != nil ? parent : ""
            var show = titleAndYear(prefixTitle.isEmpty ? (showFolder ?? namedParent) : prefixTitle)
            let folderShow = titleAndYear(showFolder ?? parent)
            if show.1 == nil, show.0.localizedCaseInsensitiveCompare(folderShow.0) == .orderedSame {
                show = folderShow
            }
            // An isolated S01E01 without a show folder remains unclassified.
            if !show.0.isEmpty {
                let last = token.numberOfRanges > 3 ? capture(token, 3, in: raw).flatMap(Int.init) : nil
                let tail = cleanRelease(suffix(raw, after: token))
                return result(.episode, show.0, year: show.1, season: season, episode: first,
                              lastEpisode: last.flatMap { $0 > first ? $0 : nil },
                              episodeTitle: tail.isEmpty ? nil : tail)
            }
        }
        if let token = match(date, raw) ?? match(reverseDate, raw) {
            let parts = (1...3).compactMap { capture(token, $0, in: raw).flatMap(Int.init) }
            let y = parts[0] > 31 ? parts[0] : parts[2]
            let d = parts[0] > 31 ? parts[2] : parts[0]
            let m = parts[1]
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            let components = DateComponents(year: y, month: m, day: d)
            let valid = calendar.date(from: components).map {
                calendar.dateComponents([.year, .month, .day], from: $0) == components
            } ?? false
            let show = titleAndYear(clean(prefix(raw, before: token)))
            if valid, !show.0.isEmpty {
                let tail = cleanRelease(suffix(raw, after: token))
                return result(.episode, show.0, year: show.1,
                              airDate: String(format: "%04d-%02d-%02d", y, m, d),
                              episodeTitle: tail.isEmpty ? nil : tail)
            }
            // Invalid date-like names must not fall through to movie-year detection.
            return result(.unknown, raw)
        }
        let movie = titleAndYear(raw)
        if let year = movie.1, !movie.0.isEmpty, !seasonParent {
            return result(.movie, movie.0, year: year)
        }
        // A matching movie folder can supply the year for a shorter filename.
        // Do not assign arbitrary videos in that folder to the movie.
        let folderMovie = titleAndYear(parent)
        let filenameTitle = cleanRelease(raw)
        let genericMovieNames: Set<String> = ["movie", "video", "feature", "main"]
        if let folderYear = folderMovie.1, !seasonParent,
           filenameTitle.localizedCaseInsensitiveCompare(folderMovie.0) == .orderedSame
            || genericMovieNames.contains(filenameTitle.lowercased()) {
            return result(.movie, folderMovie.0, year: folderYear)
        }
        // Movie IDs on the filename are explicit evidence; a TVDB ID alone
        // does not establish movie identity or an episode number.
        let filenameIDs = matches(id, raw).compactMap { capture($0, 1, in: raw)?.lowercased() }
        if filenameIDs.contains(where: { $0.hasPrefix("imdb-") || $0.hasPrefix("tmdb-") }), !seasonParent {
            return result(.movie, filenameTitle)
        }
        return result(.unknown, raw)
    }

    private static func titleAndYear(_ original: String) -> (String, Int?) {
        // Edition dates and IDs are not release years. Parenthesized years win
        // over incidental numbers; the last year handles numeric movie titles.
        let text = tags.stringByReplacingMatches(in: original,
            range: NSRange(original.startIndex..., in: original), withTemplate: "")
        if let token = matches(explicitYear, text).last ?? matches(year, text).last, let value = capture(token, 1, in: text).flatMap(Int.init) {
            let title = clean(prefix(text, before: token))
            if !title.isEmpty { return (title, value) }
        }
        return (clean(text), nil)
    }

    private static func cleanRelease(_ text: String) -> String {
        clean(match(release, text).map { prefix(text, before: $0) } ?? text)
    }
    private static func clean(_ text: String) -> String {
        let stripped = tags.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        return stripped.replacingOccurrences(of: ".", with: " ").replacingOccurrences(of: "_", with: " ")
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " -()[]"))
    }
    private static func regex(_ pattern: String) -> NSRegularExpression { try! NSRegularExpression(pattern: pattern) }
    private static func matches(_ regex: NSRegularExpression, _ text: String) -> [NSTextCheckingResult] {
        regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
    }
    private static func match(_ regex: NSRegularExpression, _ text: String) -> NSTextCheckingResult? {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
    }
    private static func capture(_ match: NSTextCheckingResult, _ index: Int, in text: String) -> String? {
        Range(match.range(at: index), in: text).map { String(text[$0]) }
    }
    private static func prefix(_ text: String, before match: NSTextCheckingResult) -> String {
        String(text[..<Range(match.range, in: text)!.lowerBound])
    }
    private static func suffix(_ text: String, after match: NSTextCheckingResult) -> String {
        String(text[Range(match.range, in: text)!.upperBound...])
    }
}
