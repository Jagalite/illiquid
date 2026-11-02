import Foundation
import Dispatch
@testable import IlliquidNativePlayback
#if os(Linux)
import Glibc
#else
import Darwin
#endif

private typealias Converter = ExternalTextSubtitleConverter

private struct Fixture {
    let name: String
    let format: Converter.Format
    let source: String
    let cues: Int
    let expectedError: String?
    let timed: Bool
    var comparisonOnly = false
}

private struct Result {
    let output: String?
    let error: String?

    var token: UInt64 {
        if let output { return UInt64(output.utf8.count) + 1 }
        switch error {
        case "missingWebVTTSignature": return 0x1000_0000_0000_0001
        case "noValidCues.srt": return 0x1000_0000_0000_0002
        case "noValidCues.webVTT": return 0x1000_0000_0000_0003
        default: fatalError("Unexpected result")
        }
    }
}

private func timestamp(_ milliseconds: Int, format: Converter.Format) -> String {
    func two(_ value: Int) -> String { value < 10 ? "0\(value)" : String(value) }
    let seconds = milliseconds / 1000
    let fraction = String(milliseconds % 1000)
    return "\(two(seconds / 3600)):\(two(seconds / 60 % 60)):\(two(seconds % 60))"
        + (format == .srt ? "," : ".") + String(repeating: "0", count: 3 - fraction.count) + fraction
}

private func makeSource(_ cues: Int, format: Converter.Format, payload: String) -> String {
    var blocks: [String] = []
    blocks.reserveCapacity(cues + 1)
    if format == .webVTT { blocks.append("WEBVTT") }
    for index in 0..<cues {
        let start = timestamp(index * 2000, format: format)
        let end = timestamp(index * 2000 + 1500, format: format)
        let identifier = format == .srt ? String(index + 1) : "cue-\(index + 1)"
        let settings = format == .webVTT ? " align:start position:10%" : ""
        blocks.append("\(identifier)\n\(start) --> \(end)\(settings)\n\(payload)")
    }
    return blocks.joined(separator: "\n\n")
}

