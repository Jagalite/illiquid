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
        while scanner.isScanning && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!scanner.isScanning)
        #expect(scanner.startedJobCount == 2)
        #expect(scanner.results[changedID] == true)
        #expect(scanner.results[rootID] == true)
        #expect(scanner.results[siblingID] == false)

        try FileManager.default.removeItem(at: media)
        scanner.invalidate(paths: [changedID])
        #expect(scanner.results[rootID] == nil)
        #expect(scanner.results[siblingID] == false)
        while scanner.isScanning && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(scanner.results[rootID] == false)

        try FileManager.default.removeItem(at: changed)
        scanner.invalidate(paths: [rootID], trees: [changedID])
        while scanner.isScanning && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
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
