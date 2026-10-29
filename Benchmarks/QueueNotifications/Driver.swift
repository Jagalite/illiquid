import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// Allocation is excluded: both variants transfer the same preallocated reference
// payloads through the complete production queue, including locks and budgets.
private final class Payload: Sendable {
    let id: Int
    let cost: BoundedQueueCost

    init(_ id: Int) {
        self.id = id
        cost = .init(bytes: 4_096 + id % 5, durationMicroseconds: Int64(10_000 + id % 11))
    }
}

private enum Method: String {
    case push
    case tryPush = "try-push"
    case prepend
}

private enum CostMode: String {
    case zero
    case packet
}

private struct ProducerReport: Sendable {
    let sent: Int
    let checksum: UInt64
}

private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: ProducerReport?

    func set(_ report: ProducerReport) {
        lock.lock()
        defer { lock.unlock() }
        value = report
    }

    func get() -> ProducerReport? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private func makeQueue(capacity: Int, costs: CostMode) -> BoundedQueue<Payload> {
    switch costs {
    case .zero:
        return BoundedQueue(capacity: capacity)
    case .packet:
        return BoundedQueue(
            capacity: capacity,
            byteCapacity: capacity * 8_192,
            durationCapacityMicroseconds: Int64(capacity * 20_000),
            cost: { $0.cost }
        )
    }
}

@inline(__always)
private func cycles(
    queue: BoundedQueue<Payload>,
    payloads: [Payload],
    iterations: Int,
    reversed: Bool,
    enqueue: (Payload) -> Void
) -> UInt64 {
    var checksum: UInt64 = 0
    for _ in 0..<iterations {
        for payload in payloads { enqueue(payload) }
        for index in payloads.indices {
            guard case .value(let payload) = queue.pop() else {
                preconditionFailure("Queue closed during buffered transfer")
            }
            // Check the actual FIFO/prepend sequence on every cycle. The receipt
            // and budget checks also make every measured result observable.
            let expectedID = reversed ? payloads.count - index : index + 1
            precondition(payload.id == expectedID)
            checksum &+= UInt64(payload.id)
        }
    }
    return checksum
}

@inline(never)
private func transferBuffered(
    queue: BoundedQueue<Payload>,
    payloads: [Payload],
    iterations: Int,
    method: Method
) -> UInt64 {
    switch method {
    case .push:
        return cycles(queue: queue, payloads: payloads, iterations: iterations, reversed: false) {
            precondition(queue.push($0))
        }
    case .tryPush:
        return cycles(queue: queue, payloads: payloads, iterations: iterations, reversed: false) {
            precondition(queue.tryPush($0) == .pushed)
        }
    case .prepend:
        return cycles(queue: queue, payloads: payloads, iterations: iterations, reversed: true) {
            precondition(queue.pushFirst($0))
        }
    }
}

private struct Observation: Encodable {
    let mode: String
    let method: String
    let costs: String
    let capacity: Int
    let depth: Int
    let iterations: Int
    let warmupTransfers: Int
    let transfers: Int
    let queueOperations: Int
    let elapsedNanoseconds: UInt64
    let processCPUSeconds: Double
    let checksum: String
    let producerWaits: Int
    let producerWaitSeconds: Double
    let peakWaitingProducers: Int
}

private func verifyEmpty(_ queue: BoundedQueue<Payload>) {
    precondition(queue.budgetSnapshot == .init(items: 0, bytes: 0, durationMicroseconds: 0))
    precondition(queue.contentionSnapshot.waitingProducers == 0)
}

private func buffered(
    method: Method,
    costs: CostMode,
    capacity: Int,
    depth: Int,
    iterations: Int
) -> Observation {
    let queue = makeQueue(capacity: capacity, costs: costs)
    let payloads = (1...depth).map(Payload.init)
    let warmup = min(iterations, max(256, 10_000 / depth))
    _ = transferBuffered(queue: queue, payloads: payloads, iterations: warmup, method: method)
    verifyEmpty(queue)

    let cpuStart = clock()
    let start = DispatchTime.now().uptimeNanoseconds
    let checksum = transferBuffered(queue: queue, payloads: payloads, iterations: iterations, method: method)
    let elapsed = DispatchTime.now().uptimeNanoseconds - start
    let cpuEnd = clock()

    let expected = UInt64(iterations) * UInt64(depth * (depth + 1) / 2)
    precondition(checksum == expected)
    verifyEmpty(queue)
    let contention = queue.contentionSnapshot
    precondition(contention.producerWaits == 0)
    queue.close()
    return Observation(
        mode: "buffered", method: method.rawValue, costs: costs.rawValue,
        capacity: capacity, depth: depth, iterations: iterations,
        warmupTransfers: warmup * depth, transfers: iterations * depth,
        queueOperations: iterations * depth * 2, elapsedNanoseconds: elapsed,
        processCPUSeconds: Double(cpuEnd - cpuStart) / Double(CLOCKS_PER_SEC),
        checksum: String(checksum, radix: 16),
        producerWaits: contention.producerWaits,
        producerWaitSeconds: contention.producerWaitSeconds,
        peakWaitingProducers: contention.peakWaitingProducers
    )
}

