import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

// Compiled beside the actual production sources in both variants. Fixture
// construction and JSON serialization are outside every timed interval.
private struct Scenario: Codable {
    let name: String
    let depth: Int // Includes the source root, matching the reader's 64-folder limit.
    let count: Int
    let style: String
    let measure: Bool

    static let all: [Scenario] = [
        .init(name: "siblings-depth1", depth: 1, count: 128, style: "missing", measure: true),
        .init(name: "siblings-depth4", depth: 4, count: 128, style: "missing", measure: true),
        .init(name: "siblings-depth12", depth: 12, count: 128, style: "missing", measure: true),
        .init(name: "siblings-depth63", depth: 63, count: 128, style: "missing", measure: true),
        .init(name: "show-nfo-depth4", depth: 4, count: 128, style: "show", measure: true),
        .init(name: "nested-plex-depth4", depth: 4, count: 128, style: "plex", measure: true),
        .init(name: "per-file-nfo-depth4", depth: 4, count: 128, style: "movie", measure: true),
        .init(name: "unique-parents-depth4", depth: 4, count: 128, style: "unique", measure: true),
        .init(name: "alternating-parents-depth4", depth: 4, count: 128, style: "alternating", measure: true),
        .init(name: "unicode-depth4", depth: 4, count: 128, style: "unicode", measure: true),
        .init(name: "extras-depth4", depth: 4, count: 128, style: "extras", measure: true),
        .init(name: "single-file-depth4", depth: 4, count: 1, style: "missing", measure: true),
        .init(name: "boundary-depth64", depth: 64, count: 4, style: "show", measure: false),
        .init(name: "rejected-depth65", depth: 65, count: 4, style: "show", measure: false),
        .init(name: "decomposed-unicode", depth: 4, count: 4, style: "decomposed", measure: false),
    ]
}

private struct Fixture {
    let scenario: Scenario
    let root: URL
    let files: [URL]

    init(_ scenario: Scenario, under base: URL, create: Bool) throws {
        self.scenario = scenario
        root = base.appendingPathComponent(scenario.name, isDirectory: true)
        var urls: [URL] = []
        var rootMappings = ["title: Mapped Show", "year: 2016"]
        for index in 0..<scenario.count {
            var folder = root
            for level in 1..<scenario.depth {
                var component = String(format: "Folder%02d", level)
                if level == scenario.depth - 1 {
                    switch scenario.style {
                    case "unique": component += "-\(index)"
                    case "alternating": component += "-\(index % 2)"
                    case "unicode": component = "Épisodes 東京 🦊"
                    case "decomposed": component = "E\u{301}pisodes 東京 🦊"
                    default: break
                    }
                }
                folder.appendPathComponent(component, isDirectory: true)
            }
            let filename: String
            switch scenario.style {
            case "show", "unicode", "decomposed":
                filename = String(format: "Show - S02E%04d - Episode.mkv", index + 1)
            case "plex": filename = String(format: "opaque%04d.mkv", index + 1)
            case "extras": filename = String(format: "clip%04d-trailer.mp4", index + 1)
            default: filename = String(format: "Film %04d (2020).mkv", index + 1)
            }
            let file = folder.appendingPathComponent(filename, isDirectory: false)
            urls.append(file)
            if create {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try Data().write(to: file)
                if scenario.style == "movie" {
                    try Self.write("<movie><title>File metadata \(index)</title><year>2019</year>"
                        + "<uniqueid type='imdb'>tt\(1000 + index)</uniqueid></movie>",
                        to: file.deletingPathExtension().appendingPathExtension("nfo"))
                }
            }
            if scenario.style == "plex" {
                let relative = String(file.path.dropFirst(root.path.count + 1))
                rootMappings.append("ep: S02E\(index + 1): \(relative)")
            }
        }
        files = urls
        if create {
            switch scenario.style {
            case "show", "unicode", "decomposed":
                try Self.write("<tvshow><title>Canonical Show 東京</title><year>2010</year>"
                    + "<uniqueid type='tvdb'>1234</uniqueid></tvshow>",
                    to: root.appendingPathComponent("tvshow.nfo", isDirectory: false))
            case "plex":
                try Self.write(rootMappings.joined(separator: "\n"),
                               to: root.appendingPathComponent(".plexmatch", isDirectory: false))
                try Self.write("season: 7\nep: S04E41-E42: opaque0003.mkv",
                               to: files[0].deletingLastPathComponent().appendingPathComponent(".plexmatch", isDirectory: false))
            default: break
            }
        }
    }

    private static func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url)
    }

    @inline(never)
    func scan() throws -> ([RecognizedMediaName], Int) {
        // A real scan creates one reader and processes its files in order. The
        // sidecar-content and path caches therefore start empty on EVERY scan.
        let reader = MediaSidecarReader()
        var results: [RecognizedMediaName] = []
        results.reserveCapacity(files.count)
        for file in files { results.append(try reader.recognize(file, within: root)) }
        return (results, reader.filesRead)
    }
}

