import Foundation
import Testing
@testable import SuperplayrApp

@Suite("Source navigation retention")
struct SourceNavigationStateTests {
    @Test func rootProjectionKeepsTabSelectionIndependentAndDeduplicatesSharedParents() {
        let folder = URL(fileURLWithPath: "/media/shows", isDirectory: true)
        let file = URL(fileURLWithPath: "/media/shows/episode.mkv")
        let tabs = [SourceTab(id: "first", items: [.init(kind: .folder, url: folder), .init(kind: .file, url: file)]),
                    SourceTab(id: "second", items: [.init(kind: .file, url: file)])]
        let index = SourceRootIndex(tabs: tabs)
        #expect(index.folders == [folder])
        #expect(index.watchRoots.map(\.path) == [folder.path])
        #expect(index.byTab["second"]?.folders.isEmpty == true)
        #expect(index.byTab["second"]?.watchRoots.map(\.path) == [folder.path])
        #expect(index.byTab["second"]?.filesByPath[file.path] == tabs[1].items[0])
        #expect(index.byTab["first"]?.filesByPath[folder.path] == nil)
        let removed = SourceRootIndex(tabs: Array(tabs.suffix(1)))
        #expect(removed.byTab["first"] == nil && removed.folders.isEmpty)
    }
    @Test @MainActor func supersededIndexNeverPublishesRemovedItems() async {
        let store = SourceRootIndexStore()
        let old = SourceTab(id: "old", items: (0..<10_000).map {
            .init(kind: .file, url: URL(fileURLWithPath: "/old/\($0).mkv"))
        })
        store.replace(tabs: [old])
        let current = SourceTab(id: "new", items: [.init(kind: .file,
            url: URL(fileURLWithPath: "/new/movie.mkv"))])
        store.replace(tabs: [current])
        #expect(store.snapshot.byTab.isEmpty)
        await store.waitUntilReady()
        #expect(store.isReady)
        #expect(store.snapshot.byTab["old"] == nil)
        #expect(store.snapshot.byTab["new"]?.filesByPath.count == 1)
        store.replace(tabs: [])
        #expect(!store.isReady)
        // Preserve the previous watch roots until replacement is ready; there
        // must not be a transient empty-root publication on ordinary tab edits.
        #expect(store.snapshot.watchRoots.map(\.path) == ["/new"])
        await store.waitUntilReady()
        #expect(store.snapshot.watchRoots.isEmpty)
    }

    @Test func tabsKeepIndependentQueriesAndStableRowIdentitiesAndRetireClosedTabs() {
        var state = SourceNavigationState()
        state.save(.init(query: "episode", rowID: "/shows/episode-20.mkv"), for: "shows", validTabs: ["shows", "films"])
        state.save(.init(query: "film", rowID: "/movies/film.mkv"), for: "films", validTabs: ["shows", "films"])
        #expect(state.location(for: "shows").query == "episode")
        #expect(state.location(for: "shows").rowID == "/shows/episode-20.mkv")
        #expect(state.location(for: "films").query == "film")
        state.save(.init(), for: "films", validTabs: ["films"])
        #expect(state.location(for: "shows") == .init())
        #expect(state.location(for: nil) == .init())
    }
}
