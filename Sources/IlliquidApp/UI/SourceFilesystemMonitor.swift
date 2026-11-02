import AppKit
import CoreServices
import Foundation
import IlliquidCore

/// Main-actor facade. Native stream operations run on one shared utility queue:
/// FSEventStreamCreate can block opening an unavailable mounted path.
final class SourceFilesystemMonitor: @unchecked Sendable {
    typealias Handler = @MainActor @Sendable ([SourceFilesystemEvent]) -> Void
    private let handler: Handler
    private let worker: SourceFilesystemStreamWorker
    private let notifications: NotificationCenter
    private var volumeObservers: [NSObjectProtocol] = []
    private var watchedRoots: [URL] = []
    private var generation: UInt64 = 0
    private var delivery: SourceFilesystemEventDelivery?

    @MainActor init(worker: SourceFilesystemStreamWorker = .init(), handler: @escaping Handler) {
        self.handler = handler
        self.worker = worker
        notifications = NSWorkspace.shared.notificationCenter
    }

    deinit {
        delivery?.close()
        worker.stop()
        for observer in volumeObservers { notifications.removeObserver(observer) }
    }

    /// Returns whether a nonempty watch request was queued, not native readiness.
    @MainActor @discardableResult
    func start(watching roots: [URL], latency: TimeInterval = 0.15) -> Bool {
        stop()
        let paths = Array(Set(roots.map { $0.absoluteURL.standardized.path })).sorted()
        guard !paths.isEmpty else { return false }
        watchedRoots = roots
        let revision = generation
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            volumeObservers.append(notifications.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] notification in
                guard let volume = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
                MainActor.assumeIsolated { self?.volumeChanged(path: volume.standardizedFileURL.path) }
            })
        }
        let delivery = SourceFilesystemEventDelivery { [weak self] events in
            guard let self, self.generation == revision else { return }
            self.handler(events)
        }
        self.delivery = delivery
        worker.start(paths: paths, latency: latency) { events in
            delivery.send(events)
        }
        return true
    }

    @MainActor private func volumeChanged(path: String) {
        let affected = SourceVolumeChangePolicy.affectedRoots(at: path, roots: watchedRoots)
        guard !affected.isEmpty else { return }
        LifecyclePerformance.mark("source-volume-change")
        let roots = watchedRoots
        start(watching: roots)
        handler(affected.map { .init(path: $0.path, flags: [.rootChanged]) })
    }

    @MainActor func stop() {
        generation &+= 1
        delivery?.close()
        delivery = nil
        for observer in volumeObservers { notifications.removeObserver(observer) }
        volumeObservers.removeAll()
        watchedRoots.removeAll()
        worker.stop()
    }
}

protocol SourceFilesystemStream: AnyObject, Sendable {
    func stop()
}

final class SourceFilesystemStreamWorker: @unchecked Sendable {
    typealias Receive = @Sendable ([SourceFilesystemEvent]) -> Void
    typealias Factory = @Sendable ([String], TimeInterval, DispatchQueue, @escaping Receive) -> (any SourceFilesystemStream)?
    private static let sharedQueue = DispatchQueue(label: "com.illiquid.source-watch", qos: .utility)
    private let queue: DispatchQueue
    private let factory: Factory
    private let lock = NSLock()
    private var generation: UInt64 = 0 // Protected by lock; never held during native calls.
    private var stream: (any SourceFilesystemStream)? // Accessed only on queue.

    init(queue: DispatchQueue? = nil, factory: @escaping Factory = { paths, latency, queue, receive in
        NativeSourceFilesystemStream(paths: paths, latency: latency, queue: queue, receive: receive)
    }) {
        self.queue = queue ?? Self.sharedQueue
        self.factory = factory
    }

    private func advance() -> UInt64 { lock.withLock { generation &+= 1; return generation } }
    private func isCurrent(_ revision: UInt64) -> Bool { lock.withLock { generation == revision } }

    func start(paths: [String], latency: TimeInterval, receive: @escaping Receive) {
        let revision = advance()
        queue.async { [self] in
            guard isCurrent(revision) else { return }
            stream?.stop()
            stream = nil
            guard isCurrent(revision) else { return }
            let receiveCurrent: Receive = { [weak self] events in
                guard self?.isCurrent(revision) == true else { return }
                receive(events)
            }
            let created = factory(paths, latency, queue, receiveCurrent)
            // Stop/restart may have arrived while FSEvents was blocked in open.
            guard isCurrent(revision) else { created?.stop(); return }
            stream = created
            // The initial scan can finish before asynchronous native startup.
            // Reconcile every root once monitoring is active so changes in that
            // gap are recovered even if no further filesystem event arrives.
            if created != nil {
                receiveCurrent(paths.map { .init(path: $0, flags: [.mustScanSubdirectories]) })
            }
        }
    }

    func stop() {
        let revision = advance()
        queue.async { [self] in
            guard isCurrent(revision) else { return }
            stream?.stop()
            stream = nil
        }
    }
}

private final class SourceFilesystemEventReceiver: @unchecked Sendable {
    let receive: SourceFilesystemStreamWorker.Receive
    init(_ receive: @escaping SourceFilesystemStreamWorker.Receive) { self.receive = receive }
}

/// All operations, including callbacks and teardown, are confined to the worker queue.
private final class NativeSourceFilesystemStream: SourceFilesystemStream, @unchecked Sendable {
    private var stream: FSEventStreamRef?
    init?(paths: [String], latency: TimeInterval, queue: DispatchQueue,
          receive: @escaping SourceFilesystemStreamWorker.Receive) {
        let receiver = SourceFilesystemEventReceiver(receive)
        var context = FSEventStreamContext(version: 0,
            info: Unmanaged.passUnretained(receiver).toOpaque(),
            retain: { pointer in
                guard let pointer else { return nil }
                _ = Unmanaged<SourceFilesystemEventReceiver>.fromOpaque(pointer).retain()
                return pointer
            },
            release: { pointer in
                if let pointer { Unmanaged<SourceFilesystemEventReceiver>.fromOpaque(pointer).release() }
            }, copyDescription: nil)
        let created = withExtendedLifetime(receiver) {
            FSEventStreamCreate(kCFAllocatorDefault, sourceFilesystemEventCallback, &context,
                paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency,
                FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot))
        }
        guard let created else { return nil }
        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            return nil
        }
        stream = created
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    fileprivate static func receive(paths: UnsafeMutableRawPointer,
        flags: UnsafePointer<FSEventStreamEventFlags>, count: Int,
        receiver: SourceFilesystemEventReceiver) {
        let pointers = paths.assumingMemoryBound(to: Optional<UnsafePointer<CChar>>.self)
        let events = SourceFilesystemEventBatch.decode(
            paths: UnsafeBufferPointer(start: pointers, count: count),
            flagsAt: { Self.flags(from: flags[$0]) }
        )
        if !events.isEmpty { receiver.receive(events) }
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
    _, context, count, paths, flags, _ in
    guard let context else { return }
    let receiver = Unmanaged<SourceFilesystemEventReceiver>.fromOpaque(context).takeUnretainedValue()
    NativeSourceFilesystemStream.receive(paths: paths, flags: flags, count: count, receiver: receiver)
}
