import Foundation
import Dispatch
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

private struct Value {
    let id: Int
    var cost: BoundedQueueCost {
        .init(bytes: 1_024 + (id & 127), durationMicroseconds: 1_000)
    }
}

private final class Payload: @unchecked Sendable {
    let id: Int
    let cost: BoundedQueueCost
    init(_ id: Int) {
        self.id = id
        cost = .init(bytes: 1_024 + (id & 127), durationMicroseconds: 1_000)
    }
}

private struct Sample: Codable {
    let wallNanoseconds: UInt64
    let cpuNanoseconds: UInt64
    let fingerprint: String
    let remainingFingerprint: String
    let remainingCount: Int
}

private struct Receipt: Codable {
    let workload: String
    let capacity: Int
    let iterations: Int
    let warmupIterations: Int
    let warmup: Sample
    let measurement: Sample
}

private func cpuNanoseconds() -> UInt64 {
    var value = timespec()
    precondition(clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &value) == 0)
    return UInt64(value.tv_sec) * 1_000_000_000 + UInt64(value.tv_nsec)
}

@inline(__always)
private func fold(_ hash: UInt64, _ value: Int) -> UInt64 {
    (hash &* 1_099_511_628_211) ^ UInt64(value)
}

@inline(never)
private func queueValues(_ workload: String, _ capacity: Int, _ iterations: Int) -> Sample {
    let occupancy = workload == "queue-value-full" ? capacity : max(1, capacity / 2)
    let mixed = workload == "queue-mixed"
    let nonblocking = workload == "queue-try"
    let queue = BoundedQueue<Value>(capacity: capacity, cost: { $0.cost })
    for id in 0..<occupancy { precondition(queue.push(Value(id: id))) }
    var hash: UInt64 = 14_695_981_039_346_656_037
    let cpuStart = cpuNanoseconds()
    let wallStart = DispatchTime.now().uptimeNanoseconds
    for index in 0..<iterations {
        guard case let .value(value) = queue.pop() else { preconditionFailure("closed queue") }
        hash = fold(hash, value.id)
        let next = Value(id: occupancy + index)
        if mixed && (index & 7) == 0 {
            precondition(queue.pushFirst(next))
        } else if nonblocking {
            precondition(queue.tryPush(next) == .pushed)
        } else {
            precondition(queue.push(next))
        }
    }
    let wallElapsed = DispatchTime.now().uptimeNanoseconds - wallStart
    let cpuElapsed = cpuNanoseconds() - cpuStart
    precondition(queue.count == occupancy)
    var remaining: UInt64 = 14_695_981_039_346_656_037
    for _ in 0..<occupancy {
        guard case let .value(value) = queue.pop() else { preconditionFailure("missing value") }
        remaining = fold(remaining, value.id)
    }
    precondition(queue.budgetSnapshot == .init(items: 0, bytes: 0, durationMicroseconds: 0))
    queue.close()
    return Sample(wallNanoseconds: wallElapsed, cpuNanoseconds: cpuElapsed,
                  fingerprint: String(hash), remainingFingerprint: String(remaining),
                  remainingCount: occupancy)
}

@inline(never)
private func queueReferences(_ workload: String, _ capacity: Int, _ iterations: Int) -> Sample {
    let occupancy = workload == "queue-reference-full" ? capacity : max(1, capacity / 2)
    // FFmpeg owns payload creation upstream. Preallocate and retain this pool
    // outside timing so this fixture isolates queue transport and ARC.
    let pool = (0..<occupancy).map(Payload.init)
    let queue = BoundedQueue<Payload>(capacity: capacity, cost: { $0.cost })
    for value in pool { precondition(queue.push(value)) }
    var hash: UInt64 = 14_695_981_039_346_656_037
    let cpuStart = cpuNanoseconds()
    let wallStart = DispatchTime.now().uptimeNanoseconds
    for _ in 0..<iterations {
        guard case let .value(value) = queue.pop() else { preconditionFailure("closed queue") }
        hash = fold(hash, value.id)
        precondition(queue.push(value))
    }
    let wallElapsed = DispatchTime.now().uptimeNanoseconds - wallStart
    let cpuElapsed = cpuNanoseconds() - cpuStart
    precondition(queue.count == occupancy)
    var remaining: UInt64 = 14_695_981_039_346_656_037
    for _ in 0..<occupancy {
        guard case let .value(value) = queue.pop() else { preconditionFailure("missing reference") }
        remaining = fold(remaining, value.id)
    }
    precondition(queue.budgetSnapshot == .init(items: 0, bytes: 0, durationMicroseconds: 0))
    queue.close()
    withExtendedLifetime(pool) {}
    return Sample(wallNanoseconds: wallElapsed, cpuNanoseconds: cpuElapsed,
                  fingerprint: String(hash), remainingFingerprint: String(remaining),
                  remainingCount: occupancy)
}

