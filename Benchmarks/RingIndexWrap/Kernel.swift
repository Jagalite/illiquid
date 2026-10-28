import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// This identical harness is compiled beside the two complete production files
// in both arms. Concrete Int/reference uses allow ordinary WMO specialization.
private protocol BenchmarkValue: Sendable { var code: Int { get } }
extension Int: BenchmarkValue { fileprivate var code: Int { self } }
private final class ReferenceValue: BenchmarkValue {
    let code: Int
    init(_ code: Int) { self.code = code }
}

private let batchSize = 256

private func cost(_ code: Int) -> BoundedQueueCost {
    BoundedQueueCost(bytes: 1 + (code & 127), durationMicroseconds: Int64(1 + (code & 63)))
}

private func cpuNanoseconds() -> UInt64 {
    var value = timespec()
    precondition(clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &value) == 0)
    return UInt64(value.tv_sec) * 1_000_000_000 + UInt64(value.tv_nsec)
}

private struct Budget: Codable, Equatable {
    let items: Int
    let bytes: Int
    let durationMicroseconds: Int64

    init(_ snapshot: BoundedQueueBudgetSnapshot) {
        items = snapshot.items; bytes = snapshot.bytes
        durationMicroseconds = snapshot.durationMicroseconds
    }

    init(codes: [Int]) {
        items = codes.count
        bytes = codes.reduce(0) { $0 + cost($1).bytes }
        durationMicroseconds = codes.reduce(0) { $0 + cost($1).durationMicroseconds }
    }
}

private func makeQueue<Value: BenchmarkValue>(capacity: Int) -> BoundedQueue<Value> {
    BoundedQueue(capacity: capacity, byteCapacity: capacity * 128,
                 durationCapacityMicroseconds: Int64(capacity * 64), cost: { cost($0.code) })
}

// Keep clock reads outside these opaque kernels, while allowing specialization
// of the actual generic production methods within the same library module.
@inline(never)
private func ringTransfers<Value: BenchmarkValue>(
    _ ring: inout FixedRingBuffer<Value>, pool: [Value], prepend: Bool, iterations: Int
) -> UInt64 {
    var checksum: UInt64 = 0
    if prepend {
        for _ in 0..<iterations {
            for value in pool {
                ring.prepend(value)
                checksum &+= UInt64(ring.removeFirst().code)
            }
        }
    } else {
        for _ in 0..<iterations {
            for value in pool {
                ring.append(value)
                checksum &+= UInt64(ring.removeFirst().code)
            }
        }
    }
    return checksum
}

@inline(never)
private func queueTransfers<Value: BenchmarkValue>(
    _ queue: BoundedQueue<Value>, pool: [Value], prepend: Bool, iterations: Int
) -> UInt64 {
    var checksum: UInt64 = 0
    if prepend {
        for _ in 0..<iterations {
            for value in pool {
                precondition(queue.pushFirst(value))
                guard case let .value(result) = queue.pop() else { preconditionFailure("Closed queue") }
                checksum &+= UInt64(result.code)
            }
        }
    } else {
        for _ in 0..<iterations {
            for value in pool {
                precondition(queue.push(value))
                guard case let .value(result) = queue.pop() else { preconditionFailure("Closed queue") }
                checksum &+= UInt64(result.code)
            }
        }
    }
    return checksum
}

private struct Measurement: Encodable {
    let kind: String
    let operation: String
    let payload: String
    let capacity: Int
    let occupancy: Int
    let iterations: Int
    let transfers: Int
    let wallNanoseconds: UInt64
    let cpuNanoseconds: UInt64
    let checksum: UInt64
    let remaining: [Int]
    let budget: Budget?
}

private func expectedResult(codes: [Int], occupancy: Int, prepend: Bool, iterations: Int)
    -> (checksum: UInt64, remaining: [Int]) {
    let transfers = iterations * batchSize
    func sum(_ values: ArraySlice<Int>) -> UInt64 { values.reduce(0) { $0 &+ UInt64($1) } }
    let cycleSum = sum(codes[...])
    if prepend {
        return (cycleSum &* UInt64(iterations), Array(codes.prefix(occupancy)))
    }
    // FIFO output is the initial occupancy followed by the input stream;
    // the last occupancy inputs remain queued. This oracle never calls a ring.
    let inputPops = transfers - occupancy
    let checksum = sum(codes.prefix(occupancy))
        &+ cycleSum &* UInt64(inputPops / batchSize)
        &+ sum(codes.prefix(inputPops % batchSize))
    let remaining = (0..<occupancy).map { codes[(transfers - occupancy + $0) % batchSize] }
    return (checksum, remaining)
}

