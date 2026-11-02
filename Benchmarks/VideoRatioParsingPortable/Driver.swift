import Foundation
import Dispatch
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif
import IlliquidCore

func cpuNanoseconds() -> UInt64 {
    var value = timespec()
    precondition(clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &value) == 0)
    return UInt64(value.tv_sec) * 1_000_000_000 + UInt64(value.tv_nsec)
}

@main
struct Main {
    static func main() throws {
        let arguments = CommandLine.arguments
        let output: [String: Any]
        if arguments.count == 2 && arguments[1] == "verify" {
            output = verifyRatio()
        } else {
            precondition(arguments.count == 3)
            let scenario = arguments[1], iterations = Int(arguments[2])!
            precondition(iterations > 0)
            let seeds: [String?] = switch scenario {
            case "ratio_nil": Array(repeating: nil, count: 16)
            case "ratio_scalar": scalarInputs.map { $0 }
            case "ratio_colon": colonInputs.map { $0 }
            case "ratio_invalid": invalidInputs.map { $0 }
            default: preconditionFailure("Unknown parser scenario")
            }
            // The native study uses this same 32-input order and exact loop.
            let inputs = seeds + Array(seeds.reversed())
            let warm = ratioLoop(inputs, min(iterations, 8192))
            let cpuStart = cpuNanoseconds(), wallStart = DispatchTime.now().uptimeNanoseconds
            let checksum = ratioLoop(inputs, iterations)
            let wall = DispatchTime.now().uptimeNanoseconds - wallStart, cpu = cpuNanoseconds() - cpuStart
            output = ["scenario": scenario, "iterations": iterations, "wall_ns": wall, "cpu_ns": cpu,
                      "checksum": String(checksum), "warm_checksum": String(warm)]
        }
        let data = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
