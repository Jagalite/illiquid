import Foundation
import Testing
@testable import IlliquidNativePlayback

@Suite("External subtitle fixed-width timestamps")
struct ExternalSubtitleTimestampTests {
    private typealias Converter = ExternalTextSubtitleConverter

    private struct Form {
        let format: Converter.Format
        let separator: String
        let includesHours: Bool
    }

    private let forms = [
        Form(format: .srt, separator: ",", includesHours: true),
        Form(format: .srt, separator: ".", includesHours: true),
        Form(format: .webVTT, separator: ".", includesHours: true),
        Form(format: .webVTT, separator: ".", includesHours: false),
    ]

    @Test func everyMillisecondFractionRoundsBothEndpoints() throws {
        for form in forms {
            var cues: [String] = []
            var expected: [String] = []
            for milliseconds in 0..<1_000 {
                let digits = padded(milliseconds, width: 3)
                let clock = form.includesHours ? "12:34:" : "34:"
                cues.append("\(milliseconds)\n\(clock)56\(form.separator)\(digits) --> "
                    + "\(clock)57\(form.separator)\(digits)\nFraction \(milliseconds)")

                // Round half-up to centiseconds. Keep the expected clock fields
                // independent of the converter's timestamp/formatting helpers.
                let rounded = milliseconds / 10 + (milliseconds % 10 >= 5 ? 1 : 0)
                let fraction = padded(rounded % 100, width: 2)
                let hours = form.includesHours ? 12 : 0
                let firstSecond = milliseconds >= 995 ? 57 : 56
                let secondSecond = milliseconds >= 995 ? 58 : 57
                expected.append("Dialogue: 0,\(hours):34:\(firstSecond).\(fraction),"
                    + "\(hours):34:\(secondSecond).\(fraction),Default,,0,0,0,,Fraction \(milliseconds)")
            }
            let input = header(form.format) + cues.joined(separator: "\n\n")
            let output = try Converter.convert(input, format: form.format)
            let wanted = Converter.defaultASSHeader + "\n" + expected.joined(separator: "\n")
            #expect(output.utf8.elementsEqual(wanted.utf8))
        }
    }

    @Test func fixedWidthClocksCarryBeyondTheirInputHourAndMinuteFields() throws {
        for form in forms where form.includesHours {
            try assertCue(
                start: "99:59:58\(form.separator)994",
                end: "99:59:59\(form.separator)999", format: form.format,
                expectedStart: "99:59:58.99", expectedEnd: "100:00:00.00"
            )
            try assertCue(
                start: "99:59:59\(form.separator)995",
                end: "100:00:00\(form.separator)015", format: form.format,
                expectedStart: "100:00:00.00", expectedEnd: "100:00:00.02"
            )
        }
        try assertCue(
            start: "59:59.995", end: "01:00:00.015", format: .webVTT,
            expectedStart: "1:00:00.00", expectedEnd: "1:00:00.02"
        )
    }

    @Test func fixedWidthFieldBoundsAndSeparatorsRemainFormatSpecific() throws {
        for form in forms {
            let prefix = form.includesHours ? "00:" : ""
            for (minutes, seconds, expected) in [
                ("00", "00", "0:00:00.00"),
                ("00", "59", "0:00:59.00"),
                ("59", "00", "0:59:00.00"),
                ("59", "59", "0:59:59.00"),
            ] {
                try assertCue(
                    start: "\(prefix)\(minutes):\(seconds)\(form.separator)000",
                    end: "01:00:00\(form.separator)000", format: form.format,
                    expectedStart: expected, expectedEnd: "1:00:00.00"
                )
            }
            for (minutes, seconds) in [("60", "00"), ("00", "60")] {
                assertRejectedAtEitherEndpoint(
                    "\(prefix)\(minutes):\(seconds)\(form.separator)000", form: form
                )
            }
            if form.format == .webVTT {
                assertRejectedAtEitherEndpoint("\(prefix)00:01,000", form: form)
            }
        }
    }

    @Test func nondigitControlAndUnicodeReplacementsAreRejectedAtEveryPosition() {
        // None of these are trimming whitespace. Replacing an edge digit with
        // a space can legitimately invoke SRT's variable-width fallback.
        let replacements = ["x", "\u{0000}", "\u{0001}", "\u{007F}", "１", "١", "\u{0301}", "🙂"]
        for form in forms {
            let timestamp = (form.includesHours ? "12:34:" : "34:")
                + "56\(form.separator)789"
            for index in timestamp.indices {
                for replacement in replacements {
                    var invalid = timestamp
                    invalid.replaceSubrange(index...index, with: replacement)
                    assertRejectedAtEitherEndpoint(invalid, form: form)
                }
            }
        }
    }

