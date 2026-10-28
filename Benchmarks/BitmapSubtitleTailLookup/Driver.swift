import CoreGraphics
import Darwin
import Dispatch
import Foundation
@testable import IlliquidNativePlayback

private enum DriverError: Error {
    case usage
    case mismatch(String)
    case clock
}

private enum Position: Equatable {
    case empty, first, middle, penultimate, latest, before, frames, expired, clear, invalid, sweep
    case fourth, fifth, eighth, tail
}

private struct Workload {
    let name: String
    let count: Int
    let position: Position

    init(_ name: String) throws {
        self.name = name
        switch name {
        case "empty": count = 0; position = .empty
        case "single-latest": count = 1; position = .latest
        case "single-before": count = 1; position = .before
        default:
            let parts = name.split(separator: "-")
            guard parts.count == 2, let count = Int(parts[1]) else { throw DriverError.usage }
            let allowed: [Int]
            let position: Position
            switch parts[0] {
            case "first": allowed = [2, 4, 8, 32, 128]; position = .first
            case "middle": allowed = [8, 32, 128]; position = .middle
            case "penultimate": allowed = [2, 4, 8, 32, 128]; position = .penultimate
            case "latest": allowed = [2, 4, 8, 32, 128]; position = .latest
            case "before": allowed = [8, 128]; position = .before
            case "frames": allowed = [4, 8, 32, 128]; position = .frames
            case "expired": allowed = [128]; position = .expired
            case "clear": allowed = [128]; position = .clear
            case "invalid": allowed = [128]; position = .invalid
            case "sweep": allowed = [128]; position = .sweep
            case "fourth": allowed = [8, 32, 128]; position = .fourth
            case "tail": allowed = [8, 32, 128]; position = .tail
            case "fifth": allowed = [128]; position = .fifth
            case "eighth": allowed = [128]; position = .eighth
            default: throw DriverError.usage
            }
            guard allowed.contains(count) else { throw DriverError.usage }
            self.count = count
            self.position = position
        }
    }
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
    mutating func shuffle(_ values: inout [Int]) {
        guard values.count > 1 else { return }
        for index in stride(from: values.count - 1, through: 1, by: -1) {
            values.swapAt(index, Int(next() % UInt64(index + 1)))
        }
    }
}

private typealias Selection = (start: Double, value: NativeBitmapSubtitleComposition)

private struct RegionReceipt: Encodable, Equatable {
    let pixels: [UInt8]
    let frameBits: [UInt64]
    let forced: Bool
    init(_ value: NativeBitmapSubtitleRegion) {
        pixels = Array(value.pixels)
        frameBits = [value.frame.minX, value.frame.minY, value.frame.width, value.frame.height]
            .map { Double($0).bitPattern }
        forced = value.isForced
    }
}

private struct CompositionReceipt: Encodable, Equatable {
    let regions: [RegionReceipt]
    let canvasBits: [UInt64]
    let durationBits: UInt64?
    let leaseOwner: String?
    init(_ value: NativeBitmapSubtitleComposition) {
        regions = value.regions.map(RegionReceipt.init)
        canvasBits = [Double(value.canvasSize.width).bitPattern, Double(value.canvasSize.height).bitPattern]
        durationBits = value.duration?.bitPattern
        leaseOwner = value.memoryLease?.owner.rawValue
    }
}

private struct QueryReceipt: Encodable, Equatable {
    let queryBits: UInt64
    let startBits: UInt64?
    let value: CompositionReceipt?
    init(_ seconds: Double, _ selection: Selection?) {
        queryBits = seconds.bitPattern
        startBits = selection?.start.bitPattern
        value = selection.map { CompositionReceipt($0.value) }
    }
}

private struct Receipt: Encodable, Equatable {
    let generation: Int
    let revision: UInt64
    let retainedBytes: Int
    let reservedBytes: Int
    let queries: [QueryReceipt]
}

private struct Counts: Equatable {
    var checksum: UInt64 = 0
    var present: UInt64 = 0
}

// Consume payload-dependent fields without turning a lookup experiment into a
// bitmap-hashing benchmark. Complete returned values are checked outside timing.
@inline(__always)
private func score(_ selected: Selection?) -> UInt64 {
    guard let selected else { return 0x42d0_0319_9aa7_87d5 }
    return selected.start.bitPattern
        &+ (selected.value.duration?.bitPattern ?? 0x19d6_3ad4_1760_0ec7)
        &+ UInt64(selected.value.regions.count)
        &+ UInt64(selected.value.regions.first?.pixels.first ?? 0)
}

