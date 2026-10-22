import Foundation
import IlliquidCore
import Testing

@testable import IlliquidApp

@Suite("Flat file projection contracts")
struct FlatFileProjectionTests {
    private let root = URL(fileURLWithPath: "/flat-projection/Library", isDirectory: true)
    private let otherRoot = URL(fileURLWithPath: "/flat-projection/Archive", isDirectory: true)
    private let unsorted = SourceTreeSortConfiguration(name: .off, dateCreated: .off, type: .off)

    @Test(arguments: [SourceVisibilityViewMode.filesOnly, .media])
    func folderOnlyMultipleRootsPreserveCompleteSortedRows(_ mode: SourceVisibilityViewMode) {
        let first = entry(root.appendingPathComponent("Movies/Feature 1 (2019).mkv"), added: 101,
                          recognitionPath: "Sidecar One (1999).mkv", metadataSources: ["NFO"])
        let second = entry(otherRoot.appendingPathComponent("Films/Feature 2 (2020).mkv"), added: 202)
        let tenth = entry(root.appendingPathComponent("Movies/Feature 10 (2021).mkv"), added: 303,
                          metadataSources: ["PlexMatch", "NFO"])
        let snapshot = input(mode, items: [.init(kind: .folder, url: root),
                                          .init(kind: .folder, url: otherRoot)],
                             entries: [tenth, second, first], roots: [root, otherRoot],
                             sort: .init(name: .ascending, dateCreated: .off, type: .off))
        let expected = [
            row(first, mode: mode, context: mode == .media ? "NFO · Movies" : "Movies"),
            row(second, mode: mode, context: "Films"),
            row(tenth, mode: mode, context: mode == .media ? "PlexMatch, NFO · Movies" : "Movies"),
        ]

        #expect(snapshot.rows() == expected)
    }

    @Test(arguments: [SourceVisibilityViewMode.filesOnly, .media])
    func explicitFilesAlreadyDiscoveredKeepTheirLoadedMetadata(_ mode: SourceVisibilityViewMode) {
        let loaded = entry(root.appendingPathComponent("Feature 2 (2020).mkv"), added: 202,
                           recognitionPath: "Authoritative Title (1997).mkv", metadataSources: ["NFO"])
        let other = entry(root.appendingPathComponent("Feature 1 (2021).mkv"), added: 101)
        let snapshot = input(mode, items: [.init(kind: .file, url: loaded.url),
                                          .init(kind: .folder, url: root),
                                          .init(kind: .file, url: other.url),
                                          .init(kind: .file, url: loaded.url)],
                             entries: [loaded, other], roots: [root], sort: unsorted)
        let expected = [row(loaded, mode: mode, context: mode == .media ? "NFO" : nil),
                        row(other, mode: mode)]

        #expect(snapshot.rows() == expected)
    }

    @Test(arguments: [SourceVisibilityViewMode.filesOnly, .media])
    func undiscoveredExplicitFilesAppendInInputOrderWithoutSorting(_ mode: SourceVisibilityViewMode) {
        let loaded = entry(root.appendingPathComponent("Feature 10 (2020).mkv"), added: 100)
        let second = entry(root.appendingPathComponent("Unscanned/Feature 2 (2021).mkv"))
        let first = entry(root.appendingPathComponent("Unscanned/Feature 1 (2022).mkv"))
        let snapshot = input(mode, items: [.init(kind: .file, url: second.url),
                                          .init(kind: .folder, url: root),
                                          .init(kind: .file, url: first.url)],
                             entries: [loaded], roots: [root], sort: unsorted)
        let expected = [row(loaded, mode: mode), row(second, mode: mode, context: "Unscanned"),
                        row(first, mode: mode, context: "Unscanned")]

        #expect(snapshot.rows() == expected)
    }

    @Test(arguments: [SourceVisibilityViewMode.filesOnly, .media])
    func repeatedExplicitFilesDeduplicateAfterTheSelectedSort(_ mode: SourceVisibilityViewMode) {
        let tenth = entry(root.appendingPathComponent("Feature 10 (2020).mkv"))
        let second = entry(root.appendingPathComponent("Feature 2 (2021).mkv"))
        let items: [SourceTabItem] = [tenth, second, tenth, second].map { .init(kind: .file, url: $0.url) }
        let cases: [(SourceTreeSortDirection, [SourceTreeDisplayRow])] = [
            (.off, [row(tenth, mode: mode), row(second, mode: mode)]),
            (.ascending, [row(second, mode: mode), row(tenth, mode: mode)]),
            (.descending, [row(tenth, mode: mode), row(second, mode: mode)]),
        ]

        for (direction, expected) in cases {
            let snapshot = input(mode, items: items, entries: [], roots: [root],
                                 sort: .init(name: direction, dateCreated: .off, type: .off))
            #expect(snapshot.rows() == expected, Comment(rawValue: direction.rawValue))
        }
    }

