import Foundation
import IlliquidCore
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

private struct Scenario: Codable {
    let name: String
    let depth: Int // Root included, as in the reader's ancestor traversal.
    let count: Int
    let style: String
    let trajectory: String
    let measure: Bool

    var fixtureName: String { "\(style)-depth\(depth)-\(count)" }

    static let all: [Scenario] = {
        var cases: [Scenario] = []
        func add(_ style: String, _ depth: Int, _ count: Int, measure: Bool = true) {
            for trajectory in ["cold", "warm"] {
                cases.append(.init(name: "\(style)-depth\(depth)-\(count)-\(trajectory)",
                    depth: depth, count: count, style: style, trajectory: trajectory, measure: measure))
            }
        }
        for depth in [1, 4, 12] {
            for count in [1, 100, 1_000] { add("rich", depth, count) }
        }
        add("missing", 4, 1_000)
        add("nfo", 4, 1_000)
        add("unique", 4, 100)
        add("alternating", 4, 1_000)
        add("mappings", 4, 8, measure: false)
        return cases
    }()
}

private struct Fixture {
    let scenario: Scenario
    let root: URL
    let files: [URL]

    init(_ scenario: Scenario, under base: URL, create: Bool) throws {
        self.scenario = scenario
        root = base.appendingPathComponent(scenario.fixtureName, isDirectory: true)
        var urls: [URL] = []
        var folders: [String: (URL, Int)] = [:]
        for index in 0..<scenario.count {
            var folder = root
            folders[folder.path] = (folder, 0)
            for level in 1..<scenario.depth {
                var component = "Level\(level)"
                if level == scenario.depth - 1 {
                    if scenario.style == "unique" { component += "-\(index)" }
                    if scenario.style == "alternating" { component += "-\(index % 2)" }
                }
                folder.appendPathComponent(component, isDirectory: true)
                folders[folder.path] = (folder, level)
            }
            let filename = String(format: "Filename Series - S02E%04d - Episode %04d {edition-Archive} 1080p.mkv", index + 1, index + 1)
            urls.append(folder.appendingPathComponent(filename, isDirectory: false))
        }
        files = urls
        guard create else { return }
        for (_, (folder, level)) in folders.sorted(by: { $0.key < $1.key }) {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            guard scenario.style != "missing" && scenario.style != "nfo" else { continue }
            var text = """
                title: Plex series \(level) 東京
                year: \(2000 + level)
                season: \(10 + level)
                tvdbid: \(20_000 + level)
                tmdbid: \(30_000 + level)
                imdbid: tt\(40_000 + level)
                guid: imdb://tt\(50_000 + level)
                """
            if scenario.style == "mappings" {
                if level == 0 {
                    for index in 0..<3 {
                        let path = String(files[index].path.dropFirst(root.path.count + 1))
                        text += "\nep: S07E\(51 + index)-E\(61 + index): \(path)"
                    }
                } else if level == scenario.depth - 1 {
                    text += "\nep: 81: \(files[1].lastPathComponent)"
                }
            }
            try Data(text.utf8).write(to: folder.appendingPathComponent(".plexmatch", isDirectory: false))
        }
        for file in files { try Data().write(to: file) }
        if scenario.style != "missing" {
            try Data("""
                <tvshow><title>NFO series</title><year>1998</year>
                <uniqueid type="tvdb">11</uniqueid><uniqueid type="tmdb">22</uniqueid>
                <uniqueid type="imdb">tt33</uniqueid></tvshow>
                """.utf8).write(to: root.appendingPathComponent("tvshow.nfo", isDirectory: false))
        }
        if scenario.style == "mappings" {
            try Data("""
                <episodedetails><showtitle>Own series</showtitle><title>Own episode</title>
                <season>3</season><episode>9</episode></episodedetails>
                """.utf8).write(to: files[2].deletingPathExtension().appendingPathExtension("nfo"))
        }
    }

    var expectedReads: Int {
        if scenario.style == "missing" { return 0 }
        if scenario.style == "nfo" { return 1 }
        let parents = scenario.style == "unique" ? scenario.count : (scenario.style == "alternating" ? 2 : 1)
        return scenario.depth + parents + (scenario.style == "mappings" ? 1 : 0)
    }

