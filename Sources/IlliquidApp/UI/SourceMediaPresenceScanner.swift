import Foundation
import Observation
import IlliquidCore

/// One resumable scan job at a time. Events queue repairs without interrupting
/// current traversal; completed sibling subtrees are reused by repair jobs.
@MainActor @Observable
final class SourceMediaPresenceScanner {
    private(set) var results: [String: Bool] = [:]
    private(set) var isScanning = false
    @ObservationIgnored private var roots: [String] = []
    @ObservationIgnored private var completed: Set<String> = []
    @ObservationIgnored private var summaries: [String: SourceMediaPresenceCursor.Summary] = [:]
    @ObservationIgnored private var pending: [String] = []
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private(set) var startedJobCount = 0
    @ObservationIgnored private var directoryRevisions: [String: Int] = [:]
    @ObservationIgnored private var treeRevisions: [String: Int] = [:]

    func setRoots(_ folders: [URL]) {
        let next = SourceRootPruning.minimal(folders.map(SourceTreeIdentity.folderID))
        guard next != roots else {
            if task == nil {
                pending = roots.filter { !completed.contains($0) }
            }
            start()
            return
        }
        stop()
        roots = next
        results = results.filter { isWatched($0.key) }
        summaries = summaries.filter { isWatched($0.key) }
        completed.formIntersection(next)
        // The roots are already disjoint and stop() emptied the queue. Repeating
        // enqueue's overlap search would reintroduce quadratic startup work.
        pending = next.filter { !completed.contains($0) }
        start()
    }

    /// Listing changes only invalidate that directory's summary. Removed/renamed
    /// trees and dropped events explicitly invalidate descendants as well.
    func invalidate(paths: Set<String>, trees: Set<String> = [], fullRoots: Set<String> = []) {
        let directories = paths.filter(isWatched)
        let subtrees = trees.union(fullRoots).filter(isWatched)
        guard !directories.isEmpty || !subtrees.isEmpty else { return }
        revision += 1
        for path in directories { directoryRevisions[path] = revision; summaries[path] = nil }
        for path in subtrees { treeRevisions[path] = revision }
        summaries = summaries.filter { entry in !subtrees.contains { Self.contains(entry.key, in: $0) } }
        results = results.filter { entry in
            !directories.contains { Self.contains($0, in: entry.key) }
                && !subtrees.contains { Self.contains(entry.key, in: $0) || Self.contains($0, in: entry.key) }
        }
        for path in directories { enqueue(path) }
        // Removed directories need a parent listing, not a scan of a vanished path.
        for path in trees where isWatched(path) {
            let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
            enqueue(isWatched(parent) ? parent : path)
        }
        for path in fullRoots where isWatched(path) { enqueue(path) }
        start()
    }

    func rescan() {
        stop()
        results.removeAll()
        summaries.removeAll()
        completed.removeAll()
        pending = roots
        start()
    }

    func stop() {
        generation += 1
        task?.cancel()
        task = nil
        pending.removeAll()
        directoryRevisions.removeAll()
        treeRevisions.removeAll()
        isScanning = false
    }

    private func enqueue(_ path: String) {
        guard !pending.contains(where: { Self.contains(path, in: $0) }) else { return }
        pending.removeAll { Self.contains($0, in: path) }
        pending.append(path)
        if pending.count > 64 {
            // Bound waiting jobs. Root repairs still skip cached sibling subtrees.
            pending = roots
        }
    }

    private func start() {
        guard task == nil, !pending.isEmpty else { return }
        let epoch = generation
        isScanning = true
        task = Task { [weak self] in
            while let self, self.generation == epoch, !Task.isCancelled, !self.pending.isEmpty {
                let path = self.pending.removeFirst()
                self.startedJobCount += 1
                let jobRevision = self.revision
                let reusableResults = self.results.filter { entry in
                    self.summaries[entry.key]?.isComplete == true
                        && self.summaries[entry.key]?.isReadable == true
                }
                let cursor = SourceMediaPresenceCursor(
                    root: URL(fileURLWithPath: path, isDirectory: true), cachedResults: reusableResults)
                do {
                    var bufferedSummaries: [String: SourceMediaPresenceCursor.Summary] = [:]
                    var lastPublication = ProcessInfo.processInfo.systemUptime
                    while true {
                        let batch = try await SourcePreparationExecutor.shared.performWhenAvailable { check in
                            try cursor.nextBatch(checkCancellation: check)
                        }
                        guard !Task.isCancelled, self.generation == epoch else { return }
                        bufferedSummaries.merge(batch.summaries) { _, new in new }
                        let now = ProcessInfo.processInfo.systemUptime
                        if batch.isComplete || now - lastPublication >= 0.1 {
                            for (folder, summary) in bufferedSummaries {
                                guard self.accepts(folder, from: jobRevision) else { continue }
                                self.summaries[folder] = summary
                            }
                            // Children settle before ancestors. Unknown descendants
                            // cannot produce a negative result for their parents.
                            for folder in bufferedSummaries.keys.sorted(by: { $0.count > $1.count }) {
                                self.recompute(folder)
                            }
                            bufferedSummaries.removeAll(keepingCapacity: true)
                            lastPublication = now
                        }
                        if batch.isComplete {
                            if self.roots.contains(path) { self.completed.insert(path) }
                            break
                        }
                        try await Task.sleep(for: .milliseconds(10))
                    }
                } catch {
                    guard !Task.isCancelled, self.generation == epoch else { return }
                    // Failed folders remain unknown. Explicit Rescan or a new event retries them.
                }
            }
            guard let self, self.generation == epoch else { return }
            self.isScanning = false
            self.task = nil
            self.directoryRevisions.removeAll()
            self.treeRevisions.removeAll()
        }
    }

