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
        // Keep one token buffer and the normalized prefix length per media.
        // Retaining slices would enlarge every record, even without qualifiers.
        var media: [(url: URL, raw: [String], tokenCount: Int)] = []
        for url in result.keys where MediaFileSupport.isSupportedMediaFile(url) {
            guard !isCancelled() else { return [:] }
            let raw = filenameTokens(url)
            let tokens = removingTrailingMediaQualifiers(from: raw)
            guard !tokens.isEmpty else { continue }
            index.insert(tokens, index: media.count)
            media.append((url, raw, tokens.count))
        }
        for subtitleURL in subtitleURLs {
            guard !isCancelled() else { return [:] }
            guard MediaFileSupport.isSupportedSubtitleFile(subtitleURL) else { continue }
            let raw = filenameTokens(subtitleURL)
            let tokens = removingTrailingSubtitleQualifiers(from: raw)
            var best: (index: Int, score: Int)?
            var tied = false
            let completed = index.visitCandidates(for: tokens, isCancelled: isCancelled) { candidate in
                let item = media[candidate]
                guard let score = matchScore(
                    rawMediaTokens: item.raw, mediaTokens: item.raw.prefix(item.tokenCount),
                    rawSubtitleTokens: raw, subtitleTokens: tokens
                ) else { return }
                if best == nil || score > best!.score {
                    best = (candidate, score)
                    tied = false
                } else if score == best!.score {
                    tied = true
                }
            }
            guard completed else { return [:] }
            if let best, !tied {
                result[media[best.index].url, default: []].append(subtitleURL)
            }
        }

        // Replacing existing values preserves indices and avoids a key snapshot.
        var resultIndex = result.startIndex
        while resultIndex != result.endIndex {
            guard !isCancelled() else { return [:] }
            result.values[resultIndex] = NaturalFilenameOrdering.sort(result.values[resultIndex])
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

        func insert(_ tokens: ArraySlice<String>, index: Int) {
            var node = self
            for token in tokens {
                if node.children[token] == nil { node.children[token] = TokenIndex() }
                node = node.children[token]!
            }
            node.terminal.append(index)
        }

        // Visit matches as they are found instead of retaining a candidate array.
        // false distinguishes cancellation from a completed, possibly empty
        // traversal, so the caller can discard all earlier associations.
        func visitCandidates(
            for tokens: ArraySlice<String>, isCancelled: () -> Bool, _ visit: (Int) -> Void
        ) -> Bool {
            guard !tokens.isEmpty else { return true }
            var node = self
            for token in tokens {
                guard !isCancelled() else { return false }
                for candidate in node.terminal {
                    guard !isCancelled() else { return false }
                    visit(candidate)
                }
                guard let child = node.children[token] else { return true }
                node = child
            }
            var pending = [node]
            while let current = pending.popLast() {
                guard !isCancelled() else { return false }
                for candidate in current.terminal {
                    guard !isCancelled() else { return false }
                    visit(candidate)
                }
                pending.append(contentsOf: current.children.values)
            }
            return true
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
        rawMediaTokens: [String], mediaTokens: ArraySlice<String>,
        rawSubtitleTokens: [String], subtitleTokens: ArraySlice<String>
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
        if let tokens = asciiFilenameTokens(stem) { return tokens }

        let normalized = stem.lowercased(with: Locale(identifier: "en_US_POSIX"))
            .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: .current)

        return normalized
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    private static func asciiFilenameTokens(_ stem: String) -> [String]? {
        // Noncontiguous strings keep Foundation's normalization path without
        // a preliminary UTF-8 traversal of bridged UTF-16 storage.
        return stem.utf8.withContiguousStorageIfAvailable { bytes -> [String]? in
            // POSIX lowercasing and diacritic/width folding reduce to ASCII case
            // conversion here. Check the whole stem before allocating tokens so
            // names needing Foundation's Unicode normalization use the original path.
            guard bytes.allSatisfy({ $0 < 128 }) else { return nil }

            var tokens: [String] = []
            var token: [UInt8] = []
            token.reserveCapacity(bytes.count)
            for byte in bytes {
                switch byte {
                case 65...90: token.append(byte + 32)
                case 48...57, 97...122: token.append(byte)
                default:
                    if !token.isEmpty {
                        tokens.append(String(decoding: token, as: UTF8.self))
                        token.removeAll(keepingCapacity: true)
                    }
                }
            }
            if !token.isEmpty { tokens.append(String(decoding: token, as: UTF8.self)) }
            return tokens
        } ?? nil
    }

    private static func removingTrailingSubtitleQualifiers(from tokens: [String]) -> ArraySlice<String> {
        var count = tokens.count
        while count > 1, subtitleQualifiers.contains(tokens[count - 1]) {
            count -= 1
        }
        return tokens.prefix(count)
    }

    private static func removingTrailingMediaQualifiers(from tokens: [String]) -> ArraySlice<String> {
        var count = tokens.count
        while count > 1, isMediaQualifier(tokens[count - 1]) {
            count -= 1
        }
        return tokens.prefix(count)
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

    private static func hasOnlySubtitleQualifiers<Stem: Collection>(
        after stem: Stem, in tokens: [String]
    ) -> Bool where Stem.Element == String {
        isPrefix(stem, of: tokens)
            && tokens.dropFirst(stem.count).allSatisfy(subtitleQualifiers.contains)
    }

    private static func isPrefix<Prefix: Collection, Values: Collection>(
        _ prefix: Prefix, of values: Values
    ) -> Bool where Prefix.Element == String, Values.Element == String {
        guard prefix.count <= values.count else {
            return false
        }
        return zip(prefix, values).allSatisfy { pair in
            pair.0 == pair.1
        }
    }

    private static func tokenWeight<Tokens: Sequence>(_ tokens: Tokens) -> Int where Tokens.Element == String {
        tokens.reduce(0) { $0 + $1.count }
    }
}
