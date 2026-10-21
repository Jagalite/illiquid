import Foundation

/// Associates supported external subtitle files with the most closely related media
/// filename in a folder.
public enum ExternalSubtitleMatcher {
    /// Returns subtitle associations keyed by the original media URLs.
    /// Returns an empty dictionary if cancellation is observed; partial
    /// associations are never published after observing cancellation.
    ///
    /// A subtitle is left unassigned if two media files are equally good matches.
    /// This prevents a generic filename such as `Show.srt` from being loaded for
    /// every episode in a folder.
    public static func associate(
        subtitleURLs: [URL],
        with mediaURLs: [URL],
        isCancelled: () -> Bool = { Task.isCancelled }
    ) -> [URL: [URL]] {
        guard !isCancelled() else { return [:] }
        var result: [URL: [URL]] = [:]
        for mediaURL in mediaURLs {
            guard !isCancelled() else { return [:] }
            result[mediaURL] = []
        }

        // Preserve every input key and the final cancellation poll without
        // building a media-name index when there are no subtitle candidates.
        if subtitleURLs.isEmpty {
            return isCancelled() ? [:] : result
        }

        let index = TokenIndex()
        var media: [(url: URL, raw: [String], tokens: [String])] = []
        for url in result.keys where MediaFileSupport.isSupportedMediaFile(url) {
            guard !isCancelled() else { return [:] }
            let raw = filenameTokens(url)
            let tokens = removingTrailingMediaQualifiers(from: raw)
            guard !tokens.isEmpty else { continue }
            index.insert(tokens, index: media.count)
            media.append((url, raw, tokens))
        }
        for subtitleURL in subtitleURLs {
            guard !isCancelled() else { return [:] }
            guard MediaFileSupport.isSupportedSubtitleFile(subtitleURL) else { continue }
            let raw = filenameTokens(subtitleURL)
            let tokens = removingTrailingSubtitleQualifiers(from: raw)
            var best: (index: Int, score: Int)?
            var tied = false
            guard let candidates = index.candidates(for: tokens, isCancelled: isCancelled) else {
                return [:]
            }
            for candidate in candidates {
                guard !isCancelled() else { return [:] }
                let item = media[candidate]
                guard let score = matchScore(
                    rawMediaTokens: item.raw, mediaTokens: item.tokens,
                    rawSubtitleTokens: raw, subtitleTokens: tokens
                ) else { continue }
                if best == nil || score > best!.score {
                    best = (candidate, score)
                    tied = false
                } else if score == best!.score {
                    tied = true
                }
            }
            if let best, !tied {
                result[media[best.index].url, default: []].append(subtitleURL)
            }
        }

        // Value-only mutation preserves indices. A standalone cursor avoids
        // retaining the dictionary through an indices view while sorting.
        var resultIndex = result.startIndex
        while resultIndex != result.endIndex {
            guard !isCancelled() else { return [:] }
            if result.values[resultIndex].count > 1 {
                result.values[resultIndex] = NaturalFilenameOrdering.sort(result.values[resultIndex])
            }
            result.formIndex(after: &resultIndex)
        }

        guard !isCancelled() else { return [:] }
        return result
    }

    /// Only prefix-related normalized names can match. Keep both ancestors and
    /// descendants so fuzzy scores and ambiguous matches retain their semantics.
    private final class TokenIndex {
        var children: [String: TokenIndex] = [:]
        var terminal: [Int] = []

        func insert(_ tokens: [String], index: Int) {
            var node = self
            for token in tokens {
                if node.children[token] == nil { node.children[token] = TokenIndex() }
                node = node.children[token]!
            }
            node.terminal.append(index)
        }

        // nil distinguishes an interrupted traversal from a completed lookup
        // with no candidates, so the caller can discard all earlier matches.
        func candidates(for tokens: [String], isCancelled: () -> Bool) -> [Int]? {
            guard !tokens.isEmpty else { return [] }
            var result: [Int] = []
            var node = self
            for token in tokens {
                guard !isCancelled() else { return nil }
                result.append(contentsOf: node.terminal)
                guard let child = node.children[token] else { return result }
                node = child
            }
            var pending = [node]
            while let current = pending.popLast() {
                guard !isCancelled() else { return nil }
                result.append(contentsOf: current.terminal)
                pending.append(contentsOf: current.children.values)
            }
            return result
        }
    }

    public static func matchingSubtitles(
        for mediaURL: URL,
        among subtitleURLs: [URL]
    ) -> [URL] {
        associate(subtitleURLs: subtitleURLs, with: [mediaURL])[mediaURL, default: []]
    }

