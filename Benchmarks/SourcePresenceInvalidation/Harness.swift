import Foundation
import Observation
@testable import IlliquidApp
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

private struct Event: Encodable {
    var paths: Set<String> = []
    var trees: Set<String> = []
    var fullRoots: Set<String> = []

    private enum CodingKeys: String, CodingKey { case paths, trees, fullRoots }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        func sorted(_ values: Set<String>) -> [String] {
            values.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        }
        try container.encode(sorted(paths), forKey: .paths)
        try container.encode(sorted(trees), forKey: .trees)
        try container.encode(sorted(fullRoots), forKey: .fullRoots)
    }
}

private enum Kind: Sendable, Equatable {
    case empty, unwatched, directory, batch, burst, queuedBurst, ineffectiveTrees
    case tree, fullRoot, mixed, filesystemRoot, unicode, boundaries, queueCollapse, allResults, lexicalCorpus
}

private struct Workload: Sendable {
    let name: String
    let total: Int
    let kind: Kind

    static let timing: [Workload] = [
        .init(name: "empty", total: 0, kind: .empty),
        .init(name: "unwatched-10000", total: 10_000, kind: .unwatched),
        .init(name: "directory-32", total: 32, kind: .directory),
        .init(name: "directory-1000", total: 1_000, kind: .directory),
        .init(name: "directory-10000", total: 10_000, kind: .directory),
        .init(name: "directory-100000", total: 100_000, kind: .directory),
        .init(name: "batch-10000-64", total: 10_000, kind: .batch),
        .init(name: "burst-10000-16", total: 10_000, kind: .burst),
        .init(name: "queued-burst-10000-16", total: 10_000, kind: .queuedBurst),
        .init(name: "ineffective-trees-10000", total: 10_000, kind: .ineffectiveTrees),
        .init(name: "tree-10000", total: 10_000, kind: .tree),
        .init(name: "full-root-10000", total: 10_000, kind: .fullRoot),
        .init(name: "mixed-10000", total: 10_000, kind: .mixed),
        .init(name: "filesystem-root-1000", total: 1_000, kind: .filesystemRoot),
        .init(name: "unicode-1000", total: 1_000, kind: .unicode),
        .init(name: "all-results-1000", total: 1_000, kind: .allResults),
    ]
    static let verification: [Workload] = [
        .init(name: "empty", total: 0, kind: .empty),
        .init(name: "unwatched-1000", total: 1_000, kind: .unwatched),
        .init(name: "directory-32", total: 32, kind: .directory),
        .init(name: "batch-1000-64", total: 1_000, kind: .batch),
        .init(name: "burst-1000-16", total: 1_000, kind: .burst),
        .init(name: "queued-burst-1000-16", total: 1_000, kind: .queuedBurst),
        .init(name: "ineffective-trees-1000", total: 1_000, kind: .ineffectiveTrees),
        .init(name: "tree-1000", total: 1_000, kind: .tree),
        .init(name: "full-root-1000", total: 1_000, kind: .fullRoot),
        .init(name: "mixed-1000", total: 1_000, kind: .mixed),
        .init(name: "filesystem-root-32", total: 32, kind: .filesystemRoot),
        .init(name: "unicode-32", total: 32, kind: .unicode),
        .init(name: "boundary-sequence", total: 0, kind: .boundaries),
        .init(name: "queue-collapse", total: 256, kind: .queueCollapse),
        .init(name: "all-results-32", total: 32, kind: .allResults),
        .init(name: "lexical-corpus", total: 0, kind: .lexicalCorpus),
    ]
}

private struct Fixture {
    var state: PresenceInvalidationFixture
    let events: [Event]
}

private func joined(_ root: String, _ component: String) -> String {
    root == "/" ? root + component : root + "/" + component
}

