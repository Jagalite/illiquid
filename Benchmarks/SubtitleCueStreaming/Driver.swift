import Darwin
import Foundation

// Compile with the complete production converter for each variant. Inputs,
// warmup, and JSON encoding are outside the timed loop. Darwin ru_maxrss is bytes.
private let maximumInputBytes = 4 * 1_024 * 1_024
private let maximumIterations = 1_000_000

private struct DriverError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private func require(_ condition: Bool, _ message: String) throws {
    guard condition else { throw DriverError(message) }
}

private enum FixtureFormat: String {
    case srt, webVTT
    func convert(_ source: String) throws -> String {
        try ExternalTextSubtitleConverter.convert(source, format: self == .srt ? .srt : .webVTT)
    }
}

private struct Fixture {
    let id: String
    let format: FixtureFormat
    let source: String
}

private struct OutputStamp: Equatable {
    let byteCount: Int
    let lastByte: UInt8
    var checksum: UInt64 { UInt64(byteCount) + UInt64(lastByte) }
}

private func stamp(_ output: String) -> OutputStamp {
    let bytes = output.utf8
    return OutputStamp(byteCount: bytes.count, lastByte: bytes.last ?? 0)
}

@inline(never)
private func consumeConversion(_ fixture: Fixture) throws -> OutputStamp {
    try autoreleasepool {
        let output = try fixture.format.convert(fixture.source)
        return stamp(output)
    }
}

private func nanoseconds(_ clock: clockid_t) throws -> UInt64 {
    var value = timespec()
    try require(clock_gettime(clock, &value) == 0, "clock_gettime failed")
    return UInt64(value.tv_sec) * 1_000_000_000 + UInt64(value.tv_nsec)
}

private func peakRSSBytes() throws -> UInt64 {
    var usage = rusage()
    try require(getrusage(RUSAGE_SELF, &usage) == 0, "getrusage failed")
    try require(usage.ru_maxrss >= 0, "getrusage returned a negative peak RSS")
    return UInt64(usage.ru_maxrss)
}

// Deterministic fixture identity, not a cryptographic integrity claim.
private func fixtureChecksum(_ fixture: Fixture) -> String {
    var value: UInt64 = 14_695_981_039_346_656_037
    for byte in (fixture.format.rawValue + "\0").utf8 {
        value ^= UInt64(byte)
        value &*= 1_099_511_628_211
    }
    for byte in fixture.source.utf8 {
        value ^= UInt64(byte)
        value &*= 1_099_511_628_211
    }
    return String(value, radix: 16)
}

private func padded(_ value: Int, width: Int) -> String {
    let text = String(value)
    return String(repeating: "0", count: max(0, width - text.count)) + text
}

private func timestamp(seconds: Int, milliseconds: Int, format: FixtureFormat) -> String {
    padded(seconds / 3_600, width: 2) + ":"
        + padded((seconds / 60) % 60, width: 2) + ":"
        + padded(seconds % 60, width: 2) + (format == .srt ? "," : ".")
        + padded(milliseconds, width: 3)
}

private func timingLine(_ cue: Int, format: FixtureFormat) -> String {
    timestamp(seconds: cue * 3, milliseconds: 120, format: format) + " --> "
        + timestamp(seconds: cue * 3 + 2, milliseconds: 840, format: format)
}

