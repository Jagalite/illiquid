import Foundation

/// Standard series/season hints and explicit episode mappings from .plexmatch.
/// Pattern directives are not interpreted as regular expressions or executed.
public struct PlexMatchHints: Sendable {
    public let metadata: MediaMetadataHints
    // Every mapping supplies only episode identity. Keep unused series metadata
    // fields out of the retained index and materialize a full hint on lookup.
    private struct EpisodeMapping: Sendable {
        let season: Int?
        let episode: Int
        let lastEpisode: Int?
    }
    private let episodes: [String: EpisodeMapping]

    public static func parse(_ text: String) -> Self? {
        guard text.utf8.count <= 128 * 1024 else { return nil }
        var metadata = MediaMetadataHints()
        metadata.content = .show
        var episodes: [String: EpisodeMapping] = [:]
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
        guard inheritsDescendantMappings || !relativePath.contains("/"),
              let episode = episodes[relativePath] else { return nil }
        var hint = MediaMetadataHints()
        hint.content = .episode
        hint.season = episode.season
        hint.episode = episode.episode
        hint.lastEpisode = episode.lastEpisode
        return hint
    }

    private static func validRelativePath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.contains("\\")
            && !path.split(separator: "/").contains(where: { $0 == ".." || $0 == "." })
    }

    // Match the ASCII numeric contract used by the other metadata hints. ICU
    // \d also accepts digits that Int cannot parse; treating those captures as
    // absent would silently change the season, episode, or range of a mapping.
    private static let episodePattern = try! NSRegularExpression(
        pattern: #"(?i)^(?:S([0-9]{1,3})E|SP|E)?([0-9]{1,4})(?:-(?:S([0-9]{1,3})E|E)?([0-9]{1,4}))?$"#)

    private static func episodeNumber(_ text: String) -> EpisodeMapping? {
        // The longest ASCII spelling is S999E9999-S999E9999. Keep ICU's
        // Unicode case folding and end-anchor behavior for all other inputs.
        let parsed = text.utf8.withContiguousStorageIfAvailable { bytes
            -> (handled: Bool, value: EpisodeMapping?) in
            guard bytes.count <= 19,
                  bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7f }) else { return (false, nil) }
            return (true, asciiEpisodeNumber(bytes))
        }
        if let parsed, parsed.handled { return parsed.value }

        guard let match = episodePattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        func number(_ index: Int) -> Int? {
            Range(match.range(at: index), in: text).flatMap { Int(text[$0]) }
        }
        guard let first = number(2) else { return nil }
        let season = text.uppercased().hasPrefix("SP") ? 0 : number(1)
        let lastEpisode = number(4)
        if let endSeason = number(3), endSeason != season { return nil }
        if let lastEpisode, lastEpisode <= first { return nil }
        return EpisodeMapping(season: season, episode: first, lastEpisode: lastEpisode)
    }

    private static func asciiEpisodeNumber(_ bytes: UnsafeBufferPointer<UInt8>) -> EpisodeMapping? {
        var index = 0
        func consume(_ letter: UInt8) -> Bool {
            guard index < bytes.count, (bytes[index] | 0x20) == letter else { return false }
            index += 1
            return true
        }
        func number(maximumDigits: Int) -> Int? {
            let start = index
            var value = 0
            while index < bytes.count {
                let byte = bytes[index]
                guard byte >= 48, byte <= 57 else { break }
                guard index - start < maximumDigits else { return nil }
                value = value * 10 + Int(byte - 48)
                index += 1
            }
            return index > start ? value : nil
        }

        var season: Int?
        if consume(0x73) { // S/s
            if consume(0x70) { // P/p: specials
                season = 0
            } else {
                guard let value = number(maximumDigits: 3), consume(0x65) else { return nil }
                season = value
            }
        } else {
            _ = consume(0x65) // Optional E/e
        }
        guard let first = number(maximumDigits: 4) else { return nil }
        if index == bytes.count {
            return EpisodeMapping(season: season, episode: first, lastEpisode: nil)
        }
        guard bytes[index] == 45 else { return nil } // -
        index += 1
        var endSeason: Int?
        if consume(0x73) {
            guard let value = number(maximumDigits: 3), consume(0x65) else { return nil }
            endSeason = value
        } else {
            _ = consume(0x65)
        }
        guard let last = number(maximumDigits: 4), index == bytes.count, last > first else { return nil }
        if let endSeason, endSeason != season { return nil }
        return EpisodeMapping(season: season, episode: first, lastEpisode: last)
    }
}
