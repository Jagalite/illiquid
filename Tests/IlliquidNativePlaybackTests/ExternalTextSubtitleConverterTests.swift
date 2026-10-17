import Foundation
import Testing
@testable import IlliquidNativePlayback

@Suite("External text subtitle conversion")
struct ExternalTextSubtitleConverterTests {
    private typealias Converter = ExternalTextSubtitleConverter

    @Test func subRipAndWebVTTKeepEquivalentTimingAndPlainText() throws {
        let srt = """
        1
        00:00:01,005 --> 00:00:03,250
        Café 日本語
        Path \\media {literal}

        2
        00:59:59,995 --> 01:00:02,000
        Second cue
        """
        let vtt = """
        WEBVTT

        first-cue
        00:01.005 --> 00:03.250 align:start position:10% line:90%
        Café 日本語
        Path \\media {literal}

        second-cue
        00:59:59.995 --> 01:00:02.000
        Second cue
        """

        let expected = [
            #"Dialogue: 0,0:00:01.01,0:00:03.25,Default,,0,0,0,,Café 日本語\NPath \\media \{literal\}"#,
            "Dialogue: 0,1:00:00.00,1:00:02.00,Default,,0,0,0,,Second cue",
        ]
        #expect(dialogueLines(try Converter.convert(srt, format: .srt)) == expected)
        #expect(dialogueLines(try Converter.convert(vtt, format: .webVTT)) == expected)
    }

