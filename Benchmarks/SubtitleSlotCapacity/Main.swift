import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// Compiled with complete production packer/region/budget declarations by
// run.py. Verification and measurement use separate processes: verification
// deliberately retains three immutable snapshots and independent byte copies.
// Measurement defaults to the latest frame; optional held3 retains frame values
// without independent byte copies to exercise Data copy-on-write ownership.
private struct HarnessError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private struct Input {
    let regions: [ASSRenderedRegion]
    let canvas: CGSize
    let strategy: SubtitleCompositionStrategy
    let size: String
}

private struct Workload {
    static let names = ["r8", "bitmap", "bgra"].flatMap { family in
        ["spike", "stable-small", "stable-large", "delayed-large"].map { "\(family)-\($0)" }
    }

    let name: String
    let isLarge: [Bool]
    let small: [Input]
    let large: [Input]

    init(_ name: String) throws {
        guard Self.names.contains(name), let separator = name.firstIndex(of: "-") else {
            throw HarnessError("Unknown case: \(name)")
        }
        self.name = name
        let family = String(name[..<separator])
        switch String(name[name.index(after: separator)...]) {
        case "spike": isLarge = [true, false, false, false, false, false]
        case "stable-small": isLarge = Array(repeating: false, count: 6)
        case "stable-large": isLarge = Array(repeating: true, count: 6)
        case "delayed-large": isLarge = [true, false, false, true]
        default: throw HarnessError("Unknown sequence: \(name)")
        }
        small = isLarge.contains(false) ? [UInt8(37), 149].map {
            Self.input(family: family, large: false, value: $0)
        } : []
        large = isLarge.contains(true) ? [UInt8(37), 149].map {
            Self.input(family: family, large: true, value: $0)
        } : []
    }

    func input(at index: Int) -> Input {
        (isLarge[index] ? large : small)[index % 2]
    }

    var inputPayloadBytes: Int {
        (small + large).reduce(0) { total, input in
            total + input.regions.reduce(0) { $0 + $1.bitmap.count }
        }
    }

    private static func input(family: String, large: Bool, value: UInt8) -> Input {
        let regions: [ASSRenderedRegion]
        let canvas: CGSize
        let strategy: SubtitleCompositionStrategy
        switch family {
        case "r8":
            regions = large ? (0..<3).map {
                region(width: 1_920, height: 1_080, x: $0, value: value)
            } : [region(width: 384, height: 64, value: value)]
            canvas = CGSize(width: 3_840, height: 2_160)
            strategy = .metalR8Atlas
        case "bitmap":
            regions = [region(width: large ? 1_920 : 700, height: large ? 1_080 : 96,
                              value: value, bitmap: true)]
            canvas = CGSize(width: 3_840, height: 2_160)
            strategy = .metalR8Atlas
        default:
            // Compatibility CPU BGRA, distinct from the production bitmap
            // atlas above. Source glyph cost stays fixed when canvas changes.
            regions = [region(width: 384, height: 64, x: 24, y: 40, value: value)]
            canvas = large ? CGSize(width: 1_920, height: 1_080) : CGSize(width: 640, height: 360)
            strategy = .metalBGRA
        }
        return Input(regions: regions, canvas: canvas, strategy: strategy,
                     size: large ? "large" : "small")
    }

    private static func region(width: Int, height: Int, x: Int = 0, y: Int = 0,
                               value: UInt8, bitmap: Bool = false) -> ASSRenderedRegion {
        let bytesPerPixel = bitmap ? 4 : 1
        return ASSRenderedRegion(
            bitmap: Data(repeating: value, count: width * height * bytesPerPixel),
            color: 0xDFA73F21,
            frame: CGRect(x: x, y: y, width: width, height: height),
            stride: width * bytesPerPixel,
            isPremultipliedBGRA: bitmap
        )
    }
}

private func prepare(_ input: Input, using packer: ASSSubtitleFramePacker) throws -> ASSPreparedSubtitleFrame {
    guard let frame = packer.prepare(regions: input.regions, canvasSize: input.canvas,
                                     strategy: input.strategy) else {
        throw HarnessError("Unexpected preparation rejection")
    }
    return frame
}

private func fullHash(_ pixels: Data, count: Int) -> String {
    let hash = pixels.withUnsafeBytes { bytes in
        bytes.bindMemory(to: UInt8.self).prefix(count).reduce(UInt64(0xcbf29ce484222325)) {
            ($0 ^ UInt64($1)) &* 0x100000001b3
        }
    }
    return String(format: "%016llx", hash)
}

private func validateExtent(_ frame: ASSPreparedSubtitleFrame) throws {
    let active = frame.metrics.uploadBytes
    guard active > 0, frame.pixels.count >= active,
          frame.bytesPerRow * Int(frame.textureSize.height) == active else {
        throw HarnessError("Prepared frame does not cover its active upload extent")
    }
}

