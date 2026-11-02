import Foundation
import IlliquidNativePlayback

@main
private enum Main {
    static func main() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data: Data
        if args == ["verify"] {
            data = try encoder.encode(RingBufferBenchmark.verify())
        } else {
            guard args.count == 5, args[0] == "measure",
                  let capacity = Int(args[2]), capacity > 0,
                  let iterations = Int(args[3]), iterations > 0,
                  let seed = UInt64(args[4]) else {
                fatalError("Usage: Driver verify | measure WORKLOAD CAPACITY ITERATIONS SEED")
            }
            let warmup = RingBufferBenchmark.measure(workload: args[1], capacity: capacity,
                iterations: 1_024, seed: seed)
            precondition(warmup.operations > 0)
            data = try encoder.encode(RingBufferBenchmark.measure(
                workload: args[1], capacity: capacity, iterations: iterations, seed: seed))
        }
        print(String(decoding: data, as: UTF8.self))
    }
}
