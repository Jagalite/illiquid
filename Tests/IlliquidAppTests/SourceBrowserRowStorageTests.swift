import Foundation
import Testing
@testable import IlliquidApp

// These semantic regressions also run against the pre-optimization source.
// Storage-sharing assertions are isolated in the second suite below.
@Suite("Source browser row projection semantics")
struct SourceBrowserRowSemanticsTests {
    @Test func emptyAndFullyExcludedInputsKeepAccurateCounts() async throws {
        var configuration = SourceVisibilityConfiguration.default
        configuration.regexRules = [
            .init(id: "unused", pattern: "does-not-match", colorIndex: 0, isEnabled: true),
        ]
        let empty = try await RowStorageFixture.project([], configuration: configuration)
        RowStorageFixture.expect(empty, rows: [], regexCounts: ["unused": 0])

        let folders = (0..<5).map {
            RowStorageFixture.row("folder-\($0)", kind: .folder(isRoot: false))
        }
        configuration.viewMode = .filesOnly
        let excluded = try await RowStorageFixture.project(folders, configuration: configuration)
        RowStorageFixture.expect(excluded, rows: [], regexCounts: ["unused": 0])

        let files = RowStorageFixture.files()
        configuration.viewMode = .tree
        configuration.manuallyHiddenPaths = Set(files.map { $0.url.path })
        let hidden = try await RowStorageFixture.project(files, configuration: configuration)
        RowStorageFixture.expect(hidden, rows: [], hiddenCount: files.count,
                                 regexCounts: ["unused": 0])
    }

    @Test(arguments: [0, 2, 4])
    func viewModeExclusionPreservesThePrefixAndSuffix(index: Int) async throws {
        var rows = RowStorageFixture.files()
        rows[index] = RowStorageFixture.row("excluded-folder", kind: .folder(isRoot: false))
        var configuration = SourceVisibilityConfiguration.default
        configuration.viewMode = .filesOnly

        let result = try await RowStorageFixture.project(rows, configuration: configuration)
        let expected = rows.enumerated().filter { $0.offset != index }.map(\.element)
        RowStorageFixture.expect(result, rows: expected)
    }

    @Test(arguments: [0, 2, 4])
    func hiddenExclusionPreservesThePrefixAndSuffix(index: Int) async throws {
        let rows = RowStorageFixture.files()
        var configuration = SourceVisibilityConfiguration.default
        configuration.manuallyHiddenPaths = [rows[index].url.path]

        let result = try await RowStorageFixture.project(rows, configuration: configuration)
        let expected = rows.enumerated().filter { $0.offset != index }.map(\.element)
        RowStorageFixture.expect(result, rows: expected, hiddenCount: 1)
        #expect(rows.allSatisfy { $0.visibility == nil })
    }

    @Test(arguments: [0, 2, 4])
    func revealedVisibilityChangePreservesOtherRows(index: Int) async throws {
        let rows = RowStorageFixture.files()
        var expected = rows
        expected[index].visibility = RowStorageFixture.manualVisibility()
        for preview in [false, true] {
            var configuration = SourceVisibilityConfiguration.default
            configuration.manuallyHiddenPaths = [rows[index].url.path]
            configuration.showsHiddenItems = !preview
            let result = try await RowStorageFixture.project(
                rows, configuration: configuration, revealsRulePreview: preview
            )
            RowStorageFixture.expect(result, rows: expected, hiddenCount: 1)
        }
        #expect(rows.allSatisfy { $0.visibility == nil })
    }

    @Test(arguments: [0, 2, 4])
    func staleInputAnnotationsAreCleared(index: Int) async throws {
        let expected = RowStorageFixture.files()
        var rows = expected
        rows[index].visibility = RowStorageFixture.manualVisibility(inherited: true)

        let result = try await RowStorageFixture.project(rows)
        RowStorageFixture.expect(result, rows: expected)
        #expect(rows[index].visibility == RowStorageFixture.manualVisibility(inherited: true))
    }

