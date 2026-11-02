/// Bounded scalar history for identifying submitted buffers and finding nearby
/// timestamps. The presenter owns synchronization; no pixel buffers are retained.
struct VideoFrameIdentityHistory: Sendable {
    struct Identity: Equatable, Sendable {
        let surfaceID: UInt32?
        let bufferID: UInt
        let time: Double
        let generation: Int
    }

    static let capacity = 128
    private var identities: [Identity] = []
    // Once full, this is both the next slot to replace and the oldest entry.
    // It remains zero while the array grows or after a flush.
    private var nextIndex = 0

    var count: Int { identities.count }

    mutating func append(_ identity: Identity) {
        if identities.count < Self.capacity {
            identities.append(identity)
        } else {
            identities[nextIndex] = identity
            nextIndex += 1
            if nextIndex == Self.capacity { nextIndex = 0 }
        }
    }

    func identity(surfaceID: UInt32?, bufferID: UInt) -> Identity? {
        // Search in reverse submission order, including when the newest entry
        // is physically before older entries. A surface miss never falls back
        // to buffer identity.
        return identities.withUnsafeBufferPointer { buffer in
            guard !buffer.isEmpty, let base = buffer.baseAddress else { return nil }
            assert(nextIndex >= 0 && nextIndex < buffer.count)
            let split = nextIndex == 0 ? buffer.count : nextIndex
            if let surfaceID {
                for index in (0..<split).reversed() {
                    let identity = base[index]
                    if identity.surfaceID == surfaceID { return identity }
                }
                for index in (split..<buffer.count).reversed() {
                    let identity = base[index]
                    if identity.surfaceID == surfaceID { return identity }
                }
            } else {
                for index in (0..<split).reversed() {
                    let identity = base[index]
                    if identity.bufferID == bufferID { return identity }
                }
                for index in (split..<buffer.count).reversed() {
                    let identity = base[index]
                    if identity.bufferID == bufferID { return identity }
                }
            }
            return nil
        }
    }

    func adjacentTime(to frame: Identity, direction: Int) -> Double? {
        // Times need not be monotonic. Reduce the two contiguous spans in
        // submission order without branching on wrap/direction for every entry.
        // Strict improvement preserves the older value on signed-zero ties.
        // The read-only pointer stays within this scope; both spans are bounded
        // by the array count and the private nextIndex invariant.
        return identities.withUnsafeBufferPointer { buffer in
            guard !buffer.isEmpty, let base = buffer.baseAddress else { return nil }
            assert(nextIndex >= 0 && nextIndex < buffer.count)
            var found = false
            if direction > 0 {
                let boundary = frame.time + 0.000001
                var nearest = Double.infinity
                for index in nextIndex..<buffer.count {
                    let candidate = base[index]
                    if candidate.generation == frame.generation, candidate.time > boundary {
                        if candidate.time < nearest { nearest = candidate.time }
                        found = true
                    }
                }
                for index in 0..<nextIndex {
                    let candidate = base[index]
                    if candidate.generation == frame.generation, candidate.time > boundary {
                        if candidate.time < nearest { nearest = candidate.time }
                        found = true
                    }
                }
                return found ? nearest : nil
            } else {
                let boundary = frame.time - 0.000001
                var nearest = -Double.infinity
                for index in nextIndex..<buffer.count {
                    let candidate = base[index]
                    if candidate.generation == frame.generation, candidate.time < boundary {
                        if candidate.time > nearest { nearest = candidate.time }
                        found = true
                    }
                }
                for index in 0..<nextIndex {
                    let candidate = base[index]
                    if candidate.generation == frame.generation, candidate.time < boundary {
                        if candidate.time > nearest { nearest = candidate.time }
                        found = true
                    }
                }
                return found ? nearest : nil
            }
        }
    }

    mutating func removeAll() {
        identities.removeAll(keepingCapacity: true)
        nextIndex = 0
    }
}
