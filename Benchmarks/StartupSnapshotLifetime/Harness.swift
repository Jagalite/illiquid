import CLeaseHeap
import Foundation

// Component-only stand-ins for the native graph. The generated AppModel file
// contains the exact production static startup methods, with this instance
// storage replacing windowing, playback, source-index and observation work.
final class PlaybackPersistenceStore: Sendable {
    init(userDefaults: UserDefaults = .standard) {}
}

// Support the isolated-preferences/session-store wiring added by PR #91.
// These stand-ins perform no preferences or filesystem writes.
enum AppPreferences {
    static var defaults: UserDefaults { .standard }
    static var sessionFileURL: URL? { nil }
}

final class AtomicPlaybackSessionStore: Sendable {
    init(fileURL: URL?) {}
}

@MainActor
final class PlaybackController {
    let persistence: PlaybackPersistenceStore
    let shutdownPersistenceError: String? = nil

    init(persistence: PlaybackPersistenceStore,
         sessionStore: AtomicPlaybackSessionStore? = nil,
         thumbnailCacheDirectory: URL? = nil) {
        self.persistence = persistence
    }
}

enum LifecyclePerformance {
    static let isEnabled = false
    static func begin(_ name: String) -> UInt64 { 0 }
    static func end(_ name: String, since: UInt64) {}
}

/// Records fixture reads without retaining any resulting source snapshot.
final class FixtureControl: @unchecked Sendable {
    static let shared = FixtureControl()
    private let lock = NSLock()
    private var calls = 0

    var readCalls: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func recordRead() {
        lock.lock()
        defer { lock.unlock() }
        calls += 1
    }
}

/// Deliberately replaces UserDefaults decoding with deterministic in-memory
/// input. SourceTab, SourceTabItem, visibility types and URL normalization are
/// copied unchanged from production. The fixture retains no resulting snapshot.
struct SourceStartupSnapshot: Sendable {
    let tabs: [SourceTab]
    let selectedID: String?

    static func load(defaults: UserDefaults) -> Self {
        FixtureControl.shared.recordRead()
        let count = Int(CommandLine.arguments[1])!
        var items: [SourceTabItem] = []
        items.reserveCapacity(count)
        for index in 0..<count {
            items.append(SourceTabItem(kind: .file, url: URL(fileURLWithPath: path(index))))
        }
        return Self(tabs: [SourceTab(id: "fixture-source-tab", items: items)],
                    selectedID: "fixture-source-tab")
    }

    static func path(_ index: Int) -> String {
        "/Volumes/Research Library/Collected Series/Season 04/Long descriptive episode title number \(index)-1080p.mkv"
    }
}

struct Observation: Codable {
    let sourceCount: Int
    let sourcePathUTF8Bytes: Int
    let sourceItemStride: Int
    let beforeEditDigest: String
    let afterEditDigest: String
    let readCalls: Int
    let modelInitializations: Int
    let startupOpenDeliveries: Int
    let lateCallerUsesSharedModel: Bool
    let loadAfterShutdownIsNil: Bool
    let outerBufferReusedForFirstEdit: Bool
    let itemsBufferReusedForFirstEdit: Bool
    let allocatorMetric: String
    let allocatorBeforeFixture: UInt64
    let allocatorAfterPublication: UInt64
    let allocatorAfterFirstEdit: UInt64
    let allocatorAfterSourceRemoval: UInt64
    let allocatorAfterShutdown: UInt64
}

