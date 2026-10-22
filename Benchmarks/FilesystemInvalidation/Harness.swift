import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// Compile this harness alongside one complete production planner source.
// Synthetic fixtures use lexical paths. Existing-path fixtures are created by
// the runner before launch; the harness never creates or enumerates media files.
private struct Fixture {
    let name: String
    let events: [SourceFilesystemEvent]
    let roots: [URL]
}

private struct CanonicalPlan: Codable, Equatable {
    let directories_to_reload: [String]
    let trees_to_invalidate: [String]
    let roots_to_rescan: [String]

    init(_ plan: SourceFilesystemInvalidationPlan) {
        directories_to_reload = plan.directoriesToReload.sorted()
        trees_to_invalidate = plan.treesToInvalidate.sorted()
        roots_to_rescan = plan.rootsToRescan.sorted()
    }
}

private struct VerificationRecord: Codable {
    let id: String
    let plan: CanonicalPlan
}

private struct Verification: Encodable {
    let format_version = 1
    let single_event_matrix: [VerificationRecord]
    let mixed_batches: [VerificationRecord]
    let workloads: [VerificationRecord]
}

private struct Measurement: Codable {
    let name: String
    let iterations: Int
    let event_count: Int
    let root_count: Int
    let elapsed_ns: UInt64
    let cpu_ns: UInt64
    let checksum: UInt64
    let final_plan: CanonicalPlan

    enum CodingKeys: String, CodingKey {
        case name = "case"
        case iterations, event_count, root_count, elapsed_ns, cpu_ns, checksum, final_plan
    }
}

private let prefix = "/tmp/illiquid-event-benchmark"

private func existingFixtureBase() -> String {
    guard let value = ProcessInfo.processInfo.environment["ILLIQUID_FILESYSTEM_BENCHMARK_FIXTURES"],
          value.hasPrefix("/") else {
        fatalError("ILLIQUID_FILESYSTEM_BENCHMARK_FIXTURES must name an absolute fixture directory")
    }
    return value
}

private func folder(_ path: String) -> URL {
    URL(fileURLWithPath: path, isDirectory: true)
}

private func roots(_ count: Int) -> [URL] {
    (0..<count).map { folder("\(prefix)/Library-\($0)") }
}

