import Foundation

/// Times use the player's zero-based media timeline, before subtitle delay.
public struct CaptionCue: Equatable, Hashable, Sendable, Identifiable {
    public let id: Int
    public let start: TimeInterval
    public let end: TimeInterval
    public let text: String

    public init?(id: Int, start: TimeInterval, end: TimeInterval, text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard start.isFinite, end.isFinite, end > max(start, 0),
              !text.isEmpty, text.utf8.count <= 65_536 else { return nil }
        self.id = id
        self.start = max(start, 0)
        self.end = end
        self.text = text
    }
}

public struct CaptionIndex: Equatable, Sendable {
    public static let maximumCues = 50_000
    public static let maximumTextBytes = 8 * 1_024 * 1_024
    public let cues: [CaptionCue]
    public let isComplete: Bool
    private let searchText: [String]

    public init(cues: [CaptionCue], isComplete: Bool = true) {
        var bytes = 0
        var bounded: [CaptionCue] = []
        var seen: Set<Key> = []
        var complete = isComplete
        for cue in cues {
            let key = Key(start: cue.start, end: cue.end, text: cue.text)
            if seen.contains(key) { continue }
            guard bounded.count < Self.maximumCues,
                  cue.text.utf8.count <= Self.maximumTextBytes - bytes else {
                complete = false
                break
            }
            bytes += cue.text.utf8.count
            seen.insert(key)
            bounded.append(cue)
        }
        bounded.sort {
            if $0.start != $1.start { return $0.start < $1.start }
            if $0.end != $1.end { return $0.end < $1.end }
            return $0.text < $1.text
        }
        self.cues = bounded.enumerated().compactMap {
            CaptionCue(id: $0.offset, start: $0.element.start, end: $0.element.end, text: $0.element.text)
        }
        self.searchText = self.cues.map { Self.normalized($0.text) }
        self.isComplete = complete
    }

    public func search(_ query: String, limit: Int = 500, isCancelled: @Sendable () -> Bool = { false }) -> [CaptionCue] {
        let query = Self.normalized(String(query.prefix(256))).trimmingCharacters(in: .whitespacesAndNewlines)
        let limit = min(max(limit, 0), Self.maximumCues)
        guard limit > 0 else { return [] }
        if query.isEmpty { return Array(cues.prefix(limit)) }
        var result: [CaptionCue] = []
        for (index, text) in searchText.enumerated() {
            if index % 128 == 0, isCancelled() { return [] }
            guard text.contains(query) else { continue }
            result.append(cues[index])
            if result.count == limit { break }
        }
        return result
    }

    public func target(for cueID: Int, subtitleDelay: TimeInterval, duration: TimeInterval? = nil) -> TimeInterval? {
        guard cues.indices.contains(cueID), subtitleDelay.isFinite else { return nil }
        // SubtitlePipeline renders at mediaTime + delay, so invert that mapping.
        let target = max(0, cues[cueID].start - subtitleDelay)
        guard target.isFinite else { return nil }
        return duration.flatMap { $0.isFinite && $0 > 0 ? min(target, $0) : nil } ?? target
    }

    /// Replays the current cue after its first 250 ms; otherwise the prior cue.
    public func previousCue(at time: TimeInterval, subtitleDelay: TimeInterval) -> CaptionCue? {
        guard time.isFinite, subtitleDelay.isFinite else { return nil }
        let before = time + subtitleDelay - 0.25
        guard before.isFinite else { return nil }
        return cues.last { $0.start <= before }
    }

    /// A deterministic subtitle heuristic, not speech recognition: join at most
    /// eight non-overlapping cues across <=1.5 s gaps and <=20 s total, stopping
    /// at sentence punctuation. Overlapping signs/dialogue are not joined.
    public func previousSentence(at time: TimeInterval, subtitleDelay: TimeInterval) -> CaptionCue? {
        guard let current = previousCue(at: time, subtitleDelay: subtitleDelay) else { return nil }
        var start = 0
        for index in cues.indices {
            if index > 0 {
                let previous = cues[index - 1]
                let gap = cues[index].start - previous.end
                if Self.endsSentence(previous.text) || gap < 0 || gap > 1.5
                    || index - start >= 8 || cues[index].end - cues[start].start > 20 {
                    start = index
                }
            }
            if index == current.id { return cues[start] }
        }
        return nil
    }

    private struct Key: Hashable { let start: Double; let end: Double; let text: String }
    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
    private static func endsSentence(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines
            .union(CharacterSet(charactersIn: "\"'”’»」』)]")))
        return trimmed.last.map { ".!?。！？".contains($0) } ?? false
    }
}

public enum CaptionText {
    /// FFmpeg text decoder events have eight comma-separated fields before Text.
    public static func fromASSPacket(_ packet: String) -> String {
        guard packet.utf8.count <= 65_536 else { return "" }
        let fields = packet.split(separator: ",", maxSplits: 8, omittingEmptySubsequences: false)
        guard fields.count == 9 else { return "" }
        return plainASS(String(fields[8]))
    }

