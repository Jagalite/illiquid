// Benchmark-only adapter. The runner appends this file verbatim to the complete
// production SourceMediaPresenceScanner.swift, in both comparison builds. This
// grants access to private state without changing any production declaration or
// copying the invalidation, queue, scheduling, or observation implementation.

enum PresenceInvalidationOwnership: String {
    case unique
    // Source-browser projections and scan cursors can keep the public results
    // snapshot alive. Summaries and revision tables remain scanner-private.
    case shared
}

struct PresenceInvalidationFixture {
    var roots: [String]
    var results: [String: Bool]
    var summaries: [String: SourceMediaPresenceCursor.Summary]
    var completed: Set<String> = []
    var pending: [String] = []
    var directoryRevisions: [String: Int] = [:]
    var treeRevisions: [String: Int] = [:]
    var generation = 7
    var revision = 19
    var startedJobCount = 3
    var primesActiveJob = false
}

struct PresenceInvalidationState: Codable, Equatable {
    struct ResultEntry: Codable, Equatable {
        let path: String
        let value: Bool
    }
    struct SummaryEntry: Codable, Equatable {
        let path: String
        let hasDirectMedia: Bool
        let children: [String]
        let isComplete: Bool
        let isReadable: Bool
    }
    struct RevisionEntry: Codable, Equatable {
        let path: String
        let value: Int
    }

    let roots: [String]
    let results: [ResultEntry]
    let summaries: [SummaryEntry]
    let completed: [String]
    let pending: [String]
    let directoryRevisions: [RevisionEntry]
    let treeRevisions: [RevisionEntry]
    let generation: Int
    let revision: Int
    let startedJobCount: Int
    let isScanning: Bool
    let hasTask: Bool

    // Stable across processes/platforms and sensitive to original UTF-8 bytes,
    // including canonically equivalent key spellings. Full traces are compared
    // as JSON in verification; timing receipts consume every final state field.
    func receipt() -> UInt64 {
        var hash = PresenceInvalidationHash()
        hash.strings(roots)
        hash.integer(results.count)
        for entry in results { hash.string(entry.path); hash.boolean(entry.value) }
        hash.integer(summaries.count)
        for entry in summaries {
            hash.string(entry.path)
            hash.boolean(entry.hasDirectMedia)
            hash.strings(entry.children)
            hash.boolean(entry.isComplete)
            hash.boolean(entry.isReadable)
        }
        hash.strings(completed)
        hash.strings(pending)
        hash.integer(directoryRevisions.count)
        for entry in directoryRevisions { hash.string(entry.path); hash.integer(entry.value) }
        hash.integer(treeRevisions.count)
        for entry in treeRevisions { hash.string(entry.path); hash.integer(entry.value) }
        hash.integer(generation)
        hash.integer(revision)
        hash.integer(startedJobCount)
        hash.boolean(isScanning)
        hash.boolean(hasTask)
        return hash.value
    }
}

private struct PresenceInvalidationHash {
    var value: UInt64 = 14_695_981_039_346_656_037

    mutating func byte(_ value: UInt8) {
        self.value = (self.value ^ UInt64(value)) &* 1_099_511_628_211
    }
    mutating func integer(_ value: Int) {
        var bits = UInt64(bitPattern: Int64(value))
        for _ in 0..<8 { byte(UInt8(truncatingIfNeeded: bits)); bits >>= 8 }
    }
    mutating func boolean(_ value: Bool) { byte(value ? 1 : 0) }
    mutating func string(_ value: String) {
        integer(value.utf8.count)
        for element in value.utf8 { byte(element) }
    }
    mutating func strings(_ values: [String]) {
        integer(values.count)
        for value in values { string(value) }
    }
}

private func presenceInvalidationUTF8Order(_ lhs: String, _ rhs: String) -> Bool {
    lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
}

// Explicit insertion makes a new dictionary. In unique mode the fixture still
// owns its template but not the scanner's dictionary storage. Child sets remain
// shared immutable values; invalidate never mutates a summary's child set.
private func presenceInvalidationCopy<Value>(_ source: [String: Value]) -> [String: Value] {
    var result: [String: Value] = [:]
    result.reserveCapacity(source.count)
    for (key, value) in source { result[key] = value }
    return result
}

extension SourceMediaPresenceScanner {
    func invalidationBenchmarkEmptyTablesReleased() -> Bool {
        (!results.isEmpty || results.capacity == 0)
            && (!summaries.isEmpty || summaries.capacity == 0)
    }

    func invalidationBenchmarkStopAndWait() async {
        let worker = task
        let jobs = startedJobCount
        stop()
        // Stop before yielding. The real task sees the changed generation and
        // cancellation before entering its scan loop, so it cannot perform I/O.
        // Awaiting outside the timer prevents cancelled Task objects accumulating
        // across the calibration or measurement iterations.
        await worker?.value
        precondition(startedJobCount == jobs)
    }

    func invalidationBenchmarkObservation() -> UInt64 {
        var hash = PresenceInvalidationHash()
        hash.integer(results.count)
        hash.integer(summaries.count)
        hash.integer(pending.count)
        hash.integer(directoryRevisions.count)
        hash.integer(treeRevisions.count)
        hash.integer(revision)
        hash.integer(startedJobCount)
        hash.boolean(isScanning)
        hash.boolean(task != nil)
        return hash.value
    }

    func invalidationBenchmarkRestore(
        _ fixture: PresenceInvalidationFixture,
        ownership: PresenceInvalidationOwnership
    ) {
        // Reset outside the measured interval. Each previous task was cancelled
        // and awaited by invalidationBenchmarkStopAndWait before this restore.
        stop()
        roots = fixture.roots
        completed = fixture.completed
        pending = fixture.pending
        results = ownership == .unique ? presenceInvalidationCopy(fixture.results) : fixture.results
        summaries = presenceInvalidationCopy(fixture.summaries)
        directoryRevisions = presenceInvalidationCopy(fixture.directoryRevisions)
        treeRevisions = presenceInvalidationCopy(fixture.treeRevisions)
        generation = fixture.generation
        revision = fixture.revision
        startedJobCount = fixture.startedJobCount
        if fixture.primesActiveJob { start() }
    }

    func invalidationBenchmarkState() -> PresenceInvalidationState {
        let orderedResults = results.keys.sorted(by: presenceInvalidationUTF8Order)
        let orderedSummaries = summaries.keys.sorted(by: presenceInvalidationUTF8Order)
        let orderedDirectories = directoryRevisions.keys.sorted(by: presenceInvalidationUTF8Order)
        let orderedTrees = treeRevisions.keys.sorted(by: presenceInvalidationUTF8Order)
        return PresenceInvalidationState(
            roots: roots,
            results: orderedResults.map { .init(path: $0, value: results[$0]!) },
            summaries: orderedSummaries.map {
                let summary = summaries[$0]!
                return .init(path: $0, hasDirectMedia: summary.hasDirectMedia,
                             children: summary.children.sorted(by: presenceInvalidationUTF8Order),
                             isComplete: summary.isComplete, isReadable: summary.isReadable)
            },
            completed: completed.sorted(by: presenceInvalidationUTF8Order),
            pending: pending,
            directoryRevisions: orderedDirectories.map { .init(path: $0, value: directoryRevisions[$0]!) },
            treeRevisions: orderedTrees.map { .init(path: $0, value: treeRevisions[$0]!) },
            generation: generation, revision: revision,
            startedJobCount: startedJobCount, isScanning: isScanning, hasTask: task != nil)
    }
}
