import CLeaseHeap
import Foundation

// MeasuredBuffer is either the unchanged production buffer or a wrapper around
// the original sidebar's extracted array declaration, append, and drain lines.
private let rootPaths = ["/media/movies", "/media/shows", "/Volumes/External/Library"]
private let capacity = 4096

private struct EventReceipt: Codable, Equatable {
    let path: String
    let flags: UInt16
}

private struct PlanReceipt: Codable, Equatable {
    let directories: [String]
    let trees: [String]
    let roots: [String]

    init(_ plan: SourceFilesystemInvalidationPlan) {
        directories = plan.directoriesToReload.sorted()
        trees = plan.treesToInvalidate.sorted()
        roots = plan.rootsToRescan.sorted()
    }
}

private struct ParityReceipt: Codable, Equatable {
    let count: Int
    let batchSize: Int
    let events: [EventReceipt]
    let plan: PlanReceipt
}

private struct Verification: Codable {
    let parity: [ParityReceipt]
    let lossPlans: [PlanReceipt]
    let recoveryChecks: Int
}

private struct Measurement: Codable {
    let inputEvents: Int
    let batchSize: Int
    let lossMarker: Bool
    let retainedEvents: Int
    let peakBufferedEventsAfterAppend: Int
    let retainedPathUTF8Bytes: Int
    let bufferCountAfterDrain: Int
    let allocatorMetric: String
    let allocatorBeforeInputBytes: UInt64
    let allocatorAfterInputBytes: UInt64
    let allocatorRetainedDeltaBytes: Int64
    let elapsedNanoseconds: UInt64
}

private func event(_ index: Int, lossMarker: Bool = false) -> SourceFilesystemEvent {
    let prefix = rootPaths[index % rootPaths.count] + "/Group\(index % 32)/"
    let suffix = "-\(index).mkv"
    let length = 96 + index % 65
    let path = prefix + String(repeating: "m", count: length - prefix.utf8.count - suffix.utf8.count) + suffix
    let flags: SourceFilesystemEvent.Flags
    if lossMarker && index == 64 {
        flags = [.eventsDropped]
    } else {
        switch index % 4 {
        case 0: flags = [.created]
        case 1: flags = [.removed]
        case 2: flags = [.renamed, .directory]
        default: flags = []
        }
    }
    return .init(path: path, flags: flags)
}

// Keep each callback-sized input array in a separate, non-inlined scope. The
// allocator sample is taken only after every temporary batch has gone away.
@inline(never)
private func appendBatch(start: Int, count: Int, lossMarker: Bool, to buffer: inout MeasuredBuffer) {
    let events = (start..<(start + count)).map { event($0, lossMarker: lossMarker) }
    buffer.append(contentsOf: events)
}

@inline(never)
private func fill(_ buffer: inout MeasuredBuffer, count: Int, batchSize: Int, lossMarker: Bool = false) -> Int {
    var peak = 0
    var offset = 0
    while offset < count {
        let length = min(batchSize, count - offset)
        appendBatch(start: offset, count: length, lossMarker: lossMarker, to: &buffer)
        peak = max(peak, buffer.count)
        offset += length
    }
    return peak
}

private func plan(_ events: [SourceFilesystemEvent]) -> SourceFilesystemInvalidationPlan {
    SourceFilesystemInvalidationPlanner.plan(
        events: events,
        roots: rootPaths.map { URL(fileURLWithPath: $0, isDirectory: true) }
    )
}

private func requireFullRescan(_ events: [SourceFilesystemEvent]) {
    precondition(plan(events) == SourceFilesystemInvalidationPlan(rootsToRescan: Set(rootPaths)))
}

@inline(never)
private func warmup() {
    var buffer = MeasuredBuffer()
    _ = fill(&buffer, count: 128, batchSize: 128)
    precondition(buffer.take().count == 128)
    buffer.removeAll()
    // Initialize the allocator accessor before the measured fixture.
    precondition(lease_history_allocator_bytes() > 0)
}