@inline(never)
private func bareRing(_ workload: String, _ capacity: Int, _ iterations: Int) -> Sample {
    let occupancy = max(1, capacity / 2)
    let mixed = workload == "ring-mixed"
    var ring = FixedRingBuffer<Int>(capacity: capacity)
    for id in 0..<occupancy { ring.append(id) }
    var hash: UInt64 = 14_695_981_039_346_656_037
    let cpuStart = cpuNanoseconds()
    let wallStart = DispatchTime.now().uptimeNanoseconds
    for index in 0..<iterations {
        hash = fold(hash, ring.removeFirst())
        if mixed && (index & 7) == 0 {
            ring.prepend(occupancy + index)
        } else {
            ring.append(occupancy + index)
        }
    }
    let wallElapsed = DispatchTime.now().uptimeNanoseconds - wallStart
    let cpuElapsed = cpuNanoseconds() - cpuStart
    precondition(ring.count == occupancy)
    var remaining: UInt64 = 14_695_981_039_346_656_037
    while !ring.isEmpty { remaining = fold(remaining, ring.removeFirst()) }
    return Sample(wallNanoseconds: wallElapsed, cpuNanoseconds: cpuElapsed,
                  fingerprint: String(hash), remainingFingerprint: String(remaining),
                  remainingCount: occupancy)
}

@inline(never)
private func countControl(_ capacity: Int, _ iterations: Int) -> Sample {
    let occupancy = max(1, capacity / 2)
    let queue = BoundedQueue<Int>(capacity: capacity)
    for id in 0..<occupancy { precondition(queue.push(id)) }
    var hash: UInt64 = 14_695_981_039_346_656_037
    let cpuStart = cpuNanoseconds()
    let wallStart = DispatchTime.now().uptimeNanoseconds
    for index in 0..<iterations { hash = fold(hash, queue.count + index) }
    let wallElapsed = DispatchTime.now().uptimeNanoseconds - wallStart
    let cpuElapsed = cpuNanoseconds() - cpuStart
    queue.close()
    return Sample(wallNanoseconds: wallElapsed, cpuNanoseconds: cpuElapsed,
                  fingerprint: String(hash), remainingFingerprint: "not-drained",
                  remainingCount: occupancy)
}

private func run(_ workload: String, _ capacity: Int, _ iterations: Int) -> Sample {
    switch workload {
    case "queue-value-half", "queue-value-full", "queue-mixed", "queue-try":
        return queueValues(workload, capacity, iterations)
    case "queue-reference-half", "queue-reference-full":
        return queueReferences(workload, capacity, iterations)
    case "ring", "ring-mixed":
        return bareRing(workload, capacity, iterations)
    case "queue-count-control":
        return countControl(capacity, iterations)
    default:
        preconditionFailure("Unknown workload: \(workload)")
    }
}

@main
private struct Main {
    static func main() throws {
        precondition(CommandLine.arguments.count == 4, "usage: benchmark workload capacity iterations")
        let workload = CommandLine.arguments[1]
        guard let capacity = Int(CommandLine.arguments[2]), capacity > 0,
              let iterations = Int(CommandLine.arguments[3]), iterations > 0
        else { preconditionFailure("positive runtime capacity and iterations required") }
        let warmupIterations = 16_384
        let warmup = run(workload, capacity, warmupIterations)
        let measurement = run(workload, capacity, iterations)
        let receipt = Receipt(workload: workload, capacity: capacity, iterations: iterations,
                              warmupIterations: warmupIterations, warmup: warmup,
                              measurement: measurement)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        print(String(decoding: try encoder.encode(receipt), as: UTF8.self))
    }
}
