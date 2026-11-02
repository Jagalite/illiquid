import Foundation
import Observation

/// The sidebar's directory cache and load lifecycle, independent of SwiftUI.
@MainActor
@Observable
final class SourceTreeDirectoryState {
    private(set) var directoryContents: [String: [SourceTreeEntry]] = [:]
    private(set) var directoryErrors: [String: String] = [:]
    private(set) var loadingFolderIDs: Set<String> = []
    private(set) var directoryLoadTasks: [String: Task<Void, Never>] = [:]

    private let load: @Sendable (URL) async -> SourceDirectoryListing

    init(load: @escaping @Sendable (URL) async -> SourceDirectoryListing) {
        self.load = load
    }

    func loadFolderIfNeeded(
        _ folderURL: URL,
        expandedFolderIDs: @escaping @MainActor () -> Set<String>,
        didLoad: @escaping @MainActor (SourceDirectoryListing) -> Void,
        didChange: @escaping @MainActor () -> Void
    ) {
        let folderID = SourceTreeIdentity.folderID(for: folderURL)
        guard directoryContents[folderID] == nil,
              directoryErrors[folderID] == nil,
              directoryLoadTasks[folderID] == nil
        else {
            loadExpandedChildren(of: folderID, expandedFolderIDs: expandedFolderIDs,
                didLoad: didLoad, didChange: didChange)
            return
        }

        loadingFolderIDs.insert(folderID)
        directoryLoadTasks[folderID] = Task { @MainActor in
            let listing = await load(folderURL)
            guard !Task.isCancelled else { return }

            loadingFolderIDs.remove(folderID)
            directoryLoadTasks[folderID] = nil
            directoryContents[folderID] = listing.entries
            directoryErrors[folderID] = listing.errorMessage
            didLoad(listing)
            loadExpandedChildren(of: folderID, expandedFolderIDs: expandedFolderIDs,
                didLoad: didLoad, didChange: didChange)
            didChange()
        }
    }

    private func loadExpandedChildren(
        of folderID: String,
        expandedFolderIDs: @escaping @MainActor () -> Set<String>,
        didLoad: @escaping @MainActor (SourceDirectoryListing) -> Void,
        didChange: @escaping @MainActor () -> Void
    ) {
        guard let entries = directoryContents[folderID] else { return }
        for entry in entries where entry.kind == .folder {
            let childID = SourceTreeIdentity.folderID(for: entry.url)
            if expandedFolderIDs().contains(childID) {
                loadFolderIfNeeded(entry.url, expandedFolderIDs: expandedFolderIDs,
                    didLoad: didLoad, didChange: didChange)
            }
        }
    }

    func cancelAllLoads() {
        directoryLoadTasks.values.forEach { $0.cancel() }
        directoryLoadTasks.removeAll()
        loadingFolderIDs.removeAll()
    }

    func cancelLoads(beneath folderURL: URL) {
        let folderPath = SourceTreeIdentity.folderID(for: folderURL)
        let descendantIDs = directoryLoadTasks.keys.filter {
            SourceTreeIdentity.contains($0, within: folderPath)
        }
        for id in descendantIDs {
            directoryLoadTasks[id]?.cancel()
            directoryLoadTasks[id] = nil
            loadingFolderIDs.remove(id)
        }
    }

    func invalidateCachedDirectory(_ folderURL: URL) {
        let folderID = SourceTreeIdentity.folderID(for: folderURL)
        directoryLoadTasks[folderID]?.cancel()
        directoryLoadTasks[folderID] = nil
        loadingFolderIDs.remove(folderID)
        directoryContents[folderID] = nil
        directoryErrors[folderID] = nil
    }

    func invalidateCachedTree(
        beneath folderURL: URL,
        preserveExpansion: Bool,
        expandedFolderIDs: inout Set<String>
    ) {
        cancelLoads(beneath: folderURL)
        let folderPath = SourceTreeIdentity.folderID(for: folderURL)
        // Collect matching keys separately instead of building a union of all
        // cached paths. Arrays do not retain dictionary storage during removal.
        let contentIDs = directoryContents.keys.filter {
            SourceTreeIdentity.contains($0, within: folderPath)
        }
        let errorIDs = directoryErrors.keys.filter {
            SourceTreeIdentity.contains($0, within: folderPath)
        }
        if !preserveExpansion {
            expandedFolderIDs = Set(expandedFolderIDs.filter {
                !SourceTreeIdentity.contains($0, within: folderPath)
            })
        }
        for id in contentIDs {
            directoryContents[id] = nil
        }
        for id in errorIDs {
            directoryErrors[id] = nil
        }
    }

    func invalidate(
        _ plan: SourceFilesystemInvalidationPlan,
        expandedFolderIDs: inout Set<String>
    ) {
        for path in plan.rootsToRescan {
            invalidateCachedTree(beneath: URL(fileURLWithPath: path, isDirectory: true),
                preserveExpansion: true, expandedFolderIDs: &expandedFolderIDs)
        }
        for path in plan.treesToInvalidate {
            invalidateCachedTree(beneath: URL(fileURLWithPath: path, isDirectory: true),
                preserveExpansion: false, expandedFolderIDs: &expandedFolderIDs)
        }
        for path in plan.directoriesToReload {
            invalidateCachedDirectory(URL(fileURLWithPath: path, isDirectory: true))
        }
    }

    static func reloadPaths(
        for plan: SourceFilesystemInvalidationPlan,
        activeRoots: [URL],
        expandedFolderIDs: Set<String>
    ) -> Set<String> {
        guard !activeRoots.isEmpty,
              !plan.directoriesToReload.isEmpty || !plan.rootsToRescan.isEmpty
        else { return [] }
        let activeRootPaths = Set(activeRoots.map(SourceTreeIdentity.folderID))
        return Set(plan.directoriesToReload.union(plan.rootsToRescan).filter { path in
            // Reuse the normalized roots for the whole event batch. Collapsed
            // directories need no containment check, and roots contain themselves.
            activeRootPaths.contains(path)
                || (expandedFolderIDs.contains(path)
                    && activeRootPaths.contains { SourceTreeIdentity.contains(path, within: $0) })
        })
    }
}