private struct Fixture {
    let timeline: BitmapSubtitleTimeline
    let expectedEntries: [Selection]
    let queries: [Double]
    let budget: SubtitleMemoryBudget

    init(_ workload: Workload, seed: UInt64) throws {
        let budget = SubtitleMemoryBudget(limitBytes: 4096)
        // Every occupancy fits within a 30-second buffered timestamp window.
        let step = 30.0 / Double(max(1, workload.count))
        var entries: [Selection] = []
        for index in 0..<workload.count {
            let marker = UInt8(truncatingIfNeeded: seed &+ UInt64(index * 17))
            let pixels = Data([marker, 32, 64, 255, marker ^ 0xff, 16, 32, 255,
                               64, marker, 16, 255, 32, 64, marker, 255])
            let regions: [NativeBitmapSubtitleRegion] = index % 4 == 2 ? [] : [
                NativeBitmapSubtitleRegion(
                    pixels: pixels,
                    frame: CGRect(x: CGFloat(index % 24), y: CGFloat(index % 7), width: 2, height: 2),
                    isForced: index.isMultiple(of: 2)
                )
            ]
            let duration: Double? = index % 4 == 1 ? 0.25 * step : (index % 4 == 3 ? 0.625 * step : nil)
            let lease = regions.isEmpty ? nil : budget.acquire(owner: .bitmapEvents, bytes: pixels.count)
            guard regions.isEmpty || lease != nil else { throw DriverError.mismatch("fixture lease") }
            let composition = NativeBitmapSubtitleComposition(
                regions: regions,
                canvasSize: CGSize(width: index.isMultiple(of: 2) ? 1920 : 1280,
                                   height: index.isMultiple(of: 2) ? 1080 : 720),
                duration: duration, memoryLease: lease
            )
            entries.append((60 + Double(index) * step, composition))
        }
        var random = Random(state: seed)
        var order = Array(entries.indices)
        random.shuffle(&order)
        var timeline = BitmapSubtitleTimeline(maximumEntries: 128, maximumBytes: 4096)
        timeline.reset(generation: 7)
        for index in order {
            guard timeline.insert(entries[index].value, at: entries[index].start, generation: 7) else {
                throw DriverError.mismatch("fixture insertion")
            }
        }

        let queries: [Double]
        switch workload.position {
        case .empty:
            queries = (0..<64).map { 60 + Double($0) / 16 }
        case .invalid:
            let values = [Double.nan, Double.infinity, -Double.infinity]
            queries = (0..<64).map { values[$0 % values.count] }
        case .before:
            queries = (0..<64).map { entries[0].start - step * (0.5 + Double($0 % 4) / 64) }
        case .frames:
            // Two seconds of 60 Hz lookups while future events remain buffered.
            // This describes the query cadence; no sleeping or display is used.
            queries = (0..<120).map { entries[0].start + Double($0) / 60 }
        case .sweep:
            random.shuffle(&order)
            queries = order.map { entries[$0].start + step * ($0 % 4 == 1 ? 0.375 : 0.0625) }
        case .tail:
            // Balance all eight tail distances, then randomize their order.
            var positions = (0..<64).map { workload.count - 1 - ($0 % 8) }
            random.shuffle(&positions)
            queries = positions.enumerated().map { item in
                entries[item.element].start + step * Double(item.offset % 4) / 64
            }
        default:
            let index: Int
            switch workload.position {
            case .first: index = 0
            case .middle: index = workload.count / 2
            case .penultimate: index = workload.count - 2
            case .latest: index = workload.count - 1
            case .fourth: index = workload.count - 4
            case .fifth: index = workload.count - 5
            case .eighth: index = workload.count - 8
            case .expired: index = workload.count / 2 + 1
            case .clear: index = workload.count / 2 + 2
            default: throw DriverError.usage
            }
            let offset = workload.position == .expired ? 0.375 : 0.0
            queries = (0..<64).map { entries[index].start + step * (offset + Double($0 % 4) / 64) }
        }
        self.timeline = timeline
        expectedEntries = entries
        self.queries = queries
        self.budget = budget
    }

    private func oracle(_ seconds: Double) -> Selection? {
        guard seconds.isFinite else { return nil }
        var selected: Selection?
        // Independent linear reference. Expiry never resurrects an older set.
        for entry in expectedEntries where entry.start <= seconds { selected = entry }
        guard let selected else { return nil }
        if let duration = selected.value.duration, seconds >= selected.start + duration { return nil }
        return selected
    }

