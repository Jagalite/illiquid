#if canImport(CoreGraphics)
import CoreGraphics
#endif
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Dispatch
import Foundation
@testable import IlliquidNativePlayback

private typealias Selection = (start: Double, value: NativeBitmapSubtitleComposition)

private enum DriverError: Error {
    case unknownWorkload(String)
    case insertionRejected(String)
    case mismatch(String)
}

private enum QueryPosition: String, CaseIterable {
    case beforeFirst = "before_first"
    case nearFirst = "near_first"
    case middle
    case penultimate
    case tailMinus3 = "tail_minus_3"
    case tailMinus4 = "tail_minus_4"
    case tailMinus5 = "tail_minus_5"
    case tail
    case beyondTail = "beyond_tail"
}

private struct Configuration {
    let name: String
    let occupancy: Int
    let position: QueryPosition
    let streamingWindow: Bool
}

private func configurations() -> [Configuration] {
    var result: [Configuration] = []
    for count in [0, 1, 2, 5, 8, 9, 32, 128] {
        for position in QueryPosition.allCases {
            if count < 9 && [.tailMinus3, .tailMinus4, .tailMinus5].contains(position) { continue }
            result.append(Configuration(name: "window_\(count)_\(position.rawValue)",
                                        occupancy: count, position: position, streamingWindow: false))
        }
    }
    // The runtime retains roughly 30 seconds of history and admits packets up
    // to 30 seconds ahead. These uniform synthetic occupancies are illustrative,
    // not measurements of the event distribution in users' subtitle tracks.
    for count in [8, 32, 128] {
        result.append(Configuration(name: "stream_history30_ahead30_\(count)",
                                    occupancy: count, position: .middle, streamingWindow: true))
    }
    return result
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

    init(seconds: Double, selected: Selection?) {
        queryBits = seconds.bitPattern
        startBits = selected?.start.bitPattern
        composition = selected.map { CompositionReceipt($0.value) }
    }
}

private struct ExpectedEntry {
    let start: Double
    let composition: NativeBitmapSubtitleComposition
}

private struct Fixture {
    let name: String
    let timeline: BitmapSubtitleTimeline
    let entries: [ExpectedEntry]
    let queryTimes: [Double]
    // Retain the real budget while its leases are present in fixture payloads.
    let budget: SubtitleMemoryBudget

    // A straightforward forward specification, independent of the production
    // lookup's search direction and bounds. Expiry is checked only after the
    // latest event is selected: an expired event never resurrects an older one.
    func expected(at seconds: Double) -> Selection? {
        guard seconds.isFinite else { return nil }
        var selected: ExpectedEntry?
        for entry in entries where entry.start <= seconds {
            selected = entry
        }
        guard let selected else { return nil }
        if let duration = selected.composition.duration, seconds >= selected.start + duration {
            return nil
        }
        return (selected.start, selected.composition)
    }

    var boundaryQueries: [Double] {
        var values: [Double] = [.nan, -.infinity, .infinity, -1, -0.0, 0.0]
        for entry in entries {
            values += [entry.start.nextDown, entry.start, entry.start.nextUp, entry.start + 0.5]
            if let duration = entry.composition.duration {
                let expiry = entry.start + duration
                values += [expiry.nextDown, expiry, expiry.nextUp]
            }
        }
        if let first = entries.first { values.append(first.start - 4) }
        if let last = entries.last { values.append(last.start + 4) }
        return values
    }
}

private func composition(index: Int, budget: SubtitleMemoryBudget,
                         alternate: Bool = false) -> NativeBitmapSubtitleComposition {
    let marker = UInt8(truncatingIfNeeded: 0x5A + index * 17 + (alternate ? 97 : 0))
    let main = NativeBitmapSubtitleRegion(
        pixels: Data([marker, 32, 64, 255, marker ^ 0xFF, 16, 32, 255,
                      64, marker, 16, 255, 32, 64, marker, 255]),
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
        regions = [] // An indefinite empty clear event remains a selected event.
        duration = nil
    default:
        regions = [main, NativeBitmapSubtitleRegion(
            pixels: Data([64, 32, marker, 255]),
            frame: CGRect(x: 40, y: alternate ? 5 : 4, width: 1, height: 1),
            isForced: alternate
        )]
        duration = 1.25
    }
    let bytes = regions.reduce(0) { $0 + $1.pixels.count }
    let lease = bytes > 0 ? budget.acquire(owner: .bitmapEvents, bytes: bytes) : nil
    precondition(bytes == 0 || lease != nil)
    return NativeBitmapSubtitleComposition(
        regions: regions,
        canvasSize: CGSize(width: alternate ? 1280 : 1920, height: alternate ? 720 : 1080),
        duration: duration, memoryLease: lease
    )
}