@main
struct Harness {
    @MainActor
    static func main() async {
        guard CommandLine.arguments.count == 2,
              let count = Int(CommandLine.arguments[1]), count > 0 else {
            fatalError("usage: StartupSnapshotLifetime POSITIVE_SOURCE_COUNT")
        }
        let metric = String(cString: lease_history_allocator_metric())
        precondition(metric != "unsupported", "allocator probe unavailable")

        // Warm shared Foundation/runtime primitives before the process baseline.
        _ = UserDefaults.standard
        _ = SourceTabItem(kind: .file, url: URL(fileURLWithPath: SourceStartupSnapshot.path(-1)))
        let replacement = SourceTabItem(kind: .file,
            url: URL(fileURLWithPath: "/Volumes/Research Library/Replacement source.mkv"))
        let heapBefore = lease_history_allocator_bytes()

        let model = await loadAndVerifySharedModel()
        precondition(model.sourceTabs.count == 1 && model.sourceTabs[0].items.count == count)
        let before = verifyAndDigest(model, sourceCount: count, replacement: nil)
        let originalOuter = outerBufferAddress(model)
        let originalItems = itemsBufferAddress(model)
        let heapPublished = lease_history_allocator_bytes()

        replaceFirstItem(model, with: replacement)
        let sameOuter = originalOuter == outerBufferAddress(model)
        let sameItems = originalItems == itemsBufferAddress(model)
        let heapEdited = lease_history_allocator_bytes()
        let after = verifyAndDigest(model, sourceCount: count, replacement: replacement)

        removeSources(model)
        precondition(model.sourceTabs.isEmpty)
        let heapRemoved = lease_history_allocator_bytes()
        let shutdownError = await AppModel.shutdownShared()
        precondition(shutdownError == nil)
        let afterShutdown = await AppModel.loadShared()
        precondition(afterShutdown == nil)
        let heapStopped = lease_history_allocator_bytes()

        let observation = Observation(
            sourceCount: count, sourcePathUTF8Bytes: before.bytes,
            sourceItemStride: MemoryLayout<SourceTabItem>.stride,
            beforeEditDigest: String(before.hash), afterEditDigest: String(after.hash),
            readCalls: FixtureControl.shared.readCalls,
            modelInitializations: AppModel.modelInitializations,
            startupOpenDeliveries: model.startupOpenDeliveries,
            lateCallerUsesSharedModel: true,
            loadAfterShutdownIsNil: afterShutdown == nil,
            outerBufferReusedForFirstEdit: sameOuter,
            itemsBufferReusedForFirstEdit: sameItems,
            allocatorMetric: metric,
            allocatorBeforeFixture: heapBefore, allocatorAfterPublication: heapPublished,
            allocatorAfterFirstEdit: heapEdited, allocatorAfterSourceRemoval: heapRemoved,
            allocatorAfterShutdown: heapStopped
        )
        // JSON allocation/encoding follows all measured intervals and heap samples.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try! encoder.encode(observation)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([10]))
    }

    @MainActor
    @inline(never)
    static func loadAndVerifySharedModel() async -> AppModel {
        AppModel.handleStartupOpenURLs([URL(fileURLWithPath: "/tmp/startup-one.mkv")])
        AppModel.handleStartupOpenURLs([URL(fileURLWithPath: "/tmp/startup-two.mkv")])
        let first = await AppModel.loadShared()!
        let later = await AppModel.loadShared()
        precondition(later === first)
        precondition(FixtureControl.shared.readCalls == 1)
        precondition(AppModel.modelInitializations == 1)
        precondition(first.startupOpenDeliveries == 2)
        return first
        // No driver-owned Task or snapshot retains the original startup data.
    }

    @MainActor
    @inline(never)
    static func outerBufferAddress(_ model: AppModel) -> UInt {
        model.sourceTabs.withUnsafeBufferPointer { UInt(bitPattern: $0.baseAddress!) }
    }

    @MainActor
    @inline(never)
    static func itemsBufferAddress(_ model: AppModel) -> UInt {
        model.sourceTabs[0].items.withUnsafeBufferPointer { UInt(bitPattern: $0.baseAddress!) }
    }

    @MainActor
    @inline(never)
    static func replaceFirstItem(_ model: AppModel, with replacement: SourceTabItem) {
        model.sourceTabs[0].items[0] = replacement
    }

    @MainActor
    @inline(never)
    static func removeSources(_ model: AppModel) {
        model.sourceTabs.removeAll()
    }

    @MainActor
    @inline(never)
    static func verifyAndDigest(
        _ model: AppModel, sourceCount: Int, replacement: SourceTabItem?
    ) -> (hash: UInt64, bytes: Int) {
        precondition(model.sourceTabs[0].id == "fixture-source-tab")
        precondition(model.sourceTabs[0].visibility == nil)
        precondition(model.sourceTabs[0].items.count == sourceCount)
        var hash: UInt64 = 14_695_981_039_346_656_037
        var bytes = 0
        for (index, item) in model.sourceTabs[0].items.enumerated() {
            let expected = index == 0 ? replacement?.path ?? SourceStartupSnapshot.path(index)
                                      : SourceStartupSnapshot.path(index)
            precondition(item.kind == .file && item.path == expected)
            for byte in item.path.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
            hash = (hash ^ 0) &* 1_099_511_628_211
            bytes += item.path.utf8.count
        }
        return (hash, bytes)
    }
}
