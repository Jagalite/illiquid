import Dispatch
import Foundation

// Compile in the same module as the exact production sources. All capacities
// come from argv so the baseline cannot specialize a constant divisor.
private struct Sample {
    let elapsedNanoseconds: UInt64
    let checksum: Int
}

private final class Payload {
    let value: Int
    init(_ value: Int) { self.value = value }
}

@main
private enum Driver {
    static func main() throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 4,
              let capacity = Int(arguments[2]), (1...100_000).contains(capacity),
              let iterations = Int(arguments[3]), (1...1_000_000_000).contains(iterations) else {
            fatalError("usage: probe CASE CAPACITY ITERATIONS")
        }
        let name = arguments[1]
        // Warm the same operation in each fresh process, then reconstruct the
        // fixture. Both checksums are observable; warmup is outside the sample.
        let warmup = measure(name, capacity: capacity, iterations: min(iterations, 20_000))
        let sample = measure(name, capacity: capacity, iterations: iterations)
        let data = try JSONSerialization.data(withJSONObject: [
            "case": name, "capacity": capacity, "iterations": iterations,
            "operations": iterations * 2,
            "elapsed_ns": sample.elapsedNanoseconds, "checksum": sample.checksum,
            "warmup_checksum": warmup.checksum
        ], options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }

    private static func measure(_ name: String, capacity: Int, iterations: Int) -> Sample {
        switch name {
        case "ring-fifo": return ringFIFO(capacity: capacity, iterations: iterations)
        case "ring-prepend": return ringPrepend(capacity: capacity, iterations: iterations)
        case "queue-fifo": return queueFIFO(capacity: capacity, iterations: iterations)
        case "queue-prepend": return queuePrepend(capacity: capacity, iterations: iterations)
        case "ring-reference-fifo": return ringReferenceFIFO(capacity: capacity, iterations: iterations)
        case "queue-reference-fifo": return queueReferenceFIFO(capacity: capacity, iterations: iterations)
        default: fatalError("unknown case: " + name)
        }
    }

    @inline(never)
    private static func ringFIFO(capacity: Int, iterations: Int) -> Sample {
        var ring = FixedRingBuffer<Int>(capacity: capacity)
        for value in 0..<(capacity - 1) { ring.append(value) }
        var checksum = 0
        let start = DispatchTime.now().uptimeNanoseconds
        for value in 0..<iterations {
            ring.append(value)
            checksum &+= ring.removeFirst()
        }
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        precondition(ring.count == capacity - 1)
        return Sample(elapsedNanoseconds: elapsed, checksum: checksum)
    }

    @inline(never)
    private static func ringPrepend(capacity: Int, iterations: Int) -> Sample {
        var ring = FixedRingBuffer<Int>(capacity: capacity)
        var checksum = 0
        var completed = 0
        let start = DispatchTime.now().uptimeNanoseconds
        while completed < iterations {
            let count = min(capacity, iterations - completed)
            // Batch before reading to exercise stored elements, rather than a
            // prepend/immediate-pop pair the optimizer could collapse.
            for offset in 0..<count { ring.prepend(completed + offset) }
            for _ in 0..<count { checksum &+= ring.removeFirst() }
            completed += count
        }
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        precondition(ring.isEmpty)
        return Sample(elapsedNanoseconds: elapsed, checksum: checksum)
    }

    @inline(never)
    private static func queueFIFO(capacity: Int, iterations: Int) -> Sample {
        let queue = BoundedQueue<Int>(capacity: capacity, cost: { _ in
            .init(bytes: 4_096, durationMicroseconds: 20_000)
        })
        for value in 0..<(capacity - 1) { precondition(queue.push(value)) }
        var checksum = 0
        let start = DispatchTime.now().uptimeNanoseconds
        for value in 0..<iterations {
            precondition(queue.push(value))
            guard case let .value(removed) = queue.pop() else { fatalError("closed queue") }
            checksum &+= removed
        }
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        precondition(queue.count == capacity - 1)
        return Sample(elapsedNanoseconds: elapsed, checksum: checksum)
    }

    @inline(never)
    private static func queuePrepend(capacity: Int, iterations: Int) -> Sample {
        let queue = BoundedQueue<Int>(capacity: capacity, cost: { _ in
            .init(bytes: 4_096, durationMicroseconds: 20_000)
        })
        var checksum = 0
        var completed = 0
        let start = DispatchTime.now().uptimeNanoseconds
        while completed < iterations {
            let count = min(capacity, iterations - completed)
            for offset in 0..<count { precondition(queue.pushFirst(completed + offset)) }
            for _ in 0..<count {
                guard case let .value(removed) = queue.pop() else { fatalError("closed queue") }
                checksum &+= removed
            }
            completed += count
        }
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        precondition(queue.count == 0)
        return Sample(elapsedNanoseconds: elapsed, checksum: checksum)
    }

    @inline(never)
    private static func ringReferenceFIFO(capacity: Int, iterations: Int) -> Sample {
        // Allocation is outside timing. Distinct references cycle through the
        // same generic storage used for packet/frame owners without FFmpeg.
        let payloads = (0..<capacity).map { Payload($0) }
        var ring = FixedRingBuffer<Payload>(capacity: capacity)
        for value in payloads.dropLast() { ring.append(value) }
        var next = capacity - 1
        var checksum = 0
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<iterations {
            ring.append(payloads[next])
            checksum &+= ring.removeFirst().value
            next += 1
            if next == capacity { next = 0 }
        }
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        precondition(ring.count == capacity - 1)
        return Sample(elapsedNanoseconds: elapsed, checksum: checksum)
    }

    @inline(never)
    private static func queueReferenceFIFO(capacity: Int, iterations: Int) -> Sample {
        let payloads = (0..<capacity).map { Payload($0) }
        let queue = BoundedQueue<Payload>(capacity: capacity, cost: { _ in
            .init(bytes: 4_096, durationMicroseconds: 20_000)
        })
        for value in payloads.dropLast() { precondition(queue.push(value)) }
        var next = capacity - 1
        var checksum = 0
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<iterations {
            precondition(queue.push(payloads[next]))
            guard case let .value(removed) = queue.pop() else { fatalError("closed queue") }
            checksum &+= removed.value
            next += 1
            if next == capacity { next = 0 }
        }
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        precondition(queue.count == capacity - 1)
        return Sample(elapsedNanoseconds: elapsed, checksum: checksum)
    }
}
