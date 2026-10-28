import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

public struct RingBenchmarkObservation: Codable {
    public let workload: String
    public let capacity: Int
    public let iterations: Int
    public let operations: Int
    public let seed: UInt64
    public let wall_ns: UInt64
    public let cpu_ns: UInt64
    public let checksum: String
    public let tail_checksum: String
    public let final_count: Int
}

private func cpuTime() -> UInt64 {
    var value = timespec()
    precondition(clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &value) == 0)
    return UInt64(value.tv_sec) * 1_000_000_000 + UInt64(value.tv_nsec)
}

private struct Timer {
    let cpu = cpuTime()
    let wall = DispatchTime.now().uptimeNanoseconds
    func stop() -> (wall: UInt64, cpu: UInt64) {
        let wallElapsed = DispatchTime.now().uptimeNanoseconds - wall
        return (wallElapsed, cpuTime() - cpu)
    }
}

private func mix(_ value: UInt64, into checksum: inout UInt64) {
    checksum = (checksum ^ value) &* 1_099_511_628_211
}

private final class Payload {
    let value: UInt64
    init(_ value: UInt64) { self.value = value }
}

/// This bridge is compiled in the production module so generic storage is
/// specialized for its concrete payloads, just as in the application. Runtime
/// capacities and iteration counts enter through a separate driver module.
public enum RingBufferBenchmark {
    public static func verify() -> [String: [UInt64]] {
        var traces: [String: [UInt64]] = [:]
        for capacity in [1, 2, 3, 12, 48, 64, 96, 192] {
            var ring = FixedRingBuffer<UInt64>(capacity: capacity)
            var oracle: [UInt64] = []
            var random = UInt64(capacity) ^ 0xA123_53FE_B40D_C897
            var trace: [UInt64] = []
            for step in 0..<8_192 {
                random = random &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                let choice = random >> 32
                if choice % 101 == 0 {
                    var snapshot = ring
                    for expected in oracle {
                        let actual = snapshot.removeFirst()
                        precondition(actual == expected)
                        trace.append(actual)
                    }
                    ring.removeAll(keepingCapacity: choice & 1 == 0)
                    oracle.removeAll()
                } else if oracle.isEmpty || (oracle.count < capacity && choice % 3 != 0) {
                    let value = UInt64(step) ^ random
                    if choice & 1 == 0 {
                        ring.append(value); oracle.append(value)
                    } else {
                        ring.prepend(value); oracle.insert(value, at: 0)
                    }
                } else {
                    let actual = ring.removeFirst()
                    precondition(actual == oracle.removeFirst())
                    trace.append(actual)
                }
                precondition(ring.count == oracle.count && ring.isEmpty == oracle.isEmpty)
                trace.append(UInt64(ring.count))
            }
            for expected in oracle {
                let actual = ring.removeFirst()
                precondition(actual == expected)
                trace.append(actual)
            }
            traces["ring-\(capacity)"] = trace

            let queue = BoundedQueue<UInt64>(capacity: capacity,
                byteCapacity: capacity * 16, durationCapacityMicroseconds: Int64(capacity * 2),
                cost: { _ in BoundedQueueCost(bytes: 8, durationMicroseconds: 1) })
            var queueTrace: [UInt64] = []
            for round in 0..<32 {
                for index in 0..<capacity {
                    precondition(queue.tryPush(UInt64(round * capacity + index)) == .pushed)
                }
                precondition(queue.tryPush(999) == .wouldBlock)
                for index in 0..<capacity {
                    guard case let .value(value) = queue.pop() else { preconditionFailure("Closed queue") }
                    precondition(value == UInt64(round * capacity + index))
                    queueTrace.append(value)
                }
                precondition(queue.pushFirst(UInt64(round)))
                guard case let .value(value) = queue.pop() else { preconditionFailure("Closed queue") }
                precondition(value == UInt64(round))
                queueTrace.append(value)
            }
            queue.removeAll()
            precondition(queue.budgetSnapshot == .init(items: 0, bytes: 0, durationMicroseconds: 0))
            queue.close()
            traces["queue-\(capacity)"] = queueTrace
        }
        return traces
    }

