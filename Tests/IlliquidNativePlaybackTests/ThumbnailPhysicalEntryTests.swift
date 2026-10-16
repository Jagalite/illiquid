import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
import IlliquidCore
@testable import IlliquidNativePlayback

/// Native counterparts to the portable cache-control-flow tests. No timing
/// thresholds: execute these against real CoreGraphics/ImageIO on macOS.
@MainActor
final class ThumbnailPhysicalEntryTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("illiquid-physical-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func key(_ n: Int = 1) -> NativeThumbnailCache.Key {
        .init(path: "/test/\(n).mkv", version: "v1", halfSecond: n, width: 64, height: 64)
    }
    private func path(_ root: URL, _ key: NativeThumbnailCache.Key, _ foreground: Bool) -> URL {
        root.appendingPathComponent("\(foreground ? "f" : "b")-\(key.digest).jpg")
    }
    private func image(width: Int) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: 12,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: 12))
        return try XCTUnwrap(context.makeImage())
    }
    @discardableResult
    private func jpeg(_ root: URL, _ key: NativeThumbnailCache.Key, _ foreground: Bool, width: Int) throws -> Int {
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try image(width: width), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        try (data as Data).write(to: path(root, key, foreground))
        return data.length
    }
    func testBothPhysicalAliasesAreAccountedAndCleared() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let k = key(); let b = try jpeg(root, k, false, width: 10), f = try jpeg(root, k, true, width: 20)
        let cache = NativeThumbnailDiskCache(directory: root)
        let bytes = await cache.bytes(); XCTAssertEqual(bytes, b + f)
        let cleared = await cache.clear(epoch: 1); XCTAssertTrue(cleared)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }
    func testForegroundAliasPreferredBeforeAndAfterInventory() async throws {
        for inventory in [false, true] {
            let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
            let k = key(); try jpeg(root, k, true, width: 20); try jpeg(root, k, false, width: 10)
            let cache = NativeThumbnailDiskCache(directory: root); if inventory { _ = await cache.bytes() }
            let result = await cache.image(for: k, background: false)
            XCTAssertEqual(result?.width, 20)
            XCTAssertTrue(FileManager.default.fileExists(atPath: path(root, k, false).path))
        }
    }
    func testCorruptPreferredAliasFallsBackToRealJPEG() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let k = key(); let size = try jpeg(root, k, false, width: 10)
        try Data("not an image".utf8).write(to: path(root, k, true))
        let cache = NativeThumbnailDiskCache(directory: root)
        let result = await cache.image(for: k, background: false); XCTAssertEqual(result?.width, 10)
        let bytes = await cache.bytes(); XCTAssertEqual(bytes, size)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).count, 1)
    }
    func testFailedAliasDeletionIsNotReportedAsClearSuccess() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let k = key(); try jpeg(root, k, false, width: 10); let f = try jpeg(root, k, true, width: 20)
        let cache = NativeThumbnailDiskCache(directory: root); _ = await cache.bytes()
        let replacement = path(root, k, true)
        try FileManager.default.removeItem(at: replacement)
        try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: true)
        let sentinel = replacement.appendingPathComponent("keep.txt"); try Data([1]).write(to: sentinel)
        let cleared = await cache.clear(epoch: 1); XCTAssertFalse(cleared)
        let bytes = await cache.bytes(); XCTAssertEqual(bytes, f)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path(root, k, false).path))
    }
    func testExactLookupDoesNotFollowStaticCacheSymlink() async throws {
        let root = try directory(), outside = try directory()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        let k = key(); try jpeg(root, k, false, width: 10); try jpeg(outside, k, true, width: 30)
        let target = path(outside, k, true)
        try FileManager.default.createSymbolicLink(at: path(root, k, true), withDestinationURL: target)
        let cache = NativeThumbnailDiskCache(directory: root)
        let result = await cache.image(for: k, background: false); XCTAssertEqual(result?.width, 10)
        let cleared = await cache.clear(epoch: 1); XCTAssertTrue(cleared)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
    }
    func testForegroundReadDefersUnrelatedPruningButUsageEnforcesBudget() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let k = key(); try jpeg(root, k, true, width: 20)
        let first = path(root, key(2), false), second = path(root, key(3), false)
        try Data(repeating: 0, count: 700_000).write(to: first)
        try Data(repeating: 0, count: 700_000).write(to: second)
        let cache = NativeThumbnailDiskCache(directory: root)
        var settings = ThumbnailPreferences(); settings.diskMiB = 1; await cache.configure(settings)
        let result = await cache.image(for: k, background: false); XCTAssertEqual(result?.width, 20)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
        let bytes = await cache.bytes(); XCTAssertLessThanOrEqual(bytes, 1_048_576)
    }
    func testClearAfterDirectPromotionFindsAllRecognizedFiles() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        try jpeg(root, key(1), false, width: 10); try jpeg(root, key(2), true, width: 20)
        let cache = NativeThumbnailDiskCache(directory: root)
        _ = await cache.image(for: key(1), background: false)
        let cleared = await cache.clear(epoch: 1); XCTAssertTrue(cleared)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).count, 0)
    }
    func testFailedPromotionStillProtectsForegroundFromSpeculativeEviction() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let k = key(); try jpeg(root, k, false, width: 10)
        try FileManager.default.createDirectory(at: path(root, k, true), withIntermediateDirectories: true)
        let cache = NativeThumbnailDiskCache(directory: root, encode: { _ in Data(repeating: 0, count: 1_048_576) })
        var settings = ThumbnailPreferences(); settings.diskMiB = 1; await cache.configure(settings)
        let result = await cache.image(for: k, background: false); XCTAssertEqual(result?.width, 10)
        await cache.insert(try image(width: 20), for: key(99), background: true, epoch: 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path(root, k, false).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path(root, key(99), false).path))
    }
}