private func measure<Value: BenchmarkValue>(
    pool: [Value], kind: String, prepend: Bool, payload: String, capacity: Int, iterations: Int
) -> Measurement {
    let occupancy = capacity - 1
    let expected = expectedResult(codes: pool.map(\.code), occupancy: occupancy,
                                  prepend: prepend, iterations: iterations)
    var ring = FixedRingBuffer<Value>(capacity: capacity)
    let queue: BoundedQueue<Value> = makeQueue(capacity: capacity)
    for value in pool.prefix(occupancy) {
        if kind == "ring" { ring.append(value) } else { precondition(queue.push(value)) }
    }
    let checksum: UInt64
    let cpuStart = cpuNanoseconds()
    let wallStart = DispatchTime.now().uptimeNanoseconds
    if kind == "ring" {
        checksum = ringTransfers(&ring, pool: pool, prepend: prepend, iterations: iterations)
    } else {
        checksum = queueTransfers(queue, pool: pool, prepend: prepend, iterations: iterations)
    }
    let wall = DispatchTime.now().uptimeNanoseconds - wallStart
    let cpu = cpuNanoseconds() - cpuStart
    let budget = kind == "queue" ? Budget(queue.budgetSnapshot) : nil
    precondition((kind == "ring" ? ring.count : queue.count) == occupancy)
    var remaining: [Int] = []
    for _ in 0..<occupancy {
        if kind == "ring" { remaining.append(ring.removeFirst().code) }
        else {
            guard case let .value(value) = queue.pop() else { preconditionFailure("Closed queue") }
            remaining.append(value.code)
        }
    }
    precondition(checksum == expected.checksum && remaining == expected.remaining,
                 "Timed FIFO output differs from the independent model")
    if let budget { precondition(budget == Budget(codes: expected.remaining)) }
    precondition(queue.contentionSnapshot.producerWaits == 0)
    queue.close()
    return Measurement(kind: kind, operation: prepend ? "prepend" : "append", payload: payload,
        capacity: capacity, occupancy: occupancy, iterations: iterations,
        transfers: iterations * batchSize, wallNanoseconds: wall, cpuNanoseconds: cpu,
        checksum: checksum, remaining: remaining, budget: budget)
}

private struct Verification: Encodable {
    let kind: String
    let operation: String
    let payload: String
    let capacity: Int
    let popped: [Int]
    let remaining: [Int]
    let budgets: [Budget]
}

private func verify<Value: BenchmarkValue>(
    pool: [Value], kind: String, prepend: Bool, payload: String, capacity: Int
) -> Verification {
    var ring = FixedRingBuffer<Value>(capacity: capacity)
    let queue: BoundedQueue<Value> = makeQueue(capacity: capacity)
    var model = Array(pool.prefix(capacity - 1)).map(\.code)
    for value in pool.prefix(capacity - 1) {
        if kind == "ring" { ring.append(value) } else { precondition(queue.push(value)) }
    }
    var popped: [Int] = [], budgets: [Budget] = []
    for step in 0..<(capacity * 5 + 257) {
        let value = pool[step % pool.count]
        if prepend { model.insert(value.code, at: 0) } else { model.append(value.code) }
        let actual: Int
        if kind == "ring" {
            if prepend { ring.prepend(value) } else { ring.append(value) }
            actual = ring.removeFirst().code
            precondition(ring.count == model.count - 1)
        } else {
            precondition(prepend ? queue.pushFirst(value) : queue.push(value))
            guard case let .value(output) = queue.pop() else { preconditionFailure("Closed queue") }
            actual = output.code
        }
        precondition(actual == model.removeFirst(), "Array-model parity failed")
        popped.append(actual)
        if kind == "queue" {
            let actualBudget = Budget(queue.budgetSnapshot)
            precondition(actualBudget == Budget(codes: model))
            budgets.append(actualBudget)
        }
    }
    var remaining: [Int] = []
    for _ in model.indices {
        if kind == "ring" { remaining.append(ring.removeFirst().code) }
        else {
            guard case let .value(value) = queue.pop() else { preconditionFailure("Closed queue") }
            remaining.append(value.code)
        }
    }
    precondition(remaining == model)
    precondition(queue.budgetSnapshot == .init(items: 0, bytes: 0, durationMicroseconds: 0))
    queue.close()
    return Verification(kind: kind, operation: prepend ? "prepend" : "append", payload: payload,
                        capacity: capacity, popped: popped, remaining: remaining, budgets: budgets)
}

public enum RingIndexBenchmark {
    public static func run(mode: String, kind: String, operation: String, payload: String,
                           capacity: Int, iterations: Int) throws -> Data {
        precondition(["verify", "measure"].contains(mode))
        precondition(["ring", "queue"].contains(kind))
        precondition(["append", "prepend"].contains(operation))
        precondition(["int", "reference"].contains(payload))
        precondition([3, 48, 64, 96, 97, 192].contains(capacity))
        precondition((1...2_000_000).contains(iterations))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        func execute<Value: BenchmarkValue>(_ pool: [Value]) throws -> Data {
            if mode == "verify" {
                return try encoder.encode(verify(pool: pool, kind: kind, prepend: operation == "prepend",
                    payload: payload, capacity: capacity))
            }
            // Excluded warmup, including checks and deallocation, before creating
            // the fresh prefilled ring/queue used by the timed measurement.
            _ = measure(pool: pool, kind: kind, prepend: operation == "prepend",
                        payload: payload, capacity: capacity, iterations: 8)
            return try encoder.encode(measure(pool: pool, kind: kind, prepend: operation == "prepend",
                payload: payload, capacity: capacity, iterations: iterations))
        }
        let codes = Array(1...batchSize)
        if payload == "int" { return try execute(codes) }
        return try execute(codes.map(ReferenceValue.init))
    }
}