private func tailIsZero(_ frame: ASSPreparedSubtitleFrame) -> Bool {
    frame.pixels.withUnsafeBytes { bytes in
        bytes.bindMemory(to: UInt8.self).dropFirst(frame.metrics.uploadBytes).allSatisfy { $0 == 0 }
    }
}

private struct FrameObservation {
    let index: Int
    let size: String
    let strategy: String
    let canvas: CGSize
    let texture: CGSize
    let rowBytes: Int
    let quads: [ASSAtlasQuad]
    let bitmap: Bool
    let metrics: ASSCompositionMetrics
    let selectedSlotBytes: Int
    let otherSlotBytes: Int
    let retainedBytes: Int
    let budgetBytes: Int
    let wallNanoseconds: UInt64
    let cpuNanoseconds: UInt64
    let minorFaults: Int64

    init(index: Int, input: Input, frame: ASSPreparedSubtitleFrame,
         packer: ASSSubtitleFramePacker, budget: SubtitleMemoryBudget,
         wallNanoseconds: UInt64 = 0, cpuNanoseconds: UInt64 = 0, minorFaults: Int64 = 0) throws {
        try validateExtent(frame)
        self.index = index
        size = input.size
        strategy = frame.strategy.rawValue
        canvas = frame.canvasSize
        texture = frame.textureSize
        rowBytes = frame.bytesPerRow
        quads = frame.quads
        bitmap = frame.usesBitmapAtlas
        metrics = frame.metrics
        selectedSlotBytes = frame.pixels.count
        retainedBytes = packer.retainedStorageByteCountForTesting
        otherSlotBytes = retainedBytes - selectedSlotBytes
        let reservation = budget.snapshot
        budgetBytes = reservation.reservedBytes
        guard otherSlotBytes >= 0, retainedBytes == budgetBytes,
              reservation.reservationsByOwner[.mainStaging] == retainedBytes,
              reservation.rejectedAcquisitions == 0 else {
            throw HarnessError("Reusable storage and subtitle budget disagree")
        }
        self.wallNanoseconds = wallNanoseconds
        self.cpuNanoseconds = cpuNanoseconds
        self.minorFaults = minorFaults
    }

    // Contains no pixel Data. Keeping observations cannot retain snapshots or
    // introduce a packer copy-on-write path during measurement.
    var json: [String: Any] {
        ["index": index, "size": size, "strategy": strategy,
         "canvas": [Double(canvas.width), Double(canvas.height)],
         "texture": [Double(texture.width), Double(texture.height)],
         "bytes_per_row": rowBytes, "uses_bitmap_atlas": bitmap,
         "quads": quads.map { quad in
             ["source": [Double(quad.source.minX), Double(quad.source.minY),
                         Double(quad.source.width), Double(quad.source.height)],
              "destination": [Double(quad.destination.minX), Double(quad.destination.minY),
                              Double(quad.destination.width), Double(quad.destination.height)],
              "color": quad.color] as [String: Any]
         },
         "image_count": metrics.imageCount, "copied_bytes": metrics.copiedBytes,
         "active_bytes": metrics.uploadBytes, "draw_calls": metrics.drawCalls,
         "atlas_width": metrics.atlasWidth, "atlas_height": metrics.atlasHeight,
         "atlas_reallocated": metrics.atlasReallocated,
         "clear_bytes": metrics.atlasClearBytes,
         "selected_slot_bytes": selectedSlotBytes, "other_slot_bytes": otherSlotBytes,
         "retained_bytes": retainedBytes, "budget_reserved_bytes": budgetBytes,
         "elapsed_ns": wallNanoseconds, "cpu_seconds": Double(cpuNanoseconds) / 1_000_000_000,
         "minor_faults": minorFaults]
    }

    var semanticJSON: [String: Any] {
        var result = json
        for key in ["clear_bytes", "selected_slot_bytes", "other_slot_bytes", "retained_bytes",
                    "budget_reserved_bytes", "elapsed_ns", "cpu_seconds", "minor_faults"] {
            result.removeValue(forKey: key)
        }
        return result
    }
}

private struct Snapshot {
    let frame: ASSPreparedSubtitleFrame
    let original: [UInt8]

    init(_ frame: ASSPreparedSubtitleFrame) {
        self.frame = frame
        // A separately allocated Array, not a Data alias, detects accidental
        // mutations even if Foundation copy-on-write ownership were broken.
        original = frame.pixels.withUnsafeBytes { Array($0) }
    }

