import Foundation
import Testing

@testable import IlliquidApp

@Suite("Sidebar directory consumer state")
@MainActor
struct SourceTreeDirectoryStateTests {
    @Test(arguments: [
        SourceFilesystemEvent.Flags.mustScanSubdirectories,
        .eventsDropped, .eventIDsWrapped, .rootChanged,
    ])
    func filesystemRootRescanReloadsExpandedCachesErrorsAndRunningLoads(
        _ flag: SourceFilesystemEvent.Flags
    ) async throws {
        let consumer = DirectoryConsumerFixture()
        defer { consumer.stop() }
        let rootEntries = [folder("/Movies"), folder("/Running"), folder("/Unavailable"), folder("/Collapsed")]
        try await consumer.loadAndFinish("/", entries: rootEntries)
        try await consumer.loadAndFinish("/Movies", entries: [folder("/Movies/Season"), media("/Movies/old.mkv")])
        try await consumer.loadAndFinish("/Movies/Season", entries: [media("/Movies/Season/old.mkv")])
        try await consumer.loadAndFinish("/Unavailable", entries: [], error: "offline")
        consumer.load("/Running")
        let oldLoad = try await consumer.takeLoad("/Running")
        consumer.expanded = ["/", "/Movies", "/Movies/Season", "/Running", "/Unavailable"]
        let expansion = consumer.expanded

        let plan = SourceFilesystemInvalidationPlanner.plan(
            events: [.init(path: "/", flags: flag)], roots: [url("/")])
        consumer.state.invalidate(plan, expandedFolderIDs: &consumer.expanded)

        #expect(oldLoad.task.isCancelled)
        #expect(consumer.state.directoryLoadTasks.isEmpty)
        #expect(consumer.state.loadingFolderIDs.isEmpty)
        #expect(consumer.state.directoryContents.isEmpty)
        #expect(consumer.state.directoryErrors.isEmpty)
        #expect(consumer.expanded == expansion)

        let reloads = consumer.reload(plan, roots: [url("/")])
        #expect(reloads == ["/"])
        let rootLoad = try await consumer.takeLoad("/")
        await consumer.finish(rootLoad, entries: rootEntries)
        let moviesLoad = try await consumer.takeLoad("/Movies")
        let runningLoad = try await consumer.takeLoad("/Running")
        let unavailableLoad = try await consumer.takeLoad("/Unavailable")
        #expect(consumer.state.directoryLoadTasks["/Collapsed"] == nil)

        // A cancelled OS read may finish after its replacement starts. It must
        // neither publish stale rows nor clear the replacement's loading state.
        let notifications = consumer.completedLoads
        await consumer.finish(oldLoad, entries: [media("/Running/stale.mkv")])
        #expect(consumer.completedLoads == notifications)
        #expect(consumer.state.directoryContents["/Running"] == nil)
        #expect(consumer.state.directoryLoadTasks["/Running"] == runningLoad.task)
        #expect(consumer.state.loadingFolderIDs.contains("/Running"))

        await consumer.finish(moviesLoad, entries: [folder("/Movies/Season"), media("/Movies/new.mkv")])
        let seasonLoad = try await consumer.takeLoad("/Movies/Season")
        await consumer.finish(seasonLoad, entries: [media("/Movies/Season/new.mkv")])
        await consumer.finish(runningLoad, entries: [media("/Running/new.mkv")])
        await consumer.finish(unavailableLoad, entries: [media("/Unavailable/back.mkv")])

        #expect(consumer.state.directoryContents["/Movies"]?.map(\.url.path) == ["/Movies/Season", "/Movies/new.mkv"])
        #expect(consumer.state.directoryContents["/Movies/Season"] == [media("/Movies/Season/new.mkv")])
        #expect(consumer.state.directoryContents["/Running"] == [media("/Running/new.mkv")])
        #expect(consumer.state.directoryErrors.isEmpty)
        #expect(consumer.state.directoryLoadTasks.isEmpty)
        #expect(consumer.state.loadingFolderIDs.isEmpty)
        #expect(consumer.expanded == expansion)
        #expect(await consumer.loader.requestCounts == ["/": 2, "/Movies": 2, "/Movies/Season": 2, "/Running": 2, "/Unavailable": 2])
    }

