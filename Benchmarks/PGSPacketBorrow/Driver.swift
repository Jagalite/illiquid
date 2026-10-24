import CFFmpeg
import Darwin
import Dispatch
import Foundation

// Only this call-site adapter differs between the two executables. The parser,
// packet owner and C module are complete production sources, not reimplementations.
@inline(never)
private func parsePacket(_ packet: FFmpegPacket) throws -> PGSSubtitlePresentation? {
#if BASELINE
    guard let data = packet.data else { return nil }
    return try PGSSubtitlePresentation.update(in: data)
#else
    return try PGSSubtitlePresentation.update(in: packet)
#endif
}

private struct ObjectSnapshot: Codable, Equatable, Sendable {
    let x: Int32
    let y: Int32
    let crop: [Int32]?
}

private struct Snapshot: Codable, Equatable, Sendable {
    let status: String
    let objects: [ObjectSnapshot]?
    let errorCode: Int32?
    let operation: String?

    static let none = Snapshot(status: "none", objects: nil, errorCode: nil, operation: nil)
    static let invalid = Snapshot(status: "error", objects: nil,
                                  errorCode: illiquid_averror_invaliddata(),
                                  operation: "Read PGS composition geometry")

    static func composition(_ objects: [ObjectSnapshot]) -> Self {
        Self(status: "composition", objects: objects, errorCode: nil, operation: nil)
    }
}

private func snapshot(_ result: PGSSubtitlePresentation?) -> Snapshot {
    guard let result else { return .none }
    return .composition(result.objects.map { object in
        ObjectSnapshot(x: object.x, y: object.y,
                       crop: object.crop.map { [$0.x, $0.y, $0.width, $0.height] })
    })
}

private func outcome(_ packet: FFmpegPacket) throws -> Snapshot {
    do { return snapshot(try parsePacket(packet)) }
    catch let error as FFmpegError {
        return Snapshot(status: "error", objects: nil, errorCode: error.code, operation: error.operation)
    }
}

private struct Fixture {
    let name: String
    let bytes: [UInt8]
    let expected: Snapshot?
    var reportedSize: Int32? = nil
}

private func packet(_ fixture: Fixture) throws -> FFmpegPacket {
    var allocation = av_packet_alloc()
    guard let raw = allocation else { throw FFmpegError(operation: "Benchmark packet allocation", code: -12) }
    defer { av_packet_free(&allocation) }
    if !fixture.bytes.isEmpty {
        try checkFFmpeg(av_new_packet(raw, Int32(fixture.bytes.count)), operation: "Benchmark payload allocation")
        fixture.bytes.withUnsafeBufferPointer { bytes in
            raw.pointee.data!.update(from: bytes.baseAddress!, count: bytes.count)
        }
    }
    if let size = fixture.reportedSize { raw.pointee.size = size }
    return try FFmpegPacket(taking: &allocation, timeBase: AVRational(num: 1, den: 90_000), generation: 0)
}

private func word(_ number: Int) -> [UInt8] {
    precondition((0...65_535).contains(number))
    return [UInt8(number >> 8), UInt8(number & 255)]
}

private func segment(_ kind: UInt8, _ payload: [UInt8]) -> [UInt8] {
    [kind] + word(payload.count) + payload
}

private func composition(_ seed: Int, cropped: Bool = false, count: Int = 1) -> [UInt8] {
    // PGS video descriptor and composition descriptor followed by object references.
    var body = word(1920)
    body += word(1080)
    body += [0x10]
    body += word(seed)
    body += [0x80, 0, 0, UInt8(count)]
    for index in 0..<count {
        body += word(index) + [0, cropped ? 0x80 : 0] + word(50 + seed + index) + word(900 + index)
        if cropped { body += word(4 + index) + word(2) + word(32 + seed) + word(16) }
    }
    return segment(0x16, body)
}

private func expectedComposition(_ seed: Int, cropped: Bool = false, count: Int = 1) -> Snapshot {
    .composition((0..<count).map { index in
        ObjectSnapshot(x: Int32(50 + seed + index), y: Int32(900 + index),
                       crop: cropped ? [Int32(4 + index), 2, Int32(32 + seed), 16] : nil)
    })
}