private struct Snapshot: Codable {
    let kind: String
    let title: String
    let year: Int?
    let season: Int?
    let episode: Int?
    let lastEpisode: Int?
    let airDate: String?
    let episodeTitle: String?
    let edition: String?
    let catalogIDs: [String]
    let variant: String?
    let metadataSources: [String]
    let seriesTitle: String
    let displayName: String
    let section: String

    init(_ value: RecognizedMediaName) {
        kind = value.kind.rawValue; title = value.title; year = value.year
        season = value.season; episode = value.episode; lastEpisode = value.lastEpisode
        airDate = value.airDate; episodeTitle = value.episodeTitle; edition = value.edition
        catalogIDs = value.catalogIDs; variant = value.variant; metadataSources = value.metadataSources
        seriesTitle = value.seriesTitle; displayName = value.displayName; section = value.section
    }
}

private struct Verification: Encodable {
    let scenario: Scenario
    let filesRead: Int
    let outputs: [Snapshot]
}

private struct Measurement: Encodable {
    let scenario: String
    let iterations: Int
    let fileCount: Int
    let elapsedNS: UInt64
    let cpuNS: UInt64
    let filesReadPerScan: Int
    let checksum: UInt64
    let final: [Snapshot]
}

// A small identical consumer keeps the complete returned values alive. Full
// JSON/field parity is checked separately, outside the timed loop.
@inline(never)
private func consume(_ values: [RecognizedMediaName]) -> UInt64 {
    var checksum: UInt64 = 0
    for value in values {
        var contribution: Int = value.title.utf8.count + value.kind.rawValue.utf8.count
        contribution += (value.year ?? 0) + (value.season ?? 0)
        contribution += (value.episode ?? 0) + (value.lastEpisode ?? 0)
        contribution += (value.episodeTitle?.utf8.count ?? 0) + (value.airDate?.utf8.count ?? 0)
        contribution += (value.edition?.utf8.count ?? 0) + (value.variant?.utf8.count ?? 0)
        contribution += value.catalogIDs.count + value.metadataSources.count
        checksum &+= UInt64(contribution)
    }
    return checksum
}

private func cpuTime() -> UInt64 {
    var value = timespec()
    precondition(clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &value) == 0)
    return UInt64(value.tv_sec) * 1_000_000_000 + UInt64(value.tv_nsec)
}

private func emit<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    print(String(decoding: try encoder.encode(value), as: UTF8.self))
}

@main
private struct Harness {
    static func main() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let mode = args.first else { fatalError("Use list, prepare ROOT, verify ROOT, or bench ROOT CASE ITERATIONS") }
        if mode == "list" { try emit(Scenario.all); return }
        precondition(args.count >= 2)
        let base = URL(fileURLWithPath: args[1], isDirectory: true)
        if mode == "prepare" {
            for scenario in Scenario.all { _ = try Fixture(scenario, under: base, create: true) }
            try emit(Scenario.all)
        } else if mode == "verify" {
            var rows: [Verification] = []
            for scenario in Scenario.all {
                let fixture = try Fixture(scenario, under: base, create: false)
                let (outputs, reads) = try fixture.scan()
                rows.append(.init(scenario: scenario, filesRead: reads, outputs: outputs.map(Snapshot.init)))
            }
            try emit(rows)
        } else if mode == "bench" {
            precondition(args.count == 4)
            let scenario = Scenario.all.first { $0.name == args[2] }!
            let iterations = Int(args[3])!
            precondition((1...100_000).contains(iterations))
            let fixture = try Fixture(scenario, under: base, create: false)
            let warmup = try fixture.scan()
            let expectedChecksum = consume(warmup.0)
            var checksum: UInt64 = 0
            var reads = 0
            var final: [RecognizedMediaName] = []
            let cpuStart = cpuTime()
            let start = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<iterations {
                let (outputs, filesRead) = try fixture.scan()
                checksum &+= consume(outputs)
                reads += filesRead
                final = outputs
            }
            let elapsed = DispatchTime.now().uptimeNanoseconds - start
            let cpu = cpuTime() - cpuStart
            precondition(final == warmup.0 && reads == warmup.1 * iterations)
            precondition(checksum == expectedChecksum &* UInt64(iterations))
            try emit(Measurement(scenario: scenario.name, iterations: iterations,
                                 fileCount: scenario.count, elapsedNS: elapsed, cpuNS: cpu,
                                 filesReadPerScan: warmup.1, checksum: checksum,
                                 final: final.map(Snapshot.init)))
        } else { fatalError("Unknown mode \(mode)") }
    }
}
