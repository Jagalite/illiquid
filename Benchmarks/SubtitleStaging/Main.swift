import Foundation

// Compiled against the actual ASSSubtitleFramePacker and its value types by
// run.py. The same driver is used for the pinned baseline and candidate.
private struct StagingWorkload {
    let name: String
    let warmRegions: [ASSRenderedRegion]
    let sampleRegions: [ASSRenderedRegion]
    let warmCanvas: CGSize
    let sampleCanvas: CGSize
    let strategy: SubtitleCompositionStrategy

    var alternateSampleRegions: [ASSRenderedRegion] {
        sampleRegions.map { region in
            ASSRenderedRegion(
                bitmap: Data(repeating: 67, count: region.bitmap.count),
                color: region.color,
                frame: region.frame,
                stride: region.stride,
                bitmapSize: region.bitmapSize,
                isPremultipliedBGRA: region.isPremultipliedBGRA
            )
        }
    }

    static func named(_ name: String) throws -> StagingWorkload {
        let baseName = name.hasSuffix("-held3") ? String(name.dropLast(6)) : name
        let largeCanvas = CGSize(width: 3_840, height: 2_160)
        let smallR8 = [region(width: 384, height: 64)]
        let mediumR8 = (0..<3).map {
            region(width: 1_300, height: 240, x: $0)
        }
        let largeR8 = (0..<3).map {
            region(width: 1_920, height: 1_080, x: $0)
        }
        let smallBitmap = [region(width: 700, height: 96, bitmap: true)]
        let largeBitmap = [region(width: 1_920, height: 1_080, bitmap: true)]

        let warm: [ASSRenderedRegion]
        let sample: [ASSRenderedRegion]
        var warmCanvas = largeCanvas
        var sampleCanvas = largeCanvas
        var strategy = SubtitleCompositionStrategy.metalR8Atlas
        switch baseName {
        case "r8-small-stable":
            warm = smallR8
            sample = smallR8
        case "r8-large-stable":
            warm = largeR8
            sample = largeR8
        case "r8-medium-to-small":
            warm = mediumR8
            sample = smallR8
        case "r8-large-to-small":
            warm = largeR8
            sample = smallR8
        case "bitmap-small-stable":
            warm = smallBitmap
            sample = smallBitmap
        case "bitmap-large-stable":
            warm = largeBitmap
            sample = largeBitmap
        case "bitmap-large-to-small":
            warm = largeBitmap
            sample = smallBitmap
        case "bgra-small-stable", "bgra-large-stable", "bgra-large-to-small":
            // This is the CPU BGRA compatibility strategy. Production bitmap
            // subtitles exercise prepareAtlas(bytesPerPixel: 4) above.
            warm = [region(width: 384, height: 64, x: 24, y: 40)]
            sample = warm
            strategy = .metalBGRA
            warmCanvas = baseName == "bgra-small-stable"
                ? CGSize(width: 640, height: 360)
                : CGSize(width: 1_920, height: 1_080)
            sampleCanvas = baseName == "bgra-large-stable"
                ? CGSize(width: 1_920, height: 1_080)
                : CGSize(width: 640, height: 360)
        default:
            throw HarnessError("Unknown workload: \(name)")
        }
        return StagingWorkload(
            name: name,
            warmRegions: warm,
            sampleRegions: sample,
            warmCanvas: warmCanvas,
            sampleCanvas: sampleCanvas,
            strategy: strategy
        )
    }