    @Test func existingCorrectAnnotationsKeepValuesAndCounts() async throws {
        var rows = RowStorageFixture.files()
        rows[2].visibility = RowStorageFixture.manualVisibility()
        var configuration = SourceVisibilityConfiguration.default
        configuration.manuallyHiddenPaths = [rows[2].url.path]
        configuration.showsHiddenItems = true

        let result = try await RowStorageFixture.project(rows, configuration: configuration)
        RowStorageFixture.expect(result, rows: rows, hiddenCount: 1)
    }

    @Test func alreadyAnnotatedFoldersStillSupplyInheritedVisibility() async throws {
        var parent = RowStorageFixture.row("parent", kind: .folder(isRoot: false))
        parent.visibility = RowStorageFixture.manualVisibility()
        let child = RowStorageFixture.row("child", ancestors: ["parent"])
        let message = RowStorageFixture.row("message", kind: .message("Unavailable"),
                                            ancestors: ["parent"])
        let visible = RowStorageFixture.row("visible")
        let rows = [parent, child, message, visible]
        var configuration = SourceVisibilityConfiguration.default
        configuration.manuallyHiddenPaths = [parent.url.path]
        configuration.showsHiddenItems = true
        var expected = rows
        expected[1].visibility = RowStorageFixture.manualVisibility(inherited: true)
        expected[2].visibility = RowStorageFixture.manualVisibility(inherited: true)

        let revealed = try await RowStorageFixture.project(rows, configuration: configuration)
        RowStorageFixture.expect(revealed, rows: expected, hiddenCount: 2)
        configuration.showsHiddenItems = false
        let hidden = try await RowStorageFixture.project(rows, configuration: configuration)
        RowStorageFixture.expect(hidden, rows: [visible], hiddenCount: 2)
    }

    @Test func emptyFolderHidingRespectsOverridesUnknownPresenceAndPreview() async throws {
        let empty = RowStorageFixture.row("empty", kind: .folder(isRoot: false), containsMedia: false)
        let overridden = RowStorageFixture.row("overridden", kind: .folder(isRoot: false), containsMedia: false)
        let unknown = RowStorageFixture.row("unknown", kind: .folder(isRoot: false))
        let media = RowStorageFixture.row("media")
        let rows = [empty, overridden, unknown, media]
        var configuration = SourceVisibilityConfiguration.default
        configuration.alwaysShownPaths = [overridden.url.path]

        let hidden = try await RowStorageFixture.project(rows, configuration: configuration)
        RowStorageFixture.expect(hidden, rows: [overridden, unknown, media], hiddenCount: 1)

        var expected = rows
        expected[0].visibility = SourceRowVisibility(matches: [.noMedia], isInherited: false)
        let preview = try await RowStorageFixture.project(
            rows, configuration: configuration, revealsRulePreview: true
        )
        RowStorageFixture.expect(preview, rows: expected, hiddenCount: 1)
    }

    @Test func hiddenAncestorsKeepTheirAnnotationsAndDirectRegexCounts() async throws {
        let folder = RowStorageFixture.row("hidden", kind: .folder(isRoot: true),
                                           path: "Hidden", containsMedia: true)
        let child = RowStorageFixture.row("child", ancestors: ["missing", "hidden"],
                                          path: "Hidden/keep.mkv")
        let message = RowStorageFixture.row("message", kind: .message("Unavailable"),
                                            ancestors: ["hidden"], path: "Hidden/status")
        let section = RowStorageFixture.row("section", kind: .mediaSection,
                                            ancestors: ["hidden"], path: "Hidden/section")
        let visible = RowStorageFixture.row("visible", path: "keep-public.mkv")
        let otherFolder = RowStorageFixture.row("other", kind: .folder(isRoot: false),
                                                containsMedia: true)
        let rows = [folder, child, message, section, visible, otherFolder]
        var configuration = SourceVisibilityConfiguration.default
        configuration.manuallyHiddenPaths = [folder.url.path]
        configuration.alwaysShownPaths = [visible.url.path]
        configuration.regexRules = [
            .init(id: "keep", pattern: "keep", colorIndex: 2, isEnabled: true),
            .init(id: "disabled", pattern: ".*", colorIndex: 1, isEnabled: false),
            .init(id: "invalid", pattern: "[", colorIndex: 0, isEnabled: true),
        ]
        let counts = ["keep": 2, "disabled": 0, "invalid": 0]
        let hidden = try await RowStorageFixture.project(
            rows, configuration: configuration, roots: [RowStorageFixture.root]
        )
        RowStorageFixture.expect(hidden, rows: [visible, otherFolder], hiddenCount: 2,
                                 regexCounts: counts)

        var expected = rows
        expected[0].visibility = RowStorageFixture.manualVisibility()
        for index in 1...3 {
            expected[index].visibility = RowStorageFixture.manualVisibility(inherited: true)
        }
        let preview = try await RowStorageFixture.project(
            rows, configuration: configuration, roots: [RowStorageFixture.root],
            revealsRulePreview: true
        )
        // The message and section inherit hiding but do not count as hidden
        // files/folders. The child's own regex match still contributes a count.
        RowStorageFixture.expect(preview, rows: expected, hiddenCount: 2, regexCounts: counts)
    }

