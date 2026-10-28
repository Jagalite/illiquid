import CFFmpeg
import Dispatch
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

#if ALLOCATIONS
@_silgen_name("meter_begin") private func meterBegin()
@_silgen_name("meter_end") private func meterEnd()
@_silgen_name("meter_requests") private func meterRequests() -> UInt64
@_silgen_name("meter_bytes") private func meterBytes() -> UInt64
#endif

// The two adapters reproduce the acquisition expressions in activeSubtitlePackets.
// The packet owner and parsers are compiled from the production sources.
@inline(never)
private func acquisition(_ packet: FFmpegPacket, kind: Int, page: UInt16?) -> Bool {
    guard kind < 2 else { return false }
#if BASELINE
    return packet.data.map { data in
        kind == 0 ? PGSSubtitlePacket.isAcquisition(data)
            : DVBSubtitlePacket.isAcquisition(data, compositionPageID: page)
    } == true
#else
    return FFmpegDemuxer.isSubtitleAcquisition(packet, isPGS: kind == 0, compositionPageID: page)
#endif
}

private struct Fixture {
    let name: String
    let bytes: [UInt8]
    var size: Int32? = nil
    var pgs: Bool? = nil
    var dvb: Bool? = nil
}

private func word(_ value: Int) -> [UInt8] {
    precondition((0...65_535).contains(value))
    return [UInt8(value >> 8), UInt8(value & 255)]
}

private func pgsSegment(_ type: UInt8, _ payload: [UInt8]) -> [UInt8] {
    [type] + word(payload.count) + payload
}

private func pgsComposition(_ state: UInt8) -> [UInt8] {
    pgsSegment(0x16, [7, 128, 4, 56, 16, 0, 1, state, 0, 0, 0])
}

private func dvbSegment(_ type: UInt8, _ payload: [UInt8], page: Int = 1) -> [UInt8] {
    [0x0F, type] + word(page) + word(payload.count) + payload
}

private func dvbComposition(_ state: UInt8, page: Int = 1) -> [UInt8] {
    dvbSegment(0x10, [5, state << 2], page: page)
}

private func objectBytes(kind: Int, count: Int, seed: Int) -> [UInt8] {
    var remaining = count
    var output: [UInt8] = []
    while remaining > 0 {
        let size = min(remaining, 65_535)
        // Opaque object data is deliberately header-like. This tests length
        // skipping, not RLE/pixel validity; FFmpeg decoding is outside the study.
        let payload = [UInt8](repeating: UInt8(0x10 + seed % 16), count: size)
        output += kind == 0 ? pgsSegment(0x15, payload) : dvbSegment(0x13, payload)
        remaining -= size
    }
    return output
}

private func makePacket(_ fixture: Fixture) throws -> FFmpegPacket {
    var raw = av_packet_alloc()
    guard let pointer = raw else { throw FFmpegError(operation: "Allocate acquisition fixture", code: -12) }
    defer { av_packet_free(&raw) }
    if !fixture.bytes.isEmpty {
        try checkFFmpeg(av_new_packet(pointer, Int32(fixture.bytes.count)), operation: "Allocate acquisition payload")
        fixture.bytes.withUnsafeBufferPointer { source in
            pointer.pointee.data!.update(from: source.baseAddress!, count: source.count)
        }
    }
    if let size = fixture.size { pointer.pointee.size = size }
    return try FFmpegPacket(taking: &raw, timeBase: AVRational(num: 1, den: 90_000), generation: 7)
}

