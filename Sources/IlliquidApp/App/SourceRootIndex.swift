import Foundation
import Observation
import IlliquidCore

/// Derived, lexical-only roots. AppModel invalidates this snapshot whenever its
/// tabs change; UI redraws and search edits reuse the prepared arrays.
struct SourceRootIndex: Sendable {
    struct Roots: Sendable {
        let folders: [URL]
        let watchRoots: [URL]
        let filesByPath: [String: SourceTabItem]
    }
    let byTab: [String: Roots]
    let folders: [URL]
    let watchRoots: [URL]

    init(tabs: [SourceTab]) {
        var byTab: [String: Roots] = [:]
        var folders: [URL] = [], watchRoots: [URL] = []
        for tab in tabs {
            if Task.isCancelled { break }
            var files: [String: SourceTabItem] = [:]
            for item in tab.items where item.kind == .file {
                if Task.isCancelled { break }
                if let path = NormalizedFileURL.persistenceKey(for: item.url), files[path] == nil {
                    files[path] = item
                }
            }
            if Task.isCancelled { break }
            let roots = Roots(folders: tab.items.compactMap { $0.kind == .folder ? $0.url : nil },
                              watchRoots: SourceTabItems.watchRoots(for: tab.items), filesByPath: files)
            byTab[tab.id] = roots
            folders += roots.folders
            watchRoots += roots.watchRoots
        }
        self.byTab = byTab
        self.folders = SourceFolderLibrary.merging([], with: folders)
        self.watchRoots = SourceFolderLibrary.merging([], with: watchRoots)
    }
}

/// Publishes only complete snapshots. Superseded builds never make stale menu
/// actions or filesystem watches visible, and indexing cannot block MainActor.
@Observable @MainActor
final class SourceRootIndexStore {
    private(set) var snapshot = SourceRootIndex(tabs: [])
    private(set) var isReady = false
    @ObservationIgnored private var revision: UInt64 = 0
    @ObservationIgnored private var task: Task<Void, Never>?

    func replace(tabs: [SourceTab]) {
        revision &+= 1
        let revision = revision
        task?.cancel()
        isReady = false
        task = Task { [weak self] in
            let worker = Task.detached(priority: .userInitiated) {
                let started = LifecyclePerformance.begin("source-root-index")
                defer { LifecyclePerformance.end("source-root-index", since: started) }
                return SourceRootIndex(tabs: tabs)
            }
            let result = await withTaskCancellationHandler {
                await worker.value
            } onCancel: { worker.cancel() }
            guard !Task.isCancelled, let self, self.revision == revision else { return }
            self.snapshot = result
            self.isReady = true
            self.task = nil
        }
    }

    func waitUntilReady() async { await task?.value }
    deinit { task?.cancel() }
}
