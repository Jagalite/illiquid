import CLeaseHeap
import Foundation
#if canImport(ObjectiveC)
import ObjectiveC
#endif

// Both variants compile this driver beside the actual production reader. Media
// URL inputs and fixture files exist before the timed/allocator interval. The
// reader opens only sidecars, so no media payload files are needed.
private struct Scenario: Codable {
    let name: String
    let count: Int
    let style: String

    static let all: [Scenario] = [
        .init(name: "missing-512", count: 512, style: "missing"),
        .init(name: "missing-8192", count: 8_192, style: "missing"),
        .init(name: "missing-cap", count: 50_010, style: "missing"),
        .init(name: "mixed-8192", count: 8_192, style: "mixed"),
        .init(name: "positive-8192", count: 8_192, style: "positive"),
        .init(name: "malformed-8192", count: 8_192, style: "malformed"),
        .init(name: "unique-parents-4096", count: 4_096, style: "unique"),
        .init(name: "unicode-1024", count: 1_024, style: "unicode"),
        .init(name: "extras-8192", count: 8_192, style: "extras"),
    ]
}

private struct Fixture {
    let scenario: Scenario
    let root: URL
    let files: [URL]

    init(_ scenario: Scenario, under base: URL, create: Bool) throws {
        self.scenario = scenario
        root = base.appendingPathComponent(scenario.name, isDirectory: true)
        if create {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        var files: [URL] = []
        files.reserveCapacity(scenario.count)
        for index in 0..<scenario.count {
            let folder: URL
            switch scenario.style {
            case "unique":
                folder = root.appendingPathComponent("Folder-\(index)", isDirectory: true)
            case "unicode":
                folder = root.appendingPathComponent("Épisodes 東京 🦊", isDirectory: true)
            default:
                folder = root
            }
            if create, folder != root {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            }
            // Keep recognized episode numbers in range even for the entry-cap
            // stress case; different editions still have distinct own-NFO paths.
            let name = scenario.style == "extras"
                ? "clip-\(index)-trailer.mp4"
                : "Series - S01E01 - Cut \(index).mkv"
            let file = folder.appendingPathComponent(name, isDirectory: false)
            files.append(file)
            if create {
                let own = file.deletingPathExtension().appendingPathExtension("nfo")
                if scenario.style == "positive" || (scenario.style == "mixed" && index % 16 == 0) {
                    try Data(("<episodedetails><showtitle>Canonical Series</showtitle>"
                        + "<title>Sidecar episode \(index)</title><season>2</season><episode>3</episode>"
                        + "</episodedetails>").utf8).write(to: own)
                } else if scenario.style == "malformed" {
                    // Readable but unsupported metadata consumes bytes and a
                    // negative-cache entry, just as a failed parse does in use.
                    try Data("<unsupported><title>Ignored</title></unsupported>".utf8).write(to: own)
                }
            }
        }
        self.files = files
        if create, scenario.style == "positive" || scenario.style == "mixed" {
            try Data("<tvshow><title>Shared Series</title><year>2018</year></tvshow>".utf8)
                .write(to: root.appendingPathComponent("tvshow.nfo"))
            try Data("title: Shared Series\nyear: 2019".utf8)
                .write(to: root.appendingPathComponent(".plexmatch"))
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

private struct ScanReceipt: Codable, Equatable {
    let filesRead: Int
    let checksum: UInt64
}

private struct Verification: Encodable {
    let scenario: Scenario
    let first: [Snapshot]
    let second: [Snapshot]
    let firstReceipt: ScanReceipt
    let secondReceipt: ScanReceipt
}

// Only this identical, small consumer runs inside timed scans. The verification
// mode separately compares every stored and derived result field exactly.
@inline(never)
private func contribution(_ value: RecognizedMediaName) -> UInt64 {
    var amount = value.title.utf8.count + value.kind.rawValue.utf8.count
    amount += (value.year ?? 0) + (value.season ?? 0)
    amount += (value.episode ?? 0) + (value.lastEpisode ?? 0)
    amount += (value.episodeTitle?.utf8.count ?? 0) + (value.airDate?.utf8.count ?? 0)
    amount += (value.edition?.utf8.count ?? 0) + (value.variant?.utf8.count ?? 0)
    amount += value.catalogIDs.count + value.metadataSources.count
    return UInt64(amount)
}

private func drainingAutoreleases<T>(_ body: () throws -> T) rethrows -> T {
    #if canImport(ObjectiveC)
    return try autoreleasepool(invoking: body)
    #else
    return try body()
    #endif
}

@inline(never)
private func scan(_ reader: MediaSidecarReader, fixture: Fixture, limit: Int? = nil) throws -> ScanReceipt {
    try drainingAutoreleases {
        var checksum: UInt64 = 0
        for file in fixture.files.prefix(limit ?? fixture.files.count) {
            checksum &+= contribution(try reader.recognize(file, within: fixture.root))
        }
        return ScanReceipt(filesRead: reader.filesRead, checksum: checksum)
    }
}

@inline(never)
private func warm(_ fixture: Fixture) throws {
    let reader = MediaSidecarReader()
    _ = try scan(reader, fixture: fixture, limit: 64)
    _ = lease_history_allocator_bytes()
    _ = lease_history_process_cpu_ns()
    _ = DispatchTime.now().uptimeNanoseconds
}

private struct HeldMeasurement {
    let before: UInt64
    let afterFirst: UInt64
    let afterSecond: UInt64
    let firstWallNS: UInt64
    let firstCPUNS: UInt64
    let secondWallNS: UInt64
    let secondCPUNS: UInt64
    let firstReceipt: ScanReceipt
    let secondReceipt: ScanReceipt
}

@inline(never)
private func measureHeldReader(_ fixture: Fixture) throws -> HeldMeasurement {
    let before = lease_history_allocator_bytes()
    let reader = MediaSidecarReader()
    let firstCPUStart = lease_history_process_cpu_ns()
    let firstStart = DispatchTime.now().uptimeNanoseconds
    let first = try scan(reader, fixture: fixture)
    let firstWall = DispatchTime.now().uptimeNanoseconds - firstStart
    let firstCPU = lease_history_process_cpu_ns() - firstCPUStart
    let afterFirst = withExtendedLifetime(reader) { lease_history_allocator_bytes() }
    let secondCPUStart = lease_history_process_cpu_ns()
    let secondStart = DispatchTime.now().uptimeNanoseconds
    let second = try scan(reader, fixture: fixture)
    let secondWall = DispatchTime.now().uptimeNanoseconds - secondStart
    let secondCPU = lease_history_process_cpu_ns() - secondCPUStart
    precondition(first == second, "A cached scan changed output or reread sidecars")
    let afterSecond = withExtendedLifetime(reader) { lease_history_allocator_bytes() }
    return HeldMeasurement(before: before, afterFirst: afterFirst, afterSecond: afterSecond,
        firstWallNS: firstWall, firstCPUNS: firstCPU, secondWallNS: secondWall, secondCPUNS: secondCPU,
        firstReceipt: first, secondReceipt: second)
}

private struct Measurement: Encodable {
    let scenario: String
    let count: Int
    let allocatorMetric: String
    let beforeBytes: UInt64
    let afterFirstBytes: UInt64
    let afterSecondBytes: UInt64
    let afterReleaseBytes: UInt64
    let retainedDeltaBytes: Int64
    let cachedDeltaBytes: Int64
    let releasedDeltaBytes: Int64
    let firstWallNS: UInt64
    let firstCPUNS: UInt64
    let secondWallNS: UInt64
    let secondCPUNS: UInt64
    let firstReceipt: ScanReceipt
    let secondReceipt: ScanReceipt
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
        guard let mode = args.first else { fatalError("Use list, prepare ROOT, verify ROOT CASE, or measure ROOT CASE") }
        if mode == "list" { try emit(Scenario.all); return }
        precondition(args.count >= 2)
        let base = URL(fileURLWithPath: args[1], isDirectory: true)
        if mode == "prepare" {
            for scenario in Scenario.all { _ = try Fixture(scenario, under: base, create: true) }
            try emit(Scenario.all)
            return
        }
        precondition(args.count == 3)
        let scenario = Scenario.all.first { $0.name == args[2] }!
        let fixture = try drainingAutoreleases { try Fixture(scenario, under: base, create: false) }
        if mode == "verify" {
            let reader = MediaSidecarReader()
            var firstChecksum: UInt64 = 0
            let first = try fixture.files.map { file in
                let value = try reader.recognize(file, within: fixture.root)
                firstChecksum &+= contribution(value)
                return Snapshot(value)
            }
            let firstReceipt = ScanReceipt(filesRead: reader.filesRead, checksum: firstChecksum)
            var secondChecksum: UInt64 = 0
            let second = try fixture.files.map { file in
                let value = try reader.recognize(file, within: fixture.root)
                secondChecksum &+= contribution(value)
                return Snapshot(value)
            }
            let secondReceipt = ScanReceipt(filesRead: reader.filesRead, checksum: secondChecksum)
            precondition(first == second && firstReceipt == secondReceipt)
            try emit(Verification(scenario: scenario, first: first, second: second,
                firstReceipt: firstReceipt, secondReceipt: secondReceipt))
        } else if mode == "measure" {
            try warm(fixture)
            let held = try measureHeldReader(fixture)
            // The noinline helper returned no reader or recognized results, so
            // its subject has been released before this final allocator sample.
            let released = lease_history_allocator_bytes()
            try emit(Measurement(scenario: scenario.name, count: scenario.count,
                allocatorMetric: String(cString: lease_history_allocator_metric()),
                beforeBytes: held.before, afterFirstBytes: held.afterFirst,
                afterSecondBytes: held.afterSecond, afterReleaseBytes: released,
                retainedDeltaBytes: Int64(held.afterFirst) - Int64(held.before),
                cachedDeltaBytes: Int64(held.afterSecond) - Int64(held.before),
                releasedDeltaBytes: Int64(released) - Int64(held.before),
                firstWallNS: held.firstWallNS, firstCPUNS: held.firstCPUNS,
                secondWallNS: held.secondWallNS, secondCPUNS: held.secondCPUNS,
                firstReceipt: held.firstReceipt, secondReceipt: held.secondReceipt))
        } else {
            fatalError("Unknown mode \(mode)")
        }
    }
}
