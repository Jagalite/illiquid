import Foundation
import Testing
@testable import IlliquidCore

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
        defaults.setPersistentDomain(["Illiquid.interface-theme.v1": "new"], forName: destination)
        LegacyPreferencesMigration.migrateIfNeeded(defaults: defaults,
            destinationDomain: destination, sourceDomain: source)
        #expect(defaults.string(forKey: "Illiquid.interface-theme.v1") == "new")
        #expect(defaults.data(forKey: "Illiquid.preferences") == payload)
        #expect(defaults.bool(forKey: "Illiquid.controls-always-visible"))
        #expect(defaults.object(forKey: "NSUnrelatedSetting") == nil)
        #expect(defaults.persistentDomain(forName: source)?["Superplayr.interface-theme.v1"] as? String == "old")
        defaults.removeObject(forKey: "Illiquid.preferences")
        LegacyPreferencesMigration.migrateIfNeeded(defaults: defaults,
            destinationDomain: destination, sourceDomain: source)
        #expect(defaults.data(forKey: "Illiquid.preferences") == nil)
    }

    @Test func importsPublishedKeysEvenAfterPreviousMigration() throws {
        let domain = "IlliquidMigration.published.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.setPersistentDomain([
            "Illiquid.legacy-preferences-imported.v1": true,
            "Superplayr.interface-scale.v1": 1.25,
            "Superplayr.playback-state.v1": Data([1, 2, 3]),
        ], forName: domain)
        LegacyPreferencesMigration.migrateIfNeeded(defaults: defaults,
            destinationDomain: domain, sourceDomain: domain)
        #expect(defaults.double(forKey: "Illiquid.interface-scale.v1") == 1.25)
        #expect(defaults.data(forKey: "Illiquid.playback-state.v1") == Data([1, 2, 3]))
    }

    @Test func copiesLegacySessionWithoutReplacingCurrentSession() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = root.appendingPathComponent("Superplayr/PlaybackSession.json")
        let current = root.appendingPathComponent("Illiquid/PlaybackSession.json")
        try FileManager.default.createDirectory(at: legacy.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data([1, 2]).write(to: legacy)
        LegacyPreferencesMigration.migrateSessionIfNeeded(to: current, fileManager: .default)
        #expect(try Data(contentsOf: current) == Data([1, 2]))
        try Data([3, 4]).write(to: current)
        LegacyPreferencesMigration.migrateSessionIfNeeded(to: current, fileManager: .default)
        #expect(try Data(contentsOf: current) == Data([3, 4]))
        #expect(try Data(contentsOf: legacy) == Data([1, 2]))
        try FileManager.default.removeItem(at: current)
        LegacyPreferencesMigration.migrateSessionIfNeeded(to: current, fileManager: .default)
        #expect(!FileManager.default.fileExists(atPath: current.path))
    }
}
