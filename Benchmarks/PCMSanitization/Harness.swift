import Foundation
@testable import IlliquidNativePlayback
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

private enum Operation: String {
    case unique = "sanitize_unique"
    case restoring = "sanitize_and_restore"
    case restoreOnly = "restore_only"
    case shared = "sanitize_shared_copy"
}

private struct Fixture {
    let bits: [UInt32]
    let trailingBytes: [UInt8]
    let dirty: [(Int, UInt32)]
    let expectedNonFinite: Int
    let expectedSubnormal: Int

    func makeData() -> Data {
        // Allocate each slot independently. Data(existingData) can retain shared
        // backing storage and would change the unique-buffer benchmark to COW.
        var data = Data(count: bits.count * 4 + trailingBytes.count)
        data.withUnsafeMutableBytes { bytes in
            for (index, word) in bits.enumerated() {
                bytes.storeBytes(of: word, toByteOffset: index * 4, as: UInt32.self)
            }
            for (index, byte) in trailingBytes.enumerated() {
                bytes[bits.count * 4 + index] = byte
            }
        }
        return data
    }
}

private struct Workload {
    let name: String
    let frames: Int
    let channels: Int
    let operation: Operation
    let fixtures: [Fixture]
}

private final class BufferPool {
    var buffers: [Data]
    init(_ fixtures: [Fixture]) { buffers = fixtures.map { $0.makeData() } }
}

private struct Output {
    let nonFinite: Int
    let subnormal: Int
    let sampleBits: UInt64

    var checksum: UInt64 {
        UInt64(nonFinite) &* 13 &+ UInt64(subnormal) &* 17 &+ sampleBits
    }
}

private func sampledBits(_ data: Data, sampleCount: Int) -> UInt64 {
    data.withUnsafeBytes { bytes in
        guard sampleCount > 0 else { return UInt64(bytes.count) }
        let first = bytes.loadUnaligned(fromByteOffset: 0, as: UInt32.self)
        let middle = bytes.loadUnaligned(fromByteOffset: (sampleCount / 2) * 4, as: UInt32.self)
        let last = bytes.loadUnaligned(fromByteOffset: (sampleCount - 1) * 4, as: UInt32.self)
        return UInt64(first) &+ UInt64(middle) &* 3 &+ UInt64(last) &* 5
            &+ UInt64(bytes.count)
    }
}

@inline(never)
private func restore(_ data: inout Data, fixture: Fixture) {
    guard !fixture.dirty.isEmpty else { return }
    data.withUnsafeMutableBytes { bytes in
        for (index, word) in fixture.dirty {
            bytes.storeBytes(of: word, toByteOffset: index * 4, as: UInt32.self)
        }
    }
}

@inline(never)
private func evaluate(_ workload: Workload, pool: BufferPool, index: Int) -> Output {
    let fixture = workload.fixtures[index]
    switch workload.operation {
    case .unique, .restoring:
        // Do not copy this Data to a local variable: that would add a COW owner.
        let result = sanitizeInterleavedFloatPCM(&pool.buffers[index])
        let bits = sampledBits(pool.buffers[index], sampleCount: fixture.bits.count)
        if workload.operation == .restoring {
            restore(&pool.buffers[index], fixture: fixture)
        }
        return Output(nonFinite: result.replacedNonFiniteSamples,
                      subnormal: result.replacedSubnormalSamples, sampleBits: bits)
    case .restoreOnly:
        restore(&pool.buffers[index], fixture: fixture)
        return Output(nonFinite: 0, subnormal: 0,
                      sampleBits: sampledBits(pool.buffers[index], sampleCount: fixture.bits.count))
    case .shared:
        // The pool retains the original owner throughout this invocation.
        // Every iteration intentionally measures the Data COW copy as well.
        var shared = pool.buffers[index]
        let result = sanitizeInterleavedFloatPCM(&shared)
        return Output(nonFinite: result.replacedNonFiniteSamples,
                      subnormal: result.replacedSubnormalSamples,
                      sampleBits: sampledBits(shared, sampleCount: fixture.bits.count))
    }
}

