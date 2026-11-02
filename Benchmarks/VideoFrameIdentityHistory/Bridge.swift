import Foundation

public struct Record: Equatable {
    public let surfaceID: UInt32?
    public let bufferID: UInt
    public let time: Double
    public let generation: Int

    public init(surfaceID: UInt32?, bufferID: UInt, time: Double, generation: Int) {
        self.surfaceID = surfaceID
        self.bufferID = bufferID
        self.time = time
        self.generation = generation
    }
}

// The driver is separately compiled without cross-module optimization. Every
// timed operation crosses an opaque, non-inlinable boundary and changes state
// that another public operation can inspect. Intermediate appends cannot be
// discarded as dead stores merely because only the last 128 records survive.
public final class HistoryWorker {
    private var history = VideoFrameIdentityHistory()
    private let lock = NSLock()
    private let includesLock: Bool

    public init(includesLock: Bool, initialCount: Int = 384) {
        precondition(initialCount >= 128)
        self.includesLock = includesLock
        for token in 0..<initialCount { _ = append(token) }
    }

    public static var identityStride: Int {
        MemoryLayout<VideoFrameIdentityHistory.Identity>.stride
    }

    public var count: Int { synchronized { history.count } }

    private func synchronized<Value>(_ body: () -> Value) -> Value {
        if includesLock {
            lock.lock()
            defer { lock.unlock() }
            return body()
        }
        return body()
    }

    private func identity(_ token: Int) -> VideoFrameIdentityHistory.Identity {
        .init(surfaceID: UInt32(token + 1), bufferID: UInt(token + 1_000),
              time: Double(token) / 60, generation: 7)
    }

    @inline(never)
    public func append(_ token: Int) -> UInt64 {
        let value = identity(token)
        return synchronized {
            history.append(value)
            return UInt64(history.count)
        }
    }

    @inline(never)
    public func lookup(_ token: Int) -> UInt64 {
        synchronized {
            history.identity(surfaceID: UInt32(token + 1), bufferID: UInt(token + 1_000))
                .map { UInt64($0.bufferID) } ?? UInt64.max
        }
    }

    @inline(never)
    public func adjacent(_ token: Int, direction: Int) -> UInt64 {
        let frame = identity(token)
        return synchronized {
            history.adjacentTime(to: frame, direction: direction)?.bitPattern ?? UInt64.max
        }
    }

    @inline(never)
    public func clear() {
        synchronized { history.removeAll() }
    }

    // Used only after timing to compare every surviving scalar field, both
    // lookup modes, eviction, and absence against the independent numeric model.
    public func record(surfaceID: UInt32?, bufferID: UInt) -> Record? {
        synchronized {
            history.identity(surfaceID: surfaceID, bufferID: bufferID).map {
                Record(surfaceID: $0.surfaceID, bufferID: $0.bufferID,
                       time: $0.time, generation: $0.generation)
            }
        }
    }
}
