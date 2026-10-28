import Dispatch
import Foundation
import IlliquidCore

#if os(Linux)
import Glibc
#else
import Darwin
#endif

private enum Kind: Sendable, Equatable { case ambiguous, longPrefix, winner, ancestor, unicode, exact, unrelated }

private struct CaseSpec: Sendable {
    let name: String
    let size: Int
    let kind: Kind
}

private let cases: [CaseSpec] = [
    .init(name: "ambiguous_16", size: 16, kind: .ambiguous),
    .init(name: "ambiguous_256", size: 256, kind: .ambiguous),
    .init(name: "ambiguous_1024", size: 1024, kind: .ambiguous),
    .init(name: "long_256", size: 256, kind: .longPrefix),
    .init(name: "long_1024", size: 1024, kind: .longPrefix),
    .init(name: "winner_256", size: 256, kind: .winner),
    .init(name: "ancestor_256", size: 256, kind: .ancestor),
    .init(name: "unicode_256", size: 256, kind: .unicode),
    .init(name: "exact_256", size: 256, kind: .exact),
    .init(name: "unrelated_256", size: 256, kind: .unrelated),
]

private struct DriverError: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

private struct Fixture {
    let media: [URL]
    let subtitles: [URL]
    let expected: [URL: [URL]]

    static func make(_ spec: CaseSpec) throws -> Self {
        let root = URL(fileURLWithPath: "/tmp/illiquid-subtitle-fuzzy-scoring", isDirectory: true)
        func url(_ stem: String, _ suffix: String) -> URL {
            root.appendingPathComponent(stem + suffix)
        }
        let prefix: String
        switch spec.kind {
        case .longPrefix:
            prefix = "The.Example.Series.Special.Extended.Edition.Finale.At.The.End.Of.The.Season"
        case .unicode:
            prefix = "Se\u{301}rie.Cafe\u{301}.東京.Finale"
        default:
            prefix = "Example.Series.Finale"
        }
        let stems = (0..<spec.size).map { index -> String in
            if spec.kind == .winner && index == 0 { return prefix + ".Extended" }
            let number = String(index)
            return prefix + ".Episode." + String(repeating: "0", count: 6 - number.count) + number
        }
        let media = stems.map { url($0, ".mkv") }
        var expected = Dictionary(uniqueKeysWithValues: media.map { ($0, [URL]()) })
        var subtitles: [URL]
        switch spec.kind {
        case .ancestor, .exact:
            // These inventories have one unambiguous sidecar per media file.
            // "Directors Commentary" is not a removable language qualifier:
            // ancestor therefore enters fuzzy scoring; exact takes the fast path.
            let suffix = spec.kind == .ancestor ? ".Directors.Commentary.en.srt" : ".en.srt"
            subtitles = stems.map { url($0, suffix) }
            for index in media.indices { expected[media[index]] = [subtitles[index]] }
        default:
            // Eight distinct language sidecars are already in natural order.
            // Equal-length descendants all tie. The winner fixture has exactly
            // one shorter descendant, whose smaller unmatched-token penalty wins.
            let languages = ["ar", "de", "en", "es", "fr", "ja", "ko", "zh"]
            let subtitlePrefix = spec.kind == .unrelated ? "Unrelated.Collection.Feature" : prefix
            subtitles = languages.map { url(subtitlePrefix, "." + $0 + ".srt") }
            if spec.kind == .winner { expected[media[0]] = subtitles }
        }
        for entry in media + subtitles {
            guard entry.lastPathComponent.utf8.count <= 255 else {
                throw DriverError("Fixture exceeds a normal filename component limit.")
            }
        }
        // Exercise the real output ordering instead of feeding pre-sorted input.
        subtitles.reverse()
        return Self(media: media, subtitles: subtitles, expected: expected)
    }
}

private struct Counts {
    let keys: Int
    let subtitles: Int
    init(_ result: [URL: [URL]]) {
        keys = result.count
        subtitles = result.values.reduce(0) { $0 + $1.count }
    }
}

private let initialChecksum: UInt64 = 14_695_981_039_346_656_037

private func consume(_ counts: Counts, into checksum: inout UInt64) {
    checksum ^= UInt64(counts.keys)
    checksum &*= 1_099_511_628_211
    checksum ^= UInt64(counts.subtitles)
    checksum &*= 1_099_511_628_211
}

@inline(never)
private func associate(_ fixture: Fixture) -> [URL: [URL]] {
    ExternalSubtitleMatcher.associate(subtitleURLs: fixture.subtitles, with: fixture.media)
}

