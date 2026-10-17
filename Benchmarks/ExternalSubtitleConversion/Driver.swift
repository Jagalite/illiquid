import Dispatch
import Foundation
#if os(Linux)
import Glibc
#else
import Darwin
#endif

private struct Fixture: Sendable {
    let name: String
    let format: ExternalTextSubtitleConverter.Format
    let source: String
}

private struct Workload: Sendable {
    let name: String
    let format: ExternalTextSubtitleConverter.Format
    let cues: Int
    let newline: String
    let profile: String

    func fixture() -> Fixture {
        let source = makeSource(format: format, cues: cues, newline: newline) { index in
            switch profile {
            case "ordinary":
                index % 3 == 0
                    ? ["Look, there is the train.", "We should hurry."]
                    : ["We should leave before sunrise."]
            case "unicode-and-escapes":
                ["Café e\u{301} — 日本語 العربية 👩🏽‍🚀 {literal} \\N",
                 "Paths: C:\\Users\\viewer\\movie.mkv · 👨‍👩‍👧‍👦"]
            case "long-lines":
                [String(repeating: "A long caption without ASS escape characters. ", count: 180)]
            case "long-lines-late-unicode":
                [String(repeating: "A long caption without ASS escape characters. ", count: 180) + "é"]
            case "escape-dense":
                [String(repeating: "\\{\\N}{{}}\\\\", count: 32),
                 String(repeating: "{\\b1}literal{\\b0}\\", count: 16)]
            default:
                fatalError("Unknown payload profile")
            }
        }
        return Fixture(name: name, format: format, source: source)
    }
}

private let workloads: [Workload] = [
    Workload(name: "srt-short-1", format: .srt, cues: 1, newline: "\n", profile: "ordinary"),
    Workload(name: "srt-short-1000", format: .srt, cues: 1_000, newline: "\n", profile: "ordinary"),
    Workload(name: "srt-short-10000", format: .srt, cues: 10_000, newline: "\n", profile: "ordinary"),
    Workload(name: "vtt-short-1", format: .webVTT, cues: 1, newline: "\n", profile: "ordinary"),
    Workload(name: "vtt-short-1000", format: .webVTT, cues: 1_000, newline: "\r\n", profile: "ordinary"),
    Workload(name: "vtt-short-10000", format: .webVTT, cues: 10_000, newline: "\n", profile: "ordinary"),
    Workload(name: "srt-unicode-1000", format: .srt, cues: 1_000, newline: "\r", profile: "unicode-and-escapes"),
    Workload(name: "vtt-unicode-1000", format: .webVTT, cues: 1_000, newline: "\n", profile: "unicode-and-escapes"),
    Workload(name: "srt-long-128", format: .srt, cues: 128, newline: "\n", profile: "long-lines"),
    Workload(name: "srt-long-late-unicode-128", format: .srt, cues: 128, newline: "\n", profile: "long-lines-late-unicode"),
    Workload(name: "vtt-escape-dense-1000", format: .webVTT, cues: 1_000, newline: "\n", profile: "escape-dense"),
]

private func formatName(_ format: ExternalTextSubtitleConverter.Format) -> String {
    format == .srt ? "srt" : "webVTT"
}

private func timestamp(_ milliseconds: Int, format: ExternalTextSubtitleConverter.Format) -> String {
    func padded(_ value: Int, width: Int) -> String {
        let digits = String(value)
        return String(repeating: "0", count: max(0, width - digits.count)) + digits
    }
    let separator = format == .srt ? "," : "."
    return "\(padded(milliseconds / 3_600_000, width: 2)):\(padded(milliseconds / 60_000 % 60, width: 2)):\(padded(milliseconds / 1_000 % 60, width: 2))\(separator)\(padded(milliseconds % 1_000, width: 3))"
}

private func makeSource(
    format: ExternalTextSubtitleConverter.Format,
    cues: Int,
    newline: String,
    payload: (Int) -> [String]
) -> String {
    let blocks = (0..<cues).map { index in
        let identifier = format == .srt ? String(index + 1) : "cue-\(index + 1)"
        let settings = format == .webVTT && index % 4 == 0 ? " align:start position:10%" : ""
        let timing = "\(timestamp(index * 1_500, format: format)) --> \(timestamp(index * 1_500 + 1_200, format: format))\(settings)"
        return ([identifier, timing] + payload(index)).joined(separator: newline)
    }
    let header = format == .webVTT ? "WEBVTT\(newline)\(newline)" : ""
    return header + blocks.joined(separator: newline + newline) + newline
}

// A fixed generator keeps the differential corpus identical across platforms.
private struct Generator {
    var state: UInt64 = 0x5342_544C_2026_1017

    mutating func next(_ upperBound: Int) -> Int {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Int((state >> 32) % UInt64(upperBound))
    }
}