private func objectSegments(payloadBytes: Int, seed: Int) -> [UInt8] {
    // An authored ODS is split into legal UInt16-length segments. Its payload is
    // deterministic pseudo-RLE; this benchmark does not claim decoded pixel parity.
    precondition(payloadBytes >= 16 && payloadBytes < 0xFF_FFF0)
    var output: [UInt8] = []
    var remaining = payloadBytes
    var first = true
    while remaining > 0 {
        let capacity = first ? 65_524 : 65_531
        let count = min(remaining, capacity)
        var body = word(seed) + [0, UInt8((first ? 0x80 : 0) | (count == remaining ? 0x40 : 0))]
        if first {
            let length = payloadBytes + 4
            body += [UInt8((length >> 16) & 255), UInt8((length >> 8) & 255), UInt8(length & 255)]
            body += word(1920) + word(120)
        }
        body += (0..<count).map { UInt8(truncatingIfNeeded: $0 &* 29 &+ seed &* 17 &+ 1) }
        output += segment(0x15, body)
        first = false
        remaining -= count
    }
    return output
}

private func workloads() -> [String: [Fixture]] {
    var result: [String: [Fixture]] = [:]
    for seed in 0..<16 {
        let end = segment(0x80, [])
        let pcs = composition(seed)
        let ods4 = objectSegments(payloadBytes: 4_096 + seed, seed: seed)
        let ods64 = objectSegments(payloadBytes: 65_524 - seed, seed: seed)
        let ods256 = objectSegments(payloadBytes: 262_144 + seed, seed: seed)
        func add(_ name: String, _ bytes: [UInt8], _ expected: Snapshot) {
            result[name, default: []].append(Fixture(name: "\(name)-\(seed)", bytes: bytes, expected: expected))
        }
        add("tiny_end", end, .none)
        add("composition_one", pcs, expectedComposition(seed))
        add("composition_two_cropped", composition(seed, cropped: true, count: 2),
            expectedComposition(seed, cropped: true, count: 2))
        add("object_4k", ods4, .none)
        add("object_64k", ods64, .none)
        add("composition_object_64k", pcs + ods64 + end, expectedComposition(seed))
        add("multisegment_256k", ods256, .none)
        add("composition_multisegment_256k", pcs + ods256 + end, expectedComposition(seed))
    }
    return result
}

private func edgeCases() -> [Fixture] {
    let cropped = composition(3, cropped: true, count: 2)
    var cases = [
        Fixture(name: "empty", bytes: [], expected: Snapshot.none),
        Fixture(name: "negative_size", bytes: [], expected: Snapshot.none, reportedSize: -1),
        Fixture(name: "null_payload_positive_size", bytes: [], expected: Snapshot.none, reportedSize: 23),
        Fixture(name: "short_header_1", bytes: [0x16], expected: .invalid),
        Fixture(name: "short_header_2", bytes: [0x16, 0], expected: .invalid),
        Fixture(name: "oversize_payload", bytes: [0x16, 0xFF, 0xFF], expected: .invalid),
        Fixture(name: "short_composition", bytes: segment(0x16, Array(repeating: 0, count: 10)), expected: .invalid),
        Fixture(name: "invalid_zero_dimensions", bytes: segment(0x16, Array(repeating: 0, count: 11)), expected: .invalid),
        Fixture(name: "clear_composition", bytes: composition(3, count: 0), expected: .composition([])),
        Fixture(name: "last_composition_wins", bytes: composition(1) + cropped,
                expected: expectedComposition(3, cropped: true, count: 2)),
        Fixture(name: "trailing_bad_header", bytes: composition(1) + [0x15, 0], expected: .invalid),
        Fixture(name: "ignored_unknown", bytes: segment(0x7F, [1, 2, 3]), expected: Snapshot.none),
        Fixture(name: "maximum_segment", bytes: segment(0x15, Array(repeating: 0xA5, count: 65_535)), expected: Snapshot.none),
    ]
    for size in 0..<cropped.count {
        cases.append(Fixture(name: "cropped_prefix_\(size)", bytes: Array(cropped.prefix(size)), expected: nil))
    }
    var countTooLarge = composition(2)
    countTooLarge[13] = 3
    cases.append(Fixture(name: "too_many_objects", bytes: countTooLarge, expected: .invalid))
    var invalidPosition = composition(2)
    invalidPosition[18] = 0xFF
    cases.append(Fixture(name: "position_outside_canvas", bytes: invalidPosition, expected: .invalid))
    // Reproducible malformed inputs stress bounds and error parity independently
    // of the success-only timed corpus. Keep individual outcomes in the receipt.
    var random: UInt64 = 0xBADC_0FFE_E123_4567
    func next() -> UInt8 {
        random = random &* 6_364_136_223_846_793_005 &+ 1
        return UInt8(truncatingIfNeeded: random >> 24)
    }
    for index in 0..<256 {
        let count = Int(next())
        let bytes = (0..<count).map { _ in next() }
        cases.append(Fixture(name: "random_\(index)", bytes: bytes, expected: nil))
    }
    for index in 0..<64 {
        var bytes = cropped
        bytes[index % bytes.count] ^= next() | 1
        cases.append(Fixture(name: "mutated_composition_\(index)", bytes: bytes, expected: nil))
    }
    return cases
}