    @Test(arguments: [SourceVisibilityViewMode.filesOnly, .media])
    func overlappingDiscoveredPathsKeepTheFirstSortedPayload(_ mode: SourceVisibilityViewMode) {
        let url = root.appendingPathComponent("Feature (2020).mkv")
        let first = entry(url, added: 101, created: 100, recognitionPath: "First Metadata (1991).mkv")
        let last = entry(url, added: 202, created: 200, recognitionPath: "Last Metadata (1992).mkv")
        let cases: [(SourceTreeSortDirection, SourceTreeEntry)] = [
            (.off, first), (.ascending, first), (.descending, last),
        ]

        for (direction, survivor) in cases {
            let snapshot = input(mode, items: [.init(kind: .folder, url: root)],
                                 entries: [first, last], roots: [root],
                                 sort: .init(name: .off, dateCreated: direction, type: .off))
            #expect(snapshot.rows() == [row(survivor, mode: mode)], Comment(rawValue: direction.rawValue))
        }
    }

    @Test(arguments: [SourceVisibilityViewMode.filesOnly, .media])
    func unicodeAndLexicalAliasesKeepTheDiscoveredURLAndMetadata(_ mode: SourceVisibilityViewMode) throws {
        let raw = try #require(URL(string: "file:///flat-projection/Library/Unused/../Cafe%CC%81/Feature%20(2020).mkv"))
        let canonical = root.appendingPathComponent("Café/Feature (2020).mkv")
        let discovered = entry(raw, added: 314, recognitionPath: "Alias Metadata (1998).mkv",
                               metadataSources: ["NFO"], visibilityPath: nil)
        let snapshot = input(mode, items: [.init(kind: .folder, url: root),
                                          .init(kind: .file, url: canonical)],
                             entries: [discovered], roots: [root], sort: unsorted)
        let expected = row(discovered, mode: mode, context: mode == .media ? "NFO · Café" : "Café",
                           identityPath: canonical.path)

        #expect(raw != canonical)
        #expect(snapshot.rows() == [expected])
    }

    @Test(arguments: [SourceVisibilityViewMode.filesOnly, .media])
    func emptySourcesAndRetainedRecursiveSnapshotKeepTheirExistingBehavior(_ mode: SourceVisibilityViewMode) {
        #expect(input(mode, items: [], entries: [], roots: [], sort: unsorted).rows().isEmpty)
        #expect(input(mode, items: [.init(kind: .folder, url: root)], entries: [],
                      roots: [root], sort: unsorted).rows().isEmpty)

        // A recursive snapshot can outlive its source items until replacement.
        // The projection still displays it; the explicit-file guard must not
        // turn an empty items array into an early return.
        let retained = entry(root.appendingPathComponent("Feature (2020).mkv"), added: 77)
        let snapshot = input(mode, items: [], entries: [retained], roots: [], sort: unsorted)
        #expect(snapshot.rows() == [row(retained, mode: mode)])
    }

    @Test(arguments: [SourceVisibilityViewMode.filesOnly, .media])
    func cancellationBeforeProjectionReturnsNoRows(_ mode: SourceVisibilityViewMode) async {
        let loaded = entry(root.appendingPathComponent("Feature 1 (2020).mkv"), added: 100)
        let explicit = entry(root.appendingPathComponent("Feature 2 (2021).mkv"))
        let itemSets: [[SourceTabItem]] = [
            [.init(kind: .folder, url: root)],
            [.init(kind: .folder, url: root), .init(kind: .file, url: explicit.url)],
        ]
        for items in itemSets {
            let snapshot = input(mode, items: items, entries: [loaded], roots: [root], sort: unsorted)
            let cancelled = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return snapshot.rows()
            }
            let result = await cancelled.value
            #expect(result.isEmpty)
        }
    }

    private func input(
        _ mode: SourceVisibilityViewMode, items: [SourceTabItem], entries: [SourceTreeEntry],
        roots: [URL], sort: SourceTreeSortConfiguration
    ) -> SourceTreeProjectionInput {
        var visibility = SourceVisibilityConfiguration.default
        visibility.viewMode = mode
        return SourceTreeProjectionInput(items: items, visibility: visibility, roots: roots,
            directoryContents: [:], directoryErrors: [:], recursiveMediaEntries: entries,
            expandedFolderIDs: [], sortConfiguration: sort)
    }

    private func entry(
        _ url: URL, added: TimeInterval? = nil, created: TimeInterval? = nil,
        recognitionPath: String? = nil, metadataSources: [String] = [], visibilityPath: String? = nil
    ) -> SourceTreeEntry {
        var result = SourceTreeEntry(url: url, kind: .media,
            dateAdded: added.map { Date(timeIntervalSince1970: $0) },
            creationDate: created.map { Date(timeIntervalSince1970: $0) }, visibilityPath: visibilityPath)
        var recognition = MediaNameRecognition.recognize(relativePath: recognitionPath ?? url.path)
        recognition.metadataSources = metadataSources
        result.recognizedMedia = recognition
        return result
    }

    private func row(
        _ entry: SourceTreeEntry, mode: SourceVisibilityViewMode, context: String? = nil,
        identityPath: String? = nil
    ) -> SourceTreeDisplayRow {
        let recognition = mode == .media ? entry.recognizedMedia : nil
        let path = identityPath ?? entry.url.path
        return SourceTreeDisplayRow(id: "media:\(path)", folderID: entry.url.deletingLastPathComponent().path,
            url: entry.url, displayName: recognition?.displayName ?? entry.url.deletingPathExtension().lastPathComponent,
            contextLabel: context, recognizedMedia: recognition, visibilityPath: path,
            depth: 0, ancestorIDs: [], kind: .media(dateAdded: entry.dateAdded))
    }
}
