import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// Compile this driver beside the complete, unmodified production files:
// FixedRingBuffer.swift and PacketQueue.swift. There are no replacement queue
// implementations or platform adapters in the timing path.
private enum ProbeFailure: Error, CustomStringConvertible {
    case message(String)
    var description: String {
        switch self { case let .message(message): message }
    }
}

private func require(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String) throws {
    guard condition() else { throw ProbeFailure.message(message()) }
}

private func emit(_ value: Any) throws {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))
}

private func cpuNanoseconds() throws -> UInt64 {
    var value = timespec()
    guard clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &value) == 0 else {
        throw ProbeFailure.message("clock_gettime(CLOCK_PROCESS_CPUTIME_ID) failed")
    }
    return UInt64(value.tv_sec) * 1_000_000_000 + UInt64(value.tv_nsec)
}

private struct Stopwatch {
    let enabled: Bool
    let cpuStart: UInt64
    let wallStart: UInt64

    init(enabled: Bool) throws {
        self.enabled = enabled
        cpuStart = enabled ? try cpuNanoseconds() : 0
        wallStart = enabled ? DispatchTime.now().uptimeNanoseconds : 0
    }

    func stop() throws -> (wall: UInt64, cpu: UInt64) {
        guard enabled else { return (0, 0) }
        let wallEnd = DispatchTime.now().uptimeNanoseconds
        let cpuEnd = try cpuNanoseconds()
        return (wallEnd - wallStart, cpuEnd - cpuStart)
    }
}

private struct Workload {
    enum Kind: String {
        case append = "ring-append"
        case prepend = "ring-prepend"
        case drain = "ring-drain"
        case clear = "ring-clear"
        case reference = "ring-reference"
        case queue = "queue-fifo"
    }

    static let names = [
        "ring-append-c1-d1",
        "ring-append-c12-d1",
        "ring-append-c12-d6",
        "ring-append-c48-d24",
        "ring-append-c96-d48",
        "ring-append-c192-d96",
        "ring-append-c256-d128",
        "ring-prepend-c96",
        "ring-drain-c96",
        "ring-clear-c96",
        "ring-reference-c96-d48",
        "queue-fifo-c12-d6",
        "queue-fifo-c96-d48",
    ]

    let name: String
    let kind: Kind
    let capacity: Int
    let depth: Int

    init(_ name: String) throws {
        // Capacity/depth are parsed from runtime input instead of literals in
        // specialized workload functions. This matters for the modulo baseline.
        let parts = name.split(separator: "-").map(String.init)
        guard parts.count >= 3,
              let kind = Kind(rawValue: parts[0] + "-" + parts[1]),
              parts[2].first == "c",
              let capacity = Int(parts[2].dropFirst()),
              (1...4096).contains(capacity)
        else { throw ProbeFailure.message("Invalid workload: \(name)") }
        let needsDepth = kind == .append || kind == .reference || kind == .queue
        let depth: Int
        if needsDepth {
            guard parts.count == 4, parts[3].first == "d",
                  let parsed = Int(parts[3].dropFirst()), (1...capacity).contains(parsed)
            else { throw ProbeFailure.message("Invalid workload depth: \(name)") }
            depth = parsed
        } else {
            guard parts.count == 3 else { throw ProbeFailure.message("Unexpected workload suffix: \(name)") }
            depth = 0
        }
        self.name = name
        self.kind = kind
        self.capacity = capacity
        self.depth = depth
    }

    var logicalElementsPerIteration: Int {
        switch kind {
        case .append, .reference, .queue: 4096
        case .prepend, .drain, .clear: 32 * capacity
        }
    }

    var operationsPerIteration: Int {
        switch kind {
        case .append, .reference, .queue: 2 * logicalElementsPerIteration
        case .prepend, .drain: 2 * logicalElementsPerIteration
        case .clear:
            // A removeAll call counts as one API operation, although it releases
            // capacity - capacity / 2 retained elements internally.
            32 * (capacity + capacity / 2 + 1)
        }
    }
}

