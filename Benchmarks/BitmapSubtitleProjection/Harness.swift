import Foundation
@testable import IlliquidNativePlayback
#if os(Linux)
import Glibc
#else
import Darwin
#endif

private struct Fixture {
    let name: String
    let composition: NativeBitmapSubtitleComposition
    let viewport: CGRect
    let forcedOnly: Bool
    let budget: SubtitleMemoryBudget

    func project() -> [ASSRenderedRegion] {
        composition.renderedRegions(in: viewport, forcedOnly: forcedOnly)
    }
}

private func names() -> [String] {
    [0, 1, 2, 4, 16, 64].flatMap { count in
        ["unforced", "forced-all", "forced-some", "forced-none"].map { "\($0)-\(count)" }
    } + ["invalid-zero", "invalid-nan"]
}

private func fixture(_ name: String) -> Fixture {
    precondition(names().contains(name))
    let count = Int(name.split(separator: "-").last!) ?? 16
    let budget = SubtitleMemoryBudget(limitBytes: 1_048_576, ownerLimitsBytes: [:])
    let regions = (0..<count).map { index in
        let width = 2 + index % 7
        let height = 2 + index % 5
        let pixels = Data((0..<(width * height * 4)).map { UInt8(truncatingIfNeeded: $0 + index * 13) })
        let forced = name.hasPrefix("forced-all") || (!name.hasPrefix("forced-none") && index.isMultiple(of: 2))
        return NativeBitmapSubtitleRegion(
            pixels: pixels,
            frame: CGRect(x: Double(index * 17) - 11.25, y: Double(index * 23) + 7.75,
                          width: Double(width), height: Double(height)),
            isForced: forced
        )
    }
    let size = if name == "invalid-zero" {
        CGSize(width: 0, height: 1080)
    } else if name == "invalid-nan" {
        CGSize(width: Double.nan, height: 1080)
    } else {
        CGSize(width: 1920, height: 1080)
    }
    let lease = budget.acquire(owner: .bitmapEvents, bytes: regions.reduce(0) { $0 + $1.pixels.count })!
    return Fixture(
        name: name,
        composition: NativeBitmapSubtitleComposition(regions: regions, canvasSize: size,
            duration: 2.5, memoryLease: lease),
        viewport: CGRect(x: 11.25, y: -7.5, width: 1280.5, height: 720.25),
        forcedOnly: name.hasPrefix("forced"), budget: budget
    )
}

private func bits(_ value: CGFloat) -> String {
    String(Double(value).bitPattern, radix: 16)
}

private func verificationFixtures() -> [Fixture] {
    names().flatMap { name in
        let base = fixture(name)
        let viewports = [base.viewport, .zero,
            CGRect(x: -37.5, y: 100.25, width: 1920, height: 1080),
            CGRect(x: 10, y: 20, width: 3840, height: 2160)]
        return viewports.enumerated().flatMap { index, viewport in
            [false, true].map { hasLease in
                Fixture(name: "\(name)/viewport-\(index)/lease-\(hasLease)",
                    composition: NativeBitmapSubtitleComposition(
                        regions: base.composition.regions,
                        canvasSize: base.composition.canvasSize,
                        duration: hasLease ? base.composition.duration : nil,
                        memoryLease: hasLease ? base.composition.memoryLease : nil),
                    viewport: viewport, forcedOnly: base.forcedOnly, budget: base.budget)
            }
        }
    }
}

