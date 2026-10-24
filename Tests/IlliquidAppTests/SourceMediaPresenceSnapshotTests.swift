import Foundation
import Testing
@testable import IlliquidApp

@Suite("Source presence repair snapshots")
struct SourceMediaPresenceSnapshotTests {
    private typealias Summary = SourceMediaPresenceCursor.Summary

    @Test func confirmedRootAndDescendantsPreservePositiveAndNegativeValues() {
        let root = "/Media/Shows"
        let results = [root: true, root + "/Present": true, root + "/Absent": false]
        var summaries = results.mapValues { summary(hasDirectMedia: $0) }
        summaries[root + "/NoKnownResult"] = summary()

        #expect(SourceMediaPresenceCursor.reusableResults(
            for: root, results: results, summaries: summaries) == results)
    }

    @Test(arguments: [false, true])
    func incompleteUnreadableAndMissingSummariesAreExcluded(value: Bool) {
        let root = "/Media"
        let confirmed = root + "/Confirmed"
        let incomplete = root + "/Incomplete"
        let unreadable = root + "/Unreadable"
        let both = root + "/IncompleteAndUnreadable"
        let missing = root + "/MissingSummary"
        let results = [confirmed: value, incomplete: value, unreadable: value,
                       both: value, missing: value]
        let summaries = [
            confirmed: summary(hasDirectMedia: value),
            incomplete: summary(hasDirectMedia: value, isComplete: false),
            unreadable: summary(hasDirectMedia: value, isReadable: false),
            both: summary(hasDirectMedia: value, isComplete: false, isReadable: false),
        ]

        #expect(SourceMediaPresenceCursor.reusableResults(
            for: root, results: results, summaries: summaries) == [confirmed: value])
    }

    @Test func ancestorsAndPrefixSiblingsCannotEnterTheJobSnapshot() {
        let root = "/Media/Show"
        let child = root + "/Season 01"
        let results = [
            "/": true,
            "/Media": true,
            root: false,
            child: false,
            child + "/Extras": true,
            "/Media/Showcase": true,
            "/Media/Shows/Season 01": true,
            "/Archive/Media/Show": true,
            "/media/show": true,
        ]

        #expect(SourceMediaPresenceCursor.reusableResults(
            for: root, results: results, summaries: results.mapValues { _ in summary() })
                == [root: false, child: false, child + "/Extras": true])
    }

    @Test func filesystemRootIncludesAbsoluteDescendantsOnly() {
        let results = ["/": false, "/Media": true, "/Volumes/节目": false,
                       "": true, "relative": true, "Media/Shows": true]

        #expect(SourceMediaPresenceCursor.reusableResults(
            for: "/", results: results, summaries: results.mapValues { _ in summary() })
                == ["/": false, "/Media": true, "/Volumes/节目": false])
    }

    @Test func equivalentUnicodeSpellingsPreserveMatchingDirectoryIdentities() {
        let root = "/Volumes/Café"
        let decomposedRoot = "/Volumes/Cafe\u{301}"
        let animated = decomposedRoot + "/动画/👩🏽‍💻"
        let punctuation = root + "/100% complete/#1"
        let results = [decomposedRoot: true, animated: false, punctuation: true,
                       "/Volumes/Caféteria": true, "/Volumes/Cafe": false]
        #expect(root == decomposedRoot)

        #expect(SourceMediaPresenceCursor.reusableResults(
            for: root, results: results, summaries: results.mapValues { _ in summary() })
                == [root: true, animated: false, punctuation: true])
    }

    @Test func snapshotValuesDoNotChangeWhenTheScannerCachesChange() {
        let root = "/Media"
        let child = root + "/Child"
        var results = [root: true, child: false, "/Other": true]
        var summaries = results.mapValues { _ in summary() }
        let snapshot = SourceMediaPresenceCursor.reusableResults(
            for: root, results: results, summaries: summaries)

        results[root] = nil
        results[child] = true
        results[root + "/New"] = false
        summaries[root] = nil
        summaries[child] = summary(isComplete: false)

        #expect(snapshot == [root: true, child: false])
        #expect(SourceMediaPresenceCursor.reusableResults(
            for: root, results: results, summaries: summaries).isEmpty)
        var changedSnapshot = snapshot
        changedSnapshot[child] = nil
        #expect(snapshot[child] == false)
        #expect(results[child] == true)
        #expect(changedSnapshot == [root: true])
    }

    @Test(arguments: [1, 2, 7, 256])
    func scopedSnapshotPreservesTraversalAndCachedSubtreeSkipping(batchLimit: Int) throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("PresenceSnapshot-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let root = temporary.appendingPathComponent("Job", isDirectory: true)
        let names = ["CachedPresent", "CachedAbsent", "Incomplete", "Unreadable", "Missing", "Fresh/Nested"]
        for name in names {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(name, isDirectory: true), withIntermediateDirectories: true)
        }
        for index in 0..<24 {
            try Data().write(to: root.appendingPathComponent("CachedPresent/movie-\(index).mkv"))
            try Data().write(to: root.appendingPathComponent("CachedAbsent/notes-\(index).txt"))
        }
        for name in ["Incomplete", "Unreadable", "Missing", "Fresh/Nested"] {
            try Data().write(to: root.appendingPathComponent(name + "/new.mp4"))
        }
        try Data().write(to: root.appendingPathComponent("notes.txt"))

        let rootID = SourceTreeIdentity.folderID(for: root)
        let present = rootID + "/CachedPresent"
        let absent = rootID + "/CachedAbsent"
        let incomplete = rootID + "/Incomplete"
        let unreadable = rootID + "/Unreadable"
        let missing = rootID + "/Missing"
        let parent = SourceTreeIdentity.folderID(for: temporary)
        let results = [present: true, absent: false, incomplete: false, unreadable: false,
                       missing: false, parent: true, rootID + "2": false, parent + "/Other": true]
        var summaries = results.mapValues { _ in summary() }
        summaries[incomplete] = summary(isComplete: false)
        summaries[unreadable] = summary(isReadable: false)
        summaries[missing] = nil

        // This is the previous scanner policy: every confirmed result from
        // every watched tree was captured by each individual repair job.
        let fullSnapshot = results.filter { entry in
            summaries[entry.key]?.isComplete == true && summaries[entry.key]?.isReadable == true
        }
        let scopedSnapshot = SourceMediaPresenceCursor.reusableResults(
            for: rootID, results: results, summaries: summaries)
        #expect(fullSnapshot.count == 5)
        #expect(scopedSnapshot == [present: true, absent: false])

        let full = try scan(root, cachedResults: fullSnapshot, batchLimit: batchLimit)
        let scoped = try scan(root, cachedResults: scopedSnapshot, batchLimit: batchLimit)
        #expect(scoped == full)
        #expect(scoped.visitedEntries == 12)
        #expect(scoped.results[rootID] == true)
        for changed in [incomplete, unreadable, missing] {
            #expect(scoped.results[changed] == true)
            #expect(scoped.summaries[changed]?.isComplete == true)
        }
        // Both positive and negative cached descendants are skipped completely.
        #expect(scoped.summaries[present] == nil)
        #expect(scoped.summaries[absent] == nil)
        let uncached = try scan(root, cachedResults: [:], batchLimit: batchLimit)
        #expect(uncached.visitedEntries == scoped.visitedEntries + 48)
        #expect(uncached.results[present] == true)
        #expect(uncached.results[absent] == false)
    }

    private func summary(hasDirectMedia: Bool = false, isComplete: Bool = true,
                         isReadable: Bool = true) -> Summary {
        Summary(hasDirectMedia: hasDirectMedia, children: [],
                isComplete: isComplete, isReadable: isReadable)
    }

    private struct ObservedSummary: Equatable {
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

    private struct Scan: Equatable {
        var results: [String: Bool] = [:]
        var summaries: [String: ObservedSummary] = [:]
        var visitedEntries = 0
    }

    private func scan(_ root: URL, cachedResults: [String: Bool], batchLimit: Int) throws -> Scan {
        let cursor = SourceMediaPresenceCursor(root: root, cachedResults: cachedResults)
        var scan = Scan()
        for _ in 0..<1_000 {
            let batch = try cursor.nextBatch(maximumEntries: batchLimit, timeBudget: 10)
            #expect(batch.visitedEntries <= batchLimit)
            scan.results.merge(batch.results) { _, new in new }
            scan.summaries.merge(batch.summaries.mapValues(ObservedSummary.init)) { _, new in new }
            scan.visitedEntries += batch.visitedEntries
            if batch.isComplete { return scan }
        }
        throw CocoaError(.fileReadUnknown)
    }
}
