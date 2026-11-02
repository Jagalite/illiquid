import CFFmpeg
import Dispatch
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// Match the two demux call sites. The owner and parsers come from the actual
// production sources; only this benchmark adapter selects the old/new API.
@inline(never)
private func classify(_ packet: FFmpegPacket, pgs: Bool, page: UInt16?) -> Bool {
#if BASELINE
    return packet.data.map { data in
        pgs ? PGSSubtitlePacket.isAcquisition(data)
            : DVBSubtitlePacket.isAcquisition(data, compositionPageID: page)
    } == true
#else
    return pgs ? PGSSubtitlePacket.isAcquisition(packet)
        : DVBSubtitlePacket.isAcquisition(packet, compositionPageID: page)
#endif
}

private struct Fixture {
    let name: String
    let bytes: [UInt8]
    var reportedSize: Int32? = nil
    var expectedPGS: Bool? = nil
    var expectedDVBAny: Bool? = nil
    var expectedDVBSelected: Bool? = nil
}

private struct Observation: Codable, Equatable {
    let name: String
    let pgs: Bool
    let dvbAny: Bool
    let dvbSelected: Bool
    let expectedPGS: Bool?
    let expectedDVBAny: Bool?
    let expectedDVBSelected: Bool?
}

private func require(_ condition: Bool, _ message: String) throws {
    if !condition {
        throw NSError(domain: "SubtitleAcquisitionBorrow", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: message])
    }
}

private func makePacket(_ fixture: Fixture) throws -> FFmpegPacket {
    var allocation = av_packet_alloc()
    guard let raw = allocation else {
        throw FFmpegError(operation: "Allocate benchmark packet", code: -12)
    }
    defer { av_packet_free(&allocation) }
    if !fixture.bytes.isEmpty {
        try checkFFmpeg(av_new_packet(raw, Int32(fixture.bytes.count)),
                        operation: "Allocate benchmark payload")
        fixture.bytes.withUnsafeBufferPointer { bytes in
            raw.pointee.data!.update(from: bytes.baseAddress!, count: bytes.count)
        }
    }
    if let size = fixture.reportedSize { raw.pointee.size = size }
    return try FFmpegPacket(taking: &allocation, timeBase: AVRational(num: 1, den: 90_000),
                            generation: 7)
}

private func word(_ value: Int) -> [UInt8] {
    precondition((0...65_535).contains(value))
    return [UInt8(value >> 8), UInt8(value & 255)]
}

private func pgsSegment(_ kind: UInt8, _ body: [UInt8]) -> [UInt8] {
    [kind] + word(body.count) + body
}

private func pgsComposition(_ state: UInt8) -> [UInt8] {
    // The acquisition scanner only requires a complete composition header.
    pgsSegment(0x16, [0x07, 0x80, 0x04, 0x38, 0x10, 0, 1, state, 0, 0, 0])
}

private func dvbSegment(_ kind: UInt8, page: Int = 0x1234, _ body: [UInt8]) -> [UInt8] {
    [0x0F, kind] + word(page) + word(body.count) + body
}

private func dvbComposition(_ flags: UInt8, page: Int = 0x1234) -> [UInt8] {
    dvbSegment(0x10, page: page, [5, flags])
}

private func objectSegments(pgs: Bool, size: Int, seed: Int) -> [UInt8] {
    var output: [UInt8] = []
    var remaining = size
    while remaining > 0 {
        let count = min(remaining, 65_535)
        let body = (0..<count).map { UInt8(truncatingIfNeeded: $0 &* 29 &+ seed &* 17) }
        output += pgs ? pgsSegment(0x15, body) : dvbSegment(0x13, body)
        remaining -= count
    }
    return output
}

private struct Workload {
    let name: String
    let pgs: Bool
    let fixtures: [Fixture]
}

private func workloads() -> [Workload] {
    let definitions: [(String, Bool, Int)] = [
        ("pgs_tiny", true, 0), ("pgs_object_4k", true, 4_096),
        ("pgs_object_64k", true, 65_535), ("pgs_acquisition_256k", true, 262_144),
        ("dvb_tiny", false, 0), ("dvb_object_4k", false, 4_096),
        ("dvb_object_64k", false, 65_535), ("dvb_acquisition_256k", false, 262_144),
    ]
    return definitions.map { name, pgs, size in
        let fixtures = (0..<16).map { seed in
            let acquisition = seed % 2 == 0
            let header = pgs ? pgsComposition(acquisition ? 0x80 : 0)
                : dvbComposition(acquisition ? 4 : 0)
            let objects = objectSegments(pgs: pgs, size: size, seed: seed)
            // Alternate early-return and late-header inputs; a large body is
            // skipped by length, never treated as a set of nested headers.
            let bytes = seed % 4 < 2 ? header + objects : objects + header
            return Fixture(name: "\(name)-\(seed)", bytes: bytes,
                           expectedPGS: pgs ? acquisition : nil,
                           expectedDVBAny: pgs ? false : acquisition,
                           expectedDVBSelected: pgs ? false : acquisition)
        }
        return Workload(name: name, pgs: pgs, fixtures: fixtures)
    }
}

