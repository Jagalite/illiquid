import Foundation
import Testing
@testable import IlliquidApp

@Suite("Source tree traversal")
struct SourceTreeTraversalTests {
    @Test func sharedDescendantsAndRepeatedRootsKeepEachOccurrence() {
        let first = folder("First")
        let second = folder("Second")
        let shared = folder("Shared")
        let video = shared.appendingPathComponent("Episode.mkv")
        let added = Date(timeIntervalSince1970: 1234)
        let input = makeInput(
            items: [tab(first), tab(second), tab(first)],
            contents: [
                first: [entry(shared, .folder)],
                second: [entry(shared, .folder)],
                shared: [entry(video, .media, added: added)],
            ],
            expanded: [first, second, shared]
        )

        #expect(input.rows() == [
            folderRow(first, root: true),
            folderRow(shared, depth: 1, ancestors: [first]),
            mediaRow(video, parent: shared, depth: 2, ancestors: [first, shared], added: added),
            folderRow(second, root: true),
            folderRow(shared, depth: 1, ancestors: [second]),
            mediaRow(video, parent: shared, depth: 2, ancestors: [second, shared], added: added),
            folderRow(first, root: true),
            folderRow(shared, depth: 1, ancestors: [first]),
            mediaRow(video, parent: shared, depth: 2, ancestors: [first, shared], added: added),
        ])
    }

    @Test func selfAndAncestorCyclesDoNotHideLaterMedia() {
        let root = folder("Root")
        let child = folder("Child")
        let rootVideo = root.appendingPathComponent("Root.mkv")
        let childVideo = child.appendingPathComponent("Child.mkv")
        let explicitFile = folder("Other").appendingPathComponent("Explicit.mkv")
        let input = makeInput(
            items: [tab(root), SourceTabItem(kind: .file, url: explicitFile)],
            contents: [
                root: [entry(root, .folder), entry(child, .folder), entry(rootVideo, .media)],
                child: [entry(root, .folder), entry(child, .folder), entry(childVideo, .media)],
            ],
            expanded: [root, child]
        )

        #expect(input.rows() == [
            folderRow(root, root: true),
            folderRow(child, depth: 1, ancestors: [root]),
            mediaRow(childVideo, parent: child, depth: 2, ancestors: [root, child]),
            mediaRow(rootVideo, parent: root, depth: 1, ancestors: [root]),
            mediaRow(explicitFile),
        ])
    }

    @Test func flattenedRootIsStillAnAncestorForCycleDetection() {
        let root = folder("Root")
        let first = folder("First")
        let second = folder("Second")
        let firstVideo = first.appendingPathComponent("First.mkv")
        let secondVideo = second.appendingPathComponent("Second.mkv")
        let input = makeInput(
            items: [tab(root)],
            contents: [
                root: [entry(root, .folder), entry(first, .folder), entry(second, .folder)],
                first: [entry(root, .folder), entry(firstVideo, .media)],
                second: [entry(root, .folder), entry(secondVideo, .media)],
            ],
            // A flattened active root does not need to be expanded.
            expanded: [first, second]
        )

        #expect(input.rows() == [
            folderRow(first),
            mediaRow(firstVideo, parent: first, depth: 1, ancestors: [first]),
            folderRow(second),
            mediaRow(secondVideo, parent: second, depth: 1, ancestors: [second]),
        ])
    }

    @Test(arguments: ["collapsed", "error", "empty", "unloaded"])
    func returningFromOneBranchDoesNotSuppressTheNext(reason: String) {
        let first = folder("First")
        let second = folder("Second")
        let shared = folder("Shared")
        let video = shared.appendingPathComponent("Episode.mkv")
        var contents: [URL: [SourceTreeEntry]] = [
            first: [entry(shared, .folder)],
            second: [entry(shared, .folder)],
        ]
        var expanded: [URL] = [first, second]
        var errors: [URL: String] = [:]
        let message: String?
        switch reason {
        case "collapsed":
            contents[shared] = [entry(video, .media)]
            message = nil
        case "error":
            expanded.append(shared)
            contents[shared] = [entry(video, .media)]
            errors[shared] = "Permission denied"
            message = "Permission denied"
        case "empty":
            expanded.append(shared)
            contents[shared] = []
            message = "No supported media"
        default:
            expanded.append(shared)
            message = nil
        }
        let input = makeInput(
            items: [tab(first), tab(second)],
            contents: contents,
            errors: errors,
            expanded: expanded,
            mediaPresence: [shared: false]
        )
        var expected = [
            folderRow(first, root: true),
            folderRow(shared, depth: 1, ancestors: [first], presence: false),
        ]
        if let message {
            expected.append(messageRow(shared, message, depth: 2, ancestors: [first, shared]))
        }
        expected += [
            folderRow(second, root: true),
            folderRow(shared, depth: 1, ancestors: [second], presence: false),
        ]
        if let message {
            expected.append(messageRow(shared, message, depth: 2, ancestors: [second, shared]))
        }

        #expect(input.rows() == expected)
    }

    @Test func retainedRowsStayUnchangedAcrossIndependentProjections() {
        let root = folder("Root")
        let child = folder("Child")
        let video = child.appendingPathComponent("Episode.mkv")
        let contents = [
            root: [entry(child, .folder)],
            child: [entry(video, .media)],
        ]
        let expanded = makeInput(items: [tab(root)], contents: contents, expanded: [child])
        let collapsed = makeInput(items: [tab(root)], contents: contents, expanded: [])
        let expected = [
            folderRow(child),
            mediaRow(video, parent: child, depth: 1, ancestors: [child]),
        ]
        let retained = expanded.rows()

        #expect(collapsed.rows() == [folderRow(child)])
        #expect(expanded.rows() == expected)
        #expect(retained == expected)
    }

    @Test func alreadyCancelledProjectionReturnsNoRowsAndDoesNotAffectLaterCalls() async {
        let root = folder("Root")
        let child = folder("Child")
        let video = child.appendingPathComponent("Episode.mkv")
        let input = makeInput(
            items: [tab(root)],
            contents: [
                root: [entry(child, .folder)],
                child: [entry(root, .folder), entry(video, .media)],
            ],
            expanded: [child]
        )
        // Cancel inside the child task before rows() starts; there is no timing
        // race with an external cancel() or dependency on scheduler speed.
        let cancelledRows = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return input.rows()
        }.value

        #expect(cancelledRows.isEmpty)
        #expect(input.rows() == [
            folderRow(child),
            mediaRow(video, parent: child, depth: 1, ancestors: [child]),
        ])
    }

    private func folder(_ name: String) -> URL {
        URL(fileURLWithPath: "/illiquid-traversal-tests/\(name)", isDirectory: true)
    }

    private func tab(_ url: URL) -> SourceTabItem {
        SourceTabItem(kind: .folder, url: url)
    }

    private func entry(
        _ url: URL, _ kind: SourceTreeEntry.Kind, added: Date? = nil
    ) -> SourceTreeEntry {
        SourceTreeEntry(url: url, kind: kind, dateAdded: added, creationDate: nil)
    }

    private func makeInput(
        items: [SourceTabItem],
        contents: [URL: [SourceTreeEntry]],
        errors: [URL: String] = [:],
        expanded: [URL],
        mediaPresence: [URL: Bool] = [:]
    ) -> SourceTreeProjectionInput {
        SourceTreeProjectionInput(
            items: items,
            visibility: .default,
            roots: items.filter { $0.kind == .folder }.map(\.url),
            directoryContents: Dictionary(uniqueKeysWithValues: contents.map { ($0.key.path, $0.value) }),
            directoryErrors: Dictionary(uniqueKeysWithValues: errors.map { ($0.key.path, $0.value) }),
            recursiveMediaEntries: [],
            expandedFolderIDs: Set(expanded.map(\.path)),
            sortConfiguration: .init(name: .off, dateCreated: .off, type: .off),
            mediaPresence: Dictionary(uniqueKeysWithValues: mediaPresence.map { ($0.key.path, $0.value) })
        )
    }

    private func folderRow(
        _ url: URL, root: Bool = false, depth: Int = 0,
        ancestors: [URL] = [], presence: Bool? = nil
    ) -> SourceTreeDisplayRow {
        SourceTreeDisplayRow(
            id: "folder:\(url.path)", folderID: url.path, url: url,
            displayName: url.lastPathComponent, visibilityPath: url.path,
            depth: depth, ancestorIDs: ancestors.map { "folder:\($0.path)" },
            kind: .folder(isRoot: root), containsSupportedMedia: presence
        )
    }

    private func mediaRow(
        _ url: URL, parent: URL? = nil, depth: Int = 0,
        ancestors: [URL] = [], added: Date? = nil
    ) -> SourceTreeDisplayRow {
        SourceTreeDisplayRow(
            id: "media:\(url.path)", folderID: parent?.path ?? "", url: url,
            displayName: url.deletingPathExtension().lastPathComponent,
            visibilityPath: url.path,
            depth: depth, ancestorIDs: ancestors.map { "folder:\($0.path)" },
            kind: .media(dateAdded: added)
        )
    }

    private func messageRow(
        _ url: URL, _ message: String, depth: Int, ancestors: [URL]
    ) -> SourceTreeDisplayRow {
        SourceTreeDisplayRow(
            id: "message:\(url.path)", folderID: url.path, url: url,
            displayName: message,
            depth: depth, ancestorIDs: ancestors.map { "folder:\($0.path)" },
            kind: .message(message)
        )
    }
}