    @inline(never)
    public static func measure(workload: String, capacity: Int, iterations: Int,
                               seed: UInt64) -> RingBenchmarkObservation {
        precondition(capacity > 0 && iterations > 0)
        precondition(["ring-fifo-int", "ring-prepend-int", "ring-burst-int", "ring-fifo-ref",
                      "queue-fifo-int", "queue-prepend-int", "queue-burst-int", "queue-fifo-ref",
                      "checksum"].contains(workload))
        let burst = workload.contains("burst")
        let prepend = workload.contains("prepend")
        let reference = workload.hasSuffix("-ref")
        let queueMode = workload.hasPrefix("queue-")
        let operations = burst ? iterations * capacity : iterations
        var checksum: UInt64 = 1_469_598_103_934_665_603
        var tailChecksum: UInt64 = 1_469_598_103_934_665_603
        let elapsed: (wall: UInt64, cpu: UInt64)
        let finalCount: Int

        if workload == "checksum" {
            let timer = Timer()
            for index in 0..<iterations { mix(seed &+ UInt64(index), into: &checksum) }
            elapsed = timer.stop()
            finalCount = 0
        } else if reference {
            precondition(!burst && !prepend)
            let pool = (0..<capacity).map { Payload(seed &+ UInt64($0)) }
            var cursor = capacity / 2
            if queueMode {
                let queue = BoundedQueue<Payload>(capacity: capacity,
                    byteCapacity: capacity * 16, durationCapacityMicroseconds: Int64(capacity * 2),
                    cost: { _ in BoundedQueueCost(bytes: 8, durationMicroseconds: 1) })
                for index in 0..<(capacity / 2) { precondition(queue.push(pool[index])) }
                let timer = Timer()
                for _ in 0..<iterations {
                    precondition(queue.push(pool[cursor]))
                    guard case let .value(value) = queue.pop() else { preconditionFailure("Closed queue") }
                    mix(value.value, into: &checksum)
                    cursor += 1
                    if cursor == capacity { cursor = 0 }
                }
                elapsed = timer.stop()
                finalCount = queue.count
                for _ in 0..<finalCount {
                    guard case let .value(value) = queue.pop() else { preconditionFailure("Closed queue") }
                    mix(value.value, into: &tailChecksum)
                }
                precondition(queue.budgetSnapshot == .init(items: 0, bytes: 0, durationMicroseconds: 0))
                queue.close()
            } else {
                var ring = FixedRingBuffer<Payload>(capacity: capacity)
                for index in 0..<(capacity / 2) { ring.append(pool[index]) }
                let timer = Timer()
                for _ in 0..<iterations {
                    ring.append(pool[cursor])
                    mix(ring.removeFirst().value, into: &checksum)
                    cursor += 1
                    if cursor == capacity { cursor = 0 }
                }
                elapsed = timer.stop()
                finalCount = ring.count
                while !ring.isEmpty { mix(ring.removeFirst().value, into: &tailChecksum) }
            }
            withExtendedLifetime(pool) {}
        } else if queueMode {
            let queue = BoundedQueue<UInt64>(capacity: capacity,
                byteCapacity: capacity * 16, durationCapacityMicroseconds: Int64(capacity * 2),
                cost: { _ in BoundedQueueCost(bytes: 8, durationMicroseconds: 1) })
            if !burst {
                for index in 0..<(capacity / 2) { precondition(queue.push(seed &+ UInt64(index))) }
            }
            let timer = Timer()
            if burst {
                for round in 0..<iterations {
                    for index in 0..<capacity {
                        precondition(queue.push(seed &+ UInt64(round * capacity + index)))
                    }
                    for _ in 0..<capacity {
                        guard case let .value(value) = queue.pop() else { preconditionFailure("Closed queue") }
                        mix(value, into: &checksum)
                    }
                }
            } else {
                for index in 0..<iterations {
                    let value = seed &+ UInt64(capacity + index)
                    precondition(prepend ? queue.pushFirst(value) : queue.push(value))
                    guard case let .value(removed) = queue.pop() else { preconditionFailure("Closed queue") }
                    mix(removed, into: &checksum)
                }
            }
            elapsed = timer.stop()
            finalCount = queue.count
            for _ in 0..<finalCount {
                guard case let .value(value) = queue.pop() else { preconditionFailure("Closed queue") }
                mix(value, into: &tailChecksum)
            }
            precondition(queue.budgetSnapshot == .init(items: 0, bytes: 0, durationMicroseconds: 0))
            queue.close()
        } else {
            var ring = FixedRingBuffer<UInt64>(capacity: capacity)
            if !burst {
                for index in 0..<(capacity / 2) { ring.append(seed &+ UInt64(index)) }
            }
            let timer = Timer()
            if burst {
                for round in 0..<iterations {
                    for index in 0..<capacity { ring.append(seed &+ UInt64(round * capacity + index)) }
                    for _ in 0..<capacity { mix(ring.removeFirst(), into: &checksum) }
                }
            } else {
                for index in 0..<iterations {
                    let value = seed &+ UInt64(capacity + index)
                    if prepend { ring.prepend(value) } else { ring.append(value) }
                    mix(ring.removeFirst(), into: &checksum)
                }
            }
            elapsed = timer.stop()
            finalCount = ring.count
            while !ring.isEmpty { mix(ring.removeFirst(), into: &tailChecksum) }
        }
        return RingBenchmarkObservation(workload: workload, capacity: capacity,
            iterations: iterations, operations: operations, seed: seed,
            wall_ns: elapsed.wall, cpu_ns: elapsed.cpu, checksum: String(checksum),
            tail_checksum: String(tailChecksum), final_count: finalCount)
    }
}