private func verificationFixtures() -> [Fixture] {
    var fixtures = workloads().flatMap(\.fixtures)
    fixtures += [
        Fixture(name: "empty", bytes: [], expectedPGS: false,
                expectedDVBAny: false, expectedDVBSelected: false),
        Fixture(name: "null-positive", bytes: [], reportedSize: 100, expectedPGS: false,
                expectedDVBAny: false, expectedDVBSelected: false),
        Fixture(name: "negative", bytes: pgsComposition(0x80), reportedSize: -1,
                expectedPGS: false, expectedDVBAny: false, expectedDVBSelected: false),
        Fixture(name: "zero", bytes: dvbComposition(4), reportedSize: 0,
                expectedPGS: false, expectedDVBAny: false, expectedDVBSelected: false),
    ]
    for value in 0...255 {
        let state = UInt8(value)
        let dvbState = (state >> 2) & 3
        fixtures.append(Fixture(name: "pgs-state-\(value)", bytes: pgsComposition(state),
                                expectedPGS: state & 0xC0 != 0,
                                expectedDVBAny: false, expectedDVBSelected: false))
        for page in [0, 0x1234, 0x4321, 65_535] {
            let acquired = dvbState == 1 || dvbState == 2
            fixtures.append(Fixture(name: "dvb-state-\(value)-page-\(page)",
                                    bytes: dvbComposition(state, page: page),
                                    expectedDVBAny: acquired,
                                    expectedDVBSelected: acquired && page == 0x1234))
        }
    }
    for pgs in [true, false] {
        let label = pgs ? "pgs" : "dvb"
        let acquisition = pgs ? pgsComposition(0x40) : dvbComposition(8)
        let update = pgs ? pgsComposition(0) : dvbComposition(0)
        let unknown = pgs ? pgsSegment(0x7F, [1, 2, 3]) : dvbSegment(0x7F, [1, 2, 3])
        let malformed: [UInt8] = pgs ? [0x15, 0xFF, 0xFF] : [0x0F, 0x13, 0x12, 0x34, 0xFF, 0xFF]
        for count in 0..<acquisition.count {
            fixtures.append(Fixture(name: "\(label)-truncated-\(count)",
                                    bytes: Array(acquisition.prefix(count)),
                                    expectedPGS: pgs ? false : nil,
                                    expectedDVBAny: pgs ? nil : false,
                                    expectedDVBSelected: pgs ? nil : false))
        }
        let authored: [(String, [UInt8], Bool)] = [
            ("acquisition", acquisition, true),
            ("update", update, false),
            ("unknown", unknown + acquisition, true),
            ("early-success", acquisition + malformed, true),
            ("malformed-before", malformed + acquisition, false),
            ("update-then-acquisition", update + acquisition, true),
            ("acquisition-then-update", acquisition + update, true),
            ("multiple-updates", update + update, false),
        ]
        for (name, bytes, expected) in authored {
            fixtures.append(Fixture(name: "\(label)-\(name)", bytes: bytes,
                                    expectedPGS: pgs ? expected : nil,
                                    expectedDVBAny: pgs ? nil : expected,
                                    expectedDVBSelected: pgs ? nil : expected))
        }
        let hidden = pgs ? pgsSegment(0x15, acquisition) : dvbSegment(0x13, acquisition)
        fixtures.append(Fixture(name: "\(label)-nested-fake-header", bytes: hidden,
                                expectedPGS: pgs ? false : nil,
                                expectedDVBAny: pgs ? nil : false,
                                expectedDVBSelected: pgs ? nil : false))
    }
    fixtures.append(Fixture(name: "dvb-ancillary-before-selected",
                            bytes: dvbComposition(4, page: 0x4321) + dvbComposition(8),
                            expectedDVBAny: true, expectedDVBSelected: true))
    fixtures.append(Fixture(name: "dvb-wrong-sync", bytes: [0] + dvbComposition(4),
                            expectedDVBAny: false, expectedDVBSelected: false))
    var random: UInt64 = 0xBADC_0FFE_E123_4567
    func next() -> UInt8 {
        random = random &* 6_364_136_223_846_793_005 &+ 1
        return UInt8(truncatingIfNeeded: random >> 24)
    }
    for index in 0..<512 {
        let count = Int(next())
        let bytes = (0..<count).map { _ in next() }
        fixtures.append(Fixture(name: "random-\(index)", bytes: bytes))
    }
    for index in 0..<256 {
        var bytes = index % 2 == 0 ? pgsComposition(0x80) : dvbComposition(4)
        bytes[index % bytes.count] ^= next() | 1
        fixtures.append(Fixture(name: "mutated-\(index)", bytes: bytes))
    }
    return fixtures
}

