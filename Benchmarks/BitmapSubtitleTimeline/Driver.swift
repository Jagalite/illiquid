import CoreGraphics
import Dispatch
import Foundation
@testable import IlliquidNativePlayback

private enum DriverError: Error, CustomStringConvertible {
    case usage
    case unknownCase(String)
    case mismatch(String)

    var description: String {
        switch self {
        case .usage:
            return "Usage: driver CASE ITERATIONS SEED (positive iterations, UInt64 seed)"
        case let .unknownCase(name):
            return "Unknown benchmark case: \(name)"
        case let .mismatch(phase):
            return "Timeline verification failed: \(phase)"
        }
    }
}

private enum Operation: String, Encodable {
    case fill
    case replace
    case stream
    case reject
}

private enum Order {
    case ascending
    case descending
    case shuffled
}

private struct BenchmarkCase {
    let name: String
    let operation: Operation
    let count: Int
    let order: Order

    init(_ name: String) throws {
        self.name = name
        let configuration: (Operation, Int, Order)
        switch name {
        case "fill-ascending-1": configuration = (.fill, 1, .ascending)
        case "fill-ascending-8": configuration = (.fill, 8, .ascending)
        case "fill-ascending-32": configuration = (.fill, 32, .ascending)
        case "fill-ascending-128": configuration = (.fill, 128, .ascending)
        case "fill-descending-128": configuration = (.fill, 128, .descending)
        case "fill-shuffled-128": configuration = (.fill, 128, .shuffled)
        case "replace-32": configuration = (.replace, 32, .shuffled)
        case "replace-128": configuration = (.replace, 128, .shuffled)
        case "stream-8": configuration = (.stream, 8, .ascending)
        case "stream-32": configuration = (.stream, 32, .ascending)
        case "stream-128": configuration = (.stream, 128, .ascending)
        case "reject-full-128": configuration = (.reject, 128, .shuffled)
        default: throw DriverError.unknownCase(name)
        }
        operation = configuration.0
        count = configuration.1
        order = configuration.2
    }
}

private struct Shuffle {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9e3779b97f4a7c15
        var value = state
        value = (value ^ (value >> 30)) &* 0xbf58476d1ce4e5b9
        value = (value ^ (value >> 27)) &* 0x94d049bb133111eb
        return value ^ (value >> 31)
    }

    mutating func apply(to values: inout [Int]) {
        guard values.count > 1 else { return }
        for index in stride(from: values.count - 1, through: 1, by: -1) {
            values.swapAt(index, Int(next() % UInt64(index + 1)))
        }
    }
}

private struct RegionReceipt: Encodable, Equatable {
    let pixels: [UInt8]
    let frameBits: [UInt64]
    let isForced: Bool

    init(_ region: NativeBitmapSubtitleRegion) {
        pixels = Array(region.pixels)
        frameBits = [region.frame.origin.x, region.frame.origin.y,
                     region.frame.size.width, region.frame.size.height].map {
            Double($0).bitPattern
        }
        isForced = region.isForced
    }
}

private struct CompositionReceipt: Encodable, Equatable {
    let regions: [RegionReceipt]
    let canvasBits: [UInt64]
    let durationBits: UInt64?
    let hasMemoryLease: Bool

    init(_ composition: NativeBitmapSubtitleComposition) {
        regions = composition.regions.map(RegionReceipt.init)
        canvasBits = [Double(composition.canvasSize.width).bitPattern,
                      Double(composition.canvasSize.height).bitPattern]
        durationBits = composition.duration?.bitPattern
        hasMemoryLease = composition.memoryLease != nil
    }
}

private struct QueryReceipt: Encodable, Equatable {
    let queryBits: UInt64
    let startBits: UInt64?
    let composition: CompositionReceipt?

    init(seconds: Double, selected: (start: Double, value: NativeBitmapSubtitleComposition)?) {
        queryBits = seconds.bitPattern
        startBits = selected?.start.bitPattern
        composition = selected.map { CompositionReceipt($0.value) }
    }
}

private struct Receipt: Encodable, Equatable {
    let generation: Int
    let revision: UInt64
    let retainedBytes: Int
    let maximumEntries: Int
    let maximumBytes: Int
    let queries: [QueryReceipt]

    init(timeline: BitmapSubtitleTimeline, seconds: [Double]) {
        generation = timeline.generation
        revision = timeline.revision
        retainedBytes = timeline.retainedBytes
        maximumEntries = timeline.maximumEntries
        maximumBytes = timeline.maximumBytes
        queries = seconds.map {
            QueryReceipt(seconds: $0, selected: timeline.composition(at: $0))
        }
    }

