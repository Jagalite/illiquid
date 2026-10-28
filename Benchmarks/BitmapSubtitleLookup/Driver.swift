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
            return "Bitmap subtitle lookup verification failed: \(phase)"
        }
    }
}

private enum QueryPattern {
    case empty
    case first
    case middle
    case newest
    case afterNewest
    case beforeFirst
    case penultimate
    case mixedForward
    case mixedShuffled
}

private struct BenchmarkCase {
    let name: String
    let pattern: QueryPattern
    let count: Int

    init(_ name: String) throws {
        self.name = name
        let configuration: (QueryPattern, Int)
        switch name {
        case "empty": configuration = (.empty, 0)
        case "first-8": configuration = (.first, 8)
        case "first-32": configuration = (.first, 32)
        case "first-128": configuration = (.first, 128)
        case "middle-8": configuration = (.middle, 8)
        case "middle-32": configuration = (.middle, 32)
        case "middle-128": configuration = (.middle, 128)
        case "newest-1": configuration = (.newest, 1)
        case "newest-8": configuration = (.newest, 8)
        case "newest-32": configuration = (.newest, 32)
        case "newest-128": configuration = (.newest, 128)
        case "after-newest-1": configuration = (.afterNewest, 1)
        case "after-newest-8": configuration = (.afterNewest, 8)
        case "after-newest-32": configuration = (.afterNewest, 32)
        case "after-newest-128": configuration = (.afterNewest, 128)
        case "before-first-1": configuration = (.beforeFirst, 1)
        case "before-first-8": configuration = (.beforeFirst, 8)
        case "before-first-32": configuration = (.beforeFirst, 32)
        case "before-first-128": configuration = (.beforeFirst, 128)
        case "penultimate-2": configuration = (.penultimate, 2)
        case "penultimate-8": configuration = (.penultimate, 8)
        case "penultimate-32": configuration = (.penultimate, 32)
        case "penultimate-128": configuration = (.penultimate, 128)
        case "mixed-forward-8": configuration = (.mixedForward, 8)
        case "mixed-forward-32": configuration = (.mixedForward, 32)
        case "mixed-forward-128": configuration = (.mixedForward, 128)
        case "mixed-shuffled-8": configuration = (.mixedShuffled, 8)
        case "mixed-shuffled-32": configuration = (.mixedShuffled, 32)
        case "mixed-shuffled-128": configuration = (.mixedShuffled, 128)
        default: throw DriverError.unknownCase(name)
        }
        pattern = configuration.0
        count = configuration.1
    }

