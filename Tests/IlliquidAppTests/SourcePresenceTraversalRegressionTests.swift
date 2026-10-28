import Foundation
import Testing
@testable import IlliquidApp

@Suite("Source presence traversal directory identities")
struct SourcePresenceTraversalRegressionTests {
    @Test func literalDirectoryNamesAndFileOnlySlicesKeepCompleteSummaries() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = try makeDirectory(root.appendingPathComponent("Cafe\u{301} 100% #1"))
        let leaf = try makeDirectory(parent.appendingPathComponent("动画 👩🏽‍💻"))
        let percent = try makeDirectory(root.appendingPathComponent("literal%2Fcomponent"))
        let empty = try makeDirectory(root.appendingPathComponent("Directory mp4 collection"))
        try Data().write(to: root.appendingPathComponent("read me #1.txt"))
        for index in 0..<12 {
            try Data().write(to: parent.appendingPathComponent("notes-\(index).txt"))
        }
        try Data().write(to: leaf.appendingPathComponent("Episode 100% #1.MKV"))
        try Data().write(to: leaf.appendingPathComponent("Episode 100% #1.srt"))
        try Data().write(to: percent.appendingPathComponent("video.mp4.txt"))

        let smallSlices = try traverse(root, maximumEntries: 1)
        let largeSlices = try traverse(root, maximumEntries: 256)
        #expect(smallSlices == largeSlices)
        #expect(smallSlices.visitedEntries == 20)

        let rootID = SourceTreeIdentity.folderID(for: root)
        let parentID = SourceTreeIdentity.folderID(for: parent)
        let leafID = SourceTreeIdentity.folderID(for: leaf)
        let percentID = SourceTreeIdentity.folderID(for: percent)
        let emptyID = SourceTreeIdentity.folderID(for: empty)
        #expect(smallSlices.results == [
            rootID: true, parentID: true, leafID: true,
            percentID: false, emptyID: false,
        ])
        #expect(smallSlices.summaries == [
            rootID: SummaryValue(children: [parentID, percentID, emptyID]),
            parentID: SummaryValue(children: [leafID]),
            leafID: SummaryValue(hasDirectMedia: true),
            percentID: SummaryValue(),
            emptyID: SummaryValue(),
        ])
        // A literal percent-escaped separator must stay one directory component.
        #expect(percentID.hasSuffix("/literal%2Fcomponent"))
    }

    @Test func namedCachedSubtreesKeepBothPresenceValuesAndSkipTheirFiles() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let positive = try makeDirectory(root.appendingPathComponent("Known #1% animé"))
        let negative = try makeDirectory(root.appendingPathComponent("Known%2Fempty"))
        let uncached = try makeDirectory(root.appendingPathComponent("Empty mkv collection"))
        for folder in [positive, negative] {
            let nested = try makeDirectory(folder.appendingPathComponent("Nested 空"))
            for index in 0..<4 {
                try Data().write(to: nested.appendingPathComponent("notes-\(index).txt"))
            }
        }
        try Data().write(to: positive.appendingPathComponent("video.MP4"))

        let rootID = SourceTreeIdentity.folderID(for: root)
        let positiveID = SourceTreeIdentity.folderID(for: positive)
        let negativeID = SourceTreeIdentity.folderID(for: negative)
        let uncachedID = SourceTreeIdentity.folderID(for: uncached)
        let cached = try traverse(root, maximumEntries: 1,
            cachedResults: [positiveID: true, negativeID: false])
        let fresh = try traverse(root, maximumEntries: 1)

        #expect(cached.visitedEntries == 3)
        #expect(fresh.visitedEntries == 14)
        #expect(cached.results == [rootID: true, uncachedID: false])
        #expect(cached.summaries == [
            rootID: SummaryValue(children: [positiveID, negativeID, uncachedID]),
            uncachedID: SummaryValue(),
        ])
        #expect(fresh.results[rootID] == cached.results[rootID])
        #expect(fresh.results[positiveID] == true)
        #expect(fresh.results[negativeID] == false)
    }

    #if os(macOS)
    @Test func temporaryDirectoryAliasKeepsTheCallersCacheNamespace() throws {
        let root = try makeRoot(in: URL(fileURLWithPath: "/tmp", isDirectory: true))
        defer { try? FileManager.default.removeItem(at: root) }
        let physicalRoot = root.resolvingSymlinksInPath()
        let child = try makeDirectory(root.appendingPathComponent("Cached #1%"))
        let nested = try makeDirectory(child.appendingPathComponent("Nested"))
        try Data().write(to: nested.appendingPathComponent("video.mkv"))

        let aliasRootID = SourceTreeIdentity.folderID(for: root)
        let physicalRootID = SourceTreeIdentity.folderID(for: physicalRoot)
        let aliasChildID = SourceTreeIdentity.folderID(for: child)
        let physicalChildID = SourceTreeIdentity.folderID(
            for: physicalRoot.appendingPathComponent(child.lastPathComponent))
        #expect(aliasRootID.hasPrefix("/tmp/"))
        #expect(physicalRootID.hasPrefix("/private/tmp/"))

        for (selectedRoot, rootID, childID) in [
            (root, aliasRootID, aliasChildID),
            (physicalRoot, physicalRootID, physicalChildID),
        ] {
            let traversal = try traverse(selectedRoot, maximumEntries: 1,
                cachedResults: [childID: true])
            #expect(traversal.visitedEntries == 1)
            #expect(traversal.results == [rootID: true])
            #expect(traversal.summaries == [rootID: SummaryValue(children: [childID])])
        }
    }
    #endif

    private struct SummaryValue: Equatable {
        var hasDirectMedia = false
        var children: Set<String> = []
        var isComplete = true
        var isReadable = true
    }

    private struct Traversal: Equatable {
        var results: [String: Bool] = [:]
        var summaries: [String: SummaryValue] = [:]
        var visitedEntries = 0
    }

    private func traverse(_ root: URL, maximumEntries: Int,
                          cachedResults: [String: Bool] = [:]) throws -> Traversal {
        let cursor = SourceMediaPresenceCursor(root: root, cachedResults: cachedResults)
        var traversal = Traversal()
        for _ in 0..<100 {
            // Keep slice boundaries independent of host speed. Correctness is
            // asserted from final maps, not filesystem enumeration order.
            let batch = try cursor.nextBatch(maximumEntries: maximumEntries, timeBudget: 60)
            #expect(batch.visitedEntries <= maximumEntries)
            traversal.results.merge(batch.results) { _, new in new }
            for (path, summary) in batch.summaries {
                traversal.summaries[path] = SummaryValue(
                    hasDirectMedia: summary.hasDirectMedia, children: summary.children,
                    isComplete: summary.isComplete, isReadable: summary.isReadable)
            }
            traversal.visitedEntries += batch.visitedEntries
            if batch.isComplete { return traversal }
        }
        Issue.record("Small traversal fixture did not finish within 100 bounded slices")
        return traversal
    }

    private func makeRoot(in parent: URL = FileManager.default.temporaryDirectory) throws -> URL {
        try makeDirectory(parent.appendingPathComponent("PresenceTraversal-\(UUID().uuidString)",
                                                       isDirectory: true))
    }

    @discardableResult
    private func makeDirectory(_ url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