    @Test(arguments: SourceVisibilityViewMode.allCases)
    func viewModesPreserveNonitemRowsAndMediaOrder(mode: SourceVisibilityViewMode) async throws {
        let folder = RowStorageFixture.row("folder", kind: .folder(isRoot: true))
        let first = RowStorageFixture.row("first")
        let message = RowStorageFixture.row("message", kind: .message("Unavailable"))
        let section = RowStorageFixture.row("section", kind: .mediaSection)
        let second = RowStorageFixture.row("second")
        let rows = [folder, first, message, section, second]
        var configuration = SourceVisibilityConfiguration.default
        configuration.viewMode = mode
        let result = try await RowStorageFixture.project(rows, configuration: configuration)

        let expected: [SourceTreeDisplayRow]
        switch mode {
        case .tree:
            expected = rows
        case .filesOnly:
            expected = [first, message, section, second]
        case .foldersOnly:
            expected = [folder, message, section]
        case .media:
            let header = SourceTreeDisplayRow(
                id: "media-section:Other Videos", folderID: "", url: first.url,
                displayName: "Other Videos (4)", depth: 0, ancestorIDs: [], kind: .mediaSection
            )
            expected = [header, first, message, section, second]
        }
        RowStorageFixture.expect(result, rows: expected)
    }

    @Test(arguments: [SourceVisibilityViewMode.filesOnly, .media])
    func recursiveModesHonorHiddenAncestorsWithoutFolderRows(mode: SourceVisibilityViewMode) async throws {
        let child = RowStorageFixture.row("child", path: "Hidden/child.mkv")
        let visible = RowStorageFixture.row("visible")
        var configuration = SourceVisibilityConfiguration.default
        configuration.viewMode = mode
        configuration.manuallyHiddenPaths = [RowStorageFixture.root.appendingPathComponent("Hidden").path]
        let hidden = try await RowStorageFixture.project(
            [child, visible], configuration: configuration, roots: [RowStorageFixture.root]
        )
        #expect(hidden.rows.filter { $0.kind.itemKind == .media } == [visible])
        #expect(hidden.hiddenCount == 1)
        #expect(hidden.regexCounts.isEmpty)
        #expect(hidden.thumbnailCandidates == [visible.url])
        #expect(hidden.mediaPaths == [visible.url.path])

        let preview = try await RowStorageFixture.project(
            [child, visible], configuration: configuration, roots: [RowStorageFixture.root],
            revealsRulePreview: true
        )
        var annotated = child
        // Recursive matcher results become direct annotations when no folder
        // display row supplies an inherited annotation.
        annotated.visibility = RowStorageFixture.manualVisibility()
        #expect(preview.rows.filter { $0.kind.itemKind == .media } == [annotated, visible])
        #expect(preview.hiddenCount == 1)
    }

