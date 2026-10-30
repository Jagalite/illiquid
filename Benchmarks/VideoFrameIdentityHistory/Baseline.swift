// Frozen history operations from SampleBufferVideoPresenter at
// ea2ff568237e2667f7b1aeee67b11a44ebe95b72. run.py checks the original
// source and these operation bodies before compiling either variant.
// Adaptations: omit Apple renderer/buffer extraction, accept scalar IDs,
// and move the unchanged NSLock scope into the shared benchmark bridge.
struct VideoFrameIdentityHistory {
    struct Identity: Equatable, Sendable {
        let surfaceID: UInt32?
        let bufferID: UInt
        let time: Double
        let generation: Int
    }

    static let capacity = 128
    private var frameIdentities: [Identity] = []
    var count: Int { frameIdentities.count }

    mutating func append(_ identity: Identity) {
        if frameIdentities.count == 128 { frameIdentities.removeFirst() }
        frameIdentities.append(identity)
    }

    func identity(surfaceID: UInt32?, bufferID: UInt) -> Identity? {
        let surface = surfaceID
        return frameIdentities.last {
            if let surface { return $0.surfaceID == surface }
            return $0.bufferID == bufferID
        }
    }

    func adjacentTime(to frame: Identity, direction: Int) -> Double? {
        let times = frameIdentities.lazy.filter { $0.generation == frame.generation }.map(\.time)
        return direction > 0
            ? times.filter { $0 > frame.time + 0.000001 }.min()
            : times.filter { $0 < frame.time - 0.000001 }.max()
    }

    mutating func removeAll() {
        frameIdentities.removeAll(keepingCapacity: true)
    }
}
