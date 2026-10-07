import Foundation

/// Adopts Illiquid keys while retaining the original settings for older builds.
/// Existing Illiquid values win; legacy domains and files stay intact.
public enum LegacyPreferencesMigration {
    public static let bundleIdentifier = "io.github.jagalite.illiquid"
    public static let legacyBundleIdentifier = "com.example.Superplayr"
    private static let marker = "Illiquid.legacy-preferences-imported.v2"

    public static func migrateIfNeeded(
        defaults: UserDefaults = .standard,
        destinationDomain: String,
        sourceDomain: String = legacyBundleIdentifier
    ) {
        var destination = defaults.persistentDomain(forName: destinationDomain) ?? [:]
        guard destination[marker] as? Bool != true else { return }
        let source = defaults.persistentDomain(forName: sourceDomain) ?? [:]
        // Published Illiquid builds also used these keys in the current domain.
        // Prefer those values over the older development application's domain.
        for values in [destination, source] {
            for (key, value) in values {
                let prefix = ["Superplayr.", "Platinum."].first(where: key.hasPrefix)
                guard let prefix else { continue }
                let renamed = "Illiquid." + key.dropFirst(prefix.count)
                if destination[renamed] == nil { destination[renamed] = value }
            }
        }
        destination[marker] = true
        defaults.setPersistentDomain(destination, forName: destinationDomain)
    }

    public static func migrateSessionIfNeeded(to destination: URL, fileManager: FileManager) {
        let legacy = destination.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Superplayr", isDirectory: true)
            .appendingPathComponent(destination.lastPathComponent)
        let marker = destination.deletingLastPathComponent()
            .appendingPathComponent(".legacy-session-imported.v1")
        guard !fileManager.fileExists(atPath: marker.path) else { return }
        do {
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            if !fileManager.fileExists(atPath: destination.path),
               fileManager.fileExists(atPath: legacy.path) {
                try fileManager.copyItem(at: legacy, to: destination)
            }
            try Data().write(to: marker, options: .atomic)
        } catch {
            // Startup remains available; a later launch can retry the copy.
        }
    }
}
