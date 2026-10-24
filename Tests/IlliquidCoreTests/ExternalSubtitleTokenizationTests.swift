import Foundation
import Testing
@testable import IlliquidCore

@Suite("External subtitle filename tokenization")
struct ExternalSubtitleTokenizationTests {
    @Test func everyASCIIScalarAgreesWithFoundationNormalization() {
        // These are URL values only; no filesystem entries are created. Include
        // control characters and URL-significant punctuation, and apply the
        // reference normalization after the same filename extraction as callers.
        for value in 0..<128 {
            let scalar = String(UnicodeScalar(UInt32(value))!)
            expectReferenceNormalization(
                of: "SentinelALPHA" + scalar + "OMEGA42",
                context: "ASCII scalar \(value)"
            )
        }
        for stem in [
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789",
            "  __ALPHA...---BETA___007++[OMEGA]!!  ",
            "\tALPHA\r\nBETA\u{0000}\u{007F}OMEGA",
            String(repeating: "A", count: 4_096) + "---Tail",
            String(repeating: "A-b_3.", count: 256) + "Tail",
        ] {
            expectReferenceNormalization(of: stem, context: "Mixed ASCII stem")
        }
    }

    @Test func asciiDelimitersKeepSeparateAndConcatenatedTitlesDistinct() {
        let separated = url("Alpha.Omega.mkv")
        let concatenated = url("AlphaOmega.mkv")
        let concatenatedSubtitle = url("ALPHAOMEGA.en.srt")
        let media = [concatenated, separated]

        for value in 0..<128 {
            let scalar = UnicodeScalar(UInt32(value))!
            // Neither NUL nor slash is a filesystem filename character.
            // Foundation preserves NUL as literal "%00" in lastPathComponent;
            // the reference-normalization test above still covers that URL case.
            guard value != 0, scalar != "/", !CharacterSet.alphanumerics.contains(scalar) else { continue }
            let subtitle = url("ALPHA" + String(scalar) + "OMEGA.en.srt")
            let expected: [URL: [URL]] = [
                separated: [subtitle],
                concatenated: [concatenatedSubtitle],
            ]
            #expect(
                ExternalSubtitleMatcher.associate(
                    subtitleURLs: [concatenatedSubtitle, subtitle], with: media
                ) == expected,
                "ASCII delimiter \(value) merged or lost a title token"
            )
        }
    }

    @Test func unicodeNamesRetainFoundationCaseDiacriticAndWidthSemantics() {
        let stems = [
            "ÉPISODE Àçtê Zèbrà",
            "E\u{0301}PISODE A\u{0300}cte\u{0302} Zebra",
            "ＡＢＣ１２３．Ｚｅｂｒａ",
            "İSTANBUL I ı i Zebra",
            "ΣΙΓΜΑ Σ ς σ Zebra",
            "STRAẞE STRASSE Zebra",
            "КИНО Москва Zebra",
            "カ\u{3099}ラス ｶﾞﾗｽ Zebra",
            "한글 漢字 東京 Zebra",
            "ALPHA😀BETA\u{200D}OMEGA",
            "ALPHA\u{00A0}BETA\u{2003}OMEGA",
            "ALPHA—BETA／OMEGA",
            String(repeating: "ASCII-", count: 256) + "Épisode",
            "Épisode" + String(repeating: "-ASCII", count: 256),
        ]
        for (index, stem) in stems.enumerated() {
            expectReferenceNormalization(of: stem, context: "Unicode stem \(index)")
        }
    }

    @Test func unicodeNormalizationStillProducesAmbiguousAndUniqueAssociations() {
        let accented = url("CAFÉ.mkv")
        let wide = url("ＣＡＦＥ.mp4")
        let generic = url("cafe.en.srt")
        let specific = url("ＣＡＦＥ.ＳＰＥＣＩＡＬ.mkv")
        let specificSubtitle = url("Café.Special.en.srt")
        let expected: [URL: [URL]] = [
            accented: [],
            wide: [],
            specific: [specificSubtitle],
        ]
        #expect(ExternalSubtitleMatcher.associate(
            subtitleURLs: [generic, specificSubtitle],
            with: [accented, specific, wide]
        ) == expected)
        #expect(ExternalSubtitleMatcher.associate(
            subtitleURLs: [specificSubtitle, generic],
            with: [wide, specific, accented]
        ) == expected)
    }

    @Test func punctuationOnlyNamesDoNotAcquireTokens() {
        let normalMedia = url("Alpha.mkv")
        let normalSubtitle = url("Alpha.srt")
        for stem in ["", ".", "...", " _-[]()!@#$%^&*+=:;,?{}|~`\t\n\r", "\u{0000}\u{007F}"] {
            #expect(ExternalSubtitleMatcher.matchScore(
                subtitleURL: url(stem + ".srt"), mediaURL: normalMedia
            ) == nil)
            #expect(ExternalSubtitleMatcher.matchScore(
                subtitleURL: normalSubtitle, mediaURL: url(stem + ".mkv")
            ) == nil)
        }
    }

    private func expectReferenceNormalization(of stem: String, context: String) {
        let media = url(stem + ".mkv")
        let subtitle = url(stem + ".srt")
        // Retain the original Foundation transform as an independent oracle.
        // Canonical stems use only dot separators, so changes to case folding,
        // token boundaries, or token contents must still earn the exact score.
        let tokens = media.deletingPathExtension().lastPathComponent
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
            .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: .current)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        #expect(!tokens.isEmpty, "Empty reference fixture: \(context)")
        let canonical = tokens.joined(separator: ".")
        let exactScore = 10_000 + tokens.reduce(0) { $0 + $1.count }
        #expect(ExternalSubtitleMatcher.matchScore(
            subtitleURL: url(canonical + ".srt"), mediaURL: media
        ) == exactScore, "Media normalization: \(context)")
        #expect(ExternalSubtitleMatcher.matchScore(
            subtitleURL: subtitle, mediaURL: url(canonical + ".mkv")
        ) == exactScore, "Subtitle normalization: \(context)")
    }

    private func url(_ filename: String) -> URL {
        URL(fileURLWithPath: "/tmp/SubtitleTokenization", isDirectory: true)
            .appendingPathComponent(filename)
    }
}