private func makeBoundaryFixture(seed: UInt64) -> Fixture {
    let roots = ["/Media", "/Media2", "/École", "/動画"]
    let paths = roots + [
        "/Media/Café", "/Media/Cafe\u{301}/Épisode", "/Media/Cafe\u{301}/Other",
        "/Media/Café-neighbor", "/Media/percent%/hash#", "/Media/Slash/\u{301}Name",
        "/Media/./dot", "/Media//double", "/Media/../raw", "/Media2/Neighbor",
        "/École/épisode", "/動画/👩🏽‍💻", "/Media/Unchanged",
    ]
    var results: [String: Bool] = [:]
    var summaries: [String: SourceMediaPresenceCursor.Summary] = [:]
    for (index, path) in paths.enumerated() {
        let positive = (index + Int(seed % 2)).isMultiple(of: 2)
        results[path] = positive
        summaries[path] = .init(
            hasDirectMedia: positive,
            children: [path + "/Child", path + "/Cafe\u{301}"],
            isComplete: index % 3 != 0, isReadable: index % 5 != 0)
    }
    // Unknown state and a missing summary are deliberate parity controls.
    summaries["/Media/Unknown"] = .init(hasDirectMedia: false, children: [],
                                         isComplete: false, isReadable: false)
    summaries["/Media/Unchanged"] = nil
    var state = PresenceInvalidationFixture(roots: roots, results: results, summaries: summaries)
    state.completed = Set(roots)
    state.pending = ["/Media/Unchanged"]
    state.directoryRevisions = ["/Media/Unchanged": 11]
    state.treeRevisions = ["/École/épisode": 13]
    state.primesActiveJob = true
    let events: [Event] = [
        .init(),
        .init(paths: ["/Media-neighbor/NotWatched"], trees: ["/Elsewhere"], fullRoots: ["/Other"]),
        .init(paths: ["/Media/Cafe\u{301}"]),
        .init(paths: ["/Media/Slash/\u{301}Name"]),
        .init(paths: ["/Media/percent%/hash#"], trees: ["/Other"]),
        .init(paths: ["/Media/./dot", "/Media//double", "/Media/../raw"]),
        .init(paths: ["/Media"], trees: ["/Media/Cafe\u{301}"]),
        .init(fullRoots: ["/E\u{301}cole"]),
        .init(paths: ["/Media2/Neighbor", "/動画/👩🏽‍💻"]),
        .init(fullRoots: ["/Media"]),
    ]
    return Fixture(state: state, events: events)
}

