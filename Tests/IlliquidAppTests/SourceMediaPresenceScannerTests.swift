import Foundation
import Testing
@testable import IlliquidApp

@Suite("Bounded source media scanner")
struct SourceMediaPresenceScannerTests {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PresenceScanner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func wideTreeUsesBoundedSlicesAndListingDoesNotScanDescendants() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<300 {
            let folder = root.appendingPathComponent("Folder-\(index)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data().write(to: folder.appendingPathComponent("notes.txt"))
        }
        let listing = SourceDirectoryLoader.read(root)
        #expect(listing.entries.count == 300)
        let input = SourceTreeProjectionInput(
            items: [.init(kind: .folder, url: root)], visibility: .default, roots: [root],
            directoryContents: [SourceTreeIdentity.folderID(for: root): listing.entries],
            directoryErrors: [:], recursiveMediaEntries: [], expandedFolderIDs: [],
            sortConfiguration: .init(name: .ascending, dateCreated: .off, type: .off))
        #expect(input.rows().allSatisfy { $0.containsSupportedMedia == nil })
        let cursor = SourceMediaPresenceCursor(root: root)
        var results: [String: Bool] = [:]
        var batches = 0
        while true {
            let batch = try cursor.nextBatch(maximumEntries: 7)
            #expect(batch.visitedEntries <= 7)
            results.merge(batch.results) { _, new in new }
            batches += 1
            if batch.isComplete { break }
        }
        #expect(batches > 80)
        #expect(results.count == 301)
        #expect(results.values.allSatisfy { !$0 })
    }

    @Test func deepTreePropagatesMediaWithoutRecursiveCallsAndSkipsHiddenPackagesAndLinks() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var leaf = root
        for _ in 0..<100 { leaf.appendPathComponent("d", isDirectory: true) }
        try FileManager.default.createDirectory(at: leaf, withIntermediateDirectories: true)
        try Data().write(to: leaf.appendingPathComponent("video.MKV"))
        let excluded = root.appendingPathComponent("Excluded", isDirectory: true)
        try FileManager.default.createDirectory(at: excluded, withIntermediateDirectories: true)
        try Data().write(to: excluded.appendingPathComponent(".hidden.mp4"))
        let package = excluded.appendingPathComponent("Bundle.app", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try Data().write(to: package.appendingPathComponent("video.mp4"))
        try FileManager.default.createSymbolicLink(at: excluded.appendingPathComponent("loop"), withDestinationURL: root)
        let cursor = SourceMediaPresenceCursor(root: root)
        var results: [String: Bool] = [:]
        while true {
            let batch = try cursor.nextBatch(maximumEntries: 3)
            results.merge(batch.results) { _, new in new }
            if batch.isComplete { break }
        }
        #expect(results[SourceTreeIdentity.folderID(for: root)] == true)
        #expect(results[SourceTreeIdentity.folderID(for: leaf)] == true)
        #expect(results[SourceTreeIdentity.folderID(for: excluded)] == false)
    }