private struct Measurement {
    let checksum: UInt64
    let expectedChecksum: UInt64
    let finalCount: Int
    let wallNanoseconds: UInt64
    let cpuNanoseconds: UInt64

    func receipt(_ workload: Workload, iterations: Int, timed: Bool) -> [String: Any] {
        var result: [String: Any] = [
            "schema": 1,
            "workload": workload.name,
            "iterations": iterations,
            "capacity": workload.capacity,
            "initial_count": workload.depth,
            "logical_elements_per_iteration": workload.logicalElementsPerIteration,
            "operations_per_iteration": workload.operationsPerIteration,
            // Decimal strings preserve every UInt64 bit in JSON consumers.
            "checksum": String(checksum),
            "expected_checksum": String(expectedChecksum),
            "final_count": finalCount,
        ]
        if timed {
            result["wall_ns"] = wallNanoseconds
            result["cpu_ns"] = cpuNanoseconds
        }
        return result
    }
}

private func triangular(_ count: UInt64) -> UInt64 {
    // Workload admission caps count at one billion, so this product fits UInt64.
    count * (count + 1) / 2
}

@inline(never)
private func runAppend(capacity: Int, depth: Int, iterations: Int, timed: Bool) throws -> Measurement {
    let total = iterations * 4096
    let expected = triangular(UInt64(total))
    var ring = FixedRingBuffer<UInt64>(capacity: capacity)
    for value in 1...depth { ring.append(UInt64(value)) }
    var nextValue = UInt64(depth + 1)
    var checksum: UInt64 = 0
    let clock = try Stopwatch(enabled: timed)
    for _ in 0..<total {
        checksum &+= ring.removeFirst()
        ring.append(nextValue)
        nextValue &+= 1
    }
    let elapsed = try clock.stop()
    let finalCount = ring.count
    try require(finalCount == depth, "Append workload changed occupancy")
    // Validate the complete final queue outside the measured interval.
    for offset in 1...depth {
        try require(ring.removeFirst() == UInt64(total + offset), "Append final FIFO differs")
    }
    try require(ring.isEmpty, "Append final queue was not exhausted")
    return Measurement(checksum: checksum, expectedChecksum: expected, finalCount: finalCount,
                       wallNanoseconds: elapsed.wall, cpuNanoseconds: elapsed.cpu)
}

@inline(never)
private func runPrepend(capacity: Int, iterations: Int, timed: Bool) throws -> Measurement {
    let batches = iterations * 32
    let expected = triangular(UInt64(batches * capacity))
    var ring = FixedRingBuffer<UInt64>(capacity: capacity)
    // Begin at a nonzero head where possible; each full prepend/drain cycle
    // crosses the wrap boundary and returns to this offset.
    for _ in 0..<(capacity / 3) { ring.append(0); _ = ring.removeFirst() }
    var nextValue: UInt64 = 1
    var checksum: UInt64 = 0
    let clock = try Stopwatch(enabled: timed)
    for _ in 0..<batches {
        for _ in 0..<capacity {
            ring.prepend(nextValue)
            nextValue &+= 1
        }
        for _ in 0..<capacity { checksum &+= ring.removeFirst() }
    }
    let elapsed = try clock.stop()
    try require(ring.isEmpty, "Prepend workload did not drain")
    return Measurement(checksum: checksum, expectedChecksum: expected, finalCount: ring.count,
                       wallNanoseconds: elapsed.wall, cpuNanoseconds: elapsed.cpu)
}

