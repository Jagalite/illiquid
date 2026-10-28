import Foundation
import Darwin
import Observation
import CProbe

private enum ProbeError: Error, CustomStringConvertible {
    case failure(String)

    var description: String {
        switch self {
        case .failure(let message):
            return message
        }
    }
}

private final class ObservationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var marked = false

    func mark() {
        lock.lock()
        marked = true
        lock.unlock()
    }

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return marked
    }
}

/// Length-prefixed UTF-8 preserves exact spelling, including canonically
/// equivalent Unicode strings. Snapshot comparison does not rely on String ==.
private struct SnapshotBytes {
    var data = Data()

    mutating func integer(_ value: Int) {
        var encoded = UInt64(value).littleEndian
        withUnsafeBytes(of: &encoded) { data.append(contentsOf: $0) }
    }

    mutating func string(_ value: String) {
        integer(value.utf8.count)
        data.append(contentsOf: value.utf8)
    }

    mutating func urls(_ values: [URL]) {
        integer(values.count)
        for value in values {
            string(value.absoluteString)
        }
    }
}

@main
@MainActor
private struct SourceRootIndexProbe {
    private enum Workload: String {
        case visibility
        case remove
        case replaceLast
        case equalCopy
    }

    private static let root = "/source-root-index-benchmark"

    private static let usage = """
    Usage:
      Driver verify <true|false>
      Driver measure <visibility|remove|replaceLast|equalCopy> \
    <total_files> <tab_count> <iterations> [timing|heap]
    """

    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            guard let mode = arguments.first else {
                throw ProbeError.failure(usage)
            }

