import Foundation
import Testing
@testable import IlliquidCore

@MainActor
@Suite("Software decoder thread preferences")
struct SoftwareDecoderThreadPreferencesTests {
    @Test func olderPreferencesDefaultToAutomatic() throws {
        let preferences = try JSONDecoder().decode(PlaybackPreferences.self, from: Data("{}".utf8))
        #expect(preferences.softwareDecoderThreadLimit == 0)
        let state = PlaybackState(preferences: preferences)
        let view = PlaybackViewStore(snapshot: PlaybackViewSnapshot(state: state))
        #expect(view.softwareDecoderThreadLimit == 0)
        state.setSoftwareDecoderThreadLimit(3)
        view.publish(PlaybackViewSnapshot(state: state))
        #expect(view.softwareDecoderThreadLimit == 3)
    }

    @Test(arguments: [0, 1, 2, 8, 64])
    func limitSurvivesPersistenceAndStateInitialization(limit: Int) throws {
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PlaybackPersistenceStore(userDefaults: defaults, namespace: "ThreadLimit")
        store.setSoftwareDecoderThreadLimit(limit)
        store.flushSynchronously()
        let reloaded = PlaybackPersistenceStore(userDefaults: defaults, namespace: "ThreadLimit")
        let preferences = reloaded.loadPreferences()
        #expect(preferences.softwareDecoderThreadLimit == limit)
        #expect(preferences.sanitized().softwareDecoderThreadLimit == limit)
        #expect(PlaybackState(preferences: preferences).softwareDecoderThreadLimit == limit)
    }

    @Test(arguments: [-1, Int.min, 65, Int.max])
    func invalidLimitsAreBounded(value: Int) throws {
        let json = Data("{\"softwareDecoderThreadLimit\":\(value)}".utf8)
        let preferences = try JSONDecoder().decode(PlaybackPreferences.self, from: json)
        #expect(preferences.softwareDecoderThreadLimit == (value < 0 ? 0 : 64))
    }
}