private func makeFixture(_ name: String) throws -> Fixture {
    var source = ""
    let format: FixtureFormat
    switch name {
    case "srt-short":
        format = .srt
        source.reserveCapacity(20_000)
        for cue in 0..<128 {
            if cue > 0 { source += "\n\n" }
            source += "\(cue + 1)\n" + timingLine(cue, format: .srt)
                + "\nA short subtitle for cue \(cue)."
        }
    case "vtt-short":
        format = .webVTT
        source = "WEBVTT\n\n"
        source.reserveCapacity(36_000)
        for cue in 0..<128 {
            if cue > 0 { source += "\n\n" }
            source += "cue-\(cue)\n" + timingLine(cue, format: .webVTT)
                + " align:start position:10% line:90%"
                + "\nThe first subtitle line for cue \(cue)."
                + "\nThe second line has café and 東京."
        }
    case "srt-multiline":
        format = .srt
        source.reserveCapacity(150_000)
        for cue in 0..<32 {
            if cue > 0 { source += "\n\n" }
            source += "\(cue + 1)\n" + timingLine(cue, format: .srt)
            for line in 0..<64 {
                source += "\nCue \(cue), line \(line): café 東京 {text} \\N <i>words</i>."
            }
        }
    case "srt-dense":
        format = .srt
        source = "1\n00:00:00,000 --> 00:00:02,000\n"
        source.reserveCapacity(500_000)
        for line in 0..<65_536 {
            if line > 0 { source += "\n" }
            source += "text \(line % 10)"
        }
    case "srt-long-line":
        format = .srt
        source = "1\n00:00:00,000 --> 00:00:02,000\n"
        source.reserveCapacity(1_024 * 1_024 + 128)
        let unit = "subtitle text "
        var remaining = 1_024 * 1_024
        while remaining >= unit.utf8.count {
            source += unit
            remaining -= unit.utf8.count
        }
        source += String(repeating: "x", count: remaining)
    case "invalid-preamble":
        format = .srt
        source.reserveCapacity(400_000)
        for line in 0..<8_192 {
            if line > 0 { source += "\n" }
            source += "Unrelated preamble row \(line) without timing"
        }
        source += "\n\n1\n00:00:00,000 --> 00:00:02,000\nRetained final cue."
    default:
        throw DriverError("Unknown case: \(name)")
    }
    try require(source.utf8.count <= maximumInputBytes, "Fixture exceeds four MiB")
    return Fixture(id: name, format: format, source: source)
}

private func changeLineEndings(_ source: String, mode: Int) -> String {
    switch mode % 4 {
    case 0: return source
    case 1: return source.replacingOccurrences(of: "\n", with: "\r\n")
    case 2: return source.replacingOccurrences(of: "\n", with: "\r")
    default:
        var result = ""
        var newline = 0
        for character in source {
            if character == "\n" {
                result += ["\r\n", "\r", "\n"][newline % 3]
                newline += 1
            } else { result.append(character) }
        }
        return result
    }
}

