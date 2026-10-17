import Foundation
import Testing
@testable import IlliquidCore

@Suite("Track selection ranking semantics")
struct TrackSelectionRankingTests {
    private func candidate(
        _ id: Int64,
        kind: MediaTrackKind = .audio,
        language: String? = nil,
        isDefault: Bool = false,
        isForced: Bool = false,
        commentary: Bool = false,
        accessible: Bool = false,
        filtersForcedEvents: Bool = false
    ) -> TrackSelectionCandidate {
        .init(
            track: .init(id: id, kind: kind, languageCode: language,
                         isDefault: isDefault, isForced: isForced),
            isCommentary: commentary,
            isAccessible: accessible,
            canFilterForcedEvents: filtersForcedEvents
        )
    }

    private func permutations<T>(_ values: [T]) -> [[T]] {
        guard !values.isEmpty else { return [[]] }
        return values.indices.flatMap { index in
            var remaining = values
            let first = remaining.remove(at: index)
            return permutations(remaining).map { [first] + $0 }
        }
    }

    @Test func orderedLanguagePreferenceOutranksEveryOtherAudioPreference() {
        let tracks = [
            candidate(99, language: "jpn", commentary: true),
            candidate(1, language: "eng", isDefault: true, accessible: true),
            candidate(0, language: "und", isDefault: true, accessible: true),
        ]
        let japaneseFirst = TrackSelectionPreferences(
            audioLanguages: ["ja", "en"], prefersAccessibleTracks: true
        )
        let englishFirst = TrackSelectionPreferences(
            audioLanguages: ["en", "ja"], prefersAccessibleTracks: true
        )
        for order in permutations(tracks) {
            #expect(japaneseFirst.select(in: order, kind: .audio, fallbackID: 1) == 99)
            #expect(englishFirst.select(in: order, kind: .audio, fallbackID: 99) == 1)
        }
    }

    @Test func commentaryAvoidancePrecedesAccessibilityDefaultAndFallback() {
        let tracks = [
            candidate(20),
            candidate(1, isDefault: true, commentary: true, accessible: true),
        ]
        let avoiding = TrackSelectionPreferences(prefersAccessibleTracks: true)
        let allowing = TrackSelectionPreferences(
            prefersAccessibleTracks: true, avoidsCommentary: false
        )
        for order in permutations(tracks) {
            #expect(avoiding.select(in: order, kind: .audio, fallbackID: 1) == 20)
            #expect(allowing.select(in: order, kind: .audio, fallbackID: 20) == 1)
        }
    }

