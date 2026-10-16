import Foundation
import XCTest
import IlliquidCore
@testable import IlliquidNativePlayback

final class ThumbnailInventoryRegressionTests: XCTestCase {
    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("illiquid-inventory-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func name(_ value: Character = "a", tier: String = "b") -> String {
        "\(tier)-\(String(repeating: String(value), count: 64)).jpg"
    }
    private func write(_ url: URL, bytes: Int = 128) throws {
        try Data(repeating: 1, count: bytes).write(to: url)
    }
    func testInventoryIsShallowAndIgnoresDirectoryAndSymlinkLookalikes() async throws {
        let root = try makeDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        try write(root.appendingPathComponent(name()))
        let directory = root.appendingPathComponent(name("b"), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sentinel = directory.appendingPathComponent(name("c"))
        try write(sentinel)
        let target = root.appendingPathComponent("not-a-thumbnail.txt")
        try write(target, bytes: 500)
        let link = root.appendingPathComponent(name("d"))
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let cache = NativeThumbnailDiskCache(directory: root)
        let bytes = await cache.bytes()
        XCTAssertEqual(bytes, 128)
        let cleared = await cache.clear(epoch: 1)
        XCTAssertTrue(cleared)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: link.path))
    }
    func testKnownFileReplacedByDirectoryCannotBeRecursivelyDeleted() async throws {
        let root = try makeDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent(name())
        try write(path)
        let cache = NativeThumbnailDiskCache(directory: root)
        let before = await cache.bytes(); XCTAssertEqual(before, 128)
        try FileManager.default.removeItem(at: path)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        let sentinel = path.appendingPathComponent("keep.txt"); try write(sentinel)
        let cleared = await cache.clear(epoch: 1)
        XCTAssertFalse(cleared)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))
    }
    func testInvalidNamesRemainUntouchedByClear() async throws {
        let root = try makeDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let invalid = ["b-123.jpg", name("z"), name("Ａ"), name().replacingOccurrences(of: ".jpg", with: ".JPG"), name(tier: "F")]
        for filename in invalid { try write(root.appendingPathComponent(filename)) }
        let cache = NativeThumbnailDiskCache(directory: root)
        let bytes = await cache.bytes(); XCTAssertEqual(bytes, 0)
        let cleared = await cache.clear(epoch: 1); XCTAssertTrue(cleared)
        for filename in invalid { XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(filename).path)) }
    }
    func testZeroBudgetClearsOnlyRecognizedRegularEntries() async throws {
        let root = try makeDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        try write(root.appendingPathComponent(name("a", tier: "b")))
        try write(root.appendingPathComponent(name("b", tier: "f")), bytes: 256)
        let unknown = root.appendingPathComponent("keep.txt"); try write(unknown)
        let cache = NativeThumbnailDiskCache(directory: root)
        let before = await cache.bytes(); XCTAssertEqual(before, 384)
        var settings = ThumbnailPreferences(); settings.diskMiB = 0
        await cache.configure(settings)
        let after = await cache.bytes(); XCTAssertEqual(after, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: unknown.path))
    }
    func testAlreadyMissingRecognizedFileDoesNotPreventClear() async throws {
        let root = try makeDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent(name())
        try write(path)
        let cache = NativeThumbnailDiskCache(directory: root)
        let before = await cache.bytes(); XCTAssertEqual(before, 128)
        try FileManager.default.removeItem(at: path)
        let cleared = await cache.clear(epoch: 1); XCTAssertTrue(cleared)
        let after = await cache.bytes(); XCTAssertEqual(after, 0)
    }
}
