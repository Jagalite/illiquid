import Dispatch
import Foundation
import IlliquidCore

private enum Failure: Error { case usage, mismatch(String) }
private struct Configuration: Sendable {
    let name: String
    let videos: Int
    let samples: Int
    let visit: Int
    let uneven: Bool
    init(_ name: String, _ videos: Int, _ samples: Int, _ visit: Int = 4, _ uneven: Bool = false) {
        self.name = name; self.videos = videos; self.samples = samples
        self.visit = visit; self.uneven = uneven
    }
}
private let configurations = [
    Configuration("empty", 0, 0), Configuration("1x6-v4", 1, 6),
    Configuration("1x64-v4", 1, 64), Configuration("4x5-v4", 4, 5),
    Configuration("8x6-v4", 8, 6), Configuration("8x11-v4", 8, 11),
    Configuration("8x24-v4", 8, 24), Configuration("8x64-v4", 8, 64),
    Configuration("16x23-v4", 16, 23), Configuration("16x64-v4", 16, 64),
    Configuration("64x6-v4", 64, 6), Configuration("64x63-v4", 64, 63),
    Configuration("64x64-v4", 64, 64), Configuration("uneven-16x64-v4", 16, 64, 4, true),
    Configuration("empty-plans-64", 64, 0), Configuration("overbound-80x80-v4", 80, 80),
    Configuration("16x23-v1", 16, 23, 1), Configuration("16x23-v8", 16, 23, 8),
    Configuration("visit-min", 16, 24, Int.min), Configuration("visit-max", 16, 24, Int.max),
]
private typealias Item = (video: Int, position: Double)
private struct Signature: Encodable, Equatable {
    let videos: [Int]
    let positionBits: [UInt64]
    init(_ result: [Item]) {
        videos = result.map { $0.video }
        positionBits = result.map { $0.position.bitPattern }
    }
}
private struct Input {
    let plans: [[Double]]
    let visit: Int
}

// Independently sort capped coordinates by visit number, video, then sample.
// This does not replay the production stride and nested slice traversal.
private func oracle(_ input: Input) -> Signature {
    let visit = min(8, max(1, input.visit))
    var coordinates: [(video: Int, sample: Int, value: Double)] = []
    for video in 0..<min(64, input.plans.count) {
        for sample in 0..<min(64, input.plans[video].count) {
            coordinates.append((video, sample, input.plans[video][sample]))
        }
    }
    coordinates.sort {
        if $0.sample / visit != $1.sample / visit { return $0.sample / visit < $1.sample / visit }
        if $0.video != $1.video { return $0.video < $1.video }
        return $0.sample < $1.sample
    }
    return Signature(coordinates.map { ($0.video, $0.value) })
}
private struct Fixture {
    let configuration: Configuration
    let inputs: [Input]
    let expected: [Signature]
    init(_ configuration: Configuration, seed: UInt64) {
        self.configuration = configuration
        let inputs = (0..<16).map { version -> Input in
            let plans = (0..<configuration.videos).map { video -> [Double] in
                let count: Int
                if configuration.uneven {
                    count = video % 5 == 0 ? 0 : 1 + (video * 17 + version * 5) % configuration.samples
                } else { count = configuration.samples }
                return (0..<count).map { sample in
                    Double(seed & 0xffff) / 8 + Double(version) / 32 + Double(video) * 100 + Double(sample) / 2
                }
            }
            return Input(plans: plans, visit: configuration.visit)
        }
        self.inputs = inputs
        expected = inputs.map(oracle)
    }
    func verify() throws -> [Signature] {
        let actual = inputs.map { Signature(ThumbnailPolicy.refinementOrder($0.plans, maximumPerVisit: $0.visit)) }
        guard actual == expected else { throw Failure.mismatch(configuration.name) }
        return actual
    }
}

@inline(__always)
private func consume(_ value: UInt64, _ checksum: inout UInt64) {
    checksum = (checksum ^ value) &* 0x100000001b3
}
@inline(never)
private func exercise(_ inputs: [Input], iterations: Int) -> UInt64 {
    var checksum: UInt64 = 0xcbf29ce484222325
    for iteration in 0..<iterations {
        let input = inputs[iteration & 15]
        let result = ThumbnailPolicy.refinementOrder(input.plans, maximumPerVisit: input.visit)
        consume(UInt64(result.count), &checksum)
        if !result.isEmpty {
            // Include result construction/destruction without adding a second
            // complete traversal to the measured scheduling work.
            let first = result[0], middle = result[result.count / 2], last = result[result.count - 1]
            consume(UInt64(first.video), &checksum); consume(first.position.bitPattern, &checksum)
            consume(UInt64(middle.video), &checksum); consume(middle.position.bitPattern, &checksum)
            consume(UInt64(last.video), &checksum); consume(last.position.bitPattern, &checksum)
        }
    }
    return checksum
}
private struct Output: Encodable {
    let name: String
    let iterations: Int
    let seed: UInt64
    let elapsed_ns: UInt64
    let operations_per_iteration: Int
    let checksum: UInt64
    let warmup_checksum: UInt64
    let receipt: [Signature]
    enum CodingKeys: String, CodingKey {
        case name = "case"
        case iterations, seed, elapsed_ns, operations_per_iteration
        case checksum, warmup_checksum, receipt
    }
}
private func emit<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    var data = try encoder.encode(value); data.append(0x0a)
    FileHandle.standardOutput.write(data)
}
@main private struct Driver {
    static func main() throws {
        let args = CommandLine.arguments
        if args.count == 2, args[1] == "cases" {
            try emit(configurations.map { $0.name })
            return
        }
        if args.count == 3, args[1] == "verify", let seed = UInt64(args[2]) {
            var receipts: [String: [Signature]] = [:]
            for configuration in configurations {
                receipts[configuration.name] = try Fixture(configuration, seed: seed).verify()
            }
            try emit(receipts)
            return
        }
        guard args.count == 4, let iterations = Int(args[2]), iterations > 0, iterations <= (1 << 34),
              let seed = UInt64(args[3]), let configuration = configurations.first(where: { $0.name == args[1] })
        else { throw Failure.usage }
        let fixture = Fixture(configuration, seed: seed)
        _ = try fixture.verify()
        let warmChecksum = exercise(fixture.inputs, iterations: 64)
        let start = DispatchTime.now().uptimeNanoseconds
        let checksum = exercise(fixture.inputs, iterations: iterations)
        let elapsed = DispatchTime.now().uptimeNanoseconds &- start
        let receipt = try fixture.verify()
        try emit(Output(name: configuration.name, iterations: iterations, seed: seed, elapsed_ns: elapsed,
                        operations_per_iteration: 1, checksum: checksum,
                        warmup_checksum: warmChecksum, receipt: receipt))
    }
}