    func verify() throws {
        let matches = frame.pixels.withUnsafeBytes { actual in
            original.withUnsafeBytes { expected in
                actual.count == expected.count
                    && (actual.isEmpty || memcmp(actual.baseAddress!, expected.baseAddress!, actual.count) == 0)
            }
        }
        guard matches else { throw HarnessError("A retained prepared frame changed") }
    }
}

private func verify(_ workload: Workload) throws -> [String: Any] {
    let budget = SubtitleMemoryBudget()
    let packer = ASSSubtitleFramePacker(memoryBudget: budget)
    defer { withExtendedLifetime(budget) {} }
    var held: [Snapshot] = []
    var semanticFrames: [[String: Any]] = []
    var storageFrames: [[String: Any]] = []
    var snapshotChecks = 0
    for index in workload.isLarge.indices {
        let input = workload.input(at: index)
        let frame = try prepare(input, using: packer)
        let fresh = try prepare(input, using: ASSSubtitleFramePacker())
        try validateExtent(frame)
        try validateExtent(fresh)
        guard fresh.pixels.count == frame.metrics.uploadBytes,
              frame.strategy == fresh.strategy, frame.canvasSize == fresh.canvasSize,
              frame.textureSize == fresh.textureSize, frame.bytesPerRow == fresh.bytesPerRow,
              frame.quads == fresh.quads, frame.usesBitmapAtlas == fresh.usesBitmapAtlas,
              frame.metrics.imageCount == fresh.metrics.imageCount,
              frame.metrics.copiedBytes == fresh.metrics.copiedBytes,
              frame.metrics.drawCalls == fresh.metrics.drawCalls,
              frame.pixels.withUnsafeBytes({ actual in
                  fresh.pixels.withUnsafeBytes { expected in
                      memcmp(actual.baseAddress!, expected.baseAddress!, expected.count) == 0
                  }
              }), tailIsZero(frame) else {
            throw HarnessError("Prepared output differs from fresh packing: \(workload.name), frame \(index)")
        }
        for snapshot in held {
            try snapshot.verify()
            snapshotChecks += 1
        }
        let observation = try FrameObservation(index: index, input: input, frame: frame,
                                                packer: packer, budget: budget)
        var semantic = observation.semanticJSON
        semantic["active_fnv1a64"] = fullHash(frame.pixels, count: frame.metrics.uploadBytes)
        semanticFrames.append(semantic)
        var storage = observation.json
        storage["zero_tail"] = true
        storage["full_snapshot_fnv1a64"] = fullHash(frame.pixels, count: frame.pixels.count)
        storageFrames.append(storage)
        if held.count == 3 { held.removeFirst() }
        held.append(Snapshot(frame))
    }
    packer.retireSource()
    guard packer.retainedStorageByteCountForTesting == 0, budget.snapshot.reservedBytes == 0 else {
        throw HarnessError("Source retirement did not release reusable storage and reservation")
    }
    // Reuse the retired packer while the preceding source's snapshots remain
    // alive. Retirement must not mutate any immutable prepared-frame output.
    _ = try prepare(workload.input(at: workload.isLarge.count - 1), using: packer)
    for snapshot in held {
        try snapshot.verify()
        snapshotChecks += 1
    }
    return ["schema": 1, "mode": "verify", "case": workload.name, "status": "passed",
            "frame_count": semanticFrames.count, "maximum_held_snapshots": 3,
            "independent_snapshot_checks": snapshotChecks,
            "source_retirement_released_storage": true,
            "parity": semanticFrames, "storage_frames": storageFrames]
}

private struct Usage {
    let cpuNanoseconds: UInt64
    let peakRSSBytes: UInt64
    let minorFaults: Int64
}

private func usage() throws -> Usage {
    var value = rusage()
    #if os(Linux)
    let result = getrusage(Int32(RUSAGE_SELF.rawValue), &value)
    #else
    let result = getrusage(RUSAGE_SELF, &value)
    #endif
    guard result == 0 else { throw HarnessError("getrusage failed") }
    let seconds = UInt64(value.ru_utime.tv_sec) + UInt64(value.ru_stime.tv_sec)
    let microseconds = UInt64(value.ru_utime.tv_usec) + UInt64(value.ru_stime.tv_usec)
    #if os(Linux)
    let peakBytes = UInt64(value.ru_maxrss) * 1_024
    #else
    let peakBytes = UInt64(value.ru_maxrss)
    #endif
    return Usage(cpuNanoseconds: seconds * 1_000_000_000 + microseconds * 1_000,
                 peakRSSBytes: peakBytes, minorFaults: Int64(value.ru_minflt))
}

