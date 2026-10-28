import Dispatch
import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

private let workloadNames = [
    "empty", "singleton_no_base", "singleton_saved",
    "unique_10", "unique_100", "unique_1000", "unique_10000",
    "edited_10000", "duplicates_10000", "no_base_10000",
    "remote_1000", "unicode_1000", "restoration_control_1000",
]
private let variantsPerWorkload = 4

private struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ value: String) { description = value }
}

@inline(__always)
private func releasingTemporaryObjects<T>(_ body: () throws -> T) rethrows -> T {
    #if canImport(Darwin)
    return try autoreleasepool(invoking: body)
    #else
    return try body()
    #endif
}

private struct Fixture {
    let name: String
    let items: [FolderPlaylistItem]
    let saved: [String]
    let expected: [String]
}

private struct Workload {
    let name: String
    let restorationControl: Bool
    let fixtures: [Fixture]
}

// The only variant-dependent adapter. All four complete production files are
// compiled unchanged; the runner separately verifies the real checkpoint callsite.
@inline(never)
private func restore(_ fixture: Fixture, control: Bool) -> [String] {
    if control {
        return PlaylistMutation.restoringOrder(fixture.items, ids: fixture.saved).map(\.id)
    }
    #if BASELINE
    return PlaylistMutation.restoringOrder(fixture.items, ids: fixture.saved).map(\.id)
    #else
    return PlaylistMutation.restoringIdentityOrder(fixture.items, ids: fixture.saved)
    #endif
}

private struct Fingerprint {
    private(set) var value: UInt64 = 14_695_981_039_346_656_037

    mutating func append(_ byte: UInt8) {
        value = (value ^ UInt64(byte)) &* 1_099_511_628_211
    }

    mutating func append(_ integer: UInt64) {
        for shift in stride(from: 0, to: 64, by: 8) {
            append(UInt8(truncatingIfNeeded: integer >> shift))
        }
    }

    mutating func append(_ string: String) {
        append(UInt64(string.utf8.count))
        for byte in string.utf8 { append(byte) }
    }

    var hex: String { String(value, radix: 16) }
}

// Every output identity and byte contributes, in order. This common consumption
// cost is included in timing; full byte-array equality is checked outside it.
@inline(never)
private func fingerprint(_ ids: [String]) -> Fingerprint {
    var result = Fingerprint()
    result.append(UInt64(ids.count))
    for id in ids { result.append(id) }
    return result
}

@inline(never)
private func consume(_ fixture: Fixture, control: Bool) -> UInt64 {
    releasingTemporaryObjects {
        let result = restore(fixture, control: control)
        return fingerprint(result).value
    }
}

private func sameBytes(_ lhs: [String], _ rhs: [String]) -> Bool {
    lhs.map { Array($0.utf8) } == rhs.map { Array($0.utf8) }
}

private struct FixtureReceipt: Codable, Equatable {
    let fixture: String
    let input_count: Int
    let saved_count: Int
    let output_count: Int
    let output_utf8_bytes: Int
    let output_fingerprint: String
    let first_id: String?
    let last_id: String?
    let legacy_identity_evaluations: Int
    let direct_identity_evaluations: Int
    let full_utf8_equality_verified: Bool
}

private func validate(_ fixture: Fixture, control: Bool = false) throws -> FixtureReceipt {
    try releasingTemporaryObjects {
        let actual = restore(fixture, control: control)
        let frozen = FrozenPlaylistMutation.restoringOrder(fixture.items, ids: fixture.saved).map(\.id)
        guard sameBytes(actual, fixture.expected), sameBytes(actual, frozen) else {
            throw Failure("Full UTF8 output mismatch in \(fixture.name)")
        }
        let n = fixture.items.count, u = actual.count
        // Derived from the frozen source, not instrumentation. The empty-saved
        // singleton skips deduplication's identity scan before its final map.
        let legacyReads = n == 0 ? 0 : (n == 1 && fixture.saved.isEmpty ? 1 : n + u)
        return FixtureReceipt(
            fixture: fixture.name, input_count: n, saved_count: fixture.saved.count,
            output_count: u, output_utf8_bytes: actual.reduce(0) { $0 + $1.utf8.count },
            output_fingerprint: fingerprint(actual).hex,
            first_id: actual.first, last_id: actual.last,
            legacy_identity_evaluations: legacyReads,
            direct_identity_evaluations: control ? legacyReads : n,
            full_utf8_equality_verified: true
        )
    }
}

