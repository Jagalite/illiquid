import Foundation
import Testing
@testable import IlliquidApp

@Suite("Source startup snapshot")
struct SourceStartupSnapshotTests {
    private static func isMainThread() -> Bool { Thread.isMainThread }
    @Test func modernTabsWinAndStaleSelectionFallsBackWithoutRewritingDefaults() throws {
        let suite = "SourceStartup-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let tabs = [SourceTab(id: "first", items: []), SourceTab(id: "second", items: [])]
        defaults.set(SourceTabStore.encode(tabs), forKey: SourceStartupSnapshot.tabsKey)
        defaults.set(["/legacy"], forKey: SourceStartupSnapshot.foldersKey)
        defaults.set("second", forKey: SourceStartupSnapshot.activeTabKey)
        #expect(SourceStartupSnapshot.load(defaults: defaults).selectedID == "second")
        defaults.set("missing", forKey: SourceStartupSnapshot.activeTabKey)
        let before = defaults.persistentDomain(forName: suite)! as NSDictionary
        let restored = SourceStartupSnapshot.load(defaults: defaults)
        #expect(restored.tabs == tabs)
        #expect(restored.selectedID == "first")
        #expect(before.isEqual(to: defaults.persistentDomain(forName: suite)!))
    }

    @Test func missingOrMalformedTabsRetainLegacyFoldersAndSelection() throws {
        let suite = "SourceStartup-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["/legacy/a", "/legacy/b"], forKey: SourceStartupSnapshot.foldersKey)
        defaults.set("/legacy/b", forKey: SourceStartupSnapshot.activeFolderKey)
        for corrupt in [false, true] {
            if corrupt { defaults.set(Data("bad json".utf8), forKey: SourceStartupSnapshot.tabsKey) }
            let restored = SourceStartupSnapshot.load(defaults: defaults)
            #expect(restored.tabs.count == 2)
            #expect(restored.selectedID == "folder:/legacy/b")
        }
        defaults.set(SourceTabStore.encode([]), forKey: SourceStartupSnapshot.tabsKey)
        let empty = SourceStartupSnapshot.load(defaults: defaults)
        #expect(empty.tabs.isEmpty && empty.selectedID == nil)
    }

    @Test func largeLibraryRestoresOffMainThreadWithSameContents() async throws {
        let suite = "SourceStartup-\(UUID())"
        let result = try await Task.detached {
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let entries = (0..<100_000).map { ["kind": "file", "path": "/media/episode-\($0).mkv"] }
            let data = try JSONSerialization.data(withJSONObject: [["id": "large", "items": entries]])
            defaults.set(data, forKey: SourceStartupSnapshot.tabsKey)
            let clock = ContinuousClock(), start = ContinuousClock.now
            let snapshot = SourceStartupSnapshot.load(defaults: defaults)
            return (snapshot, Self.isMainThread(), start.duration(to: clock.now))
        }.value
        #expect(!result.1)
        #expect(result.0.tabs.first?.items.count == 100_000)
        #expect(result.0.tabs.first?.items.last?.path == "/media/episode-99999.mkv")
        #expect(result.0.selectedID == "large")
        print("SOURCE_STARTUP rows=100000 worker_duration=\(result.2) main_thread=\(result.1)")
    }
}