private func makeFixture(_ workload: Workload, seed: UInt64) -> Fixture {
    if workload.kind == .boundaries { return makeBoundaryFixture(seed: seed) }
    if workload.kind == .empty {
        return Fixture(state: .init(roots: [], results: [:], summaries: [:]), events: [.init()])
    }
    let root = workload.kind == .filesystemRoot ? "/"
        : workload.kind == .unicode ? "/Médiathèque/動画" : "/library"
    let groupCount = min(32, max(1, (workload.total - 1) / 8))
    let leafCount = workload.total - groupCount - 1
    let groups = (0..<groupCount).map { index in
        joined(root, workload.kind == .unicode ? "Café-\(index)" : "Group-\(index)")
    }
    var leaves: [String] = []
    var children: [String: Set<String>] = [:]
    var results: [String: Bool] = [:]
    var summaries: [String: SourceMediaPresenceCursor.Summary] = [:]
    results.reserveCapacity(workload.total)
    summaries.reserveCapacity(workload.total)
    for index in 0..<leafCount {
        let group = groups[(index + Int(seed % UInt64(groupCount))) % groupCount]
        let name = workload.kind == .unicode ? "Épisode-\(index)-👩🏽‍💻" : "Folder-\(index)"
        let path = joined(group, name)
        leaves.append(path)
        children[group, default: []].insert(path)
        let positive = (index + Int(seed % 2)).isMultiple(of: 2)
        results[path] = positive
        summaries[path] = .init(hasDirectMedia: positive, children: [],
                               isComplete: !positive || index % 7 != 0,
                               isReadable: !positive || index % 11 != 0)
    }
    for group in groups {
        let members = children[group, default: []]
        results[group] = members.contains { results[$0] == true }
        summaries[group] = .init(hasDirectMedia: false, children: members,
                                isComplete: true, isReadable: true)
    }
    results[root] = groups.contains { results[$0] == true }
    summaries[root] = .init(hasDirectMedia: false, children: Set(groups),
                           isComplete: true, isReadable: true)
    precondition(results.count == workload.total && summaries.count == workload.total)
    var state = PresenceInvalidationFixture(roots: [root], results: results, summaries: summaries)
    state.completed = [root]
    state.directoryRevisions = [groups.last!: 3]
    state.treeRevisions = [joined(root, "PriorRemovedTree"): 5]
    let first = leaves[0]
    let events: [Event]
    switch workload.kind {
    case .empty, .boundaries, .lexicalCorpus: preconditionFailure("Handled separately")
    case .unwatched:
        events = [.init(paths: ["/library-neighbor/Folder"], trees: ["/Elsewhere"], fullRoots: ["/Other"])]
    case .directory, .filesystemRoot:
        events = [.init(paths: [first])]
    case .unicode:
        events = [.init(paths: [first.decomposedStringWithCanonicalMapping])]
    case .batch:
        events = [.init(paths: Set(leaves.prefix(64)))]
    case .burst, .queuedBurst:
        // Repeated events are intentionally separate invalidate calls. The
        // batched case above exercises one call with multiple changed paths.
        events = (0..<16).map { Event(paths: [leaves[$0 % 4]]) }
        if workload.kind == .queuedBurst {
            state.pending = [root]
            state.primesActiveJob = true
        }
    case .ineffectiveTrees:
        events = [.init(paths: [first], trees: ["/Elsewhere/Tree"], fullRoots: ["/AnotherRoot"])]
    case .tree:
        events = [.init(paths: [root], trees: [groups[0]])]
    case .fullRoot:
        events = [.init(fullRoots: [root])]
    case .mixed:
        let changed = leaves.first { !$0.hasPrefix(groups[0] + "/") }!
        events = [.init(paths: [root, changed], trees: [groups[0]])]
    case .queueCollapse:
        events = leaves.prefix(100).map { Event(paths: [$0]) }
    case .allResults:
        events = [.init(paths: Set(results.keys))]
    }
    return Fixture(state: state, events: events)
}

@MainActor @inline(never)
private func apply(_ events: [Event], to scanner: SourceMediaPresenceScanner) {
    for event in events {
        scanner.invalidate(paths: event.paths, trees: event.trees, fullRoots: event.fullRoots)
    }
}

private func cpuNanoseconds() -> UInt64 {
    var value = timespec()
    precondition(clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &value) == 0)
    return UInt64(value.tv_sec) * 1_000_000_000 + UInt64(value.tv_nsec)
}

private struct Verification: Encodable {
    let mode = "verify"
    let `case`: String
    let seed: UInt64
    let ownership: String
    let events: [Event]
    let stateTrace: [PresenceInvalidationState]
}

private struct Measurement: Encodable {
    let mode = "time"
    let `case`: String
    let seed: UInt64
    let ownership: String
    let iterations: Int
    let warmup: Int
    let operations: Int
    let eventCount: Int
    let inputResults: Int
    let inputSummaries: Int
    let wallNanoseconds: UInt64
    let cpuNanoseconds: UInt64
    let checksum: UInt64
    let finalStateReceipt: UInt64
}

private struct Cases: Encodable {
    let timingCases = Workload.timing.map(\.name)
    let verificationCases = Workload.verification.map(\.name)
    let ownerships = ["unique", "shared"]
}

private final class ChangeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

