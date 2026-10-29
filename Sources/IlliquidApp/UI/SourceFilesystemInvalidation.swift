import Foundation

struct SourceFilesystemEvent: Equatable, Sendable {
    struct Flags: OptionSet, Equatable, Sendable {
        let rawValue: UInt16

        static let directory = Self(rawValue: 1 << 0)
        static let created = Self(rawValue: 1 << 1)
        static let removed = Self(rawValue: 1 << 2)
        static let renamed = Self(rawValue: 1 << 3)
        static let mustScanSubdirectories = Self(rawValue: 1 << 4)
        static let eventsDropped = Self(rawValue: 1 << 5)
        static let eventIDsWrapped = Self(rawValue: 1 << 6)
        static let rootChanged = Self(rawValue: 1 << 7)

        var requiresFullRescan: Bool {
            !intersection([
                .mustScanSubdirectories,
                .eventsDropped,
                .eventIDsWrapped,
                .rootChanged,
            ]).isEmpty
        }

        var changesDirectoryListing: Bool {
            !intersection([.directory, .created, .removed, .renamed]).isEmpty
        }
    }

    let path: String
    let flags: Flags
}

/// Bounds event retention while the sidebar waits for its debounce deadline.
/// A sustained stream can keep postponing that deadline. Once detail exceeds
/// the budget, use the planner's existing event-loss recovery for every root.
/// Native callbacks apply the same per-batch bound before decoding paths;
/// tasks awaiting main-actor delivery remain a separate retention boundary.
struct SourceFilesystemEventBuffer {
    static let defaultMaximumCount = 4096

    private let maximumCount: Int
    private var events: [SourceFilesystemEvent] = []
    private var requiresFullRescan = false

    init(maximumCount: Int = SourceFilesystemEventBuffer.defaultMaximumCount) {
        self.maximumCount = max(1, maximumCount)
    }

    var count: Int { events.count }

    mutating func append(contentsOf incoming: [SourceFilesystemEvent]) {
        guard !requiresFullRescan else { return }
        if incoming.count > maximumCount - events.count
            || incoming.contains(where: { $0.flags.contains(.eventsDropped) })
        {
            // Drop this buffer's references to accumulated paths and storage.
            // The marker path is ignored by event-loss recovery.
            events = [.init(path: "/", flags: [.eventsDropped])]
            requiresFullRescan = true
        } else {
            events.append(contentsOf: incoming)
        }
    }

    mutating func take() -> [SourceFilesystemEvent] {
        let result = events
        removeAll()
        return result
    }

    mutating func removeAll() {
        events = []
        requiresFullRescan = false
    }
}

struct SourceFilesystemInvalidationPlan: Equatable, Sendable {
    var directoriesToReload: Set<String> = []
    var treesToInvalidate: Set<String> = []
    var rootsToRescan: Set<String> = []

    var isEmpty: Bool {
        directoriesToReload.isEmpty
            && treesToInvalidate.isEmpty
            && rootsToRescan.isEmpty
    }

    func affectsAny(_ roots: [URL]) -> Bool {
        let rootPaths = roots.map(Self.normalizedPath)
        return allAffectedPaths.contains { path in
            rootPaths.contains { rootPath in
                Self.contains(path, within: rootPath)
                    || Self.contains(rootPath, within: path)
            }
        }
    }

    private var allAffectedPaths: Set<String> {
        directoriesToReload.union(treesToInvalidate).union(rootsToRescan)
    }

    private static func normalizedPath(_ url: URL) -> String {
        url.absoluteURL.standardized.path
    }

    private static func contains(_ path: String, within rootPath: String) -> Bool {
        path == rootPath || path.hasPrefix(rootPath == "/" ? rootPath : rootPath + "/")
    }
}

enum SourceFilesystemInvalidationPlanner {
    static func plan(
        events: [SourceFilesystemEvent],
        roots: [URL]
    ) -> SourceFilesystemInvalidationPlan {
        let rootPaths = Set(roots.map(normalizedPath))
        guard !rootPaths.isEmpty else { return SourceFilesystemInvalidationPlan() }

        // Event loss invalidates the whole stream, including roots unrelated to
        // the marker path. Full rescans supersede all targeted work.
        if events.contains(where: { $0.flags.contains(.eventsDropped) }) {
            return SourceFilesystemInvalidationPlan(rootsToRescan: rootPaths)
        }

        var plan = SourceFilesystemInvalidationPlan()
        for event in events {
            let eventURL = URL(fileURLWithPath: event.path, isDirectory: false)
                .absoluteURL.standardized
            let eventPath = eventURL.path
            let requiresFullRescan = event.flags.requiresFullRescan
            let matchingRoots = rootPaths.filter {
                contains(eventPath, within: $0)
                    || (requiresFullRescan && contains($0, within: eventPath))
            }
            guard !matchingRoots.isEmpty else { continue }

            if requiresFullRescan {
                plan.rootsToRescan.formUnion(matchingRoots)
                continue
            }
            // Structural changes already require a reload. Only content-only
            // events need metadata classification, using the normalized URL.
            guard event.flags.changesDirectoryListing
                || eventURL.lastPathComponent == ".plexmatch"
                || eventURL.pathExtension.lowercased() == "nfo"
            else { continue }

            let parentPath = URL(fileURLWithPath: eventPath, isDirectory: false)
                .deletingLastPathComponent()
                .absoluteURL.standardized.path
            let parentIsWatched = matchingRoots.contains {
                contains(parentPath, within: $0)
            }

            if event.flags.contains(.directory) {
                if event.flags.contains(.removed) || event.flags.contains(.renamed) {
                    plan.treesToInvalidate.insert(eventPath)
                    if parentIsWatched {
                        plan.directoriesToReload.insert(parentPath)
                    } else {
                        plan.directoriesToReload.formUnion(matchingRoots)
                    }
                } else if event.flags.contains(.created) {
                    if parentIsWatched {
                        plan.directoriesToReload.insert(parentPath)
                    } else {
                        plan.directoriesToReload.formUnion(matchingRoots)
                    }
                } else {
                    plan.directoriesToReload.insert(eventPath)
                }
            } else if parentIsWatched {
                plan.directoriesToReload.insert(parentPath)
            } else {
                plan.directoriesToReload.formUnion(matchingRoots)
            }
        }

        for rootPath in plan.rootsToRescan {
            plan.directoriesToReload = Set(
                plan.directoriesToReload.filter {
                    !contains($0, within: rootPath)
                })
            plan.treesToInvalidate = Set(
                plan.treesToInvalidate.filter {
                    !contains($0, within: rootPath)
                })
        }
        return plan
    }

    private static func normalizedPath(_ url: URL) -> String {
        url.absoluteURL.standardized.path
    }

    private static func contains(_ path: String, within rootPath: String) -> Bool {
        path == rootPath || path.hasPrefix(rootPath == "/" ? rootPath : rootPath + "/")
    }
}