private func verificationFixtures() throws -> [Fixture] {
    var fixtures: [Fixture] = []
    func add(_ id: String, _ format: FixtureFormat, _ source: String) {
        fixtures.append(Fixture(id: id, format: format, source: source))
    }
    let srtTiming = "00:00:00,000 --> 00:00:02,000"
    let vttTiming = "00:00:00.000 --> 00:00:02.000"
    let srtCue = "1\n\(srtTiming)\nHello"
    let vttCue = "\(vttTiming)\nHello"
    let secondSRT = "2\n00:00:03,000 --> 00:00:04,000\nSecond"
    let secondVTT = "00:00:03.000 --> 00:00:04.000\nSecond"

    add("srt-empty", .srt, "")
    add("srt-whitespace", .srt, " \t\n \t")
    add("srt-basic", .srt, srtCue)
    add("srt-timing-only", .srt, srtTiming)
    add("srt-timing-trailing-lf", .srt, srtTiming + "\n")
    add("srt-body-trailing-lf", .srt, srtCue + "\n")
    add("srt-body-trailing-delimiter", .srt, srtCue + "\n\n")
    add("srt-leading-lf", .srt, "\n" + srtCue)
    add("srt-three-leading-lf", .srt, "\n\n\n" + srtCue)
    add("srt-leading-whitespace-line", .srt, " \t\n" + srtCue)
    add("srt-arbitrary-preamble", .srt, "one\ntwo\nthree\n" + srtTiming + "\nHello")
    add("srt-invalid-first-arrow", .srt,
        "bad --> invalid\n" + srtTiming + "\nIgnored\n\n" + secondSRT)
    add("srt-extra-arrow", .srt,
        "00:00:00,000 --> 00:00:01,000 --> 00:00:02,000\nIgnored\n\n" + secondSRT)
    add("srt-two-cues", .srt, srtCue + "\n\n" + secondSRT)
    add("srt-whitespace-payload-lines", .srt, srtTiming + "\n \t\n \nEnd")
    add("srt-empty-blocks", .srt, "\n\n" + srtCue + "\n\n\n\n" + secondSRT + "\n\n")
    add("srt-braces-and-backslashes", .srt,
        srtTiming + "\n{\\an8}x\\Ny\\nz\\\\end <b>bold</b> &amp;")
    add("srt-unicode", .srt,
        srtTiming + "\ncafé e\u{0301} 中文 👩‍💻\u{2028}next\u{2029}end")
    add("srt-bom", .srt, "\u{FEFF}" + srtCue)
    add("srt-crlf", .srt, changeLineEndings(srtCue + "\n", mode: 1))
    add("srt-cr", .srt, changeLineEndings(srtCue + "\n", mode: 2))
    add("srt-mixed-endings", .srt, changeLineEndings(srtCue + "\n\n" + secondSRT, mode: 3))
    add("srt-negative-start", .srt, "-00:00:01,000 --> 00:00:02,000\nIgnored")
    add("srt-equal-times", .srt, "00:00:01,000 --> 00:00:01,000\nIgnored")
    add("srt-reversed-times", .srt, "00:00:02,000 --> 00:00:01,000\nIgnored")
    add("srt-blank-before-body", .srt, srtTiming + "\n\nUnattached text")
    add("srt-arrow-in-payload", .srt, srtTiming + "\na --> b")
    add("srt-incomplete-final-block", .srt, srtCue + "\n\nunfinished")
    add("srt-nul-payload", .srt, srtTiming + "\na\u{0000}b")
    add("srt-control-payload", .srt, srtTiming + "\na\u{000B}b\u{000C}c")

    add("vtt-empty", .webVTT, "")
    add("vtt-signature-only", .webVTT, "WEBVTT")
    add("vtt-signature-trailing-lf", .webVTT, "WEBVTT\n")
    add("vtt-empty-body", .webVTT, "WEBVTT\n\n")
    add("vtt-basic", .webVTT, "WEBVTT\n\n" + vttCue)
    add("vtt-header-space", .webVTT, "WEBVTT header\n\n" + vttCue)
    add("vtt-header-tab", .webVTT, "WEBVTT\tlabel\n\n" + vttCue)
    add("vtt-invalid-signature-suffix", .webVTT, "WEBVTTx\n\n" + vttCue)
    add("vtt-lowercase-signature", .webVTT, "webvtt\n\n" + vttCue)
    add("vtt-leading-bom", .webVTT, "\u{FEFF}WEBVTT\n\n" + vttCue)
    add("vtt-double-bom", .webVTT, "\u{FEFF}\u{FEFF}WEBVTT\n\n" + vttCue)
    add("vtt-missing-signature", .webVTT, vttCue)
    add("vtt-leading-space-before-signature", .webVTT, " WEBVTT\n\n" + vttCue)
    add("vtt-no-header-block-separator", .webVTT, "WEBVTT\n" + vttCue)
    add("vtt-cue-identifier", .webVTT, "WEBVTT\n\ncue-id\n" + vttCue)
    add("vtt-third-line-timing", .webVTT, "WEBVTT\n\nid-one\nid-two\n" + vttCue)
    add("vtt-empty-identifier", .webVTT, "WEBVTT\n\n\n" + vttCue)
    add("vtt-whitespace-identifier", .webVTT, "WEBVTT\n\n \t\n" + vttCue)
    add("vtt-note-exact", .webVTT, "WEBVTT\n\nNOTE\n" + vttCue + "\n\n" + secondVTT)
    add("vtt-note-space", .webVTT, "WEBVTT\n\nNOTE comment\n" + vttCue + "\n\n" + secondVTT)
    add("vtt-note-tab", .webVTT, "WEBVTT\n\nNOTE\tcomment\n" + vttCue + "\n\n" + secondVTT)
    add("vtt-note-nbsp-identifier", .webVTT, "WEBVTT\n\nNOTE\u{00A0}comment\n" + vttCue)
    add("vtt-notes-identifier", .webVTT, "WEBVTT\n\nNOTES\n" + vttCue)
    add("vtt-style-block", .webVTT, "WEBVTT\n\nSTYLE\n::cue { color: red; }\n\n" + vttCue)
    add("vtt-region-block", .webVTT, "WEBVTT\n\nREGION\nid:region-one\n\n" + vttCue)
    add("vtt-timing-only", .webVTT, "WEBVTT\n\n" + vttTiming)
    add("vtt-timing-trailing-lf", .webVTT, "WEBVTT\n\n" + vttTiming + "\n")
    add("vtt-body-trailing-lf", .webVTT, "WEBVTT\n\n" + vttCue + "\n")
    add("vtt-invalid-first-arrow", .webVTT, "WEBVTT\n\nbad --> invalid\n" + vttCue + "\n\n" + secondVTT)
    add("vtt-cue-settings", .webVTT, "WEBVTT\n\n" + vttTiming
        + " align:start line:90% position:10%,line-left\nHello\nWorld")
    add("vtt-crlf", .webVTT, changeLineEndings("WEBVTT\n\n" + vttCue + "\n", mode: 1))
    add("vtt-cr", .webVTT, changeLineEndings("WEBVTT\n\n" + vttCue + "\n", mode: 2))
    add("vtt-mixed-endings", .webVTT,
        changeLineEndings("WEBVTT\n\ncue-id\n" + vttCue + "\n\n" + secondVTT, mode: 3))
    add("vtt-unicode-and-escaping", .webVTT,
        "WEBVTT\n\n" + vttTiming + "\n中文 {\\an7} e\u{0301} 👩‍💻\\N\u{2028}end")

    let timingVariants = [
        "00:00:00,000 --> 00:00:02,000", "00:00:00.000 --> 00:00:02.000",
        "00:00.000 --> 00:02.000", " 00:00:00.000 \t--> \t00:00:02.000 ",
        "bad --> invalid", "00:00:01.000 --> 00:00:01.000",
        "00:00:02.000 --> 00:00:01.000",
        "00:00:00.000 --> 00:00:01.000 --> 00:00:02.000",
        " --> 00:00:02.000", "00:00:00.000 --> ", "00:00:00.999 --> 00:00:01.001",
        "00:00:00.000 --> 00:00:02.000 align:start line:80%",
        "00:00:00:00.000 --> 00:00:02.000",
        "\u{00A0}00:00:00.000 --> 00:00:02.000\u{00A0}",
    ]
    let payloadVariants = [
        "", "\n", "\none", "\none\n", "\none\ntwo", "\n \t\ntext",
        "\n{\\an8}x\\Ny\\\\z <i>text</i>", "\ncafé e\u{0301} 中文 👩‍💻",
        "\none\n\nunattached text", "\n" + String(repeating: "abcdef", count: 683),
        "\na --> b", "\n\t",
    ]
    let srtPrefixes = [
        "", "1\n", "ignored\npreamble\n", "\n", " \t\n",
        "invalid --> invalid\n", "unused\n\n1\n",
    ]
    let vttPrefixes = [
        "", "cue-id\n", "\n", " \t\n", "id-one\nid-two\n", "NOTE\n",
        "NOTE comment\n", "NOTE\tcomment\n", "NOTE\u{00A0}comment\n", "STYLE\n",
    ]
    let vttHeaders = [
        "WEBVTT\n\n", "WEBVTT header\n\n", "WEBVTT\tlabel\n\n",
        "\u{FEFF}WEBVTT\n\n", "WEBVTT\n", "WEBVTTx\n\n",
    ]
    try require(fixtures.count < 256, "Authored corpus exceeded fixed size")
    for index in 0..<(256 - fixtures.count) {
        let format: FixtureFormat = index % 2 == 0 ? .srt : .webVTT
        let timing = timingVariants[(index / 2) % timingVariants.count]
        let payload = payloadVariants[(index / 3) % payloadVariants.count]
        var source: String
        if format == .srt {
            source = srtPrefixes[(index / 5) % srtPrefixes.count] + timing + payload
            if index % 5 == 0 { source += "\n\n" + secondSRT }
            if index % 29 == 0 { source = "\u{FEFF}" + source }
        } else {
            source = vttHeaders[(index / 7) % vttHeaders.count]
                + vttPrefixes[(index / 5) % vttPrefixes.count] + timing + payload
            if index % 5 == 0 { source += "\n\n" + secondVTT }
        }
        add("generated-\(index)-\(format.rawValue)", format,
            changeLineEndings(source, mode: index / 11))
    }
    try require(fixtures.count == 256, "Expected 256 compatibility inputs")
    for name in ["srt-short", "vtt-short", "srt-multiline", "srt-dense",
                 "srt-long-line", "invalid-preamble"] {
        fixtures.append(try makeFixture(name))
    }
    try require(Set(fixtures.map(\.id)).count == fixtures.count, "Duplicate case ID")
    return fixtures
}

