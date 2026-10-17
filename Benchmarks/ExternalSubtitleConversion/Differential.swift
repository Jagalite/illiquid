import Foundation

private enum Outcome: Equatable {
    case output([UInt8])
    case failure(String, [UInt8])
}

private struct Generator {
    var state: UInt64
    mutating func next(_ upper: Int) -> Int {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return Int(state % UInt64(upper))
    }
}

@main
enum ConversionDifferential {
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count == 3, let seed = UInt64(args[1]), let count = Int(args[2]), count >= 0 else {
            fatalError("differential SEED RANDOM_CASES")
        }
        var checked = 0
        var successes = 0
        var errors: [String: Int] = [:]
        var receipts: [UInt8] = []
        func compare(_ label: String, _ source: String, _ format: FixtureFormat, mustSucceed: Bool = false) throws {
            let baseline = old(source, format)
            let candidate = current(source, format)
            guard baseline == candidate else {
                try ConversionReceipt.emit([
                    "status": "failed", "label": label, "format": format.rawValue,
                    "source_utf8_base64": Data(source.utf8).base64EncodedString(),
                    "baseline": describe(baseline), "candidate": describe(candidate),
                ])
                throw NSError(domain: "ConverterDifferential", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Byte/error mismatch: \(label)"])
            }
            checked += 1
            switch candidate {
            case .output(let bytes):
                successes += 1
                receipts.append(contentsOf: ConversionReceipt.digest(bytes).utf8)
            case .failure(let kind, let message):
                precondition(!mustSucceed, "Expected valid fixture: \(label)")
                errors[kind, default: 0] += 1
                receipts.append(contentsOf: kind.utf8)
                receipts.append(contentsOf: message)
            }
            receipts.append(0)
        }

        let atoms = [
            "", "plain text", " ", "\\", "{", "}", "\\N", #"\\{{}}\{\}"#,
            "{\\b1}bold", "\\\u{301}", "{\u{301}", "}\u{301}",
            "\\\u{34F}", "{\u{FE0F}", "}\u{200D}", "{\u{20E3}",
            "Café", "Cafe\u{301}", "日本語", "한국어", "العربية", "हिंदी",
            "𠮷", "🇨🇦", "👩‍👩‍👧‍👦", "\u{0}", "\t", "\u{2028}", "\u{2029}",
            "\u{FEFF}", "\u{202E}abc\u{202C}", "＜｛｝＼＞", "-->", "NOTE", "STYLE",
        ]
        let endings = ["\n", "\r\n", "\r"]
        for format in FixtureFormat.allCases {
            for (endingIndex, ending) in endings.enumerated() {
                for (index, atom) in atoms.enumerated() {
                    try compare("atom-\(format.rawValue)-\(endingIndex)-\(index)",
                                cue(atom + ending + "Following line", format, ending), format,
                                mustSucceed: true)
                }
                for prefix in ["", "e\u{301}", "\u{200D}", "🐈"] {
                    for special in ["\\", "{", "}"] {
                        for suffix in ["", "\u{301}", "\u{34F}", "\u{FE0F}", "\u{200D}", "\u{20E3}", "🇦"] {
                            try compare("grapheme-\(checked)", cue(prefix + special + suffix, format, ending),
                                        format, mustSucceed: true)
                        }
                    }
                }
            }
            let invalids = ["", "nan", "-1", "+1", "1e3", "１２", "2147483648:00:00.000",
                            "00:60:00.000", "00:00:60.000", "00:00:01,000,000"]
            for invalid in invalids {
                let prefix = format == .webVTT ? "WEBVTT\n\n" : "1\n"
                try compare("invalid-\(checked)", prefix + invalid + " --> " + invalid + "\nRejected", format)
            }
            try compare("empty-\(format.rawValue)", "", format)
            try compare("untimed-\(format.rawValue)", "Untimed text\r\n\rOnly text", format)
        }
        for signature in ["WEBVTTgarbage", "WEBVTT2", "webvtt", "\u{FEFF}NOT WEBVTT"] {
            try compare("signature-\(checked)", signature + "\n\n00:01.000 --> 00:02.000\nCaption", .webVTT)
        }
        for header in ["WEBVTT", "\u{FEFF}WEBVTT", "WEBVTT - captions", "WEBVTT\tmetadata"] {
            try compare("vtt-blocks-\(checked)", header + """


            NOTE ignored comment
            00:01.000 --> 00:02.000
            A comment, not a cue

            STYLE
            ::cue { color: lime; }

            NOTEworthy
            00:02.000 --> 00:03.000 align:start
            Visible \\path {literal}
            """, .webVTT, mustSucceed: true)
        }

        var random = Generator(state: seed == 0 ? 0xD1FF_E2E3_17 : seed)
        for index in 0..<count {
            let format = FixtureFormat.allCases[random.next(2)]
            let ending = endings[random.next(endings.count)]
            var payload = ""
            for _ in 0..<(1 + random.next(30)) {
                payload += atoms[random.next(atoms.count)]
                if random.next(9) == 0 { payload += ending }
            }
            var source = cue(payload, format, ending)
            switch index % 11 {
            case 0: source = source.replacingOccurrences(of: "-->", with: "--> -->")
            case 1: source = String(repeating: ending, count: random.next(5)) + source
            case 2: source += ending + ending + cue("Later valid cue", format, ending, includeHeader: false)
            case 3: source = source.replacingOccurrences(of: "00:00:01", with: "00:60:01")
            case 4: source = "NOTE\(ending)" + source
            case 5: source = source.replacingOccurrences(of: "\r\n", with: "\r\n\r")
            default: break
            }
            try compare("random-\(index)", source, format)
        }
        // The complete inputs used for performance also pass exact-byte parity.
        for spec in ConversionFixtures.specs {
            try compare("workload-\(spec.name)", ConversionFixtures.source(spec, seed: seed),
                        spec.format, mustSucceed: true)
        }
        precondition(successes > 0 && !errors.isEmpty)
        try ConversionReceipt.emit([
            "status": "passed", "checked_cases": checked, "successful_conversions": successes,
            "error_cases": errors, "random_cases": count, "seed": String(seed),
            "performance_fixtures": ConversionFixtures.specs.count,
            "receipt_fnv1a64": ConversionReceipt.digest(receipts),
            "acceptance": "Complete UTF-8 output arrays or typed error kind and message bytes are equal",
        ])
    }