    init(generation: Int, revision: UInt64, retainedBytes: Int,
         maximumEntries: Int, maximumBytes: Int, queries: [QueryReceipt]) {
        self.generation = generation
        self.revision = revision
        self.retainedBytes = retainedBytes
        self.maximumEntries = maximumEntries
        self.maximumBytes = maximumBytes
        self.queries = queries
    }
}

private struct ExpectedEntry {
    let start: Double
    let composition: NativeBitmapSubtitleComposition
}

private struct ExpectedState {
    let entries: [ExpectedEntry]
    let revision: UInt64
    let fixture: Fixture

    var querySeconds: [Double] {
        // Preserve both zero bit patterns and represent nonfinite inputs as bits
        // in the receipt, so JSON never needs to encode NaN or infinity.
        var seconds: [Double] = [.nan, -.infinity, .infinity, -1, -0.0, 0.0]
        for entry in entries {
            seconds.append(entry.start.nextDown)
            seconds.append(entry.start)
            seconds.append(entry.start + 0.5)
            if let duration = entry.composition.duration {
                seconds.append(entry.start + duration)
            }
        }
        // Probe original entries too: stream pruning must remove old captions.
        for index in 0..<fixture.benchmark.count { seconds.append(Double(index) * 2) }
        if let first = entries.first { seconds.append(first.start - 2) }
        if let last = entries.last { seconds.append(last.start + 4) }
        return seconds
    }

    var receipt: Receipt {
        let queries = querySeconds.map { seconds -> QueryReceipt in
            let selected: (start: Double, value: NativeBitmapSubtitleComposition)?
            if seconds.isFinite, let entry = entries.last(where: { $0.start <= seconds }),
               entry.composition.duration.map({ seconds < entry.start + $0 }) ?? true {
                selected = (entry.start, entry.composition)
            } else {
                selected = nil
            }
            return QueryReceipt(seconds: seconds, selected: selected)
        }
        let bytes = entries.reduce(0) { total, entry in
            total + entry.composition.regions.reduce(0) { $0 + $1.pixels.count }
        }
        return Receipt(generation: fixture.generation, revision: revision, retainedBytes: bytes,
                       maximumEntries: fixture.benchmark.count, maximumBytes: fixture.maximumBytes,
                       queries: queries)
    }
}

private struct Counts: Equatable {
    var acceptedInsertions: UInt64 = 0
    var presentQueries: UInt64 = 0

    var checksum: UInt64 { acceptedInsertions &+ presentQueries }
}

private struct Fixture {
    let benchmark: BenchmarkCase
    let generation = 7
    let maximumBytes = 32 * 1_024 * 1_024
    let order: [Int]
    let primary: [NativeBitmapSubtitleComposition]
    let alternate: [NativeBitmapSubtitleComposition]

    init(benchmark: BenchmarkCase, seed: UInt64) {
        self.benchmark = benchmark
        var order = Array(0..<benchmark.count)
        switch benchmark.order {
        case .ascending: break
        case .descending: order.reverse()
        case .shuffled:
            var shuffle = Shuffle(state: seed)
            shuffle.apply(to: &order)
        }
        self.order = order
        // Small immutable pixel buffers are prepared once. Insertion retains
        // existing Data; this harness does not measure bitmap decoding/rendering.
        let poolCount = max(4, benchmark.count)
        primary = (0..<poolCount).map { Self.composition(index: $0, alternate: false, seed: seed) }
        alternate = (0..<poolCount).map { Self.composition(index: $0, alternate: true, seed: seed) }
    }

    private static func composition(index: Int, alternate: Bool, seed: UInt64) -> NativeBitmapSubtitleComposition {
        let marker = UInt8(truncatingIfNeeded: seed &+ UInt64(index * 17 + (alternate ? 97 : 0)))
        let pixels = Data([marker, 32, 64, 255, marker ^ 0xff, 16, 32, 255,
                           64, marker, 16, 255, 32, 64, marker, 255])
        let main = NativeBitmapSubtitleRegion(
            pixels: pixels,
            frame: CGRect(x: CGFloat(index % 24), y: alternate ? 3 : 2, width: 2, height: 2),
            isForced: (index % 2 == 0) != alternate
        )
        let regions: [NativeBitmapSubtitleRegion]
        let duration: Double?
        switch index % 4 {
        case 0:
            regions = [main]
            duration = nil
        case 1:
            regions = [main]
            duration = 0.25
        case 2:
            regions = [] // An indefinite empty clear set.
            duration = nil
        default:
            regions = [main, NativeBitmapSubtitleRegion(
                pixels: Data([64, 32, marker, 255]),
                frame: CGRect(x: 40, y: alternate ? 5 : 4, width: 1, height: 1),
                isForced: alternate
            )]
            duration = 1.25
        }
        return NativeBitmapSubtitleComposition(
            regions: regions,
            canvasSize: CGSize(width: alternate ? 1280 : 1920, height: alternate ? 720 : 1080),
            duration: duration, memoryLease: nil
        )
    }