private func verify() throws -> [String: Any] {
    var rows: [[String: Any]] = []
    for fixture in try verificationFixtures() {
        var row: [String: Any] = [
            "id": fixture.id, "format": fixture.format.rawValue,
            "source": fixture.source, "input_bytes": fixture.source.utf8.count,
            "fixture_checksum": fixtureChecksum(fixture),
        ]
        do {
            let output = try fixture.format.convert(fixture.source)
            row["status"] = "success"
            row["output"] = output
            row["output_bytes"] = output.utf8.count
        } catch let error as ExternalTextSubtitleConverter.ConversionError {
            row["status"] = "error"
            switch error {
            case .missingWebVTTSignature:
                row["error"] = "missingWebVTTSignature"
            case .noValidCues(let format):
                row["error"] = format == .srt ? "noValidCues(srt)" : "noValidCues(webVTT)"
            }
            row["message"] = error.errorDescription
        } catch {
            throw DriverError("Unexpected converter error: \(error)")
        }
        rows.append(row)
    }
    return ["schema_version": 1, "mode": "verify", "case_count": rows.count, "cases": rows]
}

private func measure(_ name: String, iterations: Int) throws -> [String: Any] {
    try require((1...maximumIterations).contains(iterations), "Invalid iteration count")
    let fixture = try makeFixture(name)
    let identity = fixtureChecksum(fixture)
    let first = try consumeConversion(fixture)
    let second = try consumeConversion(fixture)
    try require(first == second, "Warmup metadata changed")
    let expected = second.checksum * UInt64(iterations)
    var checksum: UInt64 = 0
    let cpuStart = try nanoseconds(CLOCK_PROCESS_CPUTIME_ID)
    let wallStart = try nanoseconds(CLOCK_MONOTONIC_RAW)
    for _ in 0..<iterations {
        checksum += try consumeConversion(fixture).checksum
    }
    let wall = try nanoseconds(CLOCK_MONOTONIC_RAW) - wallStart
    let cpu = try nanoseconds(CLOCK_PROCESS_CPUTIME_ID) - cpuStart
    try require(checksum == expected, "Timed checksum changed")
    return [
        "schema_version": 1, "mode": "measure", "case": name,
        "iterations": iterations, "fixture_count": 1, "fixture_checksum": identity,
        "input_bytes": fixture.source.utf8.count, "output_bytes": second.byteCount,
        "cycle_checksum": second.checksum, "checksum": checksum,
        "expected_checksum": expected, "warmup_iterations": 2,
        "wall_ns": wall, "cpu_ns": cpu,
    ]
}