private func makeFixture(_ configuration: Configuration) throws -> Fixture {
    let budget = SubtitleMemoryBudget()
    let count = configuration.occupancy
    let starts: [Double]
    let times: [Double]
    if configuration.streamingWindow {
        starts = (0..<count).map { 570 + Double($0) * (60 / Double(count)) }
        // Sixteen distinct presentation-time queries over a 120 Hz interval.
        // The window is frozen before timing; insertion/pruning are not timed.
        times = (0..<16).map { 600 + Double($0) / 120 }
    } else {
        starts = (0..<count).map { 100 + Double($0) * 2 }
        let target: Int
        switch configuration.position {
        case .beforeFirst, .nearFirst: target = 0
        case .middle: target = count / 2
        case .penultimate: target = max(0, count - 2)
        case .tailMinus3: target = max(0, count - 4)
        case .tailMinus4: target = max(0, count - 5)
        case .tailMinus5: target = max(0, count - 6)
        case .tail, .beyondTail: target = max(0, count - 1)
        }
        times = (0..<16).map { slot in
            let jitter = Double(slot + 1) / 32
            switch configuration.position {
            case .beforeFirst: return 99 - jitter
            case .beyondTail: return 104 + Double(target) * 2 + jitter
            default: return 100 + Double(target) * 2 + jitter
            }
        }
    }
    let entries = starts.enumerated().map { index, start in
        ExpectedEntry(start: start, composition: composition(index: index, budget: budget))
    }
    var timeline = BitmapSubtitleTimeline(maximumEntries: max(1, count))
    timeline.reset(generation: 7)
    for entry in entries.reversed() {
        guard timeline.insert(entry.composition, at: entry.start, generation: 7) else {
            throw DriverError.insertionRejected(configuration.name)
        }
    }
    precondition(times.count == 16 && times.allSatisfy(\.isFinite))
    precondition(Set(times).count == 16)
    return Fixture(name: configuration.name, timeline: timeline, entries: entries,
                   queryTimes: times, budget: budget)
}

// Production is a separately compiled optimized module, with no cross-module
// optimization flag or inlinable test replacement. This out-of-line adapter
// receives a varying timestamp and its actual returned value is consumed.
@inline(never)
private func read(_ timeline: BitmapSubtitleTimeline, at seconds: Double) -> Selection? {
    timeline.composition(at: seconds)
}

// Keep timed result consumption small: no receipt arrays or JSON are built
// here. The digest observes selection, duration, canvas, region geometry,
// forced flags, pixel counts/endpoints, and lease presence. Verification below
// separately compares every pixel byte and every field in complete receipts.
private func digest(_ selected: Selection?) -> UInt64 {
    guard let selected else { return 17 }
    var result = selected.start.bitPattern &+ 31
    result = result &* 31 &+ UInt64(selected.value.regions.count)
    result = result &* 31 &+ Double(selected.value.canvasSize.width).bitPattern
    result = result &* 31 &+ Double(selected.value.canvasSize.height).bitPattern
    result = result &* 31 &+ (selected.value.duration?.bitPattern ?? 0xF001)
    result = result &* 31 &+ (selected.value.memoryLease == nil ? 0 : 1)
    for region in selected.value.regions {
        result = result &* 31 &+ Double(region.frame.origin.x).bitPattern
        result = result &* 31 &+ Double(region.frame.origin.y).bitPattern
        result = result &* 31 &+ Double(region.frame.size.width).bitPattern
        result = result &* 31 &+ Double(region.frame.size.height).bitPattern
        result = result &* 31 &+ UInt64(region.pixels.count)
        result = result &* 31 &+ UInt64(region.pixels.first ?? 0)
        result = result &* 31 &+ UInt64(region.pixels.last ?? 0)
        result = result &* 31 &+ (region.isForced ? 1 : 0)
    }
    return result
}

@inline(never)
private func exercise(_ fixture: Fixture, iterations: Int) -> UInt64 {
    precondition(fixture.queryTimes.count == 16 && iterations > 0 && iterations % 16 == 0)
    var checksum: UInt64 = 0
    for index in 0..<iterations {
        checksum &+= digest(read(fixture.timeline, at: fixture.queryTimes[index & 15]))
    }
    return checksum
}

