import Foundation
import Observation
import Testing
@testable import IlliquidApp

@Suite("Source presence invalidation")
@MainActor
struct SourceMediaPresenceInvalidationTests {
    private final class Changes: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func increment() { lock.withLock { count += 1 } }
        var value: Int { lock.withLock { count } }
    }

    @Test func listingBatchDroppingEveryResultReleasesEmptyStorage() async throws {
        let tree = try makeTree()
        defer { try? FileManager.default.removeItem(at: tree.root) }
        let scanner = SourceMediaPresenceScanner()
        defer { scanner.stop() }
        scanner.setRoots([tree.root])
        try await waitForScan(scanner)
        let original = scanner.results
        try #require(!original.isEmpty)

        scanner.invalidate(paths: Set(original.keys))
        #expect(scanner.results.isEmpty)
        #expect(scanner.results.capacity == 0)
        #expect(original[SourceTreeIdentity.folderID(for: tree.leaf)] == true)
        try await waitForScan(scanner)
        #expect(scanner.results == original)
    }

    @Test func listingChangesPreserveNoOpObservationAndRetainedSnapshots() async throws {
        let tree = try makeTree()
        defer { try? FileManager.default.removeItem(at: tree.root) }
        let scanner = SourceMediaPresenceScanner()
        defer { scanner.stop() }
        scanner.setRoots([tree.root])
        try await waitForScan(scanner)
        let snapshot = scanner.results
        let root = SourceTreeIdentity.folderID(for: tree.root)
        let branch = SourceTreeIdentity.folderID(for: tree.branch)
        let leaf = SourceTreeIdentity.folderID(for: tree.leaf)
        let sibling = SourceTreeIdentity.folderID(for: tree.sibling)

        let changed = Changes()
        withObservationTracking { _ = scanner.results } onChange: { changed.increment() }
        scanner.invalidate(paths: [branch])
        #expect(changed.value == 1)
        #expect(scanner.results[root] == nil)
        #expect(scanner.results[branch] == nil)
        #expect(scanner.results[leaf] == snapshot[leaf])
        #expect(snapshot[root] == true)
        #expect(snapshot[branch] == true)
        #expect(snapshot[sibling] == false)

        // No await: the scheduled scan cannot republish between these events.
        // A repeat changes revision bookkeeping but no published result value.
        let repeated = Changes()
        withObservationTracking { _ = scanner.results } onChange: { repeated.increment() }
        scanner.invalidate(paths: [branch])
        #expect(repeated.value == 0)
        scanner.invalidate(paths: [], trees: [root + "-unwatched"])
        #expect(repeated.value == 0)
        scanner.invalidate(paths: [sibling])
        #expect(repeated.value == 1)
        #expect(scanner.results[sibling] == nil)
        #expect(snapshot[sibling] == false)
        try await waitForScan(scanner)
        #expect(scanner.results == snapshot)
    }

    @Test func listingChangeWithUnwatchedTreeArgumentsKeepsDescendantAndSiblingResults() async throws {
        let tree = try makeTree()
        defer { try? FileManager.default.removeItem(at: tree.root) }
        let scanner = SourceMediaPresenceScanner()
        defer { scanner.stop() }
        scanner.setRoots([tree.root])
        try await waitForScan(scanner)
        let original = scanner.results
        let jobs = scanner.startedJobCount
        let root = SourceTreeIdentity.folderID(for: tree.root)
        let branch = SourceTreeIdentity.folderID(for: tree.branch)
        let leaf = SourceTreeIdentity.folderID(for: tree.leaf)
        let sibling = SourceTreeIdentity.folderID(for: tree.sibling)
        #expect(original[root] == true)
        #expect(original[branch] == true)
        #expect(original[leaf] == true)
        #expect(original[sibling] == false)

        // These subtree inputs are present, but none is watched. The effective
        // subtree set is empty and only the listing and its ancestors change.
        scanner.invalidate(paths: [branch], trees: [root + "-neighbor/Removed"],
                           fullRoots: [root + "-neighbor"])
        #expect(scanner.results[root] == nil)
        #expect(scanner.results[branch] == nil)
        #expect(scanner.results[leaf] == original[leaf])
        #expect(scanner.results[sibling] == original[sibling])
        #expect(scanner.startedJobCount == jobs)
        try await waitForScan(scanner)
        #expect(scanner.results == original)
        #expect(scanner.startedJobCount == jobs + 1)
    }

    @Test func subtreeAndFullRootInvalidationStillRemoveCachedDescendants() async throws {
        let tree = try makeTree()
        defer { try? FileManager.default.removeItem(at: tree.root) }
        let scanner = SourceMediaPresenceScanner()
        defer { scanner.stop() }
        scanner.setRoots([tree.root])
        try await waitForScan(scanner)
        let original = scanner.results
        let root = SourceTreeIdentity.folderID(for: tree.root)
        let branch = SourceTreeIdentity.folderID(for: tree.branch)
        let leaf = SourceTreeIdentity.folderID(for: tree.leaf)
        let sibling = SourceTreeIdentity.folderID(for: tree.sibling)

        scanner.invalidate(paths: [root], trees: [branch])
        #expect(scanner.results[root] == nil)
        #expect(scanner.results[branch] == nil)
        #expect(scanner.results[leaf] == nil)
        #expect(scanner.results[sibling] == original[sibling])
        #expect(original[branch] == true)
        try await waitForScan(scanner)
        #expect(scanner.results == original)

        scanner.invalidate(paths: [], fullRoots: [root])
        #expect(scanner.results.isEmpty)
        try await waitForScan(scanner)
        #expect(scanner.results == original)
    }

    @Test func emptyAndUnwatchedChangesKeepSettledScannerIdle() async throws {
        let tree = try makeTree()
        defer { try? FileManager.default.removeItem(at: tree.root) }
        let scanner = SourceMediaPresenceScanner()
        defer { scanner.stop() }
        scanner.setRoots([tree.root])
        try await waitForScan(scanner)
        let original = scanner.results
        let jobs = scanner.startedJobCount
        let root = SourceTreeIdentity.folderID(for: tree.root)

        scanner.invalidate(paths: [])
        scanner.invalidate(paths: [root + "-neighbor"], trees: [root + "-neighbor/Child"],
                           fullRoots: [root + "-neighbor"])
        #expect(scanner.results == original)
        #expect(!scanner.isScanning)
        #expect(scanner.startedJobCount == jobs)
        await Task.yield()
        #expect(scanner.results == original)
        #expect(!scanner.isScanning)
        #expect(scanner.startedJobCount == jobs)
    }

    private struct Tree {
        let root: URL
        let branch: URL
        let leaf: URL
        let sibling: URL
    }

    private func makeTree() throws -> Tree {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PresenceInvalidation-\(UUID().uuidString)", isDirectory: true)
        let branch = root.appendingPathComponent("Branch", isDirectory: true)
        let leaf = branch.appendingPathComponent("Leaf", isDirectory: true)
        let sibling = root.appendingPathComponent("Branch-neighbor", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: leaf, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
            try Data().write(to: leaf.appendingPathComponent("video.mp4"))
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
        return Tree(root: root, branch: branch, leaf: leaf, sibling: sibling)
    }

    private func waitForScan(_ scanner: SourceMediaPresenceScanner) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while scanner.isScanning && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(!scanner.isScanning)
    }
}