private func receipt(_ fixture: Fixture) -> [String: Any] {
    let projected = fixture.project()
    let expected = fixture.composition.regions.filter { !fixture.forcedOnly || $0.isForced }
    let canvasIsValid = fixture.composition.canvasSize.width > 0 && fixture.composition.canvasSize.height > 0
    precondition(projected.count == (canvasIsValid ? expected.count : 0))
    let rows = projected.enumerated().map { index, value -> [String: Any] in
        let source = expected[index]
        precondition(value.bitmap == source.pixels)
        precondition(value.color == 0 && value.isPremultipliedBGRA)
        precondition(value.stride == Int(source.frame.width) * 4)
        precondition(value.bitmapSize == source.frame.size)
        precondition(value.memoryLease === fixture.composition.memoryLease)
        return [
            "bitmap": value.bitmap.base64EncodedString(),
            "color": value.color,
            "frame_bits": [bits(value.frame.minX), bits(value.frame.minY), bits(value.frame.width), bits(value.frame.height)],
            "stride": value.stride,
            "bitmap_size_bits": [bits(value.bitmapSize!.width), bits(value.bitmapSize!.height)],
            "premultiplied_bgra": value.isPremultipliedBGRA,
            "shares_source_lease": value.memoryLease === fixture.composition.memoryLease,
        ]
    }
    return [
        "workload": fixture.name,
        "input": [
            "regions": fixture.composition.regions.map { region in
                ["pixels": region.pixels.base64EncodedString(), "is_forced": region.isForced,
                 "frame_bits": [bits(region.frame.minX), bits(region.frame.minY), bits(region.frame.width), bits(region.frame.height)]] as [String: Any]
            },
            "canvas_bits": [bits(fixture.composition.canvasSize.width), bits(fixture.composition.canvasSize.height)],
            "viewport_bits": [bits(fixture.viewport.minX), bits(fixture.viewport.minY), bits(fixture.viewport.width), bits(fixture.viewport.height)],
            "forced_only": fixture.forcedOnly,
            "duration_bits": fixture.composition.duration.map { String($0.bitPattern, radix: 16) as Any } ?? NSNull(),
            "has_memory_lease": fixture.composition.memoryLease != nil,
        ],
        "output": ["regions": rows, "retained_source_bytes": fixture.composition.byteCount,
                   "reserved_bytes": fixture.budget.snapshot.reservedBytes],
    ]
}

@inline(never)
private func consume(_ values: [ASSRenderedRegion]) -> UInt64 {
    var checksum = UInt64(values.count)
    if let first = values.first, let last = values.last {
        checksum &+= Double(first.frame.minX).bitPattern
        checksum &+= Double(last.frame.maxY).bitPattern
        checksum &+= UInt64(first.bitmap.count + last.bitmap.count + first.stride + last.stride)
    }
    return checksum
}

private func cpuNanoseconds() -> UInt64 {
    var time = timespec()
    precondition(clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &time) == 0)
    return UInt64(time.tv_sec) * 1_000_000_000 + UInt64(time.tv_nsec)
}

private func emit(_ value: Any) throws {
    print(String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self))
}

@main private enum Driver {
    static func main() throws {
        let args = CommandLine.arguments
        precondition(args.count >= 2)
        if args[1] == "list" { try emit(names()); return }
        if args[1] == "verify" { try emit(verificationFixtures().map(receipt)); return }
        precondition(args.count == 3)
        let value = fixture(args[1])
        let iterations = Int(args[2])!
        precondition(iterations > 0)
        // Full field and lease checks are untimed; the complete cross-variant
        // receipts are checked separately before the measurement campaign.
        _ = receipt(value)
        var warmup: UInt64 = 0
        for _ in 0..<100 { warmup &+= consume(value.project()) }
        var checksum: UInt64 = 0
        let cpuStart = cpuNanoseconds()
        let wallStart = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<iterations { checksum &+= consume(value.project()) }
        let wall = DispatchTime.now().uptimeNanoseconds - wallStart
        let cpu = cpuNanoseconds() - cpuStart
        try emit(["workload": value.name, "iterations": iterations, "checksum": checksum, "warmup_checksum": warmup,
                  "warmup_iterations": 100, "input_region_count": value.composition.regions.count,
                  "cpu_ns": cpu, "wall_ns": wall, "cpu_ns_per_projection": Double(cpu) / Double(iterations),
                  "wall_ns_per_projection": Double(wall) / Double(iterations)])
    }
}