private struct Verification: Codable {
    struct Row: Codable {
        let name: String
        let byteCount: Int
        let result: Snapshot
        let authoredExpectation: Bool
    }
    let ffmpegVersion: String
    let rows: [Row]
}

private func verify() throws -> Verification {
    let all = workloads()
    let fixtures = all.keys.sorted().flatMap { all[$0]! } + edgeCases()
    var rows: [Verification.Row] = []
    for fixture in fixtures {
        let value = try outcome(packet(fixture))
        if let expected = fixture.expected { precondition(value == expected, "Wrong expected output: \(fixture.name)") }
        rows.append(.init(name: fixture.name, byteCount: fixture.bytes.count, result: value,
                          authoredExpectation: fixture.expected != nil))
    }
    return Verification(ffmpegVersion: String(cString: av_version_info()), rows: rows)
}

// The returned number consumes every object and crop field from every parse.
// The external process returns it so the optimizer cannot discard the work.
private func digest(_ value: PGSSubtitlePresentation?) -> UInt64 {
    guard let value else { return 17 }
    var result = UInt64(value.objects.count) &+ 31
    for object in value.objects {
        result = result &* 31 &+ UInt64(object.x)
        result = result &* 31 &+ UInt64(object.y)
        if let crop = object.crop {
            for field in [crop.x, crop.y, crop.width, crop.height] {
                result = result &* 31 &+ UInt64(field)
            }
        }
    }
    return result
}

@inline(never)
private func exercise(_ packets: [FFmpegPacket], iterations: Int) throws -> UInt64 {
    precondition(packets.count == 16 && iterations > 0 && iterations % packets.count == 0)
    var checksum: UInt64 = 0
    for index in 0..<iterations { checksum &+= digest(try parsePacket(packets[index & 15])) }
    return checksum
}

private func cpuNanoseconds() -> UInt64 {
    var time = timespec()
    precondition(clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &time) == 0)
    return UInt64(time.tv_sec) * 1_000_000_000 + UInt64(time.tv_nsec)
}

private struct Measurement: Codable {
    let workload: String
    let iterations: Int
    let warmupIterations: Int
    let payloadBytes: [Int]
    let elapsedNanoseconds: UInt64
    let cpuNanoseconds: UInt64
    let checksum: UInt64
    let cycleChecksum: UInt64
    let warmupChecksum: UInt64
    let first: Snapshot
    let last: Snapshot
}

private func measure(_ name: String, iterations: Int) throws -> Measurement {
    guard let fixtures = workloads()[name] else { fatalError("Unknown workload: \(name)") }
    let packets = try fixtures.map(packet)
    for (fixture, packet) in zip(fixtures, packets) {
        let observed = try outcome(packet)
        precondition(observed == fixture.expected!, "Timed fixture mismatch")
    }
    let cycle = try exercise(packets, iterations: 16)
    let warmupIterations = 4_096
    let warmup = try exercise(packets, iterations: warmupIterations)
    let cpuStart = cpuNanoseconds()
    let wallStart = DispatchTime.now().uptimeNanoseconds
    let checksum = try exercise(packets, iterations: iterations)
    let elapsed = DispatchTime.now().uptimeNanoseconds - wallStart
    let cpu = cpuNanoseconds() - cpuStart
    precondition(checksum == cycle &* UInt64(iterations / 16), "Timed checksum mismatch")
    return Measurement(workload: name, iterations: iterations, warmupIterations: warmupIterations,
                       payloadBytes: fixtures.map { $0.bytes.count }, elapsedNanoseconds: elapsed,
                       cpuNanoseconds: cpu, checksum: checksum, cycleChecksum: cycle,
                       warmupChecksum: warmup, first: try outcome(packets[0]), last: try outcome(packets[15]))
}

@main
private enum Main {
    static func main() throws {
        let arguments = CommandLine.arguments
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data: Data
        if arguments.count == 2 && arguments[1] == "verify" {
            data = try encoder.encode(verify())
        } else if arguments.count == 4 && arguments[1] == "measure", let iterations = Int(arguments[3]) {
            data = try encoder.encode(measure(arguments[2], iterations: iterations))
        } else {
            fatalError("Usage: benchmark verify | benchmark measure CASE ITERATIONS")
        }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([10]))
    }
}
