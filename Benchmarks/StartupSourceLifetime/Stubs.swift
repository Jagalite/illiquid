import Foundation

// These dependencies are identical in both variants. They retain no source
// snapshot. The real loader, startup handoff, source payloads and tab-close
// mutation are compiled from the production files/excerpts.
final class PlaybackPersistenceStore: @unchecked Sendable {
    init(userDefaults: UserDefaults) {}
}

@MainActor
final class AtomicPlaybackSessionStore {
    init(fileURL: URL?) {}
}

@MainActor
final class PlaybackController {
    let persistence: PlaybackPersistenceStore
    init(persistence: PlaybackPersistenceStore, sessionStore: AtomicPlaybackSessionStore,
         thumbnailCacheDirectory: URL? = nil) {
        self.persistence = persistence
    }
}

enum LifecyclePerformance {
    static let isEnabled = false
    static func begin(_ phase: String) -> UInt64 { 0 }
    static func end(_ phase: String, since start: UInt64) {}
}

@MainActor
final class SourceRootIndexStore {
    // Real indexing can temporarily retain old values. This focused ownership
    // probe excludes that work and does not claim immediate whole-app release.
    func replace(tabs: [SourceTab]) {}
}

enum AppPreferences {
    static let defaults = FixtureDefaults(fixture: ())
    static let sessionFileURL: URL? = nil
}

enum SourceFixture {
    static let tabID = "startup-tab"
    static let prefix = "/media/startup-lifetime/"
        + String(repeating: "collection-segment-0123456789/", count: 7)

    static var itemCount: Int { Int(CommandLine.arguments[1])! }

    static func path(_ index: Int) -> String {
        let number = String(index)
        return prefix + "episode-" + String(repeating: "0", count: 6 - number.count)
            + number + ".mkv"
    }

    static func data() -> Data {
        var json = "[{\"id\":\"" + tabID + "\",\"items\":["
        json.reserveCapacity(itemCount * (prefix.utf8.count + 60) + 64)
        for index in 0..<itemCount {
            if index != 0 { json.append(",") }
            json.append("{\"kind\":\"file\",\"path\":\"")
            json.append(path(index))
            json.append("\"}")
        }
        json.append("]}]")
        return Data(json.utf8)
    }
}

/// In-memory fixture access only. A fresh named suite satisfies UserDefaults'
/// initializer; all read methods used by SourceStartupSnapshot are overridden,
/// and no production preferences are read or written. The probe never seeds,
/// clears, or writes a persistent domain.
final class FixtureDefaults: UserDefaults, @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0

    init(fixture: Void) { super.init(suiteName: "Illiquid.StartupSourceProbe." + UUID().uuidString)! }

    override func data(forKey key: String) -> Data? {
        guard key == SourceStartupSnapshot.tabsKey else { return nil }
        lock.lock()
        reads += 1
        lock.unlock()
        // The loader's read closure captures no fixture arrays or payloads.
        // JSON and decoding intermediates leave scope before loadShared returns.
        return SourceFixture.data()
    }

    override func string(forKey key: String) -> String? {
        key == SourceStartupSnapshot.activeTabKey ? SourceFixture.tabID : nil
    }

    override func array(forKey key: String) -> [Any]? { nil }

    var sourceReadCount: Int {
        lock.lock(); defer { lock.unlock() }
        return reads
    }
}
