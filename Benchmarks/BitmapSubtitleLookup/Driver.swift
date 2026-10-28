import CoreGraphics
import Dispatch
import Foundation
@testable import IlliquidNativePlayback

private enum Operation: String, Encodable {
    case lookup, prune, stream
}

private struct BenchmarkCase {
    let name: String
    let operation: Operation
    let count: Int
    let position: String

    init(_ name: String) {
        self.name = name
        if name == "lookup-empty" {
            operation = .lookup; count = 0; position = "empty"
            return
        }
        let parts = name.split(separator: "-")
        precondition(parts.count >= 2)
        count = Int(parts.last!)!
        precondition([1, 8, 32, 128].contains(count))
        switch parts[0] {
        case "lookup": operation = .lookup; position = String(parts[1])
        case "prune": operation = .prune; position = "noop"
        case "stream": operation = .stream; position = "stream"
        default: preconditionFailure("Unknown workload")
        }
    }

    var operationsPerIteration: Int { operation == .stream ? count : 64 }
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

private struct Entry {
    let start: Double
    let composition: NativeBitmapSubtitleComposition
}

private struct Fixture {
    let benchmark: BenchmarkCase
    let generation = 7
    let maximumBytes = 32 * 1_024 * 1_024
    let displays: [NativeBitmapSubtitleComposition]
    let queries: [Double]

    init(benchmark: BenchmarkCase, seed: UInt64) {
        self.benchmark = benchmark
        displays = (0..<max(4, benchmark.count)).map { index in
            let marker = UInt8(truncatingIfNeeded: seed &+ UInt64(index * 17))
            let regions: [NativeBitmapSubtitleRegion] = index % 4 == 2 ? [] : [
                NativeBitmapSubtitleRegion(
                    pixels: Data([marker, 32, 64, 255]),
                    frame: CGRect(x: CGFloat(index % 24), y: 2, width: 1, height: 1),
                    isForced: index.isMultiple(of: 2)
                ),
            ]
            return NativeBitmapSubtitleComposition(
                regions: regions, canvasSize: CGSize(width: 1920, height: 1080),
                duration: index % 4 == 1 ? 0.25 : nil, memoryLease: nil
            )
        }
        queries = (0..<64).map { index in
            switch benchmark.position {
            case "empty", "before": return -1
            case "oldest", "noop": return 0.5
            case "middle": return Double(benchmark.count / 2) * 2 + 0.5
            case "penultimate": return Double(max(0, benchmark.count - 2)) * 2 + 0.5
            case "latest": return Double(max(0, benchmark.count - 1)) * 2 + 0.5
            case "mixed":
                let ordinal = (UInt64(index * 31) &+ seed) % UInt64(benchmark.count + 2)
                return Double(ordinal) * 2 - 0.5
            case "stream": return 0.5
            default: preconditionFailure("Unknown query position")
            }
        }
    }

    func makeTimeline() -> BitmapSubtitleTimeline {
        var timeline = BitmapSubtitleTimeline(
            maximumEntries: max(1, benchmark.count), maximumBytes: maximumBytes
        )
        timeline.reset(generation: generation)
        for index in 0..<benchmark.count {
            precondition(timeline.insert(displays[index], at: Double(index) * 2, generation: generation))
        }
        return timeline
    }

    func expectedEntries(iterations: Int) -> [Entry] {
        let offset = benchmark.operation == .stream ? iterations * benchmark.count : 0
        return (offset..<(offset + benchmark.count)).map {
            Entry(start: Double($0) * 2, composition: displays[$0 % displays.count])
        }
    }

    // Original reverse-scan semantics are an independent oracle for the search.
    func select(_ seconds: Double, entries: [Entry])
        -> (start: Double, value: NativeBitmapSubtitleComposition)? {
        guard seconds.isFinite, let entry = entries.last(where: { $0.start <= seconds }) else { return nil }
        if let duration = entry.composition.duration, seconds >= entry.start + duration { return nil }
        return (entry.start, entry.composition)
    }

    func expectedChecksum(iterations: Int) -> UInt64 {
        switch benchmark.operation {
        case .lookup:
            let entries = expectedEntries(iterations: 0)
            let cycle = queries.reduce(UInt64(0)) { $0 &+ token(select($1, entries: entries)) }
            return cycle &* UInt64(iterations)
        case .prune:
            let bytes = displays.prefix(benchmark.count).reduce(0) { $0 + $1.byteCount }
            return UInt64(bytes) &* UInt64(64) &* UInt64(iterations)
        case .stream:
            var result: UInt64 = 0
            for ordinal in 1...(iterations * benchmark.count) {
                let display = displays[ordinal % displays.count]
                let selected: (start: Double, value: NativeBitmapSubtitleComposition)?
                if let duration = display.duration, duration <= 0.5 {
                    selected = nil
                } else {
                    selected = (Double(ordinal) * 2, display)
                }
                result &+= token(selected)
            }
            return result
        }
    }

