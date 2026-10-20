import Foundation
import XCTest
@testable import IlliquidNativePlayback

#if canImport(CoreGraphics)
import CoreGraphics
import IlliquidCore
#endif

final class ThumbnailDiskEvictionTests: XCTestCase {
    private typealias Entry = ThumbnailDiskEvictionHeap.Entry

    /// Keep the oracle identical to the dictionary filter/sort used by trimDisk
    /// before the heap, including the metadata tier after a failed promotion.
    private func baseline(_ entries: [Entry], background: Bool) -> [Entry] {
        let files = Dictionary(uniqueKeysWithValues: entries.map { ($0.filename, $0) })
        return files.filter { !background || $0.value.background }.sorted {
            if $0.value.background != $1.value.background { return $0.value.background }
            if $0.value.used != $1.value.used { return $0.value.used < $1.value.used }
            return $0.key < $1.key
        }.map(\.value)
    }

    private func drain(_ entries: [Entry]) -> [Entry] {
        var heap = ThumbnailDiskEvictionHeap(entries)
        var result: [Entry] = []
        while let entry = heap.popFirst() { result.append(entry) }
        XCTAssertNil(heap.popFirst())
        return result
    }

    private func filename(_ number: Int, background: Bool) -> String {
        let digest = String(number, radix: 16)
        return "\(background ? "b" : "f")-\(String(repeating: "0", count: 64 - digest.count))\(digest).jpg"
    }

    func testEmptyAndSingletonAreConsumedExactlyOnce() {
        var empty = ThumbnailDiskEvictionHeap([])
        XCTAssertNil(empty.popFirst())
        XCTAssertNil(empty.popFirst())
        let entry = Entry(filename: filename(1, background: true), used: .distantPast, background: true)
        var singleton = ThumbnailDiskEvictionHeap([entry])
        XCTAssertEqual(singleton.popFirst(), entry)
        XCTAssertNil(singleton.popFirst())
        XCTAssertNil(singleton.popFirst())
    }

    func testOrderUsesMetadataTierThenDateThenLiteralFilename() {
        func name(_ tier: String, _ digit: String) -> String {
            "\(tier)-\(String(repeating: digit, count: 64)).jpg"
        }
        let tied = Date(timeIntervalSince1970: 0.125)
        let expected = [
            Entry(filename: name("b", "f"), used: .distantPast, background: true),
            Entry(filename: name("b", "A"), used: tied, background: true),
            Entry(filename: name("b", "a"), used: tied, background: true),
            Entry(filename: name("b", "b"), used: tied, background: true),
            Entry(filename: name("b", "0"), used: .distantFuture, background: true),
            // A failed rename can leave a foreground entry with a b- filename.
            Entry(filename: name("b", "c"), used: .distantPast, background: false),
            Entry(filename: name("f", "0"), used: .distantPast, background: false),
            Entry(filename: name("f", "f"), used: .distantFuture, background: false),
        ]
        let input = [6, 3, 5, 1, 4, 0, 2, 7].map { expected[$0] }
        XCTAssertEqual(baseline(input, background: false), expected)
        XCTAssertEqual(drain(input), expected)
        XCTAssertEqual(
            drain(input.filter(\.background)),
            baseline(input, background: true)
        )
    }

    func testCompleteDrainMatchesLegacyOrderThroughFullInventorySize() {
        let dates: [Date] = [
            .distantPast,
            Date(timeIntervalSince1970: -1.25),
            Date(timeIntervalSince1970: 0),
            Date(timeIntervalSince1970: 0.125),
            Date(timeIntervalSince1970: 1),
            .distantFuture,
        ]
        var random = EvictionTestRandom(state: 0x1_11_1_0_1D)
        for count in [0, 1, 2, 3, 4, 5, 31, 128, 1_024, 8_192] {
            let entries = (0..<count).map { index in
                let physicalBackground = index.isMultiple(of: 3)
                return Entry(
                    filename: filename(index, background: physicalBackground),
                    used: dates[Int(random.next() % UInt64(dates.count))],
                    background: physicalBackground && !index.isMultiple(of: 7)
                )
            }
            let ordered = baseline(entries, background: false)
            for input in [ordered, Array(ordered.reversed()), entries.shuffled(using: &random)] {
                for background in [false, true] {
                    let eligible = input.filter { !background || $0.background }
                    XCTAssertEqual(
                        drain(eligible), baseline(input, background: background),
                        "Full victim sequence differs at count \(count), background \(background)"
                    )
                }
            }
        }
    }

    func testEligibilityWithOnlyOneMetadataTier() {
        for tier in [false, true] {
            let entries = (0..<128).map {
                Entry(filename: filename($0, background: tier), used: .distantPast, background: tier)
            }.reversed()
            for background in [false, true] {
                let eligible = entries.filter { !background || $0.background }
                XCTAssertEqual(drain(eligible), baseline(Array(entries), background: background))
            }
        }
    }
}

private struct EvictionTestRandom: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
}

