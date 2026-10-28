import CFFmpeg
import CryptoKit
import Darwin
import Dispatch
import Foundation
@testable import AcquisitionComponent

private struct Fixture {
    let name: String
    let bytes: [UInt8]
    let isPGS: Bool
    let pageID: UInt16?
    let expected: Bool?
    var reportedSize: Int32? = nil
}

private let shapes = [
    "tiny_end", "small_acquisition", "small_ordinary", "object_4k", "object_64k",
    "first_64k", "last_64k", "object_256k", "first_256k", "last_256k", "mixed_64k",
]

private func word(_ value: Int) -> [UInt8] {
    precondition((0...65_535).contains(value))
    return [UInt8(value >> 8), UInt8(value & 255)]
}

private func segment(_ kind: UInt8, _ body: [UInt8], isPGS: Bool, page: UInt16) -> [UInt8] {
    (isPGS ? [kind] : [0x0F, kind] + word(Int(page))) + word(body.count) + body
}

private func composition(isPGS: Bool, flags: UInt8, page: UInt16) -> [UInt8] {
    let body: [UInt8] = isPGS
        ? [5, 0, 2, 208, 16, 0, 1, flags, 0, 0, 0]
        : [2, flags]
    return segment(isPGS ? 0x16 : 0x10, body, isPGS: isPGS, page: page)
}

private func objects(count: Int, seed: Int, isPGS: Bool, page: UInt16) -> [UInt8] {
    // Legal segment framing with synthetic object data. No pixel-decoding claim.
    var result: [UInt8] = []
    var remaining = count
    while remaining > 0 {
        let length = min(remaining, 65_535)
        let body = (0..<length).map { UInt8(truncatingIfNeeded: $0 &* 29 &+ seed &* 17) }
        result += segment(isPGS ? 0x15 : 0x13, body, isPGS: isPGS, page: page)
        remaining -= length
    }
    return result
}

private func fixtures(for name: String) -> [Fixture] {
    let isPGS = name.hasPrefix("pgs_")
    precondition(isPGS || name.hasPrefix("dvb_"))
    let shape = String(name.dropFirst(4))
    precondition(shapes.contains(shape))
    return (0..<16).map { seed in
        let page = UInt16(seed + 1)
        let acquisition = composition(isPGS: isPGS, flags: isPGS ? 0x80 : 4, page: page)
        let ordinary = composition(isPGS: isPGS, flags: 0, page: page)
        let bytes: [UInt8]
        let expected: Bool
        switch shape {
        case "tiny_end":
            bytes = segment(0x80, [], isPGS: isPGS, page: page)
            expected = false
        case "small_acquisition":
            bytes = acquisition
            expected = true
        case "small_ordinary":
            bytes = ordinary
            expected = false
        default:
            let size = shape.hasSuffix("_4k") ? 4_096
                : (shape.hasSuffix("_256k") ? 262_144 : 65_524)
            let payload = objects(count: size + seed, seed: seed, isPGS: isPGS, page: page)
            if shape.hasPrefix("first_") {
                bytes = acquisition + payload
                expected = true
            } else if shape.hasPrefix("last_") {
                bytes = payload + acquisition
                expected = true
            } else if shape.hasPrefix("mixed_") {
                bytes = (seed.isMultiple(of: 2) ? acquisition : ordinary) + payload
                expected = seed.isMultiple(of: 2)
            } else {
                bytes = payload
                expected = false
            }
        }
        return Fixture(name: "\(name)-\(seed)", bytes: bytes, isPGS: isPGS,
                       pageID: page, expected: expected)
    }
}

private func packet(_ fixture: Fixture) throws -> FFmpegPacket {
    var allocation = av_packet_alloc()
    guard let raw = allocation else { throw FFmpegError(operation: "Allocate acquisition packet", code: -12) }
    defer { av_packet_free(&allocation) }
    if !fixture.bytes.isEmpty {
        try checkFFmpeg(av_new_packet(raw, Int32(fixture.bytes.count)), operation: "Allocate acquisition payload")
        fixture.bytes.withUnsafeBufferPointer { bytes in
            raw.pointee.data!.update(from: bytes.baseAddress!, count: bytes.count)
        }
    }
    if let size = fixture.reportedSize { raw.pointee.size = size }
    return try FFmpegPacket(taking: &allocation, timeBase: AVRational(num: 1, den: 90_000), generation: 0)
}

private func parse(_ packet: FFmpegPacket, _ fixture: Fixture) -> Bool {
    packet.isSubtitleAcquisition(isPGS: fixture.isPGS, compositionPageID: fixture.pageID)
}