    @Test(arguments: [SourceFilesystemEvent.Flags.created, .removed, .renamed])
    func targetedChildChangeReloadsAnExpandedDirectoryUnderFilesystemRoot(
        _ flag: SourceFilesystemEvent.Flags
    ) async throws {
        let consumer = DirectoryConsumerFixture()
        defer { consumer.stop() }
        try await consumer.loadAndFinish("/", entries: [folder("/Movies"), folder("/Movies2")])
        try await consumer.loadAndFinish("/Movies", entries: [media("/Movies/old.mkv")])
        try await consumer.loadAndFinish("/Movies2", entries: [media("/Movies2/unchanged.mkv")])
        consumer.expanded = ["/", "/Movies", "/Movies2"]
        let plan = SourceFilesystemInvalidationPlanner.plan(
            events: [.init(path: "/Movies/changed.mkv", flags: flag)], roots: [url("/")])

        consumer.state.invalidate(plan, expandedFolderIDs: &consumer.expanded)
        #expect(consumer.state.directoryContents["/Movies"] == nil)
        #expect(consumer.reload(plan, roots: [url("/")]) == ["/Movies"])
        let replacement = try await consumer.takeLoad("/Movies")
        await consumer.finish(replacement, entries: [media("/Movies/new.mkv")])

        #expect(consumer.state.directoryContents["/Movies"] == [media("/Movies/new.mkv")])
        #expect(consumer.state.directoryContents["/Movies2"] == [media("/Movies2/unchanged.mkv")])
        #expect(await consumer.loader.requestCounts == ["/": 1, "/Movies": 2, "/Movies2": 1])
    }

    @Test func removedTreeClearsExpansionAndReloadsItsParentWithoutReloadingTheRemoval() async throws {
        let consumer = DirectoryConsumerFixture()
        defer { consumer.stop() }
        try await consumer.loadAndFinish("/Movies", entries: [folder("/Movies/Season"), folder("/Movies/Season2")])
        try await consumer.loadAndFinish("/Movies/Season", entries: [folder("/Movies/Season/Running")])
        try await consumer.loadAndFinish("/Movies/Season/Unavailable", entries: [], error: "offline")
        try await consumer.loadAndFinish("/Movies/Season2", entries: [media("/Movies/Season2/kept.mkv")])
        consumer.load("/Movies/Season/Running")
        let removedLoad = try await consumer.takeLoad("/Movies/Season/Running")
        consumer.expanded = ["/", "/Movies", "/Movies/Season", "/Movies/Season/Running", "/Movies/Season/Unavailable", "/Movies/Season2"]
        let plan = SourceFilesystemInvalidationPlanner.plan(
            events: [.init(path: "/Movies/Season", flags: [.directory, .removed])], roots: [url("/")])

        consumer.state.invalidate(plan, expandedFolderIDs: &consumer.expanded)
        #expect(removedLoad.task.isCancelled)
        #expect(consumer.expanded == ["/", "/Movies", "/Movies/Season2"])
        #expect(consumer.state.directoryContents["/Movies/Season"] == nil)
        #expect(consumer.state.directoryErrors.isEmpty)
        #expect(consumer.reload(plan, roots: [url("/")]) == ["/Movies"])
        let parentLoad = try await consumer.takeLoad("/Movies")
        await consumer.finish(parentLoad, entries: [folder("/Movies/Season2")])
        await consumer.finish(removedLoad, entries: [media("/Movies/Season/Running/stale.mkv")])

        #expect(consumer.state.directoryContents["/Movies/Season/Running"] == nil)
        #expect(consumer.state.directoryContents["/Movies/Season2"] == [media("/Movies/Season2/kept.mkv")])
        #expect(consumer.state.directoryLoadTasks.isEmpty)
        #expect(await consumer.loader.requestCounts["/Movies/Season2"] == 1)
    }

