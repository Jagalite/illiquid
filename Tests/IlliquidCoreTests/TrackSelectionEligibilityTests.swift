import Foundation
import Testing
@testable import IlliquidCore

@Suite("Track selection eligibility and automatic fallback")
struct TrackSelectionEligibilityTests {
    private func candidate(_ id: Int64, kind: MediaTrackKind, language: String? = nil,
                           isDefault: Bool = false, forced: Bool = false,
                           commentary: Bool = false, accessible: Bool = false,
                           filtersForced: Bool = false) -> TrackSelectionCandidate {
        .init(track: .init(id: id, kind: kind, languageCode: language,
                          isDefault: isDefault, isForced: forced),
              isCommentary: commentary, isAccessible: accessible,
              canFilterForcedEvents: filtersForced)
    }

    @Test func secondEligibleTrackAfterAMixedCatalogStillCompetesByPriority() {
        let subtitles = (0..<32).map {
            candidate(Int64($0), kind: .subtitle, language: "en", isDefault: true)
        }
        let japanese = candidate(100, kind: .audio, language: "ja", commentary: true)
        let english = candidate(200, kind: .audio, language: "en", isDefault: true, accessible: true)
        let preferences = TrackSelectionPreferences(
            audioLanguages: ["ja", "en"], prefersAccessibleTracks: true
        )
        for catalog in [
            subtitles + [english] + subtitles + [japanese],
            subtitles + [japanese] + subtitles + [english],
        ] {
            #expect(preferences.select(in: catalog, kind: .audio, fallbackID: 200) == 100)
        }
        #expect(preferences.select(in: subtitles + [english] + subtitles,
                                   kind: .audio, fallbackID: nil) == 200)
        #expect(preferences.select(in: subtitles, kind: .audio, fallbackID: 0) == nil)
    }

    @Test func forcedEligibilityCountsOnlyAdmittedSubtitles() {
        let rejected = (0..<24).flatMap { index in
            [
                candidate(Int64(index), kind: .audio, language: "en", forced: true),
                candidate(Int64(index + 30), kind: .subtitle, language: "en", isDefault: true),
                candidate(Int64(index + 60), kind: .subtitle, language: "ja", forced: true),
            ]
        }
        let bitmap = candidate(100, kind: .subtitle, language: "eng", isDefault: true, filtersForced: true)
        let dedicated = candidate(200, kind: .subtitle, language: "en", forced: true)
        let preferences = TrackSelectionPreferences(subtitles: .forcedOnly)
        #expect(preferences.select(in: rejected, kind: .subtitle, fallbackID: 30, audioLanguage: "en") == nil)
        #expect(preferences.select(in: rejected + [bitmap] + rejected, kind: .subtitle,
                                   fallbackID: 30, audioLanguage: "en-US") == 100)
        for catalog in [
            rejected + [bitmap] + rejected + [dedicated],
            rejected + [dedicated] + rejected + [bitmap],
        ] {
            #expect(preferences.select(in: catalog, kind: .subtitle,
                                       fallbackID: 100, audioLanguage: "en") == 200)
        }
    }

    @Test func automaticFallbackCanAppearFirstLastOrOnlyInAnotherKind() {
        let preferences = TrackSelectionPreferences()
        let audio = candidate(7, kind: .audio)
        let first = candidate(11, kind: .subtitle)
        let last = candidate(99, kind: .subtitle, isDefault: true)
        let middle = (20..<52).map { candidate(Int64($0), kind: .subtitle, forced: true) }
        let catalog = [audio, first] + middle + [last]
        #expect(preferences.select(in: catalog, kind: .subtitle, fallbackID: 11) == 11)
        #expect(preferences.select(in: catalog, kind: .subtitle, fallbackID: 99) == 99)
        #expect(preferences.select(in: catalog, kind: .subtitle, fallbackID: 7) == nil)
        #expect(preferences.select(in: catalog, kind: .subtitle, fallbackID: nil) == nil)
    }
}