    func makeTimeline() throws -> BitmapSubtitleTimeline {
        var timeline = BitmapSubtitleTimeline(maximumEntries: benchmark.count, maximumBytes: maximumBytes)
        timeline.reset(generation: generation)
        if benchmark.operation != .fill {
            for index in 0..<benchmark.count {
                guard timeline.insert(primary[index], at: Double(index) * 2, generation: generation) else {
                    throw DriverError.mismatch("untimed prefill")
                }
            }
        }
        return timeline
    }

    /// Derive the final entries directly from each workload's construction.
    /// This is O(window size), even for millions of timed insertion attempts;
    /// it never calls production insert/reset/prune or replays an optimized index.
    func expectedState(iterations: Int) -> ExpectedState {
        let total = iterations * benchmark.count
        let entries: [ExpectedEntry]
        let revision: UInt64
        switch benchmark.operation {
        case .fill:
            entries = iterations == 0 ? [] : (0..<benchmark.count).map {
                ExpectedEntry(start: Double($0) * 2, composition: primary[$0])
            }
            revision = 1 &+ UInt64(iterations) &+ UInt64(total)
        case .replace:
            let useAlternate = iterations % 2 == 1
            let values = useAlternate ? alternate : primary
            entries = (0..<benchmark.count).map {
                ExpectedEntry(start: $0 == 0 && useAlternate ? -0.0 : Double($0) * 2,
                              composition: values[$0])
            }
            revision = 1 &+ UInt64(benchmark.count) &+ UInt64(total)
        case .stream:
            entries = (total..<(total + benchmark.count)).map {
                ExpectedEntry(start: Double($0) * 2, composition: primary[$0 % primary.count])
            }
            revision = 1 &+ UInt64(benchmark.count) &+ UInt64(total)
        case .reject:
            entries = (0..<benchmark.count).map {
                ExpectedEntry(start: Double($0) * 2, composition: primary[$0])
            }
            revision = 1 &+ UInt64(benchmark.count)
        }
        return ExpectedState(entries: entries, revision: revision, fixture: self)
    }

    func expectedCounts(iterations: Int) -> Counts {
        let total = UInt64(iterations * benchmark.count)
        switch benchmark.operation {
        case .fill, .replace:
            return Counts(acceptedInsertions: total)
        case .stream:
            // Queries visit ordinal 1...total at +0.5 seconds. Only every
            // fourth composition (ordinal % 4 == 1) has already expired.
            return Counts(acceptedInsertions: total, presentQueries: total - (total + 3) / 4)
        case .reject:
            return Counts()
        }
    }

    func verify(_ timeline: BitmapSubtitleTimeline, iterations: Int, phase: String) throws -> Receipt {
        let expected = expectedState(iterations: iterations)
        let actual = Receipt(timeline: timeline, seconds: expected.querySeconds)
        guard actual == expected.receipt else { throw DriverError.mismatch(phase) }
        return actual
    }
}

@inline(never)
private func exercise(_ timeline: inout BitmapSubtitleTimeline, fixture: Fixture, iterations: Int) -> Counts {
    var counts = Counts()
    switch fixture.benchmark.operation {
    case .fill:
        for _ in 0..<iterations {
            timeline.reset(generation: fixture.generation)
            for index in fixture.order {
                if timeline.insert(fixture.primary[index], at: Double(index) * 2, generation: fixture.generation) {
                    counts.acceptedInsertions &+= 1
                }
            }
        }
    case .replace:
        for cycle in 0..<iterations {
            let useAlternate = cycle % 2 == 0
            let values = useAlternate ? fixture.alternate : fixture.primary
            for index in fixture.order {
                let start = index == 0 && useAlternate ? -0.0 : Double(index) * 2
                if timeline.insert(values[index], at: start, generation: fixture.generation) {
                    counts.acceptedInsertions &+= 1
                }
            }
        }
    case .stream:
        var next = fixture.benchmark.count
        for _ in 0..<iterations {
            for _ in 0..<fixture.benchmark.count {
                let current = Double(next - fixture.benchmark.count + 1) * 2
                // Retain the next current event before appending one future
                // event: each completed step again owns exactly count entries.
                timeline.prune(before: current)
                if timeline.insert(fixture.primary[next % fixture.primary.count],
                                   at: Double(next) * 2, generation: fixture.generation) {
                    counts.acceptedInsertions &+= 1
                }
                if timeline.composition(at: current + 0.5) != nil {
                    counts.presentQueries &+= 1
                }
                next += 1
            }
        }
    case .reject:
        for _ in 0..<iterations {
            for index in fixture.order {
                if timeline.insert(fixture.primary[index], at: Double(fixture.benchmark.count + index) * 2,
                                   generation: fixture.generation) {
                    counts.acceptedInsertions &+= 1
                }
            }
        }
    }
    return counts
}