    @Test func whitespaceAndWebVTTSettingsAreNormalizedBeforeParsing() throws {
        for form in forms {
            let clock = form.includesHours ? "12:34:" : "34:"
            let hours = form.includesHours ? 12 : 0
            let settings = form.format == .webVTT ? "\talign:start position:10%" : ""
            try assertCue(
                start: "\u{00A0}\t\(clock)56\(form.separator)005\u{2000}",
                end: "\u{2000}\(clock)57\(form.separator)015\(settings)\t\u{00A0}",
                format: form.format,
                expectedStart: "\(hours):34:56.01", expectedEnd: "\(hours):34:57.02"
            )
        }
    }

    @Test func irregularSubRipFieldsStillUseTheGeneralParser() throws {
        // These include irregular timestamps with the same total lengths as
        // the optimized forms. Length alone must never select their grammar.
        let cases = [
            ("000:00:1,005", "0:00:01.01"),
            ("00:0:01,0000", "0:00:01.00"),
            ("0:0:1,005", "0:00:01.01"),
            ("1:2:3,5", "1:02:03.01"),
        ]
        #expect(cases[0].0.utf8.count == 12)
        #expect(cases[1].0.utf8.count == 12)
        #expect(cases[2].0.utf8.count == 9)
        for (timestamp, expected) in cases {
            for separator in [",", "."] {
                let input = timestamp.replacingOccurrences(of: ",", with: separator)
                try assertCue(
                    start: input, end: "99:00:00\(separator)000", format: .srt,
                    expectedStart: expected, expectedEnd: "99:00:00.00"
                )
                try assertCue(
                    start: "00:00:00\(separator)000", end: input, format: .srt,
                    expectedStart: "0:00:00.00", expectedEnd: expected
                )
            }
        }
        for format in [Converter.Format.srt, .webVTT] {
            try assertCue(
                start: "2147483647:00:01.005", end: "2147483647:00:02.015", format: format,
                expectedStart: "2147483647:00:01.01", expectedEnd: "2147483647:00:02.02"
            )
        }
    }

    @Test func foundationBridgedSourcesPreserveExactOutputBytes() throws {
        let payload = "Café Cafe\u{0301} 日本語"
        for form in forms {
            let clock = form.includesHours ? "12:34:" : "34:"
            let hours = form.includesHours ? 12 : 0
            let input = source(
                start: "\(clock)56\(form.separator)005",
                end: "\(clock)57\(form.separator)015", format: form.format, payload: payload
            )
            let wanted = Converter.defaultASSHeader
                + "\nDialogue: 0,\(hours):34:56.01,\(hours):34:57.02,Default,,0,0,0,," + payload
            // Foundation may make either representation contiguous. This tests
            // interoperability, without assuming which storage path is taken.
            let bridged = NSString(string: input) as String
            for value in [input, bridged] {
                #expect(try Converter.convert(value, format: form.format).utf8.elementsEqual(wanted.utf8))
            }
        }
    }

    private func assertRejectedAtEitherEndpoint(_ timestamp: String, form: Form) {
        let lower = "00:00:00\(form.separator)000"
        let upper = "2147483647:59:59\(form.separator)994"
        for (start, end) in [(timestamp, upper), (lower, timestamp)] {
            #expect(throws: Converter.ConversionError.noValidCues(form.format)) {
                _ = try Converter.convert(source(start: start, end: end, format: form.format), format: form.format)
            }
        }
    }

    private func assertCue(
        start: String, end: String, format: Converter.Format,
        expectedStart: String, expectedEnd: String
    ) throws {
        let wanted = Converter.defaultASSHeader
            + "\nDialogue: 0,\(expectedStart),\(expectedEnd),Default,,0,0,0,,Caption"
        let output = try Converter.convert(source(start: start, end: end, format: format), format: format)
        #expect(output.utf8.elementsEqual(wanted.utf8))
    }

    private func source(
        start: String, end: String, format: Converter.Format, payload: String = "Caption"
    ) -> String {
        header(format) + "1\n\(start) --> \(end)\n\(payload)"
    }

    private func header(_ format: Converter.Format) -> String {
        format == .webVTT ? "WEBVTT\n\n" : ""
    }

    private func padded(_ value: Int, width: Int) -> String {
        let digits = String(value)
        return String(repeating: "0", count: width - digits.count) + digits
    }
}
