import Foundation
import Testing

@testable import IlliquidApp

@Suite("Bounded native filesystem callback decoding")
struct SourceFilesystemEventBatchTests {
    private let recovery = SourceFilesystemEvent(path: "/", flags: [.eventsDropped])
    private let roots = [URL(fileURLWithPath: "/media/movies"), URL(fileURLWithPath: "/media/shows")]

    @Test func emptyAndNullPathsDoNotReadFlags() {
        for count in [0, 1, 4096, 10000] {
            let result = decode([String?](repeating: nil, count: count), repeatingFlags: .eventsDropped)
            #expect(result.events.isEmpty)
            #expect(result.readIndices.isEmpty)
        }
    }

    @Test func nilSlotsPreserveOriginalFlagIndicesAndOrdering() {
        let paths: [String?] = [nil, "/media/movies/映画 Café.mkv", nil, "", "/media/shows/A.mkv"]
        let flags: [SourceFilesystemEvent.Flags] = [
            .eventsDropped, [.created, .renamed], .eventsDropped, [], [.removed, .init(rawValue: 1 << 12)],
        ]
        let result = decode(paths, flags: flags)
        #expect(result.readIndices == [1, 3, 4])
        #expect(result.events == [
            .init(path: paths[1]!, flags: flags[1]), .init(path: "", flags: []),
            .init(path: paths[4]!, flags: flags[4]),
        ])
    }

    @Test func copiedStringsSurviveNativeStorageAndPreserveCStringDecoding() {
        // Native storage is freed before the returned events are inspected.
        let events = withNativePaths([
            [47, 0x80, 0xff, 0],
            Array("/media/movies/Before.mkv".utf8) + [0] + Array("ignored".utf8) + [0],
            Array("/media/shows/Cafe\u{301}/映画.mkv".utf8) + [0],
        ]) { paths in
            SourceFilesystemEventBatch.decode(paths: paths) { _ in [.created] }
        }
        #expect(events.map(\.path) == ["/\u{fffd}\u{fffd}", "/media/movies/Before.mkv", "/media/shows/Cafe\u{301}/映画.mkv"])
    }

    @Test func exactly4096ValidPathsKeepAllDetails() {
        let paths = (0..<4096).map { Optional("/media/movies/Film\($0).mkv") }
        let result = decode(paths, repeatingFlags: [.created, .directory])
        #expect(result.events.map(\.path) == paths.compactMap { $0 })
        #expect(result.events.allSatisfy { $0.flags == [.created, .directory] })
        #expect(result.readIndices == Array(paths.indices))
    }

    @Test(arguments: [4097, 8192])
    func oversizedCallbacksCollapseBeforeReadingFlags(_ count: Int) {
        let result = decode([String?](repeating: "/media/movies/Same.mkv", count: count))
        #expect(result.events.count == 1)
        #expect(result.events.first == recovery)
        #expect(result.readIndices.count == 0)
    }

    @Test func sparseRawCountAboveLimitStillPreserves4096ValidEntries() {
        let paths = (0..<8192).map { index -> String? in
            index.isMultiple(of: 2) ? "/media/movies/Film\(index).mkv" : nil
        }
        let result = decode(paths)
        #expect(result.events.map(\.path) == paths.compactMap { $0 })
        #expect(result.readIndices == Array(stride(from: 0, to: 8192, by: 2)))
    }

    @Test func sparseOverflowCountsValidEntriesInsteadOfRawSlots() {
        let paths = (0..<8193).map { index -> String? in
            index.isMultiple(of: 2) ? "/media/movies/Film\(index).mkv" : nil
        }
        let result = decode(paths)
        #expect(result.events == [recovery])
        #expect(result.readIndices.isEmpty)
        var onePath = [String?](repeating: nil, count: 10000)
        onePath[9999] = "/media/shows/Last.mkv"
        let sparse = decode(onePath)
        #expect(sparse.events == [.init(path: "/media/shows/Last.mkv", flags: [.created])])
        #expect(sparse.readIndices == [9999])
    }

    @Test(arguments: [0, 1, 2])
    func reportedLossWithinBudgetKeepsOriginalCallbackDetails(_ lossIndex: Int) {
        let paths: [String?] = ["/media/movies/A.mkv", "/outside/root", "/media/shows/B.mkv"]
        var flags = [SourceFilesystemEvent.Flags](repeating: [.created], count: paths.count)
        flags[lossIndex] = [.eventsDropped, .mustScanSubdirectories]
        let result = decode(paths, flags: flags)
        #expect(result.readIndices == [0, 1, 2])
        #expect(result.events == paths.indices.map { .init(path: paths[$0]!, flags: flags[$0]) })
        var buffer = SourceFilesystemEventBuffer()
        buffer.append(contentsOf: result.events)
        #expect(buffer.take() == [recovery])
    }

    @Test func overflowComposesWithPendingEventsAndResetsAfterDrain() {
        let ordinary = SourceFilesystemEvent(path: "/media/movies/A.mkv", flags: [.created])
        var buffer = SourceFilesystemEventBuffer()
        buffer.append(contentsOf: [ordinary])
        buffer.append(contentsOf: decode([String?](repeating: ordinary.path, count: 4097)).events)
        buffer.append(contentsOf: [ordinary])
        let drained = buffer.take()
        #expect(drained == [recovery])
        #expect(SourceFilesystemInvalidationPlanner.plan(events: drained, roots: roots)
            == SourceFilesystemInvalidationPlan(rootsToRescan: ["/media/movies", "/media/shows"]))
        #expect(SourceFilesystemInvalidationPlanner.plan(events: drained, roots: []).isEmpty)
        buffer.append(contentsOf: [ordinary])
        #expect(buffer.take() == [ordinary])
    }

    @Test(arguments: [UInt64(1), 42, 0xfeed_face])
    func seededCallbacksMatchOriginalBufferAndPlanner(_ seed: UInt64) {
        var random = seed
        for rawCount in [0, 9, 128, 4096, 4097, 8205] {
            for density in [0, 1, 2] {
                var paths: [String?] = []
                var flags: [SourceFilesystemEvent.Flags] = []
                for index in 0..<rawCount {
                    random = random &* 6364136223846793005 &+ 1442695040888963407
                    let admitted = density == 2 || (density == 1 && random & 1 == 0)
                    paths.append(admitted ? "/media/\(index.isMultiple(of: 2) ? "movies" : "shows")/Film\(index).mkv" : nil)
                    // Native-loss coverage is separate so these cases exercise
                    // detailed plans instead of all collapsing to one marker.
                    flags.append(.init(rawValue: UInt16((random >> 32) & 0xdf)))
                }
                let actual = decode(paths, flags: flags).events
                let original = paths.indices.compactMap { index -> SourceFilesystemEvent? in
                    paths[index].map { .init(path: $0, flags: flags[index]) }
                }
                for pendingCount in [0, 1, 4096] {
                    let pending = [SourceFilesystemEvent](repeating:
                        .init(path: "/media/movies/Pending.mkv", flags: [.created]), count: pendingCount)
                    var expectedBuffer = SourceFilesystemEventBuffer()
                    var actualBuffer = SourceFilesystemEventBuffer()
                    expectedBuffer.append(contentsOf: pending)
                    actualBuffer.append(contentsOf: pending)
                    expectedBuffer.append(contentsOf: original)
                    actualBuffer.append(contentsOf: actual)
                    let expected = expectedBuffer.take()
                    let received = actualBuffer.take()
                    #expect(received == expected)
                    #expect(SourceFilesystemInvalidationPlanner.plan(events: received, roots: roots)
                        == SourceFilesystemInvalidationPlanner.plan(events: expected, roots: roots))
                }
            }
        }
    }

    private func decode(_ paths: [String?], repeatingFlags: SourceFilesystemEvent.Flags = [.created])
        -> (events: [SourceFilesystemEvent], readIndices: [Int]) {
        decode(paths, flags: [SourceFilesystemEvent.Flags](repeating: repeatingFlags, count: paths.count))
    }

    private func decode(_ paths: [String?], flags: [SourceFilesystemEvent.Flags])
        -> (events: [SourceFilesystemEvent], readIndices: [Int]) {
        precondition(flags.count == paths.count)
        var reads: [Int] = []
        let events = withNativePaths(paths.map { $0.map { Array($0.utf8) + [0] } }) { pointers in
            SourceFilesystemEventBatch.decode(paths: pointers) { index in
                reads.append(index)
                return flags[index]
            }
        }
        return (events, reads)
    }
}

private func withNativePaths<T>(_ values: [[UInt8]?],
    _ body: (UnsafeBufferPointer<UnsafePointer<CChar>?>) -> T) -> T {
    var owners: [(pointer: UnsafeMutablePointer<CChar>, count: Int)] = []
    let pointers = values.map { value -> UnsafePointer<CChar>? in
        guard let value else { return nil }
        precondition(value.last == 0)
        let bytes = value.map { CChar(bitPattern: $0) }
        let pointer = UnsafeMutablePointer<CChar>.allocate(capacity: bytes.count)
        bytes.withUnsafeBufferPointer { pointer.initialize(from: $0.baseAddress!, count: $0.count) }
        owners.append((pointer, bytes.count))
        return UnsafePointer(pointer)
    }
    defer {
        for owner in owners {
            owner.pointer.deinitialize(count: owner.count)
            owner.pointer.deallocate()
        }
    }
    return pointers.withUnsafeBufferPointer(body)
}