private func emit<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    print(String(decoding: try encoder.encode(value), as: UTF8.self))
}

private func verify() throws {
    var rows: [Observation] = []
    var releasedOwners = 0
    for fixture in verificationFixtures() {
        var packet: FFmpegPacket? = try makePacket(fixture)
        weak let owner = packet
        let originalPointer = packet!.pointer
        let originalData = originalPointer!.pointee.data
        let originalBuffer = originalPointer!.pointee.buf
        let originalReferences = originalBuffer.map { av_buffer_get_ref_count($0) }
        let result = Observation(name: fixture.name,
                                 pgs: classify(packet!, pgs: true, page: nil),
                                 dvbAny: classify(packet!, pgs: false, page: nil),
                                 dvbSelected: classify(packet!, pgs: false, page: 0x1234),
                                 expectedPGS: fixture.expectedPGS,
                                 expectedDVBAny: fixture.expectedDVBAny,
                                 expectedDVBSelected: fixture.expectedDVBSelected)
        if let expected = fixture.expectedPGS {
            try require(result.pgs == expected, "PGS expectation: \(fixture.name)")
        }
        if let expected = fixture.expectedDVBAny {
            try require(result.dvbAny == expected, "DVB any-page expectation: \(fixture.name)")
        }
        if let expected = fixture.expectedDVBSelected {
            try require(result.dvbSelected == expected, "DVB selected-page expectation: \(fixture.name)")
        }
        try require(packet!.pointer == originalPointer
                    && originalPointer!.pointee.data == originalData
                    && originalPointer!.pointee.buf == originalBuffer,
                    "Packet ownership changed: \(fixture.name)")
        if let originalBuffer {
            try require(av_buffer_get_ref_count(originalBuffer) == originalReferences,
                        "Native buffer references changed: \(fixture.name)")
        }
        if let originalData {
            try require(Array(UnsafeBufferPointer(start: originalData, count: fixture.bytes.count))
                        == fixture.bytes, "Payload mutated: \(fixture.name)")
        }
        packet = nil
        try require(owner == nil, "Parser retained owner: \(fixture.name)")
        releasedOwners += 1
        rows.append(result)
    }
    struct Trace: Encodable {
        let ffmpegVersion: String
        let avcodecVersion: UInt32
        let avutilVersion: UInt32
        let releasedOwners: Int
        let cases: [Observation]
    }
    try emit(Trace(ffmpegVersion: String(cString: av_version_info()),
                   avcodecVersion: avcodec_version(), avutilVersion: avutil_version(),
                   releasedOwners: releasedOwners, cases: rows))
}

private func cpuNanoseconds() -> UInt64 {
    var value = timespec()
    precondition(clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &value) == 0)
    return UInt64(value.tv_sec) * 1_000_000_000 + UInt64(value.tv_nsec)
}

@inline(never)
private func run(_ packets: [FFmpegPacket], pgs: Bool, iterations: Int) -> UInt64 {
    var checksum: UInt64 = 0
    for index in 0..<iterations {
        let slot = index & 15
        let acquired = classify(packets[slot], pgs: pgs, page: 0x1234)
        checksum &+= UInt64(slot + 1) &* (acquired ? 17 : 3)
    }
    return checksum
}