private func fixtures(selected: String? = nil) -> [Fixture] {
    func wanted(_ name: String) -> Bool { selected == nil || selected == name }
    let payloads = [
        ("plain", "The next stop is Central Station.\nPlease take your belongings with you."),
        ("multilingual", "Café déjà vu — 東京へようこそ。\nمرحبا بالعالم · Привет, мир! 👩🏽‍🚀"),
        ("escaped", #"{\an8}Open C:\clips\{take}\scene.srt"# + "\n" + #"Keep {braces}, \N text, and \\ intact."#),
    ]
    var result: [Fixture] = []
    for format in [Converter.Format.srt, .webVTT] {
        let prefix = format == .srt ? "srt" : "vtt"
        for (kind, payload) in payloads {
            for count in [1, 100, 2000, 10000] {
                let name = "\(prefix)-\(count)-\(kind)"
                guard wanted(name) else { continue }
                result.append(Fixture(name: name, format: format,
                    source: makeSource(count, format: format, payload: payload),
                    cues: count, expectedError: nil, timed: true))
            }
        }
    }
    // Timestamp controls: WebVTT's short form exercises the second fast-path
    // shape; unpadded/large hours keep the unchanged general parser exercised.
    for (name, format, hourPrefix) in [
        ("vtt-1000-short-timestamps", Converter.Format.webVTT, ""),
        ("srt-1000-unpadded-hour", .srt, "0:"),
        ("srt-1000-large-hour", .srt, "123:"),
        ("vtt-1000-large-hour", .webVTT, "123:"),
    ] {
        guard wanted(name) else { continue }
        var blocks = format == .webVTT ? ["WEBVTT"] : []
        for index in 0..<1000 {
            let start = hourPrefix + timestamp(index * 2000, format: format).dropFirst(3)
            let end = hourPrefix + timestamp(index * 2000 + 1500, format: format).dropFirst(3)
            blocks.append("\(index + 1)\n\(start) --> \(end)\nCaption")
        }
        result.append(Fixture(name: name, format: format, source: blocks.joined(separator: "\n\n"),
            cues: 1000, expectedError: nil, timed: true))
    }
    for (name, format, payload, ending) in [
        ("srt-100-plain-crlf", Converter.Format.srt, payloads[0].1, "\r\n"),
        ("vtt-100-multilingual-crlf", .webVTT, payloads[1].1, "\r\n"),
        ("srt-100-escaped-cr", .srt, payloads[2].1, "\r"),
    ] {
        guard wanted(name) else { continue }
        result.append(Fixture(name: name, format: format,
            source: makeSource(100, format: format, payload: payload).replacingOccurrences(of: "\n", with: ending),
            cues: 100, expectedError: nil, timed: true))
    }
    // Loading-sized CRLF cases isolate normalization from the unchanged
    // parsing/escaping/output work; existing LF cases remain controls.
    for format in [Converter.Format.srt, .webVTT] {
        let prefix = format == .srt ? "srt" : "vtt"
        for count in [2000, 10000] {
            for (kind, payload) in payloads.prefix(2) {
                let name = "\(prefix)-\(count)-\(kind)-crlf"
                guard wanted(name) else { continue }
                result.append(Fixture(name: name, format: format,
                    source: makeSource(count, format: format, payload: payload)
                        .replacingOccurrences(of: "\n", with: "\r\n"),
                    cues: count, expectedError: nil, timed: true))
            }
        }
        let name = "\(prefix)-2000-plain-cr"
        if wanted(name) {
            result.append(Fixture(name: name, format: format,
                source: makeSource(2000, format: format, payload: payloads[0].1)
                    .replacingOccurrences(of: "\n", with: "\r"),
                cues: 2000, expectedError: nil, timed: true))
        }
    }
    // Force the ASCII eligibility scan to reach the end before falling back.
    // This bounds the added work for almost-ASCII multilingual files.
    for format in [Converter.Format.srt, .webVTT] {
        let prefix = format == .srt ? "srt" : "vtt"
        for count in [2000, 10000] {
            let name = "\(prefix)-\(count)-late-unicode-crlf"
            guard wanted(name) else { continue }
            result.append(Fixture(name: name, format: format,
                source: (makeSource(count, format: format, payload: payloads[0].1) + " é")
                    .replacingOccurrences(of: "\n", with: "\r\n"),
                cues: count, expectedError: nil, timed: true))
        }
    }
    if wanted("vtt-100-escaped-bom") {
        result.append(Fixture(name: "vtt-100-escaped-bom", format: .webVTT,
            source: "\u{FEFF}" + makeSource(100, format: .webVTT, payload: payloads[2].1),
            cues: 100, expectedError: nil, timed: true))
    }
    result += [
        Fixture(name: "srt-empty", format: .srt, source: "", cues: 0,
            expectedError: "noValidCues.srt", timed: true),
        Fixture(name: "vtt-empty", format: .webVTT, source: "WEBVTT\n\n", cues: 0,
            expectedError: "noValidCues.webVTT", timed: true),
        Fixture(name: "vtt-missing-signature", format: .webVTT,
            source: makeSource(1, format: .srt, payload: "Hello"), cues: 0,
            expectedError: "missingWebVTTSignature", timed: true),
        Fixture(name: "srt-no-valid-cues", format: .srt,
            source: "1\n00:00:02,000 --> 00:00:01,000\nReversed\n\n2\nnot a timestamp\nIgnored", cues: 0,
            expectedError: "noValidCues.srt", timed: true),
    ].filter { wanted($0.name) }
    let special: [(String, String)] = [
        ("combining", "\\\u{0301} {\u{0301} }\u{0301}"),
        ("grapheme-joiner", "\\\u{034F} {\u{034F} }\u{034F}"),
        ("variation-selector", "\\\u{FE0F} {\u{FE0F} }\u{FE0F}"),
        ("zero-width-joiner", "\\\u{200D} {\u{200D} }\u{200D}"),
        ("keycap", "\\\u{20E3} {\u{20E3} }\u{20E3}"),
        ("prepend", "\u{0600}\\ \u{0600}{ \u{0600}}"),
        ("literal-newline-escape", #"Existing \N and \\N, {\b1}text{\b0}"#),
        ("nul-and-unicode", "A\0B é e\u{0301} 東京 {🤷🏽‍♀️} \\ نهاية"),
        ("compatibility-punctuation", "＼｛｝﹛﹜﹨"),
        ("trailing-lf", "First line\n"),
        ("empty-payload", ""),
    ]
    for format in [Converter.Format.srt, .webVTT] {
        for (kind, payload) in [
            ("unicode-escaped", "{東京} Café \\مجلد\\ {👩🏽‍🚀}\nПривет, {мир}! \\N"),
            ("combining-escaped", "\\\u{0301} {\u{FE0F} }\u{034F} a\u{0301}\n\\\u{200D} {\u{20E3} }\u{0301}"),
        ] {
            let name = "\(format == .srt ? "srt" : "vtt")-2000-\(kind)"
            guard wanted(name) else { continue }
            result.append(Fixture(name: name, format: format,
                source: makeSource(2000, format: format, payload: payload),
                cues: 2000, expectedError: nil, timed: true))
        }
    }
    for format in [Converter.Format.srt, .webVTT] {
        for (name, payload) in special {
            let caseName = "edge-\(format == .srt ? "srt" : "vtt")-\(name)"
            guard wanted(caseName) else { continue }
            result.append(Fixture(name: caseName, format: format,
                source: makeSource(1, format: format, payload: payload),
                cues: 1, expectedError: nil, timed: false))
        }
    }
    // Every sequence of length 0...3 over this alphabet: 820 payloads,
    // checked in each format. Includes grapheme/normalization boundary cases.
    if selected == nil || selected?.hasPrefix("diff-") == true {
        let alphabet = ["a", "\\", "{", "}", "\u{0301}", "中", "🙂", "\u{034F}", "\u{FE0F}"]
        var level = [""]
        for length in 0...3 {
            for format in [Converter.Format.srt, .webVTT] {
                for (index, payload) in level.enumerated() {
                    let name = "diff-\(format == .srt ? "srt" : "vtt")-\(length)-\(index)"
                    guard wanted(name) else { continue }
                    result.append(Fixture(name: name, format: format,
                        source: makeSource(1, format: format, payload: payload),
                        cues: 1, expectedError: nil, timed: false))
                }
            }
            if length < 3 { level = level.flatMap { prefix in alphabet.map { prefix + $0 } } }
        }
    }
    // Compare the complete original and candidate converters for every short
    // newline/Unicode sequence, including typed errors. Do not normalize a
    // reference and run it through the candidate: Foundation's nonliteral
    // replacement behavior is itself part of the compatibility contract.
    if selected == nil || selected?.hasPrefix("newline-diff-") == true {
        let atoms = ["\r", "\n", "a", "\u{0301}", "\u{200D}", "\u{FE0F}", "\u{0000}", "é"]
        let timing = "00:00:01.000 --> 00:00:02.000\nCaption"
        var sequences = [""]
        for length in 0...3 {
            for format in [Converter.Format.srt, .webVTT] {
                let prefix = format == .srt ? "srt" : "vtt"
                let header = format == .webVTT ? "WEBVTT\n\n" : ""
                for (index, sequence) in sequences.enumerated() {
                    for (placement, source) in [
                        header + timing + sequence + "Tail",
                        header + sequence + timing,
                        sequence,
                    ].enumerated() {
                        let name = "newline-diff-\(prefix)-\(length)-\(index)-\(placement)"
                        guard wanted(name) else { continue }
                        result.append(Fixture(name: name, format: format, source: source,
                            cues: -1, expectedError: nil, timed: false, comparisonOnly: true))
                    }
                }
            }
            if length < 3 { sequences = sequences.flatMap { prefix in atoms.map { prefix + $0 } } }
        }
    }
    // Mutate every byte position of all four recognized timestamp spellings.
    // The unchanged baseline is the oracle for these malformed/legacy forms;
    // -1 means the expected cue count is determined by byte/error parity, not
    // by a second copy of the parser in this harness. These cases are untimed.
    if selected == nil || selected?.hasPrefix("diff-timestamp-") == true {
        let atoms = (0..<128).map { String(UnicodeScalar($0)!) }
            + ["\u{0301}", "\u{034F}", "\u{00A0}", "\u{200D}", "１", "١", "🙂"]
        let forms: [(Converter.Format, String)] = [
            (.srt, "09:58:57,995"), (.srt, "09:58:57.995"),
            (.webVTT, "09:58:57.995"), (.webVTT, "58:57.995"),
        ]
        for (formIndex, form) in forms.enumerated() {
            let (format, original) = form
            let characters = Array(original)
            let header = format == .webVTT ? "WEBVTT\n\n" : "1\n"
            for position in characters.indices {
                for (atomIndex, atom) in (atoms + [""]).enumerated() {
                    let mutated = String(characters[..<position]) + atom
                        + String(characters[(position + 1)...])
                    for endpoint in 0...1 {
                        let name = "diff-timestamp-\(formIndex)-\(position)-\(atomIndex)-\(endpoint)"
                        guard wanted(name) else { continue }
                        let start = endpoint == 0 ? mutated : "00:00:00.000"
                        let end = endpoint == 1 ? mutated : "2147483647:59:59.994"
                        result.append(Fixture(name: name, format: format,
                            source: header + start + " --> " + end + "\nCaption",
                            cues: -1, expectedError: nil, timed: false))
                    }
                }
            }
        }
    }
    result += preprocessingFixtures(selected: selected)
    return result
}

private func preprocessingFixtures(selected: String?) -> [Fixture] {
    guard selected == nil || selected!.hasPrefix("preprocess-") else { return [] }
    func wanted(_ name: String) -> Bool { selected == nil || selected == name }
    var result: [Fixture] = []
    for format in [Converter.Format.srt, .webVTT] {
        let label = format == .srt ? "srt" : "vtt"
        let canonical = format == .srt ? "00:12:34,567" : "00:12:34.567"
        let spaces = [" ", "\t", " \t ", "\u{000B}", "\u{000C}", "\u{00A0}", "\u{2003}",
                      "\u{200B}", "\u{3000}", "\u{2028}", "\u{2029}", "\u{0085}",
                      " \u{0301}", "\t\u{034F}"]
        for (index, space) in spaces.enumerated() {
            let values = [space + canonical, canonical + space, space + canonical + space,
                          canonical + space + "align:start", canonical + space + "label:日本語"]
            for (position, value) in values.enumerated() {
                for endpoint in 0...1 {
                    let name = "preprocess-diff-\(label)-\(index)-\(position)-\(endpoint)"
                    guard wanted(name) else { continue }
                    let start = endpoint == 0 ? value : "00:00:00.000"
                    let end = endpoint == 0 ? "100:00:00.000" : value
                    let source = (format == .webVTT ? "WEBVTT\n\n" : "")
                        + start + " --> " + end + "\nProbe\n\n"
                        + "00:00:03.000 --> 00:00:04.000\nSentinel"
                    // As with the existing timestamp mutations, full output and
                    // errors are checked against the immutable production baseline.
                    result.append(Fixture(name: name, format: format, source: source,
                                          cues: -1, expectedError: nil, timed: false))
                }
            }
        }
        for kind in ["malformed", "unicode-settings"] {
            if kind == "unicode-settings" && format == .srt { continue }
            let name = "preprocess-control-\(label)-2000-\(kind)"
            guard wanted(name) else { continue }
            var source = makeSource(2000, format: format, payload: "Caption")
            if kind == "unicode-settings" {
                source = source.replacingOccurrences(of: "align:start", with: "align:日本語")
            } else {
                source = source.replacingOccurrences(of: #"(?m)^\d{2}:\d{2}:\d{2}[.,]\d{3} -->"#,
                    with: "00:60:00.000 -->", options: .regularExpression)
            }
            let error = kind == "malformed" ? "noValidCues." + (format == .srt ? "srt" : "webVTT") : nil
            result.append(Fixture(name: name, format: format, source: source,
                cues: kind == "malformed" ? 0 : 2000, expectedError: error, timed: true))
        }
    }
    return result
}

@inline(never)
private func convert(_ fixture: Fixture) -> Result {
    do {
        return Result(output: try Converter.convert(fixture.source, format: fixture.format), error: nil)
    } catch Converter.ConversionError.missingWebVTTSignature {
        return Result(output: nil, error: "missingWebVTTSignature")
    } catch Converter.ConversionError.noValidCues(let format) {
        return Result(output: nil, error: format == .srt ? "noValidCues.srt" : "noValidCues.webVTT")
    } catch {
        fatalError("Unexpected conversion error: \(error)")
    }
}

private func fnv(_ text: String) -> String {
    var hash: UInt64 = 14695981039346656037
    for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
    return String(hash, radix: 16)
}

private func check(_ result: Result, fixture: Fixture) {
    // Untimed timestamp mutations are checked against the exact baseline
    // output/error by run.py; their acceptance is intentionally not predicted.
    if fixture.cues < 0 { return }
    // Malformed mixed-newline fixtures are checked against the separately
    // compiled original converter, without assuming its parsing outcome.
    guard !fixture.comparisonOnly else { return }
    precondition(result.error == fixture.expectedError, "Unexpected error for \(fixture.name)")
    if let output = result.output {
        let count = output.components(separatedBy: "\n").filter { $0.hasPrefix("Dialogue: ") }.count
        precondition(count == fixture.cues, "Unexpected cue count for \(fixture.name)")
    }
}

private func metadata(_ fixture: Fixture) -> [String: Any] {
    ["case": fixture.name, "format": fixture.format == .srt ? "srt" : "webVTT",
     "cues": fixture.cues, "input_bytes": fixture.source.utf8.count,
     "input_fnv1a": fnv(fixture.source), "timed": fixture.timed]
}

private func cpuNanoseconds() -> UInt64 {
    var value = timespec()
    precondition(clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &value) == 0)
    return UInt64(value.tv_sec) * 1_000_000_000 + UInt64(value.tv_nsec)
}

private func emit(_ object: Any) throws {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([10]))
}