private enum Family: Equatable { case local, remote, unicode }

private func identity(_ label: Int, family: Family) -> String {
    switch family {
    case .local: return "/Media/Episode \(label).mkv"
    case .remote: return "https://example.invalid/series/\(label).mkv?copy=\(label % 5)#start"
    case .unicode: return "/Media/Café/Season \(label % 12)/Épisode \(label).mkv"
    }
}

private struct RawItem: Encodable {
    let url: URL
    let externalSubtitleURLs: [URL]
    let dateAdded: Date?
}

private func decodedItem(_ url: URL, marker: Int) throws -> FolderPlaylistItem {
    let raw = RawItem(
        url: url, externalSubtitleURLs: [URL(fileURLWithPath: "/Subtitles/\(marker).srt")],
        dateAdded: Date(timeIntervalSince1970: Double(marker))
    )
    return try JSONDecoder().decode(FolderPlaylistItem.self, from: JSONEncoder().encode(raw))
}

private func catalog(count: Int, family: Family) throws -> [FolderPlaylistItem] {
    try (0..<count).map { label in
        let expected = identity(label, family: family)
        let item: FolderPlaylistItem
        switch family {
        case .local, .remote:
            let url: URL
            if family == .local {
                url = URL(fileURLWithPath: expected)
            } else {
                guard let parsed = URL(string: expected) else { throw Failure("Invalid remote fixture") }
                url = parsed
            }
            item = FolderPlaylistItem(
                url: url,
                externalSubtitleURLs: [
                    URL(fileURLWithPath: "/Subtitles/\(label)-1.srt"),
                    URL(fileURLWithPath: "/Subtitles/\(label)-2.srt"),
                ],
                dateAdded: Date(timeIntervalSince1970: Double(label))
            )
        case .unicode:
            let spelling = "file://LOCALHOST/Media/Cafe%CC%81/Discard/../Season%20\(label % 12)/E%CC%81pisode%20\(label).mkv"
            guard let url = URL(string: spelling) else { throw Failure("Invalid Unicode fixture") }
            // Decode deliberately bypasses the public normalizing initializer.
            item = try decodedItem(url, marker: label)
        }
        guard sameBytes([item.id], [expected]) else { throw Failure("Fixture identity changed: \(expected)") }
        return item
    }
}

// The authored oracle uses integer identity labels, independently of URL parsing
// and String canonical equality. Missing labels cannot re-enter the playlist.
private func expectedLabels(current: [Int], saved: [Int]) -> [Int] {
    let present = Set(current)
    var emitted: Set<Int> = []
    var result: [Int] = []
    for label in saved + current where present.contains(label) && emitted.insert(label).inserted {
        result.append(label)
    }
    return result
}

private func permuted(_ labels: [Int], phase: Int) -> [Int] {
    guard !labels.isEmpty else { return [] }
    // Every timed multi-item size is a power of ten or a multiple of 2,500;
    // 37 is coprime to those sizes and visits every occurrence exactly once.
    let shift = phase * max(1, labels.count / 7) + phase
    return labels.indices.map { labels[($0 * 37 + shift) % labels.count] }
}

private func savedOrder(_ labels: [Int], phase: Int) -> [Int] {
    guard !labels.isEmpty else { return [] }
    let shift = phase * max(1, labels.count / 3)
    let rotated = labels.indices.map { labels[($0 + shift) % labels.count] }
    return phase % 2 == 0 ? rotated : Array(rotated.reversed())
}

