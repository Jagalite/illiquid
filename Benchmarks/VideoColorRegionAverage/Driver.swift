import Foundation
import IlliquidCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

private enum Workload: String, CaseIterable {
    case overall, leading, bottom, localInterior, localEdge, oneCell
    case clipped, reversed, paletteRegions, pointLookupControl
}

private func samples() -> [VideoColorSample] {
    var result: [VideoColorSample] = []
    for seed in 0..<8 {
        var colors: [SampledVideoColor] = []
        for index in 0..<96 {
            let redCode: Int = (index * 37 + seed * 19 + 11) % 257
            let greenCode: Int = (index * 73 + seed * 31 + 19) % 251
            let blueCode: Int = (index * 17 + seed * 43 + 23) % 241
            colors.append(SampledVideoColor(
                red: Double(redCode) / 256,
                green: Double(greenCode) / 250,
                blue: Double(blueCode) / 240
            ))
        }
        result.append(VideoColorSample(columns: 12, rows: 8, colors: colors))
    }
    return result
}

@inline(never)
private func consume(_ color: SampledVideoColor) -> UInt64 {
    color.red.bitPattern &+ color.green.bitPattern &+ color.blue.bitPattern
}

@inline(never)
private func perform(_ workload: Workload, values: [VideoColorSample], iterations: Int) -> UInt64 {
    var checksum: UInt64 = 0
    for index in 0..<iterations {
        let value = values[index & 7]
        let result: UInt64
        switch workload {
        case .overall:
            result = consume(value.overall)
        case .leading:
            result = consume(value.leading)
        case .bottom:
            result = consume(value.bottom)
        case .localInterior:
            let x = 1 + index % 10, y = 1 + index % 6
            result = consume(value.average(
                minimumColumn: x - 1, maximumColumn: x + 1,
                minimumRow: y - 1, maximumRow: y + 1
            ))
        case .localEdge:
            result = consume(value.average(
                minimumColumn: -1, maximumColumn: 1, minimumRow: -1, maximumRow: 1
            ))
        case .oneCell:
            let x = index % 12, y = index % 8
            result = consume(value.average(
                minimumColumn: x, maximumColumn: x, minimumRow: y, maximumRow: y
            ))
        case .clipped:
            result = consume(value.average(
                minimumColumn: Int.min, maximumColumn: Int.max,
                minimumRow: Int.min, maximumRow: Int.max
            ))
        case .reversed:
            result = consume(value.average(
                minimumColumn: 9, maximumColumn: 2, minimumRow: 6, maximumRow: 1
            ))
        case .paletteRegions:
            result = consume(value.overall) &+ consume(value.leading) &+ consume(value.bottom)
                &+ consume(value.average(
                    minimumColumn: 4, maximumColumn: 6, minimumRow: 2, maximumRow: 4
                ))
        case .pointLookupControl:
            result = consume(value.color(column: index % 16 - 2, row: index % 12 - 2))
        }
        checksum &+= result
    }
    return checksum
}

private func cpuTime() -> UInt64 {
    var value = timespec()
    precondition(clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &value) == 0)
    return UInt64(value.tv_sec) * 1_000_000_000 + UInt64(value.tv_nsec)
}

private struct Measurement: Codable {
    let name: String
    let iterations: Int
    let wallNanoseconds: UInt64
    let cpuNanoseconds: UInt64
    let checksum: String
}

private struct Verification: Codable {
    let rectangles: Int
    let componentBits: [[UInt64]]
}

private func verify() -> Verification {
    var result: [[UInt64]] = []
    var random: UInt64 = 0xC010A
    func next() -> UInt64 {
        random = random &* 6364136223846793005 &+ 1442695040888963407
        return random
    }
    let bounds = [Int.min, -50, -1, 0, 1, 3, 6, 7, 8, 11, 12, 20, Int.max]
    for value in samples() {
        for _ in 0..<2_048 {
            let coordinates = (0..<4).map { _ in bounds[Int(next() >> 32) % bounds.count] }
            let color = value.average(
                minimumColumn: coordinates[0], maximumColumn: coordinates[1],
                minimumRow: coordinates[2], maximumRow: coordinates[3]
            )
            result.append([color.red.bitPattern, color.green.bitPattern, color.blue.bitPattern])
        }
        for color in [value.overall, value.leading, value.bottom] {
            result.append([color.red.bitPattern, color.green.bitPattern, color.blue.bitPattern])
        }
    }
    return Verification(rectangles: result.count, componentBits: result)
}

private func emit<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    print(String(decoding: try encoder.encode(value), as: UTF8.self))
}

@main
private struct Driver {
    static func main() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        if args == ["--cases"] {
            try emit(Workload.allCases.map(\.rawValue))
        } else if args == ["--verify"] {
            try emit(verify())
        } else {
            precondition(args.count == 3 && args[0] == "--measure")
            let workload = Workload(rawValue: args[1])!
            let iterations = Int(args[2])!
            precondition(iterations > 0 && iterations <= 100_000_000)
            let values = samples()
            _ = perform(workload, values: values, iterations: min(10_000, max(128, iterations / 10)))
            let cpuStart = cpuTime()
            let wallStart = DispatchTime.now().uptimeNanoseconds
            let checksum = perform(workload, values: values, iterations: iterations)
            let wall = DispatchTime.now().uptimeNanoseconds - wallStart
            let cpu = cpuTime() - cpuStart
            try emit(Measurement(
                name: workload.rawValue, iterations: iterations,
                wallNanoseconds: wall, cpuNanoseconds: cpu, checksum: String(checksum)
            ))
        }
    }
}
