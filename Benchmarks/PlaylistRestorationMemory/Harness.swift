import Dispatch
import Foundation

#if os(Linux)
@inline(__always)
private func autoreleasepool<Result>(_ body: () throws -> Result) rethrows -> Result {
    try body()
}
#endif

private struct Fixture {
    let items: [FolderPlaylistItem]
    let savedIDs: [FolderPlaylistItem.ID]
    let expected: [FolderPlaylistItem]
}

private func item(_ index: Int, revision: Int = 0) -> FolderPlaylistItem {
    FolderPlaylistItem(
        url: URL(fileURLWithPath: "/Media/RestorationMemory/Season 01/Episode \(index).mkv"),
        externalSubtitleURLs: [
            URL(fileURLWithPath: "/Media/Subtitles/\(index)-\(revision).en.srt"),
            URL(fileURLWithPath: "/Media/Subtitles/\(index)-\(revision).ja.srt"),
        ],
        dateAdded: Date(timeIntervalSince1970: Double(index * 10 + revision))
    )
}

private func makeFixture(count: Int, scenario: String) -> Fixture {
    let original = (0..<count).map { item($0) }
    let savedIDs = original.map(\.id)
    switch scenario {
    case "unchanged":
        return Fixture(items: Array(original.reversed()), savedIDs: savedIDs, expected: original)
    case "edited":
        let survivors = original.enumerated().compactMap { index, value in
            index.isMultiple(of: 4) ? nil : value
        }
        let additions = (count..<(count + original.count - survivors.count)).map { item($0) }
        return Fixture(
            items: Array(survivors.reversed()) + additions,
            savedIDs: savedIDs,
            expected: survivors + additions
        )
    case "duplicates":
        // Later copies have different subtitles/dates. Full equality must keep
        // the first occurrence's metadata, not merely the same identities.
        let laterCopies = (0..<count).map { item($0, revision: 1) }
        return Fixture(
            items: Array(original.reversed()) + laterCopies,
            savedIDs: savedIDs + savedIDs + ["/Media/removed.mkv"],
            expected: original
        )
    case "no-base":
        let current = Array(original.reversed())
        return Fixture(items: current, savedIDs: [], expected: current)
    default:
        preconditionFailure("Unknown scenario")
    }
}

@inline(never)
private func warm(_ fixture: Fixture) {
    autoreleasepool {
        let result = PlaylistMutation.restoringOrder(fixture.items, ids: fixture.savedIDs)
        precondition(result == fixture.expected, "Warm-up changed complete playlist values")
    }
}

private struct Observation: Encodable {
    let mode: String
    let scenario: String
    let requestedCount: Int
    let inputCount: Int
    let savedIDCount: Int
    let validatedItemCount: Int
    let fullItemsEqual: Bool
    let itemStride: Int
    let indexStride: Int
    var milliseconds: [Double] = []
    var beforeBytes: UInt64?
    var checkpointBytes: UInt64?
    var checkpointDeltaBytes: Int64?
    var mapCapacity: UInt64?
    var orderCapacity: UInt64?
    var checkpointCount: UInt64?
}

@main
private enum Main {
    static func main() throws {
        let arguments = CommandLine.arguments
        precondition(arguments.count == 5, "Usage: harness timing|memory COUNT SCENARIO ROUNDS")
        let mode = arguments[1]
        guard let count = Int(arguments[2]), count > 0,
              let rounds = Int(arguments[4]), rounds > 0 else {
            preconditionFailure("Counts must be positive")
        }
        let scenario = arguments[3]
        // Drain fixture-construction temporaries before establishing the baseline.
        let fixture = autoreleasepool { makeFixture(count: count, scenario: scenario) }
        warm(fixture)
        var observation = Observation(
            mode: mode, scenario: scenario, requestedCount: count,
            inputCount: fixture.items.count, savedIDCount: fixture.savedIDs.count,
            validatedItemCount: fixture.expected.count, fullItemsEqual: true,
            itemStride: MemoryLayout<FolderPlaylistItem>.stride,
            indexStride: MemoryLayout<Int>.stride
        )

        #if RESTORATION_MEMORY
        precondition(mode == "memory" && scenario != "no-base")
        // Warm the stats API as well. The next begin resets every recorded field.
        restoration_memory_begin()
        let result = autoreleasepool {
            restoration_memory_begin()
            return PlaylistMutation.restoringOrder(fixture.items, ids: fixture.savedIDs)
        }
        let sample = restoration_memory_sample()
        precondition(sample.checkpoint_count == 1, "Expected one populated-map checkpoint")
        precondition(sample.unique_count == UInt64(fixture.expected.count))
        precondition(result == fixture.expected, "Memory run changed complete playlist values")
        observation.beforeBytes = sample.before_bytes
        observation.checkpointBytes = sample.checkpoint_bytes
        observation.checkpointDeltaBytes = Int64(sample.checkpoint_bytes) - Int64(sample.before_bytes)
        observation.mapCapacity = sample.map_capacity
        observation.orderCapacity = sample.order_capacity
        observation.checkpointCount = sample.checkpoint_count
        withExtendedLifetime(result) {}
        #else
        precondition(mode == "timing")
        for _ in 0..<rounds {
            let elapsed: Double = autoreleasepool {
                let start = DispatchTime.now().uptimeNanoseconds
                let result = PlaylistMutation.restoringOrder(fixture.items, ids: fixture.savedIDs)
                let end = DispatchTime.now().uptimeNanoseconds
                // Validation and result destruction are outside the timed interval.
                precondition(result == fixture.expected, "Timing run changed complete playlist values")
                return Double(end - start) / 1_000_000
            }
            observation.milliseconds.append(elapsed)
        }
        #endif

        // Keep input, IDs, and the reference result live across both heap samples.
        withExtendedLifetime(fixture) {}
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        print(String(decoding: try encoder.encode(observation), as: UTF8.self))
    }
}