    @Test func removingFilesystemRootClearsAllDescendantExpansionAndState() async throws {
        let consumer = DirectoryConsumerFixture()
        defer { consumer.stop() }
        try await consumer.loadAndFinish("/Movies", entries: [media("/Movies/old.mkv")])
        try await consumer.loadAndFinish("/Unavailable", entries: [], error: "offline")
        consumer.load("/Running")
        let running = try await consumer.takeLoad("/Running")
        consumer.expanded = ["/", "/Movies", "/Unavailable", "/Running", "/Unloaded/Child"]

        consumer.state.invalidateCachedTree(beneath: url("/"), preserveExpansion: false,
            expandedFolderIDs: &consumer.expanded)

        #expect(running.task.isCancelled)
        #expect(consumer.expanded.isEmpty)
        #expect(consumer.state.directoryContents.isEmpty)
        #expect(consumer.state.directoryErrors.isEmpty)
        #expect(consumer.state.directoryLoadTasks.isEmpty)
        #expect(consumer.state.loadingFolderIDs.isEmpty)
        await consumer.finish(running, entries: [media("/Running/stale.mkv")])
        #expect(consumer.state.directoryContents.isEmpty)
    }

    @Test(arguments: [true, false])
    func ordinaryRootInvalidationPreservesSiblingPrefixes(_ preserveExpansion: Bool) async throws {
        let consumer = DirectoryConsumerFixture()
        defer { consumer.stop() }
        for path in ["/Movies", "/Movies/Cached", "/Movies2", "/Movies-old", "/Movie"] {
            try await consumer.loadAndFinish(path, entries: [media(path + "/kept.mkv")])
        }
        try await consumer.loadAndFinish("/Movies/Error", entries: [], error: "inside")
        try await consumer.loadAndFinish("/Movies2/Error", entries: [], error: "sibling")
        consumer.load("/Movies/Running")
        let inside = try await consumer.takeLoad("/Movies/Running")
        consumer.load("/Movies2/Running")
        let sibling = try await consumer.takeLoad("/Movies2/Running")
        consumer.expanded = ["/Movies", "/Movies/Cached", "/Movies/Unloaded", "/Movies2", "/Movies-old", "/Movie"]
        let originalExpansion = consumer.expanded

        consumer.state.invalidateCachedTree(beneath: url("/Movies"), preserveExpansion: preserveExpansion,
            expandedFolderIDs: &consumer.expanded)

        #expect(inside.task.isCancelled)
        #expect(!sibling.task.isCancelled)
        #expect(Set(consumer.state.directoryContents.keys) == ["/Movies2", "/Movies-old", "/Movie", "/Movies2/Error"])
        #expect(consumer.state.directoryErrors == ["/Movies2/Error": "sibling"])
        #expect(Set(consumer.state.directoryLoadTasks.keys) == ["/Movies2/Running"])
        #expect(consumer.state.loadingFolderIDs == ["/Movies2/Running"])
        #expect(consumer.expanded == (preserveExpansion ? originalExpansion : ["/Movies2", "/Movies-old", "/Movie"]))
        await consumer.finish(inside, entries: [])
        await consumer.finish(sibling, entries: [media("/Movies2/Running/new.mkv")])
        #expect(consumer.state.directoryContents["/Movies/Running"] == nil)
        #expect(consumer.state.directoryContents["/Movies2/Running"] == [media("/Movies2/Running/new.mkv")])
    }