private func fixtures() -> [Fixture] {
    typealias Flags = SourceFilesystemEvent.Flags
    func structural(_ count: Int, _ rootCount: Int) -> [SourceFilesystemEvent] {
        let flags: [Flags] = [.created, .removed, .renamed]
        return (0..<count).map { index in
            .init(
                path: "\(prefix)/Library-\(index % rootCount)/Season-\(index % 37)/Episode-\(index).mkv",
                flags: flags[index % flags.count]
            )
        }
    }
    func content(_ count: Int, _ rootCount: Int) -> [SourceFilesystemEvent] {
        (0..<count).map { index in
            .init(
                path: "\(prefix)/Library-\(index % rootCount)/Season-\(index % 37)/Episode-\(index).mkv",
                flags: []
            )
        }
    }
    func metadata(_ count: Int, _ rootCount: Int) -> [SourceFilesystemEvent] {
        let names = [".plexmatch", "movie.nfo", "tvshow.NFO", "Episode.nFo"]
        return (0..<count).map { index in
            .init(
                path: "\(prefix)/Library-\(index % rootCount)/Season-\(index % 37)/\(names[index % names.count])",
                flags: []
            )
        }
    }
    let directoryFlags: [Flags] = [
        .directory, [.directory, .created], [.directory, .removed], [.directory, .renamed],
    ]
    let directoryEvents: [SourceFilesystemEvent] = (0..<256).map { index in
        .init(path: "\(prefix)/Library-\(index % 8)/Season-\(index)",
              flags: directoryFlags[index % directoryFlags.count])
    }
    let nestedPaths = [prefix, "\(prefix)/Library-0", "\(prefix)/Library-0/Season-0",
                       "\(prefix)/Library-1", "\(prefix)/Library-1/Season-1"]
    let fullRescanEvents: [SourceFilesystemEvent] = (0..<256).map { index in
        switch index % 8 {
        case 0:
            .init(path: "\(prefix)/Library-\(index % 32)", flags: [.mustScanSubdirectories])
        case 1:
            .init(path: "\(prefix)/Library-\(index % 32)/Season-0", flags: [.eventIDsWrapped])
        case 2:
            .init(path: "\(prefix)/Library-\(index % 32)", flags: [.rootChanged])
        default:
            .init(path: "\(prefix)/Library-\(index % 32)/Season-0/Episode-\(index).mkv", flags: [.created])
        }
    }
    var dropped = structural(4_095, 32)
    // The marker is deliberately unrelated and last. Stream loss must win
    // without normalizing or processing the 4,095 earlier event paths.
    dropped.append(.init(path: "/outside-watch-stream", flags: [.eventsDropped]))

    let existingBase = existingFixtureBase()
    let existingFiles: [SourceFilesystemEvent] = (0..<256).map { index in
        .init(path: "\(existingBase)/files/Group\(index % 16)/Episode\(index).mkv", flags: [.created])
    }
    let existingMetadata: [SourceFilesystemEvent] = (0..<256).map { index in
        .init(path: "\(existingBase)/metadata/Group\(index % 16)/Episode\(index).nfo", flags: [])
    }
    let existingDirectoryFlags: [Flags] = [
        [.directory, .created], [.directory, .removed], [.directory, .renamed],
    ]
    let existingDirectories: [SourceFilesystemEvent] = (0..<256).map { index in
        .init(path: "\(existingBase)/directories/Season\(index)",
              flags: existingDirectoryFlags[index % existingDirectoryFlags.count])
    }

    return [
        Fixture(name: "one_event", events: structural(1, 1), roots: roots(1)),
        Fixture(name: "structural_256_1root", events: structural(256, 1), roots: roots(1)),
        Fixture(name: "structural_4096_1root", events: structural(4_096, 1), roots: roots(1)),
        Fixture(name: "structural_256_32roots", events: structural(256, 32), roots: roots(32)),
        Fixture(name: "content_4096_1root", events: content(4_096, 1), roots: roots(1)),
        Fixture(name: "content_4096_32roots", events: content(4_096, 32), roots: roots(32)),
        Fixture(name: "metadata_256_1root", events: metadata(256, 1), roots: roots(1)),
        Fixture(name: "metadata_256_32roots", events: metadata(256, 32), roots: roots(32)),
        Fixture(name: "directory_mix_256", events: directoryEvents, roots: roots(8)),
        Fixture(name: "unmatched_256_32roots", events: (0..<256).map { index in
            .init(path: "\(prefix)/Library-\(index % 32)-sibling/Film-\(index).mkv", flags: [.created])
        }, roots: roots(32)),
        Fixture(name: "nested_roots_256", events: structural(256, 2), roots: nestedPaths.map(folder)),
        Fixture(name: "full_rescan_256", events: fullRescanEvents, roots: roots(32)),
        Fixture(name: "dropped_4096", events: dropped, roots: roots(32)),
        Fixture(name: "no_roots", events: structural(256, 1), roots: []),
        Fixture(name: "empty_events", events: [], roots: roots(32)),
        Fixture(name: "existing_structural_256", events: existingFiles, roots: [folder("\(existingBase)/files")]),
        Fixture(name: "existing_content_256", events: existingFiles.map {
            .init(path: $0.path, flags: [])
        }, roots: [folder("\(existingBase)/files")]),
        Fixture(name: "existing_metadata_256", events: existingMetadata, roots: [folder("\(existingBase)/metadata")]),
        Fixture(name: "existing_directory_256", events: existingDirectories, roots: [folder("\(existingBase)/directories")]),
    ]
}

@inline(never)
private func plannedCountChecksum(_ fixture: Fixture) -> UInt64 {
    let plan = SourceFilesystemInvalidationPlanner.plan(events: fixture.events, roots: fixture.roots)
    // Every returned collection participates. Member sorting/JSON encoding are
    // deliberately outside the timed region, and verified in full separately.
    return UInt64(plan.directoriesToReload.count) &* 1_000_003
        &+ UInt64(plan.treesToInvalidate.count) &* 1_000_033
        &+ UInt64(plan.rootsToRescan.count) &* 1_000_037
}

