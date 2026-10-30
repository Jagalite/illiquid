import Foundation
import Testing
@testable import IlliquidApp

@Suite("Source root index reuse")
struct SourceRootIndexReuseTests {
    @Test func visibilityEditsPreserveTheCompletePreparedIndex() {
        let original = fixture()
        let expected = SourceRootIndex(tabs: original)
        var visibility = SourceVisibilityConfiguration.default
        visibility.showsHiddenItems = true
        visibility.manuallyHiddenPaths = ["/Media/one.mkv"]
        visibility.alwaysShownPaths = ["/Media/Shows"]
        visibility.regexRules = [.init(id: "hide", pattern: "two", colorIndex: 1, isEnabled: true)]
        for mode in SourceVisibilityViewMode.allCases {
            visibility.viewMode = mode
            let variants: [SourceVisibilityConfiguration?] = [visibility, nil, .default]
            for value in variants {
                var changed = original
                changed[0].visibility = value
                changed[1].visibility = value
                #expect(SourceRootIndex.canReuseSnapshot(from: original, for: changed))
                expectEquivalent(SourceRootIndex(tabs: changed), expected)
            }
        }
        #expect(original.allSatisfy { $0.visibility == nil })
    }

    @Test func tabOrderCountAndLiteralIdentityRemainInputs() {
        let original = fixture()
        let changes = [
            Array(original.dropLast()),
            original + [SourceTab(id: "empty", items: [])],
            Array(original.reversed()),
            [SourceTab(id: "renamed", items: original[0].items), original[1]],
            [SourceTab(id: original[1].id, items: original[0].items), original[1]],
        ]
        for changed in changes {
            #expect(!SourceRootIndex.canReuseSnapshot(from: original, for: changed))
        }
        let composed = [SourceTab(id: "Café", items: original[0].items)]
        let decomposed = [SourceTab(id: "Cafe\u{301}", items: composed[0].items)]
        #expect(composed[0].id == decomposed[0].id)
        #expect(!SourceRootIndex.canReuseSnapshot(from: composed, for: decomposed))
    }

    @Test func itemEditsDetachSharedStorageWithoutChangingTheOldValue() {
        let original = fixture()
        let expected = SourceRootIndex(tabs: original)
        let edits: [(inout [SourceTab]) -> Void] = [
            { $0[0].items.append(self.item("/Media/new.mkv")) },
            { _ = $0[0].items.removeLast() },
            { $0[0].items.reverse() },
            { $0[0].items[0] = self.item("/Media/replaced.mkv") },
            { $0[0].items[0] = self.item("/Media/one.mkv", .folder) },
        ]
        for edit in edits {
            var changed = original
            edit(&changed)
            #expect(!SourceRootIndex.canReuseSnapshot(from: original, for: changed))
            expectEquivalent(SourceRootIndex(tabs: original), expected)
        }
    }

    @Test func independentEqualItemBuffersConservativelyRebuild() {
        let original = fixture()
        var changed = original
        // Force new storage while retaining the original buffer and all values.
        changed[0].items.reserveCapacity(original[0].items.capacity + 1)
        #expect(changed == original)
        #expect(!SourceRootIndex.canReuseSnapshot(from: original, for: changed))
        expectEquivalent(SourceRootIndex(tabs: changed), SourceRootIndex(tabs: original))
    }

    @Test func emptyItemsIgnoreReservedCapacity() {
        var reserved: [SourceTabItem] = []
        reserved.reserveCapacity(128)
        let original = [SourceTab(id: "empty", items: [])]
        let changed = [SourceTab(id: "empty", items: reserved, visibility: .default)]
        #expect(SourceRootIndex.canReuseSnapshot(from: [], for: []))
        #expect(SourceRootIndex.canReuseSnapshot(from: original, for: changed))
        expectEquivalent(SourceRootIndex(tabs: changed), SourceRootIndex(tabs: original))
    }