    @Test func collapsingFilesystemRootCancelsLoadsButKeepsCachesErrorsAndExpansion() async throws {
        let consumer = DirectoryConsumerFixture()
        defer { consumer.stop() }
        try await consumer.loadAndFinish("/Movies", entries: [media("/Movies/kept.mkv")])
        try await consumer.loadAndFinish("/Unavailable", entries: [], error: "offline")
        consumer.expanded = ["/Movies", "/Running"]
        consumer.load("/Running")
        let running = try await consumer.takeLoad("/Running")

        consumer.state.cancelLoads(beneath: url("/"))

        #expect(running.task.isCancelled)
        #expect(consumer.state.directoryLoadTasks.isEmpty)
        #expect(consumer.state.loadingFolderIDs.isEmpty)
        #expect(consumer.state.directoryContents["/Movies"] == [media("/Movies/kept.mkv")])
        #expect(consumer.state.directoryErrors == ["/Unavailable": "offline"])
        #expect(consumer.expanded == ["/Movies", "/Running"])
        await consumer.finish(running, entries: [])
    }

    @Test func reloadSelectionKeepsActiveRootsAndExpandedDescendantsOnly() {
        let plan = SourceFilesystemInvalidationPlan(directoriesToReload: [
            "/Movies", "/Movies/Expanded", "/Movies/Collapsed", "/Movies2", "/Movies-old", "/Movie", "/Other/Expanded",
        ])
        #expect(SourceTreeDirectoryState.reloadPaths(for: plan, activeRoots: [url("/Movies")],
            expandedFolderIDs: ["/Movies/Expanded", "/Movies2", "/Movies-old", "/Movie", "/Other/Expanded"])
            == ["/Movies", "/Movies/Expanded"])
        #expect(SourceTreeDirectoryState.reloadPaths(for: plan, activeRoots: [],
            expandedFolderIDs: ["/Movies"]).isEmpty)
    }

    @Test func repeatedLoadsAndExpansionChangesRetainExistingLoadPolicy() async throws {
        let consumer = DirectoryConsumerFixture()
        defer { consumer.stop() }
        consumer.expanded = ["/Movies", "/Movies/Season"]
        consumer.load("/Movies")
        let movies = try await consumer.takeLoad("/Movies")
        consumer.load("/Movies")
        #expect(consumer.state.directoryLoadTasks["/Movies"] == movies.task)
        consumer.expanded.remove("/Movies/Season")
        await consumer.finish(movies, entries: [folder("/Movies/Season")])
        #expect(consumer.state.directoryLoadTasks.isEmpty)

        // A cached parent must still discover a newly expanded child.
        consumer.expanded.insert("/Movies/Season")
        consumer.load("/Movies")
        let season = try await consumer.takeLoad("/Movies/Season")
        await consumer.finish(season, entries: [], error: "offline")
        consumer.load("/Movies")
        #expect(consumer.state.directoryLoadTasks.isEmpty)
        #expect(await consumer.loader.requestCounts == ["/Movies": 1, "/Movies/Season": 1])
    }

    @Test func rootVisibilityIncludesAncestorsAndKeepsCompleteRelativePaths() {
        var configuration = SourceVisibilityConfiguration.default
        configuration.manuallyHiddenPaths = ["/Movies"]
        let matcher = SourceVisibilityMatcher(configuration: configuration, roots: [url("/")])
        #expect(matcher.evaluateIncludingAncestors(url("/Movies/Season/Episode.mkv")).hiddenMatches == [.manual])
        #expect(matcher.evaluateIncludingAncestors(url("/Movies2/Episode.mkv")).hiddenMatches.isEmpty)
        #expect(matcher.relativePath(for: url("/Movies/Season/Episode.mkv")) == "Movies/Season/Episode.mkv")
        #expect(matcher.relativePath(for: url("/Episode.mkv")) == "Episode.mkv")

        let ordinary = SourceVisibilityMatcher(configuration: configuration, roots: [url("/Movies")])
        #expect(ordinary.relativePath(for: url("/Movies/Season/Episode.mkv")) == "Season/Episode.mkv")
        #expect(ordinary.relativePath(for: url("/Movies2/Episode.mkv")) == "Episode.mkv")
        #expect(ordinary.evaluateIncludingAncestors(url("/Movies2/Episode.mkv")).hiddenMatches.isEmpty)
        let overlapping = SourceVisibilityMatcher(configuration: configuration, roots: [url("/"), url("/Movies")])
        #expect(overlapping.relativePath(for: url("/Movies/Season/Episode.mkv")) == "Season/Episode.mkv")
    }

    private func url(_ path: String) -> URL { URL(fileURLWithPath: path, isDirectory: true) }
    private func folder(_ path: String) -> SourceTreeEntry {
        .init(url: url(path), kind: .folder, dateAdded: nil, creationDate: nil)
    }
    private func media(_ path: String) -> SourceTreeEntry {
        .init(url: URL(fileURLWithPath: path), kind: .media, dateAdded: nil, creationDate: nil)
    }
}