private struct Measurement {
    let elapsedNanoseconds: UInt64
    let counts: Counts
}

@inline(never)
private func measure(_ timeline: inout BitmapSubtitleTimeline, fixture: Fixture, iterations: Int) -> Measurement {
    let start = DispatchTime.now().uptimeNanoseconds
    let counts = exercise(&timeline, fixture: fixture, iterations: iterations)
    let elapsed = DispatchTime.now().uptimeNanoseconds &- start
    return Measurement(elapsedNanoseconds: elapsed, counts: counts)
}

private struct Output: Encodable {
    let caseName: String
    let iterations: Int
    let seed: UInt64
    let operation: Operation
    let elapsedNanoseconds: UInt64
    let checksum: UInt64
    let acceptedInsertions: UInt64
    let presentQueries: UInt64
    let operationsPerIteration: Int
    let queriesPerIteration: Int
    let prunesPerIteration: Int
    let resetsPerIteration: Int
    let receipt: Receipt

    enum CodingKeys: String, CodingKey {
        case caseName = "case"
        case iterations, seed, operation, checksum, receipt
        case elapsedNanoseconds = "elapsed_ns"
        case acceptedInsertions = "accepted_insertions"
        case presentQueries = "present_queries"
        case operationsPerIteration = "operations_per_iteration"
        case queriesPerIteration = "queries_per_iteration"
        case prunesPerIteration = "prunes_per_iteration"
        case resetsPerIteration = "resets_per_iteration"
    }
}

@main
private struct Driver {
    static func main() throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 4, let iterations = Int(arguments[2]), iterations > 0,
              let seed = UInt64(arguments[3]) else { throw DriverError.usage }
        let benchmark = try BenchmarkCase(arguments[1])
        // Keep integer timestamp arithmetic exact, including +0.5-second queries,
        // even if this executable is invoked outside the calibration runner.
        guard iterations <= (1 << 40) / benchmark.count else { throw DriverError.usage }
        let fixture = Fixture(benchmark: benchmark, seed: seed)

        for _ in 0..<3 {
            var warm = try fixture.makeTimeline()
            let counts = exercise(&warm, fixture: fixture, iterations: 1)
            guard counts == fixture.expectedCounts(iterations: 1) else {
                throw DriverError.mismatch("warmup operation counts")
            }
            _ = try fixture.verify(warm, iterations: 1, phase: "warmup final state")
        }

        var timeline = try fixture.makeTimeline()
        _ = try fixture.verify(timeline, iterations: 0, phase: "untimed initial state")
        let measurement = measure(&timeline, fixture: fixture, iterations: iterations)
        guard measurement.counts == fixture.expectedCounts(iterations: iterations) else {
            throw DriverError.mismatch("timed insertion/query counts")
        }
        let receipt = try fixture.verify(timeline, iterations: iterations, phase: "timed final state")
        let output = Output(
            caseName: benchmark.name, iterations: iterations, seed: seed,
            operation: benchmark.operation, elapsedNanoseconds: measurement.elapsedNanoseconds,
            checksum: measurement.counts.checksum,
            acceptedInsertions: measurement.counts.acceptedInsertions,
            presentQueries: measurement.counts.presentQueries,
            operationsPerIteration: benchmark.count,
            queriesPerIteration: benchmark.operation == .stream ? benchmark.count : 0,
            prunesPerIteration: benchmark.operation == .stream ? benchmark.count : 0,
            resetsPerIteration: benchmark.operation == .fill ? 1 : 0,
            receipt: receipt
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(output)
        data.append(0x0a)
        FileHandle.standardOutput.write(data)
    }
}
