import Foundation
import Testing
@testable import IlliquidApp

@Suite("Playback chrome preferences")
struct PlaybackChromePreferencesTests {
    @Test func absentPreferenceUsesDefaultWithoutWritingIt() throws {
        try withDefaults { defaults, _ in
            #expect(PlaybackChromePreferences.load(defaults: defaults) == 2.5)
            #expect(defaults.object(forKey: PlaybackChromePreferences.storageKey) == nil)
        }
    }

    @Test(arguments: [0.5, 2.5, 7.25, 12.375, 60.0])
    func acceptsBoundaryAndCustomValues(interval: TimeInterval) throws {
        #expect(PlaybackChromePreferences.resolve(interval) == interval)
        try withDefaults { defaults, _ in
            defaults.set(interval, forKey: PlaybackChromePreferences.storageKey)
            #expect(PlaybackChromePreferences.load(defaults: defaults) == interval)
        }
    }

    @Test func savedPreferenceSurvivesReloadAndRemovalRestoresDefault() throws {
        try withDefaults { defaults, suiteName in
            // AppModel owns writes; the preference helper must read the same key.
            defaults.set(7.25, forKey: PlaybackChromePreferences.storageKey)
            let reloaded = try #require(UserDefaults(suiteName: suiteName))
            #expect(PlaybackChromePreferences.load(defaults: reloaded) == 7.25)

            reloaded.removeObject(forKey: PlaybackChromePreferences.storageKey)
            #expect(PlaybackChromePreferences.load(defaults: defaults) == 2.5)
        }
    }

    @Test func acceptsStoredIntegerSeconds() throws {
        try withDefaults { defaults, _ in
            defaults.set(8, forKey: PlaybackChromePreferences.storageKey)
            #expect(PlaybackChromePreferences.load(defaults: defaults) == 8)
        }
    }

    @Test func invalidStoredTypesUseDefault() throws {
        let invalidValues: [Any] = [
            "not a number", "12.5", true, false,
            Data([0x01]), [2.5], ["seconds": 2.5],
        ]
        try withDefaults { defaults, _ in
            for value in invalidValues {
                defaults.set(value, forKey: PlaybackChromePreferences.storageKey)
                #expect(PlaybackChromePreferences.load(defaults: defaults) == 2.5)
            }
        }
    }

    @Test(arguments: [
        TimeInterval.nan, .infinity, -.infinity,
        -1.0, 0.0, 0.4999, 60.0001, .greatestFiniteMagnitude,
    ])
    func nonfiniteAndOutOfRangeValuesUseDefault(interval: TimeInterval) throws {
        #expect(PlaybackChromePreferences.resolve(interval) == 2.5)
        try withDefaults { defaults, _ in
            defaults.set(interval, forKey: PlaybackChromePreferences.storageKey)
            #expect(PlaybackChromePreferences.load(defaults: defaults) == 2.5)
        }
    }

    @Test func loadingInvalidPreferenceDoesNotRewriteStoredValue() throws {
        try withDefaults { defaults, _ in
            defaults.set("invalid", forKey: PlaybackChromePreferences.storageKey)
            #expect(PlaybackChromePreferences.load(defaults: defaults) == 2.5)
            #expect(defaults.string(forKey: PlaybackChromePreferences.storageKey) == "invalid")
        }
    }

    private func withDefaults(_ body: (UserDefaults, String) throws -> Void) throws {
        let suiteName = "PlaybackChromePreferencesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try body(defaults, suiteName)
    }
}
