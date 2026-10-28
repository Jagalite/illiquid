import Foundation
import Dispatch
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
@testable import IlliquidNativePlayback

private typealias Frame = VideoFrameIdentityHistory.FrameIdentity

private enum DriverError: Error, CustomStringConvertible {
    case usage, mismatch(String), clock(Int32)
    var description: String {
        switch self {
        case .usage: return "Usage: driver CASE ITERATIONS SEED (positive iterations, UInt64 seed)"
        case let .mismatch(context): return "Frame history parity failed: \(context)"
        case let .clock(code): return "Process CPU clock failed: errno \(code)"
        }
    }
}

private enum Workload: String {
    case steadyAppend = "steady-append", appendLookup = "append-lookup"
    case coldFill = "cold-fill", flushRefill = "flush-refill"
    case newest = "lookup-newest", middle = "lookup-middle", oldest = "lookup-oldest"
    case missing = "lookup-missing", surfaceReuse = "lookup-surface-reuse"
    case forward = "adjacent-forward", backward = "adjacent-backward"
}

private struct Random {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9e3779b97f4a7c15
        var value = state
        value = (value ^ (value >> 30)) &* 0xbf58476d1ce4e5b9
        value = (value ^ (value >> 27)) &* 0x94d049bb133111eb
        return value ^ (value >> 31)
    }
}

private struct Query: Hashable, Encodable {
    let surfaceID: UInt32?
    let bufferID: UInt
}

private struct FrameReceipt: Encodable, Equatable {
    let surfaceID: UInt32?
    let bufferID: UInt
    let timeBits: UInt64
    let generation: Int
    init(_ frame: Frame) {
        surfaceID = frame.surfaceID; bufferID = frame.bufferID
        timeBits = frame.time.bitPattern; generation = frame.generation
    }
}

private struct StateReceipt: Encodable, Equatable {
    let identities: [FrameReceipt?]
    let adjacentTimeBits: [UInt64?]
}

private struct Receipt: Encodable {
    let unit: String
    let initialRotation: Int
    let identityQueries: [Query]
    let adjacentQueries: [FrameReceipt]
    let before: StateReceipt
    let after: StateReceipt
}

// Independent reference: the original array traversal and comparator semantics.
private func referenceIdentity(_ entries: [Frame], query: Query) -> Frame? {
    entries.last {
        if let surface = query.surfaceID { return $0.surfaceID == surface }
        return $0.bufferID == query.bufferID
    }
}

private func referenceAdjacent(_ entries: [Frame], frame: Frame, direction: Int) -> Double? {
    let times = entries.lazy.filter { $0.generation == frame.generation }.map(\.time)
    return direction > 0
        ? times.filter { $0 > frame.time + 0.000001 }.min()
        : times.filter { $0 < frame.time - 0.000001 }.max()
}

private func identityToken(_ frame: Frame?) -> UInt64 {
    guard let frame else { return 0x9e3779b97f4a7c15 }
    return (UInt64(frame.bufferID) &* 1_099_511_628_211)
        ^ frame.time.bitPattern ^ UInt64(bitPattern: Int64(frame.generation))
        ^ (UInt64(frame.surfaceID ?? 0) &* 0x100000001b3)
}

private func timeToken(_ time: Double?) -> UInt64 {
    time?.bitPattern ?? 0x9e3779b97f4a7c15
}

private func repeatedSum(_ values: [UInt64], iterations: Int) -> UInt64 {
    let cycle = values.reduce(0, &+)
    return (cycle &* UInt64(iterations / values.count))
        &+ values.prefix(iterations % values.count).reduce(0, &+)
}

private struct Fixture {
    let workload: Workload
    let initial: [Frame]
    let cycle: [Frame]
    let fill: [Frame]
    let queries: [Query]
    let adjacentQueries: [Frame]
    let probes: [Query]
    let direction: Int
    let rotation: Int

