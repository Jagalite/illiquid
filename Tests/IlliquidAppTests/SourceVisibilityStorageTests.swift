import Foundation
import Testing
@testable import IlliquidApp

@Suite("Source visibility row storage")
struct SourceVisibilityStorageTests {
    @Test(arguments: [false, true])
    func unchangedProjectionSharesInputStorage(withRules: Bool) async throws {
        let rows = mediaRows()
        var configuration = SourceVisibilityConfiguration.default
        if withRules {
            configuration.regexRules = [
                .init(id: "no-match", pattern: "NeverMatches", colorIndex: 1, isEnabled: true),
                .init(id: "disabled", pattern: "Episode", colorIndex: 2, isEnabled: false),
            ]
        }
        let projection = try #require(await SourceBrowserFilter().project(
            rows: rows, configuration: configuration, roots: [root],
            revealsRulePreview: false, query: ""
        ))
        expectProjection(projection, rows: rows, hiddenCount: 0,
                         regexCounts: withRules ? ["no-match": 0, "disabled": 0] : [:])
        // Both borrows are live during the comparison; neither pointer escapes.
        // This is the specific retained-storage invariant under investigation.
        #expect(rows.withUnsafeBufferPointer { original in
            projection.rows.withUnsafeBufferPointer { projected in
                original.baseAddress == projected.baseAddress
            }
        })
    }

    @Test func publishedRowsRemainImmutableAcrossLaterMutations() async throws {
        let originalRows = mediaRows()
        var input = originalRows
        let filter = SourceBrowserFilter()
        let original = try #require(await filter.project(
            rows: input, configuration: .default, roots: [root],
            revealsRulePreview: false, query: ""
        ))

        input[0].contextLabel = "Changed caller metadata"
        var configuration = SourceVisibilityConfiguration.default
        configuration.manuallyHiddenPaths = [input[4].url.path]
        let changed = try #require(await filter.project(
            rows: input, configuration: configuration, roots: [root],
            revealsRulePreview: false, query: ""
        ))
        expectProjection(changed, rows: input.enumerated().compactMap {
            $0.offset == 4 ? nil : $0.element
        }, hiddenCount: 1)

        var consumerRows = original.rows
        consumerRows[1].contextLabel = "Changed consumer metadata"
        #expect(consumerRows[1].contextLabel != originalRows[1].contextLabel)
        expectProjection(original, rows: originalRows, hiddenCount: 0)
        #expect(input[1] == originalRows[1])

        let restored = try #require(await filter.project(
            rows: input, configuration: .default, roots: [root],
            revealsRulePreview: false, query: ""
        ))
        expectProjection(restored, rows: input, hiddenCount: 0)
        expectProjection(original, rows: originalRows, hiddenCount: 0)
    }

    @Test(arguments: [0, 4, 8])
    func exclusionPreservesTheAcceptedPrefixAndSuffix(index: Int) async throws {
        let rows = mediaRows()
        var configuration = SourceVisibilityConfiguration.default
        configuration.manuallyHiddenPaths = [rows[index].url.path]
        let projection = try #require(await SourceBrowserFilter().project(
            rows: rows, configuration: configuration, roots: [root],
            revealsRulePreview: false, query: ""
        ))
        expectProjection(projection, rows: rows.enumerated().compactMap {
            $0.offset == index ? nil : $0.element
        }, hiddenCount: 1)
    }

    @Test(arguments: [0, 4, 8])
    func previewAnnotationPreservesTheAcceptedPrefixAndSuffix(index: Int) async throws {
        let rows = mediaRows()
        var configuration = SourceVisibilityConfiguration.default
        configuration.manuallyHiddenPaths = [rows[index].url.path]
        let projection = try #require(await SourceBrowserFilter().project(
            rows: rows, configuration: configuration, roots: [root],
            revealsRulePreview: true, query: ""
        ))
        var expected = rows
        expected[index].visibility = .init(matches: [.manual], isInherited: false)
        expectProjection(projection, rows: expected, hiddenCount: 1)
        #expect(rows[index].visibility == nil)
    }

    @Test(arguments: [0, 4, 8])
    func staleAnnotationIsCleared(index: Int) async throws {
        let expected = mediaRows()
        var rows = expected
        rows[index].visibility = .init(matches: [.manual], isInherited: true)
        let projection = try #require(await SourceBrowserFilter().project(
            rows: rows, configuration: .default, roots: [root],
            revealsRulePreview: false, query: ""
        ))
        expectProjection(projection, rows: expected, hiddenCount: 0)
        #expect(rows[index].visibility != nil)
    }

    @Test func viewExclusionThenAnnotationAndInheritanceKeepTheirOrder() async throws {
        let visibleFolder = folderRow("Visible")
        let hiddenFolder = folderRow("Hidden")
        let message = SourceTreeDisplayRow(
            id: "message", folderID: hiddenFolder.folderID, url: hiddenFolder.url,
            displayName: "Folder message", depth: 1, ancestorIDs: [hiddenFolder.id],
            kind: .message("Folder message")
        )
        let rows = [mediaRows()[0], visibleFolder, hiddenFolder, message]
        var configuration = SourceVisibilityConfiguration.default
        configuration.viewMode = .foldersOnly
        configuration.manuallyHiddenPaths = [hiddenFolder.url.path]
        var expectedHidden = hiddenFolder
        expectedHidden.visibility = .init(matches: [.manual], isInherited: false)
        var expectedMessage = message
        expectedMessage.visibility = .init(matches: [.manual], isInherited: true)

        let projection = try #require(await SourceBrowserFilter().project(
            rows: rows, configuration: configuration, roots: [root],
            revealsRulePreview: true, query: ""
        ))
        expectProjection(projection, rows: [visibleFolder, expectedHidden, expectedMessage], hiddenCount: 1)
    }

    @Test func emptyFolderHidingAndPreviewWorkWithoutConfiguredRules() async throws {
        let prefix = mediaRows()[0]
        var folder = folderRow("Empty")
        folder.containsSupportedMedia = false
        let message = SourceTreeDisplayRow(
            id: "empty-message", folderID: folder.folderID, url: folder.url,
            displayName: "No supported media", depth: 1, ancestorIDs: [folder.id],
            kind: .message("No supported media")
        )
        let rows = [prefix, folder, message]
        let filter = SourceBrowserFilter()
        let hidden = try #require(await filter.project(
            rows: rows, configuration: .default, roots: [root],
            revealsRulePreview: false, query: ""
        ))
        expectProjection(hidden, rows: [prefix], hiddenCount: 1)

        var expectedFolder = folder
        expectedFolder.visibility = .init(matches: [.noMedia], isInherited: false)
        var expectedMessage = message
        expectedMessage.visibility = .init(matches: [.noMedia], isInherited: true)
        let preview = try #require(await filter.project(
            rows: rows, configuration: .default, roots: [root],
            revealsRulePreview: true, query: ""
        ))
        expectProjection(preview, rows: [prefix, expectedFolder, expectedMessage], hiddenCount: 1)
    }

    @Test func matchingRuleCountsSurviveAnEmptyResult() async throws {
        let rows = mediaRows()
        var configuration = SourceVisibilityConfiguration.default
        configuration.regexRules = [
            .init(id: "episodes", pattern: "Episode", colorIndex: 0, isEnabled: true),
        ]
        let projection = try #require(await SourceBrowserFilter().project(
            rows: rows, configuration: configuration, roots: [root],
            revealsRulePreview: false, query: ""
        ))
        expectProjection(projection, rows: [], hiddenCount: rows.count,
                         regexCounts: ["episodes": rows.count])
    }

    @Test func refreshedAnnotationPreservesTheConfiguredRuleIDBytes() async throws {
        let previousID = "e\u{301}"
        let currentID = "\u{e9}"
        #expect(previousID == currentID)
        #expect(Array(previousID.utf8) != Array(currentID.utf8))
        var rows = mediaRows(count: 1)
        rows[0].visibility = .init(
            matches: [.regex(.init(id: previousID, colorIndex: 2))], isInherited: false
        )
        var configuration = SourceVisibilityConfiguration.default
        configuration.regexRules = [
            .init(id: currentID, pattern: "Episode", colorIndex: 2, isEnabled: true),
        ]
        let projection = try #require(await SourceBrowserFilter().project(
            rows: rows, configuration: configuration, roots: [root],
            revealsRulePreview: true, query: ""
        ))
        let annotation = try #require(projection.rows.first?.visibility)
        #expect(annotation.regexMatches.map { Array($0.id.utf8) } == [Array(currentID.utf8)])
        #expect(projection.hiddenCount == 1)
        #expect(projection.regexCounts == [currentID: 1])
    }

    private var root: URL {
        URL(fileURLWithPath: "/tmp/illiquid-visibility-storage", isDirectory: true)
    }

    private func mediaRows(count: Int = 9) -> [SourceTreeDisplayRow] {
        (0..<count).map { index in
            let url = root.appendingPathComponent("Episode \(index).mkv")
            return SourceTreeDisplayRow(
                id: "media:\(index)", folderID: root.path, url: url,
                displayName: "Episode \(index)", contextLabel: "Context \(index)",
                visibilityPath: url.path, depth: 0, ancestorIDs: [],
                kind: .media(dateAdded: Date(timeIntervalSince1970: Double(index)))
            )
        }
    }

    private func folderRow(_ name: String) -> SourceTreeDisplayRow {
        let url = root.appendingPathComponent(name, isDirectory: true)
        return SourceTreeDisplayRow(
            id: "folder:\(name)", folderID: url.path, url: url, displayName: name,
            visibilityPath: url.path, depth: 0, ancestorIDs: [], kind: .folder(isRoot: false)
        )
    }

    private func expectProjection(
        _ actual: SourceBrowserProjection, rows: [SourceTreeDisplayRow], hiddenCount: Int,
        regexCounts: [String: Int] = [:]
    ) {
        #expect(actual.rows == rows)
        #expect(actual.hiddenCount == hiddenCount)
        #expect(actual.regexCounts == regexCounts)
        let mediaURLs = rows.compactMap { row -> URL? in
            guard case .media = row.kind else { return nil }
            return row.url
        }
        #expect(actual.thumbnailCandidates == mediaURLs)
        #expect(actual.mediaPaths == Set(mediaURLs.map { $0.standardizedFileURL.path }))
    }
}