    static func region(
        width: Int,
        height: Int,
        x: Int = 0,
        y: Int = 0,
        value: UInt8 = 233,
        bitmap: Bool = false
    ) -> ASSRenderedRegion {
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

private struct HarnessError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private struct HeldFrames {
    private var frames: [ASSPreparedSubtitleFrame?]
    private var next = 0

    init(count: Int) {
        frames = Array(repeating: nil, count: count)
    }

    mutating func retain(_ frame: ASSPreparedSubtitleFrame) {
        guard !frames.isEmpty else { return }
        frames[next] = frame
        next = (next + 1) % frames.count
    }

    func checksum() -> UInt64 {
        frames.reduce(UInt64(0)) { result, frame in
            guard let frame else { return result }
            return result &+ sampleChecksum(frame)
        }
    }
}

private func prepared(
    _ packer: ASSSubtitleFramePacker,
    regions: [ASSRenderedRegion],
    canvas: CGSize,
    strategy: SubtitleCompositionStrategy
) throws -> ASSPreparedSubtitleFrame {
    guard let frame = packer.prepare(
        regions: regions,
        canvasSize: canvas,
        strategy: strategy
    ) else {
        throw HarnessError("Frame preparation unexpectedly failed")
    }
    return frame
}

private func sampleChecksum(_ frame: ASSPreparedSubtitleFrame) -> UInt64 {
    guard frame.metrics.uploadBytes > 0 else { return 0 }
    let activeBytes = frame.metrics.uploadBytes
    let bytesPerPixel = frame.strategy == .metalBGRA ? 4 : 1
    let origin = frame.quads.first.map {
        Int($0.source.minY) * frame.bytesPerRow
            + Int($0.source.minX) * bytesPerPixel
    } ?? 0
    // Observe both texture content and padding without hashing the whole
    // allocation inside the timed loop. verify hashes and checks every byte.
    // (26, 42) is inside the CPU BGRA workload's glyph as well as the
    // nonempty atlas workloads, so alternating source bytes are observed.
    let contentProbe = min(42 * frame.bytesPerRow + 26 * bytesPerPixel, activeBytes - 1)
    let offsets = [0, activeBytes / 2, activeBytes - 1, min(origin, activeBytes - 1), contentProbe]
    return frame.pixels.withUnsafeBytes { raw in
        let bytes = raw.bindMemory(to: UInt8.self)
        return offsets.reduce(UInt64(0xcbf29ce484222325)) {
            ($0 ^ UInt64(bytes[$1])) &* 0x100000001b3
        }
    }
}

private func fullHash(_ pixels: Data) -> String {
    let hash = pixels.withUnsafeBytes { raw in
        raw.bindMemory(to: UInt8.self).reduce(UInt64(0xcbf29ce484222325)) {
            ($0 ^ UInt64($1)) &* 0x100000001b3
        }
    }
    return String(format: "%016llx", hash)
}

private func printJSON(_ object: Any) throws {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    guard let text = String(data: data, encoding: .utf8) else {
        throw HarnessError("Could not encode JSON output")
    }
    print(text)
}

private func benchmark(
    workload: StagingWorkload,
    iterations: Int,
    heldCount: Int
) throws -> [String: Any] {
    let budget = SubtitleMemoryBudget()
    defer { withExtendedLifetime(budget) {} }
    let packer = ASSSubtitleFramePacker(memoryBudget: budget)
    // Construct equal-geometry variants before timing. Different source
    // bytes model changed subtitle frames, for which production prepares a
    // texture; this harness deliberately does not time the presentation gate.
    let samples = [workload.sampleRegions, workload.alternateSampleRegions]
    // Populate both rotating slots. Measurements exclude initial allocation
    // and each slot's first cleanup after the large-to-small transition.
    for _ in 0..<2 {
        _ = try prepared(
            packer,
            regions: workload.warmRegions,
            canvas: workload.warmCanvas,
            strategy: workload.strategy
        )
    }
    var held = HeldFrames(count: heldCount)
    for index in 0..<max(8, heldCount + 2) {
        held.retain(try prepared(
            packer,
            regions: samples[index % samples.count],
            canvas: workload.sampleCanvas,
            strategy: workload.strategy
        ))
    }

    var checksum: UInt64 = 0
    var activeBytes = 0
    var logicalClearBytes = 0
    let start = DispatchTime.now().uptimeNanoseconds
    for index in 0..<iterations {
        let frame = try prepared(
            packer,
            regions: samples[index % samples.count],
            canvas: workload.sampleCanvas,
            strategy: workload.strategy
        )
        checksum &+= sampleChecksum(frame)
        activeBytes = frame.metrics.uploadBytes
        logicalClearBytes += frame.metrics.atlasClearBytes
        held.retain(frame)
    }
    let elapsed = DispatchTime.now().uptimeNanoseconds - start
    checksum &+= held.checksum()
    return [
        "case": workload.name,
        "held_count": heldCount,
        "iterations": iterations,
        "elapsed_ns": elapsed,
        "ns_per_frame": Double(elapsed) / Double(iterations),
        "checksum": String(format: "%016llx", checksum),
        "active_bytes": activeBytes,
        "retained_bytes": packer.retainedStorageByteCountForTesting,
        "budget_reserved_bytes": budget.snapshot.reservedBytes,
        // Before the fix this existing metric reports active bytes even when
        // resetBytes clears the high-water count. Preserve that observation.
        "logical_clear_bytes_per_frame": Double(logicalClearBytes) / Double(iterations),
    ]
}

private func transition(
    workload: StagingWorkload,
    heldCount: Int
) throws -> [String: Any] {
    let budget = SubtitleMemoryBudget()
    defer { withExtendedLifetime(budget) {} }
    let packer = ASSSubtitleFramePacker(memoryBudget: budget)
    let samples = [workload.sampleRegions, workload.alternateSampleRegions]
    var held = HeldFrames(count: heldCount)
    for _ in 0..<2 {
        held.retain(try prepared(
            packer,
            regions: workload.warmRegions,
            canvas: workload.warmCanvas,
            strategy: workload.strategy
        ))
    }
    var frames: [[String: Any]] = []
    for index in 0..<6 {
        let start = DispatchTime.now().uptimeNanoseconds
        let frame = try prepared(
            packer,
            regions: samples[index % samples.count],
            canvas: workload.sampleCanvas,
            strategy: workload.strategy
        )
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        held.retain(frame)
        frames.append([
            "index": index,
            "elapsed_ns": elapsed,
            "active_bytes": frame.metrics.uploadBytes,
            "retained_bytes": packer.retainedStorageByteCountForTesting,
            "logical_clear_bytes": frame.metrics.atlasClearBytes,
            "checksum": String(format: "%016llx", sampleChecksum(frame)),
        ])
    }
    return ["case": workload.name, "held_count": heldCount, "frames": frames]
}

private struct SnapshotOracle {
    let frame: ASSPreparedSubtitleFrame
    let originalBytes: [UInt8]

    init(_ frame: ASSPreparedSubtitleFrame) {
        self.frame = frame
        // A copied Array is independent storage. A second Data value could
        // alias the frame and hide accidental mutation of a held snapshot.
        originalBytes = frame.pixels.withUnsafeBytes { Array($0) }
    }

    func verify() throws {
        guard frame.pixels.withUnsafeBytes({ $0.elementsEqual(originalBytes) }) else {
            throw HarnessError("A retained frame changed after another preparation")
        }
    }
}

private func frameReceipt(
    _ frame: ASSPreparedSubtitleFrame,
    label: String,
    retainedBytes: Int
) -> [String: Any] {
    [
        "label": label,
        "strategy": frame.strategy.rawValue,
        "canvas": [Double(frame.canvasSize.width), Double(frame.canvasSize.height)],
        "texture": [Double(frame.textureSize.width), Double(frame.textureSize.height)],
        "bytes_per_row": frame.bytesPerRow,
        "pixels_count": frame.pixels.count,
        "full_data_fnv1a64": fullHash(frame.pixels),
        "uses_bitmap_atlas": frame.usesBitmapAtlas,
        "retained_bytes": retainedBytes,
        "quads": frame.quads.map { quad -> [String: Any] in
            [
                "source": [Double(quad.source.minX), Double(quad.source.minY),
                           Double(quad.source.width), Double(quad.source.height)],
                "destination": [Double(quad.destination.minX), Double(quad.destination.minY),
                                Double(quad.destination.width), Double(quad.destination.height)],
                "color": quad.color,
            ]
        },
        // Corrected clear accounting intentionally differs. Every other
        // preparation metric is part of the differential receipt.
        "metrics": [
            "image_count": frame.metrics.imageCount,
            "copied_bytes": frame.metrics.copiedBytes,
            "upload_bytes": frame.metrics.uploadBytes,
            "draw_calls": frame.metrics.drawCalls,
            "atlas_width": frame.metrics.atlasWidth,
            "atlas_height": frame.metrics.atlasHeight,
            "atlas_reallocated": frame.metrics.atlasReallocated,
        ],
    ]
}

private func verify() throws -> [String: Any] {
    let budget = SubtitleMemoryBudget()
    defer { withExtendedLifetime(budget) {} }
    let packer = ASSSubtitleFramePacker(memoryBudget: budget)
    var snapshots: [SnapshotOracle] = []
    var receipts: [[String: Any]] = []
    var snapshotChecks = 0
    let canvas = CGSize(width: 3_840, height: 2_160)

    let sequence: [(String, [ASSRenderedRegion], CGSize, SubtitleCompositionStrategy)] = [
        ("large-r8-a", [StagingWorkload.region(width: 1_300, height: 240, value: 17)], canvas, .metalR8Atlas),
        ("large-r8-b", [StagingWorkload.region(width: 1_920, height: 700, value: 31)], canvas, .metalR8Atlas),
        ("tiny-r8-a", [StagingWorkload.region(width: 5, height: 3, value: 53)], canvas, .metalR8Atlas),
        ("tiny-r8-b", [StagingWorkload.region(width: 7, height: 4, value: 71)], canvas, .metalR8Atlas),
        ("tiny-r8-reuse-a", [StagingWorkload.region(width: 4, height: 2, value: 89)], canvas, .metalR8Atlas),
        ("empty-atlas", [], canvas, .metalR8Atlas),
        ("large-bitmap-a", [StagingWorkload.region(width: 1_024, height: 512, value: 107, bitmap: true)], canvas, .metalR8Atlas),
        ("large-bitmap-b", [StagingWorkload.region(width: 1_400, height: 700, value: 127, bitmap: true)], canvas, .metalR8Atlas),
        ("tiny-bitmap-a", [StagingWorkload.region(width: 11, height: 6, value: 149, bitmap: true)], canvas, .metalR8Atlas),
        ("tiny-bitmap-b", [StagingWorkload.region(width: 9, height: 5, value: 167, bitmap: true)], canvas, .metalR8Atlas),
        ("tiny-bitmap-reuse-a", [StagingWorkload.region(width: 8, height: 3, value: 181, bitmap: true)], canvas, .metalR8Atlas),
        ("return-to-r8", [StagingWorkload.region(width: 17, height: 6, value: 199)], canvas, .metalR8Atlas),
        ("large-bgra-a", [StagingWorkload.region(width: 31, height: 15, x: 7, y: 11, value: 43)], CGSize(width: 1_920, height: 1_080), .metalBGRA),
        ("large-bgra-b", [StagingWorkload.region(width: 35, height: 13, x: 9, y: 17, value: 73)], CGSize(width: 1_024, height: 768), .metalBGRA),
        ("small-bgra-a", [StagingWorkload.region(width: 15, height: 7, x: 3, y: 4, value: 113)], CGSize(width: 64, height: 32), .metalBGRA),
        ("small-bgra-b", [StagingWorkload.region(width: 12, height: 6, x: 4, y: 5, value: 151)], CGSize(width: 48, height: 24), .metalBGRA),
        ("empty-bgra", [], CGSize(width: 40, height: 20), .metalBGRA),
        ("small-bgra-reuse", [StagingWorkload.region(width: 8, height: 3, x: 2, y: 1, value: 197)], CGSize(width: 32, height: 16), .metalBGRA),
    ]
    for (label, regions, frameCanvas, strategy) in sequence {
        let frame = try prepared(packer, regions: regions, canvas: frameCanvas, strategy: strategy)
        for snapshot in snapshots {
            try snapshot.verify()
            snapshotChecks += 1
        }
        receipts.append(frameReceipt(
            frame,
            label: label,
            retainedBytes: packer.retainedStorageByteCountForTesting
        ))
        snapshots.append(SnapshotOracle(frame))
        // Three externally held frames exceed the two reusable slots and
        // force copy-on-write, while bounding the verifier's own memory.
        if snapshots.count > 3 { snapshots.removeFirst() }
    }

    let retainedBeforeRejection = packer.retainedStorageByteCountForTesting
    let malformed = ASSRenderedRegion(
        bitmap: Data([1]),
        color: 0,
        frame: CGRect(x: 0, y: 0, width: 8, height: 8),
        stride: 1
    )
    guard packer.prepare(regions: [malformed], canvasSize: canvas, strategy: .metalR8Atlas) == nil,
          packer.retainedStorageByteCountForTesting == retainedBeforeRejection
    else {
        throw HarnessError("Malformed input was accepted or changed storage")
    }
    packer.retireSource()
    guard packer.retainedStorageByteCountForTesting == 0,
          budget.snapshot.reservedBytes == 0 else {
        throw HarnessError("Source retirement did not release staging storage")
    }
    for snapshot in snapshots {
        try snapshot.verify()
        snapshotChecks += 1
    }
    for strategy in [SubtitleCompositionStrategy.metalR8Atlas, .metalBGRA] {
        for index in 0..<3 {
            let frame = try prepared(
                packer,
                regions: [StagingWorkload.region(width: 4, height: 3, value: UInt8(37 + index * 29))],
                canvas: CGSize(width: 32, height: 16),
                strategy: strategy
            )
            for snapshot in snapshots {
                try snapshot.verify()
                snapshotChecks += 1
            }
            receipts.append(frameReceipt(
                frame,
                label: "after-retirement-\(strategy.rawValue)-\(index)",
                retainedBytes: packer.retainedStorageByteCountForTesting
            ))
        }
    }
    return [
        "schema": 1,
        "status": "passed",
        "frame_count": receipts.count,
        "independent_snapshot_checks": snapshotChecks,
        "maximum_held_snapshots": 3,
        "malformed_input_rejected": true,
        "source_retirement_released_storage": true,
        "frames": receipts,
    ]
}

@main
private enum SubtitleStagingBenchmark {
    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let command = arguments.first else {
            throw HarnessError("Usage: binary list | verify | benchmark CASE ITERATIONS HOLD_COUNT | transition CASE HOLD_COUNT")
        }
        if command == "list", arguments.count == 1 {
            let cases: [(String, Int, Int)] = [
                ("r8-small-stable", 10_000, 1),
                ("r8-large-stable", 200, 1),
                ("r8-medium-to-small", 3_000, 1),
                ("r8-large-to-small", 1_500, 1),
                ("bitmap-small-stable", 3_000, 1),
                ("bitmap-large-stable", 200, 1),
                ("bitmap-large-to-small", 1_500, 1),
                ("bgra-small-stable", 700, 1),
                ("bgra-large-stable", 200, 1),
                ("bgra-large-to-small", 700, 1),
                ("r8-large-to-small-held3", 150, 3),
                ("bitmap-large-to-small-held3", 150, 3),
            ]
            try printJSON(cases.map { name, iterations, heldCount -> [String: Any] in
                ["case": name, "iterations": iterations, "held_count": heldCount]
            })
            return
        }
        if command == "verify", arguments.count == 1 {
            try printJSON(verify())
            return
        }
        if command == "benchmark", arguments.count == 4,
           let iterations = Int(arguments[2]), (1...1_000_000).contains(iterations),
           let heldCount = Int(arguments[3]), (0...8).contains(heldCount)
        {
            try printJSON(benchmark(
                workload: StagingWorkload.named(arguments[1]),
                iterations: iterations,
                heldCount: heldCount
            ))
            return
        }
        if command == "transition", arguments.count == 3,
           let heldCount = Int(arguments[2]), (0...8).contains(heldCount)
        {
            try printJSON(transition(
                workload: StagingWorkload.named(arguments[1]),
                heldCount: heldCount
            ))
            return
        }
        throw HarnessError("Invalid arguments: \(arguments.joined(separator: " "))")
    }
}