    @Test func callerAndReturnedArrayMutationsDoNotChangePublishedRows() async throws {
        let original = RowStorageFixture.files()
        var input = original
        let published = try await RowStorageFixture.project(input)
        input[0].contextLabel = "Caller changed metadata"
        input.removeLast()
        var returned = published.rows
        returned[1].visibility = RowStorageFixture.manualVisibility()
        returned.append(RowStorageFixture.row("appended"))

        RowStorageFixture.expect(published, rows: original)
        #expect(input.count == original.count - 1)
        #expect(input[0].contextLabel == "Caller changed metadata")
        #expect(input[1].visibility == nil)
        #expect(returned[0].contextLabel == original[0].contextLabel)
        #expect(returned.count == original.count + 1)
    }

    @Test func publishedProjectionsSurviveCacheRuleAndSearchChanges() async throws {
        let rows = RowStorageFixture.files()
        let filter = SourceBrowserFilter()
        let original = try await RowStorageFixture.project(rows, filter: filter)
        var configuration = SourceVisibilityConfiguration.default
        configuration.manuallyHiddenPaths = [rows[4].url.path]
        let hidden = try await RowStorageFixture.project(rows, configuration: configuration, filter: filter)
        let searched = try await RowStorageFixture.project(rows, query: "file-2", filter: filter)
        let restored = try await RowStorageFixture.project(rows, query: " \n", filter: filter)

        RowStorageFixture.expect(original, rows: rows)
        RowStorageFixture.expect(hidden, rows: Array(rows.prefix(4)), hiddenCount: 1)
        RowStorageFixture.expect(searched, rows: [rows[2]])
        RowStorageFixture.expect(restored, rows: rows)
        #expect(await filter.visibilityBuildCount == 3)
    }

    @Test func cancelledProjectionLeavesPreviousCacheAvailable() async throws {
        let rows = RowStorageFixture.files()
        let filter = SourceBrowserFilter()
        let original = try await RowStorageFixture.project(rows, filter: filter)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await filter.project(
                rows: [RowStorageFixture.row("replacement")], configuration: .default,
                roots: [], revealsRulePreview: true, query: "replacement"
            )
        }
        #expect(await cancelled.value == nil)
        let restored = try await RowStorageFixture.project(rows, filter: filter)
        RowStorageFixture.expect(original, rows: rows)
        RowStorageFixture.expect(restored, rows: rows)
        #expect(await filter.visibilityBuildCount == 1)
    }
}

@Suite("Source browser unchanged row storage sharing")
struct SourceBrowserRowStorageTests {
    @Test(arguments: [SourceVisibilityViewMode.tree, .filesOnly, .foldersOnly])
    func unchangedRowsShareTheInputBuffer(mode: SourceVisibilityViewMode) async throws {
        let rows = (0..<64).map {
            RowStorageFixture.row("row-\($0)", kind: mode == .foldersOnly
                                  ? .folder(isRoot: false) : .media(dateAdded: nil))
        }
        var configuration = SourceVisibilityConfiguration.default
        configuration.viewMode = mode
        let result = try await RowStorageFixture.project(rows, configuration: configuration)
        RowStorageFixture.expect(result, rows: rows)
        #expect(RowStorageFixture.sharesStorage(rows, result.rows))
    }

    @Test(arguments: [false, true])
    func enabledRulesStillEvaluateWithoutForcingARowCopy(alwaysShown: Bool) async throws {
        let rows = RowStorageFixture.files(count: 64)
        var configuration = SourceVisibilityConfiguration.default
        configuration.regexRules = [
            .init(id: "rule", pattern: alwaysShown ? "file-" : "absent", colorIndex: 2, isEnabled: true),
        ]
        if alwaysShown { configuration.alwaysShownPaths = Set(rows.map { $0.url.path }) }
        let result = try await RowStorageFixture.project(rows, configuration: configuration)
        RowStorageFixture.expect(result, rows: rows,
                                 regexCounts: ["rule": alwaysShown ? rows.count : 0])
        #expect(RowStorageFixture.sharesStorage(rows, result.rows))
    }

