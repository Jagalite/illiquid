import Foundation

/// Copies original player settings when adopting the Illiquid bundle identity.
/// Existing destination values win; the old domain and history file stay intact.
public enum LegacyPreferencesMigration {
    public static let bundleIdentifier = "io.github.jagalite.illiquid"
    public static let legacyBundleIdentifier = "com.example.Superplayr"
    private static let marker = "Illiquid.legacy-preferences-imported.v1"

    public static func migrateIfNeeded(
        defaults: UserDefaults = .standard,
        destinationDomain: String,
        sourceDomain: String = legacyBundleIdentifier
    ) {
        guard destinationDomain != sourceDomain else { return }
        var destination = defaults.persistentDomain(forName: destinationDomain) ?? [:]
        guard destination[marker] as? Bool != true else { return }
        let source = defaults.persistentDomain(forName: sourceDomain) ?? [:]
        for (key, value) in source where key.hasPrefix("Superplayr.") || key.hasPrefix("Platinum.") {
            if destination[key] == nil { destination[key] = value }
        }
        destination[marker] = true
        defaults.setPersistentDomain(destination, forName: destinationDomain)
    }
}
