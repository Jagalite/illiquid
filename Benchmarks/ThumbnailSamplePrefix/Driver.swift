import Foundation
import Dispatch
import IlliquidCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

struct Workload: Sendable {
    let name: String
    let kind: String
    let duration: Double
    let focus: Double
    let count: Int
}

let workloads: [Workload] = [
    .init(name: "samples_6_resume", kind: "samples", duration: 120, focus: 42.3, count: 6),
    .init(name: "samples_12_resume", kind: "samples", duration: 120, focus: 42.3, count: 12),
    .init(name: "samples_12_start", kind: "samples", duration: 7200, focus: 0, count: 12),
    .init(name: "samples_24_resume", kind: "samples", duration: 7200, focus: 321.3, count: 24),
    .init(name: "storyboard_24", kind: "storyboard", duration: 7200, focus: 0, count: 24),
    .init(name: "samples_64_start", kind: "samples", duration: 7200, focus: 0, count: 64),
    .init(name: "samples_64_resume", kind: "samples", duration: 7200, focus: 321.3, count: 64),
    .init(name: "samples_1_resume", kind: "samples", duration: 120, focus: 42.3, count: 1),
    .init(name: "samples_short_zero", kind: "samples", duration: 0.2, focus: 0.1, count: 64),
    .init(name: "samples_short_saturated", kind: "samples", duration: 2, focus: 1, count: 12),
    .init(name: "nearby_control", kind: "nearby", duration: 120, focus: 42.3, count: 13),
]

@inline(never)
func evaluate(_ workload: Workload) -> [Double] {
    switch workload.kind {
    case "storyboard": return ThumbnailPolicy.storyboard(duration: workload.duration)
    case "nearby": return ThumbnailPolicy.nearby(duration: workload.duration, focus: workload.focus)
    default:
        return ThumbnailPolicy.samples(
            duration: workload.duration, focus: workload.focus, count: workload.count
        )
    }
}

func bits(_ values: [Double]) -> [String] {
    values.map { String($0.bitPattern, radix: 16) }
}

func emit(_ value: Any) throws {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))
}

func cpuNanoseconds() -> UInt64 {
    var value = timespec()
    precondition(clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &value) == 0)
    return UInt64(value.tv_sec) * 1_000_000_000 + UInt64(value.tv_nsec)
}

func differentialCases() -> [[String: Any]] {
    let durations: [Double] = [
        -.infinity, -1, -0.0, 0, .nan, .infinity,
        .leastNonzeroMagnitude, 0.1, 0.5, Double(0.5).nextUp,
        Double(1).nextDown, 1, Double(1).nextUp, 1.5, 2, 30, 120, 7200,
        Double.greatestFiniteMagnitude / 4, .greatestFiniteMagnitude,
    ]
    let counts = [Int.min, -1, 0, 1, 2, 3, 6, 12, 24, 32, 63, 64, 65, Int.max]
    var rows: [[String: Any]] = []
    for duration in durations {
        let focuses: [Double] = [
            .nan, .infinity, -.infinity, -1, -0.0, 0, 0.24, 0.25, 0.26,
            1, -Double.greatestFiniteMagnitude, Double.greatestFiniteMagnitude,
            duration / 3, duration, duration * 2,
        ]
        for focus in focuses {
            for count in counts {
                let result = ThumbnailPolicy.samples(duration: duration, focus: focus, count: count)
                rows.append([
                    "duration_bits": String(duration.bitPattern, radix: 16),
                    "focus_bits": String(focus.bitPattern, radix: 16),
                    "count": String(count),
                    "output_bits": bits(result),
                ])
            }
        }
        rows.append([
            "kind": "storyboard", "duration_bits": String(duration.bitPattern, radix: 16),
            "output_bits": bits(ThumbnailPolicy.storyboard(duration: duration)),
        ])
    }
    var seed: UInt64 = 0x6a09e667f3bcc909
    func next() -> UInt64 {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return seed
    }
    for _ in 0..<512 {
        let duration = Double(next() % 2_000_000 + 1) / 100
        let focus = Double(Int64(next() % 4_000_000) - 1_000_000) / 100
        let count = Int(next() % 96) - 16
        rows.append([
            "duration_bits": String(duration.bitPattern, radix: 16),
            "focus_bits": String(focus.bitPattern, radix: 16),
            "count": String(count),
            "output_bits": bits(ThumbnailPolicy.samples(duration: duration, focus: focus, count: count)),
        ])
    }
    return rows
}

let arguments = CommandLine.arguments
guard arguments.count >= 2 else { fatalError("Expected list, differential, or measure") }
switch arguments[1] {
case "list":
    try emit(workloads.map {
        ["name": $0.name, "kind": $0.kind, "duration": $0.duration,
         "focus": $0.focus, "requested_count": $0.count] as [String: Any]
    })
case "differential":
    try emit(differentialCases())
case "measure":
    guard arguments.count == 4,
          let workload = workloads.first(where: { $0.name == arguments[2] }),
          let iterations = Int(arguments[3]), iterations > 0
    else { fatalError("Expected measure WORKLOAD ITERATIONS") }
    let expected = evaluate(workload)
    var warmup: UInt64 = 0
    for _ in 0..<64 {
        warmup &+= UInt64(evaluate(workload).count)
    }
    var checksum: UInt64 = 0
    let cpuStart = cpuNanoseconds()
    let wallStart = DispatchTime.now().uptimeNanoseconds
    for _ in 0..<iterations {
        let result = evaluate(workload)
        checksum &+= UInt64(result.count)
        checksum &+= result.first?.bitPattern ?? 0
        checksum &+= result.last?.bitPattern ?? 0
    }
    let wallNanoseconds = DispatchTime.now().uptimeNanoseconds - wallStart
    let cpuElapsed = cpuNanoseconds() - cpuStart
    try emit([
        "workload": workload.name, "iterations": iterations,
        "wall_ns": wallNanoseconds, "cpu_ns": cpuElapsed,
        "checksum": String(checksum), "warmup_checksum": String(warmup),
        "output_bits": bits(expected), "output_count": expected.count,
        "output_capacity": expected.capacity,
    ])
default:
    fatalError("Unknown command")
}