    // Public recognize is dynamically linked from a separately compiled module.
    // No parser, merged-hint implementation, or filename work is extracted.
    @inline(never)
    func scan(using suppliedReader: MediaSidecarReader? = nil) throws -> ([RecognizedMediaName], Int) {
        let reader = suppliedReader ?? MediaSidecarReader()
        let before = reader.filesRead
        var outputs: [RecognizedMediaName] = []
        outputs.reserveCapacity(files.count)
        for file in files { outputs.append(try reader.recognize(file, within: root)) }
        return (outputs, reader.filesRead - before)
    }

    func assertIndependentExpectations(_ values: [RecognizedMediaName]) {
        precondition(values.count == scenario.count)
        for (index, value) in values.enumerated() {
            precondition(value.kind == .episode)
            if scenario.style == "missing" {
                precondition(value.title == "Filename Series" && value.year == nil)
                precondition(value.season == 2 && value.episode == index + 1)
                precondition(value.catalogIDs.isEmpty && value.metadataSources.isEmpty)
                continue
            }
            if scenario.style == "nfo" {
                precondition(value.title == "NFO series" && value.year == 1998)
                precondition(value.season == 2 && value.episode == index + 1)
                precondition(value.lastEpisode == nil)
                precondition(value.catalogIDs == ["tvdb-11", "tmdb-22", "imdb-tt33"])
                precondition(value.metadataSources == ["NFO"])
                continue
            }
            let level = scenario.depth - 1
            precondition(value.year == 2000 + level)
            precondition(value.catalogIDs == ["tvdb-\(20_000 + level)", "tmdb-\(30_000 + level)",
                "imdb-tt\(40_000 + level)", "imdb-tt\(50_000 + level)"])
            precondition(value.metadataSources == [".plexmatch", "NFO"])
            var expectedTitle = "Plex series \(level) 東京"
            var expectedSeason = 10 + level
            var expectedEpisode = index + 1
            var expectedLast: Int?
            if scenario.style == "mappings" {
                if index == 0 { expectedSeason = 7; expectedEpisode = 51; expectedLast = 61 }
                if index == 1 { expectedEpisode = 81 }
                if index == 2 {
                    expectedTitle = "Own series"; expectedSeason = 3; expectedEpisode = 9
                    precondition(value.episodeTitle == "Own episode")
                }
            }
            precondition(value.title == expectedTitle && value.season == expectedSeason)
            precondition(value.episode == expectedEpisode && value.lastEpisode == expectedLast)
        }
    }
}

private struct Snapshot: Codable, Equatable {
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
    let filesReadBefore: Int
    let filesReadAfter: [Int]
    let checkpoints: [Int]
    let checksum: UInt64
    let outputs: [Snapshot]
}

private struct Cancellation: Encodable {
    let scenario: String
    let primed: Bool
    let throwAt: Int
    let error: String
    let checkpoints: Int
    let filesReadBefore: Int
    let filesReadAfterThrow: Int
    let filesReadAfterResume: Int
    let resumed: Snapshot
}

private struct VerificationReport: Encodable {
    let scans: [Verification]
    let cancellations: [Cancellation]
}

private struct Measurement: Encodable {
    let scenario: String
    let iterations: Int
    let fileCount: Int
    let elapsedNS: UInt64
    let cpuNS: UInt64
    let filesReadPerScan: Int
    let totalFilesRead: Int
    let checksum: UInt64
    let final: [Snapshot]
}