    public static func plainASS(_ source: String) -> String {
        guard source.utf8.count <= 65_536 else { return "" }
        var output = ""
        var drawing = false
        var index = source.startIndex
        while index < source.endIndex {
            let character = source[index]
            if character == "{" {
                guard let end = source[index...].firstIndex(of: "}") else {
                    // An unterminated override is literal text. Stop searching
                    // the same suffix repeatedly for malicious runs of "{".
                    if !drawing { output += source[index...] }
                    break
                }
                let block = source[source.index(after: index)..<end]
                // Match only the drawing-mode tag (not \\pos or \\pbo).
                for tag in block.split(separator: "\\") where tag.first == "p" {
                    let digits = tag.dropFirst().prefix { $0.isASCII && $0.isNumber }
                    if !digits.isEmpty { drawing = Int(digits) != 0 }
                }
                index = source.index(after: end)
                continue
            }
            if character == "\\" {
                let next = source.index(after: index)
                if next < source.endIndex, "Nnh".contains(source[next]) {
                    if !drawing { output += source[next] == "h" ? " " : "\n" }
                    index = source.index(after: next)
                    continue
                }
            }
            if !drawing { output.append(character) }
            index = source.index(after: index)
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Parses the ASS representation already used by native external subtitles.
    /// ASS/SSA Format declarations are honored; Text must be the final column.
    public static func parseASSDocument(_ data: Data) -> CaptionIndex {
        guard data.count <= 16 * 1_024 * 1_024, let source = String(data: data, encoding: .utf8) else {
            return CaptionIndex(cues: [], isComplete: false)
        }
        var inEvents = false
        var fields: [String] = []
        var cues: [CaptionCue] = []
        var complete = true
        var textBytes = 0
        for rawLine in source.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("[") { inEvents = line.lowercased() == "[events]"; continue }
            guard inEvents else { continue }
            if line.lowercased().hasPrefix("format:") {
                fields = line.dropFirst(7).split(separator: ",").map {
                    $0.trimmingCharacters(in: .whitespaces).lowercased()
                }
                continue
            }
            guard line.lowercased().hasPrefix("dialogue:") else { continue }
            guard fields.last == "text", let startIndex = fields.firstIndex(of: "start"),
                  let endIndex = fields.firstIndex(of: "end"), fields.count <= 32 else {
                complete = false
                continue
            }
            let values = line.dropFirst(9).split(separator: ",", maxSplits: fields.count - 1,
                omittingEmptySubsequences: false)
            guard values.count == fields.count,
                  let start = timestamp(values[startIndex]), let end = timestamp(values[endIndex]) else {
                complete = false
                continue
            }
            guard values[values.count - 1].utf8.count <= 65_536, end > max(start, 0) else {
                complete = false
                continue
            }
            let text = plainASS(String(values[values.count - 1]))
            guard let cue = CaptionCue(id: cues.count, start: start, end: end, text: text) else { continue }
            guard cues.count < CaptionIndex.maximumCues,
                  text.utf8.count <= CaptionIndex.maximumTextBytes - textBytes else {
                complete = false
                break
            }
            textBytes += text.utf8.count
            cues.append(cue)
        }
        return CaptionIndex(cues: cues, isComplete: complete)
    }

    private static func timestamp(_ value: Substring) -> Double? {
        let parts = value.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard parts.count == 3, let hours = Double(parts[0]), let minutes = Double(parts[1]),
              let seconds = Double(parts[2]), hours.isFinite, hours >= 0,
              hours.rounded(.towardZero) == hours, minutes.rounded(.towardZero) == minutes,
              (0..<60).contains(minutes), seconds.isFinite, (0..<60).contains(seconds) else { return nil }
        let result = hours * 3_600 + minutes * 60 + seconds
        return result.isFinite ? result : nil
    }
}

public struct CaptionSourceRequest: Equatable, Hashable, Sendable {
    public let mediaURL: URL
    public let subtitleTrack: MediaTrack
    public let externalURL: URL?
    public let fallbackEncoding: SubtitleFallbackEncoding
    public let sourceRevision: UInt64
    public let mediaVersion: MediaContentVersion?

    public init(mediaURL: URL, subtitleTrack: MediaTrack, externalURL: URL? = nil,
                fallbackEncoding: SubtitleFallbackEncoding = .unicodeOnly, sourceRevision: UInt64, mediaVersion: MediaContentVersion? = nil) {
        self.mediaURL = mediaURL
        self.subtitleTrack = subtitleTrack
        self.externalURL = externalURL
        self.fallbackEncoding = fallbackEncoding
        self.sourceRevision = sourceRevision
        self.mediaVersion = mediaVersion
    }
}