            switch mode {
            case "verify":
                guard arguments.count == 2,
                      arguments[1] == "true" || arguments[1] == "false"
                else {
                    throw ProbeError.failure(usage)
                }
                try await verify(expectsVisibilityReuse: arguments[1] == "true")

            case "measure":
                guard arguments.count == 5 || arguments.count == 6,
                      let workload = Workload(rawValue: arguments[1]),
                      let totalFiles = Int(arguments[2]),
                      let tabCount = Int(arguments[3]),
                      let iterations = Int(arguments[4]),
                      totalFiles >= 0,
                      tabCount > 0,
                      iterations > 0
                else {
                    throw ProbeError.failure(usage)
                }
                let cohort = arguments.count == 6 ? arguments[5] : "timing"
                guard cohort == "timing" || cohort == "heap" else {
                    throw ProbeError.failure(usage)
                }
                try await measure(
                    workload: workload,
                    totalFiles: totalFiles,
                    tabCount: tabCount,
                    iterations: iterations,
                    samplesHeap: cohort == "heap"
                )

            default:
                throw ProbeError.failure(usage)
            }
        } catch {
            let message = "Source-root index probe failed: \(error)\n"
            FileHandle.standardError.write(Data(message.utf8))
            exit(1)
        }
    }

    private static func require(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) throws {
        guard condition() else {
            throw ProbeError.failure(message)
        }
    }

    private static func emit(_ object: [String: Any]) throws {
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0a]))
    }

    private static func makeTabs(
        totalFiles: Int,
        tabCount: Int
    ) -> [SourceTab] {
        var tabs: [SourceTab] = []
        tabs.reserveCapacity(tabCount)

        var globalFile = 0
        for tab in 0..<tabCount {
            let count = totalFiles / tabCount
                + (tab < totalFiles % tabCount ? 1 : 0)
            var items: [SourceTabItem] = []
            items.reserveCapacity(count + 1)

            // Explicit folders and loose files exercise both derived root lists.
            items.append(SourceTabItem(
                kind: .folder,
                url: URL(
                    fileURLWithPath: "\(root)/tab-\(tab)/folder",
                    isDirectory: true
                )
            ))
            for _ in 0..<count {
                items.append(SourceTabItem(
                    kind: .file,
                    url: URL(
                        fileURLWithPath:
                            "\(root)/tab-\(tab)/loose/file-\(globalFile).mkv",
                        isDirectory: false
                    )
                ))
                globalFile += 1
            }
            tabs.append(SourceTab(id: "tab-\(tab)", items: items))
        }
        return tabs
    }

    /// Decode deliberately noncanonical stored paths without passing through the
    /// normalizing convenience initializer. Production restoration can encounter
    /// these value representations, and filesByPath retains the chosen item.
    private static func rawFile(_ path: String) throws -> SourceTabItem {
        let data = try JSONSerialization.data(
            withJSONObject: ["kind": "file", "path": path],
            options: [.sortedKeys]
        )
        return try JSONDecoder().decode(SourceTabItem.self, from: data)
    }

    private static func exactSnapshotBytes(
        _ snapshot: SourceRootIndex
    ) -> Data {
        var output = SnapshotBytes()
        output.string("source-root-index-snapshot-v1")
        output.urls(snapshot.folders)
        output.urls(snapshot.watchRoots)

        let tabIDs = snapshot.byTab.keys.sorted {
            $0.utf8.lexicographicallyPrecedes($1.utf8)
        }
        output.integer(tabIDs.count)
        for id in tabIDs {
            let roots = snapshot.byTab[id]!
            output.string(id)
            output.urls(roots.folders)
            output.urls(roots.watchRoots)

            let paths = roots.filesByPath.keys.sorted {
                $0.utf8.lexicographicallyPrecedes($1.utf8)
            }
            output.integer(paths.count)
            for path in paths {
                let item = roots.filesByPath[path]!
                output.string(path)
                output.string(item.kind.rawValue)
                output.string(item.path)
            }
        }
        return output.data
    }

    private static func checksum(_ data: Data) -> String {
        var value: UInt64 = 14_695_981_039_346_656_037
        for byte in data {
            value ^= UInt64(byte)
            value = value &* 1_099_511_628_211
        }
        return String(value, radix: 16)
    }

    /// A fresh full production index is the oracle for the asynchronous,
    /// optionally reused snapshot. Complete byte comparison is the assertion;
    /// the compact checksum is only a reproducible receipt.
    private static func verifySnapshot(
        _ owner: SourceRootIndexBenchmarkOwner,
        label: String
    ) throws -> [String: Any] {
        try require(owner.isReady, "\(label): snapshot is not ready")

        let actual = exactSnapshotBytes(owner.snapshot)
        let expected = exactSnapshotBytes(
            SourceRootIndex(tabs: owner.sourceTabs)
        )
        try require(
            actual == expected,
            "\(label): published snapshot differs from a fresh complete index"
        )

        let snapshot = owner.snapshot
        return [
            "case": label,
            "checksum_fnv1a64": checksum(actual),
            "canonical_bytes": actual.count,
            "indexed_tabs": snapshot.byTab.count,
            "indexed_files": snapshot.byTab.values.reduce(0) {
                $0 + $1.filesByPath.count
            },
            "folder_roots": snapshot.folders.count,
            "watch_roots": snapshot.watchRoots.count,
        ]
    }

    /// Each helper invocation ends before the caller awaits the index worker.
    /// Temporary copies therefore do not become accidental aliases held across
    /// subsequent iterations.
    @inline(never)
    private static func mutate(
        _ owner: SourceRootIndexBenchmarkOwner,
        workload: Workload,
        tab: Int,
        replacement: SourceTabItem?
    ) {
        switch workload {
        case .visibility:
            var configuration = owner.sourceTabs[tab].visibility ?? .default
            configuration.showsHiddenItems.toggle()
            owner.setVisibility(configuration, at: tab)

        case .remove:
            // Exercise the real nested in-place mutation, including any
            // copy-on-write cost introduced by observing oldValue.
            owner.removeLastItem(at: tab)

        case .replaceLast:
            var items = owner.sourceTabs[tab].items
            items[items.count - 1] = replacement!
            owner.setItems(items, at: tab)

        case .equalCopy:
            // reserve + append into an empty array guarantees fresh nonempty
            // storage while the old source is still alive.
            let source = owner.sourceTabs[tab].items
            var copy: [SourceTabItem] = []
            copy.reserveCapacity(source.count)
            copy.append(contentsOf: source)
            owner.setItems(copy, at: tab)
        }
    }

    private static func verify(
        expectsVisibilityReuse: Bool
    ) async throws {
        var receipts: [[String: Any]] = []

        // No await occurs between initialization and this edit. The inherited
        // MainActor build task cannot have begun its actor-isolated body yet.
        let owner = SourceRootIndexBenchmarkOwner(
            tabs: makeTabs(totalFiles: 24, tabCount: 3)
        )
        try require(!owner.isReady, "initial index unexpectedly ready")
        var configuration = SourceVisibilityConfiguration.default
        configuration.showsHiddenItems = true
        owner.setVisibility(configuration, at: 0)
        try require(
            !owner.isReady,
            "initial visibility edit published an unbuilt index"
        )
        await owner.waitUntilReady()
        receipts.append(try verifySnapshot(
            owner,
            label: "initial_in_flight_visibility"
        ))

        // Skipping derived-index work must not suppress sourceTabs observation.
        let observation = ObservationFlag()
        withObservationTracking {
            _ = owner.sourceTabs[0].visibility?.showsHiddenItems
        } onChange: {
            observation.mark()
        }
        mutate(owner, workload: .visibility, tab: 0, replacement: nil)
        try require(
            observation.value,
            "visibility edit did not deliver Observation onChange"
        )
        try require(
            owner.isReady == expectsVisibilityReuse,
            "ready visibility edit had unexpected invalidation behavior"
        )
        await owner.waitUntilReady()
        receipts.append(try verifySnapshot(
            owner,
            label: "ready_visibility_and_observation"
        ))

        // Nonempty equal values in fresh storage must conservatively rebuild.
        mutate(owner, workload: .equalCopy, tab: 1, replacement: nil)
        try require(!owner.isReady, "independent equal array reused unexpectedly")
        await owner.waitUntilReady()
        receipts.append(try verifySnapshot(
            owner,
            label: "independent_equal_items"
        ))

        mutate(owner, workload: .remove, tab: 2, replacement: nil)
        try require(!owner.isReady, "item removal did not invalidate")
        await owner.waitUntilReady()
        receipts.append(try verifySnapshot(owner, label: "item_removal"))

        let replacement = SourceTabItem(
            kind: .file,
            url: URL(fileURLWithPath: "\(root)/changed-parent/replacement.mkv")
        )
        mutate(
            owner,
            workload: .replaceLast,
            tab: 0,
            replacement: replacement
        )
        try require(!owner.isReady, "item replacement did not invalidate")
        await owner.waitUntilReady()
        receipts.append(try verifySnapshot(owner, label: "path_replacement"))

        do {
            var items = owner.sourceTabs[0].items
            items[0] = SourceTabItem(
                kind: .file,
                url: URL(fileURLWithPath: "\(root)/changed-kind.mkv")
            )
            owner.setItems(items, at: 0)
        }
        try require(!owner.isReady, "item kind change did not invalidate")
        await owner.waitUntilReady()
        receipts.append(try verifySnapshot(owner, label: "kind_replacement"))

        do {
            let items = Array(owner.sourceTabs[1].items.reversed())
            owner.setItems(items, at: 1)
        }
        try require(!owner.isReady, "item reorder did not invalidate")
        await owner.waitUntilReady()
        receipts.append(try verifySnapshot(owner, label: "item_reorder"))

        owner.replaceTabs(Array(owner.sourceTabs.reversed()))
        try require(!owner.isReady, "tab reorder did not invalidate")
        await owner.waitUntilReady()
        receipts.append(try verifySnapshot(owner, label: "tab_reorder"))

        // A changed-and-reverted sequence must supersede the intervening build.
        // Both mutations occur synchronously before yielding the MainActor.
        do {
            let original = owner.sourceTabs
            var changed = original
            changed.append(SourceTab(
                id: "temporary",
                items: [SourceTabItem(
                    kind: .folder,
                    url: URL(
                        fileURLWithPath: "\(root)/temporary",
                        isDirectory: true
                    )
                )]
            ))
            owner.replaceTabs(changed)
            try require(!owner.isReady, "added tab did not invalidate")
            owner.replaceTabs(original)
            try require(
                !owner.isReady,
                "revert incorrectly reused an unrelated in-flight snapshot"
            )
        }
        await owner.waitUntilReady()
        receipts.append(try verifySnapshot(
            owner,
            label: "changed_then_reverted_before_yield"
        ))

        // Two empty arrays need no pointer identity; their contents agree.
        let empty = SourceRootIndexBenchmarkOwner(tabs: [
            SourceTab(id: "empty-a", items: []),
            SourceTab(id: "empty-b", items: []),
        ])
        await empty.waitUntilReady()
        mutate(empty, workload: .visibility, tab: 1, replacement: nil)
        try require(
            empty.isReady == expectsVisibilityReuse,
            "empty visibility edit had unexpected invalidation behavior"
        )
        await empty.waitUntilReady()
        receipts.append(try verifySnapshot(empty, label: "empty_items_visibility"))

        empty.setItems([replacement], at: 0)
        try require(!empty.isReady, "empty-to-nonempty change did not invalidate")
        await empty.waitUntilReady()
        receipts.append(try verifySnapshot(empty, label: "empty_to_nonempty"))

        empty.setItems([], at: 0)
        try require(!empty.isReady, "nonempty-to-empty change did not invalidate")
        await empty.waitUntilReady()
        receipts.append(try verifySnapshot(empty, label: "nonempty_to_empty"))

        // String == considers these IDs equal; exact UTF-8 spelling still
        // changes the dictionary key representation in a newly built index.
        let composedID = "caf\u{00e9}"
        let decomposedID = "cafe\u{0301}"
        try require(
            composedID == decomposedID
                && !composedID.utf8.elementsEqual(decomposedID.utf8),
            "Unicode ID fixture does not distinguish representation"
        )
        let unicodeIDOwner = SourceRootIndexBenchmarkOwner(tabs: [
            SourceTab(id: composedID, items: [replacement]),
        ])
        await unicodeIDOwner.waitUntilReady()
        do {
            let sharedItems = unicodeIDOwner.sourceTabs[0].items
            unicodeIDOwner.replaceTabs([
                SourceTab(id: decomposedID, items: sharedItems),
            ])
        }
        try require(
            !unicodeIDOwner.isReady,
            "byte-different tab ID did not invalidate"
        )
        await unicodeIDOwner.waitUntilReady()
        try require(
            unicodeIDOwner.snapshot.byTab.keys.first?.utf8
                .elementsEqual(decomposedID.utf8) == true,
            "published tab ID did not retain replacement UTF-8 spelling"
        )
        receipts.append(try verifySnapshot(
            unicodeIDOwner,
            label: "unicode_id_bytes"
        ))

        let composedPath = "\(root)/caf\u{00e9}.mkv"
        let decomposedPath = "\(root)/cafe\u{0301}.mkv"
        let unicodePathOwner = SourceRootIndexBenchmarkOwner(tabs: [
            SourceTab(id: "unicode-path", items: [
                try rawFile(composedPath),
            ]),
        ])
        await unicodePathOwner.waitUntilReady()
        unicodePathOwner.setItems([try rawFile(decomposedPath)], at: 0)
        try require(
            !unicodePathOwner.isReady,
            "byte-different stored path did not invalidate"
        )
        await unicodePathOwner.waitUntilReady()
        try require(
            unicodePathOwner.snapshot.byTab["unicode-path"]?
                .filesByPath.values.first?.path.utf8
                .elementsEqual(decomposedPath.utf8) == true,
            "published file item lost replacement UTF-8 spelling"
        )
        receipts.append(try verifySnapshot(
            unicodePathOwner,
            label: "unicode_item_bytes"
        ))

        // Equal normalized file keys retain the first SourceTabItem. Reordering
        // must change that selected raw value even if roots stay equivalent.
        let first = try rawFile("\(root)/alias/../selected.mkv")
        let second = try rawFile("\(root)/selected.mkv")
        let selected = SourceRootIndexBenchmarkOwner(tabs: [
            SourceTab(id: "selection", items: [first, second]),
        ])
        await selected.waitUntilReady()
        try require(
            selected.snapshot.byTab["selection"]?.filesByPath.count == 1,
            "duplicate normalized-path fixture did not collapse to one key"
        )
        try require(
            selected.snapshot.byTab["selection"]?
                .filesByPath.values.first?.path.utf8
                .elementsEqual(first.path.utf8) == true,
            "initial duplicate-key selection was not the first raw item"
        )
        selected.setItems([second, first], at: 0)
        try require(!selected.isReady, "duplicate-key reorder did not invalidate")
        await selected.waitUntilReady()
        try require(
            selected.snapshot.byTab["selection"]?
                .filesByPath.values.first?.path.utf8
                .elementsEqual(second.path.utf8) == true,
            "duplicate-key reorder did not update the selected raw item"
        )
        receipts.append(try verifySnapshot(
            selected,
            label: "duplicate_normalized_path_selection"
        ))

        try emit([
            "kind": "verification",
            "expects_visibility_reuse": expectsVisibilityReuse,
            "observation_delivered": observation.value,
            "checks": receipts.count,
            "receipts": receipts,
        ])
    }

    private static func measure(
        workload: Workload,
        totalFiles: Int,
        tabCount: Int,
        iterations: Int,
        samplesHeap: Bool
    ) async throws {
        if workload == .remove {
            // Round-robin removals match the fixture's quotient/remainder
            // distribution, so this keeps every removal on a file.
            try require(
                totalFiles >= iterations,
                "remove requires total_files >= iterations"
            )
        }
        if workload == .replaceLast {
            try require(
                totalFiles >= tabCount,
                "replaceLast requires at least one file per tab"
            )
        }

        // No local fixture array survives initialization. Keeping one here
        // would introduce an artificial shared owner into mutation controls.
        let owner = SourceRootIndexBenchmarkOwner(
            tabs: makeTabs(totalFiles: totalFiles, tabCount: tabCount)
        )
        await owner.waitUntilReady()
        try require(owner.isReady, "initial measurement index did not publish")

        // Construct URL/String values before timing. The actual array copy and
        // setter remain inside the replacement workload.
        let replacements: [SourceTabItem]
        if workload == .replaceLast {
            replacements = (0..<iterations).map { iteration in
                SourceTabItem(
                    kind: .file,
                    url: URL(
                        fileURLWithPath:
                            "\(root)/tab-\(iteration % tabCount)"
                            + "/replacement-\(iteration).mkv",
                        isDirectory: false
                    )
                )
            }
        } else {
            replacements = []
        }

        // Initialize clocks/probes before the timed section.
        _ = DispatchTime.now().uptimeNanoseconds
        _ = probe_cpu_ns()
        let heapBefore = UInt64(probe_heap_in_use())

        if samplesHeap {
            try require(
                probe_start_sampling() == 0,
                "could not start sampled heap cohort"
            )
        }

        var mutationNanoseconds: UInt64 = 0
        var readinessInvalidations = 0
        let cpuStart = UInt64(probe_cpu_ns())
        let wallStart = DispatchTime.now().uptimeNanoseconds

        for iteration in 0..<iterations {
            let mutationStart = DispatchTime.now().uptimeNanoseconds
            mutate(
                owner,
                workload: workload,
                tab: iteration % tabCount,
                replacement:
                    workload == .replaceLast ? replacements[iteration] : nil
            )
            mutationNanoseconds +=
                DispatchTime.now().uptimeNanoseconds - mutationStart

            if !owner.isReady {
                readinessInvalidations += 1
            }
            await owner.waitUntilReady()
        }

        let wallNanoseconds =
            DispatchTime.now().uptimeNanoseconds - wallStart
        let cpuNanoseconds = UInt64(probe_cpu_ns()) - cpuStart

        if samplesHeap {
            probe_stop_sampling()
        }
        let sampledPeak = samplesHeap
            ? UInt64(probe_sampled_peak_in_use()) : 0
        let heapAfter = UInt64(probe_heap_in_use())
        let peakRSS = UInt64(probe_peak_rss_bytes())

        // Full validation and deterministic checksum occur after timing and
        // after heap sampling. No cached snapshot was retained across edits.
        let snapshotReceipt = try verifySnapshot(owner, label: "final_snapshot")
        let finalInputFileCount = owner.sourceTabs.reduce(0) { total, tab in
            total + tab.items.reduce(0) {
                $0 + ($1.kind == .file ? 1 : 0)
            }
        }

        try emit([
            "kind": "measurement",
            "workload": workload.rawValue,
            "total_files": totalFiles,
            "tab_count": tabCount,
            "iterations": iterations,
            "allocation_sampled": samplesHeap,
            "wall_ns": wallNanoseconds,
            "wall_ns_per_op": Double(wallNanoseconds) / Double(iterations),
            "cpu_ns": cpuNanoseconds,
            "cpu_ns_per_op": Double(cpuNanoseconds) / Double(iterations),
            "synchronous_mutation_ns": mutationNanoseconds,
            "synchronous_mutation_ns_per_op":
                Double(mutationNanoseconds) / Double(iterations),
            "readiness_invalidations": readinessInvalidations,
            "heap_before_bytes": heapBefore,
            "heap_after_bytes": heapAfter,
            "sampled_peak_heap_bytes": sampledPeak,
            "peak_rss_bytes": peakRSS,
            "final_input_files": finalInputFileCount,
            "snapshot": snapshotReceipt,
        ])
    }
}
