import CFFmpeg
import Glibc
import Dispatch
import Foundation

// Only this call-site adapter selects the three pinned production strategies.
// Corpus, allocation, warmup, checksum, and timing code are common to all arms.
@inline(never)
private func classify(_ input: Input) -> Bool {
#if RAW_BUFFER
    return input.isPGS ? PGSSubtitlePacket.isAcquisition(input.packet)
        : DVBSubtitlePacket.isAcquisition(input.packet, compositionPageID: input.pageID)
#elseif DATA_NOCOPY
    return FFmpegDemuxer.isSubtitleAcquisition(
        input.packet, isPGS: input.isPGS, compositionPageID: input.pageID
    )
#else
    return input.packet.data.map { data in
        input.isPGS ? PGSSubtitlePacket.isAcquisition(data)
            : DVBSubtitlePacket.isAcquisition(data, compositionPageID: input.pageID)
    } == true
#endif
}

private let workloadNames = [
    "pgs_tiny", "dvb_tiny",
    "pgs_mixed_4k", "dvb_mixed_4k",
    "pgs_mixed_64k", "dvb_mixed_64k",
    "pgs_mixed_256k", "dvb_mixed_256k",
]

private struct Fixture {
    let name: String
    let isPGS: Bool
    let bytes: [UInt8]
    let expected: Bool?
    var pageID: UInt16? = 1
    var reportedSize: Int32? = nil
}

private struct Input {
    let packet: FFmpegPacket
    let isPGS: Bool
    let pageID: UInt16?
}

private func makeInput(_ fixture: Fixture) throws -> Input {
    var allocation = av_packet_alloc()
    guard let raw = allocation else {
        throw FFmpegError(operation: "Allocate acquisition benchmark packet", code: -12)
    }
    defer { av_packet_free(&allocation) }
    if !fixture.bytes.isEmpty {
        try checkFFmpeg(av_new_packet(raw, Int32(fixture.bytes.count)),
                        operation: "Allocate acquisition benchmark payload")
        fixture.bytes.withUnsafeBufferPointer { bytes in
            raw.pointee.data!.update(from: bytes.baseAddress!, count: bytes.count)
        }
    }
    if let size = fixture.reportedSize { raw.pointee.size = size }
    let packet = try FFmpegPacket(taking: &allocation,
        timeBase: AVRational(num: 1, den: 90_000), generation: 0)
    return Input(packet: packet, isPGS: fixture.isPGS, pageID: fixture.pageID)
}

private func word(_ value: Int) -> [UInt8] {
    precondition((0...65_535).contains(value))
    return [UInt8(value >> 8), UInt8(value & 255)]
}

private func segment(_ isPGS: Bool, kind: UInt8, payload: [UInt8],
                     pageID: UInt16 = 1) -> [UInt8] {
    let header = isPGS ? [kind] : [0x0F, kind] + word(Int(pageID))
    return header + word(payload.count) + payload
}

private func acquisition(_ isPGS: Bool, state: UInt8? = nil,
                         pageID: UInt16 = 1) -> [UInt8] {
    if isPGS {
        return segment(true, kind: 0x16,
            payload: [5, 0, 2, 208, 0x10, 0, 1, state ?? 0x80, 0, 0, 0])
    }
    return segment(false, kind: 0x10, payload: [2, (state ?? 1) << 2], pageID: pageID)
}

private func objects(_ isPGS: Bool, payloadBytes: Int, seed: Int) -> [UInt8] {
    // Legal segment framing and deterministic object-sized payloads. These
    // bytes exercise header skipping; they are not claimed to decode to pixels.
    var result: [UInt8] = []
    var remaining = payloadBytes
    while remaining > 0 {
        let count = min(remaining, 65_535)
        let payload = (0..<count).map { UInt8(truncatingIfNeeded: $0 &* 29 &+ seed &* 17 &+ 1) }
        result += segment(isPGS, kind: isPGS ? 0x15 : 0x13, payload: payload)
        remaining -= count
    }
    return result
}

