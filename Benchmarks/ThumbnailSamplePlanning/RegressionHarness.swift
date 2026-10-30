import Foundation
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
        guard arguments.count == 2 else {
            fail("usage: \(arguments[0]) <workload>")
        }
        guard let workload = Workload(rawValue: arguments[1]) else {
            fail("unknown workload; expected one of: \(Workload.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        let corpus = inputs(for: workload)
        let storyboard = workload == .storyboardMovie || workload == .storyboardClip
        let record: [String: Any] = [
            "workload": workload.rawValue,
            "outputs": corpus.map { input in
                plan(input, storyboard: storyboard).map { String($0.bitPattern, radix: 16) }
            },
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

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(2)
    }
}