private func nanoseconds(_ clock: clockid_t) -> UInt64 {
    var value = timespec()
    precondition(clock_gettime(clock, &value) == 0, "clock_gettime failed")
    return UInt64(value.tv_sec) &* 1_000_000_000 &+ UInt64(value.tv_nsec)
}

@inline(never)
private func measure(_ fixture: Fixture, iterations: Int) -> Measurement {
    // Two real planner calls warm the same complete workload before timing.
    var warmupChecksum: UInt64 = 0
    for _ in 0..<2 { warmupChecksum &+= plannedCountChecksum(fixture) }
    var checksum: UInt64 = warmupChecksum
    let wallStart = nanoseconds(CLOCK_MONOTONIC)
    let cpuStart = nanoseconds(CLOCK_PROCESS_CPUTIME_ID)
    for _ in 0..<iterations { checksum &+= plannedCountChecksum(fixture) }
    let cpuEnd = nanoseconds(CLOCK_PROCESS_CPUTIME_ID)
    let wallEnd = nanoseconds(CLOCK_MONOTONIC)
    let finalPlan = SourceFilesystemInvalidationPlanner.plan(events: fixture.events, roots: fixture.roots)
    return Measurement(name: fixture.name, iterations: iterations,
        event_count: fixture.events.count, root_count: fixture.roots.count,
        elapsed_ns: wallEnd - wallStart, cpu_ns: cpuEnd - cpuStart, checksum: checksum,
        final_plan: CanonicalPlan(finalPlan))
}

private struct Generator {
    var value: UInt64 = 0xCBF2_9CE4_8422_2325
    mutating func next(_ limit: Int) -> Int {
        value = value &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Int((value >> 32) % UInt64(limit))
    }
}

