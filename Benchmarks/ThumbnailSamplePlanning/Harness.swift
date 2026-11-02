import Foundation
import Dispatch
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

private enum Workload: String, CaseIterable {
    case storyboardMovie = "storyboard-movie"
    case storyboardClip = "storyboard-clip"
    case backgroundBalanced = "background-balanced"
    case backgroundEconomical = "background-economical"
    case backgroundExtensive = "background-extensive"
    case subsecond, shortClip = "short-clip"
    case fullBudgetControl = "full-budget-control"
    case oneSample = "one-sample"
    case invalidControl = "invalid-control"
}

private struct Input {
    let duration: Double
    let focus: Double
    let count: Int
}

@main
struct Harness {
    static func main() {
        let arguments = CommandLine.arguments
        guard arguments.count == 3 else {
            fail("usage: \(arguments[0]) <workload> <iterations>")
        }
        guard let workload = Workload(rawValue: arguments[1]) else {
            fail("unknown workload; expected one of: \(Workload.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        guard let iterations = Int(arguments[2]), iterations > 0,
              iterations <= Int.max / 64 else {
            fail("iterations must be a positive integer no greater than \(Int.max / 64)")
        }

        let corpus = inputs(for: workload)
        let mask = corpus.count - 1 // The corpus has exactly 64 inputs.
        let storyboard = workload == .storyboardMovie || workload == .storyboardClip
        let warmup = min(4_096, max(64, iterations / 10))
        var checksum: UInt64 = 0xcbf29ce484222325
        for index in 0..<warmup {
            checksum = consume(plan(corpus[index & mask], storyboard: storyboard), checksum)
        }

        var outputCount = 0
        let cpuStart = processCPUNanoseconds()
        let start = DispatchTime.now().uptimeNanoseconds
        for index in 0..<iterations {
            let samples = plan(corpus[index & mask], storyboard: storyboard)
            outputCount += samples.count
            checksum = consume(samples, checksum)
        }
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        let cpuElapsed = processCPUNanoseconds() - cpuStart
        let record: [String: Any] = [
            "workload": workload.rawValue,
            "iterations": iterations,
            "elapsedNanoseconds": elapsed,
            "cpuNanoseconds": cpuElapsed,
            "checksum": String(checksum, radix: 16),
            "outputCount": outputCount,
            "warmup": warmup,
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
            print(String(decoding: data, as: UTF8.self))
        } catch {
            fail("could not encode benchmark result: \(error)")
        }
    }

    @inline(never)
    private static func plan(_ input: Input, storyboard: Bool) -> [Double] {
        if storyboard {
            return ThumbnailPolicy.storyboard(duration: input.duration)
        }
        return ThumbnailPolicy.samples(
            duration: input.duration, focus: input.focus, count: input.count
        )
    }

    // Fixed work per result; retain data dependence without hashing every sample.
    @inline(__always)
    private static func consume(_ samples: [Double], _ previous: UInt64) -> UInt64 {
        var value = (previous &* 1_099_511_628_211) ^ UInt64(samples.count)
        if !samples.isEmpty {
            value = (value &* 1_099_511_628_211) ^ samples[0].bitPattern
            value = (value &* 1_099_511_628_211) ^ samples[samples.count / 2].bitPattern
            value = (value &* 1_099_511_628_211) ^ samples[samples.count - 1].bitPattern
        }
        return value
    }

    private static func inputs(for workload: Workload) -> [Input] {
        let tinyDurations = [0.1, 0.2, 0.49, 0.9]
        let shortDurations = [1.0, 1.5, 2.0, 2.5]
        return (0..<64).map { index in
            let variation = Double(index) * 0.25
            let focus = 42.3 + Double(index % 7) * 0.125
            switch workload {
            case .storyboardMovie:
                return Input(duration: 7_200 + variation, focus: 0, count: 24)
            case .storyboardClip:
                return Input(duration: 30 + Double(index % 8) * 0.0625, focus: 0, count: 24)
            case .backgroundBalanced:
                return Input(duration: 600 + variation, focus: focus, count: 12)
            case .backgroundEconomical:
                return Input(duration: 600 + variation, focus: focus, count: 6)
            case .backgroundExtensive:
                return Input(duration: 600 + variation, focus: focus, count: 24)
            case .subsecond:
                return Input(duration: tinyDurations[index & 3], focus: 0, count: 24)
            case .shortClip:
                return Input(duration: shortDurations[index & 3], focus: 0, count: 64)
            case .fullBudgetControl:
                return Input(duration: 7_200 + variation, focus: 0, count: 64)
            case .oneSample:
                return Input(duration: 7_200 + variation, focus: 42.3, count: 1)
            case .invalidControl:
                return Input(duration: 0, focus: 0, count: 24)
            }
        }
    }

    private static func processCPUNanoseconds() -> UInt64 {
        var stamp = timespec()
        guard clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &stamp) == 0 else {
            fail("clock_gettime(CLOCK_PROCESS_CPUTIME_ID) failed")
        }
        return UInt64(stamp.tv_sec) * 1_000_000_000 + UInt64(stamp.tv_nsec)
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(2)
    }
}
