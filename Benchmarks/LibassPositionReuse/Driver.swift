import CoreGraphics
import CryptoKit
import Dispatch
import Foundation
@testable import IlliquidNativePlayback
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

private enum DriverError: Error, CustomStringConvertible {
    case usage
    case failure(String)

    var description: String {
        switch self {
        case .usage:
            return "Usage: driver moving-small|moving-dense|static|content-change|moving-bounded|moving-fractional ITERATIONS SEED"
        case let .failure(message):
            return message
        }
    }
}

private struct Fixture {
    let name: String
    let size: CGSize
    let data: Data
    let times: [Double]
    let maximumImageCount: Int

    init(name: String, seed: UInt64) throws {
        guard ["moving-small", "moving-dense", "static", "content-change", "moving-bounded", "moving-fractional"].contains(name)
        else { throw DriverError.usage }
        self.name = name
        let dense = name == "moving-dense" || name == "moving-bounded" || name == "static"
        let width = dense ? 3840 : 1920
        let height = dense ? 2160 : 1080
        let fontSize = dense ? 96 : 48
        size = CGSize(width: CGFloat(width), height: CGFloat(height))
        maximumImageCount = name == "moving-bounded" ? 8 : 256
        var source = """
        [Script Info]
        ScriptType: v4.00+
        PlayResX: \(width)
        PlayResY: \(height)
        ScaledBorderAndShadow: yes
        WrapStyle: 2

        [V4+ Styles]
        Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
        Style: Default,Arial,\(fontSize),&H00FFFFFF,&H000000FF,&H00000000,&H80000000,0,0,0,0,100,100,0,0,1,2,1,7,0,0,0,1

        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text

        """
        if name == "content-change" {
            // Adjacent events change text while keeping placement fixed.
            times = (0..<64).map { Double($0 * 40 + 10) / 1000 }
            for index in 0..<64 {
                let start = Self.timestamp(centiseconds: index * 4)
                let end = Self.timestamp(centiseconds: (index + 1) * 4)
                source += "Dialogue: 0,\(start),\(end),Default,,0,0,0,,{\\an7\\pos(100,100)}Caption \(index) seed \(seed % 97)\n"
            }
        } else {
            // Most cases use integer placement; moving-fractional deliberately
            // adds subpixel motion as a control and records native change codes.
            times = (0..<64).map { Double(100 + $0 * 40) / 1000 }
            let endX = name == "moving-fractional" ? 901 : 900
            for row in 0..<(dense ? 14 : 1) {
                let y = 100 + row * 140
                let tag = name == "static"
                    ? "{\\an7\\pos(100,\(y))}"
                    : "{\\an7\\move(100,\(y),\(endX),\(y),0,8000)}"
                let text = dense
                    ? "Position-only subtitle motion \(row) seed \(seed % 97)"
                    : "A short moving caption \(seed % 97)"
                source += "Dialogue: 0,0:00:00.00,0:00:08.00,Default,,0,0,0,,\(tag)\(text)\n"
            }
        }
        data = Data(source.utf8)
    }

    private static func timestamp(centiseconds: Int) -> String {
        String(format: "0:%02d:%02d.%02d", centiseconds / 6000,
               (centiseconds / 100) % 60, centiseconds % 100)
    }

    func context() throws -> LibassContext {
        let context = try LibassContext()
        guard context.configure(frameSize: size, storageSize: size) else {
            throw DriverError.failure("Fixture geometry was not configured")
        }
        try context.loadExternal(data: data)
        return context
    }
}

/// Owns exactly the caller state needed by SubtitlePipeline: current regions,
/// plus the optional provenance token in the candidate build.
private final class RenderSequence {
    let context: LibassContext
    let maximumImageCount: Int
    private(set) var regions: [ASSRenderedRegion] = []
    #if POSITION_REUSE
    private var previous: ASSReusableRenderSnapshot?
    #endif

    init(_ fixture: Fixture) throws {
        context = try fixture.context()
        maximumImageCount = fixture.maximumImageCount
    }

    func step(_ seconds: Double) -> ASSRenderResult {
        #if POSITION_REUSE
        let result = context.render(
            at: seconds, copyIfUnchanged: false,
            maximumImageCount: maximumImageCount, reusing: previous
        )
        previous = result.reusableSnapshot
        #else
        let result = context.render(
            at: seconds, copyIfUnchanged: false,
            maximumImageCount: maximumImageCount
        )
        #endif
        if let output = result.regions { regions = output }
        return result
    }
}

