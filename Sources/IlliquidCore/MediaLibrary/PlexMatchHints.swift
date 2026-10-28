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
        var contiguous = text
        return contiguous.withUTF8 { bytes in
            if bytes.count <= 19, bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7f }) {
                return asciiEpisodeNumber(bytes)
            }
            // Valid ASCII directives fit in 19 bytes. Preserve ICU's case folding
            // and anchor behavior for non-ASCII, controls and unusual inputs.
            return regexEpisodeNumber(text)
        }
    }

    private static func asciiEpisodeNumber(_ bytes: UnsafeBufferPointer<UInt8>) -> EpisodeMapping? {
        let end = bytes.count
        guard end > 0 else { return nil }
        var offset = 0

        func isLetter(_ lowercase: UInt8) -> Bool {
            offset < end && bytes[offset] | 0x20 == lowercase
        }

        func number(maximumDigits: Int) -> Int? {
            let start = offset
            var value = 0
            while offset < end, offset - start < maximumDigits,
                  bytes[offset] >= 48, bytes[offset] <= 57 {
                value = value * 10 + Int(bytes[offset] - 48)
                offset += 1
            }
            return offset == start ? nil : value
        }

        var season: Int?
        if isLetter(0x73) { // S
            offset += 1
            if isLetter(0x70) { // SP
                season = 0
                offset += 1
            } else {
                guard let value = number(maximumDigits: 3), isLetter(0x65) else { return nil }
                season = value
                offset += 1
            }
        } else if isLetter(0x65) { // E
            offset += 1
        }
        guard let first = number(maximumDigits: 4) else { return nil }
        if offset == end {
            return EpisodeMapping(season: season, episode: first, lastEpisode: nil)
        }
        guard bytes[offset] == 0x2D else { return nil } // -
        offset += 1
        if isLetter(0x73) {
            offset += 1
            guard let endSeason = number(maximumDigits: 3), endSeason == season,
                  isLetter(0x65) else { return nil }
            offset += 1
        } else if isLetter(0x65) {
            offset += 1
        }
        guard let last = number(maximumDigits: 4), offset == end, last > first else { return nil }
        return EpisodeMapping(season: season, episode: first, lastEpisode: last)
    }

    private static func regexEpisodeNumber(_ text: String) -> EpisodeMapping? {
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
}