private struct Verification: Encodable {
    struct Row: Encodable {
        let name: String
        let authoredExpectation: Bool
        let result: QueryReceipt
    }
    struct State: Encodable {
        let name: String
        let occupancy: Int
        let generation: Int
        let revision: UInt64
        let retainedBytes: Int
        let maximumEntries: Int
        let maximumBytes: Int
    }
    let rows: [Row]
    let states: [State]
}

private func verify() throws -> Verification {
    var rows: [Verification.Row] = []
    var states: [Verification.State] = []
    func append(_ fixture: Fixture, queries: [Double], phase: String) throws {
        let expectedBytes = fixture.entries.reduce(0) { $0 + $1.composition.byteCount }
        guard fixture.timeline.retainedBytes == expectedBytes else {
            throw DriverError.mismatch("\(fixture.name) retained bytes")
        }
        for (index, seconds) in queries.enumerated() {
            let actual = QueryReceipt(seconds: seconds, selected: read(fixture.timeline, at: seconds))
            let expected = QueryReceipt(seconds: seconds, selected: fixture.expected(at: seconds))
            guard actual == expected else {
                throw DriverError.mismatch("\(fixture.name)/\(phase)/\(index)")
            }
            rows.append(.init(name: "\(fixture.name)/\(phase)/\(index)",
                              authoredExpectation: true, result: actual))
        }
        states.append(.init(name: "\(fixture.name)/\(phase)", occupancy: fixture.entries.count,
                            generation: fixture.timeline.generation, revision: fixture.timeline.revision,
                            retainedBytes: fixture.timeline.retainedBytes,
                            maximumEntries: fixture.timeline.maximumEntries,
                            maximumBytes: fixture.timeline.maximumBytes))
        withExtendedLifetime(fixture.budget) {}
    }

    for configuration in configurations() {
        let value = try makeFixture(configuration)
        try append(value, queries: value.queryTimes, phase: "timed_queries")
        // Check every entry boundary once per occupancy, plus each realistic
        // spacing. This includes exact expiry, adjacent representable doubles,
        // empty clears, finite durations, nonfinite queries and signed zero.
        if configuration.position == .nearFirst || configuration.streamingWindow {
            try append(value, queries: value.boundaryQueries, phase: "boundaries")
        }
    }

    let budget = SubtitleMemoryBudget()
    let original = composition(index: 0, budget: budget)
    let finite = composition(index: 1, budget: budget)
    let clear = composition(index: 2, budget: budget)
    let twoRegions = composition(index: 3, budget: budget)
    let alternate = composition(index: 0, budget: budget, alternate: true)
    var timeline = BitmapSubtitleTimeline(maximumEntries: 8)
    timeline.reset(generation: 7)
    let expected = [
        ExpectedEntry(start: -2, composition: original),
        ExpectedEntry(start: 0, composition: finite),
        ExpectedEntry(start: 2, composition: clear),
        ExpectedEntry(start: 4, composition: twoRegions),
    ]
    for index in [3, 1, 0, 2] {
        let entry = expected[index]
        guard timeline.insert(entry.composition, at: entry.start, generation: 7) else {
            throw DriverError.insertionRejected("authored transitions")
        }
    }
    let queries: [Double] = [-3, -2, -1, -0.0, 0, 0.25.nextDown, 0.25, 0.25.nextUp,
                             1, 2, 3, 4, 5.25.nextDown, 5.25, 5.25.nextUp, 10,
                             .nan, -.infinity, .infinity]
    try append(Fixture(name: "authored_expiry_and_clear", timeline: timeline, entries: expected,
                       queryTimes: [], budget: budget),
               queries: queries, phase: "no_resurrection")

    timeline.prune(before: 3)
    try append(Fixture(name: "pruned_history", timeline: timeline, entries: Array(expected.suffix(2)),
                       queryTimes: [], budget: budget),
               queries: queries, phase: "kept_predecessor")

    timeline.reset(generation: 8)
    try append(Fixture(name: "reset_empty", timeline: timeline, entries: [],
                       queryTimes: [], budget: budget),
               queries: queries, phase: "empty")

    guard timeline.insert(original, at: 0.0, generation: 8),
          timeline.insert(alternate, at: -0.0, generation: 8) else {
        throw DriverError.insertionRejected("signed-zero replacement")
    }
    try append(Fixture(name: "signed_zero_replacement", timeline: timeline,
                       entries: [ExpectedEntry(start: -0.0, composition: alternate)],
                       queryTimes: [], budget: budget),
               queries: [-Double.leastNonzeroMagnitude, -0.0, 0.0, Double.leastNonzeroMagnitude, 1],
               phase: "replacement_payload")

    let overflow = NativeBitmapSubtitleComposition(
        regions: original.regions, canvasSize: original.canvasSize,
        duration: Double.greatestFiniteMagnitude, memoryLease: original.memoryLease
    )
    var large = BitmapSubtitleTimeline()
    large.reset(generation: 7)
    guard large.insert(overflow, at: Double.greatestFiniteMagnitude, generation: 7) else {
        throw DriverError.insertionRejected("finite-overflow expiry")
    }
    try append(Fixture(name: "finite_expiry_sum_overflow", timeline: large,
                       entries: [ExpectedEntry(start: Double.greatestFiniteMagnitude, composition: overflow)],
                       queryTimes: [], budget: budget),
               queries: [Double.greatestFiniteMagnitude.nextDown, Double.greatestFiniteMagnitude,
                         .infinity, -.infinity, .nan], phase: "finite_guard")

    precondition(Set(rows.map(\.name)).count == rows.count)
    return Verification(rows: rows, states: states)
}

