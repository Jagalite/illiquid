import CStartupMemory
import Darwin
import Foundation
@testable import IlliquidApp

private struct Memory: Codable {
    let liveMallocBytes: UInt64
    let residentBytes: UInt64
    let physicalFootprintBytes: UInt64
    let peakResidentBytes: UInt64

    init() throws {
        var value = StartupMemorySnapshot()
        guard startup_memory_snapshot(&value) == 0 else { throw ProbeError("Memory sample failed") }
        liveMallocBytes = value.live_malloc_bytes
        residentBytes = value.resident_bytes
        physicalFootprintBytes = value.physical_footprint_bytes
        peakResidentBytes = value.peak_resident_bytes
    }
}

private struct ProbeError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

private func cpuSeconds() throws -> Double {
    var value = rusage()
    guard getrusage(RUSAGE_SELF, &value) == 0 else { throw ProbeError("getrusage failed") }
    return Double(value.ru_utime.tv_sec + value.ru_stime.tv_sec)
        + Double(value.ru_utime.tv_usec + value.ru_stime.tv_usec) / 1_000_000
}

private func elapsed(_ start: UInt64) -> Double {
    Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
}

private struct SourceReceipt: Codable, Equatable {
    let tabs: Int
    let items: Int
    let pathUTF8Bytes: Int
    let orderedPathChecksum: String
    let selectedID: String?

    private enum CodingKeys: String, CodingKey {
        case tabs, items, pathUTF8Bytes, orderedPathChecksum, selectedID
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(tabs, forKey: .tabs)
        try values.encode(items, forKey: .items)
        try values.encode(pathUTF8Bytes, forKey: .pathUTF8Bytes)
        try values.encode(orderedPathChecksum, forKey: .orderedPathChecksum)
        if let selectedID {
            try values.encode(selectedID, forKey: .selectedID)
        } else {
            try values.encodeNil(forKey: .selectedID)
        }
    }
}

// This returns only scalars and the short tab ID, never an array/string view
// into the loaded item storage. It is outside all measured timed regions.
@MainActor
@inline(never)
private func receipt(_ model: AppModel) -> SourceReceipt {
    var items = 0
    var bytes = 0
    var hash: UInt64 = 14_695_981_039_346_656_037
    for tab in model.sourceTabs {
        for item in tab.items {
            items += 1
            for byte in item.path.utf8 {
                bytes += 1
                hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211
            }
            hash = hash &* 1_099_511_628_211 // unambiguous zero separator
        }
    }
    return SourceReceipt(tabs: model.sourceTabs.count, items: items,
                         pathUTF8Bytes: bytes, orderedPathChecksum: String(hash, radix: 16),
                         selectedID: model.activeSourceTabID)
}

private struct Observation: Codable {
    let itemCount: Int
    let mode: String
    let before: Memory
    let published: Memory
    let afterAction: Memory
    let afterDiagnosticStop: Memory
    let sourceBeforeAction: SourceReceipt
    let sourceAfterAction: SourceReceipt
    let sourceAfterDiagnosticStop: SourceReceipt
    let sourceReadCount: Int
    let sharedIdentityPreserved: Bool
    let loadWallSeconds: Double
    let loadCPUSeconds: Double
    let actionWallSeconds: Double
    let actionCPUSeconds: Double
    let diagnosticStopWallSeconds: Double
    let diagnosticStopCPUSeconds: Double
}

@main
private enum StartupSourceLifetimeProbe {
    @MainActor
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count == 3, let count = Int(args[1]), [0, 100, 10_000, 100_000].contains(count),
              ["close", "unchanged"].contains(args[2]) else {
            throw ProbeError("Usage: probe 0|100|10000|100000 close|unchanged")
        }
        _ = try Memory()
        let before = try Memory()
        let loadCPUStart = try cpuSeconds()
        let loadStart = DispatchTime.now().uptimeNanoseconds
        guard let model = await AppModel.loadShared() else { throw ProbeError("No published model") }
        let loadWall = elapsed(loadStart)
        let loadCPU = try cpuSeconds() - loadCPUStart
        // Exit the publication async frame before sampling retained ownership.
        await Task.yield()
        let published = try withExtendedLifetime(model) { try Memory() }
        let original = receipt(model)
        guard original.items == count, original.tabs == 1,
              original.selectedID == SourceFixture.tabID else { throw ProbeError("Incorrect restored sources") }

        let actionCPUStart = try cpuSeconds()
        let actionStart = DispatchTime.now().uptimeNanoseconds
        if args[2] == "close" { model.closeSourceTab(SourceFixture.tabID) }
        let actionWall = elapsed(actionStart)
        let actionCPU = try cpuSeconds() - actionCPUStart
        let afterAction = try withExtendedLifetime(model) { try Memory() }
        let current = receipt(model)
        if args[2] == "close" {
            guard current.items == 0, current.tabs == 0, current.selectedID == nil else {
                throw ProbeError("Closing the source tab did not preserve expected semantics")
            }
        } else if current != original { throw ProbeError("Unchanged source control mutated") }

        // This intervention diagnoses the old loader as the remaining owner.
        // It follows the primary measurement; it is not proposed application behavior.
        let stopCPUStart = try cpuSeconds()
        let stopStart = DispatchTime.now().uptimeNanoseconds
        AppModel.stopStartupForProbe()
        let stopWall = elapsed(stopStart)
        let stopCPU = try cpuSeconds() - stopCPUStart
        let afterStop = try withExtendedLifetime(model) { try Memory() }
        let final = receipt(model)
        guard final == current else { throw ProbeError("Diagnostic stop changed the live model") }
        let sameModel = await AppModel.loadShared() === model
        guard sameModel, AppPreferences.defaults.sourceReadCount == 1 else {
            throw ProbeError("Singleton publication or one-read startup contract changed")
        }
        let result = Observation(itemCount: count, mode: args[2], before: before,
            published: published, afterAction: afterAction, afterDiagnosticStop: afterStop,
            sourceBeforeAction: original, sourceAfterAction: current, sourceAfterDiagnosticStop: final,
            sourceReadCount: AppPreferences.defaults.sourceReadCount, sharedIdentityPreserved: sameModel,
            loadWallSeconds: loadWall, loadCPUSeconds: loadCPU,
            actionWallSeconds: actionWall, actionCPUSeconds: actionCPU,
            diagnosticStopWallSeconds: stopWall, diagnosticStopCPUSeconds: stopCPU)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        print(String(decoding: try encoder.encode(result), as: UTF8.self))
    }
}