#if canImport(CoreGraphics)
/// Exercise quota checks and removal side effects against the real disk actor.
/// Reservation, zero-budget, and clear coverage lives in ThumbnailPhysicalEntryTests
/// and ThumbnailInventoryRegressionTests.
@MainActor
final class ThumbnailDiskEvictionDiskTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("illiquid-eviction-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func filename(_ number: Int, background: Bool = true) -> String {
        let digest = String(number, radix: 16)
        return "\(background ? "b" : "f")-\(String(repeating: "0", count: 64 - digest.count))\(digest).jpg"
    }

    private func write(_ root: URL, name: String, bytes: Int, age: TimeInterval) throws {
        let url = root.appendingPathComponent(name)
        try Data(repeating: 1, count: bytes).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: age)], ofItemAtPath: url.path)
    }

    private func key(_ number: Int) -> NativeThumbnailCache.Key {
        .init(path: "/test/eviction-\(number).mkv", version: "v1", halfSecond: number, width: 1, height: 1)
    }

    private func image() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 1, height: 1,
            bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        return try XCTUnwrap(context.makeImage())
    }

    func testBudgetShrinkRemovesOnlyTheOrderedVictimPrefix() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let records: [(number: Int, background: Bool, age: TimeInterval)] = [
            (1, true, 10), (2, true, 10), (0, true, 20), (3, true, 30),
            (4, false, 0), (5, false, 0), (6, false, 40), (7, false, 50),
        ]
        for record in records.reversed() {
            try write(root, name: filename(record.number, background: record.background), bytes: 300_000, age: record.age)
        }
        let cache = NativeThumbnailDiskCache(directory: root)
        let before = await cache.bytes()
        XCTAssertEqual(before, 2_400_000)

        var settings = ThumbnailPreferences()
        settings.diskMiB = 2
        await cache.configure(settings)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)), Set(records.dropFirst(2).map {
            filename($0.number, background: $0.background)
        }))
        let afterFirstShrink = await cache.bytes()
        XCTAssertEqual(afterFirstShrink, 1_800_000)

        settings.diskMiB = 1
        await cache.configure(settings)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)), Set(records.suffix(3).map {
            filename($0.number, background: $0.background)
        }))
        let afterSecondShrink = await cache.bytes()
        XCTAssertEqual(afterSecondShrink, 900_000)
    }

    func testBackgroundAdmissionCannotEvictForegroundEntries() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let oldBackground = filename(1), oldForeground = filename(2, background: false)
        try write(root, name: oldBackground, bytes: 200_000, age: 20)
        try write(root, name: oldForeground, bytes: 800_000, age: 10)
        // The injected encoder isolates admission from JPEG encoding; these
        // tests never decode their synthetic on-disk payloads.
        let cache = NativeThumbnailDiskCache(directory: root, encode: { _ in Data(repeating: 2, count: 400_000) })
        var settings = ThumbnailPreferences()
        settings.diskMiB = 1
        await cache.configure(settings)
        let inserted = key(1)
        let thumbnail = try image()
        await cache.insert(thumbnail, for: inserted, background: true, epoch: 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [oldForeground])
        let afterRejectedAdmission = await cache.bytes()
        XCTAssertEqual(afterRejectedAdmission, 800_000)

        await cache.insert(thumbnail, for: inserted, background: false, epoch: 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["f-\(inserted.digest).jpg"])
        let afterForegroundAdmission = await cache.bytes()
        XCTAssertEqual(afterForegroundAdmission, 400_000)
    }

    func testCountCapEvictsOneEntryToAdmitTheNextThumbnail() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = Data([1])
        for number in 0..<8_191 {
            try payload.write(to: root.appendingPathComponent(filename(number)))
        }
        // Equal oldest dates make the physical filename the decisive tie-break.
        for number in [0, 1] {
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)],
                ofItemAtPath: root.appendingPathComponent(filename(number)).path)
        }
        let cache = NativeThumbnailDiskCache(directory: root, encode: { _ in Data([2]) })
        let before = await cache.bytes()
        XCTAssertEqual(before, 8_191)
        let first = key(1), second = key(2), thumbnail = try image()
        await cache.insert(thumbnail, for: first, background: false, epoch: 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).count, 8_192)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(filename(0)).path))

        await cache.insert(thumbnail, for: second, background: false, epoch: 0)
        var expected = Set((1..<8_191).map { filename($0) })
        expected.insert("f-\(first.digest).jpg")
        expected.insert("f-\(second.digest).jpg")
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)), expected)
        let after = await cache.bytes()
        XCTAssertEqual(after, 8_192)
    }

    func testFailedUnlinkStopsTrimAndKeepsTheVictimForRetry() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let oldest = filename(1), next = filename(2), foreground = filename(3, background: false)
        try write(root, name: oldest, bytes: 400_000, age: 1)
        try write(root, name: next, bytes: 400_000, age: 2)
        try write(root, name: foreground, bytes: 400_000, age: 0)
        let cache = NativeThumbnailDiskCache(directory: root)
        let before = await cache.bytes()
        XCTAssertEqual(before, 1_200_000)

        let replaced = root.appendingPathComponent(oldest)
        try FileManager.default.removeItem(at: replaced)
        try FileManager.default.createDirectory(at: replaced, withIntermediateDirectories: true)
        let sentinel = replaced.appendingPathComponent("keep.txt")
        try Data([9]).write(to: sentinel)
        var settings = ThumbnailPreferences()
        settings.diskMiB = 1
        await cache.configure(settings)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)), Set([oldest, next, foreground]))
        XCTAssertEqual(try Data(contentsOf: sentinel), Data([9]))
        let afterFailure = await cache.bytes()
        XCTAssertEqual(afterFailure, 1_200_000)

        try FileManager.default.removeItem(at: replaced)
        try write(root, name: oldest, bytes: 400_000, age: 1)
        await cache.configure(settings)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)), Set([next, foreground]))
        let afterRetry = await cache.bytes()
        XCTAssertEqual(afterRetry, 800_000)
    }
}
#endif