    @Test func accessibilityMatchesThePolicyBeforeConsideringDefaultOrFallback() {
        let tracks = [candidate(20), candidate(1, isDefault: true, accessible: true)]
        for order in permutations(tracks) {
            #expect(TrackSelectionPreferences().select(
                in: order, kind: .audio, fallbackID: 1
            ) == 20)
            #expect(TrackSelectionPreferences(prefersAccessibleTracks: true).select(
                in: order, kind: .audio, fallbackID: 20
            ) == 1)
        }
    }

    @Test func forcedOnlyPrefersDedicatedTracksAfterAccessibilityBeforeDefault() {
        let tracks = [
            candidate(20, kind: .subtitle, isForced: true),
            candidate(1, kind: .subtitle, isDefault: true,
                      accessible: true, filtersForcedEvents: true),
        ]
        for order in permutations(tracks) {
            #expect(TrackSelectionPreferences(subtitles: .forcedOnly).select(
                in: order, kind: .subtitle, fallbackID: 1
            ) == 20)
            #expect(TrackSelectionPreferences(
                subtitles: .forcedOnly, prefersAccessibleTracks: true
            ).select(in: order, kind: .subtitle, fallbackID: 20) == 1)
        }

        // Equal accessibility exposes the dedicated-forced/default precedence.
        let equallyAccessible = [
            candidate(20, kind: .subtitle, isForced: true),
            candidate(1, kind: .subtitle, isDefault: true, filtersForcedEvents: true),
        ]
        #expect(TrackSelectionPreferences(subtitles: .forcedOnly).select(
            in: equallyAccessible, kind: .subtitle, fallbackID: 1
        ) == 20)
    }

    @Test func defaultSubtitlePrecedesForcedFlagAndFallbackInAlwaysMode() {
        let tracks = [
            candidate(1, kind: .subtitle, isForced: true),
            candidate(20, kind: .subtitle, isDefault: true),
        ]
        for order in permutations(tracks) {
            #expect(TrackSelectionPreferences(subtitles: .always).select(
                in: order, kind: .subtitle, fallbackID: 1
            ) == 20)
        }
    }

    @Test func forcedFlagPrecedesFallbackForSubtitlesAndDoesNotRankAudio() {
        let preferences = TrackSelectionPreferences(subtitles: .always)
        let subtitles = [
            candidate(20, kind: .subtitle, isForced: true),
            candidate(1, kind: .subtitle),
        ]
        let audio = [candidate(20, isForced: true), candidate(1)]
        for order in permutations(subtitles) {
            #expect(preferences.select(in: order, kind: .subtitle, fallbackID: 1) == 20)
        }
        for order in permutations(audio) {
            #expect(preferences.select(in: order, kind: .audio, fallbackID: 1) == 1)
            #expect(preferences.select(in: order, kind: .audio, fallbackID: nil) == 1)
        }
    }

    @Test func fallbackWinsAnEqualRankThenLowestSignedIDBreaksTies() {
        let tracks = [candidate(.min), candidate(0), candidate(.max)]
        let preferences = TrackSelectionPreferences()
        for order in permutations(tracks) {
            #expect(preferences.select(in: order, kind: .audio, fallbackID: Int64.max) == Int64.max)
            #expect(preferences.select(in: order, kind: .audio, fallbackID: 17) == Int64.min)
            #expect(preferences.select(in: order, kind: .audio, fallbackID: nil) == Int64.min)
        }
    }

    @Test func duplicateIDsDoNotDiscardCandidatesWithDifferentMetadata() {
        let tracks = [
            candidate(7, language: "fr", isDefault: true),
            candidate(7, language: "en"),
            candidate(9, language: "ja"),
        ]
        let preferences = TrackSelectionPreferences(audioLanguages: ["en", "ja"])
        for order in permutations(tracks) {
            #expect(preferences.select(in: order, kind: .audio, fallbackID: 9) == 7)
        }
    }

    @Test func emptyAndSingletonCatalogsRetainEligibilityAndPolicySemantics() {
        let always = TrackSelectionPreferences(subtitleLanguages: ["ja"], subtitles: .always)
        #expect(always.select(in: [], kind: .subtitle, fallbackID: 7) == nil)
        #expect(always.select(in: [candidate(99)], kind: .subtitle, fallbackID: 99) == nil)
        let mixed = [candidate(99), candidate(7, kind: .subtitle, language: "fr")]
        #expect(always.select(in: mixed, kind: .subtitle, fallbackID: nil) == 7)
        #expect(TrackSelectionPreferences(audioLanguages: ["ja"]).select(
            in: mixed, kind: .audio, fallbackID: nil
        ) == 99)
        #expect(TrackSelectionPreferences(subtitles: .off).select(
            in: mixed, kind: .subtitle, fallbackID: 7
        ) == nil)
        #expect(TrackSelectionPreferences().select(
            in: mixed, kind: .subtitle, fallbackID: nil
        ) == nil)
        #expect(TrackSelectionPreferences().select(
            in: mixed, kind: .subtitle, fallbackID: 7
        ) == 7)
        #expect(TrackSelectionPreferences(subtitles: .forcedOnly).select(
            in: mixed, kind: .subtitle, fallbackID: 7
        ) == nil)
    }

    @Test func automaticWithoutLanguageOrAccessibilityPolicyUsesOnlyEligibleFallback() {
        let tracks = [
            candidate(1, isDefault: true),
            candidate(2, kind: .subtitle, language: "ja"),
            candidate(3, kind: .subtitle, language: "en", isDefault: true),
            candidate(4, kind: .subtitle, language: "en", accessible: true),
        ]
        let automatic = TrackSelectionPreferences()
        #expect(automatic.select(in: tracks, kind: .subtitle, fallbackID: 1) == nil)
        #expect(automatic.select(in: tracks, kind: .subtitle, fallbackID: nil) == nil)
        #expect(automatic.select(in: tracks, kind: .subtitle, fallbackID: 2) == 2)
        #expect(TrackSelectionPreferences(subtitleLanguages: ["en"]).select(
            in: tracks, kind: .subtitle, fallbackID: 2
        ) == 3)
        #expect(TrackSelectionPreferences(prefersAccessibleTracks: true).select(
            in: tracks, kind: .subtitle, fallbackID: 2
        ) == 4)
    }

    @Test func forcedLanguageFilterUsesExplicitPolicyThenNormalizedAudioLanguage() {
        let tracks = [
            candidate(9, kind: .subtitle, language: "jpn", isDefault: true, isForced: true),
            candidate(1, kind: .subtitle, language: "eng", filtersForcedEvents: true),
            candidate(0, kind: .subtitle, language: "en", isDefault: true),
        ]
        let forced = TrackSelectionPreferences(subtitles: .forcedOnly)
        #expect(forced.select(in: tracks, kind: .subtitle, fallbackID: 0, audioLanguage: "en-US") == 1)
        #expect(forced.select(in: tracks, kind: .subtitle, fallbackID: 1, audioLanguage: "fr") == nil)
        #expect(forced.select(in: tracks, kind: .subtitle, fallbackID: 1, audioLanguage: "und") == 9)
        #expect(TrackSelectionPreferences(subtitleLanguages: ["ja"], subtitles: .forcedOnly).select(
            in: tracks, kind: .subtitle, fallbackID: 1, audioLanguage: "en"
        ) == 9)
        let bitmap = [tracks[1]]
        #expect(forced.select(in: bitmap, kind: .subtitle, fallbackID: nil, audioLanguage: "en") == 1)
        #expect(forced.select(in: bitmap, kind: .subtitle, fallbackID: 1, audioLanguage: "ja") == nil)
    }

    @Test func mutatedAndDecodedPreferencesNormalizeAliasesWithinFirst32Inputs() throws {
        let tracks = [
            candidate(1, language: "jpn"),
            candidate(3, language: "en-GB"),
            candidate(9, language: "fr", isDefault: true),
        ]
        var preferences = TrackSelectionPreferences()
        let invalid = String(repeating: "x", count: 36)
        let raw = [invalid, " ENG ", "en-US", "jpn", "und"]
        preferences.audioLanguages = raw
        #expect(preferences.sanitized().audioLanguages == ["en", "ja"])
        #expect(preferences.select(in: tracks, kind: .audio, fallbackID: 9) == 3)
        #expect(preferences.audioLanguages == raw)
        let decoded = try JSONDecoder().decode(
            TrackSelectionPreferences.self, from: JSONEncoder().encode(preferences)
        )
        #expect(decoded.audioLanguages == raw)
        #expect(decoded.select(in: tracks, kind: .audio, fallbackID: 9) == 3)

        preferences.audioLanguages = Array(repeating: invalid, count: 32) + ["ja"]
        #expect(preferences.select(in: tracks, kind: .audio, fallbackID: nil) == 9)
        preferences.audioLanguages = Array(repeating: invalid, count: 31) + ["ja", "fr"]
        #expect(preferences.select(in: tracks, kind: .audio, fallbackID: 9) == 1)

        preferences.subtitleLanguages = ["und", invalid]
        let subtitles = [candidate(1, kind: .subtitle, language: "ja", isDefault: true)]
        #expect(preferences.select(in: subtitles, kind: .subtitle, fallbackID: nil) == nil)
    }
}