private func cpuNanoseconds() -> UInt64 {
    var value = timespec()
    precondition(clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &value) == 0)
    return UInt64(value.tv_sec) * 1_000_000_000 + UInt64(value.tv_nsec)
}

private func hex(_ bytes: some Sequence<UInt8>) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
}

private func hashWord(_ value: UInt64, into hasher: inout SHA256) {
    var bigEndian = value.bigEndian
    withUnsafeBytes(of: &bigEndian) { hasher.update(bufferPointer: $0) }
}

/// Hash every output pixel and the complete geometry/color/layout contract.
/// This is called only outside timing.
private func visualDigest(_ regions: [ASSRenderedRegion]) -> String {
    var hasher = SHA256()
    hashWord(UInt64(regions.count), into: &hasher)
    for region in regions {
        hashWord(UInt64(region.color), into: &hasher)
        for coordinate in [region.frame.minX, region.frame.minY,
                           region.frame.width, region.frame.height] {
            hashWord(Double(coordinate).bitPattern, into: &hasher)
        }
        hashWord(UInt64(region.stride), into: &hasher)
        hashWord(region.isPremultipliedBGRA ? 1 : 0, into: &hasher)
        hashWord(region.memoryLease == nil ? 0 : 1, into: &hasher)
        if let size = region.bitmapSize {
            hashWord(1, into: &hasher)
            hashWord(Double(size.width).bitPattern, into: &hasher)
            hashWord(Double(size.height).bitPattern, into: &hasher)
        } else {
            hashWord(0, into: &hasher)
        }
        hashWord(UInt64(region.bitmap.count), into: &hasher)
        hasher.update(data: region.bitmap)
    }
    return hex(hasher.finalize())
}

private func sameRegions(_ left: [ASSRenderedRegion], _ right: [ASSRenderedRegion]) -> Bool {
    guard left.count == right.count else { return false }
    return zip(left, right).allSatisfy { pair in
        let a = pair.0
        let b = pair.1
        return a.bitmap == b.bitmap && a.color == b.color && a.frame == b.frame
            && a.stride == b.stride && a.bitmapSize == b.bitmapSize
            && a.isPremultipliedBGRA == b.isPremultipliedBGRA
            && (a.memoryLease != nil) == (b.memoryLease != nil)
    }
}

private struct Verification {
    let frames: Int
    let positionChanges: Int
    let contentChanges: Int
    let checksum: String

    var json: [String: Any] {
        [
            "frames": frames, "position_changes": positionChanges,
            "content_changes": contentChanges, "checksum": checksum,
            "reference_parity": true,
        ]
    }
}

private func verify(_ fixture: Fixture) throws -> Verification {
    let sequence = try RenderSequence(fixture)
    let reference = try fixture.context()
    // Include repeated, backwards and expired queries as well as the sweep.
    let times = fixture.times + [0.1, 0.1, 0.14, 8.5, 0.14, 1.0, 0.1]
    var records: [[String: Any]] = []
    var positions = 0
    var contents = 0
    for seconds in times {
        let actual = sequence.step(seconds)
        let expected = reference.render(
            at: seconds, copyIfUnchanged: true,
            maximumImageCount: fixture.maximumImageCount
        )
        guard let expectedRegions = expected.regions,
              sameRegions(sequence.regions, expectedRegions),
              actual.change == expected.change else {
            throw DriverError.failure("Full-copy visual parity failed at \(seconds)")
        }
        if actual.regions != nil {
            guard actual.maskBytes == expected.maskBytes,
                  actual.imageCount == expected.imageCount,
                  actual.resourceLimitExceeded == expected.resourceLimitExceeded else {
                throw DriverError.failure("Admission metadata parity failed at \(seconds)")
            }
        }
        if actual.change == 1 { positions += 1 }
        if actual.change == 2 { contents += 1 }
        records.append([
            "seconds_bits": String(seconds.bitPattern, radix: 16),
            "change": actual.change, "image_count": actual.imageCount,
            "mask_bytes": actual.maskBytes,
            "resource_limit_exceeded": actual.resourceLimitExceeded,
            "returned_regions": actual.regions != nil,
            "visual_sha256": visualDigest(sequence.regions),
        ])
    }
    if fixture.name.hasPrefix("moving"), fixture.name != "moving-fractional", positions == 0 {
        throw DriverError.failure("Moving fixture did not produce native position-only changes")
    }
    if fixture.name == "content-change", contents == 0 {
        throw DriverError.failure("Content fixture did not produce native content changes")
    }
    let encoded = try JSONSerialization.data(withJSONObject: records, options: [.sortedKeys])
    return Verification(frames: times.count, positionChanges: positions,
                        contentChanges: contents, checksum: hex(SHA256.hash(data: encoded)))
}

