import AppKit
import CoreServices
import Foundation
import SuperplayrCore

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
        path == rootPath || path.hasPrefix(rootPath + "/")
    }
}

enum SourceFilesystemInvalidationPlanner {
    static func plan(
        events: [SourceFilesystemEvent],
        roots: [URL]
    ) -> SourceFilesystemInvalidationPlan {
        let rootPaths = Set(roots.map(normalizedPath))
        guard !rootPaths.isEmpty else { return SourceFilesystemInvalidationPlan() }

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
        path == rootPath || path.hasPrefix(rootPath + "/")
    }
}

final class SourceFilesystemMonitor: @unchecked Sendable {
    typealias Handler = @MainActor @Sendable ([SourceFilesystemEvent]) -> Void

    private let handler: Handler
    private var stream: FSEventStreamRef?
    private var volumeObservers: [NSObjectProtocol] = []
    private var watchedRoots: [URL] = []

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    deinit {
        stop()
    }

    @discardableResult
    func start(watching roots: [URL], latency: TimeInterval = 0.15) -> Bool {
        stop()

        let paths = Array(Set(roots.map { $0.absoluteURL.standardized.path })).sorted()
        guard !paths.isEmpty else { return false }
        watchedRoots = roots
        // An FSEvents stream tied to the old device is not sufficient after a
        // drive reconnects. Reattach on volume changes and invalidate descendants.
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            volumeObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] notification in
                guard let volume = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
                let path = volume.standardizedFileURL.path
                MainActor.assumeIsolated { self?.volumeChanged(path: path) }
            })
        }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let createFlags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagWatchRoot
        )
        guard
            let stream = FSEventStreamCreate(
                kCFAllocatorDefault,
                sourceFilesystemEventCallback,
                &context,
                paths as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                latency,
                createFlags
            )
        else {
            return false
        }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
            return false
        }
        return true
    }

    @MainActor private func volumeChanged(path: String) {
        let affected = watchedRoots.filter {
            let root = $0.standardizedFileURL.path
            return root == path || root.hasPrefix(path + "/")
        }
        guard !affected.isEmpty else { return }
        LifecyclePerformance.mark("source-volume-change")
        let roots = watchedRoots
        _ = start(watching: roots)
        handler(affected.map { .init(path: $0.path, flags: [.rootChanged]) })
    }

    func stop() {
        for observer in volumeObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        volumeObservers.removeAll()
        watchedRoots.removeAll()
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    fileprivate func receive(
        paths: UnsafeMutableRawPointer,
        flags: UnsafePointer<FSEventStreamEventFlags>,
        count: Int
    ) {
        let pathPointers = paths.assumingMemoryBound(
            to: Optional<UnsafePointer<CChar>>.self
        )
        var events: [SourceFilesystemEvent] = []
        events.reserveCapacity(count)
        for index in 0..<count {
            guard let pathPointer = pathPointers[index] else { continue }
            events.append(
                SourceFilesystemEvent(
                    path: String(cString: pathPointer),
                    flags: Self.flags(from: flags[index])
                ))
        }
        guard !events.isEmpty else { return }

        let handler = handler
        Task { @MainActor in
            handler(events)
        }
    }

    private static func flags(
        from rawFlags: FSEventStreamEventFlags
    ) -> SourceFilesystemEvent.Flags {
        var flags: SourceFilesystemEvent.Flags = []
        if rawFlags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0 {
            flags.insert(.directory)
        }
        if rawFlags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated) != 0 {
            flags.insert(.created)
        }
        if rawFlags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemRemoved) != 0 {
            flags.insert(.removed)
        }
        if rawFlags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed) != 0 {
            flags.insert(.renamed)
        }
        if rawFlags & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs) != 0 {
            flags.insert(.mustScanSubdirectories)
        }
        if rawFlags
            & FSEventStreamEventFlags(
                kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped
            ) != 0
        {
            flags.insert(.eventsDropped)
        }
        if rawFlags & FSEventStreamEventFlags(kFSEventStreamEventFlagEventIdsWrapped) != 0 {
            flags.insert(.eventIDsWrapped)
        }
        if rawFlags & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged) != 0 {
            flags.insert(.rootChanged)
        }
        return flags
    }
}

private let sourceFilesystemEventCallback: FSEventStreamCallback = {
    _, context, eventCount, eventPaths, eventFlags, _ in
    guard let context else { return }
    let monitor = Unmanaged<SourceFilesystemMonitor>
        .fromOpaque(context)
        .takeUnretainedValue()
    monitor.receive(paths: eventPaths, flags: eventFlags, count: eventCount)
}