/// Only the loader is controlled: cache mutation, cancellation, admission,
/// expanded-child traversal and reload selection all execute production code.
@MainActor
private final class DirectoryConsumerFixture {
    let loader = ControlledDirectoryLoader()
    let state: SourceTreeDirectoryState
    var expanded: Set<String> = []
    var completedLoads = 0

    init() {
        let loader = self.loader
        state = SourceTreeDirectoryState { await loader.load($0) }
    }

    func load(_ path: String) {
        state.loadFolderIfNeeded(URL(fileURLWithPath: path, isDirectory: true),
            expandedFolderIDs: { self.expanded },
            didLoad: { _ in self.completedLoads += 1 }, didChange: {})
    }

    func reload(_ plan: SourceFilesystemInvalidationPlan, roots: [URL]) -> Set<String> {
        let paths = SourceTreeDirectoryState.reloadPaths(for: plan, activeRoots: roots, expandedFolderIDs: expanded)
        for path in paths { load(path) }
        return paths
    }

    struct PendingLoad {
        let request: ControlledDirectoryLoader.Request
        let task: Task<Void, Never>
    }

    func takeLoad(_ path: String) async throws -> PendingLoad {
        let task = try #require(state.directoryLoadTasks[path])
        return PendingLoad(request: await loader.nextRequest(for: path), task: task)
    }

    func finish(_ pending: PendingLoad, entries: [SourceTreeEntry], error: String? = nil) async {
        await loader.finish(pending.request, listing: .init(entries: entries, errorMessage: error))
        await pending.task.value
    }

    func loadAndFinish(_ path: String, entries: [SourceTreeEntry], error: String? = nil) async throws {
        load(path)
        let pending = try await takeLoad(path)
        await finish(pending, entries: entries, error: error)
    }

    func stop() {
        state.cancelAllLoads()
        let loader = loader
        Task { await loader.finishAll() }
    }
}

private actor ControlledDirectoryLoader {
    struct Request: Sendable {
        let id: Int
        let path: String
    }

    private var nextID = 0
    private var pending: [Int: CheckedContinuation<SourceDirectoryListing, Never>] = [:]
    private var requests: [String: [Request]] = [:]
    private var waiting: [String: CheckedContinuation<Request, Never>] = [:]
    private var stopped = false
    private(set) var requestCounts: [String: Int] = [:]

    func load(_ url: URL) async -> SourceDirectoryListing {
        guard !stopped else { return .init(entries: [], errorMessage: nil) }
        let request = Request(id: nextID, path: url.path)
        nextID += 1
        requestCounts[url.path, default: 0] += 1
        return await withCheckedContinuation { continuation in
            pending[request.id] = continuation
            if let waiter = waiting.removeValue(forKey: url.path) {
                waiter.resume(returning: request)
            } else {
                requests[url.path, default: []].append(request)
            }
        }
    }

    func nextRequest(for path: String) async -> Request {
        if let first = requests[path]?.first {
            requests[path]?.removeFirst()
            return first
        }
        return await withCheckedContinuation { waiting[path] = $0 }
    }

    func finish(_ request: Request, listing: SourceDirectoryListing) {
        pending.removeValue(forKey: request.id)?.resume(returning: listing)
    }

    func finishAll() {
        stopped = true
        for continuation in pending.values {
            continuation.resume(returning: .init(entries: [], errorMessage: nil))
        }
        pending.removeAll()
    }
}