    @Test func unavailableFolderIsUnknown() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let batch = try SourceMediaPresenceCursor(root: root).nextBatch()
        #expect(batch.isComplete)
        #expect(batch.results.isEmpty)
    }

    @Test func repairTraversalSkipsConfirmedSiblingSubtrees() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let unchanged = root.appendingPathComponent("Unchanged", isDirectory: true)
        let changed = root.appendingPathComponent("Changed", isDirectory: true)
        for folder in [unchanged, changed] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        for index in 0..<600 {
            try Data().write(to: unchanged.appendingPathComponent("notes-\(index).txt"))
        }
        let cursor = SourceMediaPresenceCursor(root: root,
            cachedResults: [SourceTreeIdentity.folderID(for: unchanged): false])
        var visited = 0
        while true {
            let batch = try cursor.nextBatch()
            visited += batch.visitedEntries
            if batch.isComplete { break }
        }
        #expect(visited == 2)
    }

    @Test func scopedRepairSnapshotPreservesPositiveAndNegativeSubtreeReuse() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let present = root.appendingPathComponent("Present", isDirectory: true)
        let absent = root.appendingPathComponent("Absent", isDirectory: true)
        let changed = root.appendingPathComponent("Changed", isDirectory: true)
        for folder in [present, absent, changed] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try Data().write(to: present.appendingPathComponent("video.mp4"))
        for index in 0..<20 {
            try Data().write(to: absent.appendingPathComponent("notes-\(index).txt"))
        }

        // The prepared namespace can differ from DirectoryEnumerator's URLs
        // on macOS (/var versus /private/var). Build every cache identity with
        // the same public boundary used by the scanner, not enumerator paths.
        let rootID = SourceTreeIdentity.folderID(for: root)
        let presentID = SourceTreeIdentity.folderID(for: present)
        let absentID = SourceTreeIdentity.folderID(for: absent)
        let changedID = SourceTreeIdentity.folderID(for: changed)
        let wholeCache = [
            presentID: true, absentID: false,
            rootID + "-other/Present": true, "/Unrelated/Absent": false,
        ]
        let scoped = SourceMediaPresenceSnapshot.reusableResults(
            under: rootID, results: wholeCache, isReusable: { _ in true }
        )
        #expect(scoped == [presentID: true, absentID: false])

        func scan(_ cache: [String: Bool]) throws -> (results: [String: Bool], visited: Int) {
            let cursor = SourceMediaPresenceCursor(root: root, cachedResults: cache)
            var results: [String: Bool] = [:]
            var visited = 0
            while true {
                let batch = try cursor.nextBatch(maximumEntries: 1)
                results.merge(batch.results) { _, new in new }
                visited += batch.visitedEntries
                if batch.isComplete { return (results, visited) }
            }
        }
        let original = try scan(wholeCache)
        let candidate = try scan(scoped)
        #expect(candidate.results == original.results)
        #expect(candidate.results == [rootID: true, changedID: false])
        #expect(candidate.visited == original.visited)
        #expect(candidate.visited == 3)
        let uncached = try scan([:])
        #expect(uncached.visited == 24)
        #expect(uncached.results == [rootID: true, presentID: true, absentID: false, changedID: false])
    }

    @MainActor @Test func narrowRepairKeepsCachedChildrenAndOtherWatchedRootsCorrect() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("Library", isDirectory: true)
        // The other watched root is deliberately a textual prefix sibling.
        let archive = root.appendingPathComponent("Library-Archive", isDirectory: true)
        let repair = library.appendingPathComponent("Repair", isDirectory: true)
        let present = repair.appendingPathComponent("Present", isDirectory: true)
        let absent = repair.appendingPathComponent("Absent", isDirectory: true)
        let unchanged = library.appendingPathComponent("Unchanged", isDirectory: true)
        let archivePresent = archive.appendingPathComponent("Present", isDirectory: true)
        let archiveAbsent = archive.appendingPathComponent("Absent", isDirectory: true)
        for folder in [present, absent, unchanged, archivePresent, archiveAbsent] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let presentMedia = present.appendingPathComponent("episode.mkv")
        let directMedia = repair.appendingPathComponent("new.mp4")
        try Data().write(to: presentMedia)
        try Data().write(to: archivePresent.appendingPathComponent("film.mp4"))
        try Data().write(to: absent.appendingPathComponent("notes.txt"))

        let libraryID = SourceTreeIdentity.folderID(for: library)
        let repairID = SourceTreeIdentity.folderID(for: repair)
        let presentID = SourceTreeIdentity.folderID(for: present)
        let absentID = SourceTreeIdentity.folderID(for: absent)
        let unchangedID = SourceTreeIdentity.folderID(for: unchanged)
        let archiveID = SourceTreeIdentity.folderID(for: archive)
        let archivePresentID = SourceTreeIdentity.folderID(for: archivePresent)
        let archiveAbsentID = SourceTreeIdentity.folderID(for: archiveAbsent)
        let scanner = SourceMediaPresenceScanner()
        defer { scanner.stop() }
        func waitForScan() async throws {
            let deadline = ContinuousClock.now + .seconds(5)
            while scanner.isScanning && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            try #require(!scanner.isScanning)
        }
        scanner.setRoots([library, archive])
        try await waitForScan()
        let initial = [
            libraryID: true, repairID: true, presentID: true, absentID: false,
            unchangedID: false, archiveID: true, archivePresentID: true, archiveAbsentID: false,
        ]
        #expect(scanner.results == initial)
        #expect(scanner.startedJobCount == 2)

        // The narrow repair changes only this directory's listing. Both known
        // positive and negative children remain valid cursor shortcuts.
        try Data().write(to: directMedia)
        scanner.invalidate(paths: [repairID])
        #expect(scanner.results[libraryID] == nil)
        #expect(scanner.results[repairID] == nil)
        #expect(scanner.results[presentID] == true)
        #expect(scanner.results[absentID] == false)
        #expect(scanner.results[archiveID] == true)
        try await waitForScan()
        #expect(scanner.results == initial)
        #expect(scanner.startedJobCount == 3)

        // Invalidate the changed child as well, so its earlier positive result
        // cannot mask disappearance. The parent repair subsumes that child job.
        try FileManager.default.removeItem(at: directMedia)
        try FileManager.default.removeItem(at: presentMedia)
        scanner.invalidate(paths: [repairID, presentID])
        #expect(scanner.results[presentID] == nil)
        #expect(scanner.results[absentID] == false)
        #expect(scanner.results[unchangedID] == false)
        #expect(scanner.results[archivePresentID] == true)
        #expect(scanner.results[archiveAbsentID] == false)
        try await waitForScan()
        #expect(scanner.results == [
            libraryID: false, repairID: false, presentID: false, absentID: false,
            unchangedID: false, archiveID: true, archivePresentID: true, archiveAbsentID: false,
        ])
        #expect(scanner.startedJobCount == 4)
    }

    @MainActor @Test func eventBurstDoesNotRestartActiveJobAndRepairsAncestorStatus() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let changed = root.appendingPathComponent("Changed", isDirectory: true)
        let sibling = root.appendingPathComponent("Sibling", isDirectory: true)
        for folder in [changed, sibling] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        for index in 0..<1_000 {
            try Data().write(to: root.appendingPathComponent("notes-\(index).txt"))
        }
        let scanner = SourceMediaPresenceScanner()
        defer { scanner.stop() }
        func waitForScan() async throws {
            // Each invalidation starts a distinct operation with its own bound.
            let deadline = ContinuousClock.now + .seconds(5)
            while scanner.isScanning && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            try #require(!scanner.isScanning)
        }
        scanner.setRoots([root])
        let deadline = ContinuousClock.now + .seconds(5)
        while scanner.startedJobCount == 0 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(scanner.startedJobCount == 1)
        #expect(scanner.isScanning)
        let changedID = SourceTreeIdentity.folderID(for: changed)
        let rootID = SourceTreeIdentity.folderID(for: root)
        let siblingID = SourceTreeIdentity.folderID(for: sibling)
        let media = changed.appendingPathComponent("video.mp4")
        try Data().write(to: media)
        for _ in 0..<20 { scanner.invalidate(paths: [changedID]) }
        #expect(scanner.startedJobCount == 1)
        try await waitForScan()
        #expect(!scanner.isScanning)
        #expect(scanner.startedJobCount == 2)
        #expect(scanner.results[changedID] == true)
        #expect(scanner.results[rootID] == true)
        #expect(scanner.results[siblingID] == false)

        try FileManager.default.removeItem(at: media)
        scanner.invalidate(paths: [changedID])
        #expect(scanner.results[rootID] == nil)
        #expect(scanner.results[siblingID] == false)
        try await waitForScan()
        #expect(scanner.results[rootID] == false)

        try FileManager.default.removeItem(at: changed)
        scanner.invalidate(paths: [rootID], trees: [changedID])
        try await waitForScan()
        #expect(scanner.results[changedID] == nil)
        #expect(scanner.results[rootID] == false)
        #expect(scanner.results[siblingID] == false)
    }

    @MainActor @Test func listenerInvalidationAndManualRescanRefreshCachedResults() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let child = root.appendingPathComponent("Child", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        let scanner = SourceMediaPresenceScanner()
        defer { scanner.stop() }
        func wait() async throws {
            let deadline = ContinuousClock.now + .seconds(5)
            while scanner.isScanning && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(!scanner.isScanning)
        }
        scanner.setRoots([root, child])
        try await wait()
        let childID = SourceTreeIdentity.folderID(for: child)
        #expect(scanner.results[childID] == false)
        let media = child.appendingPathComponent("video.mp4")
        try Data().write(to: media)
        scanner.invalidate(paths: [childID])
        #expect(scanner.results[childID] == nil)
        try await wait()
        #expect(scanner.results[childID] == true)
        try FileManager.default.removeItem(at: media)
        scanner.rescan()
        #expect(scanner.results.isEmpty)
        try await wait()
        #expect(scanner.results[childID] == false)
        scanner.rescan()
        scanner.setRoots([])
        try await Task.sleep(for: .milliseconds(30))
        #expect(scanner.results.isEmpty)
        #expect(!scanner.isScanning)
    }
}
