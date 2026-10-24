import Foundation
import Darwin

private let workloads = ["continuous_short", "long_movie", "scrubbing", "repeated_display"]

private func inputs(for workload: String) -> [Double] {
    var seed: UInt64 = 0xA19C_357E
    return (0..<4_096).map { index in
        switch workload {
        case "continuous_short":
            return Double(index / 5) + Double(index % 5) / 5
        case "long_movie":
            return 7_200 + Double(index / 5) + Double(index % 5) / 5
        case "scrubbing":
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(seed % 86_400_000) / 1_000
        case "repeated_display":
            return 42 + Double(index % 10) / 10
        default:
            preconditionFailure("Unknown workload")
        }
    }
}

@inline(never)
private func format(_ interval: Double) -> String {
    TimecodeFormatter.string(from: interval)
}

@inline(never)
private func consume(_ value: String, checksum: inout UInt64) {
    for byte in value.utf8 {
        checksum = (checksum ^ UInt64(byte)) &* 1_099_511_628_211
    }
    checksum = (checksum ^ 0xFF) &* 1_099_511_628_211
}

private func cpuTime() -> UInt64 {
    var value = timespec()
    precondition(clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &value) == 0)
    return UInt64(value.tv_sec) * 1_000_000_000 + UInt64(value.tv_nsec)
}

private struct TraceRow: Encodable, Equatable {
    let inputBits: UInt64
    let output: String
}

private struct Trace: Encodable {
    let goldenCases: Int
    let rows: [TraceRow]
}

private func verify() -> Trace {
    let golden: [(Double, String)] = [
        (0, "00:00"), (-0.0, "00:00"), (.leastNonzeroMagnitude, "00:00"),
        (-Double.leastNonzeroMagnitude, "0:00"), (-1, "0:00"),
        (.nan, "0:00"), (.infinity, "0:00"), (-Double.infinity, "0:00"),
        (0.999, "00:00"), (1.999, "00:01"), (59.999, "00:59"),
        (60, "01:00"), (60.001, "01:00"), (3_599.999, "59:59"),
        (3_600, "1:00:00"), (3_600.999, "1:00:00"), (3_601, "1:00:01"),
        (10_801.9, "3:00:01"), (86_400, "24:00:00"),
        (359_999, "99:59:59"), (360_000, "100:00:00"),
    ]
    for (input, expected) in golden {
        precondition(format(input) == expected, "Golden mismatch for bits \(input.bitPattern)")
    }
    var values = golden.map(\.0)
    values += (0...86_400).map { Double($0) }
    // Exact adjacent representable numbers distinguish floor from rounding and
    // cover transitions across minute, hour, and day boundaries.
    for boundary in [0.0, 1, 9, 10, 59, 60, 599, 600, 3_599, 3_600, 36_000, 86_400] {
        values += [boundary.nextDown, boundary.nextUp]
        for fraction in [0.001, 0.125, 0.499, 0.5, 0.999] {
            values += [boundary - fraction, boundary + fraction]
        }
    }
    for seconds in stride(from: 0, through: 86_400, by: 137) {
        values += [Double(seconds) + 0.125, Double(seconds) + 0.999]
    }
    // The old %d formatting has 32-bit hour behavior. Preserve it for inputs
    // that the old Double-to-Int conversion accepts; do not execute trapping
    // inputs such as Double(Int.max) or greatestFiniteMagnitude.
    for hours in [Double(Int32.max) - 1, Double(Int32.max), Double(Int32.max) + 1,
                  Double(UInt32.max), Double(UInt32.max) + 1, 1_000_000_000_000] {
        let seconds = hours * 3_600
        values += [seconds.nextDown, seconds, seconds.nextUp, seconds + 59, seconds + 3_599]
    }
    values += [Double(Int.max).nextDown, Double(Int.max).nextDown.nextDown]
    let rows = values.map { TraceRow(inputBits: $0.bitPattern, output: format($0)) }
    return Trace(goldenCases: golden.count, rows: rows)
}

private struct Measurement: Encodable {
    let workload: String
    let iterations: Int
    let elapsedNanoseconds: UInt64
    let cpuNanoseconds: UInt64
    let checksum: UInt64
    let warmupChecksum: UInt64
    let last: String
}

private func measure(workload: String, iterations: Int) -> Measurement {
    let values = inputs(for: workload)
    let mask = values.count - 1
    var warmupChecksum: UInt64 = 0
    autoreleasepool {
        for index in 0..<8_192 { consume(format(values[index & mask]), checksum: &warmupChecksum) }
    }
    var checksum: UInt64 = 0
    var index = 0
    let cpuStart = cpuTime()
    let start = DispatchTime.now().uptimeNanoseconds
    while index < iterations {
        let end = min(index + 4_096, iterations)
        // Bound Objective-C temporary lifetimes consistently for both variants.
        // The pool and UTF-8 checksum costs are included in measured time.
        autoreleasepool {
            while index < end {
                consume(format(values[index & mask]), checksum: &checksum)
                index += 1
            }
        }
    }
    let elapsed = DispatchTime.now().uptimeNanoseconds - start
    let cpu = cpuTime() - cpuStart
    return Measurement(workload: workload, iterations: iterations,
                       elapsedNanoseconds: elapsed, cpuNanoseconds: cpu,
                       checksum: checksum, warmupChecksum: warmupChecksum,
                       last: format(values[(iterations - 1) & mask]))
}

@main
private struct Main {
    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data: Data
        if arguments == ["verify"] {
            data = try encoder.encode(verify())
        } else {
            precondition(arguments.count == 3 && arguments[0] == "measure")
            let count = Int(arguments[2])!
            precondition(workloads.contains(arguments[1]) && (1...100_000_000).contains(count))
            data = try encoder.encode(measure(workload: arguments[1], iterations: count))
        }
        print(String(decoding: data, as: UTF8.self))
    }
}
