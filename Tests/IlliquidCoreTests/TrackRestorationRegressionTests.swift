import Foundation
import Testing
@testable import IlliquidCore

@Suite("Saved track restoration regressions")
struct TrackRestorationRegressionTests {
    @Test(arguments: MediaTrackKind.allCases)
    func unchangedFilePreservesSecondTrackThroughSettingsJSON(kind: MediaTrackKind) throws {
        for hasMetadata in [false, true] {
            let tracks = [Int64(1), 2].map {
                MediaTrack(id: $0, kind: kind, title: hasMetadata ? "Same title" : nil,
                    languageCode: hasMetadata ? "eng" : nil, codec: hasMetadata ? "same" : nil)
            }
            let preference = MediaTrackPreference(track: tracks[1])
            let settings = MediaPlaybackSettings(
                audioTrack: kind == .audio ? preference : nil,
                subtitleTrack: kind == .subtitle ? preference : nil,
                areSubtitlesVisible: false, subtitleDelay: 0.75)
            let data = try JSONEncoder().encode(settings)
            let restored = try JSONDecoder().decode(MediaPlaybackSettings.self, from: data)
            #expect(restored == settings)
            let saved = try #require(kind == .audio ? restored.audioTrack : restored.subtitleTrack)
            #expect(saved.trackID == 2)
            #expect(saved.bestMatch(in: tracks)?.id == 2)
            #expect(saved.bestMatch(in: Array(tracks.reversed()))?.id == 2)
            #expect(!restored.areSubtitlesVisible)
            #expect(restored.subtitleDelay == 0.75)
        }
    }

    @Test(arguments: MediaTrackKind.allCases)
    func distinctiveMetadataSurvivesRenumberingAndReusedID(kind: MediaTrackKind) {
        let preference = MediaTrackPreference(track: MediaTrack(id: 2, kind: kind,
            title: "Commentary", languageCode: "eng", codec: "aac"))
        let reused = MediaTrack(id: 2, kind: kind, title: "Main", languageCode: "jpn", codec: "aac")
        let renumbered = MediaTrack(id: 9, kind: kind, title: "Commentary", languageCode: "eng", codec: "aac")
        #expect(preference.bestMatch(in: [reused, renumbered])?.id == 9)
        #expect(preference.bestMatch(in: [renumbered, reused])?.id == 9)
    }

    @Test func externalFilenameWinsOverAReusedID() {
        let preference = MediaTrackPreference(track: MediaTrack(id: 2, kind: .subtitle,
            isExternal: true, externalFilename: "/media/commentary.srt"))
        let tracks = [
            MediaTrack(id: 2, kind: .subtitle, isExternal: true, externalFilename: "/media/main.srt"),
            MediaTrack(id: 7, kind: .subtitle, isExternal: true, externalFilename: "/media/commentary.srt")
        ]
        #expect(preference.bestMatch(in: tracks)?.id == 7)
    }

    @Test func legacyPreferencesWithoutIDsRemainReadable() throws {
        let json = Data(#"{"kind":"audio","title":"Same","isExternal":false}"#.utf8)
        let preference = try JSONDecoder().decode(MediaTrackPreference.self, from: json)
        #expect(preference.trackID == nil)
        let tracks = [MediaTrack(id: 2, kind: .audio, title: "Same"),
                      MediaTrack(id: 1, kind: .audio, title: "Same")]
        #expect(preference.bestMatch(in: tracks)?.id == 1)
        #expect(preference.bestMatch(in: Array(tracks.reversed()))?.id == 1)
    }

    @Test func IDsDoNotMatchAcrossKindsOrCreateMissingTracks() {
        let preference = MediaTrackPreference(track: MediaTrack(id: 2, kind: .audio))
        #expect(preference.bestMatch(in: []) == nil)
        #expect(preference.bestMatch(in: [MediaTrack(id: 2, kind: .subtitle)]) == nil)
    }

    @Test func ambiguousRenumberingIsOnlyABestEffortFallback() {
        // There is no unique metadata or stable stream identity in this fixture.
        // This specifies deterministic fallback, NOT exact post-remux restoration.
        let preference = MediaTrackPreference(track: MediaTrack(id: 2, kind: .subtitle))
        let tracks = [MediaTrack(id: 10, kind: .subtitle), MediaTrack(id: 9, kind: .subtitle)]
        #expect(preference.bestMatch(in: tracks)?.id == 9)
        #expect(preference.bestMatch(in: Array(tracks.reversed()))?.id == 9)
    }
}
