import Foundation
import Testing
@testable import IlliquidCore

@Suite("Playback product sparse media settings")
struct PlaybackProductMediaSettingsTests {
    @Test func aDelayChoiceDoesNotPinOtherDefaults() throws {
        let value = MediaPlaybackSettings(subtitleDelay: 0.25)
        #expect(value.overriddenFields == [.subtitleDelay])
        #expect(value.audioTrack == nil)
        #expect(value.subtitleTrack == nil)
        #expect(value.effectivePlaybackSpeed(default: 1.5) == 1.5)
        #expect(try JSONDecoder().decode(MediaPlaybackSettings.self, from: JSONEncoder().encode(value)) == value)
    }

    @Test func legacyOffAndZeroDelayRemainExplicit() throws {
        let data = Data(#"{"areSubtitlesVisible":false,"subtitleDelay":0}"#.utf8)
        let value = try JSONDecoder().decode(MediaPlaybackSettings.self, from: data)
        #expect(value.overrides(.subtitles))
        #expect(value.overrides(.subtitleDelay))
        #expect(!value.areSubtitlesVisible)
        #expect(!value.overrides(.playbackSpeed))
    }

    @Test func perFileValuesWinOnlyWhileOverridden() throws {
        var value = MediaPlaybackSettings(playbackSpeed: 1.75, audioDelay: -0.25,
            audioLanguage: "jpn", subtitleLanguage: "eng")
        #expect(value.audioLanguage == "ja")
        #expect(value.subtitleLanguage == "en")
        #expect(value.effectivePlaybackSpeed(default: 1.25) == 1.75)
        #expect(value.effectiveAudioDelay == -0.25)
        value.inherit(.playbackSpeed)
        #expect(value.effectivePlaybackSpeed(default: 1.25) == 1.25)
        for field in MediaPlaybackSetting.allCases { value.inherit(field) }
        #expect(value.isEmpty)
        #expect(value == MediaPlaybackSettings())
    }

    @Test func decodedAndMutatedValuesAreSanitized() throws {
        let json = Data(#"{"subtitleDelay":200,"playbackSpeed":10,"audioDelay":-100,"externalSubtitleURL":"https://example.invalid/a.srt","overriddenFields":["subtitleDelay","playbackSpeed","audioDelay"]}"#.utf8)
        var value = try JSONDecoder().decode(MediaPlaybackSettings.self, from: json)
        #expect(value.subtitleDelay == 10)
        #expect(value.playbackSpeed == 4)
        #expect(value.audioDelay == -10)
        #expect(value.externalSubtitleURL == nil)
        value.subtitleDelay = .nan
        value.audioDelay = .infinity
        value.playbackSpeed = -.infinity
        value = value.sanitized()
        #expect(value.subtitleDelay == 0)
        #expect(value.audioDelay == 0)
        #expect(value.playbackSpeed == 1)
    }

    @Test func explicitZeroDiffersFromInherited() throws {
        let inherited = MediaPlaybackSettings()
        let zero = MediaPlaybackSettings(audioDelay: 0, overriddenFields: [.audioDelay])
        #expect(inherited != zero)
        #expect(!inherited.overrides(.audioDelay))
        #expect(zero.overrides(.audioDelay))
        #expect(try JSONDecoder().decode(MediaPlaybackSettings.self, from: JSONEncoder().encode(zero)) == zero)
    }
}