private func differentialFixtures() -> [Fixture] {
    let srtTiming = "00:00:00,000 --> 00:00:01,000"
    let vttTiming = "00:00.000 --> 00:01.000"
    let payloads: [[String]] = [
        [], [""], ["ordinary caption"], ["first", "second", ""],
        ["\\N \\n \\\\ {\\b1}literal{\\b0}"], ["{}\\"],
        [" leading and trailing spaces ", "\tand tabs\t"],
        ["Café e\u{301} Ελληνικά العربية 日本語"], ["👩🏽‍🚀 👨‍👩‍👧‍👦 🏳️‍🌈"],
        ["before\0after", "\u{FEFF}BOM in payload\u{2028}line separator\u{2029}"],
        ["{\u{301}}\u{301}\\\u{301}", "{\u{FE0F}}\u{FE0F}\\\u{FE0F}"],
        ["{\u{20DD}}\u{20DD}\\\u{20DD}", "\u{301}{\u{301}\\\u{301}"],
        ["<i>text &amp; entity</i>", "00:01.000 --> 00:02.000"],
        ["one", "", "text following an empty line"],
        [String(repeating: "\\{}é", count: 257)],
        ["\u{0001}\u{000B}\u{001B}controls", "\u{00A0}\u{200B}\u{2060}"],
    ]
    var fixtures: [Fixture] = []
    for (formatIndex, format) in [ExternalTextSubtitleConverter.Format.srt, .webVTT].enumerated() {
        for (endingIndex, ending) in ["\n", "\r\n", "\r"].enumerated() {
            for (payloadIndex, payload) in payloads.enumerated() {
                fixtures.append(Fixture(
                    name: "payload-\(formatIndex)-\(endingIndex)-\(payloadIndex)", format: format,
                    source: makeSource(format: format, cues: 1, newline: ending) { _ in payload }
                ))
            }
        }
    }

    let raw: [(String, ExternalTextSubtitleConverter.Format, String)] = [
        ("empty-srt", .srt, ""), ("empty-vtt", .webVTT, ""),
        ("missing-signature", .webVTT, vttTiming + "\ntext"),
        ("lowercase-signature", .webVTT, "webvtt\n\n" + vttTiming + "\ntext"),
        ("signature-suffix", .webVTT, "WEBVTTinvalid\n\n" + vttTiming + "\ntext"),
        ("signature-only", .webVTT, "WEBVTT"),
        ("bom-and-metadata", .webVTT, "\u{FEFF}WEBVTT title\nmetadata\n\n" + vttTiming + "\n{payload}"),
        ("tab-signature", .webVTT, "WEBVTT\ttitle\n\n" + vttTiming + "\ntext"),
        ("leading-newline", .webVTT, "\nWEBVTT\n\n" + vttTiming + "\ntext"),
        ("srt-without-number", .srt, srtTiming + "\ntext"),
        ("srt-extra-identifiers", .srt, "anything\nelse\n" + srtTiming + "\ntext"),
        ("vtt-extra-identifiers", .webVTT, "WEBVTT\n\nanything\nelse\n" + vttTiming + "\ntext"),
        ("srt-timing-only", .srt, srtTiming),
        ("vtt-timing-only", .webVTT, "WEBVTT\n\n" + vttTiming),
        ("vtt-note-comment", .webVTT, "WEBVTT\n\nNOTE comment\n" + vttTiming + "\nignored\n\n" + vttTiming + "\nkept"),
        ("vtt-noteworthy-identifier", .webVTT, "WEBVTT\n\nNOTEworthy\n" + vttTiming + "\nkept"),
        ("vtt-style-identifier", .webVTT, "WEBVTT\n\nSTYLE\n" + vttTiming + "\nkept"),
        ("mixed-valid-invalid", .srt, "1\ninvalid --> timing\nskipped\n\n2\n" + srtTiming + "\n\\{kept}"),
    ]
    fixtures += raw.map { Fixture(name: $0.0, format: $0.1, source: $0.2) }
    let timingPairs = [
        ("00:00:00,000", "00:00:00,000"), ("00:00:02,000", "00:00:01,000"),
        ("-1:00:00,000", "00:00:01,000"), ("00:60:00,000", "01:01:00,000"),
        ("00:00:60,000", "00:01:01,000"), ("00:00:00,1", "00:00:00,12"),
        ("00:00:00,0009", "00:00:01,0009"), ("00:00:00", "00:00:01"),
        ("0:00:00,000", "0:00:01,000"), ("00:00:00,000", "00:00:01,000 --> extra"),
        ("99999999999999999999999:00:00,000", "00:00:01,000"),
        ("2147483647:59:59,990", "2147483647:59:59,994"),
        ("2147483647:59:59,990", "2147483647:59:59,995"),
        ("00:00:00,004", "00:00:00,005"), ("00:00:00,999", "00:00:01,000"),
    ]
    for (index, pair) in timingPairs.enumerated() {
        fixtures.append(Fixture(name: "srt-timing-\(index)", format: .srt,
                                source: "1\n\(pair.0) --> \(pair.1)\n{\\payload}"))
        fixtures.append(Fixture(name: "vtt-timing-\(index)", format: .webVTT,
                                source: "WEBVTT\n\n\(pair.0) --> \(pair.1)\n{\\payload}"
                                    .replacingOccurrences(of: ",", with: ".")))
    }

    var generator = Generator()
    let tokens = ["A", " ", "\\", "{", "}", "\t", "é", "e\u{301}", "中", "👩🏽‍🚀", "\0",
                  "\u{FEFF}", "\u{2028}", "\u{2029}", "\u{301}", "\u{FE0F}", "\u{20DD}"]
    for index in 0..<256 {
        let format: ExternalTextSubtitleConverter.Format = index % 2 == 0 ? .srt : .webVTT
        let source = makeSource(format: format, cues: 1 + generator.next(7),
                                newline: ["\n", "\r\n", "\r"][index % 3]) { _ in
            (0..<(1 + generator.next(4))).map { _ in
                (0..<generator.next(90)).map { _ in tokens[generator.next(tokens.count)] }.joined()
            }
        }
        fixtures.append(Fixture(name: "generated-\(index)", format: format, source: source))
    }
    return fixtures
}