    init(workload: Workload, seed: UInt64) {
        self.workload = workload
        direction = workload == .backward ? -1 : 1
        var random = Random(state: seed)
        rotation = Int(random.next() % 128)
        let base = UInt(1_000 + random.next() % 1_000_000)
        let offset = Int(random.next() % 128)
        func makeFrame(_ index: Int, reused: Bool = false) -> Frame {
            let ordinal = (index * 37 + offset) % 128
            return Frame(
                surfaceID: index.isMultiple(of: 3) && !reused ? nil
                    : UInt32(reused ? 500 + index % 8 : 1_000 + index),
                bufferID: reused ? base + UInt(index % 4) : base + UInt(index),
                time: index == 0 ? -0.0 : index == 1 ? 0.0 : Double(ordinal) / 24 - 2,
                generation: index < 2 ? 99 : index % 3
            )
        }
        let populated = (0..<128).map { makeFrame($0, reused: workload == .surfaceReuse) }
        initial = workload == .coldFill || workload == .flushRefill ? [] : populated
        cycle = (128..<384).map { makeFrame($0) }
        fill = Array(populated.prefix(workload == .flushRefill ? 8 : 128))
        switch workload {
        case .newest: queries = [Query(surfaceID: nil, bufferID: populated[127].bufferID)]
        case .middle: queries = [Query(surfaceID: nil, bufferID: populated[64].bufferID)]
        case .oldest: queries = [Query(surfaceID: nil, bufferID: populated[0].bufferID)]
        case .missing: queries = [Query(surfaceID: nil, bufferID: UInt.max)]
        case .surfaceReuse:
            queries = (0..<8).map { Query(surfaceID: UInt32(500 + $0), bufferID: UInt.max) }
        default: queries = [Query(surfaceID: nil, bufferID: populated[0].bufferID)]
        }
        adjacentQueries = (0..<32).map { index in
            Frame(surfaceID: nil, bufferID: base,
                  time: index.isMultiple(of: 8) ? (index.isMultiple(of: 16) ? -1 : 1)
                      : Double((index * 13 + offset) % 128) / 24 - 2 + 0.01,
                  generation: index.isMultiple(of: 8) ? 99 : index % 3)
        } + [Frame(surfaceID: nil, bufferID: base, time: .nan, generation: 99),
             Frame(surfaceID: nil, bufferID: base, time: .infinity, generation: 0),
             Frame(surfaceID: nil, bufferID: base, time: -.infinity, generation: 1)]
        var seen = Set<Query>()
        var all: [Query] = []
        for frame in populated + cycle {
            let bufferQuery = Query(surfaceID: nil, bufferID: frame.bufferID)
            if seen.insert(bufferQuery).inserted { all.append(bufferQuery) }
            if let surface = frame.surfaceID {
                let surfaceQuery = Query(surfaceID: surface, bufferID: UInt.max)
                if seen.insert(surfaceQuery).inserted { all.append(surfaceQuery) }
            }
        }
        // A supplied but absent surface must not fall back to a present buffer.
        all.append(Query(surfaceID: UInt32.max, bufferID: populated[127].bufferID))
        all.append(Query(surfaceID: nil, bufferID: UInt.max))
        probes = all
    }

    func makeHistory() -> VideoFrameIdentityHistory {
        var history = VideoFrameIdentityHistory()
        // Exercise wrapped physical storage without changing logical contents.
        if !initial.isEmpty {
            for index in 0..<rotation { history.append(initial[index]) }
        }
        for frame in initial { history.append(frame) }
        return history
    }

    func expectedEntries(after iterations: Int) -> [Frame] {
        guard iterations > 0 else { return initial }
        switch workload {
        case .steadyAppend, .appendLookup:
            let appended = min(128, iterations)
            let start = (iterations - appended) % cycle.count
            return Array(initial.suffix(128 - appended))
                + (0..<appended).map { cycle[(start + $0) % cycle.count] }
        case .coldFill, .flushRefill: return fill
        default: return initial
        }
    }

    func expectedChecksum(iterations: Int) -> UInt64 {
        let tokens: [UInt64]
        switch workload {
        case .steadyAppend: tokens = cycle.map { UInt64($0.bufferID) }
        case .appendLookup: tokens = cycle.map { identityToken($0) }
        case .coldFill, .flushRefill:
            return fill.reduce(UInt64(0)) { $0 &+ UInt64($1.bufferID) } &* UInt64(iterations)
        case .forward, .backward:
            tokens = adjacentQueries.map { timeToken(referenceAdjacent(initial, frame: $0, direction: direction)) }
        default: tokens = queries.map { identityToken(referenceIdentity(initial, query: $0)) }
        }
        return repeatedSum(tokens, iterations: iterations)
    }

    func verify(_ history: VideoFrameIdentityHistory, iterations: Int, context: String) throws -> StateReceipt {
        let entries = expectedEntries(after: iterations)
        let actual = StateReceipt(
            identities: probes.map { history.identity(surfaceID: $0.surfaceID, bufferID: $0.bufferID).map(FrameReceipt.init) },
            adjacentTimeBits: adjacentQueries.flatMap { frame in
                [-1, 1].map { history.adjacentTime(to: frame, direction: $0)?.bitPattern }
            }
        )
        let expected = StateReceipt(
            identities: probes.map { referenceIdentity(entries, query: $0).map(FrameReceipt.init) },
            adjacentTimeBits: adjacentQueries.flatMap { frame in
                [-1, 1].map { referenceAdjacent(entries, frame: frame, direction: $0)?.bitPattern }
            }
        )
        guard actual == expected else { throw DriverError.mismatch(context) }
        return actual
    }
}

