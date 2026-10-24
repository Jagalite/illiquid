import CStartupHeap
import Dispatch
import Foundation
@testable import IlliquidApp
import IlliquidCore

private enum Scenario: String, CaseIterable {
    case unchanged
    case appendItem = "append-item"
    case removeHalf = "remove-half"
    case removeAll = "remove-all"
    case replaceVisibility = "replace-visibility"
}

/// A fixed-size, deterministic checksum. Set contents are combined without
/// sorting or creating another owner of a potentially large backing buffer.
private struct Digest {
    var value: UInt64 = 14_695_981_039_346_656_037

    mutating func byte(_ byte: UInt8) {
        value = (value ^ UInt64(byte)) &* 1_099_511_628_211
    }

    mutating func integer(_ number: UInt64) {
        for shift in stride(from: 0, to: 64, by: 8) {
            byte(UInt8(truncatingIfNeeded: number >> shift))
        }
    }

    mutating func string(_ string: String) {
        for byte in string.utf8 { self.byte(byte) }
        byte(255)
    }

    mutating func strings(_ strings: Set<String>) {
        var sum: UInt64 = 0
        var xor: UInt64 = 0
        for string in strings {
            var member = Digest()
            member.string(string)
            sum &+= member.value
            xor ^= member.value
        }
        integer(UInt64(strings.count))
        integer(sum)
        integer(xor)
    }
}

private struct Checks: Encodable, Equatable {
    var tab_count = 0
    var item_count = 0
    var hidden_path_count = 0
    var shown_path_count = 0
    var regex_rule_count = 0
    var checksum: UInt64 = 0
}

/// Only the source state adopted by AppModel is represented here. The real
/// SourceRootIndexStore, UI, preference caches, decoding and playback are not
/// part of this component measurement.
@MainActor
private final class ModelFixture {
    var tabs: [SourceTab]
    var selectedID: String?

    init(_ snapshot: SourceStartupSnapshot) {
        tabs = snapshot.tabs
        selectedID = snapshot.selectedID
    }

    @inline(never)
    func mutate(_ scenario: Scenario) {
        switch scenario {
        case .unchanged:
            break
        case .appendItem:
            if tabs.isEmpty {
                tabs.append(SourceTab(id: "new-tab", items: []))
            }
            // First nested array mutation after the startup handoff. This is
            // an ownership probe, not a timing of AppModel's full add-files UI.
            tabs[0].items.append(SourceTabItem(
                kind: .file,
                url: URL(fileURLWithPath: "/benchmark/library/added-after-startup.mkv")
            ))
        case .removeHalf:
            // Close the trailing half of restored tabs (rounding up). Their
            // item arrays and visibility settings should cease to be live.
            tabs.removeLast((tabs.count + 1) / 2)
        case .removeAll:
            tabs.removeAll(keepingCapacity: false)
        case .replaceVisibility:
            for index in tabs.indices { tabs[index].visibility = nil }
        }
        selectedID = SourceTabs.resolvedSelection(selectedID, in: tabs)
    }

    @inline(never)
    func checks() -> Checks {
        var result = Checks()
        var digest = Digest()
        result.tab_count = tabs.count
        digest.integer(UInt64(tabs.count))
        for tab in tabs {
            digest.string(tab.id)
            digest.integer(UInt64(tab.items.count))
            result.item_count += tab.items.count
            for item in tab.items {
                digest.string(item.kind.rawValue)
                digest.string(item.path)
            }
            if let visibility = tab.visibility {
                digest.byte(1)
                digest.string(visibility.viewMode.rawValue)
                digest.byte(visibility.showsHiddenItems ? 1 : 0)
                digest.strings(visibility.manuallyHiddenPaths)
                digest.strings(visibility.alwaysShownPaths)
                result.hidden_path_count += visibility.manuallyHiddenPaths.count
                result.shown_path_count += visibility.alwaysShownPaths.count
                result.regex_rule_count += visibility.regexRules.count
                digest.integer(UInt64(visibility.regexRules.count))
                for rule in visibility.regexRules {
                    digest.string(rule.id)
                    digest.string(rule.pattern)
                    digest.integer(UInt64(rule.colorIndex))
                    digest.byte(rule.isEnabled ? 1 : 0)
                }
            } else {
                digest.byte(0)
            }
        }
        if let selectedID {
            digest.byte(1)
            digest.string(selectedID)
        } else {
            digest.byte(0)
        }
        result.checksum = digest.value
        return result
    }
}