@inline(never)
private func runDrain(capacity: Int, iterations: Int, timed: Bool) throws -> Measurement {
    let batches = iterations * 32
    let expected = triangular(UInt64(batches * capacity))
    var ring = FixedRingBuffer<UInt64>(capacity: capacity)
    for _ in 0..<(capacity / 3) { ring.append(0); _ = ring.removeFirst() }
    var nextValue: UInt64 = 1
    var checksum: UInt64 = 0
    let clock = try Stopwatch(enabled: timed)
    for _ in 0..<batches {
        for _ in 0..<capacity {
            ring.append(nextValue)
            nextValue &+= 1
        }
        for _ in 0..<capacity { checksum &+= ring.removeFirst() }
    }
    let elapsed = try clock.stop()
    try require(ring.isEmpty, "Drain workload did not drain")
    return Measurement(checksum: checksum, expectedChecksum: expected, finalCount: ring.count,
                       wallNanoseconds: elapsed.wall, cpuNanoseconds: elapsed.cpu)
}

@inline(never)
private func runClear(capacity: Int, iterations: Int, timed: Bool) throws -> Measurement {
    let batches = iterations * 32
    let removed = capacity / 2
    let blocks = UInt64(batches)
    let expected = blocks * (triangular(UInt64(removed)) + UInt64(capacity - removed))
        + UInt64(removed * capacity) * blocks * (blocks - 1) / 2
    var ring = FixedRingBuffer<UInt64>(capacity: capacity)
    var nextValue: UInt64 = 1
    var checksum: UInt64 = 0
    let clock = try Stopwatch(enabled: timed)
    for _ in 0..<batches {
        for _ in 0..<capacity {
            ring.append(nextValue)
            nextValue &+= 1
        }
        for _ in 0..<removed { checksum &+= ring.removeFirst() }
        checksum &+= UInt64(ring.count)
        ring.removeAll()
    }
    let elapsed = try clock.stop()
    try require(ring.isEmpty, "Clear workload retained elements")
    ring.append(0x1234)
    try require(ring.removeFirst() == 0x1234 && ring.isEmpty, "Clear workload could not refill")
    return Measurement(checksum: checksum, expectedChecksum: expected, finalCount: ring.count,
                       wallNanoseconds: elapsed.wall, cpuNanoseconds: elapsed.cpu)
}

private final class ReferencePayload {
    let value: UInt64
    init(_ value: UInt64) { self.value = value }
}

@inline(never)
private func runReference(capacity: Int, depth: Int, iterations: Int, timed: Bool) throws -> Measurement {
    let total = iterations * 4096
    // Allocation is outside timing; this workload includes retain/release work
    // while the fixture holds another reference, not object creation/destruction.
    let pool = (1...4096).map { ReferencePayload(UInt64($0)) }
    let expected = UInt64(iterations) * triangular(4096)
    var ring = FixedRingBuffer<ReferencePayload>(capacity: capacity)
    for index in 0..<depth { ring.append(pool[index]) }
    var nextIndex = depth
    var checksum: UInt64 = 0
    let clock = try Stopwatch(enabled: timed)
    for _ in 0..<total {
        checksum &+= ring.removeFirst().value
        ring.append(pool[nextIndex & 4095])
        nextIndex &+= 1
    }
    let elapsed = try clock.stop()
    let finalCount = ring.count
    try require(finalCount == depth, "Reference workload changed occupancy")
    for index in 0..<depth {
        try require(ring.removeFirst() === pool[(total + index) & 4095], "Reference final FIFO differs")
    }
    try require(ring.isEmpty, "Reference final queue was not exhausted")
    withExtendedLifetime(pool) {}
    return Measurement(checksum: checksum, expectedChecksum: expected, finalCount: finalCount,
                       wallNanoseconds: elapsed.wall, cpuNanoseconds: elapsed.cpu)
}