private func makeFixture(kind: String, count: Int, variant: Int, tailBytes: Bool) -> Fixture {
    let nonFinitePatterns: [UInt32] = [0x7f80_0000, 0xff80_0000, 0x7fc0_0001,
                                      0x7f80_0001, 0xffc0_1234, 0xff80_0011]
    let subnormalPatterns: [UInt32] = [0x0000_0001, 0x8000_0001, 0x007f_ffff,
                                      0x807f_ffff, 0x0040_0000, 0x8040_0000]
    var words: [UInt32] = []
    for index in 0..<count {
        var word: UInt32
        if kind == "silence" {
            word = (index + variant).isMultiple(of: 2) ? 0 : 0x8000_0000
        } else if (index + variant).isMultiple(of: 31) {
            word = 0
        } else if (index + variant).isMultiple(of: 37) {
            word = 0x8000_0000
        } else {
            word = Float(sin(Double(index + variant * 29 + 1) * 0.019) * 0.8).bitPattern
        }
        switch kind {
        case "sparse":
            if (index + variant * 7) % 1024 == 0 || index == count - 1 {
                word = index.isMultiple(of: 2)
                    ? nonFinitePatterns[(index + variant) % nonFinitePatterns.count]
                    : subnormalPatterns[(index + variant) % subnormalPatterns.count]
            }
        case "dense":
            if !(index + variant).isMultiple(of: 4) {
                word = nonFinitePatterns[(index + variant) % nonFinitePatterns.count]
            }
        case "subnormal":
            word = subnormalPatterns[(index + variant) % subnormalPatterns.count]
        case "tail":
            if index == count - 1 || (index + variant).isMultiple(of: 3) {
                word = variant.isMultiple(of: 2)
                    ? nonFinitePatterns[(index + variant) % nonFinitePatterns.count]
                    : subnormalPatterns[(index + variant) % subnormalPatterns.count]
            }
        default: break
        }
        words.append(word)
    }
    var dirty: [(Int, UInt32)] = []
    var nonFinite = 0
    var subnormal = 0
    for (index, word) in words.enumerated() {
        let exponent = word & 0x7f80_0000
        if exponent == 0x7f80_0000 {
            nonFinite += 1
            dirty.append((index, word))
        } else if exponent == 0, word & 0x007f_ffff != 0 {
            subnormal += 1
            dirty.append((index, word))
        }
    }
    let trailing = tailBytes ? (0..<(variant % 4)).map { UInt8(0xa1 + $0) } : []
    return Fixture(bits: words, trailingBytes: trailing, dirty: dirty,
                   expectedNonFinite: nonFinite, expectedSubnormal: subnormal)
}

private func makeWorkloads() -> [Workload] {
    var workloads: [Workload] = []
    let families: [(String, String, Operation)] = [
        ("healthy_sine", "healthy", .unique),
        ("silence", "silence", .unique),
        ("sparse_invalid", "sparse", .restoring),
        ("dense_invalid", "dense", .restoring),
        ("subnormals", "subnormal", .restoring),
        ("shared_healthy", "healthy", .shared),
        ("sparse_restore_control", "sparse", .restoreOnly),
        ("dense_restore_control", "dense", .restoreOnly),
        ("subnormal_restore_control", "subnormal", .restoreOnly),
    ]
    for (frames, channels) in [(1024, 1), (1024, 2), (1024, 6), (1024, 8), (4096, 8)] {
        for (name, kind, operation) in families {
            let fixtures = (0..<16).map { makeFixture(kind: kind, count: frames * channels,
                                                    variant: $0, tailBytes: false) }
            workloads.append(Workload(name: "\(name)/\(frames)x\(channels)", frames: frames,
                                      channels: channels, operation: operation, fixtures: fixtures))
        }
    }
    for count in [0, 1, 7, 8, 9] {
        for (name, operation) in [("tiny_tail", Operation.restoring), ("tiny_restore_control", .restoreOnly)] {
            let fixtures = (0..<16).map { makeFixture(kind: "tail", count: count, variant: $0, tailBytes: true) }
            workloads.append(Workload(name: "\(name)/\(count)", frames: count, channels: 1,
                                      operation: operation, fixtures: fixtures))
        }
    }
    return workloads
}

private func cpuNanoseconds() -> UInt64 {
    var timestamp = timespec()
    precondition(clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &timestamp) == 0)
    return UInt64(timestamp.tv_sec) * 1_000_000_000 + UInt64(timestamp.tv_nsec)
}

private func writeJSON(_ object: Any) throws {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([10]))
}

private func metadata(_ workload: Workload) -> [String: Any] {
    ["case": workload.name, "operation": workload.operation.rawValue,
     "frames": workload.frames, "channels": workload.channels,
     "samples": workload.frames * workload.channels,
     "nominal_payload_bytes": workload.frames * workload.channels * 4,
     "trailing_byte_variants": workload.name.hasPrefix("tiny") ? [0, 1, 2, 3] : [0],
     "variants": workload.fixtures.count,
     "source_nonfinite_per_cycle": workload.fixtures.reduce(0) { $0 + $1.expectedNonFinite },
     "source_subnormal_per_cycle": workload.fixtures.reduce(0) { $0 + $1.expectedSubnormal }]
}

