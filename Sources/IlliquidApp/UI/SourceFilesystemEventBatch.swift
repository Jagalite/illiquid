import Foundation

/// Avoids decoding path strings that the sidebar's event buffer would discard.
/// The bound applies to one native callback, not to the number of callbacks
/// waiting for main-actor delivery. Nil paths are skipped just as in the native
/// callback, so only admitted events count toward the shared limit.
enum SourceFilesystemEventBatch {
    static func decode(
        paths: UnsafeBufferPointer<UnsafePointer<CChar>?>,
        flagsAt: (Int) -> SourceFilesystemEvent.Flags
    ) -> [SourceFilesystemEvent] {
        let maximumCount = SourceFilesystemEventBuffer.defaultMaximumCount
        var capacity = paths.count
        if paths.count > maximumCount {
            var validCount = 0
            for pointer in paths {
                guard pointer != nil else { continue }
                validCount += 1
                if validCount > maximumCount {
                    // The downstream buffer already collapses this callback to
                    // event-loss recovery. Inspect pointer presence only: none
                    // of its C strings or flags need to be read first.
                    return [.init(path: "/", flags: [.eventsDropped])]
                }
            }
            guard validCount > 0 else { return [] }
            capacity = validCount
        }

        var events: [SourceFilesystemEvent] = []
        events.reserveCapacity(capacity)
        for index in paths.indices {
            guard let pointer = paths[index] else { continue }
            events.append(.init(path: String(cString: pointer), flags: flagsAt(index)))
        }
        return events
    }
}