private func verify(_ workloads: [Fixture]) -> Verification {
    // Do not substitute a handwritten path-normalization oracle. The runner
    // compares full canonical outputs from the exact old/new production code.
    let unicodeNFC = "\(prefix)/Caf\u{00E9}"
    let unicodeNFD = "\(prefix)/Cafe\u{0301}"
    let rootGroups: [[URL]] = [
        [],
        [folder("/")],
        [folder(prefix)],
        [folder("\(prefix)/Library-0")],
        [folder(prefix), folder("\(prefix)/Library-0"), folder("\(prefix)/Library-0/Season-0")],
        [folder("\(prefix)/Library-0"), folder("\(prefix)/Library-1"), folder("\(prefix)/映画 Library")],
        [folder("\(prefix)/Library-0/"), folder("\(prefix)/Library-0/../Library-0")],
        [folder(unicodeNFC), folder(unicodeNFD), folder("\(prefix)/100% Movies")],
        [URL(fileURLWithPath: "relative-library", isDirectory: true)],
    ]
    let paths = [
        "/", prefix, "\(prefix)/Library-0", "\(prefix)/Library-0/Season-0",
        "\(prefix)/Library-0/Season-0/Episode.mkv", "\(prefix)/Library-0/Season-0/",
        "\(prefix)/Library-0/./Season-0/../Episode.mkv", "\(prefix)/Library-0//Season-0/Episode.mkv",
        "\(prefix)/Library-0/.plexmatch", "\(prefix)/Library-0/.PLEXMATCH", "\(prefix)/Library-0/movie.nfo",
        "\(prefix)/Library-0/Movie.NFO", "\(prefix)/Library-0/.nfo", "\(prefix)/Library-0/movie.nfo/",
        "\(prefix)/Library-00/Episode.mkv", "\(prefix)/Library-0-sibling/Episode.mkv",
        "\(prefix)/Library-1/Episode.mkv", "/outside-watch-stream/Episode.mkv",
        "\(prefix)/映画 Library/第 1 話.nfo", "\(prefix)/100% Movies/100%25 #? film.nfo",
        "\(unicodeNFC)/Movie.mkv", "\(unicodeNFD)/Movie.mkv", "relative-library/Episode.mkv",
        "relative-library/../relative-library/.plexmatch", "", "//tmp/illiquid-event-benchmark/Library-0/Movie.mkv",
    ]
    var matrix: [VerificationRecord] = []
    matrix.reserveCapacity(rootGroups.count * paths.count * 256)
    for (rootIndex, rootGroup) in rootGroups.enumerated() {
        for (pathIndex, path) in paths.enumerated() {
            for rawFlags in UInt16(0)...UInt16(255) {
                let plan = SourceFilesystemInvalidationPlanner.plan(
                    events: [.init(path: path, flags: .init(rawValue: rawFlags))], roots: rootGroup)
                matrix.append(.init(id: "roots-\(rootIndex)-path-\(pathIndex)-flags-\(rawFlags)",
                                    plan: CanonicalPlan(plan)))
            }
        }
    }

    let ordinaryFlags: [SourceFilesystemEvent.Flags] = [
        [], .created, .removed, .renamed, .directory,
        [.directory, .created], [.directory, .removed], [.directory, .renamed],
        [.created, .removed, .renamed], [.directory, .created, .removed, .renamed],
        .mustScanSubdirectories, .rootChanged, .eventIDsWrapped,
    ]
    var generator = Generator()
    var batches: [VerificationRecord] = []
    for batchIndex in 0..<256 {
        let rootGroup = rootGroups[generator.next(rootGroups.count)]
        var events: [SourceFilesystemEvent] = (0..<(1 + generator.next(64))).map { _ in
            .init(path: paths[generator.next(paths.count)],
                  flags: ordinaryFlags[generator.next(ordinaryFlags.count)])
        }
        if batchIndex % 8 == 0 {
            let loss = SourceFilesystemEvent(path: "/unrelated-stream-loss", flags: [.eventsDropped])
            events.insert(loss, at: batchIndex % 16 == 0 ? 0 : events.count)
        }
        for (label, ordered) in [("forward", events), ("reverse", Array(events.reversed()))] {
            let plan = SourceFilesystemInvalidationPlanner.plan(events: ordered, roots: rootGroup)
            batches.append(.init(id: "batch-\(batchIndex)-\(label)", plan: CanonicalPlan(plan)))
        }
    }
    let existingBase = existingFixtureBase()
    for (pathIndex, path) in [
        "\(existingBase)/directories/.plexmatch", "\(existingBase)/directories/Series.nfo",
    ].enumerated() {
        for rawFlags in UInt16(0)...UInt16(255) {
            let plan = SourceFilesystemInvalidationPlanner.plan(
                events: [.init(path: path, flags: .init(rawValue: rawFlags))],
                roots: [folder("\(existingBase)/directories")])
            batches.append(.init(id: "existing-metadata-directory-\(pathIndex)-flags-\(rawFlags)",
                                 plan: CanonicalPlan(plan)))
        }
    }
    return Verification(single_event_matrix: matrix, mixed_batches: batches,
        workloads: workloads.map { fixture in
            .init(id: fixture.name, plan: CanonicalPlan(SourceFilesystemInvalidationPlanner.plan(
                events: fixture.events, roots: fixture.roots)))
        })
}

private func emit<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let encoded = try encoder.encode(value)
    FileHandle.standardOutput.write(encoded)
    FileHandle.standardOutput.write(Data([0x0A]))
}

@main
private enum FilesystemInvalidationHarness {
    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let workloads = fixtures()
        if arguments == ["cases"] {
            try emit(workloads.map(\.name))
        } else if arguments == ["verify"] {
            try emit(verify(workloads))
        } else if arguments.count == 3, arguments[0] == "bench",
                  let fixture = workloads.first(where: { $0.name == arguments[1] }),
                  let iterations = Int(arguments[2]), iterations > 0 {
            try emit(measure(fixture, iterations: iterations))
        } else {
            FileHandle.standardError.write(Data(
                "usage: filesystem-invalidation cases | verify | bench CASE POSITIVE_ITERATIONS\n".utf8))
            exit(2)
        }
    }
}