@main
private enum Main {
    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        func value(_ option: String) -> String? {
            guard let index = arguments.firstIndex(of: option), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        var selectedNames: Set<String>?
        if let path = value("--cases-file") {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            selectedNames = Set(try JSONDecoder().decode([String].self, from: data))
        }
        var workloads = makeWorkloads().filter { workload in
            if let selectedNames, !selectedNames.contains(workload.name) { return false }
            return value("--filter").map { workload.name.contains($0) } ?? true
        }
        if arguments.contains("--reverse") { workloads.reverse() }
        precondition(!workloads.isEmpty, "No matching benchmark cases")
        if arguments.contains("--list") {
            try writeJSON(workloads.map(metadata))
            return
        }
        if arguments.contains("--verify") {
            for workload in workloads {
                var record = metadata(workload)
                var outputs: [[String: Any]] = []
                for fixture in workload.fixtures {
                    var unique = fixture.makeData()
                    let before = unique.base64EncodedString()
                    let result = sanitizeInterleavedFloatPCM(&unique)
                    let after = unique.base64EncodedString()
                    precondition(result.replacedNonFiniteSamples == fixture.expectedNonFinite)
                    precondition(result.replacedSubnormalSamples == fixture.expectedSubnormal)
                    restore(&unique, fixture: fixture)
                    precondition(unique.base64EncodedString() == before, "Restoration must recover every original bit")
                    let owner = fixture.makeData()
                    var shared = owner
                    let sharedResult = sanitizeInterleavedFloatPCM(&shared)
                    precondition(shared.base64EncodedString() == after)
                    precondition(owner.base64EncodedString() == before, "Sanitation must preserve shared aliases")
                    precondition(sharedResult == result)
                    outputs.append(["input_base64": before, "sanitized_base64": after,
                                    "nonfinite": result.replacedNonFiniteSamples,
                                    "subnormal": result.replacedSubnormalSamples])
                }
                record["outputs"] = outputs
                try writeJSON(record)
            }
            return
        }
        var iterationCounts: [String: Int] = [:]
        if let path = value("--iterations-file") {
            iterationCounts = try JSONDecoder().decode([String: Int].self,
                from: Data(contentsOf: URL(fileURLWithPath: path)))
        }
        let defaultIterations = value("--iterations").flatMap(Int.init) ?? 512
        for workload in workloads {
            let iterations = iterationCounts[workload.name] ?? defaultIterations
            precondition(iterations > 0)
            let pool = BufferPool(workload.fixtures)
            var warmupChecksum: UInt64 = 0
            for index in 0..<64 {
                warmupChecksum &+= evaluate(workload, pool: pool, index: index & 15).checksum
            }
            let cpuStarted = cpuNanoseconds()
            let wallStarted = DispatchTime.now().uptimeNanoseconds
            var checksum: UInt64 = 0
            var replacedNonFinite = 0
            var replacedSubnormal = 0
            for index in 0..<iterations {
                let result = evaluate(workload, pool: pool, index: index & 15)
                checksum &+= result.checksum
                replacedNonFinite += result.nonFinite
                replacedSubnormal += result.subnormal
            }
            let elapsed = DispatchTime.now().uptimeNanoseconds - wallStarted
            let cpuElapsed = cpuNanoseconds() - cpuStarted
            // Independent count totals ensure dirty inputs are reintroduced on
            // EVERY iteration; a self-cleaning fixture cannot silently pass.
            var expectedNonFinite = 0
            var expectedSubnormal = 0
            if workload.operation != .restoreOnly {
                for index in 0..<iterations {
                    expectedNonFinite += workload.fixtures[index & 15].expectedNonFinite
                    expectedSubnormal += workload.fixtures[index & 15].expectedSubnormal
                }
            }
            precondition(replacedNonFinite == expectedNonFinite, "Dirty non-finite fixture was not restored")
            precondition(replacedSubnormal == expectedSubnormal, "Dirty subnormal fixture was not restored")
            var record = metadata(workload)
            record["iterations"] = iterations
            record["elapsed_ns"] = elapsed
            record["cpu_elapsed_ns"] = cpuElapsed
            record["ns_per_iteration"] = Double(elapsed) / Double(iterations)
            record["cpu_ns_per_iteration"] = Double(cpuElapsed) / Double(iterations)
            record["checksum"] = String(checksum, radix: 16)
            record["warmup_checksum"] = String(warmupChecksum, radix: 16)
            record["replaced_nonfinite"] = replacedNonFinite
            record["replaced_subnormal"] = replacedSubnormal
            record["expected_nonfinite"] = expectedNonFinite
            record["expected_subnormal"] = expectedSubnormal
            try writeJSON(record)
        }
    }
}