    static func matchScore(subtitleURL: URL, mediaURL: URL) -> Int? {
        guard MediaFileSupport.isSupportedSubtitleFile(subtitleURL),
              MediaFileSupport.isSupportedMediaFile(mediaURL)
        else {
            return nil
        }

        let rawMediaTokens = filenameTokens(mediaURL)
        let rawSubtitleTokens = filenameTokens(subtitleURL)
        guard !rawMediaTokens.isEmpty, !rawSubtitleTokens.isEmpty else {
            return nil
        }

        let mediaTokens = removingTrailingMediaQualifiers(from: rawMediaTokens)
        let subtitleTokens = removingTrailingSubtitleQualifiers(from: rawSubtitleTokens)

        return matchScore(
            rawMediaTokens: rawMediaTokens, mediaTokens: mediaTokens,
            rawSubtitleTokens: rawSubtitleTokens, subtitleTokens: subtitleTokens
        )
    }

    private static func matchScore(
        rawMediaTokens: [String], mediaTokens: [String],
        rawSubtitleTokens: [String], subtitleTokens: [String]
    ) -> Int? {
        guard !mediaTokens.isEmpty, !subtitleTokens.isEmpty else { return nil }

        // A language code may also be part of a title, e.g. "The Last of Us".
        // Rank full media stems before treating suffixes as language qualifiers.
        if hasOnlySubtitleQualifiers(after: rawMediaTokens, in: rawSubtitleTokens) {
            return 10_000 + tokenWeight(rawMediaTokens)
        }

        if hasOnlySubtitleQualifiers(after: mediaTokens, in: rawSubtitleTokens) {
            return 10_000 + tokenWeight(mediaTokens)
        }

        let sharedCount: Int
        if isPrefix(subtitleTokens, of: mediaTokens) {
            sharedCount = subtitleTokens.count
        } else if isPrefix(mediaTokens, of: subtitleTokens) {
            sharedCount = mediaTokens.count
        } else {
            return nil
        }

        let sharedTokens = Array(mediaTokens.prefix(sharedCount))
        let sharedWeight = tokenWeight(sharedTokens)
        guard sharedWeight >= 4 else {
            return nil
        }

        let unmatchedCount = abs(mediaTokens.count - subtitleTokens.count)
        return 5_000 + (sharedWeight * 10) + (sharedCount * 25) - (unmatchedCount * 5)
    }

    private static let subtitleQualifiers: Set<String> = [
        "ar", "ara", "arabic", "cc", "chs", "cht", "de", "deu", "dub",
        "en", "eng", "english", "es", "forced", "fr", "fra", "fre", "ger",
        "he", "hi", "ita", "it", "ja", "jpn", "ko", "kor", "lat", "nl",
        "pt", "ru", "sdh", "sign", "signs", "spa", "sub", "subs", "us",
        "zh", "zho",
    ]

    private static let mediaQualifiers: Set<String> = [
        "10bit", "aac", "ac3", "av1", "bdrip", "bluray", "ddp", "dl", "dts",
        "dvdrip", "h264", "h265", "hdr", "hevc", "remux", "uhd", "web",
        "webdl", "webrip", "x264", "x265",
    ]

    private static func filenameTokens(_ url: URL) -> [String] {
        let stem = url.deletingPathExtension().lastPathComponent
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
            .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: .current)

        return stem
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    private static func removingTrailingSubtitleQualifiers(from tokens: [String]) -> [String] {
        var result = tokens
        while result.count > 1, let last = result.last, subtitleQualifiers.contains(last) {
            result.removeLast()
        }
        return result
    }

    private static func removingTrailingMediaQualifiers(from tokens: [String]) -> [String] {
        var result = tokens
        while result.count > 1, let last = result.last, isMediaQualifier(last) {
            result.removeLast()
        }
        return result
    }

    private static func isMediaQualifier(_ token: String) -> Bool {
        if mediaQualifiers.contains(token) {
            return true
        }

        if token.hasSuffix("p") || token.hasSuffix("i") {
            let resolution = token.dropLast()
            return !resolution.isEmpty && resolution.allSatisfy(\.isNumber)
        }

        return false
    }

    private static func hasOnlySubtitleQualifiers(after stem: [String], in tokens: [String]) -> Bool {
        isPrefix(stem, of: tokens)
            && tokens.dropFirst(stem.count).allSatisfy(subtitleQualifiers.contains)
    }

    private static func isPrefix(_ prefix: [String], of values: [String]) -> Bool {
        guard prefix.count <= values.count else {
            return false
        }
        return zip(prefix, values).allSatisfy { pair in
            pair.0 == pair.1
        }
    }

    private static func tokenWeight(_ tokens: [String]) -> Int {
        tokens.reduce(0) { $0 + $1.count }
    }
}