private func workload(_ name: String) -> [Fixture] {
    precondition(workloadNames.contains(name), "Unknown workload")
    let isPGS = name.hasPrefix("pgs_")
    let size: Int
    if name.hasSuffix("_4k") { size = 4_096 }
    else if name.hasSuffix("_64k") { size = 65_536 }
    else if name.hasSuffix("_256k") { size = 262_144 }
    else { size = 0 }
    return (0..<16).map { seed in
        let acquired = acquisition(isPGS)
        let normal = acquisition(isPGS, state: 0)
        let bytes: [UInt8]
        let expected: Bool
        if size == 0 {
            switch seed & 3 {
            case 0:
                bytes = segment(isPGS, kind: 0x80, payload: [])
                expected = false
            case 1:
                bytes = acquired
                expected = true
            case 2:
                bytes = normal
                expected = false
            default:
                bytes = acquisition(isPGS, state: isPGS ? 0x40 : 2)
                expected = true
            }
        } else {
            let object = objects(isPGS, payloadBytes: size + seed, seed: seed)
            switch seed & 3 {
            case 0:
                bytes = acquired + object
                expected = true
            case 1:
                bytes = object + acquired
                expected = true
            case 2:
                bytes = object
                expected = false
            default:
                bytes = normal + object + (isPGS ? [] : acquisition(false, pageID: 2))
                expected = false
            }
        }
        return Fixture(name: "\(name)-\(seed)", isPGS: isPGS, bytes: bytes, expected: expected)
    }
}

private func edgeCases() -> [Fixture] {
    var fixtures: [Fixture] = []
    func add(_ name: String, _ isPGS: Bool, _ bytes: [UInt8], _ expected: Bool?,
             pageID: UInt16? = 1, reportedSize: Int32? = nil) {
        fixtures.append(Fixture(name: name, isPGS: isPGS, bytes: bytes,
            expected: expected, pageID: pageID, reportedSize: reportedSize))
    }
    for isPGS in [true, false] {
        let codec = isPGS ? "pgs" : "dvb"
        let good = acquisition(isPGS)
        for size: Int32 in [0, 17, -1, Int32.min] {
            add("\(codec)-null-\(size)", isPGS, [], false, reportedSize: size)
        }
        for size: Int32 in [0, -1, Int32.min] {
            add("\(codec)-nonpositive-\(size)", isPGS, good, false, reportedSize: size)
        }
        for count in 0..<good.count {
            add("\(codec)-prefix-\(count)", isPGS, Array(good.prefix(count)), false)
        }
        let badTail: [UInt8] = isPGS
            ? [0x15, 0xFF, 0xFF] : [0x0F, 0x13, 0, 1, 0xFF, 0xFF]
        add("\(codec)-accepted-before-malformed", isPGS, good + badTail, true)
        add("\(codec)-malformed-before-acquisition", isPGS, badTail + good, false)
        let embedded = segment(isPGS, kind: isPGS ? 0x15 : 0x13,
            payload: good + Array(repeating: 0x16, count: 65_535 - good.count))
        add("\(codec)-embedded-header", isPGS, embedded, false)
        add("\(codec)-maximum-segments", isPGS, embedded + embedded + good, true)
        add("\(codec)-short-control", isPGS,
            segment(isPGS, kind: isPGS ? 0x16 : 0x10,
                    payload: Array(repeating: 0xFF, count: isPGS ? 10 : 1)), false)
    }
    for state: UInt8 in [0, 0x40, 0x80, 0xC0] {
        for low: UInt8 in [0, 0x3F] {
            add("pgs-state-\(state)-\(low)", true,
                acquisition(true, state: state | low), state != 0)
        }
    }
    for page: UInt16 in [0, 1, UInt16.max] {
        for state: UInt8 in [0, 1, 2, 3] {
            let bytes = acquisition(false, state: state, pageID: page)
            let expected = state == 1 || state == 2
            add("dvb-page-\(page)-state-\(state)-matching", false, bytes, expected, pageID: page)
            add("dvb-page-\(page)-state-\(state)-any", false, bytes, expected, pageID: nil)
            add("dvb-page-\(page)-state-\(state)-other", false, bytes, false, pageID: page &+ 1)
        }
    }
    add("dvb-invalid-sync", false, [0x20] + acquisition(false), false)
    add("dvb-wrong-page-before-selected", false,
        acquisition(false, pageID: 2) + acquisition(false), true)
    add("dvb-wrong-page-before-malformed", false,
        acquisition(false, pageID: 2) + [0x0F, 0x10, 0, 1, 0xFF, 0xFF], false)

    var random: UInt64 = 0xAC01_51A1_2026_1028
    func next() -> UInt8 {
        random = random &* 6_364_136_223_846_793_005 &+ 1
        return UInt8(truncatingIfNeeded: random >> 24)
    }
    for index in 0..<256 {
        let count = Int(next())
        let bytes = (0..<count).map { _ in next() }
        add("random-\(index)", index & 1 == 0, bytes, nil,
            pageID: index % 3 == 0 ? nil : 1)
    }
    for isPGS in [true, false] {
        let original = acquisition(isPGS)
        for index in 0..<64 {
            var bytes = original
            bytes[index % bytes.count] ^= next() | 1
            add("mutated-\(isPGS)-\(index)", isPGS, bytes, nil)
        }
    }
    return fixtures
}