@inline(never)
private func runQueue(capacity: Int, depth: Int, iterations: Int, timed: Bool) throws -> Measurement {
    let total = iterations * 4096
    let expected = triangular(UInt64(total))
    let queue = BoundedQueue<UInt64>(
        capacity: capacity,
        byteCapacity: capacity * 8,
        durationCapacityMicroseconds: Int64(capacity * 1_000),
        cost: { _ in BoundedQueueCost(bytes: 8, durationMicroseconds: 1_000) }
    )
    for value in 1...depth { try require(queue.push(UInt64(value)), "Queue setup rejected a value") }
    var nextValue = UInt64(depth + 1)
    var checksum: UInt64 = 0
    let clock = try Stopwatch(enabled: timed)
    for _ in 0..<total {
        guard case let .value(value) = queue.pop() else {
            throw ProbeFailure.message("Queue closed during measurement")
        }
        checksum &+= value
        guard queue.push(nextValue) else {
            throw ProbeFailure.message("Queue rejected a value during measurement")
        }
        nextValue &+= 1
    }
    let elapsed = try clock.stop()
    let finalCount = queue.count
    let budget = queue.budgetSnapshot
    try require(finalCount == depth && budget.items == depth && budget.bytes == depth * 8
                && budget.durationMicroseconds == Int64(depth * 1_000),
                "Queue final occupancy/budget differs")
    for offset in 1...depth {
        guard case let .value(value) = queue.pop(), value == UInt64(total + offset) else {
            throw ProbeFailure.message("Queue final FIFO differs")
        }
    }
    let contention = queue.contentionSnapshot
    try require(queue.count == 0 && contention.producerWaits == 0 && contention.waitingProducers == 0,
                "Uncontended queue control unexpectedly waited or retained elements")
    queue.close()
    return Measurement(checksum: checksum, expectedChecksum: expected, finalCount: finalCount,
                       wallNanoseconds: elapsed.wall, cpuNanoseconds: elapsed.cpu)
}

private func run(_ workload: Workload, iterations: Int, timed: Bool) throws -> Measurement {
    try require(iterations > 0 && iterations <= 1_000_000, "Iterations must be in 1...1000000")
    try require(iterations * workload.logicalElementsPerIteration <= 1_000_000_000,
                "Workload exceeds the one-billion-element bound")
    let result: Measurement
    switch workload.kind {
    case .append:
        result = try runAppend(capacity: workload.capacity, depth: workload.depth,
                               iterations: iterations, timed: timed)
    case .prepend:
        result = try runPrepend(capacity: workload.capacity, iterations: iterations, timed: timed)
    case .drain:
        result = try runDrain(capacity: workload.capacity, iterations: iterations, timed: timed)
    case .clear:
        result = try runClear(capacity: workload.capacity, iterations: iterations, timed: timed)
    case .reference:
        result = try runReference(capacity: workload.capacity, depth: workload.depth,
                                  iterations: iterations, timed: timed)
    case .queue:
        result = try runQueue(capacity: workload.capacity, depth: workload.depth,
                              iterations: iterations, timed: timed)
    }
    try require(result.checksum == result.expectedChecksum,
                "\(workload.name) checksum \(result.checksum) != \(result.expectedChecksum)")
    return result
}

private struct Generator {
    var value: UInt64
    mutating func next() -> UInt64 {
        value = value &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return value
    }
}

private func contents(_ source: FixedRingBuffer<Int>) -> [Int] {
    var copy = source
    var result: [Int] = []
    while !copy.isEmpty { result.append(copy.removeFirst()) }
    return result
}

