import Foundation

/// Associates external SRT and ASS files with the most closely related media
/// filename in a folder.
public enum ExternalSubtitleMatcher {
    /// Returns subtitle associations keyed by the original media URLs.
    ///
    /// A subtitle is left unassigned if two media files are equally good matches.
    /// This prevents a generic filename such as `Show.srt` from being loaded for
    /// every episode in a folder.
    public static func associate(
        subtitleURLs: [URL],
        with mediaURLs: [URL],
        isCancelled: () -> Bool = { Task.isCancelled }
    ) -> [URL: [URL]] {
        var result: [URL: [URL]] = [:]
        for mediaURL in mediaURLs {
            result[mediaURL] = []
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
        for subtitleURL in subtitleURLs where MediaFileSupport.isSupportedSubtitleFile(subtitleURL) {
            guard !isCancelled() else { return [:] }
            let raw = filenameTokens(subtitleURL)
            let tokens = removingTrailingSubtitleQualifiers(from: raw)
            var best: (index: Int, score: Int)?
            var tied = false
            for candidate in index.candidates(for: tokens, isCancelled: isCancelled) {
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

        for mediaURL in Array(result.keys) {
            result[mediaURL] = NaturalFilenameOrdering.sort(result[mediaURL, default: []])
        }

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

        func candidates(for tokens: [String], isCancelled: () -> Bool) -> [Int] {
            guard !tokens.isEmpty else { return [] }
            var result: [Int] = []
            var node = self
            for token in tokens {
                result.append(contentsOf: node.terminal)
                guard let child = node.children[token] else { return result }
                node = child
            }
            var pending = [node]
            while let current = pending.popLast() {
                guard !isCancelled() else { return [] }
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

        if mediaTokens == subtitleTokens {
            return 10_000 + tokenWeight(mediaTokens)
        }

        if rawMediaTokens == subtitleTokens || mediaTokens == rawSubtitleTokens {
            return 9_000 + tokenWeight(mediaTokens)
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
            return token.dropLast().allSatisfy(\.isNumber)
        }

        return false
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