private struct CorpusCaseReceipt: Encodable {
    let path: String
    let initialStateReceipt: UInt64
    let firstStateReceipt: UInt64
    let repeatedStateReceipt: UInt64
    let stoppedStateReceipt: UInt64
    let resultEntriesCompared: Int
    let summaryEntriesCompared: Int
    let firstNotifications: Int
    let repeatedNotifications: Int
}

private struct CorpusVerification: Encodable {
    let mode = "verify"
    let `case` = "lexical-corpus"
    let seed: UInt64
    let ownership: String
    let alphabet: [String]
    let maximumScalars = 3
    let pathPrefix = "/Corpus/"
    let oracle = "Original directory-only filter predicate; exact UTF-8 result/summary keys and children"
    let cases: [CorpusCaseReceipt]
}

private func originalContains(_ path: String, in root: String) -> Bool {
    path == root || path.hasPrefix(root == "/" ? root : root + "/")
}

private func utf8Less(_ lhs: String, _ rhs: String) -> Bool {
    lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
}

// Compare every remaining result and summary field, including the exact original
// key/child spellings. Swift's String equality alone would hide NFC/NFD changes.
private func checkCorpusState(
    _ actual: PresenceInvalidationState,
    results: [String: Bool], summaries: [String: SourceMediaPresenceCursor.Summary]
) {
    let resultKeys = results.keys.sorted(by: utf8Less)
    precondition(actual.results.count == resultKeys.count)
    for (entry, key) in zip(actual.results, resultKeys) {
        precondition(entry.path.utf8.elementsEqual(key.utf8))
        precondition(entry.value == results[key]!)
    }
    let summaryKeys = summaries.keys.sorted(by: utf8Less)
    precondition(actual.summaries.count == summaryKeys.count)
    for (entry, key) in zip(actual.summaries, summaryKeys) {
        let expected = summaries[key]!
        precondition(entry.path.utf8.elementsEqual(key.utf8))
        precondition(entry.hasDirectMedia == expected.hasDirectMedia)
        precondition(entry.isComplete == expected.isComplete)
        precondition(entry.isReadable == expected.isReadable)
        let children = expected.children.sorted(by: utf8Less)
        precondition(entry.children.count == children.count)
        for (left, right) in zip(entry.children, children) {
            precondition(left.utf8.elementsEqual(right.utf8))
        }
    }
}