private func measure(count: Int, batchSize: Int, lossMarker: Bool) -> Measurement {
    warmup()
    var buffer = MeasuredBuffer()
    let before = lease_history_allocator_bytes()
    let start = DispatchTime.now().uptimeNanoseconds
    let peak = fill(&buffer, count: count, batchSize: batchSize, lossMarker: lossMarker)
    let elapsed = DispatchTime.now().uptimeNanoseconds - start
    let after = withExtendedLifetime(buffer) { lease_history_allocator_bytes() }

    // Summarization and planning intentionally happen AFTER the heap sample.
    let retained = buffer.count
    let events = buffer.take()
    precondition(events.count == retained && buffer.count == 0)
    let pathBytes = events.reduce(0) { $0 + $1.path.utf8.count }
    #if CANDIDATE_BUFFER
    precondition(peak <= capacity)
    if count > capacity || lossMarker {
        precondition(retained == 1)
        requireFullRescan(events)
    } else {
        precondition(retained == count)
    }
    #else
    precondition(retained == count && peak == count)
    #endif
    return Measurement(
        inputEvents: count, batchSize: batchSize, lossMarker: lossMarker,
        retainedEvents: retained, peakBufferedEventsAfterAppend: peak,
        retainedPathUTF8Bytes: pathBytes, bufferCountAfterDrain: buffer.count,
        allocatorMetric: String(cString: lease_history_allocator_metric()),
        allocatorBeforeInputBytes: before, allocatorAfterInputBytes: after,
        allocatorRetainedDeltaBytes: Int64(after) - Int64(before),
        elapsedNanoseconds: elapsed
    )
}

private func verify() -> Verification {
    var receipts: [ParityReceipt] = []
    let cases = [(0, 128), (1, 1), (127, 128), (128, 128), (512, 1),
                 (512, 31), (512, 128), (4095, 128), (4096, 128), (4096, 4096)]
    for (count, batchSize) in cases {
        var buffer = MeasuredBuffer()
        _ = fill(&buffer, count: count, batchSize: batchSize)
        let events = buffer.take()
        let expected = (0..<count).map { event($0) }
        precondition(events == expected) // Exact path, flag, and arrival order equality.
        precondition(buffer.count == 0)
        let actualPlan = plan(events)
        precondition(actualPlan == plan(expected))
        receipts.append(ParityReceipt(count: count, batchSize: batchSize,
            events: events.map { EventReceipt(path: $0.path, flags: $0.flags.rawValue) },
            plan: PlanReceipt(actualPlan)))
    }

    var lossPlans: [PlanReceipt] = []
    for batchSize in [1, 128, 512] {
        var buffer = MeasuredBuffer()
        _ = fill(&buffer, count: 512, batchSize: batchSize, lossMarker: true)
        let events = buffer.take()
        requireFullRescan(events)
        lossPlans.append(PlanReceipt(plan(events)))
    }

    var recoveryChecks = 0
    #if CANDIDATE_BUFFER
    for (count, batchSize) in [(4097, 128), (8193, 8193), (16384, 31)] {
        var buffer = MeasuredBuffer()
        let peak = fill(&buffer, count: count, batchSize: batchSize)
        precondition(peak <= capacity && buffer.count == 1)
        let marker = buffer.take()
        requireFullRescan(marker)
        precondition(marker.count == 1 && buffer.count == 0)
        _ = fill(&buffer, count: 64, batchSize: 31)
        precondition(buffer.take() == (0..<64).map { event($0) })
        _ = fill(&buffer, count: count, batchSize: batchSize)
        buffer.removeAll()
        _ = fill(&buffer, count: 64, batchSize: 31)
        precondition(buffer.take() == (0..<64).map { event($0) })
        recoveryChecks += 1
    }
    #endif
    return Verification(parity: receipts, lossPlans: lossPlans, recoveryChecks: recoveryChecks)
}

@main
private enum FilesystemEventBufferHarness {
    static func main() throws {
        let arguments = CommandLine.arguments
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let output: Data
        if arguments.count == 2 && arguments[1] == "verify" {
            output = try encoder.encode(verify())
        } else if arguments.count == 5 && arguments[1] == "measure",
                  let count = Int(arguments[2]), let batch = Int(arguments[3]),
                  count > 0, batch > 0, ["ordinary", "loss"].contains(arguments[4]) {
            output = try encoder.encode(measure(count: count, batchSize: batch,
                lossMarker: arguments[4] == "loss"))
        } else {
            fatalError("Usage: FilesystemEventBuffer verify | measure COUNT BATCH ordinary|loss")
        }
        FileHandle.standardOutput.write(output)
        FileHandle.standardOutput.write(Data([10]))
    }
}