@inline(never)
private func exercise(_ history: inout VideoFrameIdentityHistory, fixture: Fixture, iterations: Int) -> UInt64 {
    var checksum: UInt64 = 0
    var index = 0
    switch fixture.workload {
    case .steadyAppend:
        for _ in 0..<iterations {
            let frame = fixture.cycle[index]
            history.append(frame)
            checksum &+= UInt64(frame.bufferID)
            index += 1
            if index == fixture.cycle.count { index = 0 }
        }
    case .appendLookup:
        for _ in 0..<iterations {
            let frame = fixture.cycle[index]
            history.append(frame)
            checksum &+= identityToken(history.identity(surfaceID: nil, bufferID: frame.bufferID))
            index += 1
            if index == fixture.cycle.count { index = 0 }
        }
    case .coldFill, .flushRefill:
        for _ in 0..<iterations {
            history.removeAll()
            for frame in fixture.fill {
                history.append(frame)
                checksum &+= UInt64(frame.bufferID)
            }
        }
    case .forward, .backward:
        for _ in 0..<iterations {
            checksum &+= timeToken(history.adjacentTime(to: fixture.adjacentQueries[index], direction: fixture.direction))
            index += 1
            if index == fixture.adjacentQueries.count { index = 0 }
        }
    default:
        for _ in 0..<iterations {
            let query = fixture.queries[index]
            checksum &+= identityToken(history.identity(surfaceID: query.surfaceID, bufferID: query.bufferID))
            index += 1
            if index == fixture.queries.count { index = 0 }
        }
    }
    return checksum
}

private func cpuNanoseconds() throws -> UInt64 {
    var time = timespec()
    guard clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &time) == 0 else { throw DriverError.clock(errno) }
    return UInt64(time.tv_sec) * 1_000_000_000 + UInt64(time.tv_nsec)
}

private struct Output: Encodable {
    let caseName: String
    let iterations: Int
    let seed: UInt64
    let operationsPerIteration = 1
    let elapsedNanoseconds: UInt64
    let cpuNanoseconds: UInt64
    let checksum: UInt64
    let warmupChecksum: UInt64
    let warmupIterations: Int
    let receipt: Receipt
    enum CodingKeys: String, CodingKey {
        case caseName = "case", iterations, seed, checksum, receipt
        case operationsPerIteration = "operations_per_iteration"
        case elapsedNanoseconds = "elapsed_ns", cpuNanoseconds = "cpu_ns"
        case warmupChecksum = "warmup_checksum", warmupIterations = "warmup_iterations"
    }
}

@main
private struct Driver {
    static func main() throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 4, let workload = Workload(rawValue: arguments[1]),
              let iterations = Int(arguments[2]), iterations > 0,
              let seed = UInt64(arguments[3]) else { throw DriverError.usage }
        let fixture = Fixture(workload: workload, seed: seed)
        let warmupIterations = 128
        var warm = fixture.makeHistory()
        _ = try fixture.verify(warm, iterations: 0, context: "warmup initial state")
        let warmupChecksum = exercise(&warm, fixture: fixture, iterations: warmupIterations)
        guard warmupChecksum == fixture.expectedChecksum(iterations: warmupIterations) else {
            throw DriverError.mismatch("warmup checksum")
        }
        _ = try fixture.verify(warm, iterations: warmupIterations, context: "warmup final state")

        var history = fixture.makeHistory()
        let before = try fixture.verify(history, iterations: 0, context: "timed initial state")
        let cpuStart = try cpuNanoseconds()
        let wallStart = DispatchTime.now().uptimeNanoseconds
        let checksum = exercise(&history, fixture: fixture, iterations: iterations)
        let wallElapsed = DispatchTime.now().uptimeNanoseconds - wallStart
        let cpuElapsed = try cpuNanoseconds() - cpuStart
        guard checksum == fixture.expectedChecksum(iterations: iterations) else {
            throw DriverError.mismatch("timed checksum")
        }
        let after = try fixture.verify(history, iterations: iterations, context: "timed final state")
        let output = Output(caseName: workload.rawValue, iterations: iterations, seed: seed,
                            elapsedNanoseconds: wallElapsed, cpuNanoseconds: cpuElapsed,
                            checksum: checksum, warmupChecksum: warmupChecksum,
                            warmupIterations: warmupIterations, receipt: Receipt(
                                unit: workload == .coldFill ? "clear plus 128 appends" :
                                    workload == .flushRefill ? "clear plus eight appends" :
                                    workload == .appendLookup ? "one append plus newest lookup" :
                                    workload == .steadyAppend ? "one append" : "one query",
                                initialRotation: fixture.rotation, identityQueries: fixture.probes,
                                adjacentQueries: fixture.adjacentQueries.map(FrameReceipt.init),
                                before: before, after: after))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(output)
        data.append(0x0a)
        FileHandle.standardOutput.write(data)
    }
}
