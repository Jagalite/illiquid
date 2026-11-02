import CLeaseHeap
import Foundation

private let capacity = 4096
private let rootPaths = ["/media/movies", "/media/shows", "/Volumes/External/Library"]

private struct NativeEntry {
    let cString: [CChar]?
    let flags: SourceFilesystemEvent.Flags

    init(path: String?, flags: SourceFilesystemEvent.Flags = [.created]) {
        cString = path.map { Array($0.utf8CString) }
        self.flags = flags
    }

    init(bytes: [UInt8], flags: SourceFilesystemEvent.Flags = [.created]) {
        cString = bytes.map { CChar(bitPattern: $0) } + [0]
        self.flags = flags
    }
}

/// Owns genuine, stable C strings and the native-style pointer/flag arrays.
/// Construction and destruction of this input are outside both measurements.
private final class NativeBatch {
    let paths: [UnsafePointer<CChar>?]
    let flags: [SourceFilesystemEvent.Flags]
    let validCount: Int
    private let storage: UnsafeMutablePointer<CChar>
    private let initializedBytes: Int

    init(rawCount: Int, validCapacity: Int, bytesPerPath: Int = 129,
         entryAt: (Int) -> NativeEntry) {
        let byteCapacity = max(1, validCapacity * bytesPerPath)
        let storage = UnsafeMutablePointer<CChar>.allocate(capacity: byteCapacity)
        var paths = [UnsafePointer<CChar>?](repeating: nil, count: rawCount)
        var flags = [SourceFilesystemEvent.Flags](repeating: [], count: rawCount)
        var offset = 0
        var validCount = 0
        for index in 0..<rawCount {
            let entry = entryAt(index)
            flags[index] = entry.flags
            guard let bytes = entry.cString else { continue }
            precondition(offset + bytes.count <= byteCapacity)
            let destination = storage.advanced(by: offset)
            bytes.withUnsafeBufferPointer { bytes in
                destination.initialize(from: bytes.baseAddress!, count: bytes.count)
            }
            paths[index] = UnsafePointer(destination)
            offset += bytes.count
            validCount += 1
        }
        self.paths = paths
        self.flags = flags
        self.validCount = validCount
        self.storage = storage
        initializedBytes = offset
    }

    convenience init(_ entries: [NativeEntry]) {
        let validCount = entries.reduce(0) { $0 + ($1.cString == nil ? 0 : 1) }
        let longest = entries.compactMap { $0.cString?.count }.max() ?? 1
        self.init(rawCount: entries.count, validCapacity: validCount, bytesPerPath: longest) {
            entries[$0]
        }
    }

    deinit {
        storage.deinitialize(count: initializedBytes)
        storage.deallocate()
    }
}

private enum Workload: String {
    case normal64, normal512, boundary4096, overflow4097
    case overflow100000, overflow1000000, sparse8192_4096, sparse100000_1, null100000

    var rawCount: Int {
        switch self {
        case .normal64: 64
        case .normal512: 512
        case .boundary4096: 4096
        case .overflow4097: 4097
        case .overflow100000, .sparse100000_1, .null100000: 100000
        case .overflow1000000: 1000000
        case .sparse8192_4096: 8192
        }
    }

    var validCount: Int {
        switch self {
        case .sparse8192_4096: 4096
        case .sparse100000_1: 1
        case .null100000: 0
        default: rawCount
        }
    }

    func hasPath(at index: Int) -> Bool {
        switch self {
        case .sparse8192_4096: index.isMultiple(of: 2)
        case .sparse100000_1: index == rawCount - 1
        case .null100000: false
        default: true
        }
    }

    func fixture() -> NativeBatch {
        NativeBatch(rawCount: rawCount, validCapacity: validCount) { index in
            guard hasPath(at: index) else {
                // Loss flags on nil slots must never be inspected or admitted.
                return NativeEntry(path: nil, flags: [.eventsDropped])
            }
            return NativeEntry(path: paddedPath(index))
        }
    }
}

private func paddedPath(_ index: Int) -> String {
    let prefix = rootPaths[index % rootPaths.count] + "/Group\(index % 32)/"
    let suffix = "-\(index).mkv"
    return prefix + String(repeating: "m", count: 128 - prefix.utf8.count - suffix.utf8.count) + suffix
}

private struct EventReceipt: Codable, Equatable {
    let path: String
    let raw_flags: UInt16