    private func accepts(_ path: String, from version: Int) -> Bool {
        (directoryRevisions[path] ?? 0) <= version
            && !treeRevisions.contains { $0.value > version && Self.contains(path, in: $0.key) }
    }

    private func recompute(_ folder: String) {
        var path = folder
        while isWatched(path) {
            if let summary = summaries[path] {
                if summary.hasDirectMedia || summary.children.contains(where: { results[$0] == true }) {
                    results[path] = true
                } else if summary.isComplete && summary.isReadable
                            && summary.children.allSatisfy({ results[$0] == false }) {
                    results[path] = false
                } else {
                    results[path] = nil
                }
            } else {
                results[path] = nil
            }
            let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
            guard parent != path else { break }
            path = parent
        }
    }

    private func isWatched(_ path: String) -> Bool { roots.contains { Self.contains(path, in: $0) } }
    private static func contains(_ path: String, in root: String) -> Bool {
        path == root || path.hasPrefix(root == "/" ? root : root + "/")
    }
}

/// Exclusively accessed by sequential executor slices. No recursive Swift calls,
/// file contents, codec probes, or complete file inventory are needed.
final class SourceMediaPresenceCursor: @unchecked Sendable {
    struct Summary: Sendable {
        let hasDirectMedia: Bool
        let children: Set<String>
        let isComplete: Bool
        let isReadable: Bool
    }
    struct Batch: Sendable {
        let results: [String: Bool]
        let summaries: [String: Summary]
        let isComplete: Bool
        let visitedEntries: Int
    }
    private struct Folder {
        let path: String
        var hasMedia = false
        var hasDirectMedia = false
        var children: Set<String> = []
        var unknown = false
    }
    private let root: URL
    private let cachedResults: [String: Bool]
    private var summaryUpdates: [String: Summary] = [:]
    private var enumerator: FileManager.DirectoryEnumerator?
    private var initialized = false
    private var complete = false
    private var folders: [Folder] = []
    private static let keys: Set<URLResourceKey> = [
        .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isPackageKey,
    ]

    init(root: URL, cachedResults: [String: Bool] = [:]) {
        self.root = root
        self.cachedResults = cachedResults
    }

    func nextBatch(maximumEntries: Int = 256, timeBudget: TimeInterval = 0.02,
                   checkCancellation: @Sendable () throws -> Void = { try Task.checkCancellation() }) throws -> Batch {
        try checkCancellation()
        var updates: [String: Bool] = [:]
        summaryUpdates.removeAll(keepingCapacity: true)
        var visited = 0
        if !initialized {
            initialized = true
            folders = [Folder(path: SourceTreeIdentity.folderID(for: root))]
            enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: Array(Self.keys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { [weak self] _, _ in
                    self?.markUnknown()
                    return true
                })
            if enumerator == nil { markUnknown(); complete = true }
        }
        let deadline = ProcessInfo.processInfo.systemUptime + timeBudget
        while !complete && visited < max(1, maximumEntries) {
            try checkCancellation()
            guard let url = enumerator?.nextObject() as? URL else {
                complete = true
                break
            }
            visited += 1
            // Enumerator URLs may spell macOS aliases differently (/var versus
            // /private/var). Keep cache keys in the prepared source's namespace.
            let level = enumerator?.level ?? 1
            while folders.count > level { finishFolder(updates: &updates) }
            guard let parent = folders.last else { markUnknown(); continue }
            let path = URL(fileURLWithPath: parent.path, isDirectory: true)
                .appendingPathComponent(url.lastPathComponent).path
            guard let values = try? url.resourceValues(forKeys: Self.keys) else {
                markUnknown()
                continue
            }
            if values.isDirectory == true {
                if values.isSymbolicLink == true || values.isPackage == true {
                    enumerator?.skipDescendants()
                } else {
                    folders[folders.count - 1].children.insert(path)
                    if let cached = cachedResults[path] {
                        enumerator?.skipDescendants()
                        if cached {
                            for index in folders.indices { folders[index].hasMedia = true }
                        }
                    } else {
                        folders.append(Folder(path: path))
                    }
                }
            } else if values.isRegularFile == true, MediaFileSupport.isSupportedMediaFile(url) {
                folders[folders.count - 1].hasDirectMedia = true
                for index in folders.indices where !folders[index].hasMedia {
                    folders[index].hasMedia = true
                    updates[folders[index].path] = true
                }
            }
            if ProcessInfo.processInfo.systemUptime >= deadline { break }
        }
        if complete {
            while !folders.isEmpty { finishFolder(updates: &updates) }
            enumerator = nil
        }
        for folder in folders { summaryUpdates[folder.path] = summary(folder, complete: false) }
        try checkCancellation()
        return Batch(results: updates, summaries: summaryUpdates, isComplete: complete, visitedEntries: visited)
    }

    private func markUnknown() {
        for index in folders.indices { folders[index].unknown = true }
    }

    private func summary(_ folder: Folder, complete: Bool) -> Summary {
        Summary(hasDirectMedia: folder.hasDirectMedia, children: folder.children,
                isComplete: complete, isReadable: !folder.unknown)
    }

    private func finishFolder(updates: inout [String: Bool]) {
        guard let folder = folders.popLast() else { return }
        summaryUpdates[folder.path] = summary(folder, complete: true)
        if folder.hasMedia || !folder.unknown { updates[folder.path] = folder.hasMedia }
        if !folders.isEmpty {
            let parent = folders.count - 1
            folders[parent].hasMedia = folders[parent].hasMedia || folder.hasMedia
            folders[parent].unknown = folders[parent].unknown || folder.unknown
        }
    }
}
