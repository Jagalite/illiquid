import Foundation
import Testing
@testable import IlliquidCore

private final class InterruptedCopyFileManager: FileManager, @unchecked Sendable {
    override func copyItem(at srcURL: URL, to dstURL: URL) throws {
        try Data("partial".utf8).write(to: dstURL)
        throw CocoaError(.fileWriteUnknown)
    }
}

@Suite("Interrupted legacy migration regressions")
struct InterruptedMigrationRegressionTests {
    private func fixture() throws -> (root: URL, legacy: URL, destination: URL, marker: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let legacy = root.appendingPathComponent("Superplayr/session.json")
        let destination = root.appendingPathComponent("Illiquid/session.json")
        try FileManager.default.createDirectory(at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"source":"legacy","position":42}"#.utf8).write(to: legacy)
        return (root, legacy, destination,
                destination.deletingLastPathComponent().appendingPathComponent(".legacy-session-imported.v1"))
    }

    @Test func partialCopyIsNotPublishedAndNextLaunchRetries() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let original = try Data(contentsOf: f.legacy)
        LegacyPreferencesMigration.migrateSessionIfNeeded(to: f.destination, fileManager: InterruptedCopyFileManager())
        #expect(!FileManager.default.fileExists(atPath: f.destination.path))
        #expect(!FileManager.default.fileExists(atPath: f.marker.path))
        #expect(try Data(contentsOf: f.legacy) == original)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: f.destination.deletingLastPathComponent().path)
        #expect(leftovers.isEmpty)
        LegacyPreferencesMigration.migrateSessionIfNeeded(to: f.destination, fileManager: .default)
        #expect(try Data(contentsOf: f.destination) == original)
        #expect(FileManager.default.fileExists(atPath: f.marker.path))
    }

    @Test func publishedSessionSurvivesMissingMarkerAndRetry() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        // Model a restart after publication but before the marker was written.
        try FileManager.default.createDirectory(at: f.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let current = Data(#"{"source":"current","position":77}"#.utf8)
        try current.write(to: f.destination)
        LegacyPreferencesMigration.migrateSessionIfNeeded(to: f.destination, fileManager: .default)
        #expect(try Data(contentsOf: f.destination) == current)
        #expect(FileManager.default.fileExists(atPath: f.marker.path))
        #expect(try String(contentsOf: f.legacy, encoding: .utf8).contains("legacy"))
    }

    @Test func downgradeAndReupgradeDoNotReimportLegacyEdits() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        LegacyPreferencesMigration.migrateSessionIfNeeded(to: f.destination, fileManager: .default)
        let current = Data(#"{"source":"current","position":88}"#.utf8)
        try current.write(to: f.destination)
        let olderBuildEdit = Data(#"{"source":"legacy","position":99}"#.utf8)
        try olderBuildEdit.write(to: f.legacy)
        LegacyPreferencesMigration.migrateSessionIfNeeded(to: f.destination, fileManager: .default)
        #expect(try Data(contentsOf: f.destination) == current)
        #expect(try Data(contentsOf: f.legacy) == olderBuildEdit)
        // This is the migration primitive's contract, not an installed-package test.
    }

    @Test func incompletePreferencesImportPreservesExistingValuesOnRetry() throws {
        let name = "IlliquidMigrationRegression-\(UUID())"
        let source = name + ".legacy"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer {
            defaults.removePersistentDomain(forName: name)
            defaults.removePersistentDomain(forName: source)
        }
        defaults.setPersistentDomain(["Superplayr.volume": 80, "Superplayr.muted": true], forName: source)
        defaults.setPersistentDomain(["Illiquid.volume": 25], forName: name)
        LegacyPreferencesMigration.migrateIfNeeded(defaults: defaults, destinationDomain: name, sourceDomain: source)
        let imported = try #require(defaults.persistentDomain(forName: name))
        #expect(imported["Illiquid.volume"] as? Int == 25)
        #expect(imported["Illiquid.muted"] as? Bool == true)
        defaults.setPersistentDomain(["Superplayr.volume": 99, "Superplayr.muted": false], forName: source)
        LegacyPreferencesMigration.migrateIfNeeded(defaults: defaults, destinationDomain: name, sourceDomain: source)
        let reupgraded = try #require(defaults.persistentDomain(forName: name))
        #expect(reupgraded["Illiquid.volume"] as? Int == 25)
        #expect(reupgraded["Illiquid.muted"] as? Bool == true)
    }
}
