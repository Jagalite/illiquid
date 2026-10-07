import Foundation
import Testing
@testable import IlliquidCore

@Suite("Track selection defaults")
struct TrackSelectionPreferencesTests {
    private func candidate(_ id: Int64, _ kind: MediaTrackKind = .audio, language: String?,
                           defaultTrack: Bool = false, forced: Bool = false,
                           commentary: Bool = false, accessible: Bool = false) -> TrackSelectionCandidate {
        .init(track: MediaTrack(id: id, kind: kind, languageCode: language,
                               isDefault: defaultTrack, isForced: forced),
              isCommentary: commentary, isAccessible: accessible)
    }

    @Test func languageAliasesAndOrderedFallbackSurviveEpisodeTrackReordering() {
        let preferences = TrackSelectionPreferences(audioLanguages: ["ENG", "ja", "en-US", "fr", "und", "nonsense"])
        #expect(preferences.audioLanguages == ["en", "ja", "fr"])
        let first = [candidate(1, language: "ja", defaultTrack: true),
                     candidate(2, language: "en", commentary: true), candidate(3, language: "eng")]
        let next = [candidate(5, language: "eng"), candidate(4, language: "ja", defaultTrack: true),
                    candidate(6, language: "en", commentary: true)]
        #expect(preferences.select(in: first, kind: .audio, fallbackID: 1) == 3)
        #expect(preferences.select(in: next, kind: .audio, fallbackID: 4) == 5)
        #expect(preferences.select(in: [candidate(7, language: "jpn"), candidate(8, language: "fra")],
                                   kind: .audio, fallbackID: 8) == 7)
    }

    @Test func forcedOnlyDoesNotSelectFullOrWrongLanguageSubtitles() {
        let preferences = TrackSelectionPreferences(subtitles: .forcedOnly)
        let tracks = [candidate(1, .subtitle, language: "en", defaultTrack: true),
                      candidate(2, .subtitle, language: "ja", forced: true),
                      candidate(3, .subtitle, language: "eng", forced: true)]
        #expect(preferences.select(in: tracks, kind: .subtitle, fallbackID: 1, audioLanguage: "en") == 3)
        #expect(preferences.select(in: tracks, kind: .subtitle, fallbackID: 1, audioLanguage: "fr") == nil)
        #expect(TrackSelectionPreferences(subtitles: .off).select(in: tracks, kind: .subtitle, fallbackID: 1) == nil)
        #expect(TrackSelectionPreferences().select(in: tracks, kind: .subtitle, fallbackID: 1) == 1)
        #expect(TrackSelectionPreferences().select(in: tracks, kind: .subtitle, fallbackID: nil) == nil)
    }

    @Test func accessibilityFlagsAndDeterministicTies() {
        let tracks = [candidate(8, language: "en", defaultTrack: true),
                      candidate(9, language: "eng", accessible: true), candidate(2, language: "en")]
        #expect(TrackSelectionPreferences(audioLanguages: ["en"], prefersAccessibleTracks: true)
            .select(in: tracks, kind: .audio, fallbackID: 8) == 9)
        #expect(TrackSelectionPreferences().select(in: tracks, kind: .audio, fallbackID: 9) == 8)
        let tied = [candidate(8, language: nil), candidate(2, language: nil)]
        #expect(TrackSelectionPreferences().select(in: tied, kind: .audio, fallbackID: nil) == 2)
    }

    @Test func forcedOnlyCanFilterBitmapEventsButPrefersDedicatedForcedTracks() {
        let bitmap = TrackSelectionCandidate(track: .init(id: 1, kind: .subtitle,
            languageCode: "en", isDefault: true), canFilterForcedEvents: true)
        let fullText = candidate(2, .subtitle, language: "en", defaultTrack: true)
        let forcedText = candidate(3, .subtitle, language: "en", forced: true)
        let preferences = TrackSelectionPreferences(subtitles: .forcedOnly)
        #expect(preferences.select(in: [bitmap, fullText], kind: .subtitle,
                                   fallbackID: 2, audioLanguage: "eng") == 1)
        #expect(preferences.select(in: [bitmap, forcedText], kind: .subtitle,
                                   fallbackID: 1, audioLanguage: "en") == 3)
        #expect(preferences.select(in: [bitmap], kind: .subtitle,
                                   fallbackID: 1, audioLanguage: "ja") == nil)
    }

    @Test func preferencesPersistAcrossUnrelatedSettingsAndLegacyDecode() throws {
        let name = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = PlaybackPersistenceStore(userDefaults: defaults, namespace: name)
        let preferences = TrackSelectionPreferences(audioLanguages: ["ja", "en"], subtitleLanguages: ["en"],
                                                   subtitles: .forcedOnly, prefersAccessibleTracks: true)
        store.setTrackSelectionPreferences(preferences)
        store.setVolume(50)
        store.setPlaybackSpeed(1)
        store.flushSynchronously()
        #expect(PlaybackPersistenceStore(userDefaults: defaults, namespace: name).loadPreferences().trackSelection == preferences)
        #expect(try JSONDecoder().decode(PlaybackPreferences.self, from: Data("{}".utf8)).trackSelection == .init())
    }
}
