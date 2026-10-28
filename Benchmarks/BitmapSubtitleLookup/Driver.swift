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
    case lookup
    case prune
    case stream
}

private enum Position: String {
    case first
    case middle
    case penultimate
    case latest
    case missing
}

private struct BenchmarkCase {
    let name: String
    let operation: Operation
    let count: Int
    let position: Position

    var operationsPerIteration: Int { operation == .stream ? count : 32 }

    init(_ name: String) throws {
        self.name = name
        let parts = name.split(separator: "-")
        guard let first = parts.first, let operation = Operation(rawValue: String(first)),
              let last = parts.last, let count = Int(last), [1, 8, 32, 128].contains(count)
        else { throw DriverError.unknownCase(name) }
        self.operation = operation
        self.count = count
        if operation == .stream {
            guard parts.count == 2, count > 1 else { throw DriverError.unknownCase(name) }
            position = .first
        } else {
            guard parts.count == 3, let position = Position(rawValue: String(parts[1])),
                  operation != .prune || position == .first || position == .missing
            else { throw DriverError.unknownCase(name) }
            self.position = position
        }
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
            seconds.append(entry.start + fixture.spacing / 4)
            if let duration = entry.composition.duration {
                seconds.append(entry.start + duration)
            }
        }
        // Probe original entries too: stream pruning must remove old captions.
        for index in 0..<fixture.benchmark.count { seconds.append(fixture.origin + Double(index) * fixture.spacing) }
        seconds.append(contentsOf: fixture.times)
        if let first = entries.first { seconds.append(first.start - fixture.spacing) }
        if let last = entries.last { seconds.append(last.start + 2 * fixture.spacing) }
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
    var selectedStartChecksum: UInt64 = 0
    var observedMetadata: UInt64 = 0

    var checksum: UInt64 {
        acceptedInsertions &+ presentQueries &+ selectedStartChecksum &+ observedMetadata
    }
}

private struct Fixture {
    let benchmark: BenchmarkCase
    let generation = 7
    let maximumBytes = 32 * 1_024 * 1_024
    let origin: Double
    let spacing: Double
    let primary: [NativeBitmapSubtitleComposition]
    let times: [Double]
    let selectedStart: Double?

    init(benchmark: BenchmarkCase, seed: UInt64) {
        self.benchmark = benchmark
        let origin = 60.0
        self.origin = origin
        // Power-of-two counts keep this spacing exactly representable. A
        // filled window spans less than the production 30-second read-ahead.
        let spacing = 30 / Double(benchmark.count)
        self.spacing = spacing
        let poolCount = max(4, benchmark.count)
        primary = (0..<poolCount).map {
            Self.composition(index: $0, seed: seed, spacing: spacing)
        }
        let index: Int
        switch benchmark.position {
        case .first, .missing: index = 0
        case .middle: index = benchmark.count / 2
        case .penultimate: index = max(0, benchmark.count - 2)
        case .latest: index = benchmark.count - 1
        }
        let start = origin + Double(index) * spacing
        selectedStart = benchmark.position == .missing ? nil : start
        var random = Shuffle(state: seed)
        times = (0..<32).map { _ in
            let offset = spacing * Double(random.next() % 4) / 8
            return benchmark.position == .missing ? origin - spacing - offset : start + offset
        }
    }

    private static func composition(index: Int, seed: UInt64, spacing: Double) -> NativeBitmapSubtitleComposition {
        let marker = UInt8(truncatingIfNeeded: seed &+ UInt64(index * 17))
        let pixels = Data([marker, 32, 64, 255, marker ^ 0xff, 16, 32, 255,
                           64, marker, 16, 255, 32, 64, marker, 255])
        let main = NativeBitmapSubtitleRegion(
            pixels: pixels,
            frame: CGRect(x: CGFloat(index % 24), y: 2, width: 2, height: 2),
            isForced: index % 2 == 0
        )
        let regions: [NativeBitmapSubtitleRegion]
        let duration: Double?
        switch index % 4 {
        case 0:
            regions = [main]
            duration = nil
        case 1:
            regions = [main]
            duration = spacing / 8
        case 2:
            regions = [] // An indefinite empty clear set.
            duration = nil
        default:
            regions = [main, NativeBitmapSubtitleRegion(
                pixels: Data([64, 32, marker, 255]),
                frame: CGRect(x: 40, y: 4, width: 1, height: 1),
                isForced: true
            )]
            duration = spacing * 5 / 8
        }
        return NativeBitmapSubtitleComposition(
            regions: regions,
            canvasSize: CGSize(width: 1920, height: 1080),
            duration: duration, memoryLease: nil
        )
    }