    var hasMixedDisplays: Bool {
        switch pattern {
        case .mixedForward, .mixedShuffled: return true
        default: return false
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

    mutating func apply(to values: inout [Double]) {
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
}

private struct ExpectedEntry {
    let start: Double
    let composition: NativeBitmapSubtitleComposition
}

private struct Fixture {
    let benchmark: BenchmarkCase
    let generation = 7
    let maximumBytes = 32 * 1_024 * 1_024
    let entries: [ExpectedEntry]
    let querySeconds: [Double]
    let verificationSeconds: [Double]

    init(benchmark: BenchmarkCase, seed: UInt64) {
        self.benchmark = benchmark
        let origin = Double(seed % 1024) * 0.5
        entries = (0..<benchmark.count).map {
            ExpectedEntry(
                start: origin + Double($0) * 2,
                composition: Self.composition(
                    index: $0, seed: seed, mixed: benchmark.hasMixedDisplays)
            )
        }

        let point: Double
        switch benchmark.pattern {
        case .empty:
            point = origin
        case .first:
            point = entries[0].start
        case .middle:
            point = entries[benchmark.count / 2].start
        case .newest:
            point = entries[benchmark.count - 1].start
        case .afterNewest:
            point = entries[benchmark.count - 1].start + 16
        case .beforeFirst:
            point = entries[0].start.nextDown
        case .penultimate:
            point = entries[benchmark.count - 2].start
        case .mixedForward, .mixedShuffled:
            point = origin
        }

        switch benchmark.pattern {
        case .mixedForward, .mixedShuffled:
            var seconds = [origin - 0.5]
            for entry in entries {
                // At-start, active, exact expiry, expired, and clear intervals.
                // All offsets are exactly representable in these fixtures.
                seconds.append(contentsOf: [
                    entry.start, entry.start + 0.125, entry.start + 0.25,
                    entry.start + 0.5, entry.start + 1.25, entry.start + 1.75,
                ])
            }
            seconds.append(origin + Double(benchmark.count) * 2 + 8)
            if case .mixedShuffled = benchmark.pattern {
                var shuffle = Shuffle(state: seed)
                shuffle.apply(to: &seconds)
            }
            querySeconds = seconds
        default:
            // Amortize the clock and function boundary over a batch; the
            // production query and result consumption remain inside timing.
            querySeconds = Array(repeating: point, count: 256)
        }

        // Receipts probe every stored display and its boundaries, not only the
        // location exercised by a single-position timing case. Nonfinite values
        // are encoded by bit pattern, keeping the evidence valid JSON.
        var checks: [Double] = [.nan, -.infinity, .infinity, origin - 1, -0.0, 0.0]
        for entry in entries {
            checks.append(contentsOf: [
                entry.start.nextDown, entry.start, entry.start + 0.125,
                entry.start + 0.5, entry.start + 1.75,
            ])
            if let duration = entry.composition.duration {
                let end = entry.start + duration
                checks.append(contentsOf: [end.nextDown, end, end.nextUp])
            }
        }
        checks.append(origin + Double(benchmark.count) * 2 + 16)
        checks.append(contentsOf: querySeconds)
        var seen = Set<UInt64>()
        verificationSeconds = checks.filter { seen.insert($0.bitPattern).inserted }
    }

    private static func composition(index: Int, seed: UInt64, mixed: Bool)
        -> NativeBitmapSubtitleComposition
    {
        let marker = UInt8(truncatingIfNeeded: seed &+ UInt64(index * 17))
        let main = NativeBitmapSubtitleRegion(
            pixels: Data([marker, 32, 64, 255]),
            frame: CGRect(x: CGFloat(index % 24), y: 2, width: 1, height: 1),
            isForced: index.isMultiple(of: 2)
        )
        let regions: [NativeBitmapSubtitleRegion]
        let duration: Double?
        if mixed {
            switch index % 4 {
            case 0:
                regions = [main]
                duration = nil
            case 1:
                regions = [main]
                duration = 0.25
            case 2:
                regions = [] // An indefinite empty display is a clear event.
                duration = nil
            default:
                regions = [main, NativeBitmapSubtitleRegion(
                    pixels: Data([marker ^ 0xff, 16, 32, 255]),
                    frame: CGRect(x: 40, y: 4, width: 1, height: 1),
                    isForced: false
                )]
                duration = 1.25
            }
        } else {
            regions = [main]
            duration = nil
        }
        return NativeBitmapSubtitleComposition(
            regions: regions, canvasSize: CGSize(width: 1920, height: 1080),
            duration: duration, memoryLease: nil
        )
    }

    func makeTimeline() throws -> BitmapSubtitleTimeline {
        var timeline = BitmapSubtitleTimeline(
            maximumEntries: max(1, benchmark.count), maximumBytes: maximumBytes)
        timeline.reset(generation: generation)
        for entry in entries {
            guard timeline.insert(entry.composition, at: entry.start, generation: generation) else {
                throw DriverError.mismatch("untimed prefill")
            }
        }
        return timeline
    }

    /// Independent fixture oracle: scan forward and choose the last event at
    /// or before the query, then apply its duration without reviving older sets.
    /// This never calls production lookup, insertion, pruning, or index helpers.
    private func expectedSelection(at seconds: Double)
        -> (start: Double, value: NativeBitmapSubtitleComposition)?
    {
        guard seconds.isFinite else { return nil }
        var selected: ExpectedEntry?
        for entry in entries {
            if entry.start <= seconds { selected = entry }
        }
        guard let selected else { return nil }
        if let duration = selected.composition.duration,
           seconds >= selected.start + duration { return nil }
        return (selected.start, selected.composition)
    }

    func expectedChecksum(iterations: Int) -> UInt64 {
        var perIteration: UInt64 = 0
        for seconds in querySeconds {
            if let selected = expectedSelection(at: seconds) {
                perIteration &+= selected.start.bitPattern
                perIteration &+= UInt64(selected.value.regions.first?.pixels.first ?? 0)
                perIteration &+= 1
            } else {
                perIteration &+= 0xd1b54a32d192ed03
            }
        }
        return perIteration &* UInt64(iterations)
    }

    func verify(_ timeline: BitmapSubtitleTimeline, phase: String) throws -> Receipt {
        let expected = Receipt(
            generation: generation,
            revision: 1 &+ UInt64(entries.count),
            retainedBytes: entries.reduce(0) { total, entry in
                total + entry.composition.regions.reduce(0) { $0 + $1.pixels.count }
            },
            maximumEntries: max(1, benchmark.count), maximumBytes: maximumBytes,
            queries: verificationSeconds.map {
                QueryReceipt(seconds: $0, selected: expectedSelection(at: $0))
            }
        )
        let actual = Receipt(
            generation: timeline.generation, revision: timeline.revision,
            retainedBytes: timeline.retainedBytes,
            maximumEntries: timeline.maximumEntries, maximumBytes: timeline.maximumBytes,
            queries: verificationSeconds.map {
                QueryReceipt(seconds: $0, selected: timeline.composition(at: $0))
            }
        )
        guard actual == expected else { throw DriverError.mismatch(phase) }
        return actual
    }
}

@inline(never)
private func exercise(_ timeline: BitmapSubtitleTimeline, seconds queries: [Double], iterations: Int) -> UInt64 {
    var checksum: UInt64 = 0
    for _ in 0..<iterations {
        for seconds in queries {
            if let selected = timeline.composition(at: seconds) {
                // Consume timestamp, payload, and presence. Full pixel/geometry
                // receipts are verified separately, outside the timed region.
                checksum &+= selected.start.bitPattern
                checksum &+= UInt64(selected.value.regions.first?.pixels.first ?? 0)
                checksum &+= 1
            } else {
                checksum &+= 0xd1b54a32d192ed03
            }
        }
    }
    return checksum
}

private struct Measurement {
    let elapsedNanoseconds: UInt64
    let checksum: UInt64
}

@inline(never)
private func measure(_ timeline: BitmapSubtitleTimeline, seconds: [Double], iterations: Int) -> Measurement {
    let start = DispatchTime.now().uptimeNanoseconds
    let checksum = exercise(timeline, seconds: seconds, iterations: iterations)
    let elapsed = DispatchTime.now().uptimeNanoseconds &- start
    return Measurement(elapsedNanoseconds: elapsed, checksum: checksum)
}

private struct Output: Encodable {
    let caseName: String
    let iterations: Int
    let seed: UInt64
    let elapsedNanoseconds: UInt64
    let checksum: UInt64
    let operationsPerIteration: Int
    let occupancy: Int
    let receipt: Receipt

    enum CodingKeys: String, CodingKey {
        case caseName = "case"
        case iterations, seed, checksum, occupancy, receipt
        case elapsedNanoseconds = "elapsed_ns"
        case operationsPerIteration = "operations_per_iteration"
    }
}

@main
private struct Driver {
    static func main() throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 4,
              let iterations = Int(arguments[2]), iterations > 0,
              let seed = UInt64(arguments[3]) else { throw DriverError.usage }
        let benchmark = try BenchmarkCase(arguments[1])
        let fixture = Fixture(benchmark: benchmark, seed: seed)
        guard iterations <= (1 << 40) / fixture.querySeconds.count else {
            throw DriverError.usage
        }
        let timeline = try fixture.makeTimeline()
        _ = try fixture.verify(timeline, phase: "untimed initial state")
        let warmExpected = fixture.expectedChecksum(iterations: 1)
        for _ in 0..<3 {
            guard exercise(timeline, seconds: fixture.querySeconds, iterations: 1) == warmExpected else {
                throw DriverError.mismatch("warmup checksum")
            }
        }
        let expectedChecksum = fixture.expectedChecksum(iterations: iterations)
        let measurement = measure(timeline, seconds: fixture.querySeconds, iterations: iterations)
        guard measurement.checksum == expectedChecksum else {
            throw DriverError.mismatch("timed query checksum")
        }
        let receipt = try fixture.verify(timeline, phase: "untimed final state")
        let output = Output(
            caseName: benchmark.name, iterations: iterations, seed: seed,
            elapsedNanoseconds: measurement.elapsedNanoseconds,
            checksum: measurement.checksum,
            operationsPerIteration: fixture.querySeconds.count,
            occupancy: benchmark.count, receipt: receipt
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(output)
        data.append(0x0a)
        FileHandle.standardOutput.write(data)
    }
}
