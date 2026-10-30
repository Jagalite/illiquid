import Dispatch
import Foundation
import IlliquidCore
#if os(Linux)
import Glibc
#else
import Darwin
#endif

// The matcher is a separately compiled production module. Each timed iteration
// includes the entire association, result consumption, and result destruction.
// Fixture construction, full-oracle verification, and warmup are outside timing.
private struct Case: Decodable {
    let name: String
    let media: [String]
    let subtitles: [String]
    let expected: [String: [String]]
}

private struct Fixture {
    let spec: Case
    let media: [URL]
    let subtitles: [URL]
    let expected: [URL: [URL]]

    init(_ spec: Case) {
        let root = URL(fileURLWithPath: "/tmp/illiquid-subtitle-fuzzy-prefix", isDirectory: true)
        func url(_ name: String) -> URL { root.appendingPathComponent(name) }
        self.spec = spec
        media = spec.media.map(url)
        subtitles = spec.subtitles.map(url)
        expected = Dictionary(uniqueKeysWithValues: spec.expected.map { (url($0.key), $0.value.map(url)) })
    }
}

private struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

@inline(never)
private func associate(_ fixture: Fixture) -> [URL: [URL]] {
    ExternalSubtitleMatcher.associate(subtitleURLs: fixture.subtitles, with: fixture.media)
}

@inline(never)
private func run(_ fixture: Fixture, iterations: Int) -> UInt64 {
    var checksum: UInt64 = 14_695_981_039_346_656_037
    for _ in 0..<iterations {
        let result = associate(fixture)
        checksum ^= UInt64(result.count)
        checksum &*= 1_099_511_628_211
        checksum ^= UInt64(result.values.reduce(0) { $0 + $1.count })
        checksum &*= 1_099_511_628_211
    }
    return checksum
}

private func expectedChecksum(_ fixture: Fixture, iterations: Int) -> UInt64 {
    var checksum: UInt64 = 14_695_981_039_346_656_037
    let subtitleCount = fixture.expected.values.reduce(0) { $0 + $1.count }
    for _ in 0..<iterations {
        checksum ^= UInt64(fixture.expected.count)
        checksum &*= 1_099_511_628_211
        checksum ^= UInt64(subtitleCount)
        checksum &*= 1_099_511_628_211
    }
    return checksum
}

private func cpuNanoseconds() throws -> UInt64 {
    var stamp = timespec(tv_sec: 0, tv_nsec: 0)
    guard clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &stamp) == 0,
          stamp.tv_sec >= 0, stamp.tv_nsec >= 0 else {
        throw Failure("Cannot read process CPU clock")
    }
    return UInt64(stamp.tv_sec) * 1_000_000_000 + UInt64(stamp.tv_nsec)
}

private func emit<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    FileHandle.standardOutput.write(try encoder.encode(value))
    FileHandle.standardOutput.write(Data([10]))
}

private struct Verification: Encodable {
    let name: String
    let keys: Int
    let subtitles: Int
    let reversedInputs: Bool
}

private struct Measurement: Encodable {
    let name: String
    let locale: String
    let mediaCount: Int
    let subtitleCount: Int
    let iterations: Int
    let warmup: Int
    let cpuNsPerAssociation: Double
    let wallNsPerAssociation: Double
    let checksum: UInt64
    let expectedChecksum: UInt64
}

@main
private struct Driver {
    static func main() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count == 2 || args.count == 4 else {
            throw Failure("Usage: Driver CASES.json --verify | CASES.json CASE ITERATIONS WARMUP")
        }
        let specs = try JSONDecoder().decode([Case].self, from: Data(contentsOf: URL(fileURLWithPath: args[0])))
        if args.count == 2 {
            guard args[1] == "--verify" else { throw Failure("Expected --verify") }
            var reports: [Verification] = []
            for spec in specs {
                let fixture = Fixture(spec)
                guard associate(fixture) == fixture.expected else {
                    throw Failure("Oracle mismatch: \(spec.name)")
                }
                let reversed = ExternalSubtitleMatcher.associate(
                    subtitleURLs: Array(fixture.subtitles.reversed()),
                    with: Array(fixture.media.reversed())
                )
                guard reversed == fixture.expected else {
                    throw Failure("Reversed-input oracle mismatch: \(spec.name)")
                }
                reports.append(.init(name: spec.name, keys: fixture.expected.count,
                    subtitles: fixture.expected.values.reduce(0) { $0 + $1.count }, reversedInputs: true))
            }
            try emit(reports)
            return
        }
        guard let spec = specs.first(where: { $0.name == args[1] }),
              let iterations = Int(args[2]), iterations > 0,
              let warmup = Int(args[3]), warmup >= 0 else {
            throw Failure("Invalid case or iteration count")
        }
        let fixture = Fixture(spec)
        guard associate(fixture) == fixture.expected else { throw Failure("Preflight mismatch") }
        guard run(fixture, iterations: warmup) == expectedChecksum(fixture, iterations: warmup) else {
            throw Failure("Warmup mismatch")
        }
        let cpuStart = try cpuNanoseconds()
        let wallStart = DispatchTime.now().uptimeNanoseconds
        let checksum = run(fixture, iterations: iterations)
        let wallNs = DispatchTime.now().uptimeNanoseconds - wallStart
        let cpuNs = try cpuNanoseconds() - cpuStart
        let expected = expectedChecksum(fixture, iterations: iterations)
        guard checksum == expected else { throw Failure("Timed result mismatch") }
        try emit(Measurement(name: spec.name, locale: Locale.current.identifier,
            mediaCount: fixture.media.count, subtitleCount: fixture.subtitles.count,
            iterations: iterations, warmup: warmup,
            cpuNsPerAssociation: Double(cpuNs) / Double(iterations),
            wallNsPerAssociation: Double(wallNs) / Double(iterations),
            checksum: checksum, expectedChecksum: expected))
    }
}