private struct Verification: Codable {
    struct Row: Codable {
        let name: String
        let isPGS: Bool
        let pageID: UInt16?
        let payloadBytes: Int
        let reportedSize: Int32?
        let result: Bool
        let authoredExpectation: Bool
    }
    let ffmpegVersion: String
    let rows: [Row]
}

private func verify() throws -> Verification {
    let fixtures = workloadNames.flatMap(workload) + edgeCases()
    var rows: [Verification.Row] = []
    for fixture in fixtures {
        let result = classify(try makeInput(fixture))
        if let expected = fixture.expected {
            precondition(result == expected, "Wrong authored expectation: \(fixture.name)")
        }
        rows.append(.init(name: fixture.name, isPGS: fixture.isPGS, pageID: fixture.pageID,
            payloadBytes: fixture.bytes.count, reportedSize: fixture.reportedSize,
            result: result, authoredExpectation: fixture.expected != nil))
    }
    return Verification(ffmpegVersion: String(cString: av_version_info()), rows: rows)
}

@inline(never)
private func exercise(_ inputs: [Input], iterations: Int) -> UInt64 {
    precondition(inputs.count == 16 && iterations > 0 && iterations % inputs.count == 0)
    var checksum: UInt64 = 0
    for index in 0..<iterations {
        let value: UInt64 = classify(inputs[index & 15]) ? 31 : 17
        checksum &+= value &* UInt64((index & 15) + 1)
    }
    return checksum
}

private func cpuNanoseconds() -> UInt64 {
    var value = timespec()
    precondition(clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &value) == 0)
    return UInt64(value.tv_sec) * 1_000_000_000 + UInt64(value.tv_nsec)
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
    let first: Bool
    let last: Bool
}

private func measure(_ name: String, iterations: Int) throws -> Measurement {
    let fixtures = workload(name)
    let inputs = try fixtures.map(makeInput)
    for (fixture, input) in zip(fixtures, inputs) {
        precondition(classify(input) == fixture.expected!, "Timed fixture mismatch")
    }
    let cycle = exercise(inputs, iterations: 16)
    let warmupIterations = 4_096
    let warmup = exercise(inputs, iterations: warmupIterations)
    let cpuStart = cpuNanoseconds()
    let wallStart = DispatchTime.now().uptimeNanoseconds
    let checksum = exercise(inputs, iterations: iterations)
    let elapsed = DispatchTime.now().uptimeNanoseconds - wallStart
    let cpu = cpuNanoseconds() - cpuStart
    precondition(checksum == cycle &* UInt64(iterations / 16), "Timed checksum mismatch")
    return Measurement(workload: name, iterations: iterations, warmupIterations: warmupIterations,
        payloadBytes: fixtures.map { $0.bytes.count }, elapsedNanoseconds: elapsed,
        cpuNanoseconds: cpu, checksum: checksum, cycleChecksum: cycle,
        warmupChecksum: warmup, first: classify(inputs[0]), last: classify(inputs[15]))
}

@main
private enum Main {
    static func main() throws {
        let arguments = CommandLine.arguments
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let output: Data
        if arguments.count == 2 && arguments[1] == "verify" {
            output = try encoder.encode(verify())
        } else if arguments.count == 4 && arguments[1] == "measure",
                  let iterations = Int(arguments[3]) {
            output = try encoder.encode(measure(arguments[2], iterations: iterations))
        } else {
            fatalError("Usage: benchmark verify | benchmark measure CASE ITERATIONS")
        }
        FileHandle.standardOutput.write(output)
        FileHandle.standardOutput.write(Data([10]))
    }
}

