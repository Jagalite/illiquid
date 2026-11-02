import Foundation
import ThumbnailSamplePolicy
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

private struct Input {
    let duration: Double
    let focus: Double
    let count: Int
}

private func inputs(for workload: String) -> [Input] {
    (0..<32).map { index in
        let duration = 600 + Double(index) * 137.25
        let focus = duration * (0.12 + Double(index % 7) * 0.1) + 0.3
        switch workload {
        case "storyboard-24": return Input(duration: duration, focus: 0, count: 24)
        case "economical-6": return Input(duration: duration, focus: focus, count: 6)
        case "balanced-12": return Input(duration: duration, focus: focus, count: 12)
        case "extensive-24": return Input(duration: duration, focus: focus, count: 24)
        case "maximum-64": return Input(duration: duration, focus: focus, count: 64)
        case "boundary-33": return Input(duration: duration, focus: 0, count: 33)
        case "exact-level-32": return Input(duration: duration, focus: 0, count: 32)
        case "exact-level-64": return Input(duration: duration, focus: 0, count: 64)
        case "one-sample": return Input(duration: duration, focus: focus, count: 1)
        case "short-duration": return Input(duration: 0.1, focus: focus, count: 64)
        case "short-1.4": return Input(duration: 1.4, focus: 1.4 * Double(index % 9) / 8, count: 64)
        case "short-2.1": return Input(duration: 2.1, focus: 2.1 * Double(index % 9) / 8, count: 64)
        case "short-7.9": return Input(duration: 7.9, focus: 7.9 * Double(index % 9) / 8, count: 64)
        case "short-30": return Input(duration: 30, focus: 30 * Double(index % 9) / 8, count: 64)
        default: fatalError("Unknown workload: \(workload)")
        }
    }
}

private func samples(_ input: Input, storyboard: Bool) -> [Double] {
    if storyboard { return ThumbnailPolicy.storyboard(duration: input.duration) }
    return ThumbnailPolicy.samples(duration: input.duration, focus: input.focus, count: input.count)
}

private func cpuNanoseconds() -> UInt64 {
    var value = timespec()
    guard clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &value) == 0 else {
        fatalError("Cannot read process CPU clock")
    }
    return UInt64(value.tv_sec) * 1_000_000_000 + UInt64(value.tv_nsec)
}

private func consume(_ values: [Double], into checksum: inout UInt64) {
    checksum &+= UInt64(values.count)
    for value in values { checksum &+= value.bitPattern }
}

@main
enum Benchmark {
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count >= 3 else { fatalError("Usage: benchmark WORKLOAD ITERATIONS|outputs") }
        let workload = args[1]
        let corpus = inputs(for: workload)
        let storyboard = workload == "storyboard-24"
        if args[2] == "outputs" {
            let output = corpus.map { input in
                samples(input, storyboard: storyboard).map { String($0.bitPattern) }
            }
            let data = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
            print(String(decoding: data, as: UTF8.self))
            return
        }
        guard let iterations = Int(args[2]), iterations > 0 else { fatalError("Invalid iterations") }
        var warmupChecksum: UInt64 = 0
        for iteration in 0..<1_000 {
            consume(samples(corpus[iteration % corpus.count], storyboard: storyboard), into: &warmupChecksum)
        }
        var checksum: UInt64 = 0
        let wallStart = DispatchTime.now().uptimeNanoseconds
        let cpuStart = cpuNanoseconds()
        for iteration in 0..<iterations {
            consume(samples(corpus[iteration % corpus.count], storyboard: storyboard), into: &checksum)
        }
        let cpu = cpuNanoseconds() - cpuStart
        let wall = DispatchTime.now().uptimeNanoseconds - wallStart
        let result: [String: Any] = [
            "workload": workload, "iterations": iterations, "corpus_size": corpus.count,
            "wall_ns": wall, "cpu_ns": cpu, "checksum": String(checksum),
            "warmup_checksum": String(warmupChecksum),
        ]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
