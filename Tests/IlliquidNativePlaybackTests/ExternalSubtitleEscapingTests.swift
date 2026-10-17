import Foundation
import Testing
@testable import IlliquidNativePlayback

@Suite("External subtitle payload escaping")
struct ExternalSubtitleEscapingTests {
    private typealias Converter = ExternalTextSubtitleConverter

    @Test func plainUnicodePayloadPreservesExactUTF8() throws {
        // String equality alone would accept normalization of the decomposed é.
        let payload = "Cafe\u{0301} / Café / 日本語 / العربية / עִבְרִית / 𝄞 / 👩🏽‍💻 / ❤️ / \u{0000}"
        try assertPayload(payload, isConvertedTo: payload)
    }

    @Test func adjacentEscapesAreInsertedOnceWithoutReescapingNewBackslashes() throws {
        try assertPayload(
            #"{} \\ \{ \} \N \n \t {x} {{}}"#,
            isConvertedTo: #"\{\} \\\\ \\\{ \\\} \\N \\n \\t \{x\} \{\{\}\}"#
        )
    }

    @Test func unicodeEscapeBoundariesPreserveFoundationMatchingSemantics() throws {
        // Foundation's existing substring matching treats these combining
        // marks differently from a joiner. Byte scanning alone would change
        // the established output for the first three examples.
        let cases = [
            ("\\\u{0301}{\u{0308}}\u{0327} / e\u{0301}",
             "\\\u{0301}{\u{0308}}\u{0327} / e\u{0301}"),
            ("}\u{FE0F}", "}\u{FE0F}"),
            ("{\u{034F}", "{\u{034F}"),
            ("{\u{200D}", "\\{\u{200D}"),
            ("中文 {日本語}", "中文 \\{日本語\\}"),
        ]
        for (payload, expected) in cases {
            try assertPayload(payload, isConvertedTo: expected)
        }
    }

    @Test func multilinePayloadSeparatorsRemainDistinctFromLiteralASSCommands() throws {
        try assertPayload(
            #"first\N{literal}"# + "\n" + #"second\n\N"# + "\n日本語",
            isConvertedTo: #"first\\N\{literal\}\Nsecond\\n\\N\N日本語"#
        )
    }

    @Test func missingEmptyAndTrailingPayloadLinesRetainTheirExistingShape() throws {
        for format in [Converter.Format.srt, .webVTT] {
            // No payload line and one empty payload line both produce an empty
            // event; a final newline after visible text adds one ASS line break.
            let source = sourcePrefix(format)
            try assertConversion(source, format: format, expectedPayload: "")
            try assertConversion(source + "\n", format: format, expectedPayload: "")
            try assertConversion(source + "\nCaption\n", format: format, expectedPayload: #"Caption\N"#)
        }
    }

    @Test func whitespaceAndNonLFLineSeparatorsArePayloadNotParserWhitespace() throws {
        let payload = " \t\u{00A0}First\u{2028}Second\u{2029}Third\u{0085} \t "
        try assertPayload(payload, isConvertedTo: payload)
    }

    @Test func longMultilingualLineWithSparseEscapesKeepsItsEntirePayload() throws {
        let prefix = String(repeating: "e\u{0301}日本語👩🏽‍💻 ", count: 4_096)
        let suffix = String(repeating: " fin", count: 4_096)
        try assertPayload(
            prefix + #"{end}\"# + suffix,
            isConvertedTo: prefix + #"\{end\}\\"# + suffix
        )
    }

    @Test func longDenseEscapesAreNotDroppedOrDuplicatedAtBufferBoundaries() throws {
        try assertPayload(
            String(repeating: #"\{}"#, count: 8_193),
            isConvertedTo: String(repeating: #"\\\{\}"#, count: 8_193)
        )
    }

    private func assertPayload(_ payload: String, isConvertedTo expected: String) throws {
        for format in [Converter.Format.srt, .webVTT] {
            try assertConversion(
                sourcePrefix(format) + "\n" + payload,
                format: format,
                expectedPayload: expected
            )
        }
    }

    private func assertConversion(
        _ source: String, format: Converter.Format, expectedPayload: String
    ) throws {
        let expected = Converter.defaultASSHeader
            + "\nDialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,"
            + expectedPayload
        let actual = try Converter.convert(source, format: format)
        #expect(Array(actual.utf8) == Array(expected.utf8))
    }

    private func sourcePrefix(_ format: Converter.Format) -> String {
        switch format {
        case .srt: "1\n00:00:01,000 --> 00:00:02,000"
        case .webVTT: "WEBVTT\n\n00:01.000 --> 00:02.000"
        }
    }
}