    func makeTimeline() throws -> BitmapSubtitleTimeline {
        var timeline = BitmapSubtitleTimeline(maximumEntries: benchmark.count, maximumBytes: maximumBytes)
        timeline.reset(generation: generation)
        for index in 0..<benchmark.count {
            guard timeline.insert(primary[index], at: origin + Double(index) * spacing, generation: generation) else {
                throw DriverError.mismatch("untimed prefill")
            }
        }
        return timeline
    }

    /// Derive the final entries directly from each workload's construction.
    /// This is O(window size), even for millions of timed operations;
    /// it never calls production insert/reset/prune or replays an optimized index.
    func expectedState(iterations: Int) -> ExpectedState {
        let total = iterations * benchmark.count
        let entries: [ExpectedEntry]
        let revision: UInt64
        switch benchmark.operation {
        case .lookup, .prune:
            entries = (0..<benchmark.count).map {
                ExpectedEntry(start: origin + Double($0) * spacing, composition: primary[$0])
            }
            revision = 1 &+ UInt64(benchmark.count)
        case .stream:
            entries = (total..<(total + benchmark.count)).map {
                ExpectedEntry(start: origin + Double($0) * spacing, composition: primary[$0 % primary.count])
            }
            revision = 1 &+ UInt64(benchmark.count) &+ UInt64(total)
        }
        return ExpectedState(entries: entries, revision: revision, fixture: self)
    }

    func expectedCounts(iterations: Int) -> Counts {
        let total = UInt64(iterations * benchmark.operationsPerIteration)
        switch benchmark.operation {
        case .lookup:
            return Counts(
                presentQueries: selectedStart == nil ? 0 : total,
                selectedStartChecksum: (selectedStart?.bitPattern ?? 0) &* total
            )
        case .prune:
            let bytes = primary.prefix(benchmark.count).reduce(0) { $0 + $1.byteCount }
            let metadata = UInt64(bytes) &+ 1 &+ UInt64(benchmark.count)
            return Counts(observedMetadata: metadata &* total)
        case .stream:
            // Queries visit ordinals 1...total at one quarter of the spacing.
            // Every fourth composition (ordinal % 4 == 1) has expired.
            return Counts(acceptedInsertions: total, presentQueries: total - (total + 3) / 4)
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
    case .lookup:
        for _ in 0..<iterations {
            for seconds in fixture.times {
                if let selected = timeline.composition(at: seconds) {
                    counts.presentQueries &+= 1
                    counts.selectedStartChecksum &+= selected.start.bitPattern
                }
            }
        }
    case .prune:
        for _ in 0..<iterations {
            for seconds in fixture.times {
                timeline.prune(before: seconds)
                counts.observedMetadata &+= UInt64(timeline.retainedBytes) &+ timeline.revision
            }
        }
    case .stream:
        var next = fixture.benchmark.count
        for _ in 0..<iterations {
            for _ in 0..<fixture.benchmark.count {
                let current = fixture.origin + Double(next - fixture.benchmark.count + 1) * fixture.spacing
                // Advance one event, retain that display, and append a
                // future event. This is a synthetic rolling-window workload,
                // not a trace of a player's rendering or packet cadence.
                timeline.prune(before: current)
                if timeline.insert(fixture.primary[next % fixture.primary.count],
                                   at: fixture.origin + Double(next) * fixture.spacing, generation: fixture.generation) {
                    counts.acceptedInsertions &+= 1
                }
                if timeline.composition(at: current + fixture.spacing / 4) != nil {
                    counts.presentQueries &+= 1
                }
                next += 1
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
    let selectedStartChecksum: UInt64
    let observedMetadata: UInt64
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
        case selectedStartChecksum = "selected_start_checksum"
        case observedMetadata = "observed_metadata"
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
        // Keep timestamp and fractional-offset arithmetic exactly representable,
        // even if this executable is invoked outside the calibration runner.
        guard iterations <= (1 << 40) / max(benchmark.count, benchmark.operationsPerIteration) else { throw DriverError.usage }
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
            throw DriverError.mismatch("timed operation counts")
        }
        let receipt = try fixture.verify(timeline, iterations: iterations, phase: "timed final state")
        let output = Output(
            caseName: benchmark.name, iterations: iterations, seed: seed,
            operation: benchmark.operation, elapsedNanoseconds: measurement.elapsedNanoseconds,
            checksum: measurement.counts.checksum,
            acceptedInsertions: measurement.counts.acceptedInsertions,
            presentQueries: measurement.counts.presentQueries,
            selectedStartChecksum: measurement.counts.selectedStartChecksum,
            observedMetadata: measurement.counts.observedMetadata,
            operationsPerIteration: benchmark.operationsPerIteration,
            queriesPerIteration: benchmark.operation == .prune ? 0 : benchmark.operationsPerIteration,
            prunesPerIteration: benchmark.operation == .lookup ? 0 : benchmark.operationsPerIteration,
            resetsPerIteration: 0,
            receipt: receipt
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(output)
        data.append(0x0a)
        FileHandle.standardOutput.write(data)
    }
}
