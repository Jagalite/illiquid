import Foundation

/// Standard series/season hints and explicit episode mappings from .plexmatch.
/// Pattern directives are not interpreted as regular expressions or executed.
public struct PlexMatchHints: Sendable {
    public let metadata: MediaMetadataHints
    private let episodes: [String: MediaMetadataHints]

    public static func parse(_ text: String) -> Self? {
        guard text.utf8.count <= 128 * 1024 else { return nil }
        var metadata = MediaMetadataHints()
        metadata.content = .show
        var episodes: [String: MediaMetadataHints] = [:]
        var hasSupportedHint = false
        for line in text.trimmingCharacters(in: CharacterSet(charactersIn: "\u{feff}")).split(whereSeparator: \.isNewline) {
            let line = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.hasPrefix("#"), let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty, value.count <= 4096 else { continue }
            switch key {
            case "title", "show": metadata.title = value; hasSupportedHint = true
            case "year":
                if let number = MediaMetadataHints.number(value), (1800...2099).contains(number) {
                    metadata.year = number; hasSupportedHint = true
                }
            case "season":
                if let number = MediaMetadataHints.number(value, maximum: 999) {
                    metadata.season = number; hasSupportedHint = true
                }
            case "tvdbid", "tmdbid", "imdbid":
                if let id = MediaMetadataHints.catalogID(provider: String(key.dropLast(2)), value: value) {
                    metadata.catalogIDs.append(id); hasSupportedHint = true
                }
            case "guid":
                let parts = value.components(separatedBy: "://")
                if parts.count == 2, let id = MediaMetadataHints.catalogID(provider: parts[0], value: parts[1]) {
                    metadata.catalogIDs.append(id); hasSupportedHint = true
                }
            case "ep", "episode":
                guard let separator = value.firstIndex(of: ":"),
                      let hint = episodeNumber(String(value[..<separator])) else { continue }
                let path = value[value.index(after: separator)...].trimmingCharacters(in: .whitespaces)
                guard validRelativePath(path) else { continue }
                episodes[path] = hint; hasSupportedHint = true
            default: continue
            }
        }
        guard hasSupportedHint else { return nil }
        metadata.sources = [".plexmatch"]
        return .init(metadata: metadata, episodes: episodes)
    }

    public func hints(for relativePath: String, inheritsDescendantMappings: Bool = true, defaultSeason: Int? = nil) -> MediaMetadataHints {
        guard let episode = episodeHint(for: relativePath, inheritsDescendantMappings: inheritsDescendantMappings) else { return metadata }
        var result = episode.overriding(metadata)
        result.season = result.season ?? defaultSeason ?? 1
        return result
    }

    func episodeHint(for relativePath: String, inheritsDescendantMappings: Bool) -> MediaMetadataHints? {
        guard inheritsDescendantMappings || !relativePath.contains("/") else { return nil }
        return episodes[relativePath]
    }

    private static func validRelativePath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.contains("\\")
            && !path.split(separator: "/").contains(where: { $0 == ".." || $0 == "." })
    }

    private static let episodePattern = try! NSRegularExpression(
        pattern: #"(?i)^(?:S(\d{1,3})E|SP|E)?(\d{1,4})(?:-(?:S(\d{1,3})E|E)?(\d{1,4}))?$"#)

    private static func episodeNumber(_ text: String) -> MediaMetadataHints? {
        guard let match = episodePattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        func number(_ index: Int) -> Int? {
            Range(match.range(at: index), in: text).flatMap { Int(text[$0]) }
        }
        var hint = MediaMetadataHints()
        hint.content = .episode
        hint.season = text.uppercased().hasPrefix("SP") ? 0 : number(1)
        hint.episode = number(2)
        hint.lastEpisode = number(4)
        if let endSeason = number(3), endSeason != hint.season { return nil }
        if let last = hint.lastEpisode, last <= (hint.episode ?? 0) { return nil }
        return hint
    }
}