@inline(never)
private func makeSnapshotBody(count: Int) -> SourceStartupSnapshot {
    var tabs: [SourceTab] = []
    let tabCount = min(count, 4)
    for tabIndex in 0..<tabCount {
        let start = count * tabIndex / tabCount
        let end = count * (tabIndex + 1) / tabCount
        var items: [SourceTabItem] = []
        var hidden: Set<String> = []
        var shown: Set<String> = []
        items.reserveCapacity(end - start)
        for index in start..<end {
            let item = SourceTabItem(
                kind: .file,
                url: URL(fileURLWithPath:
                    "/benchmark/library/series-\(index / 24)/season-\(index / 12 % 2 + 1)/episode-\(index).mkv"
                )
            )
            items.append(item)
            if index.isMultiple(of: 8) { hidden.insert(item.path) }
            if index % 8 == 1 { shown.insert(item.path) }
        }
        tabs.append(SourceTab(
            id: "restored-tab-\(tabIndex)",
            items: items,
            visibility: SourceVisibilityConfiguration(
                viewMode: .filesOnly,
                showsHiddenItems: tabIndex.isMultiple(of: 2),
                manuallyHiddenPaths: hidden,
                alwaysShownPaths: shown,
                regexRules: [
                    SourceVisibilityRegexRule(
                        id: "restored-rule-\(tabIndex)",
                        pattern: "^bonus-\(tabIndex)-.*\\.mkv$",
                        colorIndex: tabIndex % SourceVisibilityRegexRule.colorCount,
                        isEnabled: true
                    ),
                ]
            )
        ))
    }
    // Exercise the production persistence restoration, but keep its temporary
    // seed arrays/data inside the read closure. UserDefaults is deliberately
    // absent: its own retained preference domain would hide the loader's role.
    guard let data = SourceTabStore.encode(tabs),
          let restored = SourceTabStore.restore(from: data)
    else { preconditionFailure("Synthetic source fixture failed to restore") }
    precondition(restored.reduce(0) { $0 + $1.items.count } == count)
    return SourceStartupSnapshot(
        tabs: restored,
        selectedID: SourceTabs.resolvedSelection(restored.last?.id, in: restored)
    )
}

@inline(never)
private func makeSnapshot(count: Int) -> SourceStartupSnapshot {
    // Temporary Foundation objects are drained before the read returns, rather
    // than remaining in the native process's ambient autorelease pool.
    #if canImport(ObjectiveC)
    return autoreleasepool { makeSnapshotBody(count: count) }
    #else
    return makeSnapshotBody(count: count)
    #endif
}

@MainActor
@inline(never)
private func adopt(
    _ loader: ReadOnlyStartupLoader<SourceStartupSnapshot>
) async -> ModelFixture {
    guard let snapshot = await loader.load() else {
        preconditionFailure("Startup read did not publish")
    }
    let model = ModelFixture(snapshot)
    #if !BASELINE
    loader.finish()
    #endif
    // This function boundary retires the snapshot local and the completed read
    // task's local handle before any measurement in the caller.
    return model
}

private struct CanonicalVisibility: Encodable {
    let viewMode: String
    let showsHiddenItems: Bool
    let manuallyHiddenPaths: [String]
    let alwaysShownPaths: [String]
    let regexRules: [SourceVisibilityRegexRule]

    init(_ visibility: SourceVisibilityConfiguration) {
        viewMode = visibility.viewMode.rawValue
        showsHiddenItems = visibility.showsHiddenItems
        manuallyHiddenPaths = visibility.manuallyHiddenPaths.sorted()
        alwaysShownPaths = visibility.alwaysShownPaths.sorted()
        regexRules = visibility.regexRules
    }
}

private struct CanonicalTab: Encodable {
    let id: String
    let items: [SourceTabItem]
    let visibility: CanonicalVisibility?

    init(_ tab: SourceTab) {
        id = tab.id
        items = tab.items
        visibility = tab.visibility.map(CanonicalVisibility.init)
    }
}

private struct CanonicalState: Encodable {
    let tabs: [CanonicalTab]
    let selectedID: String?

    enum CodingKeys: String, CodingKey { case tabs, selectedID }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(tabs, forKey: .tabs)
        // Encode nil explicitly so an empty state has a complete schema.
        try container.encode(selectedID, forKey: .selectedID)
    }
}

