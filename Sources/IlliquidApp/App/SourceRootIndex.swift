import Foundation
import Observation
import IlliquidCore

/// Derived, lexical-only roots. AppModel invalidates this snapshot whenever its
/// indexing inputs change; visibility, UI redraws, and search reuse the arrays.
struct SourceRootIndex: Sendable {
    struct Roots: Sendable {
        let folders: [URL]
        let watchRoots: [URL]
        let filesByPath: [String: SourceTabItem]
    }
    let byTab: [String: Roots]
    let folders: [URL]
    let watchRoots: [URL]

    /// A sufficient reuse check for visibility-only edits, without scanning file
    /// paths on MainActor or retaining another long-lived tab snapshot. Keep this
    /// in sync with every input read by init(tabs:): tab IDs, order, and items.
    /// Different item storage conservatively rebuilds, even for equal values.
    static func canReuseSnapshot(from oldTabs: [SourceTab], for newTabs: [SourceTab]) -> Bool {
        guard oldTabs.count == newTabs.count else { return false }
        for (old, new) in zip(oldTabs, newTabs) {
            guard old.id.utf8.elementsEqual(new.id.utf8),
                  old.items.count == new.items.count else { return false }
            if old.items.isEmpty { continue }
            // Both immutable borrows are live together; equal addresses and
            // counts prove identical value storage. Neither pointer escapes.
            let sharesItems = old.items.withUnsafeBufferPointer { oldItems in
                new.items.withUnsafeBufferPointer { newItems in
                    oldItems.baseAddress == newItems.baseAddress
                }
            }
            guard sharesItems else { return false }
        }
        return true
    }

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
