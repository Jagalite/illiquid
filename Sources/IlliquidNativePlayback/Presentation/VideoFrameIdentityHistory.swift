/// Scalar metadata for the most recently enqueued frames. The presenter owns
/// synchronization; this value never retains pixel buffers or IOSurfaces.
struct VideoFrameIdentityHistory: Sendable {
    struct FrameIdentity: Sendable {
        let surfaceID: UInt32?
        let bufferID: UInt
        let time: Double
        let generation: Int
    }

    private static let capacity = 128
    private var entries: [FrameIdentity] = []
    // The next slot to replace once full; equals count while still filling.
    private var nextInsertionIndex = 0

    mutating func append(_ identity: FrameIdentity) {
        if entries.count < Self.capacity {
            entries.append(identity)
        } else {
            entries[nextInsertionIndex] = identity
        }
        nextInsertionIndex += 1
        if nextInsertionIndex == Self.capacity { nextInsertionIndex = 0 }
    }

    mutating func removeAll() {
        entries.removeAll(keepingCapacity: true)
        nextInsertionIndex = 0
    }

    func identity(surfaceID: UInt32?, bufferID: UInt) -> FrameIdentity? {
        // The prefix contains the newest entries after wraparound. Searching
        // each contiguous range backward preserves newest-enqueue precedence.
        if let match = identity(in: 0..<nextInsertionIndex, surfaceID: surfaceID, bufferID: bufferID) {
            return match
        }
        return identity(in: nextInsertionIndex..<entries.count, surfaceID: surfaceID, bufferID: bufferID)
    }

    private func identity(in range: Range<Int>, surfaceID: UInt32?, bufferID: UInt) -> FrameIdentity? {
        for index in range.reversed() {
            let entry = entries[index]
            if let surfaceID {
                if entry.surfaceID == surfaceID { return entry }
            } else if entry.bufferID == bufferID {
                return entry
            }
        }
        return nil
    }

    func adjacentTime(to frame: FrameIdentity, direction: Int) -> Double? {
        let forward = direction > 0
        let threshold = forward ? frame.time + 0.000001 : frame.time - 0.000001
        var best: Double?
        func consider(_ entry: FrameIdentity) {
            guard entry.generation == frame.generation,
                  forward ? entry.time > threshold : entry.time < threshold else { return }
            if let current = best {
                if forward ? entry.time < current : entry.time > current { best = entry.time }
            } else {
                best = entry.time
            }
        }
        // Visit oldest to newest, as the original array did. Equal extrema
        // retain the first value, including the sign of a zero timestamp.
        for entry in entries[nextInsertionIndex...] { consider(entry) }
        for entry in entries[..<nextInsertionIndex] { consider(entry) }
        return best
    }
}
