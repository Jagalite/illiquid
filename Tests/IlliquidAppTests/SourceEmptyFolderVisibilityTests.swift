import Foundation
import Testing
@testable import IlliquidApp

@Suite("Folders without media visibility")
struct SourceEmptyFolderVisibilityTests {
    @Test func emptyListingCannotHideAnUnconfirmedFolder() async throws {
        let root = URL(fileURLWithPath: "/tmp/unconfirmed-source", isDirectory: true)
        let rootID = SourceTreeIdentity.folderID(for: root)
        let other = URL(fileURLWithPath: "/tmp/other.mp4")
        var input = SourceTreeProjectionInput(
            items: [.init(kind: .folder, url: root), .init(kind: .file, url: other)],
            visibility: .default, roots: [root], directoryContents: [rootID: []],
            directoryErrors: [:], recursiveMediaEntries: [], expandedFolderIDs: [],
            sortConfiguration: .init(name: .ascending, dateCreated: .off, type: .off))
        let filter = SourceBrowserFilter()
        let unknown = try #require(await filter.project(input: input, revealsRulePreview: false, query: ""))
        #expect(unknown.rows.contains { $0.folderID == rootID })
        #expect(unknown.hiddenCount == 0)
        input.mediaPresence = [rootID: false]
        let confirmed = try #require(await filter.project(input: input, revealsRulePreview: false, query: ""))
        #expect(!confirmed.rows.contains { $0.folderID == rootID })
        #expect(confirmed.hiddenCount == 1)
    }

    @Test func hideToggleRevealsEmptyFoldersAndAlwaysShowOverridesAutomaticHiding() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SourceEmptyFolders-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let empty = root.appendingPathComponent("Empty", isDirectory: true)
        let notes = root.appendingPathComponent("Notes", isDirectory: true)
        let videos = root.appendingPathComponent("Videos", isDirectory: true)
        let nested = videos.appendingPathComponent("Season", isDirectory: true)
        for folder in [empty, notes, nested] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try Data().write(to: notes.appendingPathComponent("notes.txt"))
        try Data().write(to: notes.appendingPathComponent("subtitles.srt"))
        let media = nested.appendingPathComponent("Episode.MKV")
        try Data().write(to: media)
        let rootID = SourceTreeIdentity.folderID(for: root)
        func input(_ configuration: SourceVisibilityConfiguration) throws -> SourceTreeProjectionInput {
            let cursor = SourceMediaPresenceCursor(root: root)
            var presence: [String: Bool] = [:]
            while true {
                let batch = try cursor.nextBatch()
                presence.merge(batch.results) { _, new in new }
                if batch.isComplete { break }
            }
            return .init(items: [.init(kind: .folder, url: root)], visibility: configuration, roots: [root],
                  directoryContents: [rootID: SourceDirectoryLoader.read(root).entries],
                  directoryErrors: [:], recursiveMediaEntries: [], expandedFolderIDs: [],
                  sortConfiguration: .init(name: .ascending, dateCreated: .off, type: .off),
                  mediaPresence: presence)
        }
        let filter = SourceBrowserFilter()
        let hidden = try #require(await filter.project(input: try input(.default), revealsRulePreview: false, query: ""))
        #expect(hidden.rows.map(\.url) == [videos])
        #expect(hidden.hiddenCount == 2)

        var configuration = SourceVisibilityConfiguration.default
        configuration.showsHiddenItems = true
        let revealed = try #require(await filter.project(input: try input(configuration), revealsRulePreview: false, query: ""))
        #expect(revealed.rows.count == 3)
        #expect(revealed.rows.first { $0.url == empty }?.visibility?.matches == [.noMedia])
        #expect(revealed.hiddenCount == 2)

        configuration.showsHiddenItems = false
        configuration.alwaysShownPaths = [try #require(SourceVisibilityPath.normalized(empty))]
        let overridden = try #require(await filter.project(input: try input(configuration), revealsRulePreview: false, query: ""))
        #expect(Set(overridden.rows.map(\.url)) == [empty, videos])
        #expect(overridden.hiddenCount == 1)

        try FileManager.default.removeItem(at: media)
        let removed = try #require(await filter.project(input: try input(.default), revealsRulePreview: false, query: ""))
        #expect(removed.rows.isEmpty)
        #expect(removed.hiddenCount == 3)
        try Data().write(to: empty.appendingPathComponent("New.mp4"))
        let added = try #require(await filter.project(input: try input(.default), revealsRulePreview: false, query: ""))
        #expect(added.rows.map(\.url) == [empty])
    }

    @Test func unavailableRootAndUnknownCollapsedFolderStayVisible() async throws {
        let root = URL(fileURLWithPath: "/tmp/unavailable-source")
        let file = URL(fileURLWithPath: "/tmp/movie.mkv")
        let rootID = SourceTreeIdentity.folderID(for: root)
        let input = SourceTreeProjectionInput(
            items: [.init(kind: .folder, url: root), .init(kind: .file, url: file)],
            visibility: .default, roots: [root], directoryContents: [rootID: []],
            directoryErrors: [rootID: "Folder unavailable"], recursiveMediaEntries: [],
            expandedFolderIDs: [rootID],
            sortConfiguration: .init(name: .ascending, dateCreated: .off, type: .off))
        let projection = try #require(await SourceBrowserFilter().project(input: input, revealsRulePreview: false, query: ""))
        #expect(projection.rows.count == 3)
        #expect(projection.hiddenCount == 0)

        let unknown = SourceTreeDisplayRow(id: "unknown", folderID: rootID, url: root,
            displayName: "Unknown", depth: 0, ancestorIDs: [], kind: .folder(isRoot: false))
        let collapsed = try #require(await SourceBrowserFilter().project(rows: [unknown],
            configuration: .default, roots: [root], revealsRulePreview: false, query: ""))
        #expect(collapsed.rows == [unknown])
    }

    @Test func recursivePresenceCheckHonorsCancellation() throws {
        struct Cancelled: Error {}
        #expect(throws: Cancelled.self) {
            try SourceMediaPresenceCursor(root: URL(fileURLWithPath: "/tmp")).nextBatch(
                checkCancellation: { throw Cancelled() })
        }
    }
}
