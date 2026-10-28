import Foundation

/// Converts bounded, decoded external subtitle text without loading the renderer.
/// Keep parsing independent of native playback so malformed files can be tested
/// without creating a window, a media session, or a libass context.
enum ExternalTextSubtitleConverter {
    enum Format: Equatable, Sendable {
        case srt
        case webVTT
    }

    enum ConversionError: Error, Equatable, LocalizedError {
        case missingWebVTTSignature
        case noValidCues(Format)

        var errorDescription: String? {
            switch self {
            case .missingWebVTTSignature:
                "External WebVTT is missing its WEBVTT signature"
            case .noValidCues(.srt):
                "External SRT contained no valid timed cues"
            case .noValidCues(.webVTT):
                "External WebVTT contained no valid timed cues"
            }
        }
    }

    static let defaultASSHeader = """
    [Script Info]
    ScriptType: v4.00+
    PlayResX: 1920
    PlayResY: 1080
    ScaledBorderAndShadow: yes

    [V4+ Styles]
    Format: Name,Fontname,Fontsize,PrimaryColour,SecondaryColour,OutlineColour,BackColour,Bold,Italic,Underline,StrikeOut,ScaleX,ScaleY,Spacing,Angle,BorderStyle,Outline,Shadow,Alignment,MarginL,MarginR,MarginV,Encoding
    Style: Default,sans-serif,52,&H00FFFFFF,&H000000FF,&H00101010,&H80000000,0,0,0,0,100,100,0,0,1,3,1,2,48,48,40,1

    [Events]
    Format: Layer,Start,End,Style,Name,MarginL,MarginR,MarginV,Effect,Text
    """

    static func convert(_ source: String, format: Format) throws -> String {
        var normalized = source
        if source.utf8.contains(0x0D) {
            normalized = source.replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
        }
        if format == .webVTT {
            // A UTF-8 decoder may retain the optional WebVTT byte-order mark.
            if normalized.first == "\u{FEFF}" { normalized.removeFirst() }
            let signature = normalized.split(
                separator: "\n", maxSplits: 1, omittingEmptySubsequences: false
            ).first ?? ""
            guard signature == "WEBVTT" || signature.hasPrefix("WEBVTT ")
                    || signature.hasPrefix("WEBVTT\t") else {
                throw ConversionError.missingWebVTTSignature
            }
        }

        var output = defaultASSHeader
        var hasEvents = false
        // The WebVTT header and any header metadata never contain cue payloads.
        for block in Blocks(normalized).dropFirst(format == .webVTT ? 1 : 0) {
            let lines = Array(block.split(separator: "\n", omittingEmptySubsequences: false)
                .drop(while: { $0.isEmpty }))
            guard let first = lines.first else { continue }
            let timingIndex: Int?
            if format == .webVTT {
                // NOTE is a block marker, whereas NOTEworthy is a cue identifier.
                // Ignore the entire comment even if malformed content resembles
                // a cue.
                if first == "NOTE" || first.hasPrefix("NOTE ") || first.hasPrefix("NOTE\t") {
                    continue
                }
                // A cue has at most one identifier before its timing line.
                // This also skips untimed STYLE/REGION metadata while preserving
                // those words when used as identifiers with immediate timings.
                timingIndex = first.contains("-->") ? 0
                    : (lines.count > 1 && lines[1].contains("-->") ? 1 : nil)
            } else {
                // Preserve SRT's tolerant handling of optional cue numbers.
                timingIndex = lines.firstIndex(where: { $0.contains("-->") })
            }
            guard let timingIndex else { continue }
            let timing = lines[timingIndex].components(separatedBy: "-->")
            guard timing.count == 2,
                  let start = parseTimestamp(timing[0], format: format),
                  let end = parseTimestamp(timing[1], format: format, allowsSettings: true),
                  end.milliseconds > start.milliseconds
            else { continue }
            let text = lines.dropFirst(timingIndex + 1).map(escapeASSPayload)
                .joined(separator: "\\N")
            output += "\nDialogue: 0,\(assTimestamp(start)),\(assTimestamp(end)),Default,,0,0,0,,\(text)"
            hasEvents = true
        }
        guard hasEvents else { throw ConversionError.noValidCues(format) }
        return output
    }