    var expectedCycle: Counts {
        queries.reduce(into: Counts()) { counts, seconds in
            let selected = oracle(seconds)
            counts.checksum &+= score(selected)
            if selected != nil { counts.present &+= 1 }
        }
    }

    func verify() throws -> Receipt {
        let expectedBytes = expectedEntries.reduce(0) { $0 + $1.value.byteCount }
        guard timeline.generation == 7, timeline.revision == UInt64(expectedEntries.count + 1),
              timeline.retainedBytes == expectedBytes,
              budget.snapshot.reservedBytes == expectedBytes,
              budget.snapshot.rejectedAcquisitions == 0 else {
            throw DriverError.mismatch("unchanged timeline and leases")
        }
        let receipts = try queries.map { seconds in
            let actual = timeline.composition(at: seconds)
            let expected = oracle(seconds)
            let receipt = QueryReceipt(seconds, actual)
            guard receipt == QueryReceipt(seconds, expected),
                  actual?.value.memoryLease === expected?.value.memoryLease else {
                throw DriverError.mismatch("complete selected composition")
            }
            return receipt
        }
        return Receipt(generation: timeline.generation, revision: timeline.revision,
                       retainedBytes: timeline.retainedBytes, reservedBytes: budget.snapshot.reservedBytes,
                       queries: receipts)
    }
}

@inline(never)
private func exercise(_ timeline: BitmapSubtitleTimeline, queries: [Double], iterations: Int) -> Counts {
    var result = Counts()
    for _ in 0..<iterations {
        for seconds in queries {
            let selected = timeline.composition(at: seconds)
            result.checksum &+= score(selected)
            if selected != nil { result.present &+= 1 }
        }
    }
    return result
}

private func cpuNanoseconds() throws -> UInt64 {
    var value = timespec()
    guard clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &value) == 0 else { throw DriverError.clock }
    return UInt64(value.tv_sec) * 1_000_000_000 + UInt64(value.tv_nsec)
}

private struct Output: Encodable {
    let caseName: String
    let iterations: Int
    let seed: UInt64
    let elapsed_ns: UInt64
    let cpu_ns: UInt64
    let checksum: UInt64
    let present_queries: UInt64
    let operations_per_iteration: Int
    let queries_per_iteration: Int
    let receipt: Receipt

    enum CodingKeys: String, CodingKey {
        case caseName = "case"
        case iterations, seed, elapsed_ns, cpu_ns, checksum, present_queries
        case operations_per_iteration, queries_per_iteration, receipt
    }
}

@main
private struct Driver {
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count == 4, let iterations = Int(args[2]), iterations > 0,
              let seed = UInt64(args[3]) else { throw DriverError.usage }
        let workload = try Workload(args[1])
        let fixture = try Fixture(workload, seed: seed)
        guard iterations <= Int.max / fixture.queries.count else { throw DriverError.usage }
        let cycle = fixture.expectedCycle
        for _ in 0..<3 {
            let warm = exercise(fixture.timeline, queries: fixture.queries, iterations: 32)
            guard warm == Counts(checksum: cycle.checksum &* 32, present: cycle.present * 32) else {
                throw DriverError.mismatch("warmup checksum")
            }
        }
        let before = try fixture.verify()
        let cpuStart = try cpuNanoseconds()
        let wallStart = DispatchTime.now().uptimeNanoseconds
        let measured = exercise(fixture.timeline, queries: fixture.queries, iterations: iterations)
        let wallElapsed = DispatchTime.now().uptimeNanoseconds &- wallStart
        let cpuElapsed = try cpuNanoseconds() &- cpuStart
        let receipt = try fixture.verify()
        guard receipt == before,
              measured == Counts(checksum: cycle.checksum &* UInt64(iterations),
                                 present: cycle.present * UInt64(iterations)) else {
            throw DriverError.mismatch("timed checksum and unchanged full receipt")
        }
        let output = Output(
            caseName: workload.name, iterations: iterations, seed: seed,
            elapsed_ns: wallElapsed, cpu_ns: cpuElapsed, checksum: measured.checksum,
            present_queries: measured.present, operations_per_iteration: fixture.queries.count,
            queries_per_iteration: fixture.queries.count, receipt: receipt
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(output)
        data.append(0x0a)
        FileHandle.standardOutput.write(data)
    }
}