@MainActor
private func verifyLexicalCorpus(
    seed: UInt64, ownership: PresenceInvalidationOwnership
) async -> CorpusVerification {
    // 1 + 11 + 11² + 11³ = 1,464 inputs. Prefixing a watched root makes the
    // scanner exercise each interior separator, including slash+Extend/Prepend
    // grapheme combinations, instead of rejecting most inputs as unwatched.
    let alphabet = ["/", "a", "K", "\u{212A}", "\u{0301}", "\u{0600}", "\u{200D}",
                    "\u{FE0F}", ".", "\r", "\n"]
    var suffixes = [""]
    var level = [""]
    for _ in 1...3 {
        level = level.flatMap { prefix in alphabet.map { prefix + $0 } }
        suffixes.append(contentsOf: level)
    }
    precondition(suffixes.count == 1_464)
    var receipts: [CorpusCaseReceipt] = []
    receipts.reserveCapacity(suffixes.count)
    let scanner = SourceMediaPresenceScanner()
    defer { scanner.stop() }
    for (ordinal, suffix) in suffixes.enumerated() {
        let path = "/Corpus/" + suffix
        var possibleKeys = ["", "/", path, "/Unchanged/Kept"]
        let bytes = path.utf8
        for index in bytes.indices where bytes[index] == 0x2F {
            let prefix = String(decoding: bytes[..<index], as: UTF8.self)
            possibleKeys += [prefix, prefix + "extra", prefix + "/tail"]
        }
        possibleKeys += [path + "/child", path + "neighbor"]
        var results: [String: Bool] = [:]
        for (index, original) in possibleKeys.enumerated() {
            let stored: String
            switch (index + ordinal + Int(seed % 3)) % 3 {
            case 0: stored = original.precomposedStringWithCanonicalMapping
            case 1: stored = original.decomposedStringWithCanonicalMapping
            default: stored = original
            }
            results[stored] = (index + ordinal).isMultiple(of: 2)
        }
        var summaries: [String: SourceMediaPresenceCursor.Summary] = [:]
        for (index, key) in results.keys.sorted(by: utf8Less).enumerated() {
            summaries[key] = .init(
                hasDirectMedia: index.isMultiple(of: 2),
                children: [key + "/Café", key + "/Cafe\u{301}/child"],
                isComplete: index % 3 != 0, isReadable: index % 5 != 0)
        }
        var fixture = PresenceInvalidationFixture(roots: ["/"], results: results, summaries: summaries)
        fixture.completed = ["/"]
        fixture.directoryRevisions = ["/Unchanged/Kept": 11]
        fixture.treeRevisions = ["/Retired": 13]
        scanner.invalidationBenchmarkRestore(fixture, ownership: ownership)
        let initialReceipt = scanner.invalidationBenchmarkState().receipt()
        precondition(originalContains(path, in: "/"))
        // This is the original predicate, used only as an untimed test oracle.
        // Actual behavior always calls the complete production invalidate method.
        let expectedResults = results.filter { !originalContains(path, in: $0.key) }
        var expectedSummaries = summaries
        expectedSummaries[path] = nil

        let firstChanges = ChangeCounter()
        withObservationTracking { _ = scanner.results } onChange: { firstChanges.increment() }
        scanner.invalidate(paths: [path])
        let first = scanner.invalidationBenchmarkState()
        checkCorpusState(first, results: expectedResults, summaries: expectedSummaries)
        precondition(firstChanges.value == (expectedResults.count == results.count ? 0 : 1))

        let repeatChanges = ChangeCounter()
        withObservationTracking { _ = scanner.results } onChange: { repeatChanges.increment() }
        scanner.invalidate(paths: [path])
        let repeated = scanner.invalidationBenchmarkState()
        checkCorpusState(repeated, results: expectedResults, summaries: expectedSummaries)
        precondition(repeatChanges.value == 0)
        precondition(scanner.invalidationBenchmarkEmptyTablesReleased())
        await scanner.invalidationBenchmarkStopAndWait()
        receipts.append(.init(
            path: path, initialStateReceipt: initialReceipt,
            firstStateReceipt: first.receipt(), repeatedStateReceipt: repeated.receipt(),
            stoppedStateReceipt: scanner.invalidationBenchmarkState().receipt(),
            resultEntriesCompared: expectedResults.count * 2,
            summaryEntriesCompared: expectedSummaries.count * 2,
            firstNotifications: firstChanges.value, repeatedNotifications: repeatChanges.value))
    }
    return CorpusVerification(seed: seed, ownership: ownership.rawValue, alphabet: alphabet, cases: receipts)
}

private func emit<Value: Encodable>(_ value: Value) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    print(String(decoding: try encoder.encode(value), as: UTF8.self))
}