@main
private struct Main {
    static func main() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        let cases = fixtures(selected: args.first == "measure" && args.count > 1 ? args[1] : nil)
        switch args.first {
        case "list":
            try emit(cases.map(metadata))
        case "verify":
            let records: [[String: Any]] = cases.map { fixture in
                let result = convert(fixture)
                check(result, fixture: fixture)
                var record = metadata(fixture)
                record["input_base64"] = Data(fixture.source.utf8).base64EncodedString()
                record["output_base64"] = result.output.map { Data($0.utf8).base64EncodedString() } as Any? ?? NSNull()
                record["output_fnv1a"] = result.output.map(fnv) as Any? ?? NSNull()
                record["output_bytes"] = result.output?.utf8.count ?? 0
                record["error"] = result.error as Any? ?? NSNull()
                record["token"] = String(result.token)
                return record
            }
            try emit(records)
        case "measure":
            guard args.count == 3, let fixture = cases.first(where: { $0.name == args[1] }),
                  let iterations = Int(args[2]), iterations > 0 else {
                fatalError("measure CASE POSITIVE_ITERATIONS")
            }
            // Input construction, full output checking, and warmup are untimed.
            let reference = convert(fixture)
            check(reference, fixture: fixture)
            var checksum: UInt64 = 0
            let cpuStart = cpuNanoseconds()
            let start = DispatchTime.now().uptimeNanoseconds
            for index in 0..<iterations {
                let result = convert(fixture)
                // Consume every returned string without hashing its entire
                // contents in the measured interval. The module boundary also
                // prevents the driver from hoisting or deleting conversion.
                checksum &+= result.token &+ (UInt64(index) &* 131)
            }
            let elapsed = DispatchTime.now().uptimeNanoseconds - start
            let cpuElapsed = cpuNanoseconds() - cpuStart
            var expected: UInt64 = 0
            for index in 0..<iterations { expected &+= reference.token &+ (UInt64(index) &* 131) }
            precondition(checksum == expected, "Timed result checksum changed")
            let after = convert(fixture)
            check(after, fixture: fixture)
            precondition(after.error == reference.error)
            precondition(after.output.map { Array($0.utf8) } == reference.output.map { Array($0.utf8) })
            var record = metadata(fixture)
            record["operations"] = iterations
            record["elapsed_ns"] = elapsed
            record["cpu_ns"] = cpuElapsed
            record["checksum"] = String(checksum)
            record["output_fnv1a"] = after.output.map(fnv) as Any? ?? NSNull()
            record["output_bytes"] = after.output?.utf8.count ?? 0
            record["error"] = after.error as Any? ?? NSNull()
            try emit(record)
        default:
            fatalError("Use list, verify, or measure CASE ITERATIONS")
        }
    }
}