    @Test func canonicallyEquivalentDecodedPathsStillRebuild() throws {
        let composed = try decodedItem("/Media/Café.mkv")
        let decomposed = try decodedItem("/Media/Cafe\u{301}.mkv")
        #expect(composed == decomposed)
        let original = [SourceTab(id: "files", items: [composed])]
        let changed = [SourceTab(id: "files", items: [decomposed])]
        #expect(!SourceRootIndex.canReuseSnapshot(from: original, for: changed))
        let index = SourceRootIndex(tabs: changed)
        let stored = try #require(index.byTab["files"]?.filesByPath.values.first)
        #expect(Data(stored.path.utf8) == Data(decomposed.path.utf8))
    }

    @Test func duplicateTabsAndAliasesKeepTheBuildersSelectionRules() throws {
        let alias = try decodedItem("/Media/Season/../movie.mkv")
        let canonical = try decodedItem("/Media/movie.mkv")
        let folder = item("/Media/Shows", .folder)
        let original = [
            SourceTab(id: "duplicate", items: [item("/Media/First", .folder)]),
            SourceTab(id: "duplicate", items: [alias, canonical, folder, folder]),
        ]
        var changed = original
        changed[0].visibility = .default
        changed[1].visibility = .default
        #expect(SourceRootIndex.canReuseSnapshot(from: original, for: changed))
        let index = SourceRootIndex(tabs: changed)
        expectEquivalent(index, SourceRootIndex(tabs: original))
        let lastTab = try #require(index.byTab["duplicate"])
        #expect(lastTab.folders.count == 2)
        let retained = try #require(lastTab.filesByPath["/Media/movie.mkv"])
        #expect(Data(retained.path.utf8) == Data(alias.path.utf8))
        #expect(index.folders.map(\.path) == ["/Media/First", "/Media/Shows"])
    }

    @Test @MainActor func storeStillInitializesAndPublishesTheLatestRequest() async {
        let store = SourceRootIndexStore()
        #expect(!store.isReady)
        store.replace(tabs: [])
        await store.waitUntilReady()
        #expect(store.isReady)
        expectEquivalent(store.snapshot, SourceRootIndex(tabs: []))

        let original = fixture()
        let replacement = [SourceTab(id: "replacement", items: [item("/Other/new.mkv")])]
        store.replace(tabs: original)
        store.replace(tabs: replacement)
        await store.waitUntilReady()
        #expect(store.isReady)
        expectEquivalent(store.snapshot, SourceRootIndex(tabs: replacement))
    }

    private func fixture() -> [SourceTab] {
        [
            SourceTab(id: "one", items: [
                item("/Media/one.mkv"), item("/Media/two.mkv"), item("/Media/Shows", .folder),
            ]),
            SourceTab(id: "two", items: [item("/Archive/movie.mkv"), item("/Archive", .folder)]),
        ]
    }

    private func item(_ path: String, _ kind: SourceTabItem.Kind = .file) -> SourceTabItem {
        SourceTabItem(kind: kind, url: URL(fileURLWithPath: path, isDirectory: kind == .folder))
    }

    private func decodedItem(_ path: String) throws -> SourceTabItem {
        let data = try JSONSerialization.data(withJSONObject: ["kind": "file", "path": path])
        return try JSONDecoder().decode(SourceTabItem.self, from: data)
    }

    private func expectEquivalent(_ actual: SourceRootIndex, _ expected: SourceRootIndex) {
        func urls(_ values: [URL]) -> [Data] { values.map { Data($0.absoluteString.utf8) } }
        func files(_ values: [String: SourceTabItem]) -> [Data: [Data]] {
            Dictionary(uniqueKeysWithValues: values.map {
                (Data($0.key.utf8), [Data($0.value.kind.rawValue.utf8), Data($0.value.path.utf8)])
            })
        }
        #expect(urls(actual.folders) == urls(expected.folders))
        #expect(urls(actual.watchRoots) == urls(expected.watchRoots))
        #expect(Set(actual.byTab.keys.map { Data($0.utf8) })
            == Set(expected.byTab.keys.map { Data($0.utf8) }))
        for (id, roots) in actual.byTab {
            guard let other = expected.byTab[id] else {
                Issue.record("Missing indexed tab")
                continue
            }
            #expect(urls(roots.folders) == urls(other.folders))
            #expect(urls(roots.watchRoots) == urls(other.watchRoots))
            #expect(files(roots.filesByPath) == files(other.filesByPath))
        }
    }
}