// Identical, small consumer; exact UTF-8 field parity is checked outside timing.
@inline(never)
private func consume(_ values: [RecognizedMediaName]) -> UInt64 {
    var checksum: UInt64 = 0
    for value in values {
        var contribution = value.title.utf8.count + value.kind.rawValue.utf8.count
        contribution += (value.year ?? 0) + (value.season ?? 0) + (value.episode ?? 0) + (value.lastEpisode ?? 0)
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
        guard let mode = args.first else { fatalError("Use list, prepare ROOT, verify ROOT, bench ROOT CASE ITERATIONS") }
        if mode == "list" { try emit(Scenario.all); return }
        precondition(args.count >= 2)
        let base = URL(fileURLWithPath: args[1], isDirectory: true)
        if mode == "prepare" {
            var prepared: Set<String> = []
            for scenario in Scenario.all where prepared.insert(scenario.fixtureName).inserted {
                _ = try Fixture(scenario, under: base, create: true)
            }
            try emit(Scenario.all)
        } else if mode == "verify" {
            var scans: [Verification] = []
            var cancellations: [Cancellation] = []
            for scenario in Scenario.all {
                let fixture = try Fixture(scenario, under: base, create: false)
                let reader = MediaSidecarReader()
                if scenario.trajectory == "warm" { _ = try fixture.scan(using: reader) }
                let before = reader.filesRead
                var values: [RecognizedMediaName] = []
                var reads: [Int] = []
                var checkpoints: [Int] = []
                for file in fixture.files {
                    var checks = 0
                    values.append(try reader.recognize(file, within: fixture.root) { checks += 1 })
                    reads.append(reader.filesRead); checkpoints.append(checks)
                    precondition(checks == scenario.depth * 2 + 1)
                }
                fixture.assertIndependentExpectations(values)
                precondition(reader.filesRead == fixture.expectedReads)
                scans.append(.init(scenario: scenario, filesReadBefore: before, filesReadAfter: reads,
                    checkpoints: checkpoints, checksum: consume(values), outputs: values.map(Snapshot.init)))

                // Sweep every discovery/read/final checkpoint with cold and
                // primed readers, then resume on the same reader after throw.
                if (scenario.style == "rich" && scenario.count == 1) || scenario.style == "mappings" {
                    let primed = scenario.trajectory == "warm"
                    let file = fixture.files[min(1, fixture.files.count - 1)]
                    for stop in 1...(scenario.depth * 2 + 1) {
                        let interrupted = MediaSidecarReader()
                        if primed { _ = try interrupted.recognize(fixture.files[0], within: fixture.root) }
                        let initialReads = interrupted.filesRead
                        var checks = 0
                        var errorType = "none"
                        do {
                            _ = try interrupted.recognize(file, within: fixture.root) {
                                checks += 1
                                if checks == stop { throw CancellationError() }
                            }
                        } catch is CancellationError { errorType = "CancellationError" }
                        precondition(errorType == "CancellationError" && checks == stop)
                        let stoppedReads = interrupted.filesRead
                        let resumed = try interrupted.recognize(file, within: fixture.root)
                        precondition(resumed == values[min(1, fixture.files.count - 1)])
                        cancellations.append(.init(scenario: scenario.name, primed: primed, throwAt: stop,
                            error: errorType, checkpoints: checks, filesReadBefore: initialReads,
                            filesReadAfterThrow: stoppedReads, filesReadAfterResume: interrupted.filesRead,
                            resumed: Snapshot(resumed)))
                    }
                }
            }
            try emit(VerificationReport(scans: scans, cancellations: cancellations))
        } else if mode == "bench" {
            precondition(args.count == 4)
            let scenario = Scenario.all.first { $0.name == args[2] }!
            let iterations = Int(args[3])!
            precondition((1...100_000).contains(iterations))
            let fixture = try Fixture(scenario, under: base, create: false)
            let reader: MediaSidecarReader? = scenario.trajectory == "warm" ? MediaSidecarReader() : nil
            let warmup = try fixture.scan(using: reader)
            fixture.assertIndependentExpectations(warmup.0)
            precondition(warmup.1 == fixture.expectedReads)
            let expectedChecksum = consume(warmup.0)
            let expectedReads = scenario.trajectory == "warm" ? 0 : fixture.expectedReads
            var checksum: UInt64 = 0
            var reads = 0
            var final: [RecognizedMediaName] = []
            let cpuStart = cpuTime()
            let start = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<iterations {
                let result = try fixture.scan(using: reader)
                checksum &+= consume(result.0)
                reads += result.1
                final = result.0
            }
            let elapsed = DispatchTime.now().uptimeNanoseconds - start
            let cpu = cpuTime() - cpuStart
            precondition(final == warmup.0 && reads == expectedReads * iterations)
            precondition(checksum == expectedChecksum &* UInt64(iterations))
            try emit(Measurement(scenario: scenario.name, iterations: iterations, fileCount: scenario.count,
                elapsedNS: elapsed, cpuNS: cpu, filesReadPerScan: expectedReads, totalFilesRead: reads,
                checksum: checksum, final: final.map(Snapshot.init)))
        } else { fatalError("Unknown mode \(mode)") }
    }
}