private func verifyCorpus() throws -> [[String: Any]] {
    let capacities = [1, 2, 3, 5, 7, 12, 48, 64, 95, 96, 97, 191, 192, 193, 256]
    var receipts: [[String: Any]] = []
    for capacity in capacities {
        var ring = FixedRingBuffer<Int>(capacity: capacity)
        var expected: [Int] = []
        var generator = Generator(value: UInt64(capacity) &* 0x9e3779b97f4a7c15)
        var removed: [Int] = []
        var snapshots: [[String: Any]] = []
        var wrapElements = 0

        // Every possible head offset, filled to capacity with mixed endpoint
        // insertions. The oracle is Array; it does not reuse wrap arithmetic.
        for headOffset in 0..<capacity {
            var wrapping = FixedRingBuffer<Int>(capacity: capacity)
            for _ in 0..<headOffset { wrapping.append(-1); _ = wrapping.removeFirst() }
            var reference: [Int] = []
            for value in 0..<capacity {
                if value % 2 == 0 {
                    wrapping.append(value)
                    reference.append(value)
                } else {
                    wrapping.prepend(value)
                    reference.insert(value, at: 0)
                }
            }
            try require(contents(wrapping) == reference,
                        "Wrap oracle mismatch: capacity \(capacity), offset \(headOffset)")
            for value in reference {
                try require(wrapping.removeFirst() == value, "Wrap drain mismatch")
                wrapElements += 1
            }
            try require(wrapping.isEmpty && wrapping.count == 0, "Wrap drain count mismatch")
        }

        let steps = 2048
        for step in 0..<steps {
            let operation = Int(generator.next() % 100)
            let value = Int(generator.next() % 2_000_001) - 1_000_000
            if expected.isEmpty || (operation < 38 && expected.count < capacity) {
                ring.append(value)
                expected.append(value)
            } else if operation < 65 && expected.count < capacity {
                ring.prepend(value)
                expected.insert(value, at: 0)
            } else if operation < 93 {
                let actual = ring.removeFirst()
                let reference = expected.removeFirst()
                try require(actual == reference, "Mixed oracle mismatch: capacity \(capacity), step \(step)")
                removed.append(actual)
            } else {
                ring.removeAll(keepingCapacity: step % 2 == 0)
                expected.removeAll()
            }
            try require(ring.count == expected.count && ring.isEmpty == expected.isEmpty,
                        "Mixed count mismatch: capacity \(capacity), step \(step)")
            if step % 127 == 0 {
                let actual = contents(ring)
                try require(actual == expected, "Mixed snapshot mismatch")
                snapshots.append(["step": step, "values": actual])

                // A copied ring must retain value semantics when either copy is
                // mutated. Check full contents again after mutating the copy.
                var copied = ring
                var copiedExpected = expected
                if copiedExpected.count < capacity {
                    copied.prepend(2_000_001)
                    copiedExpected.insert(2_000_001, at: 0)
                } else {
                    try require(copied.removeFirst() == copiedExpected.removeFirst(), "Copy pop mismatch")
                }
                try require(contents(copied) == copiedExpected && contents(ring) == expected,
                            "Copy-on-write isolation failed")
            }
        }
        let finalValues = contents(ring)
        try require(finalValues == expected, "Final mixed oracle mismatch")
        receipts.append([
            "capacity": capacity,
            "steps": steps,
            "wrap_offsets_checked": capacity,
            "wrap_elements_checked": wrapElements,
            "removed": removed,
            "snapshots": snapshots,
            "final_values": finalValues,
        ])
    }
    return receipts
}

@main
private struct RingBufferWrapDriver {
    static func main() {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            switch arguments.first {
            case "list":
                try require(arguments.count == 1, "Usage: list")
                try emit(Workload.names)
            case "verify":
                try require(arguments.count == 1, "Usage: verify")
                let corpus = try verifyCorpus()
                let cases = try Workload.names.map { name -> [String: Any] in
                    let workload = try Workload(name)
                    return try run(workload, iterations: 3, timed: false)
                        .receipt(workload, iterations: 3, timed: false)
                }
                try emit(["schema": 1, "corpus": corpus, "cases": cases])
            case "measure":
                try require(arguments.count == 3, "Usage: measure WORKLOAD ITERATIONS")
                guard let iterations = Int(arguments[2]) else {
                    throw ProbeFailure.message("Iterations must be an integer")
                }
                let workload = try Workload(arguments[1])
                // Separate warmup ownership: each measured ring/queue begins in
                // its documented initial state. Initialization is outside timing.
                _ = try run(workload, iterations: 2, timed: false)
                let result = try run(workload, iterations: iterations, timed: true)
                try emit(result.receipt(workload, iterations: iterations, timed: true))
            default:
                throw ProbeFailure.message("Usage: list | verify | measure WORKLOAD ITERATIONS")
            }
        } catch {
            FileHandle.standardError.write(Data(("RingBufferWrap: \(error)\n").utf8))
            exit(1)
        }
    }
}
