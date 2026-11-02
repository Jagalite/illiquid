import Dispatch
import Foundation
import FrameHistoryBenchmark
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

private let operations = ["append", "append-lookup", "lookup-newest", "lookup-oldest",
    "lookup-miss", "adjacent-forward", "adjacent-backward",
    "flush-0", "flush-1", "flush-64", "flush-128", "flush-256"]

private func cpuTime() -> UInt64 {
    var value = timespec()
    precondition(clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &value) == 0)
    return UInt64(value.tv_sec) * 1_000_000_000 + UInt64(value.tv_nsec)
}

@inline(never)
private func execute(_ operation: String, worker: HistoryWorker, iterations: Int, initialCount: Int) -> UInt64 {
    var checksum: UInt64 = 0
    switch operation {
    case "append":
        for index in 0..<iterations { checksum &+= worker.append(initialCount + index) }
    case "append-lookup":
        for index in 0..<iterations {
            _ = worker.append(initialCount + index)
            checksum &+= worker.lookup(initialCount + index)
        }
    case "lookup-newest", "lookup-oldest", "lookup-miss":
        let token = initialCount - (operation == "lookup-newest" ? 1 : (operation == "lookup-oldest" ? 128 : 257))
        for _ in 0..<iterations { checksum &+= worker.lookup(token) }
    case "adjacent-forward", "adjacent-backward":
        let direction = operation == "adjacent-forward" ? 1 : -1
        for _ in 0..<iterations { checksum &+= worker.adjacent(initialCount - 64, direction: direction) }
    default:
        let refill = Int(operation.dropFirst(6))!
        for _ in 0..<iterations {
            worker.clear()
            for token in 0..<refill { checksum &+= worker.append(token) }
            checksum &+= UInt64(worker.count)
        }
    }
    return checksum
}

private func expectedChecksum(_ operation: String, iterations: Int, initialCount: Int) -> UInt64 {
    let n = UInt64(iterations)
    switch operation {
    case "append": return 128 &* n
    case "append-lookup": return n * (2 * UInt64(initialCount + 1_000) + n - 1) / 2
    case "lookup-newest": return UInt64(initialCount + 999) &* n
    case "lookup-oldest": return UInt64(initialCount + 872) &* n
    case "lookup-miss": return UInt64.max &* n
    case "adjacent-forward": return (Double(initialCount - 63) / 60).bitPattern &* n
    case "adjacent-backward": return (Double(initialCount - 65) / 60).bitPattern &* n
    default:
        let refill = Int(operation.dropFirst(6))!
        let growing = min(128, refill)
        let perIteration = growing * (growing + 1) / 2 + 128 * max(0, refill - 128) + growing
        return UInt64(perIteration) &* n
    }
}

private func validate(_ operation: String, worker: HistoryWorker, iterations: Int, initialCount: Int) -> String {
    let end: Int
    if operation == "append" || operation == "append-lookup" {
        end = initialCount + iterations
    } else if operation.hasPrefix("flush-") {
        end = Int(operation.dropFirst(6))!
    } else {
        end = initialCount
    }
    let first = max(0, end - 128)
    precondition(worker.count == end - first, "History count differs from independent model")
    var fingerprint: UInt64 = 14_695_981_039_346_656_037
    func mix(_ value: UInt64) {
        for shift in stride(from: 0, to: 64, by: 8) {
            fingerprint = (fingerprint ^ UInt64(UInt8(truncatingIfNeeded: value >> shift))) &* 1_099_511_628_211
        }
    }
    mix(UInt64(end - first))
    for token in first..<end {
        let expected = Record(surfaceID: UInt32(token + 1), bufferID: UInt(token + 1_000),
                              time: Double(token) / 60, generation: 7)
        precondition(worker.record(surfaceID: expected.surfaceID, bufferID: expected.bufferID) == expected)
        precondition(worker.record(surfaceID: nil, bufferID: expected.bufferID) == expected)
        mix(UInt64(expected.surfaceID!)); mix(UInt64(expected.bufferID))
        mix(expected.time.bitPattern); mix(UInt64(expected.generation))
    }
    // Include a recently evicted record, an unseen future record, and a surface
    // miss whose buffer ID would match. Surface lookup must not fall back.
    for token in [first - 1, end] where token >= 0 {
        precondition(worker.record(surfaceID: UInt32(token + 1), bufferID: UInt(token + 1_000)) == nil)
        precondition(worker.record(surfaceID: nil, bufferID: UInt(token + 1_000)) == nil)
    }
    if first < end {
        precondition(worker.record(surfaceID: UInt32.max, bufferID: UInt(first + 1_000)) == nil)
    }
    return String(fingerprint, radix: 16)
}

@main
private enum Driver {
    static func main() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        precondition(args.count == 4 && operations.contains(args[0]) && ["locked", "unlocked"].contains(args[1]),
                     "Usage: driver OPERATION locked|unlocked ITERATIONS INITIAL_COUNT")
        guard let iterations = Int(args[2]), iterations > 0, iterations <= 20_000_000,
              let initialCount = Int(args[3]), [384, 401].contains(initialCount) else {
            preconditionFailure("Iterations must be in 1...20000000; initial count must be 384 or 401")
        }
        let operation = args[0], locked = args[1] == "locked"
        // An independent worker warms the exact operation without consuming the
        // measured worker's sequence or carrying its state into the interval.
        let warm = HistoryWorker(includesLock: locked, initialCount: initialCount)
        let warmChecksum = execute(operation, worker: warm, iterations: 1_024, initialCount: initialCount)
        precondition(warmChecksum == expectedChecksum(operation, iterations: 1_024, initialCount: initialCount))
        _ = validate(operation, worker: warm, iterations: 1_024, initialCount: initialCount)
        let worker = HistoryWorker(includesLock: locked, initialCount: initialCount)
        _ = cpuTime()
        _ = DispatchTime.now().uptimeNanoseconds
        let cpuStart = cpuTime()
        let wallStart = DispatchTime.now().uptimeNanoseconds
        let checksum = execute(operation, worker: worker, iterations: iterations, initialCount: initialCount)
        let wall = DispatchTime.now().uptimeNanoseconds - wallStart
        let cpu = cpuTime() - cpuStart
        precondition(checksum == expectedChecksum(operation, iterations: iterations, initialCount: initialCount))
        let state = validate(operation, worker: worker, iterations: iterations, initialCount: initialCount)
        #if CANDIDATE
        let variant = "candidate"
        #else
        let variant = "baseline"
        #endif
        let result: [String: Any] = [
            "variant": variant, "operation": operation, "lock_mode": args[1],
            "iterations": iterations, "warmup_iterations": 1_024,
            "initial_count": initialCount, "initial_rotation": initialCount % 128,
            "wall_ns": wall, "cpu_ns": cpu, "checksum": checksum,
            "state_fingerprint": state, "state_count": worker.count,
            "identity_stride": HistoryWorker.identityStride, "oracle_passed": true,
        ]
        print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
        withExtendedLifetime((worker, warm)) {}
    }
}