private struct Counts {
    var checksum: UInt64 = 0
    var unchanged = 0
    var positions = 0
    var contents = 0
    var bitmapCopies: UInt64 = 0
    var maskBytes: UInt64 = 0
    var copiedMaskBytes: UInt64 = 0
    var renderNanoseconds: UInt64 = 0
    var copyNanoseconds: UInt64 = 0

    mutating func consume(_ result: ASSRenderResult, regions: [ASSRenderedRegion], frame: Int) {
        switch result.change {
        case 0: unchanged += 1
        case 1: positions += 1
        case 2: contents += 1
        default: preconditionFailure("Unexpected libass change code")
        }
        bitmapCopies &+= UInt64(result.bitmapCopies)
        maskBytes &+= UInt64(result.maskBytes)
        // Both implementations copy either the whole admitted subset or none.
        precondition(result.bitmapCopies == 0 || result.bitmapCopies == result.imageCount)
        if result.bitmapCopies > 0 { copiedMaskBytes &+= UInt64(result.maskBytes) }
        renderNanoseconds &+= result.renderNanoseconds
        copyNanoseconds &+= result.copyNanoseconds
        checksum = checksum &* 31 &+ UInt64(regions.count)
        for (index, region) in regions.enumerated() {
            checksum = checksum &* 31 &+ UInt64(region.color)
            checksum = checksum &* 31 &+ Double(region.frame.minX).bitPattern
            checksum = checksum &* 31 &+ Double(region.frame.minY).bitPattern
            checksum = checksum &* 31 &+ UInt64(region.bitmap.count)
            if !region.bitmap.isEmpty {
                let sample = region.bitmap.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> UInt64 in
                    UInt64(bytes[(frame + index) % bytes.count])
                }
                checksum = checksum &* 31 &+ sample
            }
        }
    }
}

@inline(never)
private func exercise(_ sequence: RenderSequence, fixture: Fixture, iterations: Int) -> Counts {
    var counts = Counts()
    for _ in 0..<iterations {
        for (index, seconds) in fixture.times.enumerated() {
            let result = sequence.step(seconds)
            counts.consume(result, regions: sequence.regions, frame: index)
        }
    }
    return counts
}

@main
struct Driver {
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count == 4, let iterations = Int(args[2]), iterations > 0,
              iterations <= 1_000_000, let seed = UInt64(args[3]) else {
            throw DriverError.usage
        }
        let fixture = try Fixture(name: args[1], seed: seed)
        let verification = try verify(fixture)
        let sequence = try RenderSequence(fixture)
        let warmup = exercise(sequence, fixture: fixture, iterations: 1)
        let startCPU = cpuNanoseconds()
        let startWall = DispatchTime.now().uptimeNanoseconds
        let counts = exercise(sequence, fixture: fixture, iterations: iterations)
        let elapsed = DispatchTime.now().uptimeNanoseconds - startWall
        let cpu = cpuNanoseconds() - startCPU
        // Retain the final output across timing; then hash its complete bytes.
        let finalDigest = visualDigest(sequence.regions)
        let receipt: [String: Any] = [
            "case": fixture.name, "iterations": iterations, "seed": seed,
            "frames": iterations * fixture.times.count,
            "elapsed_ns": elapsed, "cpu_ns": cpu,
            "checksum": String(counts.checksum, radix: 16),
            "warmup_checksum": String(warmup.checksum, radix: 16),
            "final_visual_sha256": finalDigest,
            "change_counts": ["0": counts.unchanged, "1": counts.positions, "2": counts.contents],
            "bitmap_copies": counts.bitmapCopies, "mask_bytes": counts.maskBytes,
            "copied_mask_bytes": counts.copiedMaskBytes,
            "render_ns": counts.renderNanoseconds, "copy_ns": counts.copyNanoseconds,
            "verification": verification.json,
            "fixture_sha256": hex(SHA256.hash(data: fixture.data)),
            "width": Int(fixture.size.width), "height": Int(fixture.size.height),
            "maximum_image_count": fixture.maximumImageCount,
        ]
        let encoded = try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys])
        print(String(decoding: encoded, as: UTF8.self))
        withExtendedLifetime(sequence) {}
    }
}