    func verify(_ timeline: BitmapSubtitleTimeline, iterations: Int) -> Receipt {
        let entries = expectedEntries(iterations: iterations)
        var seconds = queries + [Double.nan, -.infinity, .infinity, -1, -0.0, 0.0]
        for entry in entries {
            seconds += [entry.start.nextDown, entry.start, entry.start.nextUp, entry.start + 0.5]
            if let duration = entry.composition.duration { seconds.append(entry.start + duration) }
        }
        if let last = entries.last { seconds.append(last.start + 4) }
        let actual = Receipt(timeline: timeline, seconds: seconds)
        let totalInserted = benchmark.count
            + (benchmark.operation == .stream ? iterations * benchmark.count : 0)
        let expected = Receipt(
            generation: generation, revision: 1 &+ UInt64(totalInserted),
            retainedBytes: entries.reduce(0) { $0 + $1.composition.byteCount },
            maximumEntries: max(1, benchmark.count), maximumBytes: maximumBytes,
            queries: seconds.map { QueryReceipt(seconds: $0, selected: select($0, entries: entries)) }
        )
        precondition(actual == expected, "Complete timeline receipt differs from oracle")
        return actual
    }
}

@inline(__always)
private func token(_ selected: (start: Double, value: NativeBitmapSubtitleComposition)?) -> UInt64 {
    guard let selected else { return 0x9e37_79b9_7f4a_7c15 }
    return selected.start.bitPattern &+ UInt64(selected.value.regions.count)
}

@inline(never)
private func exercise(_ timeline: inout BitmapSubtitleTimeline, fixture: Fixture, iterations: Int) -> UInt64 {
    var checksum: UInt64 = 0
    switch fixture.benchmark.operation {
    case .lookup:
        for _ in 0..<iterations {
            for seconds in fixture.queries { checksum &+= token(timeline.composition(at: seconds)) }
        }
    case .prune:
        for _ in 0..<iterations {
            for seconds in fixture.queries {
                timeline.prune(before: seconds)
                checksum &+= UInt64(timeline.retainedBytes)
            }
        }
    case .stream:
        var next = fixture.benchmark.count
        for _ in 0..<iterations {
            for _ in 0..<fixture.benchmark.count {
                let current = Double(next - fixture.benchmark.count + 1) * 2
                timeline.prune(before: current)
                precondition(timeline.insert(fixture.displays[next % fixture.displays.count],
                    at: Double(next) * 2, generation: fixture.generation))
                checksum &+= token(timeline.composition(at: current + 0.5))
                next += 1
            }
        }
    }
    return checksum
}

private struct Output: Encodable {
    let caseName: String
    let iterations: Int
    let seed: UInt64
    let operation: Operation
    let elapsedNanoseconds: UInt64
    let checksum: UInt64
    let operationsPerIteration: Int
    let receipt: Receipt

    enum CodingKeys: String, CodingKey {
        case caseName = "case"
        case iterations, seed, operation, checksum, receipt
        case elapsedNanoseconds = "elapsed_ns"
        case operationsPerIteration = "operations_per_iteration"
    }
}

@main
private struct Driver {
    static func main() throws {
        let arguments = CommandLine.arguments
        precondition(arguments.count == 4, "usage: driver CASE ITERATIONS SEED")
        let iterations = Int(arguments[2])!
        let seed = UInt64(arguments[3])!
        let benchmark = BenchmarkCase(arguments[1])
        precondition(iterations > 0 && iterations <= (1 << 40) / max(1, benchmark.count))
        let fixture = Fixture(benchmark: benchmark, seed: seed)
        for _ in 0..<3 {
            var warm = fixture.makeTimeline()
            let result = exercise(&warm, fixture: fixture, iterations: 1)
            precondition(result == fixture.expectedChecksum(iterations: 1), "warmup checksum")
            _ = fixture.verify(warm, iterations: 1)
        }
        var timeline = fixture.makeTimeline()
        _ = fixture.verify(timeline, iterations: 0)
        let expected = fixture.expectedChecksum(iterations: iterations)
        let start = DispatchTime.now().uptimeNanoseconds
        let checksum = exercise(&timeline, fixture: fixture, iterations: iterations)
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        precondition(checksum == expected, "timed checksum")
        let receipt = fixture.verify(timeline, iterations: iterations)
        let output = Output(
            caseName: benchmark.name, iterations: iterations, seed: seed,
            operation: benchmark.operation, elapsedNanoseconds: elapsed, checksum: checksum,
            operationsPerIteration: benchmark.operationsPerIteration, receipt: receipt
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(output)
        data.append(0x0a)
        FileHandle.standardOutput.write(data)
    }
}