// The production matcher is a separately compiled module. One iteration includes
// complete association, output count consumption, and result destruction.
@inline(never)
private func run(_ fixture: Fixture, iterations: Int) -> UInt64 {
    var checksum = initialChecksum
    for _ in 0..<iterations { consume(Counts(associate(fixture)), into: &checksum) }
    return checksum
}

private func expectedChecksum(_ fixture: Fixture, iterations: Int) -> UInt64 {
    var checksum = initialChecksum
    let counts = Counts(fixture.expected)
    for _ in 0..<iterations { consume(counts, into: &checksum) }
    return checksum
}

private func verify(_ fixture: Fixture) throws -> [URL: [URL]] {
    let result = associate(fixture)
    guard result == fixture.expected else {
        throw DriverError("Complete associations differ from the independent fixture oracle.")
    }
    return result
}

private struct VerificationRecord: Codable {
    let caseName: String
    let mediaCount: Int
    let subtitleCount: Int
    let associations: [String: [String]]
}

private func verification() throws -> [VerificationRecord] {
    try cases.map { spec in
        let fixture = try Fixture.make(spec)
        let result = try verify(fixture)
        return VerificationRecord(caseName: spec.name, mediaCount: fixture.media.count,
            subtitleCount: fixture.subtitles.count,
            associations: Dictionary(uniqueKeysWithValues: result.map {
                ($0.key.absoluteString, $0.value.map(\.absoluteString))
            }))
    }
}

private func cpuTime() throws -> UInt64 {
    var value = timespec(tv_sec: 0, tv_nsec: 0)
    guard clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &value) == 0,
          value.tv_sec >= 0, value.tv_nsec >= 0 else {
        throw DriverError("Cannot read the process CPU clock (errno \(errno)).")
    }
    return UInt64(value.tv_sec) * 1_000_000_000 + UInt64(value.tv_nsec)
}

private struct Measurement: Codable {
    let caseName: String
    let localeIdentifier: String
    let mediaCount: Int
    let subtitleCount: Int
    let iterations: Int
    let warmupIterations: Int
    let wallNs: UInt64
    let cpuNs: UInt64
    let wallNsPerAssociation: Double
    let cpuNsPerAssociation: Double
    let checksum: UInt64
    let expectedChecksum: UInt64
}

private func writeJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    FileHandle.standardOutput.write(try encoder.encode(value))
    FileHandle.standardOutput.write(Data([0x0A]))
}

@main
private struct SubtitleFuzzyScoringBenchmark {
    static func main() {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            if args == ["--list-cases"] { try writeJSON(cases.map(\.name)); return }
            if args == ["--verify"] { try writeJSON(verification()); return }
            guard args.count.isMultiple(of: 2) else { throw DriverError("Options require values.") }
            var options: [String: String] = [:]
            for offset in stride(from: 0, to: args.count, by: 2) {
                let key = args[offset]
                guard ["--case", "--iterations", "--warmup"].contains(key),
                      options.updateValue(args[offset + 1], forKey: key) == nil else {
                    throw DriverError("Unknown or repeated option: \(key)")
                }
            }
            guard let spec = cases.first(where: { $0.name == options["--case"] }),
                  let iterations = Int(options["--iterations"] ?? ""), iterations > 0,
                  let warmup = Int(options["--warmup"] ?? "4"), warmup >= 0 else {
                throw DriverError("Use --case NAME --iterations N [--warmup N]; N must be valid.")
            }
            let fixture = try Fixture.make(spec)
            _ = try verify(fixture)
            guard run(fixture, iterations: warmup) == expectedChecksum(fixture, iterations: warmup) else {
                throw DriverError("Warmup checksum mismatch.")
            }
            let expected = expectedChecksum(fixture, iterations: iterations)
            let cpuStart = try cpuTime()
            let wallStart = DispatchTime.now().uptimeNanoseconds
            let checksum = run(fixture, iterations: iterations)
            let wall = DispatchTime.now().uptimeNanoseconds - wallStart
            let cpu = try cpuTime() - cpuStart
            guard checksum == expected else { throw DriverError("Timed checksum mismatch.") }
            try writeJSON(Measurement(caseName: spec.name, localeIdentifier: Locale.current.identifier,
                mediaCount: fixture.media.count, subtitleCount: fixture.subtitles.count,
                iterations: iterations, warmupIterations: warmup, wallNs: wall, cpuNs: cpu,
                wallNsPerAssociation: Double(wall) / Double(iterations),
                cpuNsPerAssociation: Double(cpu) / Double(iterations),
                checksum: checksum, expectedChecksum: expected))
        } catch {
            FileHandle.standardError.write(Data("subtitle-fuzzy-scoring: \(error)\n".utf8))
            exit(1)
        }
    }
}