private func measure(workload name: String, iterations: Int) throws {
    try require(iterations > 0 && iterations % 16 == 0, "Iterations must be positive complete cycles")
    guard let workload = workloads().first(where: { $0.name == name }) else {
        throw NSError(domain: "SubtitleAcquisitionBorrow", code: 2)
    }
    let packets = try workload.fixtures.map(makePacket)
    let cycle = run(packets, pgs: workload.pgs, iterations: 16)
    // Even slots acquire: 64 * 17 + 72 * 3. This expectation is independent
    // of either parser and prevents an always-true/always-false timing result.
    try require(cycle == 1_304, "Authored timing-cycle expectation failed")
    let warmup = run(packets, pgs: workload.pgs, iterations: 4_096)
    try require(warmup == cycle &* 256, "Warmup checksum mismatch")
    let cpuStart = cpuNanoseconds()
    let wallStart = DispatchTime.now().uptimeNanoseconds
    let checksum = run(packets, pgs: workload.pgs, iterations: iterations)
    let wallElapsed = DispatchTime.now().uptimeNanoseconds - wallStart
    let cpuElapsed = cpuNanoseconds() - cpuStart
    try require(checksum == cycle &* UInt64(iterations / 16), "Timed checksum mismatch")
    struct Measurement: Encodable {
        let workload: String
        let iterations: Int
        let elapsedNanoseconds: UInt64
        let cpuNanoseconds: UInt64
        let checksum: UInt64
        let cycleChecksum: UInt64
        let payloadBytes: [Int]
    }
    try emit(Measurement(workload: name, iterations: iterations,
                         elapsedNanoseconds: wallElapsed, cpuNanoseconds: cpuElapsed,
                         checksum: checksum, cycleChecksum: cycle,
                         payloadBytes: packets.map(\.byteCount)))
}

#if os(Linux)
private struct AllocationMeter {
    typealias Action = @convention(c) () -> Void
    typealias Read = @convention(c) () -> UInt64

    let begin: Action
    let end: Action
    let requests: Read
    let bytes: Read

    init() throws {
        guard let begin = dlsym(nil, "meter_begin"),
              let end = dlsym(nil, "meter_end"),
              let requests = dlsym(nil, "meter_requests"),
              let bytes = dlsym(nil, "meter_bytes") else {
            throw NSError(domain: "SubtitleAcquisitionBorrow", code: 4,
                          userInfo: [NSLocalizedDescriptionKey:
                            "Allocation mode requires the allocmeter.c library through LD_PRELOAD"])
        }
        self.begin = unsafeBitCast(begin, to: Action.self)
        self.end = unsafeBitCast(end, to: Action.self)
        self.requests = unsafeBitCast(requests, to: Read.self)
        self.bytes = unsafeBitCast(bytes, to: Read.self)
    }
}
#endif

private func allocations(workload name: String, iterations: Int) throws {
#if os(Linux)
    try require(iterations > 0 && iterations % 16 == 0, "Iterations must be positive complete cycles")
    let meter = try AllocationMeter()
    guard let workload = workloads().first(where: { $0.name == name }) else {
        throw NSError(domain: "SubtitleAcquisitionBorrow", code: 2)
    }
    let packets = try workload.fixtures.map(makePacket)
    let cycle = run(packets, pgs: workload.pgs, iterations: 16)
    try require(cycle == 1_304, "Authored allocation-cycle expectation failed")
    let warmup = run(packets, pgs: workload.pgs, iterations: 4_096)
    try require(warmup == cycle &* 256, "Allocation warmup checksum mismatch")

    // The preloaded meter counts malloc/calloc/realloc requests and requested
    // bytes. Fixture creation, warmup, checks, and JSON encoding are excluded.
    // This is a separate observation mode; measure() never activates the meter.
    meter.begin()
    let checksum = run(packets, pgs: workload.pgs, iterations: iterations)
    meter.end()
    let allocationRequests = meter.requests()
    let requestedBytes = meter.bytes()
    try require(checksum == cycle &* UInt64(iterations / 16), "Allocation checksum mismatch")

    struct AllocationObservation: Encodable {
        let workload: String
        let iterations: Int
        let checksum: UInt64
        let cycleChecksum: UInt64
        let payloadBytes: [Int]
        let allocationRequests: UInt64
        let requestedBytes: UInt64
    }
    try emit(AllocationObservation(workload: name, iterations: iterations,
                                    checksum: checksum, cycleChecksum: cycle,
                                    payloadBytes: packets.map(\.byteCount),
                                    allocationRequests: allocationRequests,
                                    requestedBytes: requestedBytes))
#else
    throw NSError(domain: "SubtitleAcquisitionBorrow", code: 5,
                  userInfo: [NSLocalizedDescriptionKey: "Allocation mode is supported only on Linux"])
#endif
}

@main
private enum Driver {
    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments == ["verify"] {
            try verify()
        } else if arguments.count == 3, arguments[0] == "measure",
                  let iterations = Int(arguments[2]) {
            try measure(workload: arguments[1], iterations: iterations)
        } else if arguments.count == 3, arguments[0] == "allocations",
                  let iterations = Int(arguments[2]) {
            try allocations(workload: arguments[1], iterations: iterations)
        } else {
            throw NSError(domain: "SubtitleAcquisitionBorrow", code: 3,
                          userInfo: [NSLocalizedDescriptionKey:
                            "Use verify, measure WORKLOAD ITERATIONS, or allocations WORKLOAD ITERATIONS"])
        }
    }
}