private func makeWorkload(_ name: String) throws -> Workload {
    guard workloadNames.contains(name) else { throw Failure("Unknown workload \(name)") }
    let control = name == "restoration_control_1000"
    if name == "empty" {
        return Workload(name: name, restorationControl: false, fixtures: (0..<variantsPerWorkload).map {
            Fixture(name: "\(name)/\($0)", items: [],
                    saved: Array(repeating: "/removed/\($0)", count: $0), expected: [])
        })
    }
    if name.hasPrefix("singleton_") {
        let entries = try catalog(count: variantsPerWorkload, family: .local)
        return Workload(name: name, restorationControl: false, fixtures: entries.indices.map {
            let id = identity($0, family: .local)
            return Fixture(name: "\(name)/\($0)", items: [entries[$0]],
                           saved: name == "singleton_no_base" ? [] : ["/removed", id, id],
                           expected: [id])
        })
    }
    let count: Int
    switch name {
    case "unique_10": count = 10
    case "unique_100": count = 100
    case "unique_1000", "remote_1000", "unicode_1000", "restoration_control_1000": count = 1_000
    default: count = 10_000
    }
    let family: Family = name == "remote_1000" ? .remote : (name == "unicode_1000" ? .unicode : .local)
    let distinct = name == "duplicates_10000" ? count / 4 : count
    let added = name == "edited_10000" ? count / 10 : 0
    let entries = try catalog(count: distinct + added, family: family)
    let currentBase: [Int]
    if added > 0 {
        currentBase = (0..<count).filter { $0 % 10 != 0 } + Array(count..<(count + added))
    } else {
        currentBase = (0..<count).map { $0 % distinct }
    }
    let savedBase: [Int]
    if name == "no_base_10000" {
        savedBase = []
    } else if name == "duplicates_10000" {
        savedBase = (0..<distinct).flatMap { [$0, $0] } + [distinct + 17, distinct + 17]
    } else {
        savedBase = Array(0..<count)
    }
    let fixtures = (0..<variantsPerWorkload).map { phase in
        let current = permuted(currentBase, phase: phase)
        let saved = savedOrder(savedBase, phase: phase)
        let ids = saved.map { label -> String in
            let id = identity(label, family: family)
            return family == .unicode && phase % 2 == 1 ? id.decomposedStringWithCanonicalMapping : id
        }
        return Fixture(
            name: "\(name)/\(phase)", items: current.map { entries[$0] }, saved: ids,
            expected: expectedLabels(current: current, saved: saved).map { identity($0, family: family) }
        )
    }
    return Workload(name: name, restorationControl: control, fixtures: fixtures)
}

private func sequences(alphabetSize: Int, maximumLength: Int) -> [[Int]] {
    var all: [[Int]] = [[]], layer: [[Int]] = [[]]
    for _ in 0..<maximumLength {
        layer = layer.flatMap { prefix in (0..<alphabetSize).map { prefix + [$0] } }
        all += layer
    }
    return all
}

private struct Verification: Encodable, Equatable {
    let timed_fixtures: [FixtureReceipt]
    let differential_fixtures: [FixtureReceipt]
    let full_utf8_equality_verified: Bool
}

private func verify() throws -> Verification {
    var timed: [FixtureReceipt] = []
    for name in workloadNames {
        let rows = try releasingTemporaryObjects {
            let workload = try makeWorkload(name)
            return try workload.fixtures.map { try validate($0, control: workload.restorationControl) }
        }
        timed += rows
    }

    let alias = URL(string: "file://LOCALHOST/Media/Season/../Cafe%CC%81.mkv")!
    let remote = URL(string: "https://example.invalid/Media/B.mkv?copy=1")!
    let entries = [
        FolderPlaylistItem(url: URL(fileURLWithPath: "/Media/Café.mkv")),
        try decodedItem(alias, marker: 1),
        FolderPlaylistItem(url: URL(fileURLWithPath: "/Media/B.mkv")),
        FolderPlaylistItem(url: remote),
    ]
    let labels = [0, 0, 1, 2]
    let known = ["/Media/Café.mkv", "/Media/B.mkv", remote.absoluteString]
    let savedIDs = ["/Media/Café.mkv", "/Media/Cafe\u{301}.mkv", "/Media/B.mkv", remote.absoluteString, "/removed"]
    let savedLabels = [0, 0, 1, 2, 3]
    var differential: [FixtureReceipt] = []
    for current in sequences(alphabetSize: 4, maximumLength: 3) {
        for saved in sequences(alphabetSize: 5, maximumLength: 2) {
            let expected = expectedLabels(current: current.map { labels[$0] },
                                          saved: saved.map { savedLabels[$0] }).map { known[$0] }
            let fixture = Fixture(name: "sequence/\(differential.count)",
                                  items: current.map { entries[$0] }, saved: saved.map { savedIDs[$0] },
                                  expected: expected)
            differential.append(try validate(fixture))
        }
    }
    let unsupported = [
        "file://media-server.example/Media/A.mkv", "file://127.0.0.1/Media/A.mkv",
        "file://user@localhost/Media/A.mkv", "file://user:example@localhost/Media/A.mkv",
        "file://localhost:1234/Media/A.mkv", "file://localhost:0/Media/A.mkv",
        "file:relative.mkv", "https://example.invalid/Media/A.mkv?id=1",
        "https://example.invalid/Media/A.mkv?id=2",
    ]
    for spelling in unsupported {
        let item = try decodedItem(URL(string: spelling)!, marker: 3)
        let fixture = Fixture(name: "unsupported/\(spelling)",
                              items: [entries[0], item, item], saved: [spelling, spelling, "/removed"],
                              expected: [spelling, known[0]])
        differential.append(try validate(fixture))
    }
    guard timed.count == workloadNames.count * variantsPerWorkload, differential.count == 2_644 else {
        throw Failure("Verification corpus is incomplete")
    }
    return Verification(timed_fixtures: timed, differential_fixtures: differential,
                        full_utf8_equality_verified: true)
}

