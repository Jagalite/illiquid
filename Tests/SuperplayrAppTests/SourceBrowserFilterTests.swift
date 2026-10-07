import Foundation
import Testing
@testable import SuperplayrApp

@Suite("Source browser background filtering")
struct SourceBrowserFilterTests {
    @Test func expandedFolderCycleDoesNotRecurseOrDuplicateMedia() async throws {
        let root = URL(fileURLWithPath: "/tmp/shows", isDirectory: true)
        let child = root.appendingPathComponent("season", isDirectory: true)
        let file = root.appendingPathComponent("episode.mkv")
        func entry(_ url: URL, folder: Bool) -> SourceTreeEntry {
            .init(url: url, kind: folder ? .folder : .media, dateAdded: nil, creationDate: nil)
        }
        let rootID = SourceTreeIdentity.folderID(for: root)
        let childID = SourceTreeIdentity.folderID(for: child)
        let input = SourceTreeProjectionInput(
            items: [.init(kind: .folder, url: root)], visibility: .default, roots: [root],
            directoryContents: [rootID: [entry(child, folder: true), entry(file, folder: false)],
                                childID: [entry(root, folder: true)]], directoryErrors: [:],
            recursiveMediaEntries: [], expandedFolderIDs: [rootID, childID],
            sortConfiguration: .init(name: .ascending, dateCreated: .off, type: .off))
        let result = try #require(await SourceBrowserFilter().project(input: input, revealsRulePreview: false, query: ""))
        #expect(result.rows.count == 2)
        #expect(result.rows.filter { $0.url == file }.count == 1)
        #expect(Set(result.rows.map(\.id)).count == result.rows.count)
    }

    @Test(arguments: [1_000, 10_000, 100_000])
    func immutableTreeSnapshotBuildsOffUIAndReusesRowsForSearch(count: Int) async throws {
        let filter = SourceBrowserFilter()
        let items = (0..<count).map { index in
            SourceTabItem(kind: .file, url: URL(fileURLWithPath: "/tmp/episode-\(index).mkv"))
        }
        func input(_ items: [SourceTabItem]) -> SourceTreeProjectionInput {
            SourceTreeProjectionInput(items: items, visibility: .default, roots: [],
                directoryContents: [:], directoryErrors: [:], recursiveMediaEntries: [],
                expandedFolderIDs: [], sortConfiguration: .init(name: .ascending, dateCreated: .off, type: .off))
        }
        let clock = ContinuousClock()
        let start = clock.now
        let all = try #require(await filter.project(input: input(items), revealsRulePreview: false, query: ""))
        #expect(all.rows.count == count)
        let matched = try #require(await filter.project(input: input(items), revealsRulePreview: false, query: "episode-\(count - 1)"))
        #expect(matched.rows.map(\.displayName) == ["episode-\(count - 1)"])
        #expect(await filter.treeBuildCount == 1)
        #expect(await filter.visibilityBuildCount == 1)
        let restored = try #require(await filter.project(input: input(items), revealsRulePreview: false, query: " \n"))
        #expect(restored.rows == all.rows)
        #expect(restored.mediaPaths == all.mediaPaths)
        #expect(restored.thumbnailCandidates == all.thumbnailCandidates)
        let changed = try #require(await filter.project(input: input(Array(items.prefix(2))), revealsRulePreview: false, query: ""))
        #expect(changed.rows.count == 2)
        #expect(await filter.treeBuildCount == 2)
        print("SOURCE_TREE_PROJECTION count=\(count) rows_search_and_replacement=\(start.duration(to: clock.now))")
    }

    @Test func searchingReusesVisibilityAndKeepsMatchingAncestors() async throws {
        let filter = SourceBrowserFilter()
        let folder = URL(fileURLWithPath: "/tmp/Shows")
        let rows = [
            SourceTreeDisplayRow(id: "root", folderID: "root", url: folder,
                displayName: "Shows", depth: 0, ancestorIDs: [], kind: .folder(isRoot: true)),
            SourceTreeDisplayRow(id: "episode", folderID: "root", url: folder.appendingPathComponent("Episode.mkv"),
                displayName: "Episode", depth: 1, ancestorIDs: ["root"], kind: .media(dateAdded: nil))
        ]
        _ = await filter.project(rows: rows, configuration: .default, roots: [folder],
                                 revealsRulePreview: false, query: "")
        let searched = try #require(await filter.project(
            rows: rows, configuration: .default, roots: [folder],
            revealsRulePreview: false, query: "episode"
        ))
        #expect(searched.rows.map(\.id) == ["root", "episode"])
        #expect(await filter.visibilityBuildCount == 1)
        var configuration = SourceVisibilityConfiguration.default
        configuration.regexRules = [.init(id: "hide", pattern: "Episode", colorIndex: 0, isEnabled: true)]
        let hidden = try #require(await filter.project(
            rows: rows, configuration: configuration, roots: [folder],
            revealsRulePreview: false, query: "episode"
        ))
        #expect(hidden.rows.isEmpty)
        #expect(hidden.hiddenCount == 1)
        #expect(await filter.visibilityBuildCount == 2)
    }
}
