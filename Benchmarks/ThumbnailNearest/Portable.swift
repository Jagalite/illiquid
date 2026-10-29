import Foundation
#if os(Linux)
import Glibc
#else
import Darwin
#endif
@testable import ThumbnailNearestPlan

private typealias Key = NativeThumbnailPlanner.Key
private struct Failure: Error, CustomStringConvertible { let description: String }
private func require(_ value: Bool, _ message: String) throws {
    if !value { throw Failure(description: message) }
}
private struct Query {
    let key: Key
    let radius: Double
    let fallbacks: [Double]
}
private struct Fixture {
    let planner: NativeThumbnailPlanner
    let keys: [Key]
    let queries: [Query]
}
private func key(_ bucket: Int, path: String = "/benchmark/video.mkv",
                 version: String = "version-1", width: Int = 160, height: Int = 90) -> Key {
    Key(path: path, version: version, halfSecond: bucket, width: width, height: height)
}
private func fixture(_ keys: [Key], _ queries: [Query]) -> Fixture {
    Fixture(planner: NativeThumbnailPlanner(keys: keys), keys: keys, queries: queries)
}
private let cases = [
    "empty", "one-resident", "24-residents", "96-residents",
    "96-mixed-identities", "96-long-path", "24-fallback-duplicates", "missing-fallbacks",
    "96-nearby", "24-storyboard",
]
private func workload(_ name: String) throws -> Fixture {
    try require(cases.contains(name), "Unknown workload: \(name)")
    let count: Int
    switch name {
    case "empty", "missing-fallbacks": count = 0
    case "one-resident": count = 1
    case "24-residents", "24-fallback-duplicates", "24-storyboard": count = 24
    default: count = 96
    }
    let path = name == "96-long-path"
        ? "/benchmark/" + String(repeating: "television-season-component/", count: 64) + "video.mkv"
        : "/benchmark/video.mkv"
    let keys = (0..<count).map { index in
        let mixed = name == "96-mixed-identities"
        return key(index * 4, path: mixed && index % 4 == 1 ? path + ".other" : path,
                   version: mixed && index % 4 == 2 ? "version-2" : "version-1",
                   width: mixed && index % 4 == 3 ? 161 : 160)
    }
    let fallbacks: [Double]
    switch name {
    case "24-fallback-duplicates": fallbacks = (0..<24).map { Double(($0 % 8) * 4) / 2 }
    case "missing-fallbacks": fallbacks = (0..<24).map { Double($0 * 4) / 2 }
    case "24-storyboard": fallbacks = (0..<24).map { Double($0 * 4 + 2) / 2 }
    default: fallbacks = []
    }
    let targets = name == "24-storyboard" ? [3, 15, 47, 91] : [1, 13, 45, 89]
    return fixture(keys, targets.map {
        Query(key: key($0, path: path), radius: name == "96-nearby" ? 3 : 7_200, fallbacks: fallbacks)
    })
}
private func utf8Hex(_ value: String) -> String {
    let digits = Array("0123456789abcdef".utf8)
    var result: [UInt8] = []
    result.reserveCapacity(value.utf8.count * 2)
    for byte in value.utf8 {
        result.append(digits[Int(byte >> 4)])
        result.append(digits[Int(byte & 15)])
    }
    return String(decoding: result, as: UTF8.self)
}
private struct KeyReceipt: Encodable {
    let pathUTF8: String
    let versionUTF8: String
    let halfSecond: String
    let width: Int
    let height: Int
    let renderer: String
    init(_ key: Key) {
        pathUTF8 = utf8Hex(key.path); versionUTF8 = utf8Hex(key.version)
        halfSecond = String(key.halfSecond); width = key.width; height = key.height
        renderer = key.renderer
    }
}
private struct Receipt: Encodable {
    let name: String
    let orderedKeys: [KeyReceipt]?
    private enum CodingKeys: String, CodingKey { case name, orderedKeys }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(name, forKey: .name)
        try values.encode(orderedKeys, forKey: .orderedKeys)
    }
}
private func inspect(_ name: String, _ fixture: Fixture) -> [Receipt] {
    fixture.queries.enumerated().map { index, query in
        let result = fixture.planner.nearest(to: query.key, maximumDistance: query.radius,
                                             fallbackTimes: query.fallbacks)
        return Receipt(name: "\(name)-\(index)", orderedKeys: result.map { $0.map(KeyReceipt.init) })
    }
}
private struct Verification: Encodable {
    let scope = "candidate planning only; no actor, CGImage, disk, or full cache execution"
    let cases: [String]
    let fixtures: [Receipt]
}
private func verify() throws -> Verification {
    var receipts: [Receipt] = []
    for name in cases { receipts += inspect(name, try workload(name)) }
    let fallbackEdges: [Double] = [
        .nan, .infinity, -.infinity, .greatestFiniteMagnitude, -0.75, -0.25, 0.25, 0.75, 0.75,
        Double(Int.max) / 2, Double(Int.min) / 2,
    ]
    let bounds: [Double] = [-1, .nan, .infinity, -.infinity, -0.0, 0.5, 1.0.nextDown, 1, 2]
    let ties = fixture([key(2), key(-2)], bounds.map {
        Query(key: key(0), radius: $0, fallbacks: fallbackEdges)
    })
    receipts += inspect("signed-boundary-ties", ties)
    try require(ties.planner.nearest(to: key(0), maximumDistance: 1)?.first?.halfSecond == -2,
                "Equal distance must prefer the lower integer bucket")
    try require(ties.planner.nearest(to: key(0), maximumDistance: .nan) == nil,
                "Nonfinite radius must be rejected")
    let extremeKeys = [Int.max, Int.max - 1, Int.max - 2048, Int.min, Int.min + 1, 0].map { key($0) }
    let extremes = fixture(extremeKeys, [
        Query(key: key(Int.max), radius: 0, fallbacks: []),
        Query(key: key(Int.min), radius: 0, fallbacks: []),
        Query(key: key(0), radius: Double.greatestFiniteMagnitude, fallbacks: fallbackEdges),
    ])
    receipts += inspect("floating-point-precision", extremes)
    try require(extremes.planner.nearest(to: key(Int.max), maximumDistance: 0)?.first?.halfSecond == Int.max - 1,
                "Rounded Double distances must preserve integer tie ordering")
    let identity = fixture([
        key(10, path: "/other"), key(10, version: "other"), key(10, width: 161), key(10, height: 91),
    ], [Query(key: key(10), radius: 0, fallbacks: [])])
    receipts += inspect("identity-isolation", identity)
    try require(identity.planner.nearest(to: key(10), maximumDistance: 0)?.isEmpty == true,
                "Candidate collection crossed identity boundaries")
    let original = key(10, path: "/benchmark/\u{00e9}.mkv", version: "\u{00c5}")
    let alternate = key(12, path: "/benchmark/e\u{0301}.mkv", version: "A\u{030a}")
    let query = key(11, path: alternate.path, version: alternate.version)
    let unicode = fixture([original, alternate], [
        Query(key: query, radius: 10, fallbacks: [5, 6, 7, 7, 3]),
        Query(key: query, radius: 0.5, fallbacks: [5, 6, 5, 6]),
    ])
    receipts += inspect("exact-unicode-spelling", unicode)
    let first = unicode.planner.nearest(to: query, maximumDistance: 10, fallbackTimes: [5, 6])?.first
    try require(first.map { utf8Hex($0.path) == utf8Hex(original.path)
                && utf8Hex($0.version) == utf8Hex(original.version) } == true,
                "Resident key spelling must survive canonical-equivalent request/fallback strings")
    // Systematic pools vary identity, ordering, signed positions, radius and duplicates.
    for seed in 0..<48 {
        let count = [0, 1, 2, 8, 24, 96][seed % 6]
        var keys = (0..<count).map { index in
            let pattern = (index + seed) % 7
            return key(index * 4 - seed * 2, path: pattern == 1 ? "/other" : "/benchmark/video.mkv",
                       version: pattern == 2 ? "other" : "version-1",
                       width: pattern == 3 ? 161 : 160, height: pattern == 4 ? 91 : 90)
        }
        if seed % 2 == 1 { keys.reverse() }
        let fallbacks = (0..<32).map { Double((($0 + seed) % 11) * 3 - 20) / 2 + 0.25 }
        let queries = [0, 1, 2, 3].map {
            Query(key: key(seed * 3 - 60 + $0), radius: [0.0, 0.5, 3.0, 7_200.0][(seed + $0) % 4],
                  fallbacks: seed % 3 == 0 ? fallbacks + fallbackEdges : fallbacks)
        }
        receipts += inspect("systematic-\(seed)", fixture(keys, queries))
    }
    return Verification(cases: cases, fixtures: receipts)
}
private struct Measurement: Encodable {
    let caseName: String
    let iterations: Int
    let operations: Int
    let elapsedNanoseconds: UInt64
    let checksum: String
    let candidateCount: Int
    private enum CodingKeys: String, CodingKey {
        case caseName = "case"
        case iterations, operations, checksum
        case elapsedNanoseconds = "elapsed_ns"
        case candidateCount = "candidate_count"
    }
}
@inline(never)
private func perform(_ fixture: Fixture, iterations: Int) -> (UInt64, Int) {
    var checksum: UInt64 = 0xCBF29CE484222325
    var total = 0
    for index in 0..<iterations {
        let query = fixture.queries[index & 3]
        if let result = fixture.planner.nearest(to: query.key, maximumDistance: query.radius,
                                               fallbackTimes: query.fallbacks) {
            total += result.count
            checksum = (checksum ^ UInt64(result.count)) &* 0x100000001B3
            if let first = result.first, let last = result.last {
                checksum = (checksum ^ UInt64(bitPattern: Int64(first.halfSecond))) &* 0x100000001B3
                checksum = (checksum ^ UInt64(bitPattern: Int64(last.halfSecond))) &* 0x100000001B3
            }
        } else { checksum = (checksum ^ UInt64(index)) &* 0x100000001B3 }
    }
    return (checksum, total)
}
private func measure(_ name: String, iterations: Int) throws -> Measurement {
    try require(iterations > 0, "Iterations must be positive")
    let fixture = try workload(name)
    _ = perform(fixture, iterations: 512)
    let start = DispatchTime.now().uptimeNanoseconds
    let (checksum, count) = perform(fixture, iterations: iterations)
    let elapsed = DispatchTime.now().uptimeNanoseconds - start
    withExtendedLifetime(fixture) {}
    return Measurement(caseName: name, iterations: iterations, operations: iterations,
                       elapsedNanoseconds: elapsed, checksum: String(checksum, radix: 16), candidateCount: count)
}
private func emit<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    FileHandle.standardOutput.write(try encoder.encode(value))
    FileHandle.standardOutput.write(Data([10]))
}
@main private struct Portable {
    static func main() {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            if args == ["--mode", "verify"] { try emit(verify()) }
            else if args.count == 6, args[0] == "--mode", args[1] == "measure",
                    args[2] == "--case", args[4] == "--iterations", let count = Int(args[5]) {
                try emit(measure(args[3], iterations: count))
            } else { throw Failure(description: "Usage: --mode verify | --mode measure --case NAME --iterations N") }
        } catch { FileHandle.standardError.write(Data("\(error)\n".utf8)); exit(1) }
    }
}