private func corpus() -> [Fixture] {
    var result = [
        Fixture(name: "empty", bytes: [], pgs: false, dvb: false),
        Fixture(name: "null-positive", bytes: [], size: 32, pgs: false, dvb: false),
        Fixture(name: "zero-size", bytes: pgsComposition(0x80), size: 0, pgs: false, dvb: false),
        Fixture(name: "negative-size", bytes: pgsComposition(0x80), size: -1, pgs: false, dvb: false),
        Fixture(name: "pgs-end", bytes: pgsSegment(0x80, []), pgs: false, dvb: false),
    ]
    for state: UInt8 in [0, 1, 0x3F, 0x40, 0x80, 0xC0, 0xFF] {
        result.append(Fixture(name: "pgs-state-\(state)", bytes: pgsComposition(state), pgs: state & 0xC0 != 0))
    }
    for page in [0, 1, 2, 65_535] {
        for state: UInt8 in 0...3 {
            result.append(Fixture(name: "dvb-page-\(page)-state-\(state)", bytes: dvbComposition(state, page: page),
                                  dvb: page == 1 && (state == 1 || state == 2)))
        }
    }
    let pgs = pgsComposition(0x80)
    let dvb = dvbComposition(1)
    for (name, bytes) in [("pgs", pgs), ("dvb", dvb)] {
        for length in 0..<bytes.count {
            result.append(Fixture(name: "\(name)-truncated-\(length)", bytes: Array(bytes.prefix(length)),
                                  pgs: false, dvb: false))
        }
        // Existing early-success behavior must survive malformed trailing data.
        result.append(Fixture(name: "\(name)-early-success-malformed-tail", bytes: bytes + [0xFF],
                              pgs: name == "pgs", dvb: name == "dvb"))
    }
    for size in [1, 4_096, 65_535, 4 * 65_535] {
        for kind in 0...1 {
            let objects = objectBytes(kind: kind, count: size, seed: 1)
            let composition = kind == 0 ? pgs : dvb
            result.append(Fixture(name: "object-\(kind)-\(size)", bytes: objects, pgs: false, dvb: false))
            result.append(Fixture(name: "before-object-\(kind)-\(size)", bytes: composition + objects,
                                  pgs: kind == 0, dvb: kind == 1))
            result.append(Fixture(name: "after-object-\(kind)-\(size)", bytes: objects + composition,
                                  pgs: kind == 0, dvb: kind == 1))
        }
    }
    // Deterministic malformed inputs and length/state mutations complement
    // authored expected values. Full outcomes are compared between executables.
    var random: UInt64 = 0x5345_454B_424F_5252
    func next() -> UInt64 {
        random = random &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return random
    }
    for index in 0..<1_024 {
        let count = Int(next() % 128)
        var bytes = (0..<count).map { _ in UInt8(truncatingIfNeeded: next() >> 24) }
        result.append(Fixture(name: "random-\(index)", bytes: bytes))
        bytes = index % 2 == 0 ? pgs : dvb
        let offset = Int(next() % UInt64(bytes.count))
        bytes[offset] = UInt8(truncatingIfNeeded: next() >> 24)
        result.append(Fixture(name: "mutated-\(index)", bytes: bytes))
    }
    return result
}

private func verify() throws -> [[String: Any]] {
    var rows: [[String: Any]] = []
    for fixture in corpus() {
        let packet = try makePacket(fixture)
        let before = packet.data
        let pgs = acquisition(packet, kind: 0, page: nil)
        let dvb = acquisition(packet, kind: 1, page: 1)
        if let expected = fixture.pgs { precondition(pgs == expected, fixture.name) }
        if let expected = fixture.dvb { precondition(dvb == expected, fixture.name) }
        let pages: [UInt16?] = [nil, 0, 1, 2, .max]
        let pageResults = pages.map { acquisition(packet, kind: 1, page: $0) }
        precondition(acquisition(packet, kind: 2, page: nil) == false)
        precondition(packet.data == before, "Parser mutated \(fixture.name)")
        rows.append(["name": fixture.name, "bytes": fixture.bytes.count,
                     "reported_size": fixture.size.map(Int.init) ?? fixture.bytes.count,
                     "pgs": pgs, "dvb_pages_nil_0_1_2_max": pageResults,
                     "payload_unchanged": true])
    }
    return rows
}

private struct Workload {
    let packets: [FFmpegPacket]
    let expected: [Bool]
    let sizes: [Int]
    let kind: Int
}