private func memory(_ name: String) throws -> [String: Any] {
    let beforeFixture = try peakRSSBytes()
    let fixture = try makeFixture(name)
    let identity = fixtureChecksum(fixture)
    let before = try peakRSSBytes()
    let output = try fixture.format.convert(fixture.source)
    let observed = stamp(output)
    let peak = try withExtendedLifetime((fixture, output)) { try peakRSSBytes() }
    return [
        "schema_version": 1, "mode": "memory", "case": name,
        "fixture_count": 1, "fixture_checksum": identity,
        "input_bytes": fixture.source.utf8.count, "output_bytes": observed.byteCount,
        "cycle_checksum": observed.checksum, "checksum": observed.checksum,
        "expected_checksum": observed.checksum, "peak_rss_bytes": peak,
        "peak_rss_before_fixture_bytes": beforeFixture,
        "peak_rss_before_conversion_bytes": before,
        "peak_rss_growth_bytes": peak - before,
        "rss_source": "Darwin getrusage(RUSAGE_SELF).ru_maxrss", "rss_unit": "bytes",
    ]
}

@main
private enum SubtitleCueStreamingDriver {
    static func main() {
        do {
            let args = CommandLine.arguments
            let result: [String: Any]
            if args.count == 2, args[1] == "verify" {
                result = try verify()
            } else if args.count == 4, args[1] == "measure", let count = Int(args[3]) {
                result = try measure(args[2], iterations: count)
            } else if args.count == 3, args[1] == "memory" {
                result = try memory(args[2])
            } else {
                throw DriverError("Usage: Driver verify | measure CASE ITERATIONS | memory CASE")
            }
            let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
            print(String(decoding: data, as: UTF8.self))
        } catch {
            FileHandle.standardError.write(Data("SubtitleCueStreaming driver error: \(error)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }
}
