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
            let eventPath = normalizedPath(event.path)
            let matchingRoots = rootPaths.filter {
                contains(eventPath, within: $0)
                    || (event.flags.requiresFullRescan && contains($0, within: eventPath))
            }
            guard !matchingRoots.isEmpty else { continue }

            if event.flags.requiresFullRescan {
                plan.rootsToRescan.formUnion(matchingRoots)
                continue
            }
            let eventURL = URL(fileURLWithPath: eventPath)
            let isMetadata = eventURL.lastPathComponent == ".plexmatch" || eventURL.pathExtension.lowercased() == "nfo"
            guard event.flags.changesDirectoryListing || isMetadata else { continue }

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

    private static func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: false).absoluteURL.standardized.path
    }

    private static func normalizedPath(_ url: URL) -> String {
        url.absoluteURL.standardized.path
    }

    private static func contains(_ path: String, within rootPath: String) -> Bool {
        path == rootPath || path.hasPrefix(rootPath == "/" ? rootPath : rootPath + "/")
    }
}
