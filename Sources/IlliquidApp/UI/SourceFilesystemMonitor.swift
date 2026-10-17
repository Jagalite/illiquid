import AppKit
import CoreServices
import Foundation
import IlliquidCore

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
        let affected = SourceFilesystemInvalidationPlanner.rootsAffectedByVolumeChange(
            at: path, roots: watchedRoots)
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
