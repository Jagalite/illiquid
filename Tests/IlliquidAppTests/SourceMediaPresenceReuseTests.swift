import Foundation
import Testing
@testable import IlliquidApp

@Suite("Source media presence cache snapshots")
struct SourceMediaPresenceReuseTests {
    private typealias Summary = SourceMediaPresenceCursor.Summary

    private func summary(
        complete: Bool = true,
        readable: Bool = true,
        hasDirectMedia: Bool = false,
        children: Set<String> = []
    ) -> Summary {
        Summary(hasDirectMedia: hasDirectMedia, children: children,
            isComplete: complete, isReadable: readable)
    }

    @Test func rootAndDescendantsRetainBothPresenceValues() {
        let results = [
            "/Media/Show": true,
            "/Media/Show/Season": false,
            "/Media/Show/Season/Episode": true,
            "/Media/Show/Empty": false,
        ]
        let summaries = results.mapValues { summary(hasDirectMedia: $0) }

        #expect(SourceMediaPresenceCursor.reusableResults(
            in: "/Media/Show", results: results, summaries: summaries
        ) == results)
    }

    @Test func ancestorsPrefixSiblingsAndOtherRootsAreExcluded() {
        let results = [
            "/Media": true,
            "/Media/Show": false,
            "/Media/Show/Season": true,
            "/Media/Show2": true,
            "/Media/Showcase/Season": true,
            "/Media/Show-old/Season": false,
            "/Archive/Show/Season": true,
        ]
        let summaries = results.mapValues { _ in summary() }

        #expect(SourceMediaPresenceCursor.reusableResults(
            in: "/Media/Show", results: results, summaries: summaries
        ) == ["/Media/Show": false, "/Media/Show/Season": true])
        #expect(SourceMediaPresenceCursor.reusableResults(
            in: "/Missing", results: results, summaries: summaries
        ).isEmpty)
        #expect(SourceMediaPresenceCursor.reusableResults(
            in: "/Media", results: [:], summaries: summaries
        ).isEmpty)
    }

    @Test func filesystemRootMatchesAbsoluteDescendantsWithoutADoubleSeparator() {
        let results = [
            "/": false,
            "/Media": true,
            "/Archive/Empty": false,
            "relative/Media": true,
        ]
        let summaries = results.mapValues { _ in summary() }

        #expect(SourceMediaPresenceCursor.reusableResults(
            in: "/", results: results, summaries: summaries
        ) == ["/": false, "/Media": true, "/Archive/Empty": false])
    }

    @Test func missingIncompleteAndUnreadableSummariesCannotSeedReuse() {
        let results = [
            "/Media/Positive": true,
            "/Media/Negative": false,
            "/Media/MissingSummary": true,
            "/Media/IncompletePositive": true,
            "/Media/IncompleteNegative": false,
            "/Media/UnreadablePositive": true,
            "/Media/UnreadableNegative": false,
            "/Media/IncompleteAndUnreadable": true,
        ]
        let summaries = [
            // Reuse preserves the result; it does not derive it from direct media.
            "/Media/Positive": summary(hasDirectMedia: false),
            "/Media/Negative": summary(hasDirectMedia: true),
            "/Media/IncompletePositive": summary(complete: false),
            "/Media/IncompleteNegative": summary(complete: false),
            "/Media/UnreadablePositive": summary(readable: false),
            "/Media/UnreadableNegative": summary(readable: false),
            "/Media/IncompleteAndUnreadable": summary(complete: false, readable: false),
            "/Media/NoResult": summary(hasDirectMedia: true),
        ]

        #expect(SourceMediaPresenceCursor.reusableResults(
            in: "/Media", results: results, summaries: summaries
        ) == ["/Media/Positive": true, "/Media/Negative": false])
    }

    @Test func canonicallyEquivalentUnicodePathsKeepTheirOriginalKeys() {
        let composed = "/Volumes/Café"
        let decomposed = "/Volumes/Cafe\u{301}"
        let leaf = decomposed + "/动画/👩🏽‍💻"
        let punctuation = composed + "/100% complete/#1"
        let results = [
            decomposed: false,
            leaf: true,
            punctuation: false,
            composed + "2/动画": true,
        ]
        let summaries = [
            composed: summary(),
            composed + "/动画/👩🏽‍💻": summary(),
            decomposed + "/100% complete/#1": summary(),
            decomposed + "2/动画": summary(),
        ]

        for root in [composed, decomposed] {
            let reused = SourceMediaPresenceCursor.reusableResults(
                in: root, results: results, summaries: summaries)
            #expect(reused == [decomposed: false, leaf: true, punctuation: false])
            #expect(reused.keys.contains { $0.utf8.elementsEqual(decomposed.utf8) })
            #expect(reused.keys.contains { $0.utf8.elementsEqual(leaf.utf8) })
        }
    }

    @Test func snapshotRemainsIndependentWhenInputsChange() {
        var results = ["/Media/Present": true, "/Media/Empty": false, "/Other": true]
        var summaries = results.mapValues { _ in summary() }
        var snapshot = SourceMediaPresenceCursor.reusableResults(
            in: "/Media", results: results, summaries: summaries)

        results["/Media/Present"] = false
        results["/Media/Empty"] = nil
        results["/Media/New"] = true
        summaries.removeAll()

        #expect(snapshot == ["/Media/Present": true, "/Media/Empty": false])
        #expect(SourceMediaPresenceCursor.reusableResults(
            in: "/Media", results: results, summaries: summaries
        ).isEmpty)
        snapshot["/Media/New"] = false
        #expect(results["/Media/New"] == true)
    }

    @Test func scopedAndUnscopedCachesProduceEquivalentFilesystemTraversal() throws {
        let fixture = try makeRoot()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let root = try makeDirectory(fixture.appendingPathComponent("Repair"))
        let cachedMedia = try makeDirectory(root.appendingPathComponent("CachedMedia/Deep"))
        let cachedEmpty = try makeDirectory(root.appendingPathComponent("CachedEmpty/Deep"))
        let changed = try makeDirectory(root.appendingPathComponent("Changed/Inner"))
        let empty = try makeDirectory(root.appendingPathComponent("UncachedEmpty"))
        let unrelated = try makeDirectory(fixture.appendingPathComponent("Other"))
        let prefixSibling = try makeDirectory(fixture.appendingPathComponent("Repair-old"))
        try Data().write(to: cachedMedia.appendingPathComponent("video.mp4"))
        for index in 0..<4 {
            try Data().write(to: cachedEmpty.appendingPathComponent("notes-\(index).txt"))
        }
        try Data().write(to: changed.appendingPathComponent("video.mkv"))
        try Data().write(to: root.appendingPathComponent("notes.txt"))

        let rootID = SourceTreeIdentity.folderID(for: root)
        let cachedMediaID = SourceTreeIdentity.folderID(for: cachedMedia.deletingLastPathComponent())
        let cachedEmptyID = SourceTreeIdentity.folderID(for: cachedEmpty.deletingLastPathComponent())
        let changedID = SourceTreeIdentity.folderID(for: changed.deletingLastPathComponent())
        let innerID = SourceTreeIdentity.folderID(for: changed)
        let unrelatedID = SourceTreeIdentity.folderID(for: unrelated)
        let prefixSiblingID = SourceTreeIdentity.folderID(for: prefixSibling)
        let results = [
            rootID: true,
            cachedMediaID: true,
            cachedEmptyID: false,
            changedID: false,
            innerID: false,
            unrelatedID: true,
            prefixSiblingID: true,
        ]
        var summaries = results.mapValues { _ in summary() }
        summaries[changedID] = summary(complete: false)
        summaries[innerID] = summary(readable: false)
        let unscoped = results.filter {
            summaries[$0.key]?.isComplete == true && summaries[$0.key]?.isReadable == true
        }
        let scoped = SourceMediaPresenceCursor.reusableResults(
            in: rootID, results: results, summaries: summaries)
        #expect(scoped == [rootID: true, cachedMediaID: true, cachedEmptyID: false])

        let baseline = try traverse(root, cachedResults: unscoped)
        let candidate = try traverse(root, cachedResults: scoped)
        let uncached = try traverse(root, cachedResults: [:])

        // Aggregate batches by path: directory enumeration need not have a
        // stable order, but final summaries, results and traversal work must match.
        #expect(candidate == baseline)
        #expect(candidate.batchCount > 1)
        #expect(candidate.visitedEntries < uncached.visitedEntries)
        #expect(candidate.results[rootID] == true)
        #expect(candidate.results[changedID] == true)
        #expect(candidate.results[innerID] == true)
        #expect(candidate.results[SourceTreeIdentity.folderID(for: empty)] == false)
        #expect(candidate.results[cachedMediaID] == nil)
        #expect(candidate.results[cachedEmptyID] == nil)
    }

    @MainActor @Test func repairingOneWatchedRootPreservesTheOtherRootsResults() async throws {
        let fixture = try makeRoot()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let first = try makeDirectory(fixture.appendingPathComponent("First"))
        let changed = try makeDirectory(first.appendingPathComponent("Changed"))
        let sibling = try makeDirectory(first.appendingPathComponent("Unchanged"))
        let second = try makeDirectory(fixture.appendingPathComponent("Second"))
        let secondChild = try makeDirectory(second.appendingPathComponent("Media"))
        try Data().write(to: secondChild.appendingPathComponent("existing.mp4"))
        let firstID = SourceTreeIdentity.folderID(for: first)
        let changedID = SourceTreeIdentity.folderID(for: changed)
        let siblingID = SourceTreeIdentity.folderID(for: sibling)
        let secondID = SourceTreeIdentity.folderID(for: second)
        let secondChildID = SourceTreeIdentity.folderID(for: secondChild)
        let scanner = SourceMediaPresenceScanner()
        defer { scanner.stop() }

        scanner.setRoots([first, second])
        try await waitForScan(scanner)
        #expect(scanner.results[firstID] == false)
        #expect(scanner.results[changedID] == false)
        #expect(scanner.results[siblingID] == false)
        #expect(scanner.results[secondID] == true)
        #expect(scanner.results[secondChildID] == true)
        let initialJobs = scanner.startedJobCount
        #expect(initialJobs == 2)

        let media = changed.appendingPathComponent("new.mkv")
        try Data().write(to: media)
        scanner.invalidate(paths: [changedID])
        #expect(scanner.results[secondID] == true)
        #expect(scanner.results[secondChildID] == true)
        try await waitForScan(scanner)
        #expect(scanner.results[firstID] == true)
        #expect(scanner.results[changedID] == true)
        #expect(scanner.results[siblingID] == false)
        #expect(scanner.results[secondID] == true)
        #expect(scanner.results[secondChildID] == true)
        #expect(scanner.startedJobCount == initialJobs + 1)

        try FileManager.default.removeItem(at: media)
        scanner.invalidate(paths: [changedID])
        try await waitForScan(scanner)
        #expect(scanner.results[firstID] == false)
        #expect(scanner.results[changedID] == false)
        #expect(scanner.results[siblingID] == false)
        #expect(scanner.results[secondID] == true)
        #expect(scanner.results[secondChildID] == true)
        #expect(scanner.startedJobCount == initialJobs + 2)
    }

    private struct SummaryValue: Equatable {
        let hasDirectMedia: Bool
        let children: Set<String>
        let isComplete: Bool
        let isReadable: Bool

        init(_ summary: Summary) {
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
        var batchCount = 0
    }

    private func traverse(_ root: URL, cachedResults: [String: Bool]) throws -> Traversal {
        let cursor = SourceMediaPresenceCursor(root: root, cachedResults: cachedResults)
        var traversal = Traversal()
        while traversal.batchCount < 100 {
            // A generous time budget makes the entry limit determine slices;
            // no test depends on host speed or enumeration order.
            let batch = try cursor.nextBatch(maximumEntries: 2, timeBudget: 60)
            #expect(batch.visitedEntries <= 2)
            traversal.results.merge(batch.results) { _, new in new }
            traversal.summaries.merge(batch.summaries.mapValues(SummaryValue.init)) { _, new in new }
            traversal.visitedEntries += batch.visitedEntries
            traversal.batchCount += 1
            if batch.isComplete { return traversal }
        }
        Issue.record("Small fixture did not finish within 100 bounded slices")
        return traversal
    }

    private func makeRoot() throws -> URL {
        try makeDirectory(FileManager.default.temporaryDirectory
            .appendingPathComponent("PresenceReuse-\(UUID().uuidString)", isDirectory: true))
    }

    @discardableResult
    private func makeDirectory(_ url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @MainActor
    private func waitForScan(_ scanner: SourceMediaPresenceScanner) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while scanner.isScanning && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(!scanner.isScanning)
    }
}
