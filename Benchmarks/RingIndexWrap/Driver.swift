import Foundation
@testable import IlliquidNativePlayback

@main
private enum Driver {
    static func main() throws {
        let args = CommandLine.arguments
        precondition(args.count == 7,
            "Usage: driver verify|measure ring|queue append|prepend int|reference capacity output|iterations")
        let mode = args[1]
        let data = try RingIndexBenchmark.run(mode: mode, kind: args[2], operation: args[3],
            payload: args[4], capacity: Int(args[5])!, iterations: mode == "verify" ? 1 : Int(args[6])!)
        if mode == "verify" { try data.write(to: URL(fileURLWithPath: args[6])) }
        else { print(String(decoding: data, as: UTF8.self)) }
    }
}
