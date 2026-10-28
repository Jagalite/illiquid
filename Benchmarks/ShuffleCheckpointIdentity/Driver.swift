import Foundation
import Dispatch
#if os(Linux)
import Glibc
#else
import Darwin
#endif

private struct Fixture {
    let items: [FolderPlaylistItem]
    let ids: [String]
}

private func fixture(size: Int, scenario: String) -> Fixture {
    func item(_ index: Int, revision: Int = 0) -> FolderPlaylistItem {
        FolderPlaylistItem(
            url: URL(fileURLWithPath: "/Media/Series \(index % 17)/Episode \(index) Café.mkv"),
            externalSubtitleURLs: [
                URL(fileURLWithPath: "/Media/Subtitles/\(index)-\(revision).en.srt"),
                URL(fileURLWithPath: "/Media/Subtitles/\(index)-\(revision).ja.ass"),
            ],
            dateAdded: Date(timeIntervalSince1970: Double(revision))
        )
    }
    let original = (0..<size).map { item($0) }
    let ids = original.map(\.id)
    let reversed = Array(original.reversed())
    switch scenario {
    case "unchanged":
        return Fixture(items: reversed, ids: ids)
    case "edited":
        let survivors = reversed.enumerated().filter { $0.offset % 4 != 0 }.map(\.element)
        let added = (size..<(size + size - survivors.count)).map { item($0) }
        return Fixture(items: survivors + added, ids: ids)
    case "duplicates":
        return Fixture(
            items: reversed + (0..<size).map { item($0, revision: 1) },
            ids: ids + ids + ["/Media/removed.mkv"]
        )
    case "no-base":
        return Fixture(items: reversed, ids: [])
    default:
        fatalError("Unknown scenario: \(scenario)")
    }
}

@inline(never)
private func evaluate(_ fixture: Fixture, variant: String) -> [String] {
    switch variant {
    case "baseline":
        // Exact checkpoint expression on the pinned base; restoringOrder stays unchanged.
        return BaselinePlaylistMutation.restoringOrder(fixture.items, ids: fixture.ids).map(\.id)
    case "candidate":
        return PlaylistMutation.restoringIDs(fixture.items, ids: fixture.ids)
    default:
        fatalError("Unknown variant: \(variant)")
    }
}

private func scoped<T>(_ body: () -> T) -> T {
#if os(Linux)
    body()
#else
    autoreleasepool(invoking: body)
#endif
}

private struct AllocationMeter {
    let begin: @convention(c) () -> Void
    let end: @convention(c) () -> Void
    let requests: @convention(c) () -> UInt64
    let bytes: @convention(c) () -> UInt64

    init() {
        func symbol(_ name: String) -> UnsafeMutableRawPointer {
            guard let pointer = dlsym(nil, name) else { fatalError("Missing allocator meter: \(name)") }
            return pointer
        }
        begin = unsafeBitCast(symbol("meter_begin"), to: (@convention(c) () -> Void).self)
        end = unsafeBitCast(symbol("meter_end"), to: (@convention(c) () -> Void).self)
        requests = unsafeBitCast(symbol("meter_requests"), to: (@convention(c) () -> UInt64).self)
        bytes = unsafeBitCast(symbol("meter_bytes"), to: (@convention(c) () -> UInt64).self)
    }
}

@main
enum ShuffleCheckpointIdentityStudy {
    static func main() throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 6,
              let size = Int(arguments[2]), size >= 0,
              let iterations = Int(arguments[4]), iterations > 0,
              ["timing", "allocations"].contains(arguments[5]) else {
            fatalError("study <baseline|candidate> <size> <scenario> <iterations> <timing|allocations>")
        }
        let variant = arguments[1], scenario = arguments[3], mode = arguments[5]
        let input = fixture(size: size, scenario: scenario)
        // Fixture construction, byte-level parity and warmup are outside all meters.
        let expected = scoped { evaluate(input, variant: "baseline") }
        let actual = scoped { evaluate(input, variant: "candidate") }
        precondition(actual.count == expected.count)
        precondition(zip(actual, expected).allSatisfy { pair in pair.0.utf8.elementsEqual(pair.1.utf8) })
        let actualJSON = try JSONEncoder().encode(actual)
        let expectedJSON = try JSONEncoder().encode(expected)
        precondition(actualJSON == expectedJSON)
        let meter = mode == "allocations" ? AllocationMeter() : nil
        var checksum = 0
        let cpuStart = clock()
        let wallStart = DispatchTime.now().uptimeNanoseconds
        meter?.begin()
        for _ in 0..<iterations {
            checksum &+= scoped {
                let result = evaluate(input, variant: variant)
                return result.count &+ (result.first?.utf8.count ?? 0)
                    &+ (result.last?.utf8.count ?? 0)
            }
        }
        meter?.end()
        let wallEnd = DispatchTime.now().uptimeNanoseconds
        let cpuEnd = clock()
        let expectedChecksum = iterations &* (
            expected.count &+ (expected.first?.utf8.count ?? 0) &+ (expected.last?.utf8.count ?? 0)
        )
        precondition(checksum == expectedChecksum)
        var row: [String: Any] = [
            "variant": variant, "size": size, "scenario": scenario, "mode": mode,
            "input_items": input.items.count, "unique_output_ids": expected.count,
            "saved_ids": input.ids.count, "iterations": iterations, "checksum": checksum,
            "wall_ns_per_call": Double(wallEnd - wallStart) / Double(iterations),
            "cpu_ns_per_call": Double(cpuEnd - cpuStart) / Double(CLOCKS_PER_SEC)
                * 1_000_000_000 / Double(iterations),
            "byte_parity": true,
        ]
        if let meter {
            row["allocation_requests_per_call"] = Double(meter.requests()) / Double(iterations)
            row["requested_bytes_per_call"] = Double(meter.bytes()) / Double(iterations)
        }
        let output = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
        print(String(decoding: output, as: UTF8.self))
        withExtendedLifetime((input, expected, actual)) {}
    }
}