private enum DriverError: Error {
    case invalidArguments
    case unknownCase(String)
    case clockUnavailable
}

private func emit(_ value: Any) throws {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([10]))
}

private func errorLabel(_ error: ExternalTextSubtitleConverter.ConversionError) -> String {
    switch error {
    case .missingWebVTTSignature: "missingWebVTTSignature"
    case .noValidCues(.srt): "noValidCues(srt)"
    case .noValidCues(.webVTT): "noValidCues(webVTT)"
    }
}

private func cpuNanoseconds() throws -> UInt64 {
    var value = timespec()
    guard clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &value) == 0 else { throw DriverError.clockUnavailable }
    return UInt64(value.tv_sec) * 1_000_000_000 + UInt64(value.tv_nsec)
}

// Observe each returned String without hashing every output byte in the timer.
// The no-inline boundary also keeps repeated conversions in the measured loop.
@inline(never)
private func convertAndConsume(_ fixture: Fixture) throws -> UInt64 {
    let result = try ExternalTextSubtitleConverter.convert(fixture.source, format: fixture.format)
    let bytes = result.utf8
    return UInt64(bytes.count) &+ UInt64(bytes.first ?? 0) &+ UInt64(bytes.last ?? 0)
}

@main
private struct Driver {
    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        switch arguments.first {
        case "cases":
            try emit(workloads.map { workload -> [String: Any] in
                ["name": workload.name, "format": formatName(workload.format), "cues": workload.cues,
                 "line_ending": workload.newline == "\r\n" ? "CRLF" : workload.newline == "\r" ? "CR" : "LF",
                 "profile": workload.profile, "input_bytes": workload.fixture().source.utf8.count]
            })
        case "verify":
            for fixture in workloads.map({ $0.fixture() }) + differentialFixtures() {
                var receipt: [String: Any] = [
                    "name": fixture.name, "format": formatName(fixture.format),
                    "input_utf8_base64": Data(fixture.source.utf8).base64EncodedString(),
                ]
                do {
                    let output = try ExternalTextSubtitleConverter.convert(fixture.source, format: fixture.format)
                    receipt["output_utf8_base64"] = Data(output.utf8).base64EncodedString()
                    receipt["error"] = NSNull()
                } catch let error as ExternalTextSubtitleConverter.ConversionError {
                    receipt["output_utf8_base64"] = NSNull()
                    receipt["error"] = errorLabel(error)
                }
                try emit(receipt)
            }
        case "time":
            guard arguments.count == 4, let iterations = Int(arguments[2]), iterations > 0,
                  let warmup = Int(arguments[3]), warmup > 0 else { throw DriverError.invalidArguments }
            guard let workload = workloads.first(where: { $0.name == arguments[1] }) else {
                throw DriverError.unknownCase(arguments[1])
            }
            let fixture = workload.fixture() // Source construction is outside both clocks.
            var sink: UInt64 = 0
            for _ in 0..<warmup { sink &+= try convertAndConsume(fixture) }
            let cpuStart = try cpuNanoseconds()
            let wallStart = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<iterations { sink &+= try convertAndConsume(fixture) }
            let wall = DispatchTime.now().uptimeNanoseconds - wallStart
            let cpu = try cpuNanoseconds() - cpuStart
            try emit([
                "case": workload.name, "iterations": iterations, "warmup_iterations": warmup,
                "input_bytes": fixture.source.utf8.count, "wall_nanoseconds": wall,
                "cpu_nanoseconds": cpu, "wall_ns_per_conversion": Double(wall) / Double(iterations),
                "cpu_ns_per_conversion": Double(cpu) / Double(iterations), "output_sink": String(sink),
            ] as [String: Any])
        default:
            throw DriverError.invalidArguments
        }
    }
}