@MainActor
@inline(never)
private func writeActualStateBody(_ model: ModelFixture, to path: String) throws {
    let state = CanonicalState(
        tabs: model.tabs.map(CanonicalTab.init),
        selectedID: model.selectedID
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(state).write(to: URL(fileURLWithPath: path))
}

@MainActor
@inline(never)
private func writeActualState(_ model: ModelFixture, to path: String) throws {
    #if canImport(ObjectiveC)
    try autoreleasepool { try writeActualStateBody(model, to: path) }
    #else
    try writeActualStateBody(model, to: path)
    #endif
}

private struct Measurement: Encodable {
    let schema = 1
    let scope = "startup loader and adopted saved explicit source items; not whole AppModel or player RSS"
    let cleanup_scope = "diagnostic only; sampled after optional state serialization and its runtime caches"
    let scenario: String
    let saved_explicit_item_count: Int
    let state_output_written: Bool
    let allocator_metric: String
    let allocator_before_load_bytes: UInt64
    let allocator_after_handoff_bytes: UInt64
    let allocator_after_mutation_bytes: UInt64
    let allocator_after_model_release_bytes: UInt64
    let allocator_after_cleanup_bytes: UInt64
    let handoff_allocator_delta_bytes: Int64
    let retained_allocator_delta_bytes: Int64
    let model_release_allocator_delta_bytes: Int64
    let cleanup_allocator_delta_bytes: Int64
    let mutation_wall_nanoseconds: UInt64
    let mutation_cpu_nanoseconds: UInt64
    let checks: Checks
}

@MainActor
@inline(never)
private func warmUp() async throws {
    let loader = ReadOnlyStartupLoader { makeSnapshot(count: 8) }
    var model: ModelFixture? = await adopt(loader)
    model!.mutate(.appendItem)
    _ = model!.checks()
    // Warm encoder metadata without writing a file or retaining source data.
    let encoder = JSONEncoder()
    _ = try encoder.encode(CanonicalState(
        tabs: model!.tabs.map(CanonicalTab.init), selectedID: model!.selectedID
    ))
    model = nil
    loader.stop()
    _ = startup_heap_bytes()
    _ = startup_cpu_nanoseconds()
    _ = DispatchTime.now().uptimeNanoseconds
}

@MainActor
@inline(never)
private func measure(
    _ scenario: Scenario, count: Int, stateOutput: String?
) async throws -> Measurement {
    try await warmUp()
    await Task.yield()
    let metric = String(cString: startup_heap_metric())
    precondition(metric != "unsupported", "Live allocator metric unavailable")
    let before = startup_heap_bytes()
    // Capture a scalar only. Capturing prebuilt tabs would keep their storage
    // alive independently of the production loader and invalidate the result.
    var loader: ReadOnlyStartupLoader<SourceStartupSnapshot>? =
        ReadOnlyStartupLoader { makeSnapshot(count: count) }
    var model: ModelFixture? = await adopt(loader!)
    await Task.yield()
    let handoff = withExtendedLifetime((loader, model)) { startup_heap_bytes() }
    let wallStart = DispatchTime.now().uptimeNanoseconds
    let cpuStart = startup_cpu_nanoseconds()
    model!.mutate(scenario)
    let cpu = startup_cpu_nanoseconds() - cpuStart
    let wall = DispatchTime.now().uptimeNanoseconds - wallStart
    let retained = withExtendedLifetime((loader, model)) { startup_heap_bytes() }
    let checks = model!.checks()
    // Full byte parity observes the actual measured model, after the primary
    // heap/timing samples. The noinline helper drops projection/data temporaries
    // before model release; any encoder/allocator cache effects are diagnostic.
    if let stateOutput { try writeActualState(model!, to: stateOutput) }
    model = nil
    let modelReleased = withExtendedLifetime(loader) { startup_heap_bytes() }
    loader!.stop()
    loader = nil
    let cleaned = startup_heap_bytes()
    return Measurement(
        scenario: scenario.rawValue, saved_explicit_item_count: count,
        state_output_written: stateOutput != nil, allocator_metric: metric,
        allocator_before_load_bytes: before,
        allocator_after_handoff_bytes: handoff,
        allocator_after_mutation_bytes: retained,
        allocator_after_model_release_bytes: modelReleased,
        allocator_after_cleanup_bytes: cleaned,
        handoff_allocator_delta_bytes: Int64(handoff) - Int64(before),
        retained_allocator_delta_bytes: Int64(retained) - Int64(before),
        model_release_allocator_delta_bytes: Int64(modelReleased) - Int64(before),
        cleanup_allocator_delta_bytes: Int64(cleaned) - Int64(before),
        mutation_wall_nanoseconds: wall, mutation_cpu_nanoseconds: cpu,
        checks: checks
    )
}

@main
private enum StartupSnapshotBenchmark {
    @MainActor
    static func main() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard (2...3).contains(arguments.count),
              let scenario = Scenario(rawValue: arguments[0]),
              let count = Int(arguments[1]), (0...1_000_000).contains(count)
        else {
            throw NSError(domain: "StartupSnapshotBenchmark", code: 1, userInfo: [
                NSLocalizedDescriptionKey:
                    "Usage: StartupSnapshotBenchmark <\(Scenario.allCases.map(\.rawValue).joined(separator: "|"))> <saved-explicit-item-count:0...1000000> [state-output-path]",
            ])
        }
        let measurement = try await measure(
            scenario, count: count,
            stateOutput: arguments.count == 3 ? arguments[2] : nil
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(measurement)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([10]))
    }
}