    init(_ event: SourceFilesystemEvent) {
        path = event.path
        raw_flags = event.flags.rawValue
    }
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

private struct CaseReceipt: Codable {
    let name: String
    let raw_count: Int
    let valid_count: Int
    let decoded_count: Int
    let flags_reads: Int
    let decoded_events: [EventReceipt]?
    let buffered_events: [EventReceipt]
    let plan: PlanReceipt
}

private struct Verification: Codable {
    let cases: [CaseReceipt]
}

private func verifyCase(_ name: String, _ fixture: NativeBatch,
                        roots: [String] = rootPaths) -> CaseReceipt {
    var readIndices: [Int] = []
    let decoded = fixture.paths.withUnsafeBufferPointer { paths in
        SourceFilesystemEventBatch.decode(paths: paths) { index in
            readIndices.append(index)
            return fixture.flags[index]
        }
    }
    // An independent direct reconstruction checks the exact original C-string
    // and skipped-nil semantics before differential receipts leave the process.
    let validIndices = fixture.paths.indices.filter { fixture.paths[$0] != nil }
    let expected = validIndices.map { index in
        SourceFilesystemEvent(path: String(cString: fixture.paths[index]!), flags: fixture.flags[index])
    }
    precondition(validIndices.count == fixture.validCount)
    if fixture.validCount <= capacity {
        precondition(decoded == expected && readIndices == validIndices)
    } else {
        // The same harness also runs the original, unbounded implementation.
        let original = decoded == expected && readIndices == validIndices
        let bounded = decoded == [.init(path: "/", flags: [.eventsDropped])] && readIndices.isEmpty
        precondition(original || bounded)
    }
    var referenceBuffer = SourceFilesystemEventBuffer()
    referenceBuffer.append(contentsOf: expected)
    var buffer = SourceFilesystemEventBuffer()
    buffer.append(contentsOf: decoded)
    let buffered = buffer.take()
    precondition(buffered == referenceBuffer.take())
    let plan = SourceFilesystemInvalidationPlanner.plan(
        events: buffered, roots: roots.map { URL(fileURLWithPath: $0, isDirectory: true) }
    )
    if fixture.validCount > capacity {
        precondition(plan == SourceFilesystemInvalidationPlan(rootsToRescan: Set(roots)))
    }
    return CaseReceipt(name: name, raw_count: fixture.paths.count, valid_count: fixture.validCount,
        decoded_count: decoded.count, flags_reads: readIndices.count,
        decoded_events: fixture.validCount <= capacity ? decoded.map(EventReceipt.init) : nil,
        buffered_events: buffered.map(EventReceipt.init), plan: PlanReceipt(plan))
}

private func verify() -> Verification {
    var cases: [CaseReceipt] = []
    cases.append(verifyCase("empty", NativeBatch([])))
    cases.append(verifyCase("single", NativeBatch([NativeEntry(path: "/media/movies/Movie.mkv")])))
    cases.append(verifyCase("unicode_nil_and_empty", NativeBatch([
        NativeEntry(path: nil, flags: [.eventsDropped]),
        NativeEntry(path: "/media/movies/映画 Café.mkv", flags: [.created, .renamed]),
        NativeEntry(path: nil, flags: [.directory, .eventsDropped]),
        NativeEntry(path: "/media/shows/Cafe\u{301}/S01E01.mkv", flags: [.removed]),
        NativeEntry(path: "", flags: []),
        NativeEntry(path: "/", flags: [.mustScanSubdirectories]),
    ])))
    cases.append(verifyCase("cstring_decoding", NativeBatch([
        NativeEntry(bytes: [47, 109, 101, 100, 105, 97, 47, 0x80, 0xff, 46, 109, 107, 118]),
        NativeEntry(bytes: Array("/media/movies/Before.mkv".utf8) + [0] + Array("ignored".utf8)),
    ])))
    let flags: [SourceFilesystemEvent.Flags] = [[], .directory, .created, .removed, .renamed,
        .mustScanSubdirectories, .eventIDsWrapped, .rootChanged, .init(rawValue: 1 << 12)]
    cases.append(verifyCase("all_flag_kinds", NativeBatch(flags.enumerated().map { index, flags in
        NativeEntry(path: "/media/movies/Group\(index)/Film.mkv", flags: flags)
    })))
    for marker in [0, 3, 6] {
        cases.append(verifyCase("native_loss_\(marker)", NativeBatch((0..<7).map { index in
            NativeEntry(path: "/media/movies/Film\(index).mkv",
                flags: index == marker ? [.eventsDropped, .mustScanSubdirectories] : [.created])
        })))
    }
    for workload in [Workload.normal64, .boundary4096, .overflow4097, .sparse8192_4096,
                     .sparse100000_1, .null100000] {
        cases.append(verifyCase(workload.rawValue, workload.fixture()))
    }
    let mixedOverflow = NativeBatch(rawCount: 8194, validCapacity: 4097) { index in
        index.isMultiple(of: 2) ? NativeEntry(path: paddedPath(index))
            : NativeEntry(path: nil, flags: [.eventsDropped])
    }
    cases.append(verifyCase("overflow_with_null_slots", mixedOverflow))
    cases.append(verifyCase("overflow_with_no_roots", mixedOverflow, roots: []))
    let duplicateOverflow = NativeBatch(rawCount: 4097, validCapacity: 4097) { _ in
        NativeEntry(path: "/media/movies/Same.mkv")
    }
    cases.append(verifyCase("duplicate_paths_still_overflow", duplicateOverflow))
    return Verification(cases: cases)
}

/// No inlining keeps the returned array observable to the optimizer. Only a
/// small fixed amount of result consumption belongs to the timing interval.
@inline(never)
private func consume(_ events: [SourceFilesystemEvent]) -> UInt64 {
    var value = UInt64(events.count) &* 1_099_511_628_211
    if let first = events.first {
        value = (value &+ UInt64(first.flags.rawValue)) &* 1_099_511_628_211
        value &+= UInt64(first.path.utf8.count)
    }
    if let last = events.last {
        value = (value &+ UInt64(last.flags.rawValue)) &* 1_099_511_628_211
        value &+= UInt64(last.path.utf8.count)
    }
    return value
}

/// The array and its strings are destroyed before returning to the timer.
@inline(never)
private func timedOperation(_ fixture: NativeBatch) -> UInt64 {
    fixture.paths.withUnsafeBufferPointer { paths in
        let events = SourceFilesystemEventBatch.decode(paths: paths) { fixture.flags[$0] }
        return consume(events)
    }
}

@inline(never)
private func warmup(_ fixture: NativeBatch) {
    _ = timedOperation(fixture)
    _ = timedOperation(fixture)
    precondition(lease_history_allocator_bytes() > 0)
}

private struct MemorySample {
    let returnedEvents: Int
    let pathBytes: Int
    let deltaBytes: Int64
    let flagsReads: Int
}

@inline(never)
private func memorySample(_ fixture: NativeBatch) -> MemorySample {
    var flagsReads = 0
    let before = lease_history_allocator_bytes()
    let events = fixture.paths.withUnsafeBufferPointer { paths in
        SourceFilesystemEventBatch.decode(paths: paths) { index in
            flagsReads += 1
            return fixture.flags[index]
        }
    }
    let after = withExtendedLifetime(events) { lease_history_allocator_bytes() }
    // Do not touch array elements or build receipts before the live sample.
    let count = events.count
    let bytes = events.reduce(0) { $0 + $1.path.utf8.count }
    return withExtendedLifetime(events) {
        MemorySample(returnedEvents: count, pathBytes: bytes,
            deltaBytes: Int64(after) - Int64(before), flagsReads: flagsReads)
    }
}

private struct Measurement: Codable {
    let workload: String
    let iterations: Int
    let elapsed_ns: UInt64
    let process_cpu_ns: UInt64
    let checksum: UInt64
    let returned_events: Int
    let callback_path_bytes: Int
    let live_allocator_delta_bytes: Int64
    let flags_reads: Int
    let allocator_metric: String
}

@inline(never)
private func measure(_ workload: Workload, iterations: Int) -> Measurement {
    let fixture = workload.fixture()
    warmup(fixture)
    let memory = memorySample(fixture)
    var checksum: UInt64 = 0
    let cpuStart = lease_history_process_cpu_ns()
    let start = DispatchTime.now().uptimeNanoseconds
    for _ in 0..<iterations { checksum &+= timedOperation(fixture) }
    let elapsed = DispatchTime.now().uptimeNanoseconds - start
    let cpuElapsed = lease_history_process_cpu_ns() - cpuStart
    return withExtendedLifetime(fixture) {
        Measurement(workload: workload.rawValue, iterations: iterations, elapsed_ns: elapsed,
            process_cpu_ns: cpuElapsed, checksum: checksum, returned_events: memory.returnedEvents,
            callback_path_bytes: memory.pathBytes, live_allocator_delta_bytes: memory.deltaBytes,
            flags_reads: memory.flagsReads,
            allocator_metric: String(cString: lease_history_allocator_metric()))
    }
}

@main
private enum FilesystemEventBatchHarness {
    static func main() throws {
        let arguments = CommandLine.arguments
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let output: Data
        if arguments.count == 2, arguments[1] == "verify" {
            output = try encoder.encode(verify())
        } else if arguments.count == 4, arguments[1] == "measure",
                  let workload = Workload(rawValue: arguments[2]),
                  let iterations = Int(arguments[3]), iterations > 0 {
            output = try encoder.encode(measure(workload, iterations: iterations))
        } else {
            fatalError("Usage: FilesystemEventBatch verify | measure WORKLOAD ITERATIONS")
        }
        FileHandle.standardOutput.write(output)
        FileHandle.standardOutput.write(Data([10]))
    }
}
