import Foundation
import Testing
@testable import SuperplayrCore

struct LegacyPreferencesMigrationTests {
    @Test func importsOnlyPlayerKeysOnceWithoutOverwritingDestinationOrSource() throws {
        let source = "IlliquidMigration.source.\(UUID())"
        let destination = "IlliquidMigration.destination.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: destination))
        defer {
            defaults.removePersistentDomain(forName: source)
            defaults.removePersistentDomain(forName: destination)
        }
        let payload = Data([0, 1, 255])
        defaults.setPersistentDomain([
            "Superplayr.interface-theme.v1": "old",
            "Superplayr.preferences": payload,
            "Platinum.controls-always-visible": true,
            "NSUnrelatedSetting": "do not copy",
        ], forName: source)
        defaults.setPersistentDomain(["Superplayr.interface-theme.v1": "new"], forName: destination)
        LegacyPreferencesMigration.migrateIfNeeded(defaults: defaults,
            destinationDomain: destination, sourceDomain: source)
        #expect(defaults.string(forKey: "Superplayr.interface-theme.v1") == "new")
        #expect(defaults.data(forKey: "Superplayr.preferences") == payload)
        #expect(defaults.bool(forKey: "Platinum.controls-always-visible"))
        #expect(defaults.object(forKey: "NSUnrelatedSetting") == nil)
        #expect(defaults.persistentDomain(forName: source)?["Superplayr.interface-theme.v1"] as? String == "old")
        defaults.removeObject(forKey: "Superplayr.preferences")
        LegacyPreferencesMigration.migrateIfNeeded(defaults: defaults,
            destinationDomain: destination, sourceDomain: source)
        #expect(defaults.data(forKey: "Superplayr.preferences") == nil)
    }
}
