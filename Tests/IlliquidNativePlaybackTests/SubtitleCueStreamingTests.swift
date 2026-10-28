import Foundation
import Testing
@testable import IlliquidNativePlayback

@Suite("External subtitle cue streaming compatibility")
struct SubtitleCueStreamingTests {
    private typealias Format = ExternalTextSubtitleConverter.Format
    private static let dialoguePrefix =
        "\nDialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,"

    @Test func srtFindsTimingAfterLeadingEmptyLinesAndArbitraryPreamble() throws {
        for preamble in ["", "1\n", "arbitrary label\nmetadata\n", "\n",
                         "\n42\n", "\nheading\nanother heading\n"] {
            let source = preamble + timing(for: .srt) + "\nFirst\nSecond"
            #expect(try convert(source, format: .srt) == expected(["First\\NSecond"]))
        }
    }

    @Test func srtDoesNotSearchPastTheFirstArrowContainingLine() throws {
        for invalidFirstLine in ["preamble --> invalid", timing(for: .srt) + " --> extra",
                                 "00:00:02,000 --> 00:00:01,000"] {
            let rejected = invalidFirstLine + "\n" + timing(for: .srt) + "\nIgnored"
            let accepted = timing(for: .srt) + "\nAccepted"
            #expect(try convert(rejected + "\n\n" + accepted, format: .srt)
                    == expected(["Accepted"]))
        }
    }

    @Test func arrowsAfterAcceptedTimingRemainPayload() throws {
        let line = timing(for: .srt)
        let source = line + "\ncaption --> still text\n" + line + "\nlast"
        #expect(try convert(source, format: .srt)
                == expected(["caption --> still text\\N" + line + "\\Nlast"]))
    }

    @Test func webVTTPermitsAtMostOneIdentifierBeforeTiming() throws {
        let cases: [(String, Bool)] = [
            ("", true), ("cue-id\n", true), (" \n", true), ("\ncue-id\n", true),
            ("one\ntwo\n", false), ("prefix --> invalid\n", false),
        ]
        for (prefix, accepts) in cases {
            let target = prefix + timing(for: .webVTT) + "\nTarget"
            let control = timing(for: .webVTT) + "\nControl"
            #expect(try convert(document(target + "\n\n" + control, format: .webVTT),
                                format: .webVTT)
                    == expected(accepts ? ["Target", "Control"] : ["Control"]))
        }
    }

    @Test func webVTTKeepsExistingNotePrefixAndIdentifierRules() throws {
        let cases: [(String, Bool)] = [
            ("NOTE", false), ("NOTE comment", false), ("NOTE\tcomment", false),
            ("NOTE:", true), ("note", true), (" NOTE", true),
            ("NOTE\u{00A0}comment", true), ("STYLE", true), ("REGION", true),
        ]
        for (identifier, accepts) in cases {
            let target = identifier + "\n" + timing(for: .webVTT) + "\nTarget"
            let control = timing(for: .webVTT) + "\nControl"
            #expect(try convert(document(target + "\n\n" + control, format: .webVTT),
                                format: .webVTT)
                    == expected(accepts ? ["Target", "Control"] : ["Control"]))
        }
    }

    @Test func webVTTDiscardsTheCompleteFirstBlockAsHeader() throws {
        for signature in ["WEBVTT", "WEBVTT captions", "WEBVTT\tcaptions", "\u{FEFF}WEBVTT"] {
            let source = signature + "\n" + timing(for: .webVTT)
                + "\nDiscarded with header\n\n" + timing(for: .webVTT) + "\nAccepted"
            #expect(try convert(source, format: .webVTT) == expected(["Accepted"]))
        }
        #expect(throws: ExternalTextSubtitleConverter.ConversionError.noValidCues(.webVTT)) {
            _ = try convert("WEBVTT\n" + timing(for: .webVTT) + "\nNo separate cue block",
                            format: .webVTT)
        }
    }

    @Test func emptyPayloadsStillProduceDialogueEvents() throws {
        for format in [Format.srt, .webVTT] {
            for suffix in ["", "\n", "\n\n", "\n\n\n"] {
                #expect(try convert(document(timing(for: format) + suffix, format: format),
                                    format: format) == expected([""]))
            }
        }
    }

    @Test func aSingleTrailingLineFeedProducesAFinalEmptyPayloadField() throws {
        for format in [Format.srt, .webVTT] {
            for count in 0...6 {
                let body = timing(for: format) + "\nalpha\nbeta" + String(repeating: "\n", count: count)
                let payload = count == 1 ? "alpha\\Nbeta\\N" : "alpha\\Nbeta"
                #expect(try convert(document(body, format: format), format: format)
                        == expected([payload]))
            }
        }
    }

    @Test func repeatedBlockSeparatorsPreserveCueBoundaries() throws {
        for format in [Format.srt, .webVTT] {
            for leadingCount in 0...5 {
                for separatorCount in 2...6 {
                    let body = String(repeating: "\n", count: leadingCount)
                        + timing(for: format) + "\nFirst"
                        + String(repeating: "\n", count: separatorCount)
                        + timing(for: format) + "\nSecond"
                    #expect(try convert(document(body, format: format), format: format)
                            == expected(["First", "Second"]))
                }
            }
        }
    }

    @Test func whitespaceAndUnicodePayloadLinesRetainExactBoundaries() throws {
        let lines = [" ", "\t", "\u{00A0}", "Café / Cafe\u{0301}", "字幕 العربية",
                     "👩🏽‍🚀", "left\u{2028}middle\u{2029}right"]
        for format in [Format.srt, .webVTT] {
            let body = timing(for: format) + "\n" + lines.joined(separator: "\n")
            #expect(try convert(document(body, format: format), format: format)
                    == expected([lines.joined(separator: "\\N")]))
        }
    }

    @Test func newlineNormalizationPrecedesCueLineParsing() throws {
        for format in [Format.srt, .webVTT] {
            let body = timing(for: format) + "\nAlpha\nBeta\n\n"
                + timing(for: format) + "\nGamma\n"
            let normalized = document(body, format: format)
            let separators = ["\r\n", "\n", "\r"]
            var mixed = ""
            for (index, line) in normalized.components(separatedBy: "\n").enumerated() {
                if index > 0 { mixed += separators[(index - 1) % separators.count] }
                mixed += line
            }
            for source in [normalized,
                           normalized.replacingOccurrences(of: "\n", with: "\r\n"),
                           normalized.replacingOccurrences(of: "\n", with: "\r"), mixed] {
                #expect(try convert(source, format: format)
                        == expected(["Alpha\\NBeta", "Gamma\\N"]))
            }
        }
    }

    @Test func largeMultilineCuePreservesEveryLineAndItsFinalEmptyField() throws {
        let lines = (0..<4_096).map { "Line \($0): 字幕 café" }
        for format in [Format.srt, .webVTT] {
            let body = timing(for: format) + "\n" + lines.joined(separator: "\n") + "\n"
            #expect(try convert(document(body, format: format), format: format)
                    == expected([lines.joined(separator: "\\N") + "\\N"]))
        }
    }

    private func timing(for format: Format) -> String {
        switch format {
        case .srt: "00:00:01,000 --> 00:00:02,000"
        case .webVTT: "00:00:01.000 --> 00:00:02.000"
        }
    }

    private func document(_ body: String, format: Format) -> String {
        format == .webVTT ? "WEBVTT\n\n" + body : body
    }

    private func convert(_ source: String, format: Format) throws -> String {
        try ExternalTextSubtitleConverter.convert(source, format: format)
    }

    private func expected(_ payloads: [String]) -> String {
        ExternalTextSubtitleConverter.defaultASSHeader
            + payloads.map { Self.dialoguePrefix + $0 }.joined()
    }
}