    private static func cue(_ payload: String, _ format: FixtureFormat, _ ending: String,
                            includeHeader: Bool = true) -> String {
        let header = format == .webVTT && includeHeader ? "WEBVTT\(ending)\(ending)" : ""
        let separator = format == .srt ? "," : "."
        return header + "identifier\(ending)00:00:01\(separator)005 --> 00:00:03\(separator)250\(ending)" + payload
    }

    private static func old(_ source: String, _ format: FixtureFormat) -> Outcome {
        do {
            return .output(Array(try BaselineExternalTextSubtitleConverter.convert(
                source, format: format == .srt ? .srt : .webVTT).utf8))
        } catch let error as BaselineExternalTextSubtitleConverter.ConversionError {
            let kind: String
            switch error {
            case .missingWebVTTSignature: kind = "missingWebVTTSignature"
            case .noValidCues(.srt): kind = "noValidCues.srt"
            case .noValidCues(.webVTT): kind = "noValidCues.webVTT"
            }
            return .failure(kind, Array((error.errorDescription ?? "").utf8))
        } catch { return .failure("unexpected", Array(String(describing: error).utf8)) }
    }

    private static func current(_ source: String, _ format: FixtureFormat) -> Outcome {
        do {
            return .output(Array(try ExternalTextSubtitleConverter.convert(
                source, format: format == .srt ? .srt : .webVTT).utf8))
        } catch let error as ExternalTextSubtitleConverter.ConversionError {
            let kind: String
            switch error {
            case .missingWebVTTSignature: kind = "missingWebVTTSignature"
            case .noValidCues(.srt): kind = "noValidCues.srt"
            case .noValidCues(.webVTT): kind = "noValidCues.webVTT"
            }
            return .failure(kind, Array((error.errorDescription ?? "").utf8))
        } catch { return .failure("unexpected", Array(String(describing: error).utf8)) }
    }

    private static func describe(_ outcome: Outcome) -> [String: Any] {
        switch outcome {
        case .output(let bytes):
            return ["kind": "output", "bytes": bytes.count,
                    "utf8_base64": Data(bytes).base64EncodedString()]
        case .failure(let kind, let message):
            return ["kind": kind, "message_utf8_base64": Data(message).base64EncodedString()]
        }
    }
}