private func cpuNanoseconds() -> UInt64 {
    var time = timespec()
    precondition(clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &time) == 0)
    return UInt64(time.tv_sec) * 1_000_000_000 + UInt64(time.tv_nsec)
}

private struct Measurement: Encodable {
    let workload: String
    let occupancy: Int
    let queryTimes: [Double]
    let iterations: Int
    let warmupIterations: Int
    let elapsedNanoseconds: UInt64
    let cpuNanoseconds: UInt64
    let checksum: UInt64
    let cycleChecksum: UInt64
    let warmupChecksum: UInt64
    let first: QueryReceipt
    let last: QueryReceipt
}

private func measure(_ name: String, iterations: Int) throws -> Measurement {
    precondition(iterations > 0 && iterations % 16 == 0)
    guard let configuration = configurations().first(where: { $0.name == name }) else {
        throw DriverError.unknownWorkload(name)
    }
    let fixture = try makeFixture(configuration)
    var expectedCycle: UInt64 = 0
    for seconds in fixture.queryTimes {
        let selected = read(fixture.timeline, at: seconds)
        guard QueryReceipt(seconds: seconds, selected: selected)
                == QueryReceipt(seconds: seconds, selected: fixture.expected(at: seconds)) else {
            throw DriverError.mismatch("timed fixture \(name)")
        }
        expectedCycle &+= digest(fixture.expected(at: seconds))
    }
    let cycle = exercise(fixture, iterations: 16)
    precondition(cycle == expectedCycle, "Cycle checksum mismatch")
    let warmupIterations = 4_096
    let warmup = exercise(fixture, iterations: warmupIterations)
    precondition(warmup == cycle &* UInt64(warmupIterations / 16), "Warmup checksum mismatch")
    let cpuStart = cpuNanoseconds()
    let wallStart = DispatchTime.now().uptimeNanoseconds
    let checksum = exercise(fixture, iterations: iterations)
    let elapsed = DispatchTime.now().uptimeNanoseconds - wallStart
    let cpu = cpuNanoseconds() - cpuStart
    precondition(checksum == cycle &* UInt64(iterations / 16), "Timed checksum mismatch")
    let output = Measurement(
        workload: name, occupancy: fixture.entries.count, queryTimes: fixture.queryTimes,
        iterations: iterations, warmupIterations: warmupIterations,
        elapsedNanoseconds: elapsed, cpuNanoseconds: cpu, checksum: checksum,
        cycleChecksum: cycle, warmupChecksum: warmup,
        first: QueryReceipt(seconds: fixture.queryTimes[0],
                            selected: read(fixture.timeline, at: fixture.queryTimes[0])),
        last: QueryReceipt(seconds: fixture.queryTimes[15],
                           selected: read(fixture.timeline, at: fixture.queryTimes[15]))
    )
    withExtendedLifetime(fixture.budget) {}
    return output
}

@main
private enum Main {
    static func main() throws {
        let arguments = CommandLine.arguments
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data: Data
        if arguments.count == 2 && arguments[1] == "list" {
            data = try encoder.encode(configurations().map(\.name).sorted())
        } else if arguments.count == 2 && arguments[1] == "verify" {
            data = try encoder.encode(verify())
        } else if arguments.count == 4 && arguments[1] == "measure", let iterations = Int(arguments[3]) {
            data = try encoder.encode(measure(arguments[2], iterations: iterations))
        } else {
            fatalError("Usage: benchmark list | benchmark verify | benchmark measure CASE ITERATIONS")
        }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([10]))
    }
}