private func memoryCheckpoint() throws -> [String: Any] {
    #if os(Linux)
    let status = try String(contentsOfFile: "/proc/self/status", encoding: .utf8)
    guard let line = status.split(separator: "\n").first(where: { $0.hasPrefix("VmRSS:") }),
          let kilobytes = UInt64(line.split(whereSeparator: { $0.isWhitespace })[1]) else {
        throw HarnessError("Could not read current VmRSS")
    }
    return ["resident_bytes": kilobytes * 1_024,
            "peak_rss_bytes": try usage().peakRSSBytes,
            "physical_footprint_bytes": NSNull(),
            "resident_source": "/proc/self/status:VmRSS"]
    #elseif canImport(Darwin)
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    guard result == KERN_SUCCESS else { throw HarnessError("TASK_VM_INFO failed: \(result)") }
    return ["resident_bytes": UInt64(info.resident_size),
            "peak_rss_bytes": try usage().peakRSSBytes,
            "physical_footprint_bytes": UInt64(info.phys_footprint),
            "resident_source": "task_info:TASK_VM_INFO"]
    #else
    throw HarnessError("Memory checkpoints require Linux or macOS")
    #endif
}

private func measure(_ workload: Workload, heldCount: Int = 1) throws -> [String: Any] {
    let budget = SubtitleMemoryBudget()
    let packer = ASSSubtitleFramePacker(memoryBudget: budget)
    var latest: ASSPreparedSubtitleFrame?
    var held: [ASSPreparedSubtitleFrame] = []
    if heldCount == 3 { held.reserveCapacity(3) }
    var observations: [FrameObservation] = []
    observations.reserveCapacity(workload.isLarge.count)
    let before = try memoryCheckpoint()
    for index in workload.isLarge.indices {
        let input = workload.input(at: index)
        let usageBefore = try usage()
        let started = DispatchTime.now().uptimeNanoseconds
        latest = try prepare(input, using: packer)
        let elapsed = DispatchTime.now().uptimeNanoseconds - started
        let usageAfter = try usage()
        guard let frame = latest else { throw HarnessError("Missing measured frame") }
        observations.append(try FrameObservation(
            index: index, input: input, frame: frame, packer: packer, budget: budget,
            wallNanoseconds: elapsed,
            cpuNanoseconds: usageAfter.cpuNanoseconds - usageBefore.cpuNanoseconds,
            minorFaults: usageAfter.minorFaults - usageBefore.minorFaults
        ))
        if heldCount == 3 {
            // Keep three prior frame values alive during the next preparation,
            // exceeding the two reusable slots and exercising real Data COW.
            // Queue updates are untimed; no oracle arrays or byte copies exist.
            if held.count == 3 { held.removeFirst() }
            held.append(frame)
        }
    }
    // No byte hashing, fresh oracle, independent byte copies, or JSON encoding
    // happens before this checkpoint. Keep both inputs and current owners alive.
    let after = try withExtendedLifetime((workload, packer, budget, latest, held)) {
        try memoryCheckpoint()
    }
    guard let final = latest else { throw HarnessError("No measured output") }
    return ["schema": 1, "mode": "measure", "case": workload.name,
            "frame_count": observations.count, "maximum_latest_snapshots": 1,
            "retained_snapshot_limit": heldCount,
            "retained_snapshot_count": heldCount == 3 ? held.count : 1,
            "input_payload_bytes": workload.inputPayloadBytes,
            "memory_before": before, "memory": after,
            "total_wall_ns": observations.reduce(UInt64(0)) { $0 + $1.wallNanoseconds },
            "total_cpu_ns": observations.reduce(UInt64(0)) { $0 + $1.cpuNanoseconds },
            "frames": observations.map(\.json),
            "final_active_fnv1a64": fullHash(final.pixels, count: final.metrics.uploadBytes),
            "final_zero_tail": tailIsZero(final),
            "checkpoint_before_output_hashing": true]
}

@main
private enum SubtitleSlotCapacityBenchmark {
    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let result: Any
        switch arguments.first {
        case "list" where arguments.count == 1:
            result = Workload.names
        case "verify" where arguments.count == 1:
            result = try Workload.names.map { try verify(Workload($0)) }
        case "verify" where arguments.count == 2:
            result = try verify(Workload(arguments[1]))
        case "measure" where arguments.count == 2:
            result = try measure(Workload(arguments[1]))
        case "measure" where arguments.count == 3:
            guard let heldCount = Int(arguments[2]), heldCount == 1 || heldCount == 3 else {
                throw HarnessError("HOLD_COUNT must be 1 or 3")
            }
            result = try measure(Workload(arguments[1]), heldCount: heldCount)
        default:
            throw HarnessError("Usage: binary list | verify [CASE] | measure CASE [1|3]")
        }
        let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        guard let text = String(data: data, encoding: .utf8) else { throw HarnessError("JSON encoding failed") }
        print(text)
    }
}
