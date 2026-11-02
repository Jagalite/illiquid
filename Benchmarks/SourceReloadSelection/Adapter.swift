import Foundation

/// A separate module boundary keeps repeated calls observable to the harness.
/// The selector and its identity/plan helpers are verbatim production slices.
public enum ReloadSelectionAPI {
    @MainActor
    @inline(never)
    public static func select(
        directoriesToReload: Set<String>,
        rootsToRescan: Set<String>,
        activeRoots: [URL],
        expandedFolderIDs: Set<String>,
        treesToInvalidate: Set<String> = []
    ) -> Set<String> {
        SourceTreeDirectoryState.reloadPaths(
            for: SourceFilesystemInvalidationPlan(
                directoriesToReload: directoriesToReload,
                treesToInvalidate: treesToInvalidate,
                rootsToRescan: rootsToRescan
            ),
            activeRoots: activeRoots,
            expandedFolderIDs: expandedFolderIDs
        )
    }

    #if DIFFERENTIAL_VERIFY
    @MainActor
    public static func baselineSelect(
        directoriesToReload: Set<String>,
        rootsToRescan: Set<String>,
        activeRoots: [URL],
        expandedFolderIDs: Set<String>,
        treesToInvalidate: Set<String> = []
    ) -> Set<String> {
        BaselineSourceTreeDirectoryState.reloadPaths(
            for: SourceFilesystemInvalidationPlan(
                directoriesToReload: directoriesToReload,
                treesToInvalidate: treesToInvalidate,
                rootsToRescan: rootsToRescan
            ),
            activeRoots: activeRoots,
            expandedFolderIDs: expandedFolderIDs
        )
    }
    #endif
}