    @Test(arguments: ["\n", "\r\n", "\r"])
    func lineEndingConventionsPreserveMultilineCues(newline: String) throws {
        let lines = ["1", "00:00:01,000 --> 00:00:02,000", "First line", "Second line"]
        let srt = lines.joined(separator: newline)
        let vtt = ["WEBVTT", "", "00:01.000 --> 00:02.000", "First line", "Second line"]
            .joined(separator: newline)
        let expected = [#"Dialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,First line\NSecond line"#]

        #expect(dialogueLines(try Converter.convert(srt, format: .srt)) == expected)
        #expect(dialogueLines(try Converter.convert(vtt, format: .webVTT)) == expected)
    }

    @Test func legacySubRipFractionVariantsRemainSupported() throws {
        let cases = [
            ("00:00:01", "0:00:01.00"),
            ("00:00:01,5", "0:00:01.01"),
            ("00:00:01,50", "0:00:01.05"),
            ("00:00:01.005", "0:00:01.01"),
            ("00:00:01,005999", "0:00:01.01"),
            ("00:00:01,994", "0:00:01.99"),
            ("00:00:01,995", "0:00:02.00"),
        ]
        for (timestamp, expectedStart) in cases {
            let converted = try Converter.convert(
                "1\n\(timestamp) --> 00:00:03,000\nCaption", format: .srt
            )
            #expect(dialogueLines(converted) == [
                "Dialogue: 0,\(expectedStart),0:00:03.00,Default,,0,0,0,,Caption",
            ])
        }
    }

    @Test func acceptsLargeHoursWithoutNarrowingOrLosingCentiseconds() throws {
        for format in [Converter.Format.srt, .webVTT] {
            let separator = format == .srt ? "," : "."
            let source = cue(
                start: "2147483647:59:58\(separator)005",
                end: "2147483647:59:59\(separator)994",
                format: format
            )
            #expect(dialogueLines(try Converter.convert(source, format: format)) == [
                "Dialogue: 0,2147483647:59:58.01,2147483647:59:59.99,Default,,0,0,0,,Caption",
            ])
        }
    }

    @Test(arguments: [
        "nan", "NaN", "inf", "Infinity", "-inf", "-1", "-0", "+1",
        "1e309", "1e3", "-1e309", "0x1p2", "1.5", "wat", "", "１２", "١", "0_0",
    ])
    func nonDecimalComponentsAreRejectedInEitherEndpoint(component: String) {
        for format in [Converter.Format.srt, .webVTT] {
            for field in 0..<3 {
                var parts = ["00", "00", "00"]
                parts[field] = component
                let separator = format == .srt ? "," : "."
                assertRejectedTimestamp(parts.joined(separator: ":") + separator + "000", format: format)
            }
        }
    }

    @Test(arguments: [
        "00:60:00,000", "00:00:60,000", "00:99:00,000", "00:00:99,000",
        "00::01,000", ":00:00:01,000", "00:00:01,000:", "00:00:01,000,001",
        "00:00:01,nan", "00:00:01,inf", "00:00:01,-1", "00:00:01,12x",
        "2147483648:00:00,000", "2147483647:59:59,995",
        "9223372036854775807:00:00,000", "1e308:00:00,000",
    ])
    func malformedSubRipTimestampsAreRejected(timestamp: String) {
        assertRejectedTimestamp(timestamp, format: .srt)
    }

    @Test(arguments: [
        "00:60:00.000", "00:00:60.000", "60:00.000", "00:60.000",
        "00::01.000", ":00:01.000", "00:00:01.000:", "00:00:01.000.001",
        "00:01", "00:01.0", "00:01.00", "00:01.0000", "0:01.000", "00:1.000",
        "00:00:01.nan", "00:00:01.inf", "00:00:01.-01", "00:00:01.12x",
        "2147483648:00:00.000", "2147483647:59:59.995",
        "9223372036854775807:00:00.000", "1e308:00:00.000",
    ])
    func malformedWebVTTTimestampsAreRejected(timestamp: String) {
        assertRejectedTimestamp(timestamp, format: .webVTT)
    }

    @Test func oversizedDecimalFieldsAreRejectedWithoutArithmeticOverflow() {
        let digits = String(repeating: "9", count: 20_000)
        for format in [Converter.Format.srt, .webVTT] {
            for field in 0..<3 {
                var parts = ["00", "00", "00"]
                parts[field] = digits
                let separator = format == .srt ? "," : "."
                assertRejectedTimestamp(parts.joined(separator: ":") + separator + "000", format: format)
            }
        }
    }

    @Test func malformedCuesDoNotPreventLaterValidCuesFromLoading() throws {
        for format in [Converter.Format.srt, .webVTT] {
            let separator = format == .srt ? "," : "."
            let header = format == .webVTT ? "WEBVTT\n\n" : ""
            let source = header + """
            invalid-end
            00:00:01\(separator)000 --> inf:00:00\(separator)000
            Invalid cue must not be shown

            invalid-start
            wat:00:01\(separator)000 --> 00:00:02\(separator)000
            Invalid cue must not be retimed to zero

            good
            00:00:02\(separator)000 --> 00:00:03\(separator)000
            Valid cue survives
            """
            #expect(dialogueLines(try Converter.convert(source, format: format)) == [
                "Dialogue: 0,0:00:02.00,0:00:03.00,Default,,0,0,0,,Valid cue survives",
            ])
        }
    }

    @Test func zeroLengthAndReversedCuesAreNotImported() {
        for format in [Converter.Format.srt, .webVTT] {
            let separator = format == .srt ? "," : "."
            for end in ["00:00:01", "00:00:00"] {
                let source = cue(start: "00:00:01\(separator)000", end: end + separator + "000", format: format)
                #expect(throws: Converter.ConversionError.noValidCues(format)) {
                    _ = try Converter.convert(source, format: format)
                }
            }
        }
    }

    @Test(arguments: ["WEBVTT", "WEBVTT - bilingual captions", "WEBVTT\theader"])
    func optionalUTF8ByteOrderMarkIsAccepted(signature: String) throws {
        let body = signature + "\n\n00:01.000 --> 00:02.000\nCafé 日本語"
        let expected = try Converter.convert(body, format: .webVTT)
        #expect(try Converter.convert("\u{FEFF}" + body, format: .webVTT) == expected)
    }

    @Test(arguments: ["", "WEBVTTgarbage", "WEBVTT2", "webvtt", "NOT WEBVTT"])
    func anExactWebVTTSignatureIsRequired(signature: String) {
        #expect(throws: Converter.ConversionError.missingWebVTTSignature) {
            _ = try Converter.convert(signature + "\n\n00:01.000 --> 00:02.000\nCaption", format: .webVTT)
        }
    }

    @Test func webVTTCommentAndMetadataBlocksCannotBecomeVisibleCues() throws {
        // '-->' is disallowed inside an authored NOTE. Treat malformed NOTE
        // content as a comment instead of promoting timing-looking text to captions.
        let source = """
        WEBVTT

        NOTE a comment containing a timing-looking line
        00:01.000 --> 00:02.000
        Comment must not become a caption

        NOTE
        00:02.000 --> 00:03.000
        Another comment

        STYLE
        ::cue { color: lime; }

        REGION
        id:lower
        width:40%

        NOTEworthy
        00:03.000 --> 00:04.000
        A cue identifier can begin with NOTE
        """
        #expect(dialogueLines(try Converter.convert(source, format: .webVTT)) == [
            "Dialogue: 0,0:00:03.00,0:00:04.00,Default,,0,0,0,,A cue identifier can begin with NOTE",
        ])
    }

    @Test(arguments: ["STYLE", "REGION", " STYLE", "REGION ", "\tREGION"])
    func metadataWordsCanBeCueIdentifiers(identifier: String) throws {
        let source = "WEBVTT\n\n\(identifier)\n00:01.000 --> 00:02.000\nCaption"
        #expect(dialogueLines(try Converter.convert(source, format: .webVTT)) == [
            "Dialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,Caption",
        ])
    }

    @Test func commentsOnlyAndUntimedTextReportNoValidCues() {
        #expect(throws: Converter.ConversionError.noValidCues(.srt)) {
            _ = try Converter.convert("Untimed plain text", format: .srt)
        }
        #expect(throws: Converter.ConversionError.noValidCues(.webVTT)) {
            _ = try Converter.convert("WEBVTT\n\nNOTE\n00:01.000 --> 00:02.000\nComment", format: .webVTT)
        }
    }

    private func assertRejectedTimestamp(_ timestamp: String, format: Converter.Format) {
        let separator = format == .srt ? "," : "."
        let intervals = [
            (timestamp, "2147483647:59:59\(separator)994"),
            ("00:00:00\(separator)000", timestamp),
        ]
        for (start, end) in intervals {
            #expect(throws: Converter.ConversionError.noValidCues(format)) {
                _ = try Converter.convert(cue(start: start, end: end, format: format), format: format)
            }
        }
    }

    private func cue(start: String, end: String, format: Converter.Format) -> String {
        let header = format == .webVTT ? "WEBVTT\n\n" : "1\n"
        return header + start + " --> " + end + "\nCaption"
    }

    private func dialogueLines(_ ass: String) -> [String] {
        ass.components(separatedBy: "\n").filter { $0.hasPrefix("Dialogue:") }
    }
}