private func edgeCases() -> [Fixture] {
    var cases: [Fixture] = []
    for isPGS in [true, false] {
        let prefix = isPGS ? "pgs" : "dvb"
        func add(_ name: String, _ bytes: [UInt8], _ expected: Bool?, page: UInt16? = 1,
                 size: Int32? = nil) {
            cases.append(Fixture(name: "\(prefix)-\(name)", bytes: bytes, isPGS: isPGS,
                                 pageID: page, expected: expected, reportedSize: size))
        }
        let acquisition = composition(isPGS: isPGS, flags: isPGS ? 0x80 : 4, page: 1)
        let ordinary = composition(isPGS: isPGS, flags: 0, page: 1)
        add("empty", [], false)
        add("null-positive-size", [], false, size: 12)
        add("null-negative-size", [], false, size: -1)
        add("nonnull-zero-size", acquisition, false, size: 0)
        add("nonnull-negative-size", acquisition, false, size: -1)
        for flags in UInt16(0)...255 {
            let byte = UInt8(flags)
            let state = (byte >> 2) & 3
            let expected = isPGS ? byte & 0xC0 != 0 : state == 1 || state == 2
            let bytes = composition(isPGS: isPGS, flags: byte, page: 1)
            add("flags-\(flags)-matching", bytes, expected)
            add("flags-\(flags)-any", bytes, expected, page: nil)
            add("flags-\(flags)-other", bytes, isPGS ? expected : false, page: 2)
        }
        for count in 0..<acquisition.count {
            add("truncated-\(count)", Array(acquisition.prefix(count)), false)
        }
        let malformed: [UInt8] = isPGS ? [0x15, 0xFF, 0xFF] : [0x0F, 0x13, 0, 1, 0xFF, 0xFF]
        add("bad-prefix", malformed + acquisition, false)
        add("bad-tail", acquisition + malformed, true)
        add("short-tail", acquisition + [0x0F], true)
        add("ordinary-short-tail", ordinary + [0x0F], false)
        let payload = acquisition + [UInt8](repeating: 0xFF, count: 65_535 - acquisition.count)
        let object = segment(isPGS ? 0x15 : 0x13, payload, isPGS: isPGS, page: 1)
        add("embedded-header", object, false)
        add("last-after-max-segment", object + acquisition, true)
        add("first-before-max-segment", acquisition + object, true)
        if !isPGS {
            add("bad-sync", [1, 0x10, 0, 1, 0, 2, 2, 4] + acquisition, false)
            let ancillary = composition(isPGS: false, flags: 4, page: 2)
            add("ancillary", ancillary + ordinary, false)
            add("ancillary-any", ancillary + ordinary, true, page: nil)
            add("ancillary-followed-by-selected", ancillary + acquisition, true)
        }
        var random: UInt64 = 0x0123_4567_89AB_CDEF
        func next() -> UInt8 {
            random = random &* 6_364_136_223_846_793_005 &+ 1
            return UInt8(truncatingIfNeeded: random >> 24)
        }
        for index in 0..<512 {
            let bytes = (0..<Int(next())).map { _ in next() }
            add("random-\(index)", bytes, nil)
        }
        for index in 0..<128 {
            var bytes = acquisition
            bytes[index % bytes.count] ^= next() | 1
            add("mutated-\(index)", bytes, nil)
        }
    }
    return cases
}

private struct Verification: Codable, Equatable {
    struct Row: Codable, Equatable {
        let name: String
        let isPGS: Bool
        let pageID: UInt16?
        let byteCount: Int
        let reportedSize: Int32?
        let inputSHA256: String
        let result: Bool
        let authoredExpectation: Bool
    }
    let ffmpegVersion: String
    let rows: [Row]
}

private func verify() throws -> Verification {
    var rows: [Verification.Row] = []
    func inspect(_ fixture: Fixture) throws {
        let owner = try packet(fixture)
        let value = parse(owner, fixture)
        if let expected = fixture.expected {
            precondition(value == expected, "Wrong acquisition decision: \(fixture.name)")
        }
        let hash = SHA256.hash(data: Data(fixture.bytes)).map { String(format: "%02x", $0) }.joined()
        rows.append(.init(name: fixture.name, isPGS: fixture.isPGS, pageID: fixture.pageID,
                          byteCount: fixture.bytes.count, reportedSize: fixture.reportedSize,
                          inputSHA256: hash, result: value, authoredExpectation: fixture.expected != nil))
    }
    for codec in ["pgs", "dvb"] {
        for shape in shapes {
            for fixture in fixtures(for: "\(codec)_\(shape)") { try inspect(fixture) }
        }
    }
    for fixture in edgeCases() { try inspect(fixture) }
    return Verification(ffmpegVersion: String(cString: av_version_info()), rows: rows)
}

@inline(never)
private func exercise(_ packets: [FFmpegPacket], _ fixtures: [Fixture], iterations: Int) -> UInt64 {
    precondition(packets.count == 16 && iterations > 0 && iterations % 16 == 0)
    var checksum: UInt64 = 0
    for index in 0..<iterations {
        let slot = index & 15
        checksum &+= parse(packets[slot], fixtures[slot]) ? UInt64(slot + 101) : UInt64(slot + 17)
    }
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
    let decisions: [Bool]
}

private func measure(_ name: String, iterations: Int) throws -> Measurement {
    let inputs = fixtures(for: name)
    let packets = try inputs.map(packet)
    let decisions = zip(packets, inputs).map { parse($0.0, $0.1) }
    precondition(decisions == inputs.map { $0.expected! })
    let cycle = exercise(packets, inputs, iterations: 16)
    let warmupIterations = 4_096
    let warmup = exercise(packets, inputs, iterations: warmupIterations)
    let cpuStart = cpuNanoseconds()
    let wallStart = DispatchTime.now().uptimeNanoseconds
    let checksum = exercise(packets, inputs, iterations: iterations)
    let elapsed = DispatchTime.now().uptimeNanoseconds - wallStart
    let cpu = cpuNanoseconds() - cpuStart
    precondition(checksum == cycle &* UInt64(iterations / 16), "Timed checksum mismatch")
    precondition(zip(packets, inputs).map { parse($0.0, $0.1) } == decisions)
    return Measurement(workload: name, iterations: iterations, warmupIterations: warmupIterations,
                       payloadBytes: inputs.map { $0.bytes.count }, elapsedNanoseconds: elapsed,
                       cpuNanoseconds: cpu, checksum: checksum, cycleChecksum: cycle,
                       warmupChecksum: warmup, decisions: decisions)
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