private func cpuNanoseconds() -> UInt64 {
    var value = timespec()
    precondition(clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &value) == 0)
    return UInt64(value.tv_sec) * 1_000_000_000 + UInt64(value.tv_nsec)
}

private struct Measurement: Encodable {
    let workload: String
    let restoration_control: Bool
    let iterations: Int
    let fixture_count: Int
    let process_id: Int32
    let elapsed_nanoseconds: UInt64
    let cpu_nanoseconds: UInt64
    let cycle_checksum: String
    let checksum: String
    let expected_checksum: String
    let fixtures: [FixtureReceipt]
}

private func measure(_ name: String, iterations: Int) throws -> Measurement {
    guard iterations > 0, iterations % variantsPerWorkload == 0 else {
        throw Failure("Iterations must be a positive multiple of \(variantsPerWorkload)")
    }
    let workload = try releasingTemporaryObjects { try makeWorkload(name) }
    let receipts = try workload.fixtures.map { try validate($0, control: workload.restorationControl) }
    var cycleChecksum: UInt64 = 0
    for (index, row) in receipts.enumerated() {
        cycleChecksum &+= UInt64(row.output_fingerprint, radix: 16)! &* UInt64(index + 1)
    }
    let expected = cycleChecksum &* UInt64(iterations / variantsPerWorkload)
    var checksum: UInt64 = 0
    let startCPU = cpuNanoseconds()
    let startWall = DispatchTime.now().uptimeNanoseconds
    for index in 0..<iterations {
        let position = index % variantsPerWorkload
        checksum &+= consume(workload.fixtures[position], control: workload.restorationControl)
            &* UInt64(position + 1)
    }
    let elapsed = DispatchTime.now().uptimeNanoseconds - startWall
    let cpu = cpuNanoseconds() - startCPU
    guard checksum == expected else { throw Failure("Timed checksum mismatch in \(name)") }
    return Measurement(
        workload: name, restoration_control: workload.restorationControl,
        iterations: iterations, fixture_count: variantsPerWorkload, process_id: getpid(),
        elapsed_nanoseconds: elapsed, cpu_nanoseconds: cpu,
        cycle_checksum: String(cycleChecksum, radix: 16), checksum: String(checksum, radix: 16),
        expected_checksum: String(expected, radix: 16), fixtures: receipts
    )
}

private func emit<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(value)
    print(String(decoding: data, as: UTF8.self))
}

@main
private struct Driver {
    static func main() {
        do {
            let args = CommandLine.arguments
            if args.count == 2 && args[1] == "verify" {
                try emit(verify())
            } else if args.count == 2 && args[1] == "list" {
                try emit(workloadNames)
            } else if args.count == 4 && args[1] == "measure", let iterations = Int(args[3]) {
                try emit(measure(args[2], iterations: iterations))
            } else {
                throw Failure("Usage: benchmark verify | list | measure WORKLOAD ITERATIONS")
            }
        } catch {
            FileHandle.standardError.write(Data("Benchmark failed: \(error)\n".utf8))
            exit(1)
        }
    }
}
