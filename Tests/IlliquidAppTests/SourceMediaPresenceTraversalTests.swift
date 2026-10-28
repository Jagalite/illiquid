import Foundation
import Testing
@testable import IlliquidApp

@Suite("Source media presence traversal identities")
struct SourceMediaPresenceTraversalTests {
    @Test func mixedFilesKeepDirectorySummariesAcrossEntryBudgets() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let media = try makeDirectory(root.appendingPathComponent("Media", isDirectory: true))
        let text = try makeDirectory(root.appendingPathComponent("Text", isDirectory: true))
        let empty = try makeDirectory(root.appendingPathComponent("Empty", isDirectory: true))
        for file in [root.appendingPathComponent("readme.txt"),
                     media.appendingPathComponent("video.MKV"),
                     media.appendingPathComponent("subtitle.srt"),
                     text.appendingPathComponent("poster.jpg"),
                     text.appendingPathComponent("notes.txt")] {
            try Data().write(to: file)
        }

        let sliced = try traverse(root, maximumEntries: 1)
        let whole = try traverse(root, maximumEntries: 64)
        #expect(sliced == whole)
        #expect(sliced.visitedEntries == 8)
        let rootID = SourceTreeIdentity.folderID(for: root)
        let mediaID = SourceTreeIdentity.folderID(for: media)
        let textID = SourceTreeIdentity.folderID(for: text)
        let emptyID = SourceTreeIdentity.folderID(for: empty)
        #expect(sliced.results == [rootID: true, mediaID: true, textID: false, emptyID: false])
        #expect(Set(sliced.summaries.keys) == Set([rootID, mediaID, textID, emptyID]))
        #expect(sliced.summaries[rootID]?.children == Set([mediaID, textID, emptyID]))
        #expect(sliced.summaries[rootID]?.hasDirectMedia == false)
        #expect(sliced.summaries[mediaID]?.hasDirectMedia == true)
        #expect(sliced.summaries[textID]?.hasDirectMedia == false)
        #expect(sliced.summaries[emptyID]?.children.isEmpty == true)
        #expect(sliced.summaries.values.allSatisfy { $0.isComplete && $0.isReadable })
    }

    @Test func unicodeAndPercentLikeNamesKeepLiteralDirectoryKeys() throws {
        let fixture = try makeRoot()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let root = try makeDirectory(fixture.appendingPathComponent("Cafe\u{301} 100% # collection", isDirectory: true))
        let parentName = "%2F %2E%2E 日本語"
        let leafName = "Saison e\u{301} 01"
        let parent = try makeDirectory(root.appendingPathComponent(parentName, isDirectory: true))
        let leaf = try makeDirectory(parent.appendingPathComponent(leafName, isDirectory: true))
        let other = try makeDirectory(root.appendingPathComponent("%252F", isDirectory: true))
        try Data().write(to: leaf.appendingPathComponent("episode #1 100%.mp4"))
        try Data().write(to: other.appendingPathComponent("notes.txt"))

        let scan = try traverse(root, maximumEntries: 1)
        let rootID = SourceTreeIdentity.folderID(for: root)
        let parentID = rootID + "/" + parentName
        let leafID = parentID + "/" + leafName
        let otherID = rootID + "/%252F"
        #expect(scan.results == [rootID: true, parentID: true, leafID: true, otherID: false])
        #expect(scan.summaries[rootID]?.children == Set([parentID, otherID]))
        #expect(scan.summaries[parentID]?.children == Set([leafID]))
        #expect(scan.summaries[leafID]?.hasDirectMedia == true)
        #expect(scan.visitedEntries == 5)
        // The root identity is normalized once. Descendant keys must keep its
        // exact bytes even when enumeration reports another Unicode spelling.
        #expect(scan.summaries.keys.allSatisfy { $0.utf8.starts(with: rootID.utf8) })
    }

    @Test func cachedDirectoryKeysSkipDescendantsAndPropagateBothValues() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cached = try makeDirectory(root.appendingPathComponent("Cache %2F Café", isDirectory: true))
        let deep = try makeDirectory(cached.appendingPathComponent("Deep", isDirectory: true))
        let uncached = try makeDirectory(root.appendingPathComponent("Uncached", isDirectory: true))
        try Data().write(to: deep.appendingPathComponent("notes.txt"))
        try Data().write(to: uncached.appendingPathComponent("notes.txt"))
        let rootID = SourceTreeIdentity.folderID(for: root)
        let cachedID = SourceTreeIdentity.folderID(for: cached)
        let uncachedID = SourceTreeIdentity.folderID(for: uncached)

        for cachedPresence in [false, true] {
            let scan = try traverse(root, maximumEntries: 1, cachedResults: [cachedID: cachedPresence])
            #expect(scan.visitedEntries == 3)
            #expect(scan.results == [rootID: cachedPresence, uncachedID: false])
            #expect(Set(scan.summaries.keys) == Set([rootID, uncachedID]))
            #expect(scan.summaries[rootID]?.children == Set([cachedID, uncachedID]))
            #expect(scan.summaries[rootID]?.hasDirectMedia == false)
            #expect(scan.summaries[rootID]?.isComplete == true)
        }
    }

    @Test func hiddenEntriesAndDirectoryLinksDoNotBecomeChildren() throws {
        let fixture = try makeRoot()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let root = try makeDirectory(fixture.appendingPathComponent("Root", isDirectory: true))
        let visible = try makeDirectory(root.appendingPathComponent("Visible", isDirectory: true))
        let hidden = try makeDirectory(root.appendingPathComponent(".Hidden", isDirectory: true))
        let outside = try makeDirectory(fixture.appendingPathComponent("Outside", isDirectory: true))
        try Data().write(to: outside.appendingPathComponent("outside.mp4"))
        try Data().write(to: hidden.appendingPathComponent("hidden.mp4"))
        try Data().write(to: root.appendingPathComponent(".hidden.mp4"))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("Linked", isDirectory: true), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("Loop", isDirectory: true), withDestinationURL: root)

        let scan = try traverse(root, maximumEntries: 1)
        let rootID = SourceTreeIdentity.folderID(for: root)
        let visibleID = SourceTreeIdentity.folderID(for: visible)
        #expect(scan.results == [rootID: false, visibleID: false])
        #expect(Set(scan.summaries.keys) == Set([rootID, visibleID]))
        #expect(scan.summaries[rootID]?.children == Set([visibleID]))
        #expect(scan.visitedEntries == 3)
    }

    #if os(macOS)
    @Test func varAliasKeepsPreparedNamespaceForCachedAndTraversedChildren() throws {
        let name = "PresenceTraversal-\(UUID().uuidString)"
        let root = try makeDirectory(URL(fileURLWithPath: "/var/tmp", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true))
        defer { try? FileManager.default.removeItem(at: root) }
        let physicalRoot = root.resolvingSymlinksInPath()
        try #require(root.path == "/var/tmp/" + name)
        try #require(physicalRoot.path == "/private/var/tmp/" + name)
        var isDirectory: ObjCBool = false
        let physicalExists = FileManager.default.fileExists(atPath: physicalRoot.path, isDirectory: &isDirectory)
        try #require(physicalExists && isDirectory.boolValue)

        let cached = try makeDirectory(root.appendingPathComponent("Cached Café %2F", isDirectory: true))
        let cachedDeep = try makeDirectory(cached.appendingPathComponent("Deep", isDirectory: true))
        let uncached = try makeDirectory(root.appendingPathComponent("Uncached", isDirectory: true))
        let nested = try makeDirectory(uncached.appendingPathComponent("日本語 #1", isDirectory: true))
        try Data().write(to: cachedDeep.appendingPathComponent("cached.mp4"))
        try Data().write(to: nested.appendingPathComponent("new.mkv"))
        let rootID = SourceTreeIdentity.folderID(for: root)
        let cachedID = SourceTreeIdentity.folderID(for: cached)
        let uncachedID = SourceTreeIdentity.folderID(for: uncached)
        let nestedID = SourceTreeIdentity.folderID(for: nested)
        try #require(rootID.utf8.elementsEqual(root.path.utf8))

        let scan = try traverse(root, maximumEntries: 1, cachedResults: [cachedID: true])
        #expect(scan.visitedEntries == 4)
        #expect(scan.results == [rootID: true, uncachedID: true, nestedID: true])
        #expect(Set(scan.summaries.keys) == Set([rootID, uncachedID, nestedID]))
        #expect(scan.summaries[rootID]?.children == Set([cachedID, uncachedID]))
        #expect(scan.summaries[uncachedID]?.children == Set([nestedID]))
        #expect(scan.summaries[nestedID]?.children.isEmpty == true)
        // Check every emitted identity, including cached children that have no
        // summary of their own. /private/var keys would miss the prepared cache.
        let returnedPaths = Array(scan.results.keys) + Array(scan.summaries.keys)
            + scan.summaries.values.flatMap { $0.children }
        #expect(returnedPaths.allSatisfy { $0.utf8.starts(with: rootID.utf8) })
    }

    @Test func packagesDoNotBecomeTraversableDirectoryChildren() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let package = try makeDirectory(root.appendingPathComponent("Bundle.app", isDirectory: true))
        try Data().write(to: package.appendingPathComponent("video.mp4"))
        // Package classification is a native Foundation contract. The portable
        // tests cover ordinary directories and links separately.
        #expect(try package.resourceValues(forKeys: [.isPackageKey]).isPackage == true)

        let scan = try traverse(root, maximumEntries: 1)
        let rootID = SourceTreeIdentity.folderID(for: root)
        #expect(scan.results == [rootID: false])
        #expect(Set(scan.summaries.keys) == Set([rootID]))
        #expect(scan.summaries[rootID]?.children.isEmpty == true)
        #expect(scan.visitedEntries == 1)
    }
    #endif

    private struct SummaryValue: Equatable {
        let hasDirectMedia: Bool
        let children: Set<String>
        let isComplete: Bool
        let isReadable: Bool

        init(_ summary: SourceMediaPresenceCursor.Summary) {
            hasDirectMedia = summary.hasDirectMedia
            children = summary.children
            isComplete = summary.isComplete
            isReadable = summary.isReadable
        }
    }

    private struct Traversal: Equatable {
        var results: [String: Bool] = [:]
        var summaries: [String: SummaryValue] = [:]
        var visitedEntries = 0
    }

    private func traverse(
        _ root: URL, maximumEntries: Int, cachedResults: [String: Bool] = [:]
    ) throws -> Traversal {
        let cursor = SourceMediaPresenceCursor(root: root, cachedResults: cachedResults)
        var traversal = Traversal()
        for _ in 0..<128 {
            // Entry limits determine these small-fixture slices. The generous
            // time limit avoids assertions about host speed or enumeration order.
            let batch = try cursor.nextBatch(maximumEntries: maximumEntries, timeBudget: 60)
            #expect(batch.visitedEntries <= maximumEntries)
            traversal.results.merge(batch.results) { _, new in new }
            traversal.summaries.merge(batch.summaries.mapValues(SummaryValue.init)) { _, new in new }
            traversal.visitedEntries += batch.visitedEntries
            if batch.isComplete { return traversal }
        }
        Issue.record("Small traversal fixture did not complete within 128 slices")
        return traversal
    }

    private func makeRoot() throws -> URL {
        try makeDirectory(FileManager.default.temporaryDirectory
            .appendingPathComponent("PresenceTraversal-\(UUID().uuidString)", isDirectory: true))
    }

    @discardableResult
    private func makeDirectory(_ url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