    @Test(arguments: [false, true])
    func alreadyCorrectRevealedAnnotationsShareTheInputBuffer(preview: Bool) async throws {
        var rows = RowStorageFixture.files()
        rows[2].visibility = RowStorageFixture.manualVisibility()
        var configuration = SourceVisibilityConfiguration.default
        configuration.manuallyHiddenPaths = [rows[2].url.path]
        configuration.showsHiddenItems = !preview
        let result = try await RowStorageFixture.project(
            rows, configuration: configuration, revealsRulePreview: preview
        )
        RowStorageFixture.expect(result, rows: rows, hiddenCount: 1)
        #expect(RowStorageFixture.sharesStorage(rows, result.rows))
    }

    @Test func clearingSearchRestoresTheSharedVisibilityBuffer() async throws {
        let rows = RowStorageFixture.files()
        let filter = SourceBrowserFilter()
        let original = try await RowStorageFixture.project(rows, filter: filter)
        let searched = try await RowStorageFixture.project(rows, query: "file-2", filter: filter)
        let restored = try await RowStorageFixture.project(rows, query: " \t\n", filter: filter)
        RowStorageFixture.expect(searched, rows: [rows[2]])
        RowStorageFixture.expect(restored, rows: rows)
        #expect(RowStorageFixture.sharesStorage(rows, original.rows))
        #expect(RowStorageFixture.sharesStorage(rows, restored.rows))
        #expect(await filter.visibilityBuildCount == 1)
    }
}

private enum RowStorageFixture {
    static let root = URL(fileURLWithPath: "/tmp/illiquid-row-storage", isDirectory: true)

    static func row(
        _ id: String, kind: SourceTreeDisplayRow.Kind = .media(dateAdded: nil),
        ancestors: [String] = [], path: String? = nil, containsMedia: Bool? = nil
    ) -> SourceTreeDisplayRow {
        let url = root.appendingPathComponent(path ?? "\(id).mkv")
        var result = SourceTreeDisplayRow(
            id: id, folderID: "library", url: url, displayName: id,
            depth: ancestors.count, ancestorIDs: ancestors, kind: kind
        )
        result.contextLabel = "Fixture \(id)"
        result.visibilityPath = url.path
        result.containsSupportedMedia = containsMedia
        return result
    }

    static func files(count: Int = 5) -> [SourceTreeDisplayRow] {
        (0..<count).map { row("file-\($0)") }
    }

    static func manualVisibility(inherited: Bool = false) -> SourceRowVisibility {
        SourceRowVisibility(matches: [.manual], isInherited: inherited)
    }

    static func project(
        _ rows: [SourceTreeDisplayRow], configuration: SourceVisibilityConfiguration = .default,
        roots: [URL] = [], revealsRulePreview: Bool = false, query: String = "",
        filter: SourceBrowserFilter = SourceBrowserFilter()
    ) async throws -> SourceBrowserProjection {
        try #require(await filter.project(
            rows: rows, configuration: configuration, roots: roots,
            revealsRulePreview: revealsRulePreview, query: query
        ))
    }

    static func expect(
        _ projection: SourceBrowserProjection, rows: [SourceTreeDisplayRow],
        hiddenCount: Int = 0, regexCounts: [String: Int] = [:]
    ) {
        #expect(projection.rows == rows)
        #expect(projection.hiddenCount == hiddenCount)
        #expect(projection.regexCounts == regexCounts)
        let media = rows.filter { $0.kind.itemKind == .media }
        #expect(projection.thumbnailCandidates == Array(media.prefix(2_048)).map(\.url))
        #expect(projection.mediaPaths == Set(media.map { $0.url.standardizedFileURL.path }))
    }

    static func sharesStorage(_ lhs: [SourceTreeDisplayRow], _ rhs: [SourceTreeDisplayRow]) -> Bool {
        guard !lhs.isEmpty, lhs.count == rhs.count else { return false }
        // Compare only while both buffer borrows are active; do not retain
        // pointers or assume an empty Array has unique backing storage.
        return lhs.withUnsafeBufferPointer { left in
            rhs.withUnsafeBufferPointer { right in
                left.baseAddress == right.baseAddress
            }
        }
    }
}
