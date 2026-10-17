import Foundation

enum FixtureFormat: String, CaseIterable, Sendable { case srt, webVTT }

struct ConversionFixtureSpec: Sendable {
    let name: String
    let format: FixtureFormat
    let cues: Int
    let payload: String
    let newline: String
}

enum ConversionFixtures {
    static let specs: [ConversionFixtureSpec] = [
        .init(name: "tiny_srt_ascii", format: .srt, cues: 2, payload: "ascii", newline: "\n"),
        .init(name: "tiny_vtt_unicode", format: .webVTT, cues: 2, payload: "unicode", newline: "\n"),
        .init(name: "feature_srt_ascii", format: .srt, cues: 1_500, payload: "ascii", newline: "\n"),
        .init(name: "feature_vtt_ascii", format: .webVTT, cues: 1_500, payload: "ascii", newline: "\n"),
        .init(name: "feature_srt_unicode_crlf", format: .srt, cues: 1_500, payload: "unicode", newline: "\r\n"),
        .init(name: "feature_vtt_unicode", format: .webVTT, cues: 1_500, payload: "unicode", newline: "\n"),
        .init(name: "feature_srt_sparse", format: .srt, cues: 1_500, payload: "sparse", newline: "\n"),
        .init(name: "feature_vtt_sparse_crlf", format: .webVTT, cues: 1_500, payload: "sparse", newline: "\r\n"),
        .init(name: "feature_srt_dense", format: .srt, cues: 1_500, payload: "dense", newline: "\n"),
        .init(name: "feature_vtt_dense_cr", format: .webVTT, cues: 1_500, payload: "dense", newline: "\r"),
        .init(name: "feature_srt_sparse_cr", format: .srt, cues: 1_500, payload: "sparse", newline: "mixed"),
        .init(name: "fallback_srt_late_ascii_crlf", format: .srt, cues: 1_500, payload: "late_ascii", newline: "\r\n"),
        .init(name: "fallback_vtt_late_unicode_crlf", format: .webVTT, cues: 1_500, payload: "late_unicode", newline: "\r\n"),
        .init(name: "large_srt_mixed", format: .srt, cues: 12_000, payload: "mixed", newline: "\n"),
        .init(name: "large_vtt_mixed", format: .webVTT, cues: 12_000, payload: "mixed", newline: "\n"),
    ]

    static func source(_ spec: ConversionFixtureSpec, seed: UInt64) -> String {
        let newline = spec.newline == "mixed" ? "\n" : spec.newline
        var blocks: [String] = []
        blocks.reserveCapacity(spec.cues + 1)
        if spec.format == .webVTT { blocks.append("WEBVTT benchmark\(newline)Kind: captions") }
        for index in 0..<spec.cues {
            let selector = UInt64(index) &+ seed
            let text: String
            switch spec.payload {
            case "ascii":
                text = "A quiet conversation near the river, caption \(index), take \(selector % 17)."
            case "unicode":
                text = "Café 日本語 한국어 العربية हिंदी 🐈 e\u{301}, caption \(index), take \(selector % 17)."
            case "sparse":
                text = selector % 8 == 0
                    ? "Café 日本語, path \\media {literal}, caption \(index)."
                    : "Café 日本語, a quiet conversation near the river, caption \(index)."
            case "dense":
                text = String(repeating: #"\{a}\{b}{{\\}}"#, count: 8) + " 日本語 \(index)"
            case "late_ascii":
                text = String(repeating: "A quiet conversation near the river. ", count: 30) + "\(index)\\"
            case "late_unicode":
                text = String(repeating: "Café 日本語 한국어 العربية 🐈 e\u{301}. ", count: 30) + "\(index){"
            case "mixed":
                let clause = selector % 3 == 0
                    ? "Café 日本語 한국어 🐈, path \\media {literal}, an ordinary spoken sentence. "
                    : "Café 日本語 한국어 🐈, an ordinary spoken sentence beside the river. "
                text = String(repeating: clause, count: 5) + "Caption \(index)."
            default: preconditionFailure("Unknown payload: \(spec.payload)")
            }
            let start = timestamp(milliseconds: index * 2_400 + 5, format: spec.format)
            let end = timestamp(milliseconds: index * 2_400 + 1_805, format: spec.format)
            let settings = spec.format == .webVTT && index % 5 == 0 ? " align:start position:10%" : ""
            let hasSecondLine = spec.payload != "late_ascii" && spec.payload != "late_unicode"
                && (spec.payload == "mixed" || index % 3 == 0)
            let secondLine = hasSecondLine ? "\(newline)Second line \(index)." : ""
            var block = "\(index + 1)\(newline)\(start) --> \(end)\(settings)\(newline)\(text)\(secondLine)"
            // An occasional CR in otherwise-LF input exposes the full fallback
            // scan; it must not be reported as an all-LF fast-path workload.
            if spec.newline == "mixed", index % 97 == 0 {
                block = block.replacingOccurrences(of: "\n", with: "\r")
            }
            blocks.append(block)
        }
        return blocks.joined(separator: newline + newline) + newline
    }

    static func timestamp(milliseconds: Int, format: FixtureFormat) -> String {
        let hours = milliseconds / 3_600_000
        let minutes = (milliseconds / 60_000) % 60
        let seconds = (milliseconds / 1_000) % 60
        let fraction = milliseconds % 1_000
        let separator = format == .srt ? "," : "."
        return "\(pad(hours, width: 2)):\(pad(minutes, width: 2)):\(pad(seconds, width: 2))\(separator)\(pad(fraction, width: 3))"
    }

    private static func pad(_ value: Int, width: Int) -> String {
        let digits = String(value)
        return String(repeating: "0", count: max(0, width - digits.count)) + digits
    }
}

enum ConversionReceipt {
    // Supplemental receipt only. Differential acceptance compares full bytes.
    static func digest<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        var value: UInt64 = 14_695_981_039_346_656_037
        for byte in bytes { value = (value ^ UInt64(byte)) &* 1_099_511_628_211 }
        return String(value, radix: 16)
    }

    static func emit(_ value: [String: Any]) throws {
        let bytes = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        FileHandle.standardOutput.write(bytes)
        FileHandle.standardOutput.write(Data([10]))
    }
}