@main
struct SourcePresenceInvalidationBenchmark {
    @MainActor
    static func main() async throws {
        var options: [String: String] = [:]
        let arguments = Array(CommandLine.arguments.dropFirst())
        precondition(arguments.count.isMultiple(of: 2), "Expected --option value pairs")
        for index in stride(from: 0, to: arguments.count, by: 2) {
            precondition(options[arguments[index]] == nil, "Repeated option")
            options[arguments[index]] = arguments[index + 1]
        }
        let allowed: Set<String> = ["--mode", "--case", "--seed", "--ownership", "--iterations", "--warmup"]
        precondition(Set(options.keys).isSubset(of: allowed), "Unknown option")
        let mode = options["--mode"] ?? "verify"
        if mode == "cases" { try emit(Cases()); return }
        precondition(mode == "verify" || mode == "time", "Expected cases, verify, or time mode")
        guard let name = options["--case"],
              let workload = (Workload.timing + Workload.verification).first(where: { $0.name == name }),
              let seed = UInt64(options["--seed"] ?? "1"),
              let ownership = PresenceInvalidationOwnership(rawValue: options["--ownership"] ?? "unique")
        else { preconditionFailure("Expected a supported --case, --seed, and --ownership") }
        if workload.kind == .lexicalCorpus {
            precondition(mode == "verify", "The lexical corpus is an untimed correctness check")
            try emit(await verifyLexicalCorpus(seed: seed, ownership: ownership))
            return
        }
        let fixture = makeFixture(workload, seed: seed)
        let scanner = SourceMediaPresenceScanner()
        defer { scanner.stop() }

        if mode == "verify" {
            scanner.invalidationBenchmarkRestore(fixture.state, ownership: ownership)
            var trace = [scanner.invalidationBenchmarkState()]
            for event in fixture.events {
                scanner.invalidate(paths: event.paths, trees: event.trees, fullRoots: event.fullRoots)
                precondition(scanner.invalidationBenchmarkEmptyTablesReleased())
                trace.append(scanner.invalidationBenchmarkState())
            }
            await scanner.invalidationBenchmarkStopAndWait()
            trace.append(scanner.invalidationBenchmarkState())
            try emit(Verification(case: name, seed: seed, ownership: ownership.rawValue,
                                  events: fixture.events, stateTrace: trace))
            return
        }

        guard let iterations = Int(options["--iterations"] ?? "1"), iterations > 0,
              let warmup = Int(options["--warmup"] ?? "2"), warmup >= 0
        else { preconditionFailure("Positive --iterations and nonnegative --warmup required") }

        scanner.invalidationBenchmarkRestore(fixture.state, ownership: ownership)
        apply(fixture.events, to: scanner)
        precondition(scanner.invalidationBenchmarkEmptyTablesReleased())
        let expectedReceipt = scanner.invalidationBenchmarkState().receipt()
        let expectedObservation = scanner.invalidationBenchmarkObservation()
        await scanner.invalidationBenchmarkStopAndWait()
        for _ in 0..<warmup {
            scanner.invalidationBenchmarkRestore(fixture.state, ownership: ownership)
            apply(fixture.events, to: scanner)
            precondition(scanner.invalidationBenchmarkObservation() == expectedObservation)
            await scanner.invalidationBenchmarkStopAndWait()
        }

        var wall: UInt64 = 0
        var cpu: UInt64 = 0
        var checksum: UInt64 = 0
        var finalReceipt: UInt64 = 0
        for iteration in 0..<iterations {
            scanner.invalidationBenchmarkRestore(fixture.state, ownership: ownership)
            let startCPU = cpuNanoseconds()
            let startWall = DispatchTime.now().uptimeNanoseconds
            apply(fixture.events, to: scanner)
            wall &+= DispatchTime.now().uptimeNanoseconds - startWall
            cpu &+= cpuNanoseconds() - startCPU
            let observation = scanner.invalidationBenchmarkObservation()
            precondition(observation == expectedObservation)
            checksum &+= observation
            if iteration == iterations - 1 {
                precondition(scanner.invalidationBenchmarkEmptyTablesReleased())
                finalReceipt = scanner.invalidationBenchmarkState().receipt()
                precondition(finalReceipt == expectedReceipt)
            }
            await scanner.invalidationBenchmarkStopAndWait()
        }
        try emit(Measurement(
            case: name, seed: seed, ownership: ownership.rawValue, iterations: iterations, warmup: warmup,
            operations: iterations * fixture.events.count, eventCount: fixture.events.count,
            inputResults: fixture.state.results.count, inputSummaries: fixture.state.summaries.count,
            wallNanoseconds: wall, cpuNanoseconds: cpu, checksum: checksum, finalStateReceipt: finalReceipt))
    }
}