private func threaded(
    costs: CostMode,
    capacity: Int,
    iterations: Int,
    warmupTransfers: Int
) -> Observation {
    let queue = makeQueue(capacity: capacity, costs: costs)
    let payloads = (1...4_096).map(Payload.init)
    let ready = DispatchSemaphore(value: 0)
    let startSignal = DispatchSemaphore(value: 0)
    let done = DispatchSemaphore(value: 0)
    let report = ResultBox()
    Thread.detachNewThread {
        ready.signal()
        startSignal.wait()
        var checksum: UInt64 = 0
        for index in 0..<iterations {
            let payload = payloads[index % payloads.count]
            precondition(queue.push(payload))
            checksum &+= UInt64(payload.id)
        }
        report.set(ProducerReport(sent: iterations, checksum: checksum))
        done.signal()
    }
    precondition(ready.wait(timeout: .now() + 5) == .success)
    let cpuStart = clock()
    let start = DispatchTime.now().uptimeNanoseconds
    startSignal.signal()
    var checksum: UInt64 = 0
    for index in 0..<iterations {
        guard case .value(let payload) = queue.pop() else {
            preconditionFailure("Queue closed during threaded transfer")
        }
        precondition(payload.id == index % payloads.count + 1)
        checksum &+= UInt64(payload.id)
    }
    // Include producer completion and every capacity/consumer wait. Thread and
    // queue construction occurred before the synchronized start.
    precondition(done.wait(timeout: .now() + 10) == .success)
    let elapsed = DispatchTime.now().uptimeNanoseconds - start
    let cpuEnd = clock()
    let sent = report.get()
    precondition(sent?.sent == iterations && sent?.checksum == checksum)
    let fullCycles = iterations / payloads.count
    let remainder = iterations % payloads.count
    let expected = UInt64(fullCycles) * UInt64(payloads.count * (payloads.count + 1) / 2)
        + UInt64(remainder * (remainder + 1) / 2)
    precondition(checksum == expected)
    verifyEmpty(queue)
    let contention = queue.contentionSnapshot
    queue.close()
    return Observation(
        mode: "threaded", method: Method.push.rawValue, costs: costs.rawValue,
        capacity: capacity, depth: 1, iterations: iterations,
        warmupTransfers: warmupTransfers, transfers: iterations,
        queueOperations: iterations * 2, elapsedNanoseconds: elapsed,
        processCPUSeconds: Double(cpuEnd - cpuStart) / Double(CLOCKS_PER_SEC),
        checksum: String(checksum, radix: 16),
        producerWaits: contention.producerWaits,
        producerWaitSeconds: contention.producerWaitSeconds,
        peakWaitingProducers: contention.peakWaitingProducers
    )
}

@main
private struct Driver {
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count == 7,
              ["buffered", "threaded"].contains(args[1]),
              let method = Method(rawValue: args[2]),
              let costs = CostMode(rawValue: args[3]),
              let capacity = Int(args[4]), (1...192).contains(capacity),
              let depth = Int(args[5]), (1...capacity).contains(depth),
              let iterations = Int(args[6]), (1...4_000_000).contains(iterations) else {
            preconditionFailure("usage: driver MODE METHOD COSTS CAPACITY DEPTH ITERATIONS")
        }
        let observation: Observation
        if args[1] == "threaded" {
            precondition(method == .push && depth == 1)
            let warmup = min(iterations, 2_000)
            _ = threaded(costs: costs, capacity: capacity, iterations: warmup, warmupTransfers: 0)
            observation = threaded(
                costs: costs, capacity: capacity, iterations: iterations, warmupTransfers: warmup
            )
        } else {
            observation = buffered(
                method: method, costs: costs, capacity: capacity, depth: depth, iterations: iterations
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        print(String(decoding: try encoder.encode(observation), as: UTF8.self))
    }
}