private func workload(_ name: String) throws -> Workload {
    let kind = name.hasPrefix("pgs") ? 0 : (name == "disabled" ? 2 : 1)
    var packets: [FFmpegPacket] = []
    var expected: [Bool] = []
    var sizes: [Int] = []
    for seed in 0..<16 {
        let acquiring = seed % 2 == 0
        let composition = kind == 0 ? pgsComposition(acquiring ? 0x80 : 0) : dvbComposition(acquiring ? 1 : 0)
        let bytes: [UInt8]
        if name == "disabled" { bytes = objectBytes(kind: 0, count: 65_535, seed: seed) }
        else if name.hasSuffix("empty") { bytes = [] }
        else if name.hasSuffix("tiny") { bytes = composition }
        else {
            let count = name.contains("256k") ? 4 * 65_535 : (name.contains("64k") ? 65_535 : 4_096)
            let objects = objectBytes(kind: kind, count: count, seed: seed)
            if name.contains("first") { bytes = composition + objects }
            else if name.contains("last") { bytes = objects + composition }
            else { bytes = objects }
        }
        let expectedValue = acquiring && (name.contains("first") || name.contains("last") || name.hasSuffix("tiny"))
        packets.append(try makePacket(Fixture(name: name, bytes: bytes)))
        expected.append(expectedValue)
        sizes.append(bytes.count)
    }
    return Workload(packets: packets, expected: expected, sizes: sizes, kind: kind)
}

@inline(never)
private func loop(_ input: Workload, iterations: Int) -> UInt64 {
    var checksum: UInt64 = 0
    for index in 0..<iterations {
        let slot = index & 15
        if acquisition(input.packets[slot], kind: input.kind, page: 1) {
            checksum &+= UInt64(slot + 1)
        }
    }
    return checksum
}

private func cpuNanoseconds() -> UInt64 {
    var value = timespec()
    precondition(clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &value) == 0)
    return UInt64(value.tv_sec) * 1_000_000_000 + UInt64(value.tv_nsec)
}

@main
private struct Driver {
    static func main() throws {
        let arguments = CommandLine.arguments
        precondition(arguments.count >= 2)
        var result: [String: Any]
        if arguments[1] == "verify" {
            result = ["outcomes": try verify()]
        } else {
            precondition(arguments.count == 4)
            let mode = arguments[1], name = arguments[2], iterations = Int(arguments[3])!
            precondition(iterations > 0 && iterations % 16 == 0)
            let input = try workload(name)
            let cycleChecksum = input.expected.enumerated().reduce(UInt64(0)) { $0 + ($1.element ? UInt64($1.offset + 1) : 0) }
            for index in input.packets.indices {
                precondition(acquisition(input.packets[index], kind: input.kind, page: 1) == input.expected[index])
            }
            precondition(loop(input, iterations: 256) == cycleChecksum * 16)
            let checksum: UInt64
#if ALLOCATIONS
            precondition(mode == "allocations")
            // Resolve instrumentation symbols before enabling the measured pass.
            meterBegin()
            meterEnd()
            _ = meterRequests()
            _ = meterBytes()
            meterBegin()
            checksum = loop(input, iterations: iterations)
            meterEnd()
            result = ["allocation_requests": meterRequests(), "allocation_requested_bytes": meterBytes()]
#else
            precondition(mode == "timing")
            let cpuStart = cpuNanoseconds(), wallStart = DispatchTime.now().uptimeNanoseconds
            checksum = loop(input, iterations: iterations)
            let wall = DispatchTime.now().uptimeNanoseconds - wallStart
            let cpu = cpuNanoseconds() - cpuStart
            result = ["wall_nanoseconds": wall, "cpu_nanoseconds": cpu]
#endif
            precondition(checksum == cycleChecksum * UInt64(iterations / 16))
            result.merge(["mode": mode, "case": name, "iterations": iterations,
                          "checksum": checksum, "cycle_checksum": cycleChecksum,
                          "packet_sizes": input.sizes, "expected_cycle": input.expected]) { _, new in new }
            withExtendedLifetime(input) {}
        }
        let encoded = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        print(String(decoding: encoded, as: UTF8.self))
    }
}