    /// Visit one block at a time instead of retaining copies of every block
    /// alongside every converted event. LF has no alternate Unicode spelling;
    /// scanning its UTF-8 bytes preserves non-overlapping "\n\n" separators,
    /// including empty blocks and a single trailing LF within the last block.
    private struct Blocks: Sequence, IteratorProtocol {
        private let source: String
        private var nextStart: String.Index?

        init(_ source: String) {
            self.source = source
            nextStart = source.startIndex
        }

        mutating func next() -> Substring? {
            guard let start = nextStart else { return nil }
            let bytes = source.utf8
            var cursor = start
            while let newline = bytes[cursor...].firstIndex(of: 0x0A) {
                let afterNewline = bytes.index(after: newline)
                guard afterNewline != bytes.endIndex else { break }
                if bytes[afterNewline] == 0x0A {
                    nextStart = bytes.index(after: afterNewline)
                    return source[start..<newline]
                }
                cursor = afterNewline
            }
            nextStart = nil
            return source[start...]
        }
    }

    private static func escapeASSPayload(_ line: Substring) -> String {
        let bytes = line.utf8
        var escapeCount = 0
        var isASCII = true
        for byte in bytes {
            if byte >= 0x80 { isASCII = false }
            if byte == 0x5C || byte == 0x7B || byte == 0x7D { escapeCount += 1 }
            if !isASCII, escapeCount > 0 { break }
        }
        guard escapeCount > 0 else { return String(line) }
        guard isASCII else {
            // Foundation's nonliteral matching can leave a backslash or brace
            // attached to a combining mark untouched. Retain that behavior for
            // Unicode payloads instead of treating every UTF-8 byte as a match.
            return line.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "{", with: "\\{")
                .replacingOccurrences(of: "}", with: "\\}")
        }
        var escaped: [UInt8] = []
        escaped.reserveCapacity(bytes.count + escapeCount)
        for byte in bytes {
            if byte == 0x5C || byte == 0x7B || byte == 0x7D { escaped.append(0x5C) }
            escaped.append(byte)
        }
        return String(decoding: escaped, as: UTF8.self)
    }

    private struct Timestamp {
        let milliseconds: Int64
        let centiseconds: Int64
    }

    // libass 0.17.5 string2timecode reads the ASS hour field into int32_t.
    // This is a representation bound, not a limit on ordinary media duration.
    private static let maximumASSHours = Int64(Int32.max)

    private static func parseTimestamp(
        _ value: String, format: Format, allowsSettings: Bool = false
    ) -> Timestamp? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        let timestamp: Substring
        if format == .webVTT, allowsSettings {
            // Positioning settings remain ignored, as in the existing importer.
            timestamp = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" }).first ?? ""
        } else {
            timestamp = trimmed[...]
        }
        if let parsed = timestamp.utf8.withContiguousStorageIfAvailable({
            parseFixedWidthTimestamp($0, format: format)
        }) ?? nil {
            return parsed
        }
        let parts = timestamp.split(separator: ":", omittingEmptySubsequences: false)
        let hours: Int64
        let minutesIndex: Int
        switch format {
        case .srt:
            guard parts.count == 3,
                  let parsedHours = decimalInteger(parts[0], maximum: maximumASSHours)
            else { return nil }
            hours = parsedHours
            minutesIndex = 1
        case .webVTT:
            guard parts.count == 2 || parts.count == 3 else { return nil }
            if parts.count == 3 {
                guard parts[0].utf8.count >= 2,
                      let parsedHours = decimalInteger(parts[0], maximum: maximumASSHours)
                else { return nil }
                hours = parsedHours
                minutesIndex = 1
            } else {
                hours = 0
                minutesIndex = 0
            }
            guard parts[minutesIndex].utf8.count == 2 else { return nil }
        }
        guard let minutes = decimalInteger(parts[minutesIndex], maximum: 59) else { return nil }
        let secondsParts = parts[minutesIndex + 1].split(
            omittingEmptySubsequences: false,
            whereSeparator: { $0 == "." || (format == .srt && $0 == ",") }
        )
        guard secondsParts.count == 1 || secondsParts.count == 2,
              let seconds = decimalInteger(secondsParts[0], maximum: 59)
        else { return nil }
        if format == .webVTT {
            guard secondsParts.count == 2, secondsParts[0].utf8.count == 2,
                  secondsParts[1].utf8.count == 3 else { return nil }
        }

        var fraction: Int64 = 0
        if secondsParts.count == 2 {
            let digits = secondsParts[1]
            guard !digits.isEmpty, digits.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
                  let parsed = decimalInteger(digits.prefix(3), maximum: 999)
            else { return nil }
            // Preserve SRT's existing millisecond interpretation and truncation
            // of additional fractional digits. WebVTT requires exactly three.
            fraction = parsed
        }
        // Every operand is bounded before arithmetic; neither hostile numbers
        // nor floating-point special values can reach a trapping Int conversion.
        let milliseconds = ((hours * 60 + minutes) * 60 + seconds) * 1_000 + fraction
        let centiseconds = (milliseconds + 5) / 10
        // Rounding 59:59.995 may carry into the next hour. Check the emitted
        // value too, so the ASS parser never receives an overflowing hour field.
        guard centiseconds / 360_000 <= maximumASSHours else { return nil }
        return Timestamp(milliseconds: milliseconds, centiseconds: centiseconds)
    }

    /// Most cues use HH:MM:SS,mmm / HH:MM:SS.mmm, or WebVTT's MM:SS.mmm.
    /// Read those ASCII fields without allocating split arrays. Everything else
    /// keeps the general parser's whitespace, large-hour, and legacy SRT rules.
    private static func parseFixedWidthTimestamp(
        _ bytes: UnsafeBufferPointer<UInt8>, format: Format
    ) -> Timestamp? {
        let hours: Int64
        let offset: Int
        if bytes.count == 12 {
            guard bytes[2] == 58,
                  let value = decimalPair(bytes[0], bytes[1]) else { return nil }
            hours = value
            offset = 3
        } else if bytes.count == 9, format == .webVTT {
            hours = 0
            offset = 0
        } else {
            return nil
        }
        guard bytes[offset + 2] == 58,
              bytes[offset + 5] == 46 || (format == .srt && bytes[offset + 5] == 44),
              let minutes = decimalPair(bytes[offset], bytes[offset + 1]), minutes < 60,
              let seconds = decimalPair(bytes[offset + 3], bytes[offset + 4]), seconds < 60,
              let fractionPrefix = decimalPair(bytes[offset + 6], bytes[offset + 7]),
              bytes[offset + 8] >= 48, bytes[offset + 8] <= 57 else { return nil }
        let fraction = fractionPrefix * 10 + Int64(bytes[offset + 8] - 48)
        // Two-digit hours and validated fields cannot approach the ASS hour
        // bound, including a centisecond carry from 99:59:59.995 to 100:00:00.
        let milliseconds = ((hours * 60 + minutes) * 60 + seconds) * 1_000 + fraction
        return Timestamp(milliseconds: milliseconds, centiseconds: (milliseconds + 5) / 10)
    }

    private static func decimalPair(_ first: UInt8, _ second: UInt8) -> Int64? {
        guard first >= 48, first <= 57, second >= 48, second <= 57 else { return nil }
        return Int64(first - 48) * 10 + Int64(second - 48)
    }

    private static func decimalInteger(_ value: Substring, maximum: Int64) -> Int64? {
        guard !value.isEmpty else { return nil }
        var result: Int64 = 0
        for byte in value.utf8 {
            guard byte >= 48, byte <= 57 else { return nil }
            let digit = Int64(byte - 48)
            guard result <= (maximum - digit) / 10 else { return nil }
            result = result * 10 + digit
        }
        return result
    }

    private static func assTimestamp(_ timestamp: Timestamp) -> String {
        let value = timestamp.centiseconds
        let hours = value / 360_000
        let minutes = (value / 6_000) % 60
        let seconds = (value / 100) % 60
        let fraction = value % 100
        // Interpolation avoids narrowing a Swift Int through printf's %d.
        return "\(hours):\(twoDigits(minutes)):\(twoDigits(seconds)).\(twoDigits(fraction))"
    }

    private static func twoDigits(_ value: Int64) -> String {
        value < 10 ? "0\(value)" : String(value)
    }
}
